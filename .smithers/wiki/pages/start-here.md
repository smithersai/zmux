# Start here

`zmux` is a headless tmux-style PTY session multiplexer and terminal intelligence daemon written in Zig 0.17.1 with zero external runtime dependencies. A long-lived daemon (`zmuxd`) owns sessions, windows, panes, PTYs, a pure-Zig VT100/OSC screen engine, and bounded scrollback buffers. Clients (`zmux`, `zmux-connect`, desktop apps, web terminals, and coding agents via JSON-RPC, MCP, or official TS/Python/C99 SDKs) attach over a local UNIX-domain JSON-RPC 2.0 socket.

## Architecture at a glance

```text
  client A (zmux CLI / MCP / SSH)         \
  client B (TS / Python / C99 / xterm.js)  >--> UNIX socket (JSON-RPC 2.0) --> zmuxd (src/server.zig + src/server/*)
  client C (headless CI / agent runtime)  /                                      |-- src/mux.zig + src/mux/* (sessions, windows, panes)
                                                                                 |-- src/native.zig + src/vt.zig (NativeSession + VT engine)
                                                                                 |-- src/reactor.zig (kqueue / epoll zero-poll loop)
                                                                                 |-- src/buffer.zig + src/buffer/* (bounded scrollback)
                                                                                 `-- src/pty.zig + src/foreground.zig (OS PTY and jobs)
```

Every subsystem is organized as a public root facade (`src/<module>.zig`) backed by focused internal submodules (`src/<module>/*.zig`), keeping all Zig source files under 600 production lines and 24 kB for auditability and sharp incremental cache keys.

## Module ownership map

| Module | Owns |
| --- | --- |
| `src/main.zig` | Public Zig library entry point exporting `Server`, `SessionManager`, `NativeSession`, `vt`, `reactor`, `cli`, `c_api`, and submodules |
| `src/cli.zig` | Unified `zmux` CLI with auto-spawn default, 18 verbs, built-in `zmux mcp` server, `zmux ssh`, and `zmux doctor` |
| `src/daemon.zig` | `zmuxd` CLI entrypoint, working directory isolation (`/`), startup lock, and signal handling |
| `src/connect.zig` | `zmux-connect` interactive CLI client, raw mode, `SIGWINCH` forwarding, and auto-spawn |
| `src/server.zig` | Multi-client UNIX-socket accept loop, peer-credential checks, 39 RPC handlers, and slow-client backpressure |
| `src/mux.zig` | Session, window, pane, layout split/zoom, metadata, logical client, key binding, and command state machine |
| `src/native.zig` | Per-pane runtime combining `Pty`, `vt.Terminal`, `ScrollbackBuffer`, `foreground.Tracker`, asciicast recorder, and waits |
| `src/vt.zig` | Zero-dependency pure-Zig VT100/xterm/ECMA-48/OSC terminal state engine and ANSI restore serializer |
| `src/reactor.zig` | Zero-poll OS event reactor (`kqueue` `EVFILT_PROC` on macOS, `epoll` + `eventfd` + `pidfd` on Linux) |
| `src/pty.zig` | POSIX PTY allocation, child spawn, `TIOCSWINSZ` resize, and SIGHUP/SIGTERM/SIGKILL teardown |
| `src/foreground.zig` | Foreground process group inspection on macOS (`proc_pidinfo`) and Linux (`/proc`) |
| `src/buffer.zig` | Bounded scrollback ring buffer with monotonic byte offsets and generation tracking |
| `src/protocol.zig` | JSON-RPC 2.0 schemas, nesting/node bounds, error kinds, and base64 framing helpers |
| `src/rpc_line_reader.zig` | Bounded newline-delimited frame reader handling partial reads, `EINTR`, and `EAGAIN` |
| `src/socket_path.zig` | Canonical socket path resolution and `sun_path` validation shared by daemon and client |
| `src/c_api.zig` | Embeddable `libzmux` C99 ABI (`include/zmux.h`) for scrollback, JSON-RPC client, and VT state |
| `src/sys.zig` | POSIX syscall wrappers for descriptors, `AF_UNIX`, peer credentials, and monotonic clocks |
| `src/log.zig` | Structured JSON logger for daemon and client diagnostics |

## Next pages

- Read [VT engine, OS reactor, CLI, MCP, and SDK ecosystem](vt-reactor-and-ecosystem.md) for v0.5.0 terminal intelligence, MCP, and SDKs.
- Read [PTY and process lifecycle](pty-and-process-lifecycle.md) for OS process group and signal invariants.
- Read [JSON-RPC protocol and framing](protocol-and-framing.md) for the wire contract and OpenRPC 1.3.2 schema.
- Read [Smithers Cloud factory, object store, and trust model](factory-and-trust-model.md) to work through `smithers.sh/smithersai/zmux`.
