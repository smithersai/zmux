"""Exception hierarchy and JSON-RPC error metadata for the zmux Python SDK."""

from __future__ import annotations

from typing import Any, Literal

ErrorKind = Literal[
    "parse",
    "invalid_request",
    "method_not_found",
    "invalid_params",
    "not_found",
    "terminated",
    "conflict",
    "limit",
    "spawn_failed",
    "io",
    "internal",
    "unknown",
]


class ErrorCode:
    """Standard JSON-RPC 2.0 and zmux domain error codes."""

    PARSE_ERROR: int = -32700
    INVALID_REQUEST: int = -32600
    METHOD_NOT_FOUND: int = -32601
    INVALID_PARAMS: int = -32602
    INTERNAL_ERROR: int = -32603
    SESSION_ERROR: int = -32000


_CODE_TO_DEFAULT_KIND: dict[int, str] = {
    ErrorCode.PARSE_ERROR: "parse",
    ErrorCode.INVALID_REQUEST: "invalid_request",
    ErrorCode.METHOD_NOT_FOUND: "method_not_found",
    ErrorCode.INVALID_PARAMS: "invalid_params",
    ErrorCode.INTERNAL_ERROR: "internal",
}


class ZmuxError(Exception):
    """Base exception for all zmux SDK failures."""


class ZmuxSocketPathError(ZmuxError, ValueError):
    """Raised when a socket path fails resolution or validation."""

    def __init__(self, message: str, *, reason: str = "invalid", path: str | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(message)


class ZmuxConnectionError(ZmuxError):
    """Raised on socket connect, disconnect, peer auth, or daemon spawn failure."""


class ZmuxTimeoutError(ZmuxError, TimeoutError):
    """Raised when a connect, RPC, read, or wait operation times out."""


class ZmuxProtocolError(ZmuxError):
    """Raised when the wire stream carries malformed JSON or exceeds frame bounds."""


class ZmuxRpcError(ZmuxError):
    """Raised when zmuxd returns a JSON-RPC 2.0 error response."""

    def __init__(
        self,
        code: int,
        kind: str,
        message: str,
        *,
        data: dict[str, Any] | None = None,
    ) -> None:
        self.code: int = int(code)
        self.kind: str = str(kind)
        self.message: str = str(message)
        self.data: dict[str, Any] | None = data
        super().__init__(f"zmux RPC error [{self.code}/{self.kind}]: {self.message}")

    @classmethod
    def from_rpc_error(cls, payload: dict[str, Any]) -> ZmuxRpcError:
        """Build a ZmuxRpcError from a JSON-RPC `error` object."""
        raw_code = payload.get("code", ErrorCode.INTERNAL_ERROR)
        code = int(raw_code) if isinstance(raw_code, int) and not isinstance(raw_code, bool) else ErrorCode.INTERNAL_ERROR
        raw_message = payload.get("message")
        message = str(raw_message) if raw_message is not None else "unknown error"
        raw_data = payload.get("data")
        data = raw_data if isinstance(raw_data, dict) else None
        kind: str
        if data is not None and isinstance(data.get("kind"), str) and data["kind"]:
            kind = data["kind"]
        else:
            kind = _CODE_TO_DEFAULT_KIND.get(code, "unknown")
        return cls(code, kind, message, data=data)

    @property
    def is_not_found(self) -> bool:
        return self.kind == "not_found"

    @property
    def is_terminated(self) -> bool:
        return self.kind == "terminated"

    @property
    def is_conflict(self) -> bool:
        return self.kind == "conflict"

    @property
    def is_method_not_found(self) -> bool:
        return self.code == ErrorCode.METHOD_NOT_FOUND or self.kind == "method_not_found"

    @property
    def is_invalid_params(self) -> bool:
        return self.code == ErrorCode.INVALID_PARAMS or self.kind == "invalid_params"
