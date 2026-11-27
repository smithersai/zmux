# JSON-RPC protocol and framing

Clients and the `zmuxd` daemon exchange newline-delimited JSON-RPC 2.0 messages over a local UNIX domain socket. Framing lives in `src/rpc_line_reader.zig`, protocol types live in `src/protocol.zig`, and the reference CLI client lives in `src/connect.zig`.

## Bounded framing invariants

- Every incoming frame is bounded in length by `src/rpc_line_reader.zig` so an untrusted or buggy local client cannot cause unbounded allocation.
- Partial reads, short writes, `EINTR`, `EAGAIN`, and Linux `POLL.HUP` without `POLL.IN` during EOF draining are handled explicitly without dropping tail frames.
- `src/protocol.zig` bounds JSON nesting depth and node count before full parsing and rejects corrupt base64 payloads on fast paths.

## v0.4.0 wire contract decisions (D1 to D6)

`CHANGELOG.md` and `src/protocol.zig` codify six breaking hardening decisions:

1. **D1 (Scoped output delivery):** `pane_output` notifications go only to attached or explicitly subscribed connections (`events.subscribe` with specific pane IDs or `["*"]`). Every output frame carries `offset` and `generation`. Slow consumers receive `pane_output_dropped` with `dropped_bytes` and `resume_offset`.
2. **D2 (Strict JSON-RPC errors):** Malformed JSON returns `-32700`. Domain errors return `-32000` with structured `data.kind`. Notifications (requests with no `id`) execute silently and emit no response frame.
3. **D3 (Environment merge):** Spawn methods merge `env` over the daemon environment unless `clearEnv: true` is passed. Unset `TERM` defaults to `xterm-256color`.
4. **D4 (Atomic attach and replay):** `client.attach` accepts `createIfMissing` to create and attach atomically. Responses carry `created`, `exited`, `exitCode`, `signal`, `generation`, `replayStartOffset`, `replayEndOffset`, and `replayBase64`.
5. **D5 (Unique session names):** Session names are unique. Exact IDs take precedence over session names when resolving targets.
6. **D6 (Socket path normalization):** CLI entrypoints resolve relative socket paths against the working directory (`src/socket_path.zig`), while library callers must supply an absolute path.

## Method families

- Daemon control: `daemon.ping`, `daemon.shutdown`, `mux.snapshot`
- Sessions: `session.{create,info,list,terminate,resize,capture,send,sendKey,rename}`
- Windows and panes: `window.{new,select,rename}`, `pane.{split,select,rename,respawn}`
- Clients and events: `client.{attach,detach,switch,list}`, `events.subscribe`
- Key bindings and commands: `key.{bind,dispatch,list}`, `command.exec` (`split-window`, `new-window`, `respawn-pane`)

You can validate frames interactively using the [Protocol Inspector](https://smithersai.github.io/zmux/playground/) or the `playground/protocol` view on `smithers.sh/smithersai/zmux`.
