# zmux

A headless, zero-dependency PTY session multiplexer and terminal intelligence daemon written in Zig. A long-lived daemon (`zmuxd`) owns the mux tree, PTY child processes, bounded scrollback ring buffers, and a pure-Zig VT100/xterm/OSC terminal state engine. Clients attach over a UNIX-domain JSON-RPC 2.0 socket through the unified `zmux` CLI, built-in `zmux mcp` server, official TypeScript and Python SDKs, the authenticated `zmux-ws` web bridge, or the embeddable `libzmux` C99 ABI.

`zmux` is the session backbone behind the [Smithers App](https://github.com/smithersai) and is built for any application that needs persistent, inspectable terminal sessions without depending on `tmux(1)`: native desktop apps, web terminals (`xterm.js`), coding agents (Claude Code, Codex, MCP hosts), SSH workflows, and CI fixtures all attach to the same daemon model.

```text
┌────────────────────────────┐     UNIX socket / JSON-RPC 2.0      ┌─────────────────────────────┐
│  zmux CLI / zmux ssh / MCP │ ──────────────────────────────────> │                             │
└────────────────────────────┘                                     │      zmuxd (daemon)         │
┌────────────────────────────┐                                     │  - sessions / windows       │
│  TS / Python / C99 SDKs    │ ──────────────────────────────────> │  - panes / splits / zoom    │
└────────────────────────────┘                                     │  - kqueue / epoll reactor   │
┌────────────────────────────┐                                     │  - pure-Zig VT100/OSC grid  │
│  zmux-ws -> xterm.js Web   │ ──────────────────────────────────> │  - scrollback + asciicast   │
└────────────────────────────┘                                     └─────────────────────────────┘
```

## Why zmux

`tmux(1)` is a great interactive multiplexer for humans, but a painful programmatic substrate. Its control mode bolts a line-oriented protocol onto a CLI, its state hides behind opaque format strings, and embedding it means shelling out to a binary you do not own. `zmux` keeps tmux's daemon-owns-the-PTY architecture and reimagines everything else for apps and agents:

- **Typed JSON-RPC 2.0 + OpenRPC 1.3.2.** All 39 RPCs and 13 push notifications are documented in [`protocol/openrpc.json`](protocol/openrpc.json) and verified against Zig server dispatch tables in CI. No format strings or screen-scraping.
- **Pure-Zig VT100/xterm/OSC terminal intelligence.** Every pane tracks a stateful cell grid, primary and alternate screen buffers, cursor and DEC modes, OSC 0/2 title, OSC 7 CWD, OSC 52 clipboard, OSC 133 prompt/command boundaries, and OSC 7501/9/777 agent status with zero external dependencies.
- **Agent-native primitives out of the box.** `session.screen` reads rendered text and cells, `pane.wait` blocks server-side on patterns, exits, idle windows, or prompt completion, `pane.exec` returns structured `{exitCode, output, durationMs}`, `pane.signal` delivers POSIX signals, `pane.record` writes asciicast v2 `.cast` files, and `zmux mcp` exposes 9 stdio MCP tools directly from the single native binary.
- **Zero-poll OS event reactor.** macOS `kqueue(2)` (`EVFILT_PROC` + `NOTE_EXIT`) and Linux `epoll(7)` + `eventfd(2)` + `pidfd_open(2)` eliminate legacy 25 ms exit polling loops.
- **First-class multi-client sharing and lossless reattach.** Multiple humans, web terminals, and headless agents share one daemon-owned PTY with per-client `readOnly` and `resizePolicy` modes, `replayMode: "vt"` lossless TUI restoration, and gap-free `resumeFromOffset` delta replay.
- **Embeddable everywhere.** Zero runtime dependencies, MIT license, native Zig package, `libzmux.a` + `include/zmux.h` C99 ABI, zero-dep `@smithers/zmux` TypeScript/Bun/Node SDK + `zmux-ws` + `xterm` adapter, and zero-dep Python 3.10+ sync/`asyncio` SDK.

## Architectural thesis: headless backbone, not terminal chrome

`zmux` is intentionally focused on being the fast, secure, programmatic PTY backbone. Status bars, popups, copy-mode UIs, mouse menus, and `.tmux.conf` scripting belong in the host application (your terminal emulator, desktop app, web UI, or coding agent), not baked into the daemon. Like tmux, `zmux` keeps sessions alive across client and app restarts while `zmuxd` and its PTY children run. It does not persist live processes across an OS reboot.

## What's supported

- **Daemon & security:** UNIX-domain JSON-RPC 2.0 control socket, private `0700` daemon-managed directories, `0600` socket files, same-UID peer credential authentication (`SO_PEERCRED` / `getpeereid`), persistent `flock(2)` startup locking, and slow-client backpressure.
- **Unified `zmux` CLI:** auto-spawns `zmuxd` by default (`--no-spawn` to opt out) with `attach`, `new`, `ls`, `run`/`exec`, `send`, `screen`, `capture`/`tail`, `wait`, `signal`, `split`, `close`, `kill`, `rename`, `events`, `record`, `ssh`, `mcp`, `doctor`, `daemon`, and `shutdown`.
- **Daemon & mux core:** `daemon.{ping,shutdown}`, `mux.snapshot`, `session.{create,info,list,terminate,resize,capture,screen,send,sendKey,rename}`, `window.{new,select,rename,close}`, `pane.{split,select,rename,respawn,close,resizeSplit,zoom,metadata,wait,exec,signal,record}`, `client.{attach,detach,switch,list,setMode}`, `events.subscribe`, `key.{bind,dispatch,list}`, and `command.exec`.
- **VT & OSC state engine:** primary/alt screens, SGR 16/256/truecolor, UTF-8 wide cell widths, DEC modes, `replayMode: "vt"` ANSI restore snapshots, formatted `session.capture` (`raw`, `plain`, `ansi`, `cells`), and live push notifications (`pane_title_changed`, `pane_cwd_changed`, `pane_prompt_changed`, `pane_status_changed`).
- **SDKs & Web bridge:** [`protocol/openrpc.json`](protocol/openrpc.json), [`sdk/ts/`](sdk/ts/) (`@smithers/zmux`, `@smithers/zmux/xterm`, `zmux-ws`), [`sdk/python/`](sdk/python/) (sync + `asyncio`), and [`include/zmux.h`](include/zmux.h) + `libzmux.a` C99 ABI.
- **Compatibility binaries:** `zmuxd`, `zmux-connect`, `smithers-session-daemon`, and `smithers-session-connect`.

## Install

### One-line POSIX installer (SHA-256 verified)

```sh
curl -fsSL https://raw.githubusercontent.com/smithersai/zmux/main/scripts/install.sh | sh
```

Installs `zmux`, `zmuxd`, and `zmux-connect` into `~/.local/bin` after verifying `SHA256SUMS`. Pass `--dry-run`, `--dir DIR`, or `--version v0.5.0` to customize.

### Homebrew, Nix, and bunx/npx

```sh
# Homebrew (formula zmux.rb is generated and attached to every GitHub Release)
brew install https://github.com/smithersai/zmux/releases/latest/download/zmux.rb

# Nix flakes
nix run github:smithersai/zmux -- doctor --json

# Node / Bun zero-install launcher (downloads and SHA-256 verifies native binary)
bunx @smithers/zmux-cli ls
```

### Prebuilt release tarballs

GitHub Releases ship `.tar.gz` archives with `.sha256` sidecars, a consolidated `SHA256SUMS`, and `zmux.rb` for all four targets:

| Asset | Contents | Target |
|-------|----------|--------|
| `zmux-linux-x64.tar.gz` | `zmux`, `zmuxd`, `zmux-connect`, `LICENSE` | Linux x86_64, static musl |
| `zmux-linux-arm64.tar.gz` | `zmux`, `zmuxd`, `zmux-connect`, `LICENSE` | Linux arm64, static musl |
| `zmux-macos-arm64.tar.gz` | `zmux`, `zmuxd`, `zmux-connect`, `LICENSE` | macOS arm64 |
| `zmux-macos-x64.tar.gz` | `zmux`, `zmuxd`, `zmux-connect`, `LICENSE` | macOS x86_64 |
| `libzmux-<target>.tar.gz` | `libzmux.a`, `zmux.h`, `LICENSE` | All four targets |

Legacy split archives (`zmuxd-<target>.tar.gz` and `zmux-connect-<target>.tar.gz`) continue to ship alongside the unified archive.

### As a Zig package

`zmux` requires Zig **0.17.1** or a later **0.17.x** patch release (`>= 0.17.1, < 0.18.0`). Use zmux v0.2.1 for Zig 0.15.2.

```sh
zig fetch --save=zmux git+https://github.com/smithersai/zmux
```

Then in your `build.zig`:

```zig
const zmux_dep = b.dependency("zmux", .{
    .target = target,
    .optimize = optimize,
});

// Use the Zig library API (Server, SessionManager, NativeSession, vt, reactor, cli)
exe.root_module.addImport("zmux", zmux_dep.module("zmux"));

// Or install prebuilt binaries / libzmux.a
b.installArtifact(zmux_dep.artifact("zmux"));
b.installArtifact(zmux_dep.artifact("zmuxd"));
b.installArtifact(zmux_dep.artifact("zmux-connect"));
```

### From source

```sh
git clone https://github.com/smithersai/zmux
cd zmux
zig build -Doptimize=ReleaseSafe
zig build test
```

Produces:

| Artifact | Purpose |
|----------|---------|
| `zig-out/bin/zmux` | Unified CLI (auto-spawns `zmuxd`, interactive attach, agent verbs, `zmux mcp`, `zmux ssh`, `zmux doctor`). |
| `zig-out/bin/zmuxd` | Long-lived daemon owning sessions, PTYs, VT engines, and scrollback buffers. |
| `zig-out/bin/zmux-connect` | Backwards-compatible interactive attach client. |
| `zig-out/bin/smithers-session-daemon` | Alias of `zmuxd` for embedding apps. |
| `zig-out/bin/smithers-session-connect` | Alias of `zmux-connect` for embedding apps. |
| `zig-out/lib/libzmux.a` + `zig-out/include/zmux.h` | Embeddable C99 static library and header. |

## Quickstart

### Interactive sessions and agent scripting

`zmux` auto-starts `zmuxd` on demand when the daemon socket is absent:

```sh
# Open or create an interactive session named "work" (detach with Ctrl-\)
zmux work

# Reattach with lossless VT state restoration (ideal for vim, htop, TUIs)
zmux attach work --replay vt

# Script panes directly from a shell or coding agent
zmux new build --command "/bin/sh"
zmux exec build "zig build test"
zmux screen build --format plain
zmux wait build --pattern "passed" --timeout-ms 30000
zmux signal build SIGINT
zmux record build start --out session.cast
zmux doctor --json
```

### Built-in MCP server for coding agents

Register the native binary directly with Claude Code, Cursor, or any stdio MCP host (zero Node/Python runtime required):

```sh
claude mcp add zmux -- zmux mcp
```

`zmux mcp` exposes 9 tools: `zmux_list_sessions`, `zmux_create_session`, `zmux_send_input`, `zmux_send_key`, `zmux_read_screen`, `zmux_wait`, `zmux_exec`, `zmux_signal`, and `zmux_terminate`.

### Remote sessions over SSH

Attach to a remote host's `zmuxd` socket with automatic tunnel reconnect and gap-free `resumeFromOffset` replay:

```sh
zmux ssh devbox work
```

### TypeScript, Python, Web, and C99 SDKs

```ts
// TypeScript / Bun / Node (@smithers/zmux, zero dependencies)
import { ZmuxClient } from "@smithers/zmux"

const client = await ZmuxClient.connect({ spawnDaemon: true })
const pane = await client.createSession({ id: "agent", command: "/bin/sh" })
const res = await client.execPane({ paneId: pane.paneId, command: "uname -a" })
const screen = await client.screen({ paneId: pane.paneId })
console.log(res.exitCode, screen.title, screen.cwd, screen.text)
client.close()
```

```python
# Python 3.10+ (sdk/python, zero dependencies, sync + asyncio)
from zmux import ZmuxClient

with ZmuxClient.connect(spawn_daemon=True) as client:
    pane = client.create_session(name="agent", command="/bin/sh")
    screen = client.screen(pane.pane_id)
    print(screen.text)
```

```sh
# Authenticated WebSocket / HTTP / SSE bridge for browser xterm.js UIs
bun sdk/ts/src/bridge-cli.ts --port 7777
```

### Raw UNIX socket JSON-RPC

To connect programmatically without an SDK, speak newline-delimited JSON-RPC 2.0 over the daemon's socket:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"daemon.ping"}' \
  | nc -U "$HOME/.smithers/sessions.sock"
# {"jsonrpc":"2.0","id":1,"result":{"version":"0.5.0","pid":12345,"socketPath":"/home/user/.smithers/sessions.sock","sessions":0,"panes":0}}
```

The socket protocol is one JSON document per physical line terminated by `\n`. Do not split one request across multiple lines. The daemon disconnects clients that do not complete their first frame within 10 seconds of connecting or do not complete a started frame within 30 seconds.

`session.create` accepts `id` (or `name`/`title`) as the human-readable session name. The daemon allocates a separate auto-generated pane id and returns it as `paneId`. `client.attach` accepts either a name or an ID, with exact IDs taking precedence over names. Duplicate session names return `DuplicateSessionName`.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session.create","params":{"id":"work","rows":40,"cols":120,"command":"bash"}}' \
  | nc -U "$HOME/.smithers/sessions.sock"
```

## Socket and lifecycle

`--socket PATH` overrides the default socket path. Without it, `zmux`, `zmuxd`, `zmux-connect`, and all SDKs resolve the path identically:

| Order | Source |
|-------|--------|
| 1 | `$ZMUX_SOCKET` |
| 2 | `$SMITHERS_SESSION_SOCKET` |
| 3 | `$XDG_RUNTIME_DIR/smithers-sessions.sock` |
| 4 | `$HOME/.smithers/sessions.sock` |
| 5 | `/tmp/zmux-<uid>/sessions.sock` when `HOME` is unset |

UNIX socket paths are limited to 103 bytes on macOS and 107 bytes on Linux. The CLI resolves relative paths against its working directory. The library requires an absolute path and returns `SocketPathNotAbsolute` for relative paths.

Set structured daemon log verbosity on stderr with `zmuxd --log-level <error|warn|info|debug>` or `ZMUX_LOG_LEVEL` (default `warn`).

The daemon writes an advisory pid file at `<socket>.pid` and acquires `<socket>.lock` with `flock(2)` on startup. A second daemon started against a live socket exits with status 0 without unlinking the active socket. By default `zmuxd` self-exits after 3600 idle seconds only when it has zero live sessions and zero attached clients (`--idle-seconds 0` disables idle exit).

After startup `zmuxd` runs in `/`. Panes start in the creator's `cwd` (or `$HOME`, falling back to `/`) and inherit the daemon umask. Terminating a pane sends `SIGHUP` and `SIGCONT` to its foreground and shell process groups, `SIGTERM` 100 ms later, and `SIGKILL` at the deadline. `SIGTERM` and `SIGINT` request graceful daemon shutdown, while `SIGHUP` is ignored so an auto-spawned daemon survives its spawning terminal.

The daemon accepts up to 256 concurrent client connections. `scrollbackBytes` defaults to 10 MiB and must be 64 MiB or smaller.

## Library use

### Embedding in Zig

```zig
const std = @import("std");
const zmux = @import("zmux");

pub fn main(init: std.process.Init) !void {
    var server = try zmux.Server.init(init.gpa, init.io, "/tmp/zmux.sock", 60);
    defer server.deinit();
    try server.run();
}
```

Every stateful entry point takes a `std.Io` after the allocator: `zmux.Server.init(gpa, io, socket_path, idle_timeout_seconds)`, `zmux.NativeSession.create(gpa, io, options)`, and `zmux.SessionManager.init(gpa, io, event_sink)`. The allocator must be thread-safe and outlive `Server.deinit`. Use a thread-safe `Io` such as `std.Io.Threaded` (`std.process.Init.io`).

Top-level Zig modules:

| Module | Role |
|--------|------|
| `zmux.server` | UNIX-socket JSON-RPC 2.0 server, peer auth, 39 RPC handlers |
| `zmux.daemon` | `zmuxd` entry point and `flock(2)` startup lock |
| `zmux.cli` | Unified `zmux` CLI, built-in `zmux mcp`, `zmux ssh`, and `zmux doctor` |
| `zmux.connect` | Interactive attach runtime (raw mode, `SIGWINCH`, detach chords) |
| `zmux.mux` | Session, window, pane, split/zoom layout, metadata, client, and key state |
| `zmux.native` | Per-pane PTY runtime, VT bridge, asciicast recorder, condition waits |
| `zmux.vt` | Pure-Zig VT100/xterm/ECMA-48/OSC terminal state engine |
| `zmux.reactor` | Zero-poll OS reactor (`kqueue` on macOS, `epoll` + `pidfd` on Linux) |
| `zmux.pty` | Low-level `openpty(3)` and manual fork/exec PTY child spawning |
| `zmux.protocol` | JSON-RPC 2.0 framing, nesting bounds, error kinds, version |
| `zmux.buffer` | Bounded scrollback ring buffer with monotonic offsets |
| `zmux.foreground` | Foreground-process detection on macOS (`proc_pidinfo`) and Linux (`/proc`) |
| `zmux.c_api` | `libzmux` C99 ABI (`include/zmux.h`) for scrollback, client, and VT handles |

### Embedding via C99 (`libzmux.a` + `include/zmux.h`)

Link against `zig-out/lib/libzmux.a` and include `zig-out/include/zmux.h` to embed scrollback buffers, authenticated UNIX-socket JSON-RPC clients, and the pure-Zig VT terminal engine in C, Swift, Rust, or Go. See [`test/c_api/smoke.c`](test/c_api/smoke.c).

## Protocol

`zmux` speaks JSON-RPC 2.0 over a newline-delimited UNIX-domain socket. The complete machine-readable contract lives in [`protocol/openrpc.json`](protocol/openrpc.json) (39 methods, 13 notifications, 61 schemas, 11 error kinds). Request and response fields use camelCase, and notification params use snake_case.

### Requests

```json
{ "jsonrpc": "2.0", "id": 1, "method": "session.create", "params": { "id": "work", "rows": 40, "cols": 120, "command": "bash" } }
```

Mutating calls that create a pane (`session.create`, `window.new`, and `pane.split`) return `{sessionId, windowId, paneId, generation}`. They merge `env` over the daemon environment by default (`clearEnv: true` replaces it, and unset `TERM` defaults to `xterm-256color`).

`client.attach` accepts `createIfMissing`, `readOnly`, `resizePolicy` (`latest`, `smallest`, `ignore`), `replayMode` (`raw`, `vt`/`ansi_restore`, `none`), and `resumeFromOffset` + `resumeGeneration` for gap-free delta reconnects. The response returns `created`, `exited`, `exitCode`, `signal`, `generation`, `replayBase64`, `replayStartOffset`, `replayEndOffset`, `replayMode`, `readOnly`, `resumed`, and `truncated`. Discard live `pane_output` bytes below `replayEndOffset` in that generation.

`session.screen` returns rendered VT state (`rows`, `cols`, `cursor`, `altScreen`, `title`, `cwd`, `promptState`, `lastCommandExitCode`, `commandSeq`, `agentStatus`, `modes`, `text`, `lines`, optional `cells`, and optional `ansiRestore`). `session.capture` supports `format` (`raw`, `plain`, `ansi`, `cells`) and returns lossy UTF-8 `text` alongside raw `textBase64`.

### Notifications (server -> client)

```json
{ "jsonrpc": "2.0", "method": "pane_output", "params": { "pane_id": "pane-1", "data_base64": "aGVsbG8=", "offset": 12, "generation": 1 } }
```

`pane_output` goes to attached connections and explicit `events.subscribe` observers (`{"panes":["*"]}` or pane IDs). Lifecycle and OSC notifications are global. Slow readers receive `pane_output_dropped` with the dropped byte count and `resume_offset`.

| Notification | Params | Sent when |
|--------------|--------|-----------|
| `pane_output` | `pane_id`, `data_base64`, `offset`, `generation` | PTY produced bytes |
| `pane_output_dropped` | `pane_id`, `dropped_bytes`, `resume_offset`, `generation` | Connection output queue hit its high-water mark |
| `pane_activity` | `pane_id`, `last_activity_ms`, `generation` | Output arrived after at least one second of silence |
| `pane_bell` | `pane_id`, `last_bell_ms`, `generation` | Pane received a `BEL` |
| `pane_title_changed` | `pane_id`, `title`, `generation` | OSC 0 or OSC 2 updated the pane title |
| `pane_cwd_changed` | `pane_id`, `cwd`, `generation` | OSC 7 reported a new working directory |
| `pane_prompt_changed` | `pane_id`, `state`, `exit_code`, `command_seq`, `generation` | OSC 133 marked a prompt or command boundary |
| `pane_status_changed` | `pane_id`, `status`, `text`, `generation` | OSC 7501/9/777 updated agent status |
| `session_exited` | `session_id`, `pid`, `exit_code`, `signal`, `generation` | Pane PTY output ended after child exit |
| `foreground_changed` | `session_id`, `pid`, `comm`, `argv`, `argv_truncated` | Pane foreground process changed |
| `pane_respawned` | `pane_id`, `generation`, `pid` | Pane acquired a new PTY child |
| `client_detached` | `client_id`, `reason` | Client detached remotely or its pane/session was removed |
| `client_switched` | `client_id`, `pane_id`, `generation`, `replay_base64`, `replay_end_offset` | Another connection switched this client to another pane |

For compatibility, `session_id` in `session_exited` and `foreground_changed` carries a pane ID.

### Errors

Requests with no `id` are notifications and receive no response. Request IDs may be strings, integers, or null. Errors include a stable `message` (such as `PaneNotFound`) and a category in `error.data.kind`. Branch on `data.kind`.

| Code | `data.kind` |
|------|-------------|
| `-32700` | `parse` |
| `-32600` | `invalid_request` |
| `-32601` | `method_not_found` |
| `-32602` | `invalid_params` |
| `-32000` | `not_found`, `terminated`, `conflict`, `limit`, `spawn_failed`, `io` |
| `-32603` | `internal` |

## Security

- Daemon-managed socket directories must be owned by the effective UID with no group or other permission bits. Missing directories are created with mode `0700` and sockets are bound with mode `0600`.
- Daemon and client authenticate the peer effective UID with `SO_PEERCRED` on Linux and `getpeereid(3)` on macOS before exchanging RPCs.
- Startup is locked with `flock(2)` on `<socket>.lock` so concurrent starters never unlink a live socket.
- `zmux-ws` enforces constant-time bearer token verification and loopback-only `Origin` checks by default.

## Platform support

| Platform | Daemon | CLI / Client | `libzmux` |
|----------|--------|--------------|-----------|
| macOS (arm64, x86_64) | ✅ (`kqueue`) | ✅ | ✅ |
| Linux (glibc, static musl) | ✅ (`epoll` + `pidfd`) | ✅ | ✅ |
| iOS | ❌ (no `fork`) | ❌ | ❌ |
| Windows | ❌ | ❌ | ❌ |

Minimum macOS deployment target is 14.0.

## Development, fuzzing, and benchmarks

```sh
zig build -Doptimize=ReleaseSafe   # build zmux, zmuxd, zmux-connect, libzmux.a
zig build test --summary all       # unit + integration + 49 fuzz corpus + C99 smoke tests
zig build fuzz -Doptimize=ReleaseSafe --fuzz=25K
zig build bench-check              # compile all 17 benchmark suites (114 benchmarks)
```

Every subsystem declares its exact Zig dependency closure in [`PACKAGE.ts`](PACKAGE.ts) and runs through Smithers Cloud ([smithers.sh/smithersai/zmux](https://smithers.sh/smithersai/zmux)) with shared read-only caching at `https://build.smithers.sh` and continuous Uphill Lighthouse backpressure audits:

```sh
mise install && export ZIG="$(mise which zig)"
smthrs ci '//...'
smthrs run //:bench
uphill --compact
smthrs test '//.smithers/...'
smthrs build //:docsSite
```

Explore the public factory portal, [Engineering Wiki](https://smithersai.github.io/zmux/wiki/), [Mythical History](https://smithersai.github.io/zmux/history/), [Lighthouse Backpressure Audit](https://smithersai.github.io/zmux/audit/), and interactive [JSON-RPC Protocol Inspector](https://smithersai.github.io/zmux/playground/).

## Acknowledgements

`zmux` borrows tmux's server-owns-the-PTY process model (`server.c`, `client.c`, `proc.c`, `spawn.c`, and `tmux.1`) while building a clean-room Zig runtime and structured JSON-RPC protocol for modern apps and agents.

## License

[MIT](LICENSE)
