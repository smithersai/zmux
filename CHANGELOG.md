# Changelog

## [0.3.0] - 2026-11-22

### Changed

- **Breaking toolchain change.** zmux now requires Zig 0.17.1. The `comptime`
  guard in `build.zig` accepts any 0.17.x release at or above 0.17.1
  (`>= 0.17.1, < 0.18.0`) instead of one exact version, so 0.17.2 and later
  patch releases build without changes. 0.18 development builds are rejected.
- **Breaking library API change.** Migrated to the Zig 0.16/0.17 `std.Io`
  interface. `zmux.Server.init`, `zmux.NativeSession.create`, and
  `zmux.SessionManager.init` take a `std.Io` after the allocator, and zmux
  uses it for mutexes, condition variables, clocks, sleeps, randomness, and
  file access. Pass a thread-safe implementation such as `std.Io.Threaded`.
- `zmuxd` and `zmux-connect` use `pub fn main(init: std.process.Init)` for
  their allocator, `Io`, arguments, and environment.
- The structured logger keeps its process-global API, like `std.log`. It
  serializes lines with the same stderr lock as `std.debug.print`, so zmux
  lines no longer interleave with other stderr diagnostics in an embedding
  process. `log.initFromEnv` now takes an environment map.
- The server idle timeout uses the monotonic clock, so wall-clock changes no
  longer shorten or extend it.
- Syscalls that `std.Io` does not model (PTY fork/exec, `poll(2)`, socket
  binding, peer credentials, owner and inode checks) moved behind one internal
  libc module, `src/sys.zig`.
- The exported `zmux` module now links `libutil` on Linux and `libproc` on
  macOS, so embedders no longer link them by hand. The integration tests now
  import the public `zmux` module directly.

### Fixed

- Fixed Linux `createPrivateSocketParent` under `umask 0022` (and any non-0700
  umask): opened directories with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW` instead
  of `O_PATH` so `fchmod(2)` succeeds reliably on Linux, and verified the
  opened descriptor's uid and inode before and after `fchmod`.
- Socket writes now pass `MSG_NOSIGNAL` (plus `SO_NOSIGPIPE` on macOS) so a
  closed peer surfaces as a write error rather than terminating an embedding
  process with `SIGPIPE`.
- Eliminated heap allocations between `fork(2)` and `exec` in both PTY spawning
  and `zmux-connect --spawn-daemon`.
- Removed stale `@hasDecl(std.posix, "pipe")` / `pipe2` test guards so all
  pipe, `POLL.HUP`, and `WouldBlock` tests execute on Zig 0.17.1.
- Pinned lock/pid parent directory creation to explicit mode `0755` instead of
  Zig 0.17's `.default_dir` (`0777`).
- Fixed a timing flake in the `max_client_connections` integration test on
  Linux by waiting for `active_connections` to settle instead of sleeping a
  fixed duration.

### Preserved

- Linux `/proc` foreground inspection, JSON stderr diagnostics with
  `--log-level` and `ZMUX_LOG_LEVEL`, `SocketPathTooLong` validation,
  race-free 0600 socket binding without `umask(2)`, and `POLL.HUP` line
  draining behave as in 0.2.0.

## [0.2.0] - 2026-11-22

### Added

- Added `--detach-key` and the `ls`, `kill`, `rename`, and `shutdown` management
  commands to `zmux-connect`.
- Exported the `zmux.connect` module for embedders.
- Added Linux foreground process inspection through `/proc/<pid>/comm` and
  `/proc/<pid>/cmdline`.
- Added structured daemon diagnostics on stderr, configurable with
  `--log-level` or `ZMUX_LOG_LEVEL`. The default level is `warn`.
- Added explicit Unix socket path length validation for macOS and Linux.

### Changed

- **Breaking release asset change.** Releases now ship `.tar.gz` archives
  with `.sha256` checksums for Linux x86_64 and arm64 and macOS x86_64 and
  arm64. v0.1.0 shipped raw binaries for Linux x86_64 and macOS arm64.
- Updated CI and release workflows to use Node 24 actions.

### Fixed

- Completed audit batches A–G, fixing daemon and session lifecycle issues,
  concurrency bugs, and mux correctness issues, improving PTY robustness,
  and hardening daemon security. The audit also delivered the CLI and module
  export changes listed above.
- Made Unix socket binding race-free and eliminated global `umask` mutation
  during socket creation.

## [0.1.0] - 2026-06-18

### Added

- Initial release.

### Fixed

- PR #1 reduced keystroke latency from approximately 350 ms to 1.6 ms and
  fixed open-or-create behavior in `zmux-connect`.
