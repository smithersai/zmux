# Daemon lifecycle and socket security

Because `zmuxd` spawns real interactive shells under the user's account, socket isolation and peer authentication are treated as hard security boundaries across `src/daemon.zig`, `src/server.zig`, `src/socket_path.zig`, and `src/log.zig`.

## Socket path resolution

`src/socket_path.zig` implements one shared precedence order for both `zmuxd` and `zmux-connect`:

1. Explicit CLI `--socket` override
2. `$ZMUX_SOCKET`
3. `$SMITHERS_SESSION_SOCKET`
4. `$XDG_RUNTIME_DIR/smithers-sessions.sock`
5. `$HOME/.smithers/sessions.sock`
6. `/tmp/zmux-<euid>/sessions.sock`

Every resolved path is checked for NUL bytes, trailing slashes, and `sockaddr_un.sun_path` length limits before binding.

## Private directories and startup locking

- Daemon-managed socket directories are created and verified as `0700` owned by the current effective UID. Symlink parents and group/world-writable directories are refused and logged as `socket_dir_refused` or `socket_dir_insecure`.
- Startup locking guarantees two concurrent `zmuxd` invocations cannot race and unlink a live daemon socket.
- After resolving paths, `zmuxd` changes its working directory to `/` so the daemon never pins a user's mount point or temporary directory.

## Same-UID peer credentials

Both the daemon (`src/server.zig`) and client (`src/connect.zig`) verify peer effective UIDs over the UNIX socket (`SO_PEERCRED` on Linux, `LOCAL_PEERCRED` / `getpeereid` on macOS) before accepting or sending RPC requests. Foreign-UID connections are rejected immediately and verified in CI by the root-level foreign-UID integration test step.

## Slow-client backpressure and shutdown

- Outbound control responses and output notifications enforce strict per-connection byte ceilings (`max_queued_bytes`, `max_control_bytes`).
- A slow output consumer never blocks the PTY reader or other attached clients: output frames are dropped cleanly with a `pane_output_dropped` notification carrying `resume_offset`, while an overly backlogged control channel disconnects cleanly.
- `daemon.shutdown` replies `{ "ok": true }`, flips `running` to false, refuses new mutations, closes active clients, and leaves ordered resource teardown to the main server loop.
- All diagnostic events emit structured JSON lines via `src/log.zig`.
