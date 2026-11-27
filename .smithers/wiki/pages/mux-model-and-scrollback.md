# Mux model and scrollback replay

`src/mux.zig` owns the logical multiplexer hierarchy (sessions, windows, panes, attached clients, key bindings, and commands), while `src/buffer.zig` owns the bounded per-pane scrollback ring buffer.

## Hierarchy and identity

- A **session** owns one or more **windows**, each of which owns one or more **panes** arranged in a split layout.
- Each pane wraps a reference-counted `NativeSession` (`src/native.zig`) so concurrent RPC handlers, output streaming, and teardown never race on freeing a pane's PTY state.
- Session names are unique (Decision D5). When an RPC target matches both a session ID and a session name, exact IDs take precedence.
- `mux.snapshot` returns the full server-owned tree of sessions, windows, panes, attached clients, key bindings, alerts (activity, bell, exit), and respawn generations.

## Bounded scrollback ring buffer

`src/buffer.zig` stores recent terminal bytes in a fixed-capacity ring buffer with monotonic byte offsets:

- `append` advances the logical end offset and drops the oldest bytes when capacity is reached, advancing `startOffset` cleanly.
- Every `pane.respawn` increments the pane's `generation` counter so clients distinguish new process output from prior runs.
- On `client.attach`, the daemon returns `replayStartOffset`, `replayEndOffset`, `generation`, and `replayBase64`. Subsequent `pane_output` notifications resume seamlessly at `replayEndOffset` with zero gaps and zero duplicates.
- `session.capture` returns both UTF-8-sanitized `text` and exact raw bytes in `textBase64`.

## Multi-client attach and key dispatch

- Multiple logical clients (`client.attach`) can view and send input to the same pane simultaneously.
- Detached clients receive `client_detached` with the reason, and remote switches notify the owning connection with `client_switched`.
- `key.bind` validates command strings through `parseCommandLine` up front, rejecting unknown commands with `error.InvalidParams` rather than failing later at dispatch time.
- `command.exec` implements `split-window`, `new-window`, and `respawn-pane` cleanly inside the server model.
