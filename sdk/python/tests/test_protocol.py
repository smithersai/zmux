"""Unit tests for framing, error mapping, protocol parsing, and replay/offset deduplication."""

from __future__ import annotations

import base64
import json
import unittest

from zmux.errors import ErrorCode, ZmuxProtocolError, ZmuxRpcError
from zmux.protocol import (
    AttachResult,
    CaptureResult,
    ClientDetachedEvent,
    ClientSwitchedEvent,
    DispatchKeyResult,
    ExecPaneResult,
    ForegroundChangedEvent,
    FrameDecoder,
    LayoutLeaf,
    LayoutSplit,
    MuxSnapshot,
    OutputReassembler,
    PaneActivityEvent,
    PaneBellEvent,
    PaneCwdChangedEvent,
    PaneOutputDroppedEvent,
    PaneOutputEvent,
    PanePromptChangedEvent,
    PaneRespawnedEvent,
    PaneStatusChangedEvent,
    PaneTitleChangedEvent,
    PingResult,
    ScreenResult,
    SessionExitedEvent,
    UnknownNotification,
    WaitResult,
    encode_request,
    parse_notification,
)


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


class ErrorMappingTests(unittest.TestCase):
    def test_from_rpc_error_extracts_code_kind_message(self) -> None:
        err = ZmuxRpcError.from_rpc_error(
            {
                "code": ErrorCode.SESSION_ERROR,
                "message": "PaneNotFound",
                "data": {"kind": "not_found"},
            }
        )
        self.assertEqual(err.code, -32000)
        self.assertEqual(err.kind, "not_found")
        self.assertEqual(err.message, "PaneNotFound")
        self.assertTrue(err.is_not_found)
        self.assertFalse(err.is_conflict)
        self.assertIn("PaneNotFound", str(err))

    def test_from_rpc_error_fallback_kinds_without_data(self) -> None:
        for code, expected_kind in (
            (ErrorCode.PARSE_ERROR, "parse"),
            (ErrorCode.INVALID_REQUEST, "invalid_request"),
            (ErrorCode.METHOD_NOT_FOUND, "method_not_found"),
            (ErrorCode.INVALID_PARAMS, "invalid_params"),
            (ErrorCode.INTERNAL_ERROR, "internal"),
            (ErrorCode.SESSION_ERROR, "unknown"),
        ):
            err = ZmuxRpcError.from_rpc_error({"code": code, "message": "oops"})
            self.assertEqual(err.code, code)
            self.assertEqual(err.kind, expected_kind)

        m_err = ZmuxRpcError(ErrorCode.METHOD_NOT_FOUND, "method_not_found", "MethodNotFound")
        self.assertTrue(m_err.is_method_not_found)
        c_err = ZmuxRpcError(ErrorCode.SESSION_ERROR, "conflict", "PaneRunning")
        self.assertTrue(c_err.is_conflict)
        t_err = ZmuxRpcError(ErrorCode.SESSION_ERROR, "terminated", "SessionTerminated")
        self.assertTrue(t_err.is_terminated)


class FramingTests(unittest.TestCase):
    def test_partial_chunks_and_multiline_bursts(self) -> None:
        dec = FrameDecoder(max_frame_bytes=4096)
        raw = (
            b'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n'
            b"\n"
            b'{"jsonrpc":"2.0","method":"pane_bell","params":{"pane_id":"p1","last_bell_ms":9}}\r\n'
        )
        # Feed 5 bytes at a time, including splitting multi-byte lines.
        decoded: list[dict[str, object]] = []
        for i in range(0, len(raw), 5):
            decoded.extend(dec.feed(raw[i : i + 5]))
        self.assertEqual(len(decoded), 2)
        self.assertEqual(decoded[0]["id"], 1)
        self.assertEqual(decoded[1]["method"], "pane_bell")
        dec.check_eof()

    def test_bounded_frame_cap_rejects_oversized_with_or_without_newline(self) -> None:
        dec = FrameDecoder(max_frame_bytes=64)
        with self.assertRaises(ZmuxProtocolError):
            dec.feed(b'{"id":1,"result":"' + b"a" * 80 + b'"}\n')

        dec2 = FrameDecoder(max_frame_bytes=32)
        dec2.feed(b"{" + b"a" * 20)
        with self.assertRaises(ZmuxProtocolError):
            dec2.feed(b"b" * 20)

    def test_malformed_json_non_object_and_truncated_eof(self) -> None:
        dec = FrameDecoder()
        with self.assertRaises(ZmuxProtocolError):
            dec.feed(b"{bad json}\n")

        with self.assertRaises(ZmuxProtocolError):
            dec.feed(b"[1,2,3]\n")

        dec.feed(b'{"jsonrpc":"2.0","id":1')
        with self.assertRaises(ZmuxProtocolError):
            dec.check_eof()

    def test_encode_request_and_notification(self) -> None:
        req = encode_request("daemon.ping", {}, 42)
        self.assertTrue(req.endswith(b"\n"))
        self.assertEqual(req.count(b"\n"), 1)
        parsed = json.loads(req.decode("utf-8"))
        self.assertEqual(parsed, {"jsonrpc": "2.0", "method": "daemon.ping", "id": 42, "params": {}})

        notif = encode_request("session.send", {"sessionId": "p1", "text": "hi"}, is_notification=True)
        parsed_n = json.loads(notif.decode("utf-8"))
        self.assertNotIn("id", parsed_n)

        with self.assertRaises(ZmuxProtocolError):
            encode_request("session.send", {"text": "x" * 200}, 1, max_request_bytes=64)


class ProtocolParsingTests(unittest.TestCase):
    def test_parse_all_notifications_and_camel_or_snake_client_switched(self) -> None:
        out = parse_notification(
            "pane_output",
            {"pane_id": "pane-1", "data_base64": _b64(b"hello"), "offset": 10, "generation": 2},
        )
        self.assertIsInstance(out, PaneOutputEvent)
        assert isinstance(out, PaneOutputEvent)
        self.assertEqual(out.data, b"hello")
        self.assertEqual(out.offset, 10)
        self.assertEqual(out.generation, 2)

        dropped = parse_notification(
            "pane_output_dropped",
            {"pane_id": "pane-1", "dropped_bytes": 512, "resume_offset": 1024, "generation": 2},
        )
        self.assertIsInstance(dropped, PaneOutputDroppedEvent)
        assert isinstance(dropped, PaneOutputDroppedEvent)
        self.assertEqual(dropped.dropped_bytes, 512)
        self.assertEqual(dropped.resume_offset, 1024)

        act = parse_notification("pane_activity", {"pane_id": "pane-1", "last_activity_ms": 111, "generation": 1})
        self.assertIsInstance(act, PaneActivityEvent)

        bell = parse_notification("pane_bell", {"pane_id": "pane-1", "last_bell_ms": 222, "generation": 1})
        self.assertIsInstance(bell, PaneBellEvent)

        exited = parse_notification(
            "session_exited",
            {"session_id": "pane-1", "pid": 999, "exit_code": 0, "signal": None, "generation": 3},
        )
        self.assertIsInstance(exited, SessionExitedEvent)
        assert isinstance(exited, SessionExitedEvent)
        self.assertEqual(exited.pane_id, "pane-1")
        self.assertEqual(exited.exit_code, 0)

        fg = parse_notification(
            "foreground_changed",
            {"session_id": "pane-1", "pid": 55, "comm": "git", "argv": ["git", "status"], "argv_truncated": False},
        )
        self.assertIsInstance(fg, ForegroundChangedEvent)
        assert isinstance(fg, ForegroundChangedEvent)
        self.assertEqual(fg.argv, ("git", "status"))

        resp = parse_notification("pane_respawned", {"pane_id": "pane-1", "generation": 4, "pid": 77})
        self.assertIsInstance(resp, PaneRespawnedEvent)

        det = parse_notification("client_detached", {"client_id": "client-1", "reason": "remote_detach"})
        self.assertIsInstance(det, ClientDetachedEvent)

        # camelCase replay fields (as emitted by v0.4.0 src/server.zig)
        sw_camel = parse_notification(
            "client_switched",
            {
                "client_id": "client-1",
                "pane_id": "pane-2",
                "generation": 2,
                "replayBase64": _b64(b"abc"),
                "replayStartOffset": 5,
                "replayEndOffset": 8,
            },
        )
        self.assertIsInstance(sw_camel, ClientSwitchedEvent)
        assert isinstance(sw_camel, ClientSwitchedEvent)
        self.assertEqual(sw_camel.replay_bytes, b"abc")
        self.assertEqual(sw_camel.replay_end_offset, 8)

        # snake_case replay fields (forward-compatible)
        sw_snake = parse_notification(
            "client_switched",
            {
                "client_id": "client-1",
                "pane_id": "pane-3",
                "generation": 5,
                "replay_base64": _b64(b"xyz"),
                "replay_start_offset": 0,
                "replay_end_offset": 3,
            },
        )
        self.assertIsInstance(sw_snake, ClientSwitchedEvent)
        assert isinstance(sw_snake, ClientSwitchedEvent)
        self.assertEqual(sw_snake.replay_bytes, b"xyz")
        self.assertEqual(sw_snake.replay_end_offset, 3)

        # Forward-compatible v0.5/v0.6 notifications and unknown fallback
        self.assertIsInstance(parse_notification("pane_title_changed", {"pane_id": "p1", "title": "vim"}), PaneTitleChangedEvent)
        self.assertIsInstance(parse_notification("pane_cwd_changed", {"pane_id": "p1", "cwd": "/tmp"}), PaneCwdChangedEvent)
        self.assertIsInstance(parse_notification("pane_prompt_changed", {"pane_id": "p1", "prompt_state": "prompt"}), PanePromptChangedEvent)
        self.assertIsInstance(parse_notification("pane_status_changed", {"pane_id": "p1", "agent_status": "working"}), PaneStatusChangedEvent)
        unk = parse_notification("future_event", {"k": 1})
        self.assertIsInstance(unk, UnknownNotification)

    def test_parse_snapshot_and_v05_results(self) -> None:
        ping = PingResult.from_dict(
            {
                "version": "0.4.0",
                "pid": 123,
                "socketPath": "/tmp/z.sock",
                "sessions": 1,
                "panes": 2,
                "livePanes": 2,
                "connections": 1,
                "droppedEvents": 0,
                "rejectedConnections": 0,
            }
        )
        self.assertEqual(ping.version, "0.4.0")
        self.assertEqual(ping.live_panes, 2)

        cap = CaptureResult.from_dict({"sessionId": "pane-1", "text": "hi", "textBase64": _b64(b"hi")})
        self.assertEqual(cap.raw_bytes, b"hi")

        snap = MuxSnapshot.from_dict(
            {
                "sessions": [
                    {
                        "id": "sess-1",
                        "name": "work",
                        "activeWindowId": "win-1",
                        "windows": [
                            {
                                "id": "win-1",
                                "sessionId": "sess-1",
                                "index": 0,
                                "name": "1",
                                "activePaneId": "pane-1",
                                "layout": {
                                    "kind": "split",
                                    "id": "split-1",
                                    "axis": "vertical",
                                    "first": {"kind": "leaf", "paneId": "pane-1"},
                                    "second": {"kind": "leaf", "paneId": "pane-2"},
                                },
                                "panes": [
                                    {
                                        "id": "pane-1",
                                        "windowId": "win-1",
                                        "sessionId": "sess-1",
                                        "index": 0,
                                        "title": "main",
                                        "hasCustomTitle": False,
                                        "state": "running",
                                        "generation": 1,
                                        "pid": 42,
                                        "rows": 24,
                                        "cols": 80,
                                        "cwd": "/tmp",
                                        "command": "sh",
                                        "alerts": {
                                            "activity": True,
                                            "bell": False,
                                            "exited": False,
                                            "lastActivityMs": 1000,
                                            "lastBellMs": 0,
                                        },
                                    }
                                ],
                            }
                        ],
                    }
                ],
                "clients": [
                    {
                        "id": "client-1",
                        "sessionId": "sess-1",
                        "windowId": "win-1",
                        "paneId": "pane-1",
                        "rows": 24,
                        "cols": 80,
                        "active": True,
                    }
                ],
                "keyBindings": [{"table": "prefix", "key": "%", "command": "split-window -h", "repeat": False}],
            }
        )
        self.assertEqual(len(snap.sessions), 1)
        layout = snap.sessions[0].windows[0].layout
        self.assertIsInstance(layout, LayoutSplit)
        assert isinstance(layout, LayoutSplit)
        self.assertIsInstance(layout.first, LayoutLeaf)
        self.assertEqual(snap.key_bindings[0].key, "%")

        unhandled = DispatchKeyResult.from_dict({"handled": False})
        self.assertFalse(unhandled.handled)
        self.assertIsNone(unhandled.snapshot)

        screen = ScreenResult.from_dict(
            {
                "rows": 24,
                "cols": 80,
                "cursor": {"row": 2, "col": 5, "visible": True},
                "altScreen": False,
                "title": "bash",
                "cwd": "/tmp",
                "promptState": "prompt",
                "lastCommandExitCode": 0,
                "commandSeq": 3,
                "agentStatus": "idle",
                "modes": {"autowrap": True},
                "text": "$ ",
                "lines": ["$ "],
            }
        )
        self.assertEqual(screen.cursor.row, 2)
        self.assertEqual(screen.prompt_state, "prompt")
        self.assertEqual(screen.lines, ("$ ",))

        wait = WaitResult.from_dict({"matched": True, "reason": "pattern", "paneId": "pane-1", "match": "OK", "elapsedMs": 12})
        self.assertTrue(wait.matched)
        self.assertEqual(wait.match, "OK")

        ex = ExecPaneResult.from_dict({"paneId": "pane-1", "exitCode": 0, "output": "done\n", "timedOut": False})
        self.assertEqual(ex.exit_code, 0)
        self.assertEqual(ex.output, "done\n")


class OutputReassemblerTests(unittest.TestCase):
    def _make_attach(
        self,
        *,
        pane_id: str = "pane-1",
        generation: int = 1,
        replay: bytes = b"hello world",
        start: int = 0,
        end: int | None = None,
    ) -> AttachResult:
        end_off = start + len(replay) if end is None else end
        return AttachResult(
            client_id="client-1",
            session_id="sess-1",
            window_id="win-1",
            pane_id=pane_id,
            rows=24,
            cols=80,
            generation=generation,
            replay_base64=_b64(replay),
            replay_start_offset=start,
            replay_end_offset=end_off,
        )

    def test_deduplicates_full_and_partial_overlap_with_replay(self) -> None:
        attach = self._make_attach(replay=b"0123456789", start=0, end=10)
        reasm = OutputReassembler(attach)
        self.assertEqual(reasm.initial_replay(attach), b"0123456789")
        self.assertEqual(reasm.cursor_offset, 10)

        # Completely covered by replay -> dropped.
        ev_old = PaneOutputEvent("pane-1", _b64(b"456789"), b"456789", offset=4, generation=1)
        self.assertEqual(reasm.apply_output(ev_old), b"")
        self.assertEqual(reasm.cursor_offset, 10)

        # Partially overlapping replay -> emits only the unseen tail.
        ev_partial = PaneOutputEvent("pane-1", _b64(b"89ABCD"), b"89ABCD", offset=8, generation=1)
        self.assertEqual(reasm.apply_output(ev_partial), b"ABCD")
        self.assertEqual(reasm.cursor_offset, 14)

        # Contiguous live chunk -> emitted in full.
        ev_next = PaneOutputEvent("pane-1", _b64(b"EF"), b"EF", offset=14, generation=1)
        self.assertEqual(reasm.apply_output(ev_next), b"EF")
        self.assertEqual(reasm.cursor_offset, 16)

        # Different pane ignored.
        ev_other = PaneOutputEvent("pane-2", _b64(b"ZZ"), b"ZZ", offset=0, generation=1)
        self.assertEqual(reasm.apply_output(ev_other), b"")

    def test_generation_filtering_respawn_dropped_and_switch(self) -> None:
        attach = self._make_attach(generation=2, replay=b"abc", start=10, end=13)
        reasm = OutputReassembler(attach)

        # Stale generation ignored.
        stale = PaneOutputEvent("pane-1", _b64(b"old"), b"old", offset=99, generation=1)
        self.assertEqual(reasm.apply_output(stale), b"")

        # Dropped output advances cursor.
        dropped = PaneOutputDroppedEvent("pane-1", dropped_bytes=100, resume_offset=113, generation=2)
        self.assertTrue(reasm.apply_dropped(dropped))
        self.assertEqual(reasm.cursor_offset, 113)

        # Respawn resets offset to 0 on higher generation.
        respawn = PaneRespawnedEvent("pane-1", generation=3, pid=999)
        self.assertTrue(reasm.apply_respawned(respawn))
        self.assertEqual(reasm.generation, 3)
        self.assertEqual(reasm.cursor_offset, 0)

        ev_new_gen = PaneOutputEvent("pane-1", _b64(b"fresh"), b"fresh", offset=0, generation=3)
        self.assertEqual(reasm.apply_output(ev_new_gen), b"fresh")
        self.assertEqual(reasm.cursor_offset, 5)

        # Client switched updates pane_id, generation, and offset.
        sw = ClientSwitchedEvent("client-1", "pane-9", 7, _b64(b"sw"), 20, 22)
        self.assertEqual(reasm.apply_switched(sw), b"sw")
        self.assertEqual(reasm.pane_id, "pane-9")
        self.assertEqual(reasm.generation, 7)
        self.assertEqual(reasm.cursor_offset, 22)

    def test_reconnect_deduplicates_same_generation_and_handles_gap(self) -> None:
        attach1 = self._make_attach(generation=1, replay=b"hello", start=0, end=5)
        reasm = OutputReassembler(attach1)
        self.assertEqual(reasm.cursor_offset, 5)

        # Reconnect returns replay covering 0..9 -> only unseen suffix "1234" emitted.
        attach2 = self._make_attach(generation=1, replay=b"hello1234", start=0, end=9)
        self.assertEqual(reasm.apply_reconnect(attach2), b"1234")
        self.assertEqual(reasm.cursor_offset, 9)

        # Reconnect with no new bytes -> empty.
        attach3 = self._make_attach(generation=1, replay=b"hello1234", start=0, end=9)
        self.assertEqual(reasm.apply_reconnect(attach3), b"")

        # Reconnect after scrollback wrapped past cursor -> emit full replay.
        attach4 = self._make_attach(generation=1, replay=b"GAP_TAIL", start=50, end=58)
        self.assertEqual(reasm.apply_reconnect(attach4), b"GAP_TAIL")
        self.assertEqual(reasm.cursor_offset, 58)

        # Reconnect on newer generation -> emit full replay.
        attach5 = self._make_attach(generation=2, replay=b"RESPAWNED", start=0, end=9)
        self.assertEqual(reasm.apply_reconnect(attach5), b"RESPAWNED")
        self.assertEqual(reasm.generation, 2)
        self.assertEqual(reasm.cursor_offset, 9)


if __name__ == "__main__":
    unittest.main()
