"""Unit tests verifying socket_path.py exact parity with src/socket_path.zig."""

from __future__ import annotations

import os
import unittest

from zmux.errors import ZmuxSocketPathError
from zmux.socket_path import (
    MAX_UNIX_PATH_LEN_DARWIN,
    MAX_UNIX_PATH_LEN_LINUX,
    absolutize_socket_path,
    is_default_managed,
    max_unix_path_len,
    resolve_socket_path,
    resolve_socket_path_unvalidated,
    validate_socket_path,
)


class SocketPathTests(unittest.TestCase):
    def test_precedence_override_env_xdg_home_uid_fallback(self) -> None:
        env: dict[str, str] = {}
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=501),
            "/tmp/zmux-501/sessions.sock",
        )

        env["HOME"] = "/home/u"
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=501),
            "/home/u/.smithers/sessions.sock",
        )

        env["XDG_RUNTIME_DIR"] = "/run/user/7"
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=501),
            "/run/user/7/smithers-sessions.sock",
        )

        env["SMITHERS_SESSION_SOCKET"] = "/s/smithers.sock"
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=501),
            "/s/smithers.sock",
        )

        env["ZMUX_SOCKET"] = "/s/zmux.sock"
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=501),
            "/s/zmux.sock",
        )

        self.assertEqual(
            resolve_socket_path("/s/override.sock", env=env, euid=501),
            "/s/override.sock",
        )

    def test_skips_empty_env_values(self) -> None:
        env = {
            "ZMUX_SOCKET": "",
            "SMITHERS_SESSION_SOCKET": "",
            "XDG_RUNTIME_DIR": "",
            "HOME": "/home/u",
        }
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=1000),
            "/home/u/.smithers/sessions.sock",
        )

        env["SMITHERS_SESSION_SOCKET"] = "/s/smithers.sock"
        env["XDG_RUNTIME_DIR"] = "/run/user/7"
        self.assertEqual(
            resolve_socket_path(None, env=env, euid=1000),
            "/s/smithers.sock",
        )

    def test_trailing_slash_on_xdg_and_home_does_not_double(self) -> None:
        self.assertEqual(
            resolve_socket_path(None, env={"XDG_RUNTIME_DIR": "/run/user/7/"}, euid=7),
            "/run/user/7/smithers-sessions.sock",
        )
        self.assertEqual(
            resolve_socket_path(None, env={"HOME": "/home/u/"}, euid=7),
            "/home/u/.smithers/sessions.sock",
        )

    def test_absolutize_rules_match_zig(self) -> None:
        self.assertEqual(absolutize_socket_path("/tmp/a.sock", cwd="/work"), "/tmp/a.sock")
        self.assertEqual(absolutize_socket_path("sub/a.sock", cwd="/work"), "/work/sub/a.sock")
        self.assertEqual(absolutize_socket_path("./z.sock", cwd="/work"), "/work/z.sock")
        self.assertEqual(absolutize_socket_path(".//./a.sock", cwd="/work"), "/work/a.sock")
        self.assertEqual(absolutize_socket_path("./././c.sock", cwd="/work"), "/work/c.sock")
        # Inner ./ and .. are preserved verbatim for the kernel.
        self.assertEqual(absolutize_socket_path("a/./b.sock", cwd="/work"), "/work/a/./b.sock")
        self.assertEqual(absolutize_socket_path("../a.sock", cwd="/work"), "/work/../a.sock")
        self.assertEqual(absolutize_socket_path("z.sock", cwd="/"), "/z.sock")

        for bad in ("", ".", "./", ".///", "././.", ".//."):
            with self.assertRaises(ZmuxSocketPathError) as ctx:
                absolutize_socket_path(bad, cwd="/work")
            self.assertEqual(ctx.exception.reason, "empty")

        for bad_nul in ("a\x00b", "/abs\x00", "\x00"):
            with self.assertRaises(ZmuxSocketPathError) as ctx:
                absolutize_socket_path(bad_nul, cwd="/work")
            self.assertEqual(ctx.exception.reason, "contains_nul")

    def test_sun_path_limits_darwin_and_linux(self) -> None:
        self.assertEqual(max_unix_path_len("darwin"), MAX_UNIX_PATH_LEN_DARWIN)
        self.assertEqual(max_unix_path_len("linux"), MAX_UNIX_PATH_LEN_LINUX)
        self.assertEqual(MAX_UNIX_PATH_LEN_DARWIN, 103)
        self.assertEqual(MAX_UNIX_PATH_LEN_LINUX, 107)

        at_darwin = "/" + "s" * (MAX_UNIX_PATH_LEN_DARWIN - 1)
        over_darwin = "/" + "s" * MAX_UNIX_PATH_LEN_DARWIN
        at_linux = "/" + "s" * (MAX_UNIX_PATH_LEN_LINUX - 1)
        over_linux = "/" + "s" * MAX_UNIX_PATH_LEN_LINUX

        self.assertEqual(resolve_socket_path(at_darwin, env={}, platform="darwin"), at_darwin)
        with self.assertRaises(ZmuxSocketPathError) as ctx:
            resolve_socket_path(over_darwin, env={}, platform="darwin")
        self.assertEqual(ctx.exception.reason, "too_long")

        # Unvalidated returns it so callers can report the offending path.
        self.assertEqual(resolve_socket_path_unvalidated(over_darwin, env={}), over_darwin)

        # 104 bytes is rejected on macOS but accepted on Linux.
        self.assertEqual(resolve_socket_path(over_darwin, env={}, platform="linux"), over_darwin)
        self.assertEqual(resolve_socket_path(at_linux, env={}, platform="linux"), at_linux)
        with self.assertRaises(ZmuxSocketPathError) as ctx2:
            resolve_socket_path(over_linux, env={}, platform="linux")
        self.assertEqual(ctx2.exception.reason, "too_long")

        # Multi-byte UTF-8 counts bytes, not Unicode characters.
        multibyte = "/" + "é" * 52  # 1 + 104 = 105 UTF-8 bytes
        self.assertEqual(len(os.fsencode(multibyte)), 105)
        with self.assertRaises(ZmuxSocketPathError) as ctx3:
            validate_socket_path(multibyte, platform="darwin")
        self.assertEqual(ctx3.exception.reason, "too_long")
        validate_socket_path(multibyte, platform="linux")

    def test_validate_precedence_and_rejections(self) -> None:
        with self.assertRaises(ZmuxSocketPathError) as ctx:
            validate_socket_path("")
        self.assertEqual(ctx.exception.reason, "empty")

        with self.assertRaises(ZmuxSocketPathError) as ctx:
            validate_socket_path("rel\x00/")
        self.assertEqual(ctx.exception.reason, "contains_nul")

        for bad_dir in ("relative.sock", "./relative.sock", "/", "/tmp/dir/", "/a//"):
            with self.assertRaises(ZmuxSocketPathError) as ctx:
                validate_socket_path(bad_dir)
            self.assertEqual(ctx.exception.reason, "no_socket_directory")

        # Trailing slash beats too_long (matching src/socket_path.zig:402-406).
        long_dir = "/" + "s" * 120 + "/"
        with self.assertRaises(ZmuxSocketPathError) as ctx:
            validate_socket_path(long_dir, platform="darwin")
        self.assertEqual(ctx.exception.reason, "no_socket_directory")

    def test_is_default_managed_parity(self) -> None:
        self.assertTrue(is_default_managed("/tmp/zmux-501/sessions.sock", env={}, euid=501))
        self.assertFalse(is_default_managed("/tmp/zmux-502/sessions.sock", env={}, euid=501))
        self.assertFalse(is_default_managed("/home/u/.smithers/sessions.sock", env={}, euid=501))
        self.assertFalse(is_default_managed("/.smithers/sessions.sock", env={"HOME": ""}, euid=501))

        env = {"HOME": "/home/u/"}
        self.assertTrue(is_default_managed("/home/u/.smithers/sessions.sock", env=env, euid=501))
        self.assertTrue(is_default_managed("/home/u/.smithers//other.sock", env=env, euid=501))
        self.assertFalse(is_default_managed("/home/u/.smithers/sub/sessions.sock", env=env, euid=501))
        self.assertFalse(is_default_managed("/home/u/.smithersx/sessions.sock", env=env, euid=501))
        self.assertFalse(is_default_managed("/run/user/7/smithers-sessions.sock", env=env, euid=501))
        self.assertFalse(is_default_managed("relative.sock", env=env, euid=501))
        self.assertFalse(is_default_managed("/", env=env, euid=501))


if __name__ == "__main__":
    unittest.main()
