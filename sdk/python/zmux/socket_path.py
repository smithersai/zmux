"""Socket path resolution and validation matching src/socket_path.zig."""

from __future__ import annotations

import os
import posixpath
import sys
from collections.abc import Mapping

from .errors import ZmuxSocketPathError

MAX_UNIX_PATH_LEN_DARWIN: int = 103
MAX_UNIX_PATH_LEN_LINUX: int = 107


def max_unix_path_len(platform: str | None = None) -> int:
    """Return the maximum byte length for sockaddr_un.sun_path excluding NUL."""
    target = sys.platform if platform is None else platform
    if target == "darwin":
        return MAX_UNIX_PATH_LEN_DARWIN
    if target.startswith("linux"):
        return MAX_UNIX_PATH_LEN_LINUX
    return MAX_UNIX_PATH_LEN_DARWIN


def _non_empty(env: Mapping[str, str], name: str) -> str | None:
    value = env.get(name)
    if value is None or value == "":
        return None
    return value


def _join_posix(*parts: str) -> str:
    """Join POSIX path components without doubling slashes."""
    if not parts:
        return ""
    result = parts[0]
    for part in parts[1:]:
        if result == "/":
            result = "/" + part.lstrip("/")
        else:
            result = result.rstrip("/") + "/" + part.lstrip("/")
    return result


def _trim_trailing_slashes(path: str) -> str:
    end = len(path)
    while end > 1 and path[end - 1] == "/":
        end -= 1
    return path[:end]


def _resolve_raw(
    override: str | None,
    env: Mapping[str, str],
    euid: int,
) -> str:
    """Resolve raw path before absolutization and validation.

    Precedence:
      override > $ZMUX_SOCKET > $SMITHERS_SESSION_SOCKET >
      $XDG_RUNTIME_DIR/smithers-sessions.sock > $HOME/.smithers/sessions.sock >
      /tmp/zmux-<euid>/sessions.sock
    """
    if override is not None:
        if override == "":
            raise ZmuxSocketPathError("socket path override must not be empty", reason="empty", path=override)
        return override

    zmux_socket = _non_empty(env, "ZMUX_SOCKET")
    if zmux_socket is not None:
        return zmux_socket

    smithers_socket = _non_empty(env, "SMITHERS_SESSION_SOCKET")
    if smithers_socket is not None:
        return smithers_socket

    xdg_runtime_dir = _non_empty(env, "XDG_RUNTIME_DIR")
    if xdg_runtime_dir is not None:
        return _join_posix(xdg_runtime_dir, "smithers-sessions.sock")

    home = _non_empty(env, "HOME")
    if home is not None:
        return _join_posix(home, ".smithers", "sessions.sock")

    return f"/tmp/zmux-{euid}/sessions.sock"


def absolutize_socket_path(path: str, *, cwd: str | None = None) -> str:
    """Resolve a relative path against cwd without collapsing `..` segments.

    Mirrors `socket_path.absolutize` in `src/socket_path.zig`.
    """
    if path == "":
        raise ZmuxSocketPathError("socket path must not be empty", reason="empty", path=path)
    if "\x00" in path:
        raise ZmuxSocketPathError("socket path must not contain NUL bytes", reason="contains_nul", path=path)
    if path.startswith("/"):
        return path

    relative = path
    while relative.startswith("./"):
        relative = relative[2:]
        while relative.startswith("/"):
            relative = relative[1:]

    if relative == "" or relative == ".":
        raise ZmuxSocketPathError(
            f"socket path names only the current directory: {path!r}",
            reason="empty",
            path=path,
        )

    if cwd is None:
        try:
            resolved_cwd = os.getcwd()
        except OSError as exc:
            raise ZmuxSocketPathError(
                f"current working directory unavailable: {exc}",
                reason="cwd_unavailable",
                path=path,
            ) from exc
    else:
        resolved_cwd = cwd

    if not resolved_cwd or not resolved_cwd.startswith("/"):
        raise ZmuxSocketPathError(
            f"current working directory is not absolute: {resolved_cwd!r}",
            reason="cwd_unavailable",
            path=path,
        )

    return _join_posix(resolved_cwd, relative)


def validate_socket_path(
    path: str,
    *,
    max_len: int | None = None,
    platform: str | None = None,
) -> None:
    """Validate that `path` is non-empty, NUL-free, absolute, a file path, and fits sun_path.

    Checks errors in the exact precedence order of `src/socket_path.zig`:
      1. EmptySocketPath
      2. SocketPathContainsNul
      3. NoSocketDirectory (not absolute or trailing slash)
      4. SocketPathTooLong
    """
    if path == "":
        raise ZmuxSocketPathError("socket path must not be empty", reason="empty", path=path)
    if "\x00" in path:
        raise ZmuxSocketPathError("socket path must not contain NUL bytes", reason="contains_nul", path=path)
    if not path.startswith("/"):
        raise ZmuxSocketPathError(
            f"socket path must be absolute: {path!r}",
            reason="no_socket_directory",
            path=path,
        )
    if path.endswith("/"):
        raise ZmuxSocketPathError(
            f"socket path must name a file, not a directory: {path!r}",
            reason="no_socket_directory",
            path=path,
        )
    limit = max_unix_path_len(platform) if max_len is None else max_len
    encoded_len = len(os.fsencode(path))
    if encoded_len > limit:
        raise ZmuxSocketPathError(
            f"socket path exceeds sun_path limit ({encoded_len} > {limit} bytes): {path!r}",
            reason="too_long",
            path=path,
        )


def resolve_socket_path_unvalidated(
    override: str | None = None,
    *,
    env: Mapping[str, str] | None = None,
    cwd: str | None = None,
    euid: int | None = None,
) -> str:
    """Resolve and absolutize the socket path without enforcing sun_path length."""
    actual_env = os.environ if env is None else env
    actual_euid = os.geteuid() if euid is None else euid
    raw = _resolve_raw(override, actual_env, actual_euid)
    return absolutize_socket_path(raw, cwd=cwd)


def resolve_socket_path(
    override: str | None = None,
    *,
    env: Mapping[str, str] | None = None,
    cwd: str | None = None,
    euid: int | None = None,
    max_len: int | None = None,
    platform: str | None = None,
) -> str:
    """Resolve, absolutize, and validate the zmux daemon socket path."""
    path = resolve_socket_path_unvalidated(override, env=env, cwd=cwd, euid=euid)
    validate_socket_path(path, max_len=max_len, platform=platform)
    return path


def is_default_managed(
    path: str,
    *,
    env: Mapping[str, str] | None = None,
    euid: int | None = None,
) -> bool:
    """Return True when `path`'s parent is a daemon-managed private directory.

    Mirrors `socket_path.isDefaultManaged` in `src/socket_path.zig`:
    true only for `$HOME/.smithers` and `/tmp/zmux-<euid>`.
    """
    if not path.startswith("/"):
        return False
    dirname = posixpath.dirname(path)
    if not dirname or dirname == "/":
        return False
    parent = _trim_trailing_slashes(dirname)
    actual_env = os.environ if env is None else env
    home = _non_empty(actual_env, "HOME")
    if home is not None:
        managed = f"{_trim_trailing_slashes(home)}/.smithers"
        if parent == managed:
            return True
    actual_euid = os.geteuid() if euid is None else euid
    return parent == f"/tmp/zmux-{actual_euid}"
