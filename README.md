# zmux

A tmux-style PTY session multiplexer, written in Zig and shipped as a Zig
package. A long-lived daemon owns the mux model and PTY child processes;
clients attach and detach over a UNIX-domain JSON-RPC socket.

`zmux` is the session backbone behind the [Smithers App](https://github.com/smithersai)
and is intended for any application that needs persistent terminal sessions
without depending on `tmux(1)` itself: native desktop apps, GTK frontends,
web terminals, headless agent runtimes, and CI fixtures all attach to the
same daemon model.

```
┌────────────┐     UNIX socket / JSON-RPC      ┌───────────────────────┐
│  client A  │ ──────────────────────────────▶ │                       │
└────────────┘                                  │                       │
┌────────────┐                                  │   zmuxd (daemon)      │
│  client B  │ ──────────────────────────────▶ │  • sessions / windows │
└────────────┘                                  │  • panes / PTYs       │
┌────────────┐                                  │  • scrollback buffer  │
│  client C  │ ──────────────────────────────▶ │  • key bindings       │
└────────────┘                                  └───────────────────────┘
```

## Why zmux

`tmux(1)` is a great terminal multiplexer but a poor library: its server speaks
a line-oriented control protocol bolted onto a CLI, its model lives behind
opaque format strings, and embedding it means shelling out to a binary you
do not own. `zmux` keeps tmux's server-owns-the-PTY architecture and drops
everything else:

- **JSON-RPC over a UNIX socket.** Every API call is a structured request with
  a structured response. No format strings, no screen-scraping `tmux ls`.
- **First-class multi-client semantics.** Multiple logical clients can attach
  to the same pane simultaneously. Native, web, and headless frontends share
  one daemon-owned PTY without fighting over the fd.
- **Server-side scrollback capture.** Every pane streams into a bounded ring
  buffer. New attachments replay the recent backlog instead of starting at a
  blank screen.
- **Out-of-band notifications.** Pane output, activity, bell, exit, and
  foreground-process changes arrive as JSON-RPC notifications, so a UI does
  not need to poll.
- **Embeddable.** Zig package, MIT license, no required system services.

## What's supported

- UNIX-domain JSON-RPC control socket
- Owner-only socket files and private daemon-managed directories
- Same-UID peer credential validation by both client and daemon
- Daemon-side startup locking so concurrent starters cannot unlink or steal a
  live daemon socket
- `daemon.ping` / `daemon.shutdown`
- Server-owned session, window, pane, layout, client, key binding, activity /
  bell / exit alert, and respawn state exposed by `mux.snapshot`
- `session.{create,info,list,terminate,resize,capture,send,sendKey,rename}`
- `window.{new,select,rename}`
- `pane.{split,select,rename,respawn}`
- `client.{attach,detach,switch,list}` — multiple logical clients per pane
- `key.{bind,dispatch,list}` — prefix-style key binding and dispatch
- `command.exec` — first tmux-like command parser for `split-window`,
  `new-window`, and `respawn-pane`
- PTY resize, raw-byte input, named-key input, and bounded scrollback capture
- Pane output, activity, bell, exit, and foreground process notifications
- Client-side raw mode, SIGWINCH resize forwarding, and termios restoration
- Helper binary aliases for embedding apps:
  `smithers-session-daemon` and `smithers-session-connect`

## Current gaps

`zmux` is intentionally smaller than tmux. It owns the state and the daemon
model, but the command surface is narrower. The following are not yet
implemented and would be welcome contributions:

- Full tmux command-line target syntax (`-t session:window.pane` everywhere)
- Copy mode and paste buffers
- Status bars, menus, popups
- Hooks and formats
- Config file (`.tmux.conf`-style) loading
- Layout persistence across daemon restarts

Like tmux, `zmux` keeps sessions alive across client/app restarts only while
the daemon process and its PTY child processes remain alive. It does not keep
live processes alive across an operating-system reboot.

## Install

`zmux` requires Zig **0.17.1** or a later **0.17.x** patch release. A
`comptime` guard in `build.zig` accepts `>= 0.17.1` and `< 0.18.0` and rejects
0.18 development builds. Use zmux v0.2.1 for Zig 0.15.2. It fixes Linux socket directory creation from v0.2.0.

### Prebuilt binaries

GitHub Releases ship `.tar.gz` archives with matching
`.sha256` checksums for all four targets below. v0.1.0 shipped raw binaries
for linux-x64 and macos-arm64.

| Asset | Target |
|-------|--------|
| `zmuxd-linux-x64.tar.gz` / `zmux-connect-linux-x64.tar.gz` | Linux x86_64, musl |
| `zmuxd-linux-arm64.tar.gz` / `zmux-connect-linux-arm64.tar.gz` | Linux arm64, musl |
| `zmuxd-macos-arm64.tar.gz` / `zmux-connect-macos-arm64.tar.gz` | macOS arm64 |
| `zmuxd-macos-x64.tar.gz` / `zmux-connect-macos-x64.tar.gz` | macOS x86_64 |

Each tarball includes the binary and `LICENSE`, with a matching `.sha256`
sidecar:

```sh
release_tag=vX.Y.Z
curl -LO "https://github.com/smithersai/zmux/releases/download/${release_tag}/zmux-connect-linux-x64.tar.gz"
curl -LO "https://github.com/smithersai/zmux/releases/download/${release_tag}/zmux-connect-linux-x64.tar.gz.sha256"
shasum -a 256 -c zmux-connect-linux-x64.tar.gz.sha256
tar -xzf zmux-connect-linux-x64.tar.gz
chmod +x zmux-connect
```

### As a Zig package

```sh
zig fetch --save=zmux git+https://github.com/smithersai/zmux
```

Then in your `build.zig`:

```zig
const zmux_dep = b.dependency("zmux", .{
    .target = target,
    .optimize = optimize,
});

// Use the library API
exe.root_module.addImport("zmux", zmux_dep.module("zmux"));

// Or install one of the prebuilt executables
b.installArtifact(zmux_dep.artifact("zmuxd"));
b.installArtifact(zmux_dep.artifact("zmux-connect"));
```

### From source

```sh
git clone https://github.com/smithersai/zmux
cd zmux
zig build
zig build test
```

Produces:

| Artifact | Purpose |
|----------|---------|
| `zig-out/bin/zmuxd` | Long-lived daemon. Owns sessions and PTY child processes. |
| `zig-out/bin/zmux-connect` | Client. Attaches stdin/stdout to a session over the daemon socket. |
| `zig-out/bin/smithers-session-daemon` | Alias of `zmuxd` for embedding apps. |
| `zig-out/bin/smithers-session-connect` | Alias of `zmux-connect` for embedding apps. |

## Quickstart

The tmux-like one-command path starts a daemon on demand, opens or creates a
session named `work`, and attaches your terminal:

```sh
zmux-connect work --spawn-daemon
```

`--spawn-daemon` looks for a sibling `zmuxd` next to the `zmux-connect`
binary (`smithers-session-connect` prefers `smithers-session-daemon`) and
waits up to 4 seconds for the socket. An auto-spawned daemon writes startup
stderr to `<socket>.log` in a private directory owned by your UID.
Pass an existing private parent when auto-spawning on a custom path.

Detach with `Ctrl-\` by default, then reattach with the same session name:

```sh
zmux-connect work
```

Use `--detach-key ctrl-a` to choose a different chord, or
`--detach-key none` to disable it. Detach interception is enabled only when
stdin is a TTY, so piped input is forwarded verbatim. After piped input
reaches EOF, the client reads output until the session ends or the socket
is quiet for two seconds. The pane keeps running when the client leaves.
Reattaching to an exited pane prints its replay and exit status, then
respawns it with the original command.

You can also start the daemon explicitly on its default socket.

```sh
# Terminal 1 — daemon
zmuxd

# Terminal 2 — open or create a session named "work"
zmux-connect work
```

Pass `--no-create` to require an existing session, or `--command CMD` to
override the shell command spawned in the new session. Both binaries support
`--version` / `-V`.

Common management calls are available through `zmux-connect`:

```sh
zmux-connect ls
zmux-connect rename work renamed
zmux-connect kill renamed
zmux-connect shutdown
```

Add `--json` to `ls`, `kill`, `rename`, or `shutdown` to print the raw
JSON-RPC response on stdout, including errors. An RPC error exits with status 1.
`--socket PATH` may precede the verb. To attach to a session named `attach`,
`ls`, `kill`, `rename`, or `shutdown`, use `zmux-connect attach NAME` or
`zmux-connect -- NAME`. The latter form also accepts names starting with `-`.

To connect programmatically, use the daemon’s resolved path from the next
section. This example uses the default HOME-based socket.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"daemon.ping"}' \
  | nc -U "$HOME/.smithers/sessions.sock"
# {"jsonrpc":"2.0","id":1,"result":{"version":"0.4.0","pid":12345,"socketPath":"/home/user/.smithers/sessions.sock","sessions":0,"panes":0}}
```

The socket protocol is one JSON document per physical line, terminated by
`\n`. Do not split one request across multiple lines. The daemon disconnects
clients that do not complete their first frame within 10 seconds of connecting
or do not complete a started frame within 30 seconds.

`session.create` accepts `id` (or equivalently `name`/`title`) as the
human-readable session name; the daemon allocates a separate auto-generated
pane id and returns it as `paneId`. `client.attach` accepts either a name
or an ID. An exact ID takes precedence over a name. Duplicate names
return `DuplicateSessionName`.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session.create","params":{"id":"work","rows":40,"cols":120,"command":"bash"}}' \
  | nc -U "$HOME/.smithers/sessions.sock"
```

## Socket & lifecycle

`--socket PATH` overrides the default socket path. Without it, `zmuxd` and
`zmux-connect` resolve the path identically:

| Order | Source |
|-------|--------|
| 1 | `$ZMUX_SOCKET` |
| 2 | `$SMITHERS_SESSION_SOCKET` |
| 3 | `$XDG_RUNTIME_DIR/smithers-sessions.sock` |
| 4 | `$HOME/.smithers/sessions.sock` |
| 5 | `/tmp/zmux-<uid>/sessions.sock` when `HOME` is unset |

Unix socket paths are limited to 103 bytes on macOS and 107 bytes on Linux.
The CLI resolves relative paths against its working directory.
The library requires an absolute path and returns `SocketPathNotAbsolute`
for relative paths. If the resolved path is too long, choose a shorter path with `--socket` or
`ZMUX_SOCKET`.

Set the verbosity of structured daemon diagnostics on stderr with
`zmuxd --log-level <error|warn|info|debug>` or the `ZMUX_LOG_LEVEL` environment
variable. The default is `warn`.

The daemon writes an advisory pid file at `<socket>.pid` and uses
`<socket>.lock` for startup locking. A second daemon started against a live
socket exits successfully without unlinking the running daemon's socket.

By default `zmuxd` self-exits after 3600 idle seconds, but only when it has
zero live sessions. Use `--idle-seconds 0` to run until explicit shutdown.
Sessions and PTY children die with the daemon; zmux does not persist live
processes across daemon shutdown or operating-system reboot.

After startup `zmuxd` runs in `/`, not in the directory it was launched
from. A pane starts in the `cwd` its creator passes. `zmux-connect` passes
its own working directory when it creates a session. Without `cwd`, a pane
starts in `$HOME`, or in `/` when `$HOME` is not an existing absolute
directory. Panes inherit the daemon's umask.

Terminating a pane sends `SIGHUP` and `SIGCONT` to its foreground and shell
process groups, `SIGTERM` 100 ms later, and `SIGKILL` at the deadline.
Background jobs that a shell moved to their own process group die only if
the shell forwards `SIGHUP` to them, as bash does and dash does not.

`SIGTERM` and `SIGINT` request graceful shutdown. `SIGHUP` is ignored so an
auto-spawned daemon survives the spawning client's terminal. You can also
stop the daemon with `zmux-connect shutdown` or the `daemon.shutdown` RPC.

The daemon accepts at most 256 concurrent client connections. `scrollbackBytes`
defaults to 10 MiB and must be 64 MiB or smaller for `session.create`,
`window.new`, and `pane.split`.

## Library use

The Zig API exposes the daemon, mux model, and protocol primitives so an
embedding app can run an in-process server (tests, single-process apps) or
build a custom client:

```zig
const std = @import("std");
const zmux = @import("zmux");

pub fn main(init: std.process.Init) !void {
    var server = try zmux.Server.init(init.gpa, init.io, "/tmp/zmux.sock", 60);
    defer server.deinit();
    try server.run();
}
```

Every stateful entry point takes a `std.Io` after the allocator:
`zmux.Server.init(gpa, io, socket_path, idle_timeout_seconds)`,
`zmux.NativeSession.create(gpa, io, options)`, and
`zmux.SessionManager.init(gpa, io, event_sink)`. zmux runs each client
connection and PTY reader on its own `std.Thread`. The allocator must be
thread-safe and outlive `Server.deinit`. Use thread-safe Io such as
`std.Io.Threaded` (`std.process.Init.io` is one). The
`Io` supplies mutexes, clocks, sleeps, randomness, and file access. PTY and
socket descriptors use nonblocking I/O driven by `poll(2)`.

Top-level modules:

| Module | Role |
|--------|------|
| `zmux.server` | UNIX-socket JSON-RPC server, request dispatch |
| `zmux.daemon` | `zmuxd` entry point and startup lock |
| `zmux.mux` | Session / window / pane / client / key state |
| `zmux.native` | PTY child spawn, fd lifecycle, event sink |
| `zmux.pty` | Low-level `openpty(3)` plus manual fork/exec PTY child spawning |
| `zmux.protocol` | JSON-RPC framing, error codes, version |
| `zmux.buffer` | Bounded ring buffer for scrollback |
| `zmux.foreground` | Foreground-process detection: full comm/argv on macOS and Linux, pid-only fallback on other platforms |
| `zmux.connect` | Client implementation (raw mode, SIGWINCH) |

## Protocol

`zmux` speaks JSON-RPC 2.0 over a newline-delimited UNIX-domain socket. The
protocol version is reported by `daemon.ping` along with the daemon `pid`,
`socketPath`, and separate `sessions` and `panes` counts (see
`src/protocol.zig`). Request and response fields use camelCase. Notifications
use snake_case params. `mux.snapshot` pane alerts expose `activity`, `bell`,
`exited`, `lastActivityMs`, and `lastBellMs`.

### Requests

```json
{ "jsonrpc": "2.0", "id": 1, "method": "session.create", "params": { "id": "work", "rows": 40, "cols": 120, "command": "bash" } }
```

Mutating requests that create a pane (`session.create`, `window.new`,
and `pane.split`) return `{sessionId, windowId, paneId, generation}`. They
merge `env` over the daemon environment by default. Set `clearEnv: true` to
supply a replacement environment. An unset `TERM` defaults to
`xterm-256color`.

`client.attach` accepts `createIfMissing` with `session.create` parameters
to open or create atomically. The result includes `created`, `exited`,
`exitCode`, `signal`, `generation`, and the exclusive byte offset
`replayEndOffset` of the base64 scrollback replay. Use the returned `paneId` and
discard live bytes below `replayEndOffset` in that generation. Attach also
succeeds after a pane has exited. `pane.respawn` defaults to `kill: false`
and returns `PaneRunning` on a running pane. Use `kill: true` to replace it.

`session.capture` returns UTF-8 `text` with invalid sequences replaced by
U+FFFD. Use `textBase64` for the original bytes.

### Notifications (server → client)

```json
{ "jsonrpc": "2.0", "method": "pane_output", "params": { "pane_id": "pane-1", "data_base64": "aGVsbG8=", "offset": 12, "generation": 1 } }
```

`pane_output` goes to attached connections and explicit subscribers.
Call `events.subscribe` with `{"panes":["*"]}` or a list of pane IDs to
observe unattached panes. Lifecycle events are global. A slow reader
can receive `pane_output_dropped` and see a gap in its terminal output.
The notification gives the number of dropped bytes and the byte offset
where live output resumes.

| Notification | Params | Sent when |
|--------------|--------|-----------|
| `pane_output` | `pane_id`, `data_base64`, `offset`, `generation` | PTY produced bytes |
| `pane_output_dropped` | `pane_id`, `dropped_bytes`, `resume_offset`, `generation` | The connection's output queue crossed its high-water mark |
| `pane_activity` | `pane_id`, `last_activity_ms`, `generation` | Pane received output after at least a second of inactivity |
| `pane_bell` | `pane_id`, `last_bell_ms`, `generation` | Pane received a `BEL` |
| `session_exited` | `session_id`, `pid`, `exit_code`, `signal`, `generation` | Pane's PTY output ended after child exit |
| `foreground_changed` | `session_id`, `pid`, `comm`, `argv`, `argv_truncated` | Pane's foreground process changed |
| `pane_respawned` | `pane_id`, `generation`, `pid` | Pane acquired a new PTY child |
| `client_detached` | `client_id`, `reason` | A client detached remotely or its pane/session was removed |
| `client_switched` | `client_id`, `pane_id`, `generation`, `replay_base64`, `replay_end_offset` | A different connection switched this client to another pane |

For compatibility, the notification field `session_id` carries a **pane ID**.
The owning connection receives `client_detached` or `client_switched` when
another connection modifies its attachment. Resize uses the most recent
requested size for a pane, including across a respawn or detach.

On macOS, `foreground_changed.comm` and `argv` come from platform process
inspection. On Linux, they come from `/proc/<pid>/comm` and
`/proc/<pid>/cmdline`, respectively. On other platforms, the notification
falls back to the process ID, with a `pid-<n>` placeholder for `comm` and an
empty `argv`.

### Errors

Requests with no `id` are notifications and receive no response. A request
ID may be a string, integer, or null. Errors include a stable `message` such
as `PaneNotFound` and a category in `error.data.kind`. Branch on the category.

| Code | `data.kind` |
|------|-------------|
| `-32700` | `parse` |
| `-32600` | `invalid_request` |
| `-32601` | `method_not_found` |
| `-32602` | `invalid_params` |
| `-32000` | `not_found`, `terminated`, `conflict`, `limit`, `spawn_failed`, `io` |
| `-32603` | `internal` |

## Troubleshooting

- `zmux-connect: no daemon at <socket>`: start `zmuxd`, pass
  `--spawn-daemon`, or make sure daemon and client resolve the same socket
  path.
- `PaneNotFound`: the requested pane/session is absent. Without `--no-create`,
  `zmux-connect <name>` creates a missing session automatically; with
  `--no-create`, it exits instead.
- Daemon start exits immediately with status 0: another daemon is already
  accepting connections on that socket. This is intentional concurrent-start
  behavior.
- A clean restart reuses the advisory `<socket>.lock` sentinel and replaces
  a stale socket after verifying its owner and type. Leave the lock file in
  place so concurrent starters lock the same inode. The advisory pid file
  is `<socket>.pid`.
- Auto-spawn failure: check `<socket>.log` for daemon startup stderr.
- Daemon disappeared after inactivity: the default idle timeout is 3600
  seconds with zero running panes and zero attached clients. Restart it or use `--idle-seconds 0`.
- Terminal looks stuck after an interrupted client: run `reset` or
  `stty sane`.
- Stop the daemon with `zmux-connect shutdown`, a `daemon.shutdown` RPC, or
  `SIGTERM`.

## Security

- Daemon-managed socket directories must be owned by the effective UID and
  have no group or other permission bits. The daemon creates missing managed
  directories with mode `0700` and binds sockets with mode `0600`. Explicit
  socket directories belong to the caller.
- The daemon and client authenticate the peer's effective UID with
  `SO_PEERCRED` on Linux and `getpeereid(3)` on macOS. They require a matching
  UID before exchanging RPCs.
- Startup is locked by `flock(2)` on a sentinel file; concurrent starters
  detect a live daemon and exit cleanly instead of unlinking the socket.

## Platform support

| Platform | Daemon | Client |
|----------|--------|--------|
| macOS (arm64, x86_64) | ✅ | ✅ |
| Linux (glibc, musl)   | ✅ | ✅ |
| iOS                   | ❌ (no `fork`) | ❌ |
| Windows               | ❌ | ❌ |

Minimum macOS deployment target is 14.0.

## Development

```sh
zig build           # build all artifacts
zig build test      # unit + integration tests
```

The integration suite drives the real server over a UNIX socket and exercises
session create / attach / detach / scrollback replay end-to-end. See
`test/integration/session_daemon.zig`.

## Acknowledgements

`zmux` borrows tmux's architecture wholesale. The reference points used while
writing it:

- `tmux/server.c` — server socket creation, long-running server loop
- `tmux/client.c` — client connect / start-server retry and start lock
- `tmux/proc.c` — background server process model
- `tmux/spawn.c` — server-owned PTY child creation
- `tmux/tmux.1` — documented client/server attach/detach behavior

## License

[MIT](LICENSE)
