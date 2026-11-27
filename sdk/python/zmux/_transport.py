"""Shared low-level helpers for peer authentication, daemon spawning, and RPC params."""

from __future__ import annotations

import base64
import ctypes
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
from collections.abc import Mapping
from typing import Any

from .errors import ZmuxConnectionError
from .socket_path import is_default_managed

PatternLike = str | bytes | re.Pattern[str] | re.Pattern[bytes]


def verify_peer_euid(sock: socket.socket, *, expected_uid: int | None = None) -> int | None:
    """Verify the connected UNIX socket peer runs under the same effective UID.

    Uses `getpeereid(3)` on macOS/BSD and `SO_PEERCRED` on Linux.
    Returns the peer UID if checked, or None if unavailable on the platform.
    Raises `ZmuxConnectionError` on UID mismatch or credential lookup failure.
    """
    want_uid = os.geteuid() if expected_uid is None else expected_uid

    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = getattr(libc, "getpeereid", None)
        if getpeereid is None:
            return None
        getpeereid.argtypes = [
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32),
        ]
        getpeereid.restype = ctypes.c_int
        euid = ctypes.c_uint32(0)
        egid = ctypes.c_uint32(0)
        rc = getpeereid(sock.fileno(), ctypes.byref(euid), ctypes.byref(egid))
        if rc != 0:
            err = ctypes.get_errno()
            raise ZmuxConnectionError(f"getpeereid failed while authenticating zmuxd (errno {err})")
        peer_uid = int(euid.value)
        if peer_uid != want_uid:
            raise ZmuxConnectionError(
                f"refusing connection to zmuxd owned by uid {peer_uid} (expected {want_uid})"
            )
        return peer_uid

    if sys.platform.startswith("linux"):
        so_peercred = getattr(socket, "SO_PEERCRED", 17)
        try:
            raw = sock.getsockopt(socket.SOL_SOCKET, so_peercred, struct.calcsize("3i"))
        except OSError as exc:
            raise ZmuxConnectionError(f"SO_PEERCRED failed while authenticating zmuxd: {exc}") from exc
        _pid, peer_uid, _gid = struct.unpack("3i", raw)
        if peer_uid != want_uid:
            raise ZmuxConnectionError(
                f"refusing connection to zmuxd owned by uid {peer_uid} (expected {want_uid})"
            )
        return int(peer_uid)

    return None


def find_daemon_binary(daemon_bin: str | os.PathLike[str] | None = None) -> str:
    """Locate the `zmuxd` (or `smithers-session-daemon`) executable."""
    if daemon_bin is not None:
        candidate = os.fspath(daemon_bin)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
        found = shutil.which(candidate)
        if found:
            return found
        raise ZmuxConnectionError(f"configured zmuxd binary not found or not executable: {candidate!r}")

    env_bin = os.environ.get("ZMUXD_BIN")
    if env_bin:
        if os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
            return env_bin
        found = shutil.which(env_bin)
        if found:
            return found

    for name in ("zmuxd", "smithers-session-daemon"):
        found = shutil.which(name)
        if found:
            return found

    raise ZmuxConnectionError("could not find 'zmuxd' or 'smithers-session-daemon' in PATH")


def spawn_daemon_detached(
    socket_path: str,
    *,
    daemon_bin: str | os.PathLike[str] | None = None,
    idle_seconds: int | None = None,
) -> None:
    """Start a detached `zmuxd` process listening on `socket_path`."""
    binary = find_daemon_binary(daemon_bin)

    parent = os.path.dirname(socket_path)
    if parent and not os.path.exists(parent) and is_default_managed(socket_path):
        os.makedirs(parent, mode=0o700, exist_ok=True)

    argv = [binary, "--socket", socket_path]
    if idle_seconds is not None:
        argv.extend(["--idle-seconds", str(idle_seconds)])

    log_path = os.devnull
    try:
        candidate_log = f"{socket_path}.log"
        if parent and os.path.isdir(parent):
            fd = os.open(candidate_log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.close(fd)
            log_path = candidate_log
    except OSError:
        log_path = os.devnull

    # Launch via a short-lived POSIX shell in a new session so zmuxd is reparented
    # cleanly (no zombie processes and no Python Popen ResourceWarning).
    launcher = [
        "/bin/sh",
        "-c",
        'log="$1"; shift; "$@" </dev/null >/dev/null 2>>"$log" &',
        "zmuxd-launcher",
        log_path,
        *argv,
    ]
    try:
        subprocess.run(
            launcher,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ZmuxConnectionError(f"failed to spawn zmuxd ({binary}): {exc}") from exc


def build_create_params(
    *,
    name: str | None = None,
    title: str | None = None,
    command: str | None = None,
    shell: str | None = None,
    cwd: str | None = None,
    env: Mapping[str, str] | None = None,
    clear_env: bool = False,
    rows: int | None = None,
    cols: int | None = None,
    scrollback_bytes: int | None = None,
    metadata: Mapping[str, Any] | None = None,
    id_field: str | None = None,
) -> dict[str, Any]:
    """Build parameter dict for `session.create`, `window.new`, and `pane.split`."""
    params: dict[str, Any] = {}
    if id_field is not None:
        params["id"] = id_field
    if name is not None:
        params["name"] = name
    if title is not None:
        params["title"] = title
    if command is not None:
        params["command"] = command
    if shell is not None:
        params["shell"] = shell
    if cwd is not None:
        params["cwd"] = cwd
    if env is not None:
        params["env"] = dict(env)
    if clear_env:
        params["clearEnv"] = True
    if rows is not None:
        params["rows"] = rows
    if cols is not None:
        params["cols"] = cols
    if scrollback_bytes is not None:
        params["scrollbackBytes"] = scrollback_bytes
    if metadata is not None:
        params["metadata"] = dict(metadata)
    return params


def build_send_params(
    target: str,
    text: str | bytes | None = None,
    *,
    enter: bool = False,
    data: bytes | None = None,
) -> dict[str, Any]:
    """Build parameter dict for `session.send`."""
    params: dict[str, Any] = {"sessionId": target}
    if data is not None:
        params["dataBase64"] = base64.b64encode(data).decode("ascii")
        return params
    if isinstance(text, (bytes, bytearray, memoryview)):
        raw = bytes(text)
        if enter:
            raw += b"\r"
        params["dataBase64"] = base64.b64encode(raw).decode("ascii")
        return params
    params["text"] = "" if text is None else text
    if enter:
        params["enter"] = True
    return params


def build_attach_params(
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
) -> dict[str, Any]:
    """Build parameter dict for `client.attach`."""
    params: dict[str, Any] = {
        "paneId": target,
        "rows": rows,
        "cols": cols,
    }
    if create_if_missing is True:
        params["createIfMissing"] = {}
    elif isinstance(create_if_missing, dict):
        params["createIfMissing"] = dict(create_if_missing)
    if resume_from_offset is not None:
        params["resumeFromOffset"] = resume_from_offset
    if resume_generation is not None:
        params["resumeGeneration"] = resume_generation
    if read_only is not None:
        params["readOnly"] = read_only
    if resize_policy is not None:
        params["resizePolicy"] = resize_policy
    if replay_mode is not None:
        params["replayMode"] = replay_mode
    return params


def match_pattern(buffer: bytes, pattern: PatternLike) -> tuple[str, int] | None:
    """Search `buffer` for `pattern`, returning `(matched_text, end_byte_offset)` or None."""
    if isinstance(pattern, bytes):
        idx = buffer.find(pattern)
        if idx == -1:
            return None
        end = idx + len(pattern)
        return (pattern.decode("utf-8", errors="replace"), end)

    if isinstance(pattern, re.Pattern):
        if isinstance(pattern.pattern, bytes):
            m = pattern.search(buffer)
            if m is None:
                return None
            return (m.group(0).decode("utf-8", errors="replace"), m.end())
        text = buffer.decode("utf-8", errors="replace")
        m_str = pattern.search(text)
        if m_str is None:
            return None
        end_bytes = len(text[: m_str.end()].encode("utf-8"))
        return (m_str.group(0), end_bytes)

    needle = pattern.encode("utf-8")
    idx = buffer.find(needle)
    if idx != -1:
        return (pattern, idx + len(needle))
    text = buffer.decode("utf-8", errors="replace")
    char_idx = text.find(pattern)
    if char_idx == -1:
        return None
    end_bytes = len(text[: char_idx + len(pattern)].encode("utf-8"))
    return (pattern, end_bytes)
