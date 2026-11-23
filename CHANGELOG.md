# Changelog

## [Unreleased]

Round-1 code review fixes (tracks T1-T5 and their integration). Decisions
D1-D6 change the wire contract.

### Changed

- **D1.** `pane_output` goes to attached or subscribed connections. Use
  `events.subscribe` with pane IDs or `["*"]` to monitor output separately.
  Output frames include `offset` and `generation`. Slow consumers receive
  `pane_output_dropped` with `dropped_bytes` and `resume_offset`. Lifecycle
  broadcasts remain global.
- **D2.** Malformed JSON returns `-32700`. Domain failures use `-32000` and
  errors include `data.kind`. Requests with no ID receive no response.
- **D3.** Spawn methods merge `env` over the daemon environment. Set
  `clearEnv: true` to replace it. Unset `TERM` defaults to `xterm-256color`.
- **D4.** `client.attach` can create a missing session atomically with
  `createIfMissing`. The response adds `created`, `exited`, `exitCode`,
  `signal`, `generation`, and `replayEndOffset`. `zmux-connect` replays
  exited panes and displays their status before respawning. `pane.respawn`
  defaults to `kill: false` and emits `pane_respawned`.
- **D5.** Session names are unique. An exact ID takes precedence over a
  session name.
- **D6.** Relative socket options resolve against the working directory.
  Library callers must pass an absolute path.
- `session.create`, `window.new`, and `pane.split` return compact results
  with `sessionId`, `windowId`, `paneId`, and `generation`.
  `session.capture` adds `textBase64` and sanitizes invalid UTF-8 in `text`.
- Detached clients receive `client_detached` with the reason. Remote
  switches notify the owning connection with `client_switched`. The
  existing notification field `session_id` carries a pane ID.
- `foreground_changed` also reports the return to the shell, and carries
  `argv_truncated`. The shell that owns the terminal at spawn is the
  baseline and produces no event.
- `pane_activity` fires once per idle-to-active edge (output after at least
  one second of silence), not per output chunk.
- `session.resize` on an exited pane returns `SessionTerminated`
  (`data.kind: "terminated"`). `pane.respawn` accepts a session ID or name
  like every other pane target.
- An empty positional `params` array (`[]`) reads as no parameters.
  Non-empty arrays and scalars remain `InvalidParams`.
- `zmuxd` changes its working directory to `/` after resolving its paths.
  `zmux-connect` sends its working directory when it creates a session.
  A pane created without `cwd` starts in `$HOME`, or in `/` when `$HOME`
  is not an existing absolute directory. The umask is inherited unchanged.
- Terminating a pane sends `SIGHUP` and `SIGCONT` to the foreground and
  shell process groups, `SIGTERM` 100 ms later, and `SIGKILL` at the
  deadline, so `HUP` handlers run before the job is killed.

### Fixed

- Authenticate daemons before sending any request. Auto-spawn verifies its
  log destination and reaps the intermediate child.
- Drain buffered daemon frames, preserve partial frames, and bound writes.
  Restore the terminal on exit or suspend. Drain redirected stdin through
  EOF and keep reading pane output during a two-second quiet period.
- Accept reserved names with the explicit `attach` verb. Escape controls
  in human-readable output and print complete error responses with `--json`.
- Protocol: bound JSON nesting and node count before parsing, accept only
  string, integer, or null request IDs, and map every handler error through
  one error table. Lines longer than the reader buffer survive read timeouts.
- Foreground tracking: the Darwin argv parser no longer reads into the
  environment block. A failed process lookup reports the `pid-<n>` fallback
  once and retries with backoff instead of committing it.
- PTY and sessions: report child setup failures from the forked child, reset
  signal dispositions and close inherited descriptors before `exec`, emit
  `session_exited` exactly once after the final output, and serialize input
  writes per session with a deadline.
- Mux: fix a use-after-free between concurrent create and terminate, bound
  panes, clients, key bindings, and total scrollback, and reject duplicate
  session names. Event sinks are cleared outside the manager lock on every
  removal path, which removes a shutdown and respawn deadlock.
- Server: verify peer credentials, bind the socket privately through a pinned
  directory descriptor, never unlink a path that is not this user's stale
  socket, and replace the start-lock race with a persistent `flock` file.
  A create whose response cannot be built is rolled back, and the compact
  reply buffer is reserved before the mutation commits. One spare descriptor
  lets a control connection in when the descriptor table is full.
- Validate releases on each native target and publish only after every
  platform has supplied its archives and checksums.

## [0.3.0] - 2026-11-23

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

## [0.2.1] - 2026-11-23

### Fixed

- Fixed Linux `createPrivateSocketParent` for Zig 0.15.2 consumers. Opening the
  directory without `O_PATH` lets `fchmod` enforce mode `0700` under `umask 0022`.

## [0.2.0] - 2026-11-23

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
