"""Live integration tests against a real `zmuxd` daemon plus mock v0.5/v0.6 UNIX server tests."""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

from zmux import (
    AsyncZmuxClient,
    ClientSwitchedEvent,
    PaneOutputEvent,
    SessionExitedEvent,
    ZmuxClient,
    ZmuxConnectionError,
    ZmuxRpcError,
    ZmuxTimeoutError,
)


def _find_zmuxd() -> str:
    env_bin = os.environ.get("ZMUXD_BIN")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    local_bin = repo_root / "zig-out" / "bin" / "zmuxd"
    if local_bin.is_file() and os.access(local_bin, os.X_OK):
        return str(local_bin)
    found = shutil.which("zmuxd")
    if found:
        return found
    raise RuntimeError(f"zmuxd binary not found (expected at {local_bin}; run `zig build` first)")


class LiveDaemonBase(unittest.TestCase):
    """Spawns a dedicated `zmuxd` instance in a short `/tmp` directory per test."""

    def setUp(self) -> None:
        self.zmuxd_bin = _find_zmuxd()
        self.tmp_dir = tempfile.mkdtemp(prefix="zmux-py-", dir="/tmp")
        os.chmod(self.tmp_dir, 0o700)
        self.socket_path = os.path.join(self.tmp_dir, "s.sock")
        self.proc: subprocess.Popen[bytes] | None = None

    def start_daemon(self) -> None:
        self.proc = subprocess.Popen(
            [self.zmuxd_bin, "--socket", self.socket_path, "--idle-seconds", "0"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                stderr = self.proc.stderr.read().decode("utf-8", errors="replace") if self.proc.stderr else ""
                raise RuntimeError(f"zmuxd exited early ({self.proc.returncode}): {stderr}")
            if os.path.exists(self.socket_path):
                try:
                    with ZmuxClient.connect(self.socket_path, timeout=1.0) as client:
                        client.ping()
                        return
                except Exception:
                    pass
            time.sleep(0.02)
        raise TimeoutError(f"zmuxd did not start listening on {self.socket_path}")

    def tearDown(self) -> None:
        try:
            with ZmuxClient.connect(self.socket_path, timeout=1.0) as client:
                client.shutdown()
        except Exception:
            pass

        if self.proc is not None:
            try:
                self.proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=2.0)
            if self.proc.stderr is not None:
                self.proc.stderr.close()

        shutil.rmtree(self.tmp_dir, ignore_errors=True)


class SyncLiveDaemonTests(LiveDaemonBase):
    def test_auto_spawn_ping_and_shutdown(self) -> None:
        # Connecting without spawn_daemon fails clearly.
        with self.assertRaises(ZmuxConnectionError):
            ZmuxClient.connect(self.socket_path, timeout=1.0, spawn_daemon=False)

        with ZmuxClient.connect(
            self.socket_path,
            timeout=5.0,
            spawn_daemon=True,
            daemon_bin=self.zmuxd_bin,
            idle_seconds=60,
        ) as client:
            pong = client.ping()
            self.assertEqual(pong.version, "0.5.0")
            self.assertGreater(pong.pid, 0)
            self.assertEqual(pong.socket_path, self.socket_path)
            self.assertEqual(pong.sessions, 0)
            self.assertTrue(client.shutdown())

    def test_full_rpc_surface_and_error_mapping(self) -> None:
        self.start_daemon()
        with ZmuxClient.connect(self.socket_path, timeout=5.0) as client:
            created = client.create_session(
                "alpha",
                command="/bin/sh",
                rows=24,
                cols=80,
                env={"ZMUX_PY_TEST": "yes"},
            )
            self.assertIsNotNone(created.pane_id)
            assert created.pane_id is not None
            assert created.session_id is not None
            assert created.window_id is not None

            sessions = client.list_sessions()
            self.assertEqual(len(sessions), 1)
            self.assertEqual(sessions[0].session_name, "alpha")

            info = client.info_session(created.pane_id)
            self.assertEqual(info.id, created.pane_id)
            self.assertEqual(info.state, "running")

            # Rename session, window, pane
            snap = client.rename_session(created.session_id, "alpha-renamed")
            self.assertEqual(snap.sessions[0].name, "alpha-renamed")

            snap = client.rename_window(created.window_id, "main-win")
            self.assertEqual(snap.sessions[0].windows[0].name, "main-win")

            snap = client.rename_pane(created.pane_id, "main-pane")
            self.assertEqual(snap.sessions[0].windows[0].panes[0].title, "main-pane")

            # New window + select window
            win2 = client.new_window(created.session_id, title="second", command="/bin/sh")
            self.assertNotEqual(win2.window_id, created.window_id)
            snap = client.select_window(win2.window_id)
            self.assertEqual(snap.sessions[0].active_window_id, win2.window_id)

            # Split pane + select pane + layout verification
            split = client.split_pane(win2.pane_id, axis="horizontal", command="/bin/sh")
            self.assertNotEqual(split.pane_id, win2.pane_id)
            snap = client.select_pane(split.pane_id)
            target_win = [w for w in snap.sessions[0].windows if w.id == win2.window_id][0]
            self.assertEqual(target_win.active_pane_id, split.pane_id)
            self.assertEqual(target_win.layout.kind, "split")

            # Resize, send, sendKey, capture
            self.assertTrue(client.resize_session(created.pane_id, 30, 100))
            self.assertTrue(client.send(created.pane_id, "echo PY_CAPTURE_TOKEN", enter=True))
            self.assertTrue(client.send_key(created.pane_id, "Enter"))

            deadline = time.monotonic() + 5.0
            captured_text = ""
            while time.monotonic() < deadline:
                cap = client.capture_session(created.pane_id, lines=50)
                captured_text = cap.text
                if "PY_CAPTURE_TOKEN" in captured_text:
                    self.assertIn(b"PY_CAPTURE_TOKEN", cap.raw_bytes)
                    break
                time.sleep(0.03)
            self.assertIn("PY_CAPTURE_TOKEN", captured_text)

            # Key bindings + dispatch + command.exec
            bindings = client.bind_key("z", "split-window -v", table="prefix", repeat=False)
            self.assertTrue(any(b.key == "z" for b in bindings))
            listed_keys = client.list_keys()
            self.assertTrue(any(b.key == "z" for b in listed_keys))

            unhandled = client.dispatch_key(created.pane_id, "no-such-key")
            self.assertFalse(unhandled.handled)
            handled = client.dispatch_key(created.pane_id, "z")
            self.assertTrue(handled.handled)
            self.assertIsNotNone(handled.snapshot)

            snap_cmd = client.exec_command(created.pane_id, "new-window")
            self.assertGreaterEqual(len(snap_cmd.sessions[0].windows), 3)

            # events.subscribe
            sub = client.subscribe_events(["*"])
            self.assertTrue(sub.ok)
            self.assertTrue(sub.all)

            # Respawn running pane without kill -> conflict error; with kill=True -> succeeds
            with self.assertRaises(ZmuxRpcError) as conflict_ctx:
                client.respawn_pane(created.pane_id, kill=False)
            self.assertTrue(conflict_ctx.exception.is_conflict)
            snap_respawn = client.respawn_pane(created.pane_id, kill=True)
            self.assertGreaterEqual(len(snap_respawn.sessions), 1)

            # Error mapping for unknown pane and unknown method
            with self.assertRaises(ZmuxRpcError) as nf_ctx:
                client.info_session("does-not-exist")
            self.assertTrue(nf_ctx.exception.is_not_found)

            with self.assertRaises(ZmuxRpcError) as mnf_ctx:
                client.call("nonexistent.method", {})
            self.assertTrue(mnf_ctx.exception.is_method_not_found)

            # Clean terminate
            self.assertTrue(client.terminate_session(created.session_id))
            self.assertEqual(len(client.list_sessions()), 0)

    def test_attached_pane_streaming_wait_for_reconnect_and_remote_switch(self) -> None:
        self.start_daemon()
        with ZmuxClient.connect(self.socket_path, timeout=5.0) as client:
            created = client.create_session("stream-test", command="/bin/sh", rows=24, cols=80)
            assert created.pane_id is not None

            with client.attach(created.pane_id, rows=24, cols=80) as pane:
                clients = client.list_clients()
                self.assertEqual(len(clients), 1)
                self.assertEqual(clients[0].id, pane.client_id)

                # Send two markers in one command and verify consecutive wait_for works without losing data.
                pane.send("printf 'MARKER_ONE\\nMARKER_TWO\\n'", enter=True)
                res1 = pane.wait_for(pattern="MARKER_ONE", timeout=5.0)
                self.assertTrue(res1.matched)
                self.assertEqual(res1.reason, "pattern")
                self.assertEqual(res1.match, "MARKER_ONE")

                res2 = pane.wait_for(pattern=re.compile(r"MARKER_T[A-Z]+"), timeout=5.0)
                self.assertTrue(res2.matched)
                self.assertEqual(res2.match, "MARKER_TWO")

                # Wait for idle
                idle_res = pane.wait_for(idle_ms=120, timeout=5.0)
                self.assertTrue(idle_res.matched)
                self.assertEqual(idle_res.reason, "idle")

                # Reconnect should not duplicate already-seen bytes!
                prev_offset = pane.cursor_offset
                reattach = pane.reconnect(rows=30, cols=100)
                self.assertEqual(reattach.rows, 30)
                self.assertEqual(reattach.cols, 100)
                self.assertGreaterEqual(pane.cursor_offset, prev_offset)

                pane.send("echo AFTER_RECONNECT", enter=True)
                res3 = pane.wait_for(pattern="AFTER_RECONNECT", timeout=5.0)
                self.assertTrue(res3.matched)
                self.assertNotIn("MARKER_ONE", res3.text or "")

                # Remote switch from a second connection emits client_switched to pane owner!
                pane2 = client.create_session("switch-target", command="/bin/sh")
                assert pane2.pane_id is not None
                switched_events: list[ClientSwitchedEvent] = []
                unsub = client.on_notification(
                    lambda ev: switched_events.append(ev) if isinstance(ev, ClientSwitchedEvent) else None
                )
                try:
                    with ZmuxClient.connect(self.socket_path, timeout=5.0) as controller:
                        controller.switch_client(pane.client_id, pane2.pane_id)

                    # Pump incoming notifications so the owner processes `client_switched`.
                    sw_deadline = time.monotonic() + 5.0
                    while not switched_events and time.monotonic() < sw_deadline:
                        client.next_notification(timeout=max(0.05, sw_deadline - time.monotonic()))
                    self.assertGreaterEqual(len(switched_events), 1)
                    self.assertEqual(pane.pane_id, pane2.pane_id)

                    pane.send("echo SWITCHED_TARGET_OK", enter=True)
                    sw_wait = pane.wait_for(pattern="SWITCHED_TARGET_OK", timeout=5.0)
                    self.assertTrue(sw_wait.matched)
                finally:
                    unsub()

            # Short-lived exiting pane: wait_for(exit=True) returns exit_code
            exiter = client.create_session("short", command="/bin/sh -c 'echo BYE_SYNC; exit 7'")
            assert exiter.pane_id is not None
            with client.attach(exiter.pane_id) as exit_pane:
                exit_res = exit_pane.wait_for(exit=True, timeout=5.0)
                self.assertTrue(exit_res.matched)
                self.assertEqual(exit_res.reason, "exit")
                self.assertEqual(exit_res.exit_code, 7)
                self.assertIn("BYE_SYNC", exit_res.text or "")
                self.assertIsNone(exit_pane.read_output(timeout=0.5))


class AsyncLiveDaemonTests(LiveDaemonBase):
    def test_async_client_auto_spawn_streaming_and_wait_for(self) -> None:
        async def scenario() -> None:
            async with await AsyncZmuxClient.connect(
                self.socket_path,
                timeout=5.0,
                spawn_daemon=True,
                daemon_bin=self.zmuxd_bin,
                idle_seconds=60,
            ) as client:
                pong = await client.ping()
                self.assertEqual(pong.version, "0.5.0")
                self.assertEqual(pong.socket_path, self.socket_path)

                created = await client.create_session("async-work", command="/bin/sh", rows=24, cols=80)
                assert created.pane_id is not None

                seen_events: list[object] = []
                unsub = client.on_notification(lambda ev: seen_events.append(ev))
                try:
                    async with await client.attach(created.pane_id, rows=24, cols=80) as pane:
                        # Concurrent RPC call while attached and streaming!
                        await asyncio.gather(
                            pane.send("echo ASYNC_FIRST && echo ASYNC_SECOND", enter=True),
                            client.ping(),
                            pane.resize(28, 96),
                        )

                        res1 = await pane.wait_for(pattern="ASYNC_FIRST", timeout=5.0)
                        self.assertTrue(res1.matched)
                        self.assertEqual(res1.match, "ASYNC_FIRST")

                        res2 = await pane.wait_for(pattern="ASYNC_SECOND", timeout=5.0)
                        self.assertTrue(res2.matched)

                        # Reconnect deduplication on async pane
                        await pane.reconnect(rows=25, cols=90)
                        await pane.send("echo ASYNC_RECONNECTED", enter=True)
                        res3 = await pane.wait_for(pattern="ASYNC_RECONNECTED", timeout=5.0)
                        self.assertTrue(res3.matched)
                        self.assertNotIn("ASYNC_FIRST", res3.text or "")

                        # Verify wait_for timeout raises ZmuxTimeoutError
                        with self.assertRaises(ZmuxTimeoutError):
                            await pane.wait_for(pattern="NEVER_APPEARS_XYZ", timeout=0.15)
                finally:
                    unsub()

                self.assertTrue(any(isinstance(ev, PaneOutputEvent) for ev in seen_events))

                # Async iterator over output() on an exiting pane
                exiter = await client.create_session("async-exit", command="/bin/sh -c 'echo STREAM_DONE; exit 3'")
                assert exiter.pane_id is not None
                collected = bytearray()
                async with await client.attach(exiter.pane_id) as exit_pane:
                    async for chunk in exit_pane.output(timeout=5.0):
                        collected.extend(chunk)
                    self.assertTrue(exit_pane.exited)
                    self.assertEqual(exit_pane.exit_code, 3)
                self.assertIn(b"STREAM_DONE", bytes(collected))

                # Async RPC error handling
                with self.assertRaises(ZmuxRpcError) as err_ctx:
                    await client.info_session("missing-pane")
                self.assertTrue(err_ctx.exception.is_not_found)

                # Notification async generator receives session_exited
                exited_seen: list[SessionExitedEvent] = []

                async def watch_exit() -> None:
                    async for ev in client.notifications():
                        if isinstance(ev, SessionExitedEvent):
                            exited_seen.append(ev)
                            return

                watcher = asyncio.create_task(watch_exit())
                await asyncio.sleep(0.05)
                await client.create_session("notify-exit", command="/bin/sh -c 'exit 0'")
                await asyncio.wait_for(watcher, timeout=5.0)
                self.assertEqual(len(exited_seen), 1)

                await client.shutdown()

        asyncio.run(scenario())


class ForwardCompatMockRpcTests(unittest.TestCase):
    """Tests forward-compatible v0.5/v0.6 helpers over a real AF_UNIX mock server."""

    def setUp(self) -> None:
        self.tmp_dir = tempfile.mkdtemp(prefix="zmux-mock-", dir="/tmp")
        self.sock_path = os.path.join(self.tmp_dir, "mock.sock")
        self.server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server_sock.bind(self.sock_path)
        self.server_sock.listen(4)
        self.stop_event = threading.Event()
        self.received_calls: list[tuple[str, dict[str, object]]] = []
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.stop_event.set()
        try:
            self.server_sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2.0)
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def _serve(self) -> None:
        self.server_sock.settimeout(0.1)
        while not self.stop_event.is_set():
            try:
                conn, _ = self.server_sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                buf = b""
                while not self.stop_event.is_set():
                    data = conn.recv(65536)
                    if not data:
                        break
                    buf += data
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        if not line.strip():
                            continue
                        req = json.loads(line.decode("utf-8"))
                        method = req["method"]
                        params = req.get("params") or {}
                        self.received_calls.append((method, params))
                        result = self._handle(method, params)
                        reply = json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}) + "\n"
                        conn.sendall(reply.encode("utf-8"))

    @staticmethod
    def _handle(method: str, params: dict[str, object]) -> dict[str, object]:
        if method == "session.screen":
            return {
                "rows": 24,
                "cols": 80,
                "cursor": {"row": 1, "col": 4, "visible": True},
                "altScreen": False,
                "title": "test",
                "cwd": "/tmp",
                "promptState": "prompt",
                "lastCommandExitCode": 0,
                "commandSeq": 2,
                "agentStatus": "idle",
                "modes": {"autowrap": True},
                "text": "hello",
                "lines": ["hello"],
            }
        if method == "pane.wait":
            return {"matched": True, "reason": "pattern", "paneId": params["paneId"], "match": "READY", "elapsedMs": 5}
        if method == "pane.exec":
            return {"paneId": params["paneId"], "exitCode": 0, "output": "ok\n", "timedOut": False}
        if method in ("pane.signal", "pane.close", "window.close", "pane.metadata"):
            return {"ok": True, "method": method}
        return {"ok": True}

    def test_v05_v06_helpers_sync_and_async(self) -> None:
        with ZmuxClient.connect(self.sock_path, timeout=3.0) as client:
            scr = client.screen("pane-1", include_scrollback=True, lines=50)
            self.assertEqual(scr.text, "hello")
            self.assertEqual(scr.cursor.col, 4)

            wt = client.wait_pane("pane-1", pattern="READY", timeout_ms=2000)
            self.assertTrue(wt.matched)
            self.assertEqual(wt.match, "READY")

            ex = client.exec_pane("pane-1", "echo ok", timeout_ms=2000)
            self.assertEqual(ex.exit_code, 0)
            self.assertEqual(ex.output, "ok\n")

            self.assertTrue(client.signal_pane("pane-1", "SIGINT"))
            self.assertEqual(client.close_pane("pane-1"), {"ok": True, "method": "pane.close"})
            self.assertEqual(client.close_window("win-1"), {"ok": True, "method": "window.close"})
            self.assertEqual(client.set_metadata("pane-1", {"role": "agent"}), {"ok": True, "method": "pane.metadata"})

        async def run_async() -> None:
            async with await AsyncZmuxClient.connect(self.sock_path, timeout=3.0) as client:
                scr = await client.screen("pane-1")
                self.assertEqual(scr.agent_status, "idle")
                wt = await client.wait_pane("pane-1", exit=True)
                self.assertTrue(wt.matched)
                ex = await client.exec_pane("pane-1", "pwd")
                self.assertEqual(ex.exit_code, 0)
                self.assertTrue(await client.signal_pane("pane-1", 15))
                await client.close_pane("pane-1")
                await client.close_window("win-1")
                await client.set_metadata("pane-1", {"k": "v"})

        asyncio.run(run_async())


if __name__ == "__main__":
    unittest.main()
