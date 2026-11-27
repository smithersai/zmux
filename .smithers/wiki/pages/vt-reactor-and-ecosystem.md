# VT engine, OS reactor, CLI, MCP, and SDK ecosystem

Starting in v0.5.0, `zmux` pairs its hardened PTY session daemon with a pure-Zig terminal state engine, a zero-poll OS event reactor, a unified CLI with built-in MCP and SSH support, a canonical OpenRPC specification, and zero-dependency TypeScript, Python, and C99 SDKs.

## Pure-Zig VT100/xterm/OSC state engine (`src/vt/`)

Every `NativeSession` feeds raw PTY output simultaneously into its byte-level `ScrollbackBuffer` and an embedded `vt.Terminal` state machine (`src/vt/terminal.zig`, `src/native/vt_bridge.zig`). Keeping the VT engine pure Zig preserves zero external dependencies while unlocking four capabilities:

- **Structured screen snapshots (`session.screen`)**: returns cursor position, terminal modes, OSC metadata, clean plain text, optional per-cell attribute matrices, and optional `ansiRestore` sequences.
- **Lossless TUI reattach (`replayMode: "vt"`)**: clients attaching to full-screen TUIs (`vim`, `htop`, `claude`) receive a compact synthesized ANSI restore sequence instead of replaying raw historical scrollback.
- **OSC semantic tracking (`src/vt/osc.zig`)**: extracts OSC 0/2 window titles, OSC 7 working directories (`file://` URIs), OSC 52 clipboard updates, OSC 133 shell prompt/command boundaries, and OSC 7501/9/777 agent status transitions, emitting `pane_title_changed`, `pane_cwd_changed`, `pane_prompt_changed`, and `pane_status_changed` push notifications.
- **Formatted capture (`session.capture`)**: supports `raw` (v0.4.0 default), `plain`, `ansi`, and `cells`.

## Zero-poll OS event reactor (`src/reactor/`)

`src/reactor.zig` wraps `kqueue(2)` on macOS (`src/reactor/kqueue.zig`) and `epoll(7)` + `eventfd(2)` + `pidfd_open(2)` on Linux (`src/reactor/epoll.zig`). `src/native/reader.zig` uses the reactor to multiplex PTY readability, cross-thread shutdown wakeups, and kernel-level process exit notifications (`EVFILT_PROC` `NOTE_EXIT` on macOS, `pidfd` on Linux), removing the legacy 25 ms Darwin exit-polling loop.

## Unified `zmux` CLI, MCP server, and SSH attach (`src/cli/`)

`zig-out/bin/zmux` is the primary user and agent entrypoint. It auto-spawns `zmuxd` by default (`--no-spawn` to disable) and exposes interactive verbs (`attach`, `ssh`), scripting verbs (`new`, `ls`, `run`/`exec`, `send`, `screen`, `capture`/`tail`, `wait`, `signal`, `split`, `close`, `kill`, `rename`, `events`, `record`, `shutdown`), diagnostics (`doctor`), and a built-in zero-dependency stdio MCP server (`zmux mcp`) with 9 agent tools (`src/cli/mcp.zig`, `src/cli/mcp_tools.zig`).

## OpenRPC 1.3.2, SDKs, and `libzmux` C99 ABI

- **Canonical wire contract (`protocol/openrpc.json`)**: documents all 39 JSON-RPC methods, 13 notifications, 61 schemas, and 11 error kinds, cross-checked against `src/server/*.zig` and `src/protocol.zig` by `protocol/validate-spec.mjs`.
- **TypeScript / Bun / Node SDK (`sdk/ts/`, `@smithers/zmux`)**: zero-dependency `ZmuxClient`, `AttachedPane` offset/generation reconciler, `@smithers/zmux/xterm` web terminal adapter, and authenticated `zmux-ws` WebSocket + HTTP `/rpc` + SSE `/events` bridge with strict Origin verification.
- **Python 3.10+ SDK (`sdk/python/`)**: zero-dependency sync (`ZmuxClient`) and `asyncio` (`AsyncZmuxClient`) clients with `AttachedPane` stream helpers and byte-exact socket-path parity.
- **C99 static library (`include/zmux.h`, `src/c_api/`, `libzmux.a`)**: exposes opaque handles for `zmux_scrollback_t`, `zmux_client_t`, and `zmux_vt_t` for Swift, Rust, Go, and C host embeddings.
