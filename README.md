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
- Server-owned session, window, pane, layout, client, key binding, alert, and
  respawn state exposed by `mux.snapshot`
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

`zmux` requires Zig **0.15.2** (pinned at `comptime` in `build.zig`).

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

Start the daemon on a private socket, then attach a client. If the named
session does not yet exist, `zmux-connect` creates it automatically and
attaches:

```sh
# Terminal 1 — daemon
zmuxd --socket /tmp/zmux.sock

# Terminal 2 — open or create a session named "work"
zmux-connect work --socket /tmp/zmux.sock
```

Pass `--no-create` to require an existing session, or `--command CMD` to
override the shell command spawned in the new session.

Drive the same daemon programmatically — every method is JSON-RPC 2.0:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"daemon.ping"}' \
  | nc -U /tmp/zmux.sock
# {"jsonrpc":"2.0","id":1,"result":{"version":"0.1.0"}}
```

`session.create` accepts `id` (or equivalently `name`/`title`) as the
human-readable session name; the daemon allocates a separate auto-generated
pane id and returns it in the response. `client.attach` accepts either id
form for `paneId` — i.e. `"work"` or `"pane-1-…"`.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session.create",
  "params":{"id":"work","rows":40,"cols":120,"command":"bash"}}' \
  | nc -U /tmp/zmux.sock
```

## Library use

The Zig API exposes the daemon, mux model, and protocol primitives so an
embedding app can run an in-process server (tests, single-process apps) or
build a custom client:

```zig
const zmux = @import("zmux");

var server = try zmux.Server.init(allocator, "/tmp/zmux.sock", 60);
defer server.deinit();
try server.run();
```

Top-level modules:

| Module | Role |
|--------|------|
| `zmux.server` | UNIX-socket JSON-RPC server, request dispatch |
| `zmux.daemon` | `zmuxd` entry point and startup lock |
| `zmux.mux` | Session / window / pane / client / key state |
| `zmux.native` | PTY child spawn, fd lifecycle, event sink |
| `zmux.pty` | Low-level `openpty(3)` / `forkpty(3)` wrappers |
| `zmux.protocol` | JSON-RPC framing, error codes, version |
| `zmux.buffer` | Bounded ring buffer for scrollback |
| `zmux.foreground` | Foreground-process detection (Linux/macOS) |
| `zmux.connect` | Client implementation (raw mode, SIGWINCH) |

## Protocol

`zmux` speaks JSON-RPC 2.0 over a newline-delimited UNIX-domain socket. The
protocol version is reported by `daemon.ping` (see `src/protocol.zig`).

### Requests

```jsonc
{ "jsonrpc": "2.0", "id": 1, "method": "session.create",
  "params": { "id": "work", "rows": 40, "cols": 120, "command": "bash" } }
```

### Notifications (server → client)

```jsonc
{ "jsonrpc": "2.0", "method": "pane_output",
  "params": { "session": "work", "pane": 0, "data": "...base64..." } }
```

| Notification | Sent when |
|--------------|-----------|
| `pane_output` | PTY produced bytes |
| `pane_activity` | Pane received output after being idle |
| `pane_bell` | Pane received a `BEL` |
| `session_exited` | Session's child process exited |
| `foreground_changed` | Pane's foreground process changed |

### Errors

JSON-RPC standard error codes plus `-32000` (`session_error`) for domain
errors (unknown session, PTY allocation failure, etc.).

## Security

- Sockets are created in directories with mode `0700` and files with mode
  `0600`; the daemon never widens permissions on parent directories it did
  not create.
- Accepted client connections are validated via SO_PEERCRED / `LOCAL_PEERPID`
  and rejected unless the peer's UID matches the daemon's.
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
