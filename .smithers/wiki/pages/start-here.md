# Start here

`zmux` is a feature-minimal tmux-style PTY session multiplexer written in Zig 0.17.1 with zero external runtime dependencies. A long-lived daemon (`zmuxd`) owns sessions, windows, panes, PTYs, and bounded scrollback buffers. Clients (`zmux-connect`, desktop apps, web terminals, and coding agents) attach over a local UNIX-domain JSON-RPC 2.0 socket.

## Architecture at a glance

```text
  client A (zmux-connect / IDE / agent)  \
  client B (web terminal / dashboard)     >--> UNIX socket (JSON-RPC 2.0) --> zmuxd (src/server.zig + src/server/*)
  client C (headless CI / test harness)  /                                      |-- src/mux.zig + src/mux/* (sessions, windows, panes)
                                                                                |-- src/native.zig + src/native/* (NativeSession + reader)
                                                                                |-- src/buffer.zig + src/buffer/* (bounded scrollback)
                                                                                `-- src/pty.zig + src/foreground.zig (OS PTY and jobs)
```

Every subsystem is organized as a public root facade (`src/<module>.zig`) backed by focused internal submodules (`src/<module>/*.zig`), keeping all 84 Zig source files under 600 production lines and 24 kB for auditability and sharp incremental cache keys.

## Module ownership map

| Module | Owns |
| --- | --- |
| `src/main.zig` | Public Zig library entry point exporting `Server`, `SessionManager`, `NativeSession`, and submodules |
| `src/daemon.zig` | `zmuxd` CLI entrypoint, working directory isolation (`/`), startup lock, and signal handling |
| `src/connect.zig` | `zmux-connect` interactive CLI client, raw mode, `SIGWINCH` forwarding, and auto-spawn |
| `src/server.zig` | Multi-client UNIX-socket accept loop, peer-credential checks, RPC dispatch, and slow-client backpressure |
| `src/mux.zig` | Session, window, pane, logical client, key binding, and tmux-like command state machine |
| `src/native.zig` | Per-pane runtime combining `Pty`, `ScrollbackBuffer`, `foreground.Tracker`, and event fan-out |
| `src/pty.zig` | POSIX PTY allocation, child spawn, `TIOCSWINSZ` resize, and SIGHUP/SIGTERM/SIGKILL teardown |
| `src/foreground.zig` | Foreground process group inspection on macOS (`proc_pidinfo`) and Linux (`/proc`) |
| `src/buffer.zig` | Bounded scrollback ring buffer with monotonic byte offsets and generation tracking |
| `src/protocol.zig` | JSON-RPC 2.0 schemas, nesting/node bounds, error kinds, and base64 framing helpers |
| `src/rpc_line_reader.zig` | Bounded newline-delimited frame reader handling partial reads, `EINTR`, and `EAGAIN` |
| `src/socket_path.zig` | Canonical socket path resolution and `sun_path` validation shared by daemon and client |
| `src/sys.zig` | POSIX syscall wrappers for descriptors, `AF_UNIX`, peer credentials, and monotonic clocks |
| `src/log.zig` | Structured JSON logger for daemon and client diagnostics |

## Next pages

- Read [PTY and process lifecycle](pty-and-process-lifecycle.md) for OS process group and signal invariants.
- Read [JSON-RPC protocol and framing](protocol-and-framing.md) for the v0.4.0 wire contract.
- Read [Smithers Cloud factory, object store, and trust model](factory-and-trust-model.md) to work through `smithers.sh/smithersai/zmux`.
