# PTY and process lifecycle

`zmux` treats every pane as a real POSIX pseudo-terminal owned by the daemon process. The lifecycle spans `src/pty.zig`, `src/foreground.zig`, `src/sys.zig`, and `src/native.zig`.

## PTY allocation and descriptor hygiene

- `src/pty.zig` allocates a master/slave PTY pair with `O_CLOEXEC` enforced so descriptors never leak into unrelated child processes spawned concurrently in the daemon.
- Before `exec`, child setup creates a new session (`setsid`), establishes the slave PTY as the controlling terminal (`TIOCSCTTY`), configures `TERM` (defaulting to `xterm-256color` under Decision D3), and merges or clears environment variables according to `clearEnv`.
- Resize requests issue `TIOCSWINSZ` against the master descriptor while guarding against closed or terminated handles.

## Signal escalation ladder

Terminating or respawning a pane must clean up both the shell and any foreground job running in its own process group.

1. `zmux` sends `SIGHUP` and `SIGCONT` to both the recorded foreground process group and the shell process group so interactive jobs receive hangup handlers cleanly.
2. After a 100 ms grace window, surviving groups receive `SIGTERM`.
3. At the final deadline, any stubborn survivors receive `SIGKILL`.
4. Wait status decoding masks raw waitpid bits cleanly to distinguish normal exit codes from terminating signals.

Even when a pane's shell dies unexpectedly (for example `SIGKILL` from outside `zmux`), `src/native.zig` tracks the last observed foreground process group and ensures `stopForOwnerRelease()` terminates orphaned foreground jobs rather than leaving background processes behind.

## Foreground process detection

`src/foreground.zig` polls the terminal foreground process group (`tcgetpgrp`) on a bounded cadence:

- On macOS, it inspects process metadata via Darwin `libproc` APIs.
- On Linux, it reads `/proc/<pid>/comm` and `/proc/<pid>/cmdline` with bounded buffers and explicit `argv_truncated` reporting.
- The initial shell spawned with the pane acts as the baseline and emits no spurious `foreground_changed` event. Returning from a foreground command back to the shell emits a clean `foreground_changed` notification.

## Stream finalization and slow sinks

When a child exits while output still sits in the kernel PTY buffer, `src/native.zig` drains buffered bytes through the scrollback ring and event sink before emitting the final `session_exited` event. Re-entrant sink barriers guarantee contiguous monotonic offsets and prevent use-after-free during concurrent client detach or pane teardown.
