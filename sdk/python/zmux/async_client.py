"""Asyncio AF_UNIX JSON-RPC client and AsyncAttachedPane for zmux."""

from __future__ import annotations

import asyncio
import os
import time
from collections import deque
from collections.abc import AsyncIterator, Callable, Mapping, Sequence
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

AsyncNotificationCallback = Callable[[Notification], Any]


class AsyncAttachedPane:
    """Asyncio controller for an attached zmux pane with replay/offset reconciliation."""

    def __init__(self, client: AsyncZmuxClient, attach_result: AttachResult) -> None:
        self._client: AsyncZmuxClient = client
        self._attach_result: AttachResult = attach_result
        self._reassembler: OutputReassembler = OutputReassembler(attach_result)
        self._pending_chunks: deque[bytes] = deque()
        self._wakeup: asyncio.Event = asyncio.Event()
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
            self._wakeup.set()
        elif self.exited:
            self._wakeup.set()

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

    async def __aenter__(self) -> AsyncAttachedPane:
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        if not self.detached and not self._client.is_closed:
            try:
                await self.detach()
            except (ZmuxConnectionError, ZmuxRpcError, ZmuxTimeoutError):
                pass
        self._client._unregister_attached_pane(self)

    def _notify_closed(self) -> None:
        self._wakeup.set()

    def _handle_notification(self, event: Notification) -> None:
        if isinstance(event, PaneOutputEvent):
            if event.pane_id == self.pane_id:
                chunk = self._reassembler.apply_output(event)
                if chunk:
                    self._pending_chunks.append(chunk)
                    self._wakeup.set()
        elif isinstance(event, PaneOutputDroppedEvent):
            if self._reassembler.apply_dropped(event):
                self.dropped_events.append(event)
                self._wakeup.set()
        elif isinstance(event, SessionExitedEvent):
            if event.session_id == self.pane_id and event.generation >= self.generation:
                self.exited = True
                self.exit_code = event.exit_code
                self.signal = event.signal
                self._wakeup.set()
        elif isinstance(event, PaneRespawnedEvent):
            if self._reassembler.apply_respawned(event):
                self.exited = False
                self.exit_code = None
                self.signal = None
                self._wakeup.set()
        elif isinstance(event, ClientDetachedEvent):
            if event.client_id == self.client_id:
                self.detached = True
                self.detach_reason = event.reason
                self._wakeup.set()
        elif isinstance(event, ClientSwitchedEvent):
            if event.client_id == self.client_id:
                self.pane_id = event.pane_id
                self.exited = False
                self.exit_code = None
                self.signal = None
                replay = self._reassembler.apply_switched(event)
                if replay:
                    self._pending_chunks.append(replay)
                self._wakeup.set()

    async def read_output(self, timeout: float | None = None) -> bytes | None:
        """Await the next reconciled output chunk, or None if the pane exited/detached/closed."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            if self._pending_chunks:
                return self._pending_chunks.popleft()
            if self.exited or self.detached or self._client.is_closed:
                return None

            self._wakeup.clear()
            if self._pending_chunks:
                return self._pending_chunks.popleft()
            if self.exited or self.detached or self._client.is_closed:
                return None

            if deadline is None:
                await self._wakeup.wait()
            else:
                remaining = deadline - time.monotonic()
                if remaining <= 0.0:
                    raise ZmuxTimeoutError(f"timed out waiting for output from pane {self.pane_id!r}")
                try:
                    await asyncio.wait_for(self._wakeup.wait(), timeout=remaining)
                except asyncio.TimeoutError as exc:
                    raise ZmuxTimeoutError(f"timed out waiting for output from pane {self.pane_id!r}") from exc

    async def output(self, timeout: float | None = None) -> AsyncIterator[bytes]:
        """Async iterate over reconciled output chunks until exit, detach, or close."""
        while True:
            chunk = await self.read_output(timeout=timeout)
            if chunk is None:
                return
            yield chunk

    async def wait_for(
        self,
        *,
        pattern: PatternLike | None = None,
        exit: bool = False,
        idle_ms: int | None = None,
        timeout: float | None = 30.0,
    ) -> WaitResult:
        """Await until `pattern` matches, pane exits, or output goes idle for `idle_ms`."""
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
                        self._wakeup.set()
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
                return WaitResult(
                    matched=bool(exit),
                    reason="exit" if exit else "exited",
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

            self._wakeup.clear()
            if self._pending_chunks or self.exited or self.detached or self._client.is_closed:
                continue

            if wait_slice is None:
                await self._wakeup.wait()
            else:
                try:
                    await asyncio.wait_for(self._wakeup.wait(), timeout=wait_slice)
                except asyncio.TimeoutError:
                    if idle_sec is not None and (time.monotonic() - last_activity) >= idle_sec:
                        continue
                    if deadline is not None and time.monotonic() >= deadline:
                        raise ZmuxTimeoutError(f"wait_for timed out on pane {self.pane_id!r}") from None

    async def send(self, text: str | bytes = "", *, enter: bool = False) -> bool:
        """Send text or raw bytes to this pane."""
        return await self._client.send(self.pane_id, text, enter=enter)

    async def send_bytes(self, data: bytes) -> bool:
        """Send raw binary bytes to this pane via base64."""
        return await self._client.send(self.pane_id, data=data)

    async def send_key(self, key: str) -> bool:
        """Send a named key to this pane."""
        return await self._client.send_key(self.pane_id, key)

    async def resize(self, rows: int, cols: int) -> bool:
        """Resize this pane."""
        ok = await self._client.resize_session(self.pane_id, rows, cols)
        if ok:
            self.rows = rows
            self.cols = cols
        return ok

    async def capture(self, *, lines: int = 200) -> CaptureResult:
        """Capture recent scrollback lines from this pane."""
        return await self._client.capture_session(self.pane_id, lines=lines)

    async def detach(self) -> bool:
        """Detach this logical client from zmuxd."""
        if self.detached:
            return True
        ok = await self._client.detach(self.client_id)
        self.detached = True
        self.detach_reason = "local_detach"
        self._client._unregister_attached_pane(self)
        self._wakeup.set()
        return ok

    async def reconnect(self, *, rows: int | None = None, cols: int | None = None) -> AttachResult:
        """Re-attach to this pane, reconnecting the client socket if closed."""
        target_rows = self.rows if rows is None else rows
        target_cols = self.cols if cols is None else cols

        if self._client.is_closed:
            await self._client._reconnect_socket()
        elif not self.detached:
            try:
                await self._client.detach(self.client_id)
            except (ZmuxRpcError, ZmuxConnectionError, ZmuxTimeoutError):
                pass

        try:
            result = await self._client.attach_raw(
                self.pane_id,
                rows=target_rows,
                cols=target_cols,
                resume_from_offset=self.cursor_offset,
                resume_generation=self.generation,
            )
        except ZmuxRpcError as exc:
            if not exc.is_invalid_params:
                raise
            result = await self._client.attach_raw(
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
            self._wakeup.set()
        return result


class AsyncZmuxClient:
    """Asyncio JSON-RPC 2.0 client for `zmuxd` over an AF_UNIX socket."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
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
        self._reader: asyncio.StreamReader | None = reader
        self._writer: asyncio.StreamWriter | None = writer
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
        self._pending: dict[int | str, asyncio.Future[Any]] = {}
        self._listeners: list[AsyncNotificationCallback] = []
        self._notification_queues: list[asyncio.Queue[Notification | None]] = []
        self._attached_panes: list[AsyncAttachedPane] = []
        self._write_lock: asyncio.Lock = asyncio.Lock()
        self._closed: bool = False
        self._reader_task: asyncio.Task[None] | None = asyncio.create_task(self._read_loop())

    @classmethod
    async def connect(
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
    ) -> AsyncZmuxClient:
        """Open an asyncio UNIX-socket connection to `zmuxd`, optionally spawning it."""
        resolved = resolve_socket_path(socket_path)
        reader, writer = await cls._open_streams(
            resolved,
            timeout=timeout,
            spawn_daemon=spawn_daemon,
            daemon_bin=daemon_bin,
            spawn_timeout=spawn_timeout,
            idle_seconds=idle_seconds,
            verify_peer_uid=verify_peer_uid,
        )
        return cls(
            reader,
            writer,
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
    async def _try_open_once(
        path: str,
        timeout: float,
        verify_peer_uid: bool,
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(path),
            timeout=timeout,
        )
        try:
            if verify_peer_uid:
                raw_sock = writer.get_extra_info("socket")
                if raw_sock is not None:
                    verify_peer_euid(raw_sock)
            return reader, writer
        except Exception:
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
            raise

    @classmethod
    async def _open_streams(
        cls,
        resolved: str,
        *,
        timeout: float,
        spawn_daemon: bool,
        daemon_bin: str | os.PathLike[str] | None,
        spawn_timeout: float,
        idle_seconds: int | None,
        verify_peer_uid: bool,
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
        try:
            return await cls._try_open_once(resolved, timeout, verify_peer_uid)
        except (FileNotFoundError, ConnectionRefusedError) as exc:
            if not spawn_daemon:
                raise ZmuxConnectionError(
                    f"no zmuxd daemon listening at {resolved!r}; start zmuxd or pass spawn_daemon=True"
                ) from exc
        except asyncio.TimeoutError as exc:
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
                return await cls._try_open_once(resolved, min(timeout, remaining), verify_peer_uid)
            except (FileNotFoundError, ConnectionRefusedError) as exc:
                last_exc = exc
                sleep_for = min(delay, max(0.0, deadline - time.monotonic()))
                if sleep_for > 0.0:
                    await asyncio.sleep(sleep_for)
                delay = min(delay * 1.5, 0.1)
            except asyncio.TimeoutError as exc:
                last_exc = exc
            except OSError as exc:
                raise ZmuxConnectionError(f"failed to connect to zmuxd at {resolved!r}: {exc}") from exc

    async def _reconnect_socket(self) -> None:
        await self.close()
        reader, writer = await self._open_streams(
            self._socket_path,
            timeout=self._default_timeout,
            spawn_daemon=self._spawn_daemon,
            daemon_bin=self._daemon_bin,
            spawn_timeout=self._spawn_timeout,
            idle_seconds=self._idle_seconds,
            verify_peer_uid=self._verify_peer_uid,
        )
        self._reader = reader
        self._writer = writer
        self._decoder = FrameDecoder(max_frame_bytes=self._max_frame_bytes)
        self._closed = False
        self._reader_task = asyncio.create_task(self._read_loop())

    @property
    def socket_path(self) -> str:
        return self._socket_path

    @property
    def is_closed(self) -> bool:
        return self._closed or self._writer is None

    async def close(self) -> None:
        """Close the UNIX socket connection and stop the background reader task."""
        if self._closed and self._writer is None and self._reader_task is None:
            return
        self._closed = True

        task = self._reader_task
        self._reader_task = None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

        writer = self._writer
        self._writer = None
        self._reader = None
        if writer is not None:
            try:
                writer.close()
                await writer.wait_closed()
            except OSError:
                pass

        self._fail_pending(ZmuxConnectionError("zmux async client closed"))
        self._wake_all_consumers()

    async def __aenter__(self) -> AsyncZmuxClient:
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        await self.close()

    def _register_attached_pane(self, pane: AsyncAttachedPane) -> None:
        if pane not in self._attached_panes:
            self._attached_panes.append(pane)

    def _unregister_attached_pane(self, pane: AsyncAttachedPane) -> None:
        if pane in self._attached_panes:
            self._attached_panes.remove(pane)

    def on_notification(self, callback: AsyncNotificationCallback) -> Callable[[], None]:
        """Register a sync or async callback for incoming server notifications."""
        self._listeners.append(callback)

        def _unsubscribe() -> None:
            if callback in self._listeners:
                self._listeners.remove(callback)

        return _unsubscribe

    async def notifications(self) -> AsyncIterator[Notification]:
        """Async iterate over all server notifications arriving on this connection."""
        queue: asyncio.Queue[Notification | None] = asyncio.Queue()
        self._notification_queues.append(queue)
        try:
            while True:
                item = await queue.get()
                if item is None:
                    return
                yield item
        finally:
            if queue in self._notification_queues:
                self._notification_queues.remove(queue)

    def _fail_pending(self, exc: Exception) -> None:
        pending = list(self._pending.values())
        self._pending.clear()
        for fut in pending:
            if not fut.done():
                fut.set_exception(exc)

    def _wake_all_consumers(self) -> None:
        for pane in list(self._attached_panes):
            pane._notify_closed()
        for queue in list(self._notification_queues):
            queue.put_nowait(None)

    async def _read_loop(self) -> None:
        reader = self._reader
        if reader is None:
            return
        try:
            while True:
                chunk = await reader.read(65536)
                if not chunk:
                    self._decoder.check_eof()
                    self._closed = True
                    self._fail_pending(ZmuxConnectionError("zmuxd closed connection"))
                    self._wake_all_consumers()
                    return
                for frame in self._decoder.feed(chunk):
                    self._dispatch_frame(frame)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self._closed = True
            err = exc if isinstance(exc, (ZmuxConnectionError, ZmuxProtocolError, ZmuxRpcError)) else ZmuxConnectionError(
                f"async socket read error: {exc}"
            )
            self._fail_pending(err)
            self._wake_all_consumers()

    def _dispatch_frame(self, frame: dict[str, Any]) -> None:
        if "method" in frame and "id" not in frame:
            event = parse_notification(str(frame["method"]), frame.get("params"))
            for pane in list(self._attached_panes):
                pane._handle_notification(event)
            for queue in list(self._notification_queues):
                queue.put_nowait(event)
            for listener in list(self._listeners):
                result = listener(event)
                if asyncio.iscoroutine(result):
                    asyncio.create_task(result)
            return

        if "id" in frame:
            req_id = frame["id"]
            if req_id is None and "error" in frame and isinstance(frame["error"], dict):
                self._fail_pending(ZmuxRpcError.from_rpc_error(frame["error"]))
                return
            if isinstance(req_id, (int, str)) and not isinstance(req_id, bool):
                fut = self._pending.pop(req_id, None)
                if fut is None or fut.done():
                    return
                if "error" in frame and isinstance(frame["error"], dict):
                    fut.set_exception(ZmuxRpcError.from_rpc_error(frame["error"]))
                elif "result" in frame:
                    fut.set_result(frame["result"])
                else:
                    fut.set_exception(ZmuxProtocolError(f"JSON-RPC reply missing 'result' and 'error': {frame!r}"))
                return

        raise ZmuxProtocolError(f"unexpected JSON-RPC frame: {frame!r}")

    async def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        """Send a JSON-RPC notification (no id, no reply expected)."""
        if self.is_closed or self._writer is None:
            raise ZmuxConnectionError("zmux async client connection is closed")
        payload = encode_request(method, params, is_notification=True)
        async with self._write_lock:
            try:
                self._writer.write(payload)
                await asyncio.wait_for(self._writer.drain(), timeout=self._default_timeout)
            except asyncio.TimeoutError as exc:
                raise ZmuxTimeoutError(f"timed out sending notification {method!r}") from exc
            except OSError as exc:
                await self.close()
                raise ZmuxConnectionError(f"socket write failed during {method!r}: {exc}") from exc

    async def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> Any:
        """Send a JSON-RPC request and await its decoded `result` payload."""
        if self.is_closed or self._writer is None:
            raise ZmuxConnectionError("zmux async client connection is closed")

        request_id = self._next_id
        self._next_id += 1
        effective_timeout = self._default_timeout if timeout is None else timeout
        payload = encode_request(method, params, request_id)

        loop = asyncio.get_running_loop()
        fut: asyncio.Future[Any] = loop.create_future()
        self._pending[request_id] = fut

        try:
            async with self._write_lock:
                self._writer.write(payload)
                await asyncio.wait_for(self._writer.drain(), timeout=effective_timeout)
            return await asyncio.wait_for(fut, timeout=effective_timeout)
        except asyncio.TimeoutError as exc:
            self._pending.pop(request_id, None)
            raise ZmuxTimeoutError(f"timed out waiting for RPC {method!r} reply") from exc
        except OSError as exc:
            self._pending.pop(request_id, None)
            await self.close()
            raise ZmuxConnectionError(f"socket write failed during {method!r}: {exc}") from exc
        except BaseException:
            self._pending.pop(request_id, None)
            raise

    # -----------------------------------------------------------------------
    # v0.4.0 D1-D6 RPC methods

    async def ping(self) -> PingResult:
        return PingResult.from_dict(await self.call("daemon.ping", {}))

    async def shutdown(self) -> bool:
        res = await self.call("daemon.shutdown", {})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def snapshot(self) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("mux.snapshot", {}))

    async def create_session(
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
        return SessionInfo.from_dict(await self.call("session.create", params))

    async def terminate_session(self, session_id: str) -> bool:
        res = await self.call("session.terminate", {"sessionId": session_id})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def list_sessions(self) -> list[SessionInfo]:
        items = await self.call("session.list", {})
        return [SessionInfo.from_dict(item) for item in items if isinstance(item, dict)]

    async def info_session(self, session_id: str) -> SessionInfo:
        return SessionInfo.from_dict(await self.call("session.info", {"sessionId": session_id}))

    async def resize_session(self, session_id: str, rows: int, cols: int) -> bool:
        res = await self.call("session.resize", {"sessionId": session_id, "rows": rows, "cols": cols})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def capture_session(self, session_id: str, *, lines: int = 200) -> CaptureResult:
        return CaptureResult.from_dict(
            await self.call("session.capture", {"sessionId": session_id, "lines": lines})
        )

    async def send(
        self,
        session_id: str,
        text: str | bytes | None = None,
        *,
        enter: bool = False,
        data: bytes | None = None,
    ) -> bool:
        params = build_send_params(session_id, text, enter=enter, data=data)
        res = await self.call("session.send", params)
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def send_key(self, session_id: str, key: str) -> bool:
        res = await self.call("session.sendKey", {"sessionId": session_id, "key": key})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def rename_session(self, session_id: str, name: str) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("session.rename", {"sessionId": session_id, "name": name}))

    async def new_window(
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
        return PaneHandle.from_dict(await self.call("window.new", params))

    async def select_window(self, window_id: str) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("window.select", {"windowId": window_id}))

    async def rename_window(self, window_id: str, name: str) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("window.rename", {"windowId": window_id, "name": name}))

    async def split_pane(
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
        return PaneHandle.from_dict(await self.call("pane.split", params))

    async def select_pane(self, pane_id: str) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("pane.select", {"paneId": pane_id}))

    async def rename_pane(self, pane_id: str, title: str, *, custom: bool = True) -> MuxSnapshot:
        return MuxSnapshot.from_dict(
            await self.call("pane.rename", {"paneId": pane_id, "title": title, "custom": custom})
        )

    async def respawn_pane(self, pane_id: str, *, kill: bool = False) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("pane.respawn", {"paneId": pane_id, "kill": kill}))

    async def attach_raw(
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
        return AttachResult.from_dict(await self.call("client.attach", params))

    async def attach(
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
    ) -> AsyncAttachedPane:
        result = await self.attach_raw(
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
        return AsyncAttachedPane(self, result)

    async def detach(self, client_id: str) -> bool:
        res = await self.call("client.detach", {"clientId": client_id})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def switch_client(self, client_id: str, target: str) -> MuxSnapshot:
        return MuxSnapshot.from_dict(
            await self.call("client.switch", {"clientId": client_id, "paneId": target})
        )

    async def list_clients(self) -> list[ClientInfo]:
        items = await self.call("client.list", {})
        return [ClientInfo.from_dict(item) for item in items if isinstance(item, dict)]

    async def subscribe_events(self, panes: Sequence[str]) -> SubscribeResult:
        return SubscribeResult.from_dict(await self.call("events.subscribe", {"panes": list(panes)}))

    async def bind_key(
        self,
        key: str,
        command: str,
        *,
        table: str = "prefix",
        repeat: bool = False,
    ) -> list[KeyBinding]:
        items = await self.call("key.bind", {"table": table, "key": key, "command": command, "repeat": repeat})
        return [KeyBinding.from_dict(item) for item in items if isinstance(item, dict)]

    async def dispatch_key(self, pane_id: str, key: str, *, table: str = "prefix") -> DispatchKeyResult:
        return DispatchKeyResult.from_dict(
            await self.call("key.dispatch", {"paneId": pane_id, "table": table, "key": key})
        )

    async def list_keys(self) -> list[KeyBinding]:
        items = await self.call("key.list", {})
        return [KeyBinding.from_dict(item) for item in items if isinstance(item, dict)]

    async def exec_command(self, pane_id: str, command: str) -> MuxSnapshot:
        return MuxSnapshot.from_dict(await self.call("command.exec", {"paneId": pane_id, "command": command}))

    # -----------------------------------------------------------------------
    # Forward-compatible v0.5 / v0.6 RPC helpers

    async def screen(
        self,
        target: str,
        *,
        include_scrollback: bool | None = None,
        include_cells: bool | None = None,
        lines: int | None = None,
    ) -> ScreenResult:
        params: dict[str, Any] = {"sessionId": target}
        if include_scrollback is not None:
            params["includeScrollback"] = include_scrollback
        if include_cells is not None:
            params["includeCells"] = include_cells
        if lines is not None:
            params["lines"] = lines
        return ScreenResult.from_dict(await self.call("session.screen", params))

    async def wait_pane(
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
        return WaitResult.from_dict(await self.call("pane.wait", params, timeout=rpc_timeout))

    async def exec_pane(
        self,
        target: str,
        command: str,
        *,
        timeout_ms: int | None = None,
    ) -> ExecPaneResult:
        params: dict[str, Any] = {"paneId": target, "command": command}
        if timeout_ms is not None:
            params["timeoutMs"] = timeout_ms
        rpc_timeout = None if timeout_ms is None else max(self._default_timeout, (timeout_ms / 1000.0) + 5.0)
        return ExecPaneResult.from_dict(await self.call("pane.exec", params, timeout=rpc_timeout))

    async def signal_pane(self, target: str, signal: str | int) -> bool:
        res = await self.call("pane.signal", {"paneId": target, "signal": signal})
        return bool(res.get("ok", True)) if isinstance(res, dict) else True

    async def close_pane(self, pane_id: str) -> MuxSnapshot | dict[str, Any]:
        res = await self.call("pane.close", {"paneId": pane_id})
        if isinstance(res, dict) and "sessions" in res:
            return MuxSnapshot.from_dict(res)
        return res if isinstance(res, dict) else {"ok": True}

    async def close_window(self, window_id: str) -> MuxSnapshot | dict[str, Any]:
        res = await self.call("window.close", {"windowId": window_id})
        if isinstance(res, dict) and "sessions" in res:
            return MuxSnapshot.from_dict(res)
        return res if isinstance(res, dict) else {"ok": True}

    async def set_metadata(self, pane_id: str, metadata: Mapping[str, Any]) -> dict[str, Any]:
        res = await self.call("pane.metadata", {"paneId": pane_id, "metadata": dict(metadata)})
        return res if isinstance(res, dict) else {"ok": True}
