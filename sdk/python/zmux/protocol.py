"""Typed v0.4.0 D1-D6 protocol models, v0.5/v0.6 helpers, NDJSON framing, and replay deduplication."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass, field
from typing import Any, Literal, Union

from .errors import ZmuxProtocolError

PROTOCOL_VERSION: str = "0.5.0"
MAX_FRAME_BYTES: int = 16 * 1024 * 1024
MAX_REQUEST_BYTES: int = 1024 * 1024


def _decode_b64(encoded: str) -> bytes:
    if not encoded:
        return b""
    try:
        return base64.b64decode(encoded.encode("ascii"), validate=True)
    except Exception as exc:
        raise ZmuxProtocolError(f"invalid base64 payload in zmux frame: {exc}") from exc


def _as_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool) or value is None:
        return default
    return int(value)


def _as_opt_int(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    return int(value)


def _as_str(value: Any, default: str = "") -> str:
    if value is None:
        return default
    return str(value)


def _as_opt_str(value: Any) -> str | None:
    if value is None:
        return None
    return str(value)


def _as_bool(value: Any, default: bool = False) -> bool:
    if isinstance(value, bool):
        return value
    return default


# ---------------------------------------------------------------------------
# Response dataclasses


@dataclass(frozen=True)
class PingResult:
    """Result of `daemon.ping`."""

    version: str
    pid: int
    socket_path: str
    sessions: int
    panes: int
    live_panes: int = 0
    connections: int = 0
    dropped_events: int = 0
    rejected_connections: int = 0
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PingResult:
        return cls(
            version=_as_str(data.get("version")),
            pid=_as_int(data.get("pid")),
            socket_path=_as_str(data.get("socketPath")),
            sessions=_as_int(data.get("sessions")),
            panes=_as_int(data.get("panes")),
            live_panes=_as_int(data.get("livePanes")),
            connections=_as_int(data.get("connections")),
            dropped_events=_as_int(data.get("droppedEvents")),
            rejected_connections=_as_int(data.get("rejectedConnections")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class PaneHandle:
    """Compact identifier handle returned by `window.new` and `pane.split`."""

    session_id: str
    window_id: str
    pane_id: str
    generation: int = 0
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PaneHandle:
        return cls(
            session_id=_as_str(data.get("sessionId")),
            window_id=_as_str(data.get("windowId")),
            pane_id=_as_str(data.get("paneId")),
            generation=_as_int(data.get("generation")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class SessionInfo:
    """Detailed session/pane info from `session.create`, `session.info`, or `session.list`."""

    id: str
    title: str
    pid: int
    state: str
    cwd: str | None = None
    shell: str | None = None
    scrollback_bytes: int = 0
    exit_status: int | None = None
    exit_code: int | None = None
    signal: int | None = None
    generation: int = 0
    session_id: str | None = None
    session_name: str | None = None
    window_id: str | None = None
    pane_id: str | None = None
    pane_title: str | None = None
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionInfo:
        pane_id = _as_opt_str(data.get("paneId")) or _as_opt_str(data.get("id"))
        return cls(
            id=_as_str(data.get("id") or pane_id),
            title=_as_str(data.get("title")),
            pid=_as_int(data.get("pid")),
            state=_as_str(data.get("state")),
            cwd=_as_opt_str(data.get("cwd")),
            shell=_as_opt_str(data.get("shell")),
            scrollback_bytes=_as_int(data.get("scrollbackBytes")),
            exit_status=_as_opt_int(data.get("exitStatus")),
            exit_code=_as_opt_int(data.get("exitCode")),
            signal=_as_opt_int(data.get("signal")),
            generation=_as_int(data.get("generation")),
            session_id=_as_opt_str(data.get("sessionId")),
            session_name=_as_opt_str(data.get("sessionName")),
            window_id=_as_opt_str(data.get("windowId")),
            pane_id=pane_id,
            pane_title=_as_opt_str(data.get("paneTitle")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class AlertState:
    """Alert flags and timestamps for a pane in `mux.snapshot`."""

    activity: bool = False
    bell: bool = False
    exited: bool = False
    last_activity_ms: int = 0
    last_bell_ms: int = 0

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> AlertState:
        if not isinstance(data, dict):
            return cls()
        return cls(
            activity=_as_bool(data.get("activity")),
            bell=_as_bool(data.get("bell")),
            exited=_as_bool(data.get("exited")),
            last_activity_ms=_as_int(data.get("lastActivityMs")),
            last_bell_ms=_as_int(data.get("lastBellMs")),
        )


@dataclass(frozen=True)
class LayoutLeaf:
    """Leaf node in a window layout tree."""

    pane_id: str
    kind: Literal["leaf"] = "leaf"


@dataclass(frozen=True)
class LayoutSplit:
    """Split node in a window layout tree."""

    id: str
    axis: str
    first: LayoutNode
    second: LayoutNode
    kind: Literal["split"] = "split"


LayoutNode = Union[LayoutLeaf, LayoutSplit]


def parse_layout_node(data: dict[str, Any]) -> LayoutNode:
    kind = data.get("kind")
    if kind == "leaf":
        return LayoutLeaf(pane_id=_as_str(data.get("paneId")))
    if kind == "split":
        first_raw = data.get("first")
        second_raw = data.get("second")
        if not isinstance(first_raw, dict) or not isinstance(second_raw, dict):
            raise ZmuxProtocolError("split layout node missing child nodes")
        return LayoutSplit(
            id=_as_str(data.get("id")),
            axis=_as_str(data.get("axis")),
            first=parse_layout_node(first_raw),
            second=parse_layout_node(second_raw),
        )
    raise ZmuxProtocolError(f"unknown layout node kind: {kind!r}")


@dataclass(frozen=True)
class PaneSnapshot:
    """Pane representation inside `mux.snapshot`."""

    id: str
    window_id: str
    session_id: str
    index: int
    title: str
    has_custom_title: bool
    state: str
    generation: int
    pid: int
    rows: int
    cols: int
    cwd: str | None
    command: str
    alerts: AlertState
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PaneSnapshot:
        return cls(
            id=_as_str(data.get("id")),
            window_id=_as_str(data.get("windowId")),
            session_id=_as_str(data.get("sessionId")),
            index=_as_int(data.get("index")),
            title=_as_str(data.get("title")),
            has_custom_title=_as_bool(data.get("hasCustomTitle")),
            state=_as_str(data.get("state")),
            generation=_as_int(data.get("generation")),
            pid=_as_int(data.get("pid")),
            rows=_as_int(data.get("rows")),
            cols=_as_int(data.get("cols")),
            cwd=_as_opt_str(data.get("cwd")),
            command=_as_str(data.get("command")),
            alerts=AlertState.from_dict(data.get("alerts")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class WindowSnapshot:
    """Window representation inside `mux.snapshot`."""

    id: str
    session_id: str
    index: int
    name: str
    active_pane_id: str
    layout: LayoutNode
    panes: tuple[PaneSnapshot, ...]
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> WindowSnapshot:
        layout_raw = data.get("layout")
        if not isinstance(layout_raw, dict):
            raise ZmuxProtocolError("window snapshot missing layout object")
        panes_raw = data.get("panes", [])
        panes = tuple(PaneSnapshot.from_dict(p) for p in panes_raw if isinstance(p, dict))
        return cls(
            id=_as_str(data.get("id")),
            session_id=_as_str(data.get("sessionId")),
            index=_as_int(data.get("index")),
            name=_as_str(data.get("name")),
            active_pane_id=_as_str(data.get("activePaneId")),
            layout=parse_layout_node(layout_raw),
            panes=panes,
            raw=dict(data),
        )


@dataclass(frozen=True)
class SessionSnapshot:
    """Session representation inside `mux.snapshot`."""

    id: str
    name: str
    active_window_id: str
    windows: tuple[WindowSnapshot, ...]
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SessionSnapshot:
        windows_raw = data.get("windows", [])
        windows = tuple(WindowSnapshot.from_dict(w) for w in windows_raw if isinstance(w, dict))
        return cls(
            id=_as_str(data.get("id")),
            name=_as_str(data.get("name")),
            active_window_id=_as_str(data.get("activeWindowId")),
            windows=windows,
            raw=dict(data),
        )


@dataclass(frozen=True)
class ClientInfo:
    """Attached logical client metadata from `client.list` or `mux.snapshot`."""

    id: str
    session_id: str
    window_id: str
    pane_id: str
    rows: int
    cols: int
    active: bool = True
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ClientInfo:
        return cls(
            id=_as_str(data.get("id")),
            session_id=_as_str(data.get("sessionId")),
            window_id=_as_str(data.get("windowId")),
            pane_id=_as_str(data.get("paneId")),
            rows=_as_int(data.get("rows")),
            cols=_as_int(data.get("cols")),
            active=_as_bool(data.get("active"), default=True),
            raw=dict(data),
        )


@dataclass(frozen=True)
class KeyBinding:
    """Key binding entry from `key.list`, `key.bind`, or `mux.snapshot`."""

    table: str
    key: str
    command: str
    repeat: bool = False

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> KeyBinding:
        return cls(
            table=_as_str(data.get("table")),
            key=_as_str(data.get("key")),
            command=_as_str(data.get("command")),
            repeat=_as_bool(data.get("repeat")),
        )


@dataclass(frozen=True)
class MuxSnapshot:
    """Complete server state snapshot from `mux.snapshot` and state-mutating RPCs."""

    sessions: tuple[SessionSnapshot, ...]
    clients: tuple[ClientInfo, ...]
    key_bindings: tuple[KeyBinding, ...]
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MuxSnapshot:
        sessions = tuple(SessionSnapshot.from_dict(s) for s in data.get("sessions", []) if isinstance(s, dict))
        clients = tuple(ClientInfo.from_dict(c) for c in data.get("clients", []) if isinstance(c, dict))
        bindings = tuple(KeyBinding.from_dict(k) for k in data.get("keyBindings", []) if isinstance(k, dict))
        return cls(sessions=sessions, clients=clients, key_bindings=bindings, raw=dict(data))


@dataclass(frozen=True)
class AttachResult:
    """Result of `client.attach`."""

    client_id: str
    session_id: str
    window_id: str
    pane_id: str
    rows: int
    cols: int
    created: bool = False
    exited: bool = False
    exit_code: int | None = None
    signal: int | None = None
    generation: int = 0
    replay_base64: str = ""
    replay_start_offset: int = 0
    replay_end_offset: int = 0
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def replay_bytes(self) -> bytes:
        """Decoded raw scrollback replay bytes."""
        return _decode_b64(self.replay_base64)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> AttachResult:
        return cls(
            client_id=_as_str(data.get("clientId")),
            session_id=_as_str(data.get("sessionId")),
            window_id=_as_str(data.get("windowId")),
            pane_id=_as_str(data.get("paneId")),
            rows=_as_int(data.get("rows")),
            cols=_as_int(data.get("cols")),
            created=_as_bool(data.get("created")),
            exited=_as_bool(data.get("exited")),
            exit_code=_as_opt_int(data.get("exitCode")),
            signal=_as_opt_int(data.get("signal")),
            generation=_as_int(data.get("generation")),
            replay_base64=_as_str(data.get("replayBase64")),
            replay_start_offset=_as_int(data.get("replayStartOffset")),
            replay_end_offset=_as_int(data.get("replayEndOffset")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class CaptureResult:
    """Result of `session.capture`."""

    session_id: str
    text: str
    text_base64: str
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def raw_bytes(self) -> bytes:
        """Exact raw bytes captured from scrollback."""
        return _decode_b64(self.text_base64)

    @property
    def data(self) -> bytes:
        """Alias for `raw_bytes`."""
        return self.raw_bytes

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CaptureResult:
        return cls(
            session_id=_as_str(data.get("sessionId")),
            text=_as_str(data.get("text")),
            text_base64=_as_str(data.get("textBase64")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class SubscribeResult:
    """Result of `events.subscribe`."""

    ok: bool
    all: bool
    panes: tuple[str, ...]

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> SubscribeResult:
        panes_raw = data.get("panes", [])
        panes = tuple(str(p) for p in panes_raw) if isinstance(panes_raw, list) else ()
        return cls(
            ok=_as_bool(data.get("ok"), default=True),
            all=_as_bool(data.get("all")),
            panes=panes,
        )


@dataclass(frozen=True)
class DispatchKeyResult:
    """Result of `key.dispatch`: either `{handled: false}` or a `MuxSnapshot`."""

    handled: bool
    snapshot: MuxSnapshot | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> DispatchKeyResult:
        if data.get("handled") is False and "sessions" not in data:
            return cls(handled=False, snapshot=None)
        return cls(handled=True, snapshot=MuxSnapshot.from_dict(data))


# ---------------------------------------------------------------------------
# Forward-compatible v0.5 / v0.6 result dataclasses


@dataclass(frozen=True)
class CursorState:
    """Terminal cursor state returned inside `ScreenResult`."""

    row: int = 0
    col: int = 0
    visible: bool = True

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> CursorState:
        if not isinstance(data, dict):
            return cls()
        return cls(
            row=_as_int(data.get("row")),
            col=_as_int(data.get("col")),
            visible=_as_bool(data.get("visible"), default=True),
        )


@dataclass(frozen=True)
class ScreenResult:
    """Structured terminal screen snapshot from `session.screen` (v0.5+)."""

    rows: int
    cols: int
    cursor: CursorState
    alt_screen: bool = False
    title: str = ""
    cwd: str | None = None
    prompt_state: str = "unknown"
    last_command_exit_code: int | None = None
    command_seq: int = 0
    agent_status: str = "unknown"
    modes: dict[str, Any] = field(default_factory=dict)
    text: str = ""
    lines: tuple[str, ...] = ()
    cells: list[Any] | None = None
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ScreenResult:
        lines_raw = data.get("lines", [])
        lines = tuple(str(line) for line in lines_raw) if isinstance(lines_raw, list) else ()
        modes_raw = data.get("modes")
        modes = dict(modes_raw) if isinstance(modes_raw, dict) else {}
        cells_raw = data.get("cells")
        cells = list(cells_raw) if isinstance(cells_raw, list) else None
        return cls(
            rows=_as_int(data.get("rows")),
            cols=_as_int(data.get("cols")),
            cursor=CursorState.from_dict(data.get("cursor")),
            alt_screen=_as_bool(data.get("altScreen")),
            title=_as_str(data.get("title")),
            cwd=_as_opt_str(data.get("cwd")),
            prompt_state=_as_str(data.get("promptState"), default="unknown"),
            last_command_exit_code=_as_opt_int(data.get("lastCommandExitCode")),
            command_seq=_as_int(data.get("commandSeq")),
            agent_status=_as_str(data.get("agentStatus"), default="unknown"),
            modes=modes,
            text=_as_str(data.get("text")),
            lines=lines,
            cells=cells,
            raw=dict(data),
        )


@dataclass(frozen=True)
class WaitResult:
    """Result from `pane.wait` (v0.5+) or client-side `AttachedPane.wait_for`."""

    matched: bool
    reason: str
    pane_id: str | None = None
    match: str | None = None
    exit_code: int | None = None
    signal: int | None = None
    elapsed_ms: int | None = None
    text: str | None = None
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> WaitResult:
        return cls(
            matched=_as_bool(data.get("matched"), default=True),
            reason=_as_str(data.get("reason") or "matched"),
            pane_id=_as_opt_str(data.get("paneId") or data.get("pane_id")),
            match=_as_opt_str(data.get("match")),
            exit_code=_as_opt_int(data.get("exitCode") if "exitCode" in data else data.get("exit_code")),
            signal=_as_opt_int(data.get("signal")),
            elapsed_ms=_as_opt_int(data.get("elapsedMs") if "elapsedMs" in data else data.get("elapsed_ms")),
            text=_as_opt_str(data.get("text")),
            raw=dict(data),
        )


@dataclass(frozen=True)
class ExecPaneResult:
    """Result from `pane.exec` (v0.5+)."""

    pane_id: str | None
    exit_code: int | None
    output: str
    timed_out: bool = False
    raw: dict[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ExecPaneResult:
        return cls(
            pane_id=_as_opt_str(data.get("paneId") or data.get("pane_id")),
            exit_code=_as_opt_int(data.get("exitCode") if "exitCode" in data else data.get("exit_code")),
            output=_as_str(data.get("output") or data.get("text")),
            timed_out=_as_bool(data.get("timedOut") if "timedOut" in data else data.get("timed_out")),
            raw=dict(data),
        )


# ---------------------------------------------------------------------------
# Notifications (server -> client)


@dataclass(frozen=True)
class PaneOutputEvent:
    """`pane_output` notification."""

    pane_id: str
    data_base64: str
    data: bytes
    offset: int = 0
    generation: int = 0
    method: Literal["pane_output"] = "pane_output"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneOutputEvent:
        encoded = _as_str(params.get("data_base64"))
        return cls(
            pane_id=_as_str(params.get("pane_id")),
            data_base64=encoded,
            data=_decode_b64(encoded),
            offset=_as_int(params.get("offset")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class PaneOutputDroppedEvent:
    """`pane_output_dropped` notification."""

    pane_id: str
    dropped_bytes: int
    resume_offset: int
    generation: int = 0
    method: Literal["pane_output_dropped"] = "pane_output_dropped"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneOutputDroppedEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id")),
            dropped_bytes=_as_int(params.get("dropped_bytes")),
            resume_offset=_as_int(params.get("resume_offset")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class PaneActivityEvent:
    """`pane_activity` notification."""

    pane_id: str
    last_activity_ms: int
    generation: int = 0
    method: Literal["pane_activity"] = "pane_activity"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneActivityEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id")),
            last_activity_ms=_as_int(params.get("last_activity_ms")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class PaneBellEvent:
    """`pane_bell` notification."""

    pane_id: str
    last_bell_ms: int
    generation: int = 0
    method: Literal["pane_bell"] = "pane_bell"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneBellEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id")),
            last_bell_ms=_as_int(params.get("last_bell_ms")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class SessionExitedEvent:
    """`session_exited` notification (for compatibility `session_id` holds the pane ID)."""

    session_id: str
    pid: int
    exit_code: int | None = None
    signal: int | None = None
    generation: int = 0
    method: Literal["session_exited"] = "session_exited"

    @property
    def pane_id(self) -> str:
        return self.session_id

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> SessionExitedEvent:
        return cls(
            session_id=_as_str(params.get("session_id")),
            pid=_as_int(params.get("pid")),
            exit_code=_as_opt_int(params.get("exit_code")),
            signal=_as_opt_int(params.get("signal")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class ForegroundChangedEvent:
    """`foreground_changed` notification."""

    session_id: str
    pid: int
    comm: str
    argv: tuple[str, ...] = ()
    argv_truncated: bool = False
    method: Literal["foreground_changed"] = "foreground_changed"

    @property
    def pane_id(self) -> str:
        return self.session_id

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> ForegroundChangedEvent:
        argv_raw = params.get("argv", [])
        argv = tuple(str(arg) for arg in argv_raw) if isinstance(argv_raw, list) else ()
        return cls(
            session_id=_as_str(params.get("session_id")),
            pid=_as_int(params.get("pid")),
            comm=_as_str(params.get("comm")),
            argv=argv,
            argv_truncated=_as_bool(params.get("argv_truncated")),
        )


@dataclass(frozen=True)
class PaneRespawnedEvent:
    """`pane_respawned` notification."""

    pane_id: str
    generation: int
    pid: int
    method: Literal["pane_respawned"] = "pane_respawned"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneRespawnedEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id")),
            generation=_as_int(params.get("generation")),
            pid=_as_int(params.get("pid")),
        )


@dataclass(frozen=True)
class ClientDetachedEvent:
    """`client_detached` notification."""

    client_id: str
    reason: str
    method: Literal["client_detached"] = "client_detached"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> ClientDetachedEvent:
        return cls(
            client_id=_as_str(params.get("client_id") or params.get("clientId")),
            reason=_as_str(params.get("reason")),
        )


@dataclass(frozen=True)
class ClientSwitchedEvent:
    """`client_switched` notification.

    Accepts both camelCase (`replayBase64`, `replayStartOffset`, `replayEndOffset`,
    as emitted by v0.4.0 `src/server.zig`) and snake_case (`replay_base64`, etc.).
    """

    client_id: str
    pane_id: str
    generation: int = 0
    replay_base64: str = ""
    replay_start_offset: int = 0
    replay_end_offset: int = 0
    method: Literal["client_switched"] = "client_switched"

    @property
    def replay_bytes(self) -> bytes:
        return _decode_b64(self.replay_base64)

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> ClientSwitchedEvent:
        replay_b64 = _as_str(params.get("replayBase64") if "replayBase64" in params else params.get("replay_base64"))
        start = _as_int(
            params.get("replayStartOffset") if "replayStartOffset" in params else params.get("replay_start_offset")
        )
        end = _as_int(
            params.get("replayEndOffset") if "replayEndOffset" in params else params.get("replay_end_offset")
        )
        return cls(
            client_id=_as_str(params.get("client_id") or params.get("clientId")),
            pane_id=_as_str(params.get("pane_id") or params.get("paneId")),
            generation=_as_int(params.get("generation")),
            replay_base64=replay_b64,
            replay_start_offset=start,
            replay_end_offset=end,
        )


@dataclass(frozen=True)
class PaneTitleChangedEvent:
    """Forward-compatible v0.5+ `pane_title_changed` notification."""

    pane_id: str
    title: str
    generation: int = 0
    method: Literal["pane_title_changed"] = "pane_title_changed"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneTitleChangedEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id") or params.get("paneId")),
            title=_as_str(params.get("title")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class PaneCwdChangedEvent:
    """Forward-compatible v0.5+ `pane_cwd_changed` notification."""

    pane_id: str
    cwd: str
    generation: int = 0
    method: Literal["pane_cwd_changed"] = "pane_cwd_changed"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneCwdChangedEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id") or params.get("paneId")),
            cwd=_as_str(params.get("cwd")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class PanePromptChangedEvent:
    """Forward-compatible v0.5+ `pane_prompt_changed` notification."""

    pane_id: str
    prompt_state: str
    last_command_exit_code: int | None = None
    command_seq: int = 0
    generation: int = 0
    method: Literal["pane_prompt_changed"] = "pane_prompt_changed"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PanePromptChangedEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id") or params.get("paneId")),
            prompt_state=_as_str(params.get("prompt_state") or params.get("promptState")),
            last_command_exit_code=_as_opt_int(
                params.get("last_command_exit_code")
                if "last_command_exit_code" in params
                else params.get("lastCommandExitCode")
            ),
            command_seq=_as_int(params.get("command_seq") if "command_seq" in params else params.get("commandSeq")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class PaneStatusChangedEvent:
    """Forward-compatible v0.5+ `pane_status_changed` notification."""

    pane_id: str
    agent_status: str
    notification: str | None = None
    generation: int = 0
    method: Literal["pane_status_changed"] = "pane_status_changed"

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> PaneStatusChangedEvent:
        return cls(
            pane_id=_as_str(params.get("pane_id") or params.get("paneId")),
            agent_status=_as_str(params.get("agent_status") or params.get("agentStatus")),
            notification=_as_opt_str(params.get("notification")),
            generation=_as_int(params.get("generation")),
        )


@dataclass(frozen=True)
class UnknownNotification:
    """Fallback notification container for future or custom server notifications."""

    method: str
    params: dict[str, Any] = field(default_factory=dict)


Notification = Union[
    PaneOutputEvent,
    PaneOutputDroppedEvent,
    PaneActivityEvent,
    PaneBellEvent,
    SessionExitedEvent,
    ForegroundChangedEvent,
    PaneRespawnedEvent,
    ClientDetachedEvent,
    ClientSwitchedEvent,
    PaneTitleChangedEvent,
    PaneCwdChangedEvent,
    PanePromptChangedEvent,
    PaneStatusChangedEvent,
    UnknownNotification,
]

_NOTIFICATION_PARSERS: dict[str, Any] = {
    "pane_output": PaneOutputEvent.from_params,
    "pane_output_dropped": PaneOutputDroppedEvent.from_params,
    "pane_activity": PaneActivityEvent.from_params,
    "pane_bell": PaneBellEvent.from_params,
    "session_exited": SessionExitedEvent.from_params,
    "foreground_changed": ForegroundChangedEvent.from_params,
    "pane_respawned": PaneRespawnedEvent.from_params,
    "client_detached": ClientDetachedEvent.from_params,
    "client_switched": ClientSwitchedEvent.from_params,
    "pane_title_changed": PaneTitleChangedEvent.from_params,
    "pane_cwd_changed": PaneCwdChangedEvent.from_params,
    "pane_prompt_changed": PanePromptChangedEvent.from_params,
    "pane_status_changed": PaneStatusChangedEvent.from_params,
}


def parse_notification(method: str, params: Any) -> Notification:
    """Parse a JSON-RPC server notification into a typed event dataclass."""
    param_dict = params if isinstance(params, dict) else {}
    parser = _NOTIFICATION_PARSERS.get(method)
    if parser is not None:
        return parser(param_dict)
    return UnknownNotification(method=method, params=dict(param_dict))


# ---------------------------------------------------------------------------
# Bounded NDJSON framing


def encode_request(
    method: str,
    params: dict[str, Any] | None = None,
    request_id: int | str | None = None,
    *,
    is_notification: bool = False,
    max_request_bytes: int = MAX_REQUEST_BYTES,
) -> bytes:
    """Serialize a single-line JSON-RPC 2.0 request or notification frame."""
    envelope: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if not is_notification:
        envelope["id"] = request_id
    if params is not None:
        envelope["params"] = params
    encoded = (json.dumps(envelope, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    if len(encoded) > max_request_bytes:
        raise ZmuxProtocolError(
            f"request frame for {method!r} exceeds maximum size ({len(encoded)} > {max_request_bytes} bytes)"
        )
    return encoded


class FrameDecoder:
    """Incremental newline-delimited JSON decoder bounded to `max_frame_bytes`."""

    def __init__(self, max_frame_bytes: int = MAX_FRAME_BYTES) -> None:
        if max_frame_bytes <= 0:
            raise ValueError("max_frame_bytes must be positive")
        self.max_frame_bytes = max_frame_bytes
        self._buf = bytearray()

    @property
    def buffered_bytes(self) -> int:
        return len(self._buf)

    def feed(self, chunk: bytes) -> list[dict[str, Any]]:
        """Feed raw socket bytes and return all decoded JSON object frames."""
        if not chunk:
            return []

        frames: list[dict[str, Any]] = []
        view = memoryview(chunk)
        pos = 0
        total = len(chunk)

        while pos < total:
            nl = chunk.find(b"\n", pos)
            if nl == -1:
                remaining = total - pos
                if len(self._buf) + remaining > self.max_frame_bytes:
                    self._buf.clear()
                    raise ZmuxProtocolError(
                        f"incoming frame exceeds maximum size ({self.max_frame_bytes} bytes)"
                    )
                self._buf.extend(view[pos:])
                break

            segment_len = nl - pos + 1
            if len(self._buf) + segment_len > self.max_frame_bytes:
                self._buf.clear()
                raise ZmuxProtocolError(
                    f"incoming frame exceeds maximum size ({self.max_frame_bytes} bytes)"
                )

            if self._buf:
                self._buf.extend(view[pos : nl + 1])
                raw_line = bytes(self._buf)
                self._buf.clear()
            else:
                raw_line = chunk[pos : nl + 1]

            pos = nl + 1
            stripped = raw_line.strip()
            if not stripped:
                continue
            frames.append(self._parse_json_line(stripped))

        return frames

    def check_eof(self) -> None:
        """Raise if EOF occurred in the middle of an unterminated frame."""
        if self._buf and self._buf.strip():
            self._buf.clear()
            raise ZmuxProtocolError("truncated JSON-RPC frame at EOF")
        self._buf.clear()

    @staticmethod
    def _parse_json_line(raw_line: bytes) -> dict[str, Any]:
        try:
            obj = json.loads(raw_line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ZmuxProtocolError(f"malformed JSON-RPC frame: {exc}") from exc
        if not isinstance(obj, dict):
            raise ZmuxProtocolError(f"expected JSON object frame, got {type(obj).__name__}")
        return obj


# ---------------------------------------------------------------------------
# Replay + live offset deduplication state machine


class OutputReassembler:
    """Reconciles `AttachResult` replay with live `pane_output` offsets and generations."""

    def __init__(self, attach_result: AttachResult) -> None:
        self.pane_id: str = attach_result.pane_id
        self.generation: int = attach_result.generation
        self.cursor_offset: int = attach_result.replay_end_offset

    def initial_replay(self, attach_result: AttachResult) -> bytes:
        """Reset state to `attach_result` and return its replay payload."""
        self.pane_id = attach_result.pane_id
        self.generation = attach_result.generation
        self.cursor_offset = attach_result.replay_end_offset
        return attach_result.replay_bytes

    def apply_reconnect(self, attach_result: AttachResult) -> bytes:
        """Apply a re-attach replay, deduplicating any bytes already seen in the same generation."""
        replay = attach_result.replay_bytes
        if attach_result.pane_id != self.pane_id or attach_result.generation != self.generation:
            self.pane_id = attach_result.pane_id
            self.generation = attach_result.generation
            self.cursor_offset = attach_result.replay_end_offset
            return replay

        if attach_result.replay_end_offset <= self.cursor_offset:
            return b""

        if attach_result.replay_start_offset <= self.cursor_offset:
            skip = self.cursor_offset - attach_result.replay_start_offset
            self.cursor_offset = attach_result.replay_end_offset
            if skip >= len(replay):
                return b""
            return replay[skip:]

        self.cursor_offset = attach_result.replay_end_offset
        return replay

    def apply_output(self, event: PaneOutputEvent) -> bytes:
        """Filter and slice a `PaneOutputEvent`, returning only unseen bytes."""
        if event.pane_id != self.pane_id:
            return b""
        if event.generation < self.generation:
            return b""

        data = event.data
        chunk_end = event.offset + len(data)
        if event.generation > self.generation:
            self.generation = event.generation
            self.cursor_offset = chunk_end
            return data

        if chunk_end <= self.cursor_offset:
            return b""

        if event.offset < self.cursor_offset:
            skip = self.cursor_offset - event.offset
            self.cursor_offset = chunk_end
            return data[skip:]

        self.cursor_offset = chunk_end
        return data

    def apply_dropped(self, event: PaneOutputDroppedEvent) -> bool:
        """Advance cursor past dropped output. Returns True if relevant to this pane."""
        if event.pane_id != self.pane_id:
            return False
        if event.generation < self.generation:
            return False
        if event.generation > self.generation:
            self.generation = event.generation
            self.cursor_offset = event.resume_offset
            return True
        if event.resume_offset > self.cursor_offset:
            self.cursor_offset = event.resume_offset
        return True

    def apply_respawned(self, event: PaneRespawnedEvent) -> bool:
        """Advance generation on respawn. Returns True if relevant to this pane."""
        if event.pane_id != self.pane_id:
            return False
        if event.generation > self.generation:
            self.generation = event.generation
            self.cursor_offset = 0
            return True
        return False

    def apply_switched(self, event: ClientSwitchedEvent) -> bytes:
        """Update target pane/generation/offset on `client_switched` and return replay bytes."""
        self.pane_id = event.pane_id
        self.generation = event.generation
        self.cursor_offset = event.replay_end_offset
        return event.replay_bytes
