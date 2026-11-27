"""Synchronous AF_UNIX JSON-RPC client and high-level AttachedPane for zmux."""

from __future__ import annotations

import os
import socket
import time
from collections import deque
from collections.abc import Callable, Iterator, Mapping, Sequence
from typing import Any

from ._transport import (
    PatternLike,
    build_attach_params,
    build_create_params,
    build_send_params,
    match_pattern,
    spawn_daemon_detached,
    verify_peer_euid,
)
from .errors import (
    ZmuxConnectionError,
    ZmuxProtocolError,
    ZmuxRpcError,
    ZmuxTimeoutError,
)
from .protocol import (
    MAX_FRAME_BYTES,
    AttachResult,
    CaptureResult,
    ClientDetachedEvent,
    ClientInfo,
    ClientSwitchedEvent,
    DispatchKeyResult,
    ExecPaneResult,
    FrameDecoder,
    KeyBinding,
    MuxSnapshot,
    Notification,
    OutputReassembler,
    PaneHandle,
    PaneOutputDroppedEvent,
    PaneOutputEvent,
    PaneRespawnedEvent,
    PingResult,
    ScreenResult,
    SessionExitedEvent,
    SessionInfo,
    SubscribeResult,
    WaitResult,
    encode_request,
    parse_notification,
)
from .socket_path import resolve_socket_path

NotificationCallback = Callable[[Notification], None]


class AttachedPane:
    """High-level handle for an attached zmux pane with replay/offset reconciliation."""

    def __init__(self, client: ZmuxClient, attach_result: AttachResult) -> None:
        self._client: ZmuxClient = client
        self._attach_result: AttachResult = attach_result
        self._reassembler: OutputReassembler = OutputReassembler(attach_result)
        self._pending_chunks: deque[bytes] = deque()
        self.dropped_events: list[PaneOutputDroppedEvent] = []

        self.client_id: str = attach_result.client_id
        self.session_id: str = attach_result.session_id
        self.window_id: str = attach_result.window_id
        self.pane_id: str = attach_result.pane_id
        self.rows: int = attach_result.rows
        self.cols: int = attach_result.cols
        self.created: bool = attach_result.created
        self.exited: bool = attach_result.exited
        self.exit_code: int | None = attach_result.exit_code
        self.signal: int | None = attach_result.signal
        self.detached: bool = False
        self.detach_reason: str | None = None

        replay = self._reassembler.initial_replay(attach_result)
        if replay:
            self._pending_chunks.append(replay)

        self._client._register_attached_pane(self)

    @property
    def attach_result(self) -> AttachResult:
        return self._attach_result

    @property
    def generation(self) -> int:
        return self._reassembler.generation

    @property
    def cursor_offset(self) -> int:
        return self._reassembler.cursor_offset

    def __enter__(self) -> AttachedPane:
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if not self.detached and not self._client.is_closed:
            try:
                self.detach()
            except (ZmuxConnectionError, ZmuxRpcError, ZmuxTimeoutError):
                pass
        self._client._unregister_attached_pane(self)

    def _handle_notification(self, event: Notification) -> None:
        if isinstance(event, PaneOutputEvent):
            if event.pane_id == self.pane_id:
                chunk = self._reassembler.apply_output(event)
                if chunk:
                    self._pending_chunks.append(chunk)
        elif isinstance(event, PaneOutputDroppedEvent):
            if self._reassembler.apply_dropped(event):
                self.dropped_events.append(event)
        elif isinstance(event, SessionExitedEvent):
            if event.session_id == self.pane_id and event.generation >= self.generation:
                self.exited = True
                self.exit_code = event.exit_code
                self.signal = event.signal
        elif isinstance(event, PaneRespawnedEvent):
            if self._reassembler.apply_respawned(event):
                self.exited = False
                self.exit_code = None
                self.signal = None
        elif isinstance(event, ClientDetachedEvent):
            if event.client_id == self.client_id:
                self.detached = True
                self.detach_reason = event.reason
        elif isinstance(event, ClientSwitchedEvent):
            if event.client_id == self.client_id:
                self.pane_id = event.pane_id
                self.exited = False
                self.exit_code = None
                self.signal = None
                replay = self._reassembler.apply_switched(event)
                if replay:
                    self._pending_chunks.append(replay)

    def read_output(self, timeout: float | None = None) -> bytes | None:
        """Read the next reconciled output chunk, or None if the pane exited/detached/closed."""
        if self._pending_chunks:
            return self._pending_chunks.popleft()
        if self.exited or self.detached or self._client.is_closed:
            return None

        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            if self._pending_chunks:
                return self._pending_chunks.popleft()
            if self.exited or self.detached or self._client.is_closed:
                return None
            remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
            if remaining is not None and remaining <= 0.0:
                raise ZmuxTimeoutError(f"timed out waiting for output from pane {self.pane_id!r}")
            got_frame = self._client._pump_once(remaining)
            if not got_frame:
                if self._pending_chunks:
                    return self._pending_chunks.popleft()
                return None

    def output(self, timeout: float | None = None) -> Iterator[bytes]:
        """Yield reconciled output byte chunks until the pane exits, detaches, or closes."""
        while True:
            chunk = self.read_output(timeout=timeout)
            if chunk is None:
                return
            yield chunk

    def wait_for(
        self,
        *,
        pattern: PatternLike | None = None,
        exit: bool = False,
        idle_ms: int | None = None,
        timeout: float | None = 30.0,
    ) -> WaitResult:
        """Wait until `pattern` matches, pane exits, or output goes idle for `idle_ms`."""
        if pattern is None and not exit and idle_ms is None:
            raise ValueError("wait_for requires at least one of pattern, exit=True, or idle_ms")
        if idle_ms is not None and idle_ms < 0:
            raise ValueError("idle_ms must be non-negative")

        started = time.monotonic()
        deadline = None if timeout is None else started + timeout
        idle_sec = None if idle_ms is None else idle_ms / 1000.0
        accumulated = bytearray()
        last_activity = started

        def _elapsed_ms() -> int:
            return int((time.monotonic() - started) * 1000)

        def _drain_pending() -> bool:
            nonlocal last_activity
            drained = False
            while self._pending_chunks:
                accumulated.extend(self._pending_chunks.popleft())
                drained = True
            if drained:
                last_activity = time.monotonic()
            return drained

        while True:
            _drain_pending()

            if pattern is not None:
                hit = match_pattern(bytes(accumulated), pattern)
                if hit is not None:
                    matched_text, end_idx = hit
                    if end_idx < len(accumulated):
                        self._pending_chunks.appendleft(bytes(accumulated[end_idx:]))
                    return WaitResult(
                        matched=True,
                        reason="pattern",
                        pane_id=self.pane_id,
                        match=matched_text,
                        exit_code=self.exit_code,
                        signal=self.signal,
                        elapsed_ms=_elapsed_ms(),
                        text=bytes(accumulated[:end_idx]).decode("utf-8", errors="replace"),
                    )

            if self.exited:
                if exit:
                    return WaitResult(
                        matched=True,
                        reason="exit",
                        pane_id=self.pane_id,
                        exit_code=self.exit_code,
                        signal=self.signal,
                        elapsed_ms=_elapsed_ms(),
                        text=bytes(accumulated).decode("utf-8", errors="replace"),
                    )
                return WaitResult(
                    matched=False,
                    reason="exited",
                    pane_id=self.pane_id,
                    exit_code=self.exit_code,
                    signal=self.signal,
                    elapsed_ms=_elapsed_ms(),
                    text=bytes(accumulated).decode("utf-8", errors="replace"),
                )

            if self.detached or self._client.is_closed:
                return WaitResult(
                    matched=False,
                    reason="detached" if self.detached else "closed",
                    pane_id=self.pane_id,
                    exit_code=self.exit_code,
                    signal=self.signal,
                    elapsed_ms=_elapsed_ms(),
                    text=bytes(accumulated).decode("utf-8", errors="replace"),
                )

            now = time.monotonic()
            if idle_sec is not None and (now - last_activity) >= idle_sec:
                return WaitResult(
                    matched=True,
                    reason="idle",
                    pane_id=self.pane_id,
                    exit_code=self.exit_code,
                    signal=self.signal,
                    elapsed_ms=_elapsed_ms(),
                    text=bytes(accumulated).decode("utf-8", errors="replace"),
                )

            wait_slice: float | None = None
            if deadline is not None:
                rem = deadline - now
                if rem <= 0.0:
                    raise ZmuxTimeoutError(f"wait_for timed out on pane {self.pane_id!r}")
                wait_slice = rem
            if idle_sec is not None:
                idle_rem = max(0.0, (last_activity + idle_sec) - now)
                wait_slice = idle_rem if wait_slice is None else min(wait_slice, idle_rem)

            try:
                got_frame = self._client._pump_once(wait_slice)
                if not got_frame and not self._pending_chunks and not self.exited:
                    return WaitResult(
                        matched=False,
                        reason="closed",
                        pane_id=self.pane_id,
                        exit_code=self.exit_code,
                        signal=self.signal,
                        elapsed_ms=_elapsed_ms(),
                        text=bytes(accumulated).decode("utf-8", errors="replace"),
                    )
            except ZmuxTimeoutError:
                if idle_sec is not None and (time.monotonic() - last_activity) >= idle_sec:
                    continue
                if deadline is not None and time.monotonic() >= deadline:
                    raise

    def send(self, text: str | bytes = "", *, enter: bool = False) -> bool:
        """Send text or raw bytes to this pane."""
        return self._client.send(self.pane_id, text, enter=enter)

    def send_bytes(self, data: bytes) -> bool:
        """Send raw binary bytes to this pane via base64."""
        return self._client.send(self.pane_id, data=data)

    def send_key(self, key: str) -> bool:
        """Send a named key (for example `Enter`, `C-c`, `Up`) to this pane."""
        return self._client.send_key(self.pane_id, key)

    def resize(self, rows: int, cols: int) -> bool:
        """Resize this pane and update cached dimensions."""
        ok = self._client.resize_session(self.pane_id, rows, cols)
        if ok:
            self.rows = rows
            self.cols = cols
        return ok

    def capture(self, *, lines: int = 200) -> CaptureResult:
        """Capture recent scrollback lines from this pane."""
        return self._client.capture_session(self.pane_id, lines=lines)

    def detach(self) -> bool:
        """Detach this logical client from zmuxd."""
        if self.detached:
            return True
        ok = self._client.detach(self.client_id)
        self.detached = True
        self.detach_reason = "local_detach"
        self._client._unregister_attached_pane(self)
        return ok

    def reconnect(self, *, rows: int | None = None, cols: int | None = None) -> AttachResult:
        """Re-attach to this pane, reconnecting the socket if needed and deduplicating replay."""
        target_rows = self.rows if rows is None else rows
        target_cols = self.cols if cols is None else cols

        if self._client.is_closed:
            self._client._reconnect_socket()
        elif not self.detached:
            try:
                self._client.detach(self.client_id)
            except (ZmuxRpcError, ZmuxConnectionError, ZmuxTimeoutError):
                pass

        try:
            result = self._client.attach_raw(
                self.pane_id,
                rows=target_rows,
                cols=target_cols,
                resume_from_offset=self.cursor_offset,
                resume_generation=self.generation,
            )
        except ZmuxRpcError as exc:
            if not exc.is_invalid_params:
                raise
            result = self._client.attach_raw(
                self.pane_id,
                rows=target_rows,
                cols=target_cols,
            )

        self._attach_result = result
        self.client_id = result.client_id
        self.session_id = result.session_id
        self.window_id = result.window_id
        self.pane_id = result.pane_id
        self.rows = result.rows
        self.cols = result.cols
        self.exited = result.exited
        self.exit_code = result.exit_code
        self.signal = result.signal
        self.detached = False
        self.detach_reason = None
        self._client._register_attached_pane(self)

        delta = self._reassembler.apply_reconnect(result)
        if delta:
            self._pending_chunks.append(delta)
        return result


class ZmuxClient:
    """Synchronous JSON-RPC 2.0 client for `zmuxd` over an AF_UNIX socket."""

    def __init__(
        self,
        sock: socket.socket,
        socket_path: str,
        *,
        timeout: float = 10.0,
        max_frame_bytes: int = MAX_FRAME_BYTES,
        spawn_daemon: bool = False,
        daemon_bin: str | os.PathLike[str] | None = None,
        spawn_timeout: float = 4.0,
        idle_seconds: int | None = None,
        verify_peer_uid: bool = True,
    ) -> None:
        self._sock: socket.socket | None = sock
        self._socket_path: str = socket_path
        self._default_timeout: float = timeout
        self._max_frame_bytes: int = max_frame_bytes
        self._spawn_daemon: bool = spawn_daemon
        self._daemon_bin: str | os.PathLike[str] | None = daemon_bin
        self._spawn_timeout: float = spawn_timeout
        self._idle_seconds: int | None = idle_seconds
        self._verify_peer_uid: bool = verify_peer_uid

        self._decoder: FrameDecoder = FrameDecoder(max_frame_bytes=max_frame_bytes)
        self._next_id: int = 1
        self._buffered_responses: dict[int | str, dict[str, Any]] = {}
        self._notifications: deque[Notification] = deque(maxlen=4096)
        self._listeners: list[NotificationCallback] = []
        self._attached_panes: list[AttachedPane] = []

    @classmethod
    def connect(
        cls,
        socket_path: str | None = None,
        *,
        timeout: float = 10.0,
        spawn_daemon: bool = False,
        daemon_bin: str | os.PathLike[str] | None = None,
        spawn_timeout: float = 4.0,
        idle_seconds: int | None = None,
        verify_peer_uid: bool = True,
        max_frame_bytes: int = MAX_FRAME_BYTES,
    ) -> ZmuxClient:
        """Connect to a running `zmuxd` daemon, optionally spawning it on demand."""
        resolved = resolve_socket_path(socket_path)
        sock = cls._open_socket(
            resolved,
            timeout=timeout,
            spawn_daemon=spawn_daemon,
            daemon_bin=daemon_bin,
            spawn_timeout=spawn_timeout,
            idle_seconds=idle_seconds,
            verify_peer_uid=verify_peer_uid,
        )
        return cls(
            sock,
            resolved,
            timeout=timeout,
            max_frame_bytes=max_frame_bytes,
            spawn_daemon=spawn_daemon,
            daemon_bin=daemon_bin,
            spawn_timeout=spawn_timeout,
            idle_seconds=idle_seconds,
            verify_peer_uid=verify_peer_uid,
        )

    @staticmethod
    def _try_connect_once(path: str, timeout: float, verify_peer_uid: bool) -> socket.socket:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.settimeout(timeout)
            sock.connect(path)
            if verify_peer_uid:
                verify_peer_euid(sock)
            return sock
        except Exception:
            sock.close()
            raise

    @classmethod
    def _open_socket(
        cls,
        resolved: str,
        *,
        timeout: float,
        spawn_daemon: bool,
        daemon_bin: str | os.PathLike[str] | None,
        spawn_timeout: float,
        idle_seconds: int | None,
        verify_peer_uid: bool,
    ) -> socket.socket:
        try:
            return cls._try_connect_once(resolved, timeout, verify_peer_uid)
        except (FileNotFoundError, ConnectionRefusedError) as exc:
            if not spawn_daemon:
                raise ZmuxConnectionError(
                    f"no zmuxd daemon listening at {resolved!r}; start zmuxd or pass spawn_daemon=True"
                ) from exc
        except socket.timeout as exc:
            raise ZmuxTimeoutError(f"timed out connecting to zmuxd at {resolved!r}") from exc
        except OSError as exc:
            raise ZmuxConnectionError(f"failed to connect to zmuxd at {resolved!r}: {exc}") from exc

        spawn_daemon_detached(resolved, daemon_bin=daemon_bin, idle_seconds=idle_seconds)

        deadline = time.monotonic() + spawn_timeout
        delay = 0.02
        last_exc: Exception | None = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0.0:
                raise ZmuxTimeoutError(
                    f"spawned zmuxd at {resolved!r} did not become ready within {spawn_timeout:.2f}s"
                ) from last_exc
            try:
                return cls._try_connect_once(resolved, min(timeout, remaining), verify_peer_uid)
            except (FileNotFoundError, ConnectionRefusedError) as exc:
                last_exc = exc
                sleep_for = min(delay, max(0.0, deadline - time.monotonic()))
                if sleep_for > 0.0:
                    time.sleep(sleep_for)
                delay = min(delay * 1.5, 0.1)
            except socket.timeout as exc:
                last_exc = exc
            except OSError as exc:
                raise ZmuxConnectionError(f"failed to connect to zmuxd at {resolved!r}: {exc}") from exc

    def _reconnect_socket(self) -> None:
        self.close()
        self._sock = self._open_socket(
            self._socket_path,
            timeout=self._default_timeout,
            spawn_daemon=self._spawn_daemon,
            daemon_bin=self._daemon_bin,
            spawn_timeout=self._spawn_timeout,
            idle_seconds=self._idle_seconds,
            verify_peer_uid=self._verify_peer_uid,
        )
        self._decoder = FrameDecoder(max_frame_bytes=self._max_frame_bytes)
        self._buffered_responses.clear()

    @property
    def socket_path(self) -> str:
        return self._socket_path

    @property
    def is_closed(self) -> bool:
        return self._sock is None

    def close(self) -> None:
        """Close the UNIX socket connection."""
        sock = self._sock
        self._sock = None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def __enter__(self) -> ZmuxClient:
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.close()

    def _register_attached_pane(self, pane: AttachedPane) -> None:
        if pane not in self._attached_panes:
            self._attached_panes.append(pane)

    def _unregister_attached_pane(self, pane: AttachedPane) -> None:
        if pane in self._attached_panes:
            self._attached_panes.remove(pane)

    def on_notification(self, callback: NotificationCallback) -> Callable[[], None]:
        """Register a listener invoked for every incoming server notification."""
        self._listeners.append(callback)

        def _unsubscribe() -> None:
            if callback in self._listeners:
                self._listeners.remove(callback)

        return _unsubscribe

    def drain_notifications(self) -> list[Notification]:
        """Return and clear all currently queued server notifications."""
        items = list(self._notifications)
        self._notifications.clear()
        return items

    def next_notification(self, timeout: float | None = None) -> Notification | None:
        """Return the next server notification, waiting up to `timeout` seconds."""
        if self._notifications:
            return self._notifications.popleft()
        deadline = None if timeout is None else time.monotonic() + timeout
        while not self._notifications:
            if self._sock is None:
                return None
            remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
            if remaining is not None and remaining <= 0.0:
                raise ZmuxTimeoutError("timed out waiting for notification from zmuxd")
            if not self._pump_once(remaining):
                return None
        return self._notifications.popleft()

    def _require_socket(self) -> socket.socket:
        if self._sock is None:
            raise ZmuxConnectionError("zmux client connection is closed")
        return self._sock

    def _dispatch_frame(self, frame: dict[str, Any]) -> None:
        if "method" in frame and "id" not in frame:
            event = parse_notification(str(frame["method"]), frame.get("params"))
            self._notifications.append(event)
            for pane in list(self._attached_panes):
                pane._handle_notification(event)
            for listener in list(self._listeners):
                listener(event)
            return

        if "id" in frame:
            req_id = frame["id"]
            if req_id is None and "error" in frame and isinstance(frame["error"], dict):
                raise ZmuxRpcError.from_rpc_error(frame["error"])
            if isinstance(req_id, (int, str)) and not isinstance(req_id, bool):
                self._buffered_responses[req_id] = frame
                return

        raise ZmuxProtocolError(f"unexpected JSON-RPC frame: {frame!r}")

    def _pump_once(self, timeout: float | None) -> bool:
        """Read one chunk from the socket and dispatch all complete frames.

        Returns False on clean EOF, True when one or more frames (or partial bytes)
        were read. Raises `ZmuxTimeoutError` on timeout.
        """
        sock = self._require_socket()
        sock.settimeout(timeout)
        try:
            chunk = sock.recv(65536)
        except socket.timeout as exc:
            raise ZmuxTimeoutError("timed out reading from zmuxd socket") from exc
        except OSError as exc:
            self.close()
            raise ZmuxConnectionError(f"socket read failed: {exc}") from exc

        if not chunk:
            self.close()
            self._decoder.check_eof()
            return False

        for frame in self._decoder.feed(chunk):
            self._dispatch_frame(frame)
        return True

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        """Send a JSON-RPC notification (no id, no reply expected)."""
        sock = self._require_socket()
        payload = encode_request(method, params, is_notification=True)
        try:
            sock.settimeout(self._default_timeout)
            sock.sendall(payload)
        except socket.timeout as exc:
            raise ZmuxTimeoutError(f"timed out sending notification {method!r}") from exc
        except OSError as exc:
            self.close()
            raise ZmuxConnectionError(f"socket write failed during {method!r}: {exc}") from exc

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        """Send a JSON-RPC request and return its decoded `result` payload."""
        sock = self._require_socket()
        request_id = self._next_id
        self._next_id += 1

        effective_timeout = self._default_timeout if timeout is None else timeout
        deadline = None if effective_timeout is None else time.monotonic() + effective_timeout
        payload = encode_request(method, params, request_id)

        try:
            sock.settimeout(effective_timeout)
            sock.sendall(payload)
        except socket.timeout as exc:
            raise ZmuxTimeoutError(f"timed out sending RPC {method!r}") from exc
        except OSError as exc:
            self.close()
            raise ZmuxConnectionError(f"socket write failed during {method!r}: {exc}") from exc

        while request_id not in self._buffered_responses:
            remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
            if remaining is not None and remaining <= 0.0:
                raise ZmuxTimeoutError(f"timed out waiting for RPC {method!r} reply")
            if not self._pump_once(remaining):
                raise ZmuxConnectionError(f"zmuxd closed connection while awaiting {method!r}")

        response = self._buffered_responses.pop(request_id)
        if "error" in response and isinstance(response["error"], dict):
            raise ZmuxRpcError.from_rpc_error(response["error"])
        if "result" not in response:
            raise ZmuxProtocolError(f"JSON-RPC reply for {method!r} missing 'result' and 'error'")
        return response["result"]

    # -----------------------------------------------------------------------
    # v0.4.0 D1-D6 RPC methods

    def ping(self) -> PingResult:
        """Call `daemon.ping`."""
        return PingResult.from_dict(self.call("daemon.ping", {}))

    def shutdown(self) -> bool:
        """Call `daemon.shutdown`."""
        res = self.call("daemon.shutdown", {})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def snapshot(self) -> MuxSnapshot:
        """Call `mux.snapshot`."""
        return MuxSnapshot.from_dict(self.call("mux.snapshot", {}))

    def create_session(
        self,
        name: str | None = None,
        *,
        title: str | None = None,
        command: str | None = None,
        shell: str | None = None,
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
        clear_env: bool = False,
        rows: int = 24,
        cols: int = 80,
        scrollback_bytes: int | None = None,
        metadata: Mapping[str, Any] | None = None,
    ) -> SessionInfo:
        """Call `session.create`."""
        params = build_create_params(
            name=name,
            title=title,
            command=command,
            shell=shell,
            cwd=cwd,
            env=env,
            clear_env=clear_env,
            rows=rows,
            cols=cols,
            scrollback_bytes=scrollback_bytes,
            metadata=metadata,
        )
        return SessionInfo.from_dict(self.call("session.create", params))

    def terminate_session(self, session_id: str) -> bool:
        """Call `session.terminate`."""
        res = self.call("session.terminate", {"sessionId": session_id})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def list_sessions(self) -> list[SessionInfo]:
        """Call `session.list`."""
        items = self.call("session.list", {})
        return [SessionInfo.from_dict(item) for item in items if isinstance(item, dict)]

    def info_session(self, session_id: str) -> SessionInfo:
        """Call `session.info`."""
        return SessionInfo.from_dict(self.call("session.info", {"sessionId": session_id}))

    def resize_session(self, session_id: str, rows: int, cols: int) -> bool:
        """Call `session.resize`."""
        res = self.call("session.resize", {"sessionId": session_id, "rows": rows, "cols": cols})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def capture_session(self, session_id: str, *, lines: int = 200) -> CaptureResult:
        """Call `session.capture`."""
        return CaptureResult.from_dict(self.call("session.capture", {"sessionId": session_id, "lines": lines}))

    def send(
        self,
        session_id: str,
        text: str | bytes | None = None,
        *,
        enter: bool = False,
        data: bytes | None = None,
    ) -> bool:
        """Call `session.send` with text or raw bytes."""
        params = build_send_params(session_id, text, enter=enter, data=data)
        res = self.call("session.send", params)
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def send_key(self, session_id: str, key: str) -> bool:
        """Call `session.sendKey`."""
        res = self.call("session.sendKey", {"sessionId": session_id, "key": key})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def rename_session(self, session_id: str, name: str) -> MuxSnapshot:
        """Call `session.rename`."""
        return MuxSnapshot.from_dict(self.call("session.rename", {"sessionId": session_id, "name": name}))

    def new_window(
        self,
        session_id: str,
        *,
        title: str | None = None,
        command: str | None = None,
        shell: str | None = None,
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
        clear_env: bool = False,
        rows: int = 24,
        cols: int = 80,
        scrollback_bytes: int | None = None,
    ) -> PaneHandle:
        """Call `window.new`."""
        params = build_create_params(
            title=title,
            command=command,
            shell=shell,
            cwd=cwd,
            env=env,
            clear_env=clear_env,
            rows=rows,
            cols=cols,
            scrollback_bytes=scrollback_bytes,
        )
        params["sessionId"] = session_id
        return PaneHandle.from_dict(self.call("window.new", params))

    def select_window(self, window_id: str) -> MuxSnapshot:
        """Call `window.select`."""
        return MuxSnapshot.from_dict(self.call("window.select", {"windowId": window_id}))

    def rename_window(self, window_id: str, name: str) -> MuxSnapshot:
        """Call `window.rename`."""
        return MuxSnapshot.from_dict(self.call("window.rename", {"windowId": window_id, "name": name}))

    def split_pane(
        self,
        pane_id: str,
        *,
        axis: str = "vertical",
        title: str | None = None,
        command: str | None = None,
        shell: str | None = None,
        cwd: str | None = None,
        env: Mapping[str, str] | None = None,
        clear_env: bool = False,
        rows: int = 24,
        cols: int = 80,
        scrollback_bytes: int | None = None,
    ) -> PaneHandle:
        """Call `pane.split`."""
        params = build_create_params(
            title=title,
            command=command,
            shell=shell,
            cwd=cwd,
            env=env,
            clear_env=clear_env,
            rows=rows,
            cols=cols,
            scrollback_bytes=scrollback_bytes,
        )
        params["paneId"] = pane_id
        params["axis"] = axis
        return PaneHandle.from_dict(self.call("pane.split", params))

    def select_pane(self, pane_id: str) -> MuxSnapshot:
        """Call `pane.select`."""
        return MuxSnapshot.from_dict(self.call("pane.select", {"paneId": pane_id}))

    def rename_pane(self, pane_id: str, title: str, *, custom: bool = True) -> MuxSnapshot:
        """Call `pane.rename`."""
        return MuxSnapshot.from_dict(
            self.call("pane.rename", {"paneId": pane_id, "title": title, "custom": custom})
        )

    def respawn_pane(self, pane_id: str, *, kill: bool = False) -> MuxSnapshot:
        """Call `pane.respawn`."""
        return MuxSnapshot.from_dict(self.call("pane.respawn", {"paneId": pane_id, "kill": kill}))

    def attach_raw(
        self,
        target: str,
        *,
        rows: int = 24,
        cols: int = 80,
        create_if_missing: bool | dict[str, Any] | None = None,
        resume_from_offset: int | None = None,
        resume_generation: int | None = None,
        read_only: bool | None = None,
        resize_policy: str | None = None,
        replay_mode: str | None = None,
    ) -> AttachResult:
        """Call `client.attach` and return the raw `AttachResult`."""
        params = build_attach_params(
            target,
            rows=rows,
            cols=cols,
            create_if_missing=create_if_missing,
            resume_from_offset=resume_from_offset,
            resume_generation=resume_generation,
            read_only=read_only,
            resize_policy=resize_policy,
            replay_mode=replay_mode,
        )
        return AttachResult.from_dict(self.call("client.attach", params))

    def attach(
        self,
        target: str,
        *,
        rows: int = 24,
        cols: int = 80,
        create_if_missing: bool | dict[str, Any] | None = None,
        resume_from_offset: int | None = None,
        resume_generation: int | None = None,
        read_only: bool | None = None,
        resize_policy: str | None = None,
        replay_mode: str | None = None,
    ) -> AttachedPane:
        """Attach to a pane and return a high-level `AttachedPane` controller."""
        result = self.attach_raw(
            target,
            rows=rows,
            cols=cols,
            create_if_missing=create_if_missing,
            resume_from_offset=resume_from_offset,
            resume_generation=resume_generation,
            read_only=read_only,
            resize_policy=resize_policy,
            replay_mode=replay_mode,
        )
        return AttachedPane(self, result)

    def detach(self, client_id: str) -> bool:
        """Call `client.detach`."""
        res = self.call("client.detach", {"clientId": client_id})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def switch_client(self, client_id: str, target: str) -> MuxSnapshot:
        """Call `client.switch`."""
        return MuxSnapshot.from_dict(
            self.call("client.switch", {"clientId": client_id, "paneId": target})
        )

    def list_clients(self) -> list[ClientInfo]:
        """Call `client.list`."""
        items = self.call("client.list", {})
        return [ClientInfo.from_dict(item) for item in items if isinstance(item, dict)]

    def subscribe_events(self, panes: Sequence[str]) -> SubscribeResult:
        """Call `events.subscribe`."""
        return SubscribeResult.from_dict(self.call("events.subscribe", {"panes": list(panes)}))

    def bind_key(
        self,
        key: str,
        command: str,
        *,
        table: str = "prefix",
        repeat: bool = False,
    ) -> list[KeyBinding]:
        """Call `key.bind`."""
        items = self.call("key.bind", {"table": table, "key": key, "command": command, "repeat": repeat})
        return [KeyBinding.from_dict(item) for item in items if isinstance(item, dict)]

    def dispatch_key(self, pane_id: str, key: str, *, table: str = "prefix") -> DispatchKeyResult:
        """Call `key.dispatch`."""
        return DispatchKeyResult.from_dict(
            self.call("key.dispatch", {"paneId": pane_id, "table": table, "key": key})
        )

    def list_keys(self) -> list[KeyBinding]:
        """Call `key.list`."""
        items = self.call("key.list", {})
        return [KeyBinding.from_dict(item) for item in items if isinstance(item, dict)]

    def exec_command(self, pane_id: str, command: str) -> MuxSnapshot:
        """Call `command.exec`."""
        return MuxSnapshot.from_dict(self.call("command.exec", {"paneId": pane_id, "command": command}))

    # -----------------------------------------------------------------------
    # Forward-compatible v0.5 / v0.6 RPC helpers

    def screen(
        self,
        target: str,
        *,
        include_scrollback: bool | None = None,
        include_cells: bool | None = None,
        lines: int | None = None,
    ) -> ScreenResult:
        """Call `session.screen` (v0.5+ VT screen snapshot)."""
        params: dict[str, Any] = {"sessionId": target}
        if include_scrollback is not None:
            params["includeScrollback"] = include_scrollback
        if include_cells is not None:
            params["includeCells"] = include_cells
        if lines is not None:
            params["lines"] = lines
        return ScreenResult.from_dict(self.call("session.screen", params))

    def wait_pane(
        self,
        target: str,
        *,
        pattern: str | None = None,
        regex: bool = False,
        exit: bool = False,
        idle_ms: int | None = None,
        prompt_state: str | None = None,
        timeout_ms: int | None = None,
    ) -> WaitResult:
        """Call `pane.wait` (v0.5+ server-side wait)."""
        params: dict[str, Any] = {"paneId": target}
        if pattern is not None:
            params["pattern"] = pattern
        if regex:
            params["regex"] = True
        if exit:
            params["exit"] = True
        if idle_ms is not None:
            params["idleMs"] = idle_ms
        if prompt_state is not None:
            params["promptState"] = prompt_state
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        rpc_timeout = None if timeout_ms is None else max(self._default_timeout, (timeout_ms / 1000.0) + 5.0)
        return WaitResult.from_dict(self.call("pane.wait", params, timeout=rpc_timeout))

    def exec_pane(
        self,
        target: str,
        command: str,
        *,
        timeout_ms: int | None = None,
    ) -> ExecPaneResult:
        """Call `pane.exec` (v0.5+ structured command execution)."""
        params: dict[str, Any] = {"paneId": target, "command": command}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        rpc_timeout = None if timeout_ms is None else max(self._default_timeout, (timeout_ms / 1000.0) + 5.0)
        return ExecPaneResult.from_dict(self.call("pane.exec", params, timeout=rpc_timeout))

    def signal_pane(self, target: str, signal: str | int) -> bool:
        """Call `pane.signal` (v0.5+ explicit POSIX signal delivery)."""
        res = self.call("pane.signal", {"paneId": target, "signal": signal})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    def close_pane(self, pane_id: str) -> MuxSnapshot | dict[str, Any]:
        """Call `pane.close` (v0.5+ single pane removal)."""
        res = self.call("pane.close", {"paneId": pane_id})
        if isinstance(res, dict) and "sessions" in res:
            return MuxSnapshot.from_dict(res)
        return res if isinstance(res, dict) else {"ok": True}

    def close_window(self, window_id: str) -> MuxSnapshot | dict[str, Any]:
        """Call `window.close` (v0.5+ window removal)."""
        res = self.call("window.close", {"windowId": window_id})
        if isinstance(res, dict) and "sessions" in res:
            return MuxSnapshot.from_dict(res)
        return res if isinstance(res, dict) else {"ok": True}

    def set_metadata(self, pane_id: str, metadata: Mapping[str, Any]) -> dict[str, Any]:
        """Call `pane.metadata` (v0.5+ pane metadata update)."""
        res = self.call("pane.metadata", {"paneId": pane_id, "metadata": dict(metadata)})
        return res if isinstance(res, dict) else {"ok": True}
