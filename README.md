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
- Owner-only socket file permissions; newly-created private socket directories
  are tightened to `0700` without chmodding existing parents like `/tmp`
- Same-UID peer credential validation on accepted socket clients
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
0.18 development builds. zmux v0.2.0 is the last release for Zig 0.15.2.

### Prebuilt binaries

Starting with v0.2.0, GitHub Releases ship `.tar.gz` archives with matching
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
waits up to 2 seconds for the socket. An auto-spawned daemon writes startup
stderr to `<socket>.log`.

Detach with `Ctrl-\` by default, then reattach with the same session name:

```sh
zmux-connect work
```

Use `--detach-key ctrl-a` to choose a different chord, or
`--detach-key none` to disable it. Detach interception is enabled only when
stdin is a TTY, so piped input is forwarded verbatim.

You can also start the daemon explicitly on a private socket:

```sh
# Terminal 1 — daemon
zmuxd --socket /tmp/zmux.sock

# Terminal 2 — open or create a session named "work"
zmux-connect work --socket /tmp/zmux.sock
```

Pass `--no-create` to require an existing session, or `--command CMD` to
override the shell command spawned in the new session. Both binaries support
`--version` / `-V`.

Common management calls are available through `zmux-connect`:

```sh
zmux-connect ls --socket /tmp/zmux.sock
zmux-connect rename work renamed --socket /tmp/zmux.sock
zmux-connect kill renamed --socket /tmp/zmux.sock
zmux-connect shutdown --socket /tmp/zmux.sock
```

Add `--json` to `ls`, `kill`, `rename`, or `shutdown` to print the raw
JSON-RPC response.

Drive the same daemon programmatically — every method is JSON-RPC 2.0:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"daemon.ping"}' \
  | nc -U /tmp/zmux.sock
# {"jsonrpc":"2.0","id":1,"result":{"version":"0.3.0","pid":12345,"socketPath":"/tmp/zmux.sock","sessions":0,"panes":0}}
```

The socket protocol is one JSON document per physical line, terminated by
`\n`. Do not split one request across multiple lines.

`session.create` accepts `id` (or equivalently `name`/`title`) as the
human-readable session name; the daemon allocates a separate auto-generated
pane id and returns it in the response. `client.attach` accepts either id
form for `paneId` — i.e. `"work"` or `"pane-1-…"`.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session.create","params":{"id":"work","rows":40,"cols":120,"command":"bash"}}' \
  | nc -U /tmp/zmux.sock
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
If the resolved path is too long, choose a shorter path with `--socket` or
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
connection and PTY reader on its own `std.Thread`, so pass a thread-safe
implementation such as `std.Io.Threaded` (`std.process.Init.io` is one). The
`Io` supplies mutexes, clocks, sleeps, randomness, and file access. PTY, socket,
and `poll(2)` work stays on blocking descriptors.

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

```jsonc
{ "jsonrpc": "2.0", "id": 1, "method": "session.create", "params": { "id": "work", "rows": 40, "cols": 120, "command": "bash" } }
```

### Notifications (server → client)

```jsonc
{ "jsonrpc": "2.0", "method": "pane_output", "params": { "pane_id": "pane-1", "data_base64": "...base64..." } }
```

| Notification | Params | Sent when |
|--------------|--------|-----------|
| `pane_output` | `pane_id`, `data_base64` | PTY produced bytes |
| `pane_activity` | `pane_id`, `last_activity_ms` | Pane received output after being idle |
| `pane_bell` | `pane_id`, `last_bell_ms` | Pane received a `BEL` |
| `session_exited` | `session_id`, `pid`, `exit_code`, `signal` | Pane's PTY child exited |
| `foreground_changed` | `session_id`, `pid`, `comm`, `argv` | Pane's foreground process changed |

On macOS, `foreground_changed.comm` and `argv` come from platform process
inspection. On Linux, they come from `/proc/<pid>/comm` and
`/proc/<pid>/cmdline`, respectively. On other platforms, the notification
falls back to the process ID, with a `pid-<n>` placeholder for `comm` and an
empty `argv`.

### Errors

JSON-RPC standard error codes plus `-32000` (`session_error`) for domain
errors (unknown session, PTY allocation failure, etc.).

`zmux-connect`'s create-vs-attach fallback treats an error payload containing
the substring `PaneNotFound` as permission to create the session unless
`--no-create` was passed.

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
- Stale socket or lock files: if no daemon is running, remove `<socket>` and
  `<socket>.lock`. The pid file is `<socket>.pid`.
- Auto-spawn failure: check `<socket>.log` for daemon startup stderr.
- Daemon disappeared after inactivity: the default idle timeout is 3600
  seconds with zero sessions. Restart it or use `--idle-seconds 0`.
- Terminal looks stuck after an interrupted client: run `reset` or
  `stty sane`.
- Stop the daemon with `zmux-connect shutdown`, a `daemon.shutdown` RPC, or
  `SIGTERM`.

## Security

- Sockets are created in directories with mode `0700` and files with mode
  `0600`; the daemon never widens permissions on parent directories it did
  not create.
- Accepted client connections are validated via `SO_PEERCRED` on Linux and
  `getpeereid(3)` / `LOCAL_PEERCRED` on macOS, then rejected unless the
  peer's effective UID matches the daemon's. Unsupported platforms fail
  closed.
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
zig build test      # unit + integration tests + fuzz corpus smoke checks
```

The integration suite drives the real server over a UNIX socket and exercises
session create / attach / detach / scrollback replay end-to-end. See
`test/integration/session_daemon.zig`.

### Fuzz testing

`zmux` ships a 32-target coverage-guided structured fuzz suite built on Zig
0.17's `std.testing.fuzz` + `std.testing.Smith` with LLVM SanitizerCoverage
instrumentation (`test/fuzz/`). Every fuzz target checks differential oracles,
single-line JSON-RPC / JSON log invariants, structural state-graph invariants,
and `FailingAllocator` OOM leak/atomicity guarantees:

```sh
# Fast pure + pipe/socketpair fuzz suite (26 targets)
zig build fuzz -Doptimize=ReleaseSafe --fuzz=25K --summary all

# Continuous fuzzing with web UI (runs until interrupted)
zig build fuzz -Doptimize=ReleaseSafe --fuzz

# Target a single fuzzer by name
zig build fuzz -Dtest-filter="ScrollbackBuffer" --fuzz=100K

# Live real-PTY, private socket binding, pid/lock, and multi-client chaos (6 targets)
zig build fuzz-live --fuzz=150 --summary all
```

`zig build test` automatically executes every fuzz target's regression corpus
deterministically without `--fuzz`. CI runs bounded coverage-guided campaigns
for both `fuzz` and `fuzz-live` on Ubuntu on every push and pull request.

### Performance benchmarks & incremental Smithers workflow

`zmux` includes 85 `ReleaseFast` benchmarks across all 12 modules (`bench/`),
paired with a committed baseline ([`bench/baseline.json`](bench/baseline.json))
and incremental Smithers target declarations ([`.smithers/WORKSPACE.ts`](.smithers/WORKSPACE.ts),
[`PACKAGE.ts`](PACKAGE.ts)).

Each per-module test and benchmark target declares its exact Zig source
dependency closure, and every benchmark runs in Smithers' `exclusive` tier with
cached `.benchmarks/<module>.json` outputs so unchanged modules hit cache and
only affected benchmarks re-run on any change:

```sh
# Run only affected unit/fuzz/integration tests and benchmarks for your changes
smithers-build affected test //... --include-exclusive

# Run benchmarks incrementally (cache-hitting unchanged modules) and print the
# full Markdown comparison table against bench/baseline.json
smithers-build run //:bench

# Refresh bench/baseline.json from the latest cached/fresh benchmark results
smithers-build run //:benchUpdateBaseline

# Run all non-exclusive unit, fuzz, format, and integration tests
smithers-build test //...
```

You can also invoke individual suites directly with Zig:

```sh
zig build bench-buffer                     # single module suite (ReleaseFast)
zig build bench-server -- --quick          # faster sampling for quick iteration
zig build bench-check                      # compile all benchmark binaries
zig build bench                            # run all 12 benchmark suites
```

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
