const std = @import("std");
const builtin = @import("builtin");

const buffer = @import("buffer.zig");
const foreground = @import("foreground.zig");
const pty = @import("pty.zig");

pub const EnvMode = pty.EnvMode;
const protocol = @import("protocol.zig");
const sys = @import("sys.zig");

/// Decoded child exit: exactly one of the fields is set for a reaped child,
/// both null when the status was unavailable.
pub const ExitInfo = struct { exit_code: ?u32, signal: ?u32 };

/// Budget for one `send`/`sendKey`/`writeInput` call.
pub const default_input_deadline_ms: i64 = 2000;

/// How long the reader waits, idle, for more output or EOF after the child
/// exits while a descendant still holds the PTY slave open. Output that is
/// already readable when this expires is still drained (see
/// `exit_drain_max_bytes`), so `session_exited` follows the last buffered
/// byte, not a timer.
pub const exit_drain_grace_ms: i64 = 250;

/// Bound on the output drained after the idle wait ended (the grace expired
/// or the owner asked the reader to stop). It is far larger than any kernel
/// PTY buffer, so everything that was buffered when the child exited is
/// delivered; a descendant that keeps writing forever cannot postpone
/// `session_exited` indefinitely.
pub const exit_drain_max_bytes: usize = 1024 * 1024;

/// `pane_activity` fires on the idle-to-active edge: output after at least
/// this long without any.
pub const activity_idle_ms: i64 = 1000;

/// Extra lookups (with doubling backoff) for a foreground group whose
/// process info could not be read, before the fallback form is accepted.
const foreground_degraded_retries: u8 = 4;

/// Budget `terminate` gives SIGHUP/SIGTERM before escalating to SIGKILL.
pub const terminate_grace_ms: i64 = 300;

/// How long SIGHUP gets to work alone before SIGTERM follows. A SIGTERM sent
/// together with the SIGHUP would kill a job before its HUP handler ran.
pub const hangup_grace_ms: i64 = 100;

/// After SIGKILL the reap normally completes within milliseconds. This bounds
/// the wait so an unkillable child (uninterruptible I/O) cannot hang shutdown.
const kill_reap_budget_ms: i64 = 5000;

/// Test seam: when false, reader threads skip foreground-process polling,
/// the only reader-side use of the session allocator. Allocation-failure
/// tests disable it so their failure indices do not depend on scheduling.
pub var foreground_check_enabled: std.atomic.Value(bool) = .init(true);

/// Test seam: called with the child PID right before the reader thread is
/// spawned; an error is reported as if `std.Thread.spawn` had failed.
pub var spawn_reader_hook: ?*const fn (child_pid: std.posix.pid_t) std.Thread.SpawnError!void = null;

/// Number of sessions fully torn down. Test seam for teardown that finishes
/// on a detached reader thread.
pub var teardown_count: std.atomic.Value(usize) = .init(0);

pub const NativeSessionState = enum {
    creating,
    running,
    terminated,

    pub fn label(self: NativeSessionState) []const u8 {
        return @tagName(self);
    }

    pub fn canTransition(self: NativeSessionState, next: NativeSessionState) bool {
        return switch (self) {
            .creating => next == .running or next == .terminated,
            .running => next == .terminated,
            .terminated => false,
        };
    }
};

pub const NativeSessionOptions = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    /// How `env` combines with the daemon environment. See `pty.EnvMode`.
    env_mode: pty.EnvMode = .merge,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,
    event_sink: ?EventSink = null,
    /// Process generation of this pane, stamped on every event. Fixed at
    /// create time; a respawn creates a new session with the next value.
    generation: u64 = 0,
};

pub const Event = union(enum) {
    foreground_changed: protocol.ForegroundChangedParams,
    session_exited: protocol.SessionExitedParams,
    pane_output: PaneOutputEvent,
    pane_activity: PaneActivityEvent,
    pane_bell: PaneBellEvent,
};

pub const PaneOutputEvent = struct {
    pane_id: []const u8,
    data: []const u8,
    /// Stream offset of `data[0]`.
    offset: u64,
    generation: u64,
};

pub const PaneActivityEvent = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
    generation: u64,
};

pub const PaneBellEvent = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
    generation: u64,
};

pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) void,
};

/// A single PTY-backed shell with bounded scrollback and a background reader
/// thread. Reference counted: `create` returns one reference; `release` (or
/// `destroy`) drops it and the last release terminates the child.
///
/// `io` supplies the mutex, clock, and sleep primitives. The reader runs on a
/// dedicated `std.Thread` doing `poll(2)`/`read(2)` on the PTY master, so any
/// `std.Io` implementation whose `Mutex`, `Condition`, and `sleep` are
/// thread-safe works (for example `std.Io.Threaded`).
///
/// Lifecycle. Two facts are tracked separately: the PTY reaching EOF and the
/// child being reaped. Only the reap (`waitpid` returning a status or
/// `ECHILD`) moves the session to `terminated`; a child that closes its
/// terminal and keeps running stays `running`. The reader thread is the only
/// emitter of events. After the child is reaped it drains the PTY to EOF.
/// When a descendant holds the slave open it waits at most
/// `exit_drain_grace_ms` for more, then drains whatever is still immediately
/// readable. Then it emits `session_exited` exactly once, closes the master,
/// and returns.
///
/// "Process reaped" and "stream finalized" are therefore different moments:
/// `exitInfo` is set at the reap, while output may still be in flight.
/// `isStreamFinalized` turns true only once the reader has delivered the
/// last byte and `session_exited`; scrollback is complete from then on and
/// stays readable until the session is destroyed.
///
/// Lock order: `input_mutex` before `mutex`; `pty.Pty.wait_mutex` is a leaf.
pub const NativeSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Guards state, exit status, title, scrollback, the sink and `in_flight`.
    mutex: std.Io.Mutex = .init,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    id: []u8,
    title_value: []u8,
    shell_value: ?[]u8,
    cwd_value: ?[]u8,
    handle: pty.Pty,
    scrollback: buffer.ScrollbackBuffer,
    state_value: NativeSessionState = .creating,
    exit_status: ?u32 = null,
    /// Undecoded wait status, kept for `exitInfo`.
    raw_exit_status: ?u32 = null,
    generation_value: u64 = 0,

    event_sink: ?EventSink = null,
    /// Sink callbacks currently executing. `clearEventSink` waits for zero.
    in_flight: u32 = 0,
    emit_idle: std.Io.Condition = .init,

    /// Serializes `send`/`sendKey`/`writeInput` (so text+Enter is atomic and
    /// concurrent inputs never interleave) and the reader's close of the
    /// master against in-flight writes.
    input_mutex: std.Io.Mutex = .init,
    input_stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Monotonic time at which SIGTERM follows the SIGHUP of
    /// `beginTerminate`; 0 until teardown begins.
    term_at_ms: std.atomic.Value(i64) = .init(0),
    /// `stopInput` writes one byte; blocked writers poll the read end.
    stop_pipe: [2]sys.fd_t,

    foreground_tracker: foreground.Tracker,
    next_foreground_check_ms: i64 = 0,
    /// Group whose last lookup was degraded, and how often it was polled.
    foreground_degraded_pgid: ?std.posix.pid_t = null,
    foreground_degraded_polls: u8 = 0,
    /// Monotonic time of the last PTY output; reader thread only.
    last_output_ms: ?i64 = null,

    reader_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_thread: ?std.Thread = null,
    /// Thread id of the live reader thread, 0 when none is running.
    reader_tid: std.atomic.Value(u64) = .init(0),
    reader_finished: std.atomic.Value(bool) = .init(false),
    /// Set once the child is reaped and the PTY output drain loop has exited,
    /// immediately before emitting `session_exited`.
    stream_finalized: std.atomic.Value(bool) = .init(false),
    /// Set when the last reference is dropped from inside a sink callback:
    /// the reader thread detaches and tears the session down itself.
    destroy_on_reader_exit: std.atomic.Value(bool) = .init(false),

    pub fn create(allocator: std.mem.Allocator, io: std.Io, opts: NativeSessionOptions) !*NativeSession {
        const native = try allocator.create(NativeSession);
        errdefer allocator.destroy(native);

        const id = try allocator.dupe(u8, opts.id);
        errdefer allocator.free(id);

        const native_title = try allocator.dupe(u8, opts.title orelse opts.id);
        errdefer allocator.free(native_title);

        const shell = if (opts.shell) |value| try allocator.dupe(u8, value) else null;
        errdefer if (shell) |value| allocator.free(value);

        const cwd = if (opts.cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| allocator.free(value);

        var scrollback = try buffer.ScrollbackBuffer.init(allocator, opts.scrollback_bytes);
        errdefer scrollback.deinit();

        const stop_pipe = try sys.pipeCloexec();
        errdefer {
            sys.close(stop_pipe[0]);
            sys.close(stop_pipe[1]);
        }
        try sys.setNonBlocking(stop_pipe[1]);

        const handle = try pty.Pty.spawn(allocator, io, .{
            .shell = opts.shell,
            .command = opts.command,
            .cwd = opts.cwd,
            .env = opts.env,
            .env_mode = opts.env_mode,
            .rows = opts.rows,
            .cols = opts.cols,
        });

        native.* = .{
            .allocator = allocator,
            .io = io,
            .id = id,
            .title_value = native_title,
            .shell_value = shell,
            .cwd_value = cwd,
            .handle = handle,
            .scrollback = scrollback,
            .event_sink = opts.event_sink,
            .stop_pipe = stop_pipe,
            .foreground_tracker = foreground.Tracker.init(handle.child_pid),
            .generation_value = opts.generation,
        };
        // From here the child is ours: any failure must kill and reap it, or
        // it would run on with nobody holding its PID.
        errdefer {
            native.handle.kill();
            _ = native.handle.waitBlocking(kill_reap_budget_ms);
            native.handle.close();
        }

        // Set before the reader exists, so the reader's own transition to
        // `terminated` can never be overwritten.
        native.setState(.running);
        // The shell owns the terminal at spawn: that is the baseline, not a
        // change. The first event is the first job, and a later return to
        // the shell group is reported like any other change.
        native.foreground_tracker.commit(handle.child_pid);
        if (spawn_reader_hook) |hook| try hook(handle.child_pid);
        native.reader_thread = try std.Thread.spawn(.{}, NativeSession.readerLoop, .{native});
        return native;
    }

    pub fn retain(self: *NativeSession) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *NativeSession) void {
        if (self.ref_count.fetchSub(1, .seq_cst) != 1) return;
        if (self.onReaderThread()) {
            // Dropped from inside a sink callback. Joining here would be a
            // self-join; the reader finishes the teardown once the callback
            // returns.
            self.destroy_on_reader_exit.store(true, .seq_cst);
            self.reader_stop.store(true, .seq_cst);
            return;
        }
        self.destroyInternal();
    }

    pub fn destroy(self: *NativeSession) void {
        self.release();
    }

    fn destroyInternal(self: *NativeSession) void {
        self.stopForOwnerRelease();
        self.reader_stop.store(true, .seq_cst);
        if (self.reader_thread) |thread| thread.join();
        self.freeResources();
    }

    /// Final teardown. No other thread may reference the session.
    fn freeResources(self: *NativeSession) void {
        self.handle.close();
        sys.close(self.stop_pipe[0]);
        sys.close(self.stop_pipe[1]);
        self.scrollback.deinit();
        self.allocator.free(self.id);
        self.allocator.free(self.title_value);
        if (self.shell_value) |value| self.allocator.free(value);
        if (self.cwd_value) |value| self.allocator.free(value);
        self.allocator.destroy(self);
        _ = teardown_count.fetchAdd(1, .seq_cst);
    }

    pub fn state(self: *NativeSession) NativeSessionState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state_value;
    }

    /// Every state write goes through here so the transition table is
    /// enforced, not just documented.
    fn setStateLocked(self: *NativeSession, next: NativeSessionState) void {
        if (self.state_value == next) return;
        std.debug.assert(self.state_value.canTransition(next));
        self.state_value = next;
    }

    fn setState(self: *NativeSession, next: NativeSessionState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.setStateLocked(next);
    }

    pub fn generation(self: *NativeSession) u64 {
        return self.generation_value;
    }

    pub fn isRunning(self: *NativeSession) bool {
        return self.state() == .running;
    }

    /// Null while the child has not been reaped.
    pub fn exitInfo(self: *NativeSession) ?ExitInfo {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.exitInfoLocked();
    }

    fn exitInfoLocked(self: *NativeSession) ?ExitInfo {
        if (self.state_value != .terminated) return null;
        const status = self.raw_exit_status orelse return .{ .exit_code = null, .signal = null };
        return .{
            .exit_code = if (std.posix.W.IFEXITED(status)) std.posix.W.EXITSTATUS(status) else null,
            .signal = if (std.posix.W.IFSIGNALED(status)) @backingInt(std.posix.W.TERMSIG(status)) else null,
        };
    }

    pub fn setTitle(self: *NativeSession, title: []const u8) !void {
        const owned = try self.allocator.dupe(u8, title);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.allocator.free(self.title_value);
        self.title_value = owned;
    }

    // -- Termination ------------------------------------------------------

    /// `beginTerminate` then `awaitTerminated` with `terminate_grace_ms`.
    pub fn terminate(self: *NativeSession) void {
        self.beginTerminate();
        self.awaitTerminated(sys.monotonicMs() + terminate_grace_ms);
    }

    /// Terminate the child unless it has already been reaped. A reaped
    /// child can still leave a foreground job behind (it ignored the hangup
    /// and outlived its shell); that job is terminated too.
    pub fn stopForOwnerRelease(self: *NativeSession) void {
        if (!self.handle.isReaped() or self.handle.orphanedForegroundGroup() != null) self.terminate();
    }

    /// Exit info once the PTY stream has been drained (every output byte is in
    /// scrollback). Returns null while the child is running or while the
    /// reader thread is still draining final bytes after reap.
    pub fn finalizedExitInfo(self: *NativeSession) ?ExitInfo {
        if (!self.stream_finalized.load(.seq_cst)) return null;
        return self.exitInfo();
    }

    /// True once the reader thread has finished: every byte of PTY output
    /// has been appended to scrollback and delivered, and `session_exited`
    /// (if the child was reaped) has been emitted. `exitInfo` can be set
    /// earlier, at the reap, while output is still being drained; callers
    /// that snapshot or replace an exited pane should wait for this.
    pub fn isStreamFinalized(self: *NativeSession) bool {
        return self.reader_finished.load(.seq_cst);
    }

    /// Non-blocking start of teardown: close input (waking blocked writers),
    /// then SIGHUP+SIGCONT to the terminal foreground group and the shell
    /// group, which is what a closing terminal delivers. `awaitTerminated`
    /// continues the ladder: SIGTERM to the foreground and shell groups
    /// `hangup_grace_ms` later, SIGKILL at its deadline. The reap state is
    /// refreshed first, so a child that something else already collected is
    /// never signalled by number. Once the child is reaped only a foreground
    /// job that outlived it is still signalled. Idempotent.
    ///
    /// The master is deliberately not closed here: the reader thread is
    /// polling it, and the reader closes it itself after draining the final
    /// output.
    pub fn beginTerminate(self: *NativeSession) void {
        self.stopInput();
        if (self.term_at_ms.cmpxchgStrong(0, sys.monotonicMs() + hangup_grace_ms, .seq_cst, .seq_cst) != null) return;
        _ = self.reapExited();
        self.handle.hangupForeground();
    }

    /// Reap until the monotonic `deadline_ms` (`sys.monotonicMs`). After a
    /// `beginTerminate`, SIGTERM follows the SIGHUP once `hangup_grace_ms`
    /// passed. At the deadline, and only if the child is still not reaped, escalate to
    /// SIGKILL for the foreground and shell groups and keep reaping until
    /// `waitpid` collects the child (bounded by `kill_reap_budget_ms`).
    ///
    /// The ladder does not stop when the shell is reaped while a foreground
    /// job that ignored the hangup is still alive: that job gets the same
    /// SIGTERM and, at the deadline, SIGKILL.
    ///
    /// Then give the reader thread a bounded moment to drain the final
    /// output and emit `session_exited`, so both normally precede the return.
    pub fn awaitTerminated(self: *NativeSession, deadline_ms: i64) void {
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);

        var kill_give_up_ms: ?i64 = null;
        var term_sent = false;
        while (true) {
            const reaped = self.reapIsDone();
            // SIGKILL is the last step for a job that outlived its shell;
            // there is nothing of it to reap here.
            if (reaped and (kill_give_up_ms != null or self.handle.orphanedForegroundGroup() == null)) break;
            const now = sys.monotonicMs();
            const term_at = self.term_at_ms.load(.seq_cst);
            if (!term_sent and term_at != 0 and now >= @min(term_at, deadline_ms)) {
                term_sent = true;
                self.handle.terminate();
            }
            if (kill_give_up_ms) |give_up| {
                if (now >= give_up) {
                    std.log.warn("zmux-native: child {d} not reaped {d} ms after SIGKILL", .{ self.handle.child_pid, kill_reap_budget_ms });
                    return;
                }
            } else if (now >= deadline_ms) {
                self.handle.kill();
                kill_give_up_ms = now + kill_reap_budget_ms;
            }
            self.sleepMs(if (kill_give_up_ms != null) 2 else 5);
        }

        if (self.onReaderThread()) return;
        const reader_deadline = sys.monotonicMs() + exit_drain_grace_ms + 150;
        while (!self.reader_finished.load(.seq_cst) and sys.monotonicMs() < reader_deadline) {
            self.sleepMs(2);
        }
    }

    /// Record the child's exit status if it has exited. Returns the raw wait
    /// status when one is available. Never emits `session_exited`: the reader
    /// thread does, after draining the PTY.
    pub fn reapExited(self: *NativeSession) ?u32 {
        switch (self.handle.reap()) {
            .running => return null,
            // The reap flag and the status come from one locked read, so a
            // caller racing the thread that collected the child publishes
            // the same status, never a bare "terminated".
            .exited => |status| {
                self.markTerminated(status);
                return status;
            },
        }
    }

    /// `reapExited`, reporting whether the child has been reaped at all
    /// (with or without a status).
    fn reapIsDone(self: *NativeSession) bool {
        switch (self.handle.reap()) {
            .running => return false,
            .exited => |status| {
                self.markTerminated(status);
                return true;
            },
        }
    }

    /// Only called once `waitpid` returned a status or `ECHILD`.
    fn markTerminated(self: *NativeSession, status: ?u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state_value == .terminated) return;
        self.setStateLocked(.terminated);
        self.exit_status = if (status) |value| decodedExitStatus(value) else null;
        self.raw_exit_status = status;
    }

    // -- Input ------------------------------------------------------------

    /// Write `text`, then Enter when `enter` is set, as one atomic input.
    /// The `default_input_deadline_ms` budget starts when the call does, so
    /// time spent queued behind another writer counts against it.
    pub fn send(self: *NativeSession, text: []const u8, enter: bool) !void {
        const deadline_ms = sys.monotonicMs() + default_input_deadline_ms;
        self.input_mutex.lockUncancelable(self.io);
        defer self.input_mutex.unlock(self.io);
        try self.admitInputLocked();
        try self.writeLocked(text, deadline_ms);
        if (enter) try self.writeLocked("\r", deadline_ms);
    }

    pub fn sendKey(self: *NativeSession, key: []const u8) !void {
        const sequence = keySequence(key) orelse return error.UnknownKey;
        try self.writeInput(sequence);
    }

    /// Budgeted like `send`: queueing time counts.
    pub fn writeInput(self: *NativeSession, bytes: []const u8) !void {
        const deadline_ms = sys.monotonicMs() + default_input_deadline_ms;
        self.input_mutex.lockUncancelable(self.io);
        defer self.input_mutex.unlock(self.io);
        try self.admitInputLocked();
        try self.writeLocked(bytes, deadline_ms);
    }

    fn admitInputLocked(self: *NativeSession) error{ SessionTerminated, InputClosed }!void {
        if (!self.isRunning()) return error.SessionTerminated;
        if (self.input_stopped.load(.seq_cst)) return error.InputClosed;
    }

    fn writeLocked(self: *NativeSession, bytes: []const u8, deadline_ms: i64) !void {
        self.handle.write(bytes, deadline_ms, self.stop_pipe[0]) catch |err| {
            // The terminal rejects input once the child is gone; report that
            // as the session's state, not as a transport error.
            if (err == error.InputOutput or err == error.BrokenPipe) {
                _ = self.reapExited();
                if (!self.isRunning()) return error.SessionTerminated;
            }
            return err;
        };
    }

    /// Wakes blocked writers (they return `InputClosed`). All later
    /// send/sendKey/writeInput calls return `InputClosed`. Idempotent and
    /// non-blocking.
    pub fn stopInput(self: *NativeSession) void {
        if (self.input_stopped.swap(true, .seq_cst)) return;
        _ = sys.write(self.stop_pipe[1], "x") catch {};
    }

    pub fn resize(self: *NativeSession, cols: u16, rows: u16) !void {
        if (self.state() == .terminated) return error.SessionTerminated;
        try self.handle.resize(cols, rows);
    }

    // -- Scrollback -------------------------------------------------------

    pub fn scrollbackTail(self: *NativeSession, allocator: std.mem.Allocator, max_bytes: usize) !buffer.Tail {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.snapshotTail(allocator, max_bytes);
    }

    pub fn captureBounded(self: *NativeSession, allocator: std.mem.Allocator, lines: usize, max_bytes: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.captureLastLinesBounded(allocator, lines, max_bytes);
    }

    pub fn capture(self: *NativeSession, allocator: std.mem.Allocator, lines: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.captureLastLines(allocator, lines);
    }

    pub fn scrollbackSnapshot(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.snapshot(allocator);
    }

    pub fn infoJson(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.print(
            "{{\"id\":{f},\"title\":{f},\"pid\":{},\"state\":{f},\"cwd\":",
            .{
                std.json.fmt(self.id, .{}),
                std.json.fmt(self.title_value, .{}),
                self.handle.child_pid,
                std.json.fmt(self.state_value.label(), .{}),
            },
        );
        if (self.cwd_value) |cwd| {
            try out.writer.print("{f}", .{std.json.fmt(cwd, .{})});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"shell\":");
        if (self.shell_value) |shell| {
            try out.writer.print("{f}", .{std.json.fmt(shell, .{})});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.print(",\"scrollbackBytes\":{},\"exitStatus\":", .{self.scrollback.len});
        try writeOptionalU32(&out.writer, self.exit_status);
        // `exitStatus` conflates exit code and signal number and is kept for
        // existing clients; `exitCode` and `signal` separate them.
        const exit: ExitInfo = self.exitInfoLocked() orelse .{ .exit_code = null, .signal = null };
        try out.writer.writeAll(",\"exitCode\":");
        try writeOptionalU32(&out.writer, exit.exit_code);
        try out.writer.writeAll(",\"signal\":");
        try writeOptionalU32(&out.writer, exit.signal);
        try out.writer.print(",\"generation\":{}}}", .{self.generation_value});
        return out.toOwnedSlice();
    }

    fn writeOptionalU32(writer: *std.Io.Writer, value: ?u32) !void {
        if (value) |v| {
            try writer.print("{}", .{v});
        } else {
            try writer.writeAll("null");
        }
    }

    // -- Reader thread ----------------------------------------------------

    fn currentThreadTag() u64 {
        // Thread ids are never 0 on the supported platforms; 0 means "none".
        return @intCast(std.Thread.getCurrentId());
    }

    fn onReaderThread(self: *NativeSession) bool {
        return self.reader_tid.load(.seq_cst) == currentThreadTag();
    }

    fn readerLoop(self: *NativeSession) void {
        self.reader_tid.store(currentThreadTag(), .seq_cst);

        var read_buf: [8192]u8 = undefined;
        var pty_eof = false;
        var exit_seen_ms: ?i64 = null;
        // Bytes read after the idle wait ended; see `exit_drain_max_bytes`.
        var overtime_bytes: usize = 0;

        // The loop runs until the child is reaped and the PTY is drained.
        // `reader_stop` and the post-exit grace end only the *waiting*: data
        // that is immediately readable is still delivered, because the
        // kernel buffer holds the only copy of it.
        while (true) {
            const stopping = self.reader_stop.load(.seq_cst);
            // The last reference was dropped from inside a callback on this
            // thread: the owner is gone, deliver nothing more.
            if (stopping and self.destroy_on_reader_exit.load(.seq_cst)) break;

            if (exit_seen_ms == null and self.reapIsDone()) exit_seen_ms = self.monotonicMs();

            // With a pidfd the exit wakes the poll; without one (Darwin) a
            // short timeout bounds how late the exit is noticed.
            var timeout_ms: i32 = if (self.handle.pid_fd >= 0) 100 else 25;
            // Overtime: no more waiting, only draining what is already there.
            var overtime = false;
            if (stopping) {
                if (pty_eof) break;
                overtime = true;
            } else if (exit_seen_ms) |seen| {
                if (pty_eof) break;
                // A descendant still holds the slave open: stop waiting for
                // an EOF that may never come.
                const remaining = exit_drain_grace_ms - (self.monotonicMs() - seen);
                if (remaining <= 0) overtime = true else timeout_ms = @intCast(remaining);
            } else if (!pty_eof) {
                self.pollForegroundChange() catch {};
            }
            if (overtime) {
                if (overtime_bytes >= exit_drain_max_bytes) break;
                timeout_ms = 0;
            }

            // Negative descriptors are ignored by poll(2). After PTY EOF with
            // a live child (it closed its terminal) only the exit is awaited.
            var fds = [_]std.posix.pollfd{
                .{ .fd = if (pty_eof) -1 else self.handle.master_fd, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = if (exit_seen_ms == null) self.handle.pid_fd else -1, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&fds, timeout_ms) catch {
                if (overtime) break;
                self.sleepMs(10);
                continue;
            };
            if (ready == 0 or fds[0].revents == 0) {
                // Nothing is buffered any more: the stream is final.
                if (overtime) break;
                continue;
            }

            const n = self.handle.read(&read_buf) catch |err| switch (err) {
                error.WouldBlock => {
                    if (overtime) break;
                    continue;
                },
                // Linux reports EIO once every slave descriptor is closed.
                else => {
                    pty_eof = true;
                    continue;
                },
            };
            if (n == 0) {
                pty_eof = true;
                continue;
            }
            if (overtime) overtime_bytes += n;
            self.handleOutput(read_buf[0..n]);
        }

        self.finishReader();
    }

    fn handleOutput(self: *NativeSession, data: []const u8) void {
        // The offset is taken under the same lock as the append, so
        // consecutive events carry contiguous offsets.
        self.mutex.lockUncancelable(self.io);
        const offset = self.scrollback.endOffset();
        self.scrollback.append(data);
        self.mutex.unlock(self.io);

        _ = self.emitEvent(.{ .pane_output = .{
            .pane_id = self.id,
            .data = data,
            .offset = offset,
            .generation = self.generation_value,
        } });

        const now_ms = self.nowMs();
        const mono_ms = self.monotonicMs();
        const was_idle = if (self.last_output_ms) |last| mono_ms - last >= activity_idle_ms else true;
        self.last_output_ms = mono_ms;
        if (was_idle) {
            _ = self.emitEvent(.{ .pane_activity = .{
                .pane_id = self.id,
                .last_activity_ms = now_ms,
                .generation = self.generation_value,
            } });
        }
        if (std.mem.indexOfScalar(u8, data, 0x07) != null) {
            _ = self.emitEvent(.{ .pane_bell = .{
                .pane_id = self.id,
                .last_bell_ms = now_ms,
                .generation = self.generation_value,
            } });
        }
    }

    /// Reader epilogue: emit `session_exited` once (after every
    /// `pane_output`), release the master, and hand off or finish teardown.
    fn finishReader(self: *NativeSession) void {
        if (self.handle.isReaped()) {
            // Re-verify any remembered foreground group right at reap time so
            // a short-lived job that already exited is cleared immediately and
            // cannot match a later PID wrap on a retained exited pane.
            _ = self.handle.orphanedForegroundGroup();
            // All PTY output is now in scrollback. Flip `stream_finalized`
            // before emitting `session_exited` so a concurrent attach either
            // sees `finalizedExitInfo() == null` and receives `session_exited`,
            // or sees `finalizedExitInfo() != null` with the complete tail.
            self.stream_finalized.store(true, .seq_cst);
            const exit: ExitInfo = self.exitInfo() orelse .{ .exit_code = null, .signal = null };
            _ = self.emitEvent(.{ .session_exited = .{
                .session_id = self.id,
                .pid = self.handle.child_pid,
                .exit_code = exit.exit_code,
                .signal = exit.signal,
                .generation = self.generation_value,
            } });

            // An exited pane keeps its scrollback but not its descriptors.
            // `input_mutex` keeps the close from racing an in-flight write;
            // stopping input first wakes a writer blocked on a full queue,
            // so the lock is not held up for the rest of its deadline.
            self.stopInput();
            self.input_mutex.lockUncancelable(self.io);
            self.handle.close();
            self.input_mutex.unlock(self.io);
        }

        self.reader_tid.store(0, .seq_cst);
        self.reader_finished.store(true, .seq_cst);

        if (self.destroy_on_reader_exit.load(.seq_cst)) {
            // The owner dropped the last reference from inside a callback on
            // this thread. Nobody will join us: detach and finish teardown.
            if (self.reader_thread) |thread| thread.detach();
            self.stopForOwnerRelease();
            self.freeResources();
        }
    }

    fn pollForegroundChange(self: *NativeSession) !void {
        const now_ms = self.monotonicMs();
        if (now_ms < self.next_foreground_check_ms) return;
        self.next_foreground_check_ms = now_ms + foreground.poll_interval_ms;

        // Remember the foreground group while the shell is alive: if the
        // shell dies first, teardown still needs to reach that job.
        self.handle.captureForeground();
        if (!foreground_check_enabled.load(.seq_cst)) return;

        // Without a sink nothing can be delivered: skip the lookup and leave
        // the change uncommitted for whoever subscribes later.
        if (!self.hasEventSink()) return;
        var process = (try self.foreground_tracker.poll(self.allocator, self.io, self.handle.master_fd)) orelse return;
        defer process.deinit();

        if (process.degraded) {
            // The lookup fell back to `pid-<n>`. Report that form once per
            // group, then retry with backoff; a group whose leader stays
            // unreadable is accepted after `foreground_degraded_retries`.
            const first = self.foreground_degraded_pgid != process.pid;
            if (first) {
                self.foreground_degraded_pgid = process.pid;
                self.foreground_degraded_polls = 0;
            }
            self.foreground_degraded_polls += 1;
            if (self.foreground_degraded_polls > foreground_degraded_retries) {
                self.foreground_tracker.commit(process.pid);
                self.foreground_degraded_pgid = null;
                return;
            }
            const shift: u6 = @intCast(self.foreground_degraded_polls - 1);
            self.next_foreground_check_ms = now_ms + (foreground.poll_interval_ms << shift);
            if (!first) return;
        } else {
            self.foreground_degraded_pgid = null;
        }

        const delivered = self.emitEvent(.{ .foreground_changed = .{
            .session_id = self.id,
            .pid = process.pid,
            .comm = process.comm,
            .argv = process.argv,
            .argv_truncated = process.argv_truncated,
        } });
        // Commit only a fully resolved, delivered change, so a failed lookup
        // or an undelivered event is retried on a later poll.
        if (delivered and !process.degraded) self.foreground_tracker.commit(process.pid);
    }

    fn hasEventSink(self: *NativeSession) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.event_sink != null;
    }

    // -- Event sink -------------------------------------------------------

    /// Returns false when no sink was installed, so nothing was delivered.
    fn emitEvent(self: *NativeSession, event: Event) bool {
        self.mutex.lockUncancelable(self.io);
        const sink = self.event_sink orelse {
            self.mutex.unlock(self.io);
            return false;
        };
        // Counted before unlocking, so `clearEventSink` either sees the sink
        // already null here or waits for this callback to return.
        self.in_flight += 1;
        self.mutex.unlock(self.io);

        sink.emit(sink.context, event);

        self.mutex.lockUncancelable(self.io);
        self.in_flight -= 1;
        if (self.in_flight == 0) self.emit_idle.broadcast(self.io);
        self.mutex.unlock(self.io);
        return true;
    }

    /// Replace the sink. Passing null from any thread other than the reader
    /// also waits for in-flight callbacks, like `clearEventSink`; from inside
    /// a callback it only prevents further events.
    pub fn setEventSink(self: *NativeSession, sink: ?EventSink) void {
        const wait_for_idle = sink == null and !self.onReaderThread();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.event_sink = sink;
        if (wait_for_idle) {
            while (self.in_flight != 0) self.emit_idle.waitUncancelable(self.io, &self.mutex);
        }
    }

    /// Remove the sink and block until no callback is in flight: once this
    /// returns, the sink's context may be freed. Must not be called from the
    /// reader thread (that is, from inside a sink callback), where it would
    /// wait for itself.
    pub fn clearEventSink(self: *NativeSession) void {
        std.debug.assert(!self.onReaderThread());
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.event_sink = null;
        while (self.in_flight != 0) self.emit_idle.waitUncancelable(self.io, &self.mutex);
    }

    /// Remove the sink without waiting: no new callback starts, but one that
    /// is already running may finish after this returns. For callers that
    /// hold a lock the sink itself may take.
    pub fn dropEventSink(self: *NativeSession) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.event_sink = null;
    }

    fn nowMs(self: *NativeSession) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    fn monotonicMs(self: *NativeSession) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn sleepMs(self: *NativeSession, ms: i64) void {
        // Plain threads are never canceled; ignoring error.Canceled is safe.
        self.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }
};

pub fn decodedExitStatus(status: u32) u32 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) return @backingInt(std.posix.W.TERMSIG(status));
    return status;
}

// Single-byte control sequences for Ctrl-<letter>: C-a => 0x01 .. C-z => 0x1A.
// Stored in a container-level const so `ctrlKeySequence` can hand back a
// stable slice into read-only data rather than a dangling stack pointer.
const ctrl_key_sequences = blk: {
    var table: [26][1]u8 = undefined;
    var i: u8 = 0;
    while (i < 26) : (i += 1) table[i] = [1]u8{i + 1};
    break :blk table;
};

fn keyEql(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

// Parse tmux-style Ctrl-<letter> names ("C-a", "c-a") into their control byte.
fn ctrlKeySequence(key: []const u8) ?[]const u8 {
    if (key.len != 3) return null;
    if (key[0] != 'C' and key[0] != 'c') return null;
    if (key[1] != '-') return null;
    const c = key[2];
    if (!std.ascii.isAlphabetic(c)) return null;
    const index = std.ascii.toUpper(c) - 'A';
    return &ctrl_key_sequences[index];
}

pub fn keySequence(key: []const u8) ?[]const u8 {
    if (ctrlKeySequence(key)) |sequence| return sequence;

    if (keyEql(key, "Enter") or keyEql(key, "Return")) return "\r";
    if (keyEql(key, "Tab")) return "\t";
    if (keyEql(key, "Backspace")) return "\x7f";
    if (keyEql(key, "Escape") or keyEql(key, "Esc")) return "\x1b";
    if (keyEql(key, "Space")) return " ";
    if (keyEql(key, "ArrowUp") or keyEql(key, "Up")) return "\x1b[A";
    if (keyEql(key, "ArrowDown") or keyEql(key, "Down")) return "\x1b[B";
    if (keyEql(key, "ArrowRight") or keyEql(key, "Right")) return "\x1b[C";
    if (keyEql(key, "ArrowLeft") or keyEql(key, "Left")) return "\x1b[D";
    if (keyEql(key, "Home")) return "\x1b[H";
    if (keyEql(key, "End")) return "\x1b[F";
    if (keyEql(key, "PageUp")) return "\x1b[5~";
    if (keyEql(key, "PageDown")) return "\x1b[6~";
    if (keyEql(key, "Insert")) return "\x1b[2~";
    if (keyEql(key, "Delete")) return "\x1b[3~";
    if (keyEql(key, "F1")) return "\x1bOP";
    if (keyEql(key, "F2")) return "\x1bOQ";
    if (keyEql(key, "F3")) return "\x1bOR";
    if (keyEql(key, "F4")) return "\x1bOS";
    if (keyEql(key, "F5")) return "\x1b[15~";
    if (keyEql(key, "F6")) return "\x1b[17~";
    if (keyEql(key, "F7")) return "\x1b[18~";
    if (keyEql(key, "F8")) return "\x1b[19~";
    if (keyEql(key, "F9")) return "\x1b[20~";
    if (keyEql(key, "F10")) return "\x1b[21~";
    if (keyEql(key, "F11")) return "\x1b[23~";
    if (keyEql(key, "F12")) return "\x1b[24~";
    return null;
}

test "native session state machine keeps PTY running until termination" {
    try std.testing.expect(NativeSessionState.creating.canTransition(.running));
    try std.testing.expect(NativeSessionState.running.canTransition(.terminated));
    try std.testing.expect(!NativeSessionState.terminated.canTransition(.running));
}

test "native session key names map to terminal sequences" {
    try std.testing.expectEqualStrings("\x1b[A", keySequence("ArrowUp").?);
    try std.testing.expectEqualStrings("\r", keySequence("Enter").?);
    try std.testing.expect(keySequence("Unknown") == null);
}

test "native session key map covers ctrl, navigation, and function keys" {
    // Ctrl-<letter> control bytes.
    try std.testing.expectEqualStrings("\x01", keySequence("C-a").?);
    try std.testing.expectEqualStrings("\x03", keySequence("C-c").?);
    try std.testing.expectEqualStrings("\x04", keySequence("C-d").?);
    try std.testing.expectEqualStrings("\x1a", keySequence("C-z").?);
    try std.testing.expectEqualStrings("\x03", keySequence("c-C").?);

    // Navigation / editing keys.
    try std.testing.expectEqualStrings("\x1b[H", keySequence("Home").?);
    try std.testing.expectEqualStrings("\x1b[F", keySequence("End").?);
    try std.testing.expectEqualStrings("\x1b[5~", keySequence("PageUp").?);
    try std.testing.expectEqualStrings("\x1b[6~", keySequence("PageDown").?);
    try std.testing.expectEqualStrings("\x1b[2~", keySequence("Insert").?);
    try std.testing.expectEqualStrings("\x1b[3~", keySequence("Delete").?);
    try std.testing.expectEqualStrings(" ", keySequence("Space").?);

    // Function keys (xterm sequences).
    try std.testing.expectEqualStrings("\x1bOP", keySequence("F1").?);
    try std.testing.expectEqualStrings("\x1bOS", keySequence("F4").?);
    try std.testing.expectEqualStrings("\x1b[15~", keySequence("F5").?);
    try std.testing.expectEqualStrings("\x1b[21~", keySequence("F10").?);
    try std.testing.expectEqualStrings("\x1b[24~", keySequence("F12").?);

    // Case-insensitive matching keeps the original names working.
    try std.testing.expectEqualStrings("\r", keySequence("enter").?);
    try std.testing.expectEqualStrings("\x1b", keySequence("ESCAPE").?);

    // Unrecognized keys still return null.
    try std.testing.expect(keySequence("C-4") == null);
    try std.testing.expect(keySequence("F13") == null);
    try std.testing.expect(keySequence("Meta") == null);
}

test "decoded exit status unwraps waitpid status words" {
    try std.testing.expectEqual(@as(u32, 7), decodedExitStatus(7 << 8));
}

// ---------------------------------------------------------------------------
// Session tests. Each spawns a real child under /bin/sh.

const supported_os = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;

const EventKind = std.meta.Tag(Event);

/// Thread-safe event sink that records what the reader thread emits.
const Recorder = struct {
    mutex: std.Io.Mutex = .init,
    output: std.ArrayList(u8) = .empty,
    kinds: std.ArrayList(EventKind) = .empty,
    outputs: usize = 0,
    activity: usize = 0,
    bells: usize = 0,
    exits: usize = 0,
    exit_code: ?u32 = null,
    exit_signal: ?u32 = null,
    exit_at_ms: i64 = 0,
    expected_generation: u64 = 0,
    generation_mismatch: bool = false,
    next_offset: ?u64 = null,
    offsets_contiguous: bool = true,
    /// Sleep this long inside every pane_output callback.
    output_delay_ms: i64 = 0,
    entered: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    fn sink(self: *Recorder) EventSink {
        return .{ .context = self, .emit = Recorder.emit };
    }

    fn deinit(self: *Recorder) void {
        self.output.deinit(allocator);
        self.kinds.deinit(allocator);
    }

    fn emit(context: *anyopaque, event: Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        _ = self.entered.fetchAdd(1, .seq_cst);
        defer _ = self.completed.fetchAdd(1, .seq_cst);

        self.mutex.lockUncancelable(io);
        self.kinds.append(allocator, std.meta.activeTag(event)) catch {};
        var delay_ms: i64 = 0;
        switch (event) {
            .pane_output => |out| {
                self.outputs += 1;
                self.output.appendSlice(allocator, out.data) catch {};
                if (out.generation != self.expected_generation) self.generation_mismatch = true;
                if (self.next_offset) |expected| {
                    if (out.offset != expected) self.offsets_contiguous = false;
                }
                self.next_offset = out.offset + out.data.len;
                delay_ms = self.output_delay_ms;
            },
            .pane_activity => |activity| {
                self.activity += 1;
                if (activity.generation != self.expected_generation) self.generation_mismatch = true;
            },
            .pane_bell => |bell| {
                self.bells += 1;
                if (bell.generation != self.expected_generation) self.generation_mismatch = true;
            },
            .session_exited => |exit| {
                self.exits += 1;
                self.exit_code = exit.exit_code;
                self.exit_signal = exit.signal;
                self.exit_at_ms = sys.monotonicMs();
                if (exit.generation != self.expected_generation) self.generation_mismatch = true;
            },
            .foreground_changed => {},
        }
        self.mutex.unlock(io);
        if (delay_ms > 0) sys.sleepMs(delay_ms);
    }

    fn exitCount(self: *Recorder) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.exits;
    }

    fn waitForExit(self: *Recorder, timeout_ms: i64) !void {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (self.exitCount() == 0) {
            if (sys.monotonicMs() >= deadline) return error.TestTimedOutWaitingForExit;
            sys.sleepMs(2);
        }
    }

    fn outputContains(self: *Recorder, needle: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return std.mem.indexOf(u8, self.output.items, needle) != null;
    }

    fn waitForOutput(self: *Recorder, needle: []const u8, timeout_ms: i64) !void {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (!self.outputContains(needle)) {
            if (sys.monotonicMs() >= deadline) return error.TestTimedOutWaitingForOutput;
            sys.sleepMs(2);
        }
    }

    fn countByte(self: *Recorder, byte: u8) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return std.mem.count(u8, self.output.items, &.{byte});
    }
};

fn testCreate(rec: ?*Recorder, command: ?[]const u8, extra: struct {
    id: []const u8 = "t2",
    generation: u64 = 0,
    shell: []const u8 = "/bin/sh",
    env: ?[]const []const u8 = null,
    scrollback_bytes: usize = 1024 * 1024,
}) !*NativeSession {
    if (rec) |r| r.expected_generation = extra.generation;
    return NativeSession.create(std.testing.allocator, std.testing.io, .{
        .id = extra.id,
        .shell = extra.shell,
        .command = command,
        .env = extra.env,
        .scrollback_bytes = extra.scrollback_bytes,
        .event_sink = if (rec) |r| r.sink() else null,
        .generation = extra.generation,
    });
}

/// Zombie-aware: an exited process that nothing reaped is not running.
fn processExists(pid: std.posix.pid_t) bool {
    return pty.processRunning(pid);
}

fn waitUntilGone(pid: std.posix.pid_t, timeout_ms: i64) bool {
    const deadline = sys.monotonicMs() + timeout_ms;
    while (processExists(pid)) {
        if (sys.monotonicMs() >= deadline) return false;
        sys.sleepMs(5);
    }
    return true;
}

fn expectJsonContains(json: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, json, needle) == null) {
        std.debug.print("expected {s}\n to contain {s}\n", .{ json, needle });
        return error.TestExpectedContains;
    }
}

const Reaper = struct {
    native: *NativeSession,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(self: *Reaper) void {
        while (!self.stop.load(.seq_cst)) _ = self.native.reapExited();
    }
};

test "final output is drained before session_exited even while another thread reaps" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const total = 64 * 1024;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "head -c 65536 /dev/zero | tr '\\000' '\\001'", .{});
    defer native.destroy();

    // A reaper spinning on another thread used to win the race against the
    // reader and mark the session terminated with output still unread.
    var reaper = Reaper{ .native = native };
    const reaper_thread = try std.Thread.spawn(.{}, Reaper.run, .{&reaper});
    const waited = rec.waitForExit(15_000);
    reaper.stop.store(true, .seq_cst);
    reaper_thread.join();
    try waited;

    const snapshot = try native.scrollbackSnapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, total), std.mem.count(u8, snapshot, "\x01"));
    try std.testing.expectEqual(@as(usize, total), rec.countByte(0x01));

    rec.mutex.lockUncancelable(Recorder.io);
    defer rec.mutex.unlock(Recorder.io);
    // Exactly one exit event, ordered after every pane_output.
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
    try std.testing.expectEqual(EventKind.session_exited, rec.kinds.items[rec.kinds.items.len - 1]);
    try std.testing.expectEqual(@as(?u32, 0), rec.exit_code);
    // Offsets are contiguous and end at the scrollback's stream offset.
    try std.testing.expect(rec.offsets_contiguous);
    try std.testing.expectEqual(@as(u64, snapshot.len), rec.next_offset.?);
    try std.testing.expectEqual(snapshot.len, rec.output.items.len);
}

test "session_exited is emitted exactly once across reap, terminate and destroy" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "echo once; exit 4", .{});
    try rec.waitForExit(10_000);
    _ = native.reapExited();
    _ = native.reapExited();
    native.terminate();
    native.stopForOwnerRelease();
    native.destroy();

    try std.testing.expectEqual(@as(usize, 1), rec.exits);
    try std.testing.expectEqual(@as(?u32, 4), rec.exit_code);
    try std.testing.expectEqual(@as(?u32, null), rec.exit_signal);
}

test "a descendant holding the terminal open delays session_exited by the drain grace only" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    // The background subshell ignores the hangup sent when the session
    // leader exits and keeps the slave open as its stdout for two seconds.
    // The leader lingers briefly so the trap is installed before it exits.
    const leader_sleep_ms: i64 = 300;
    const started_at = sys.monotonicMs();
    const native = try testCreate(&rec, "(trap '' HUP; exec sleep 2) & sleep 0.3; exit 5", .{});
    defer native.destroy();

    const reap_deadline = sys.monotonicMs() + 10_000;
    while (native.exitInfo() == null) {
        try std.testing.expect(sys.monotonicMs() < reap_deadline);
        sys.sleepMs(1);
    }
    const reaped_at = sys.monotonicMs();
    try rec.waitForExit(5_000);

    // Lower bound from the spawn, not from `reaped_at`: this thread can
    // observe the reap late on a loaded machine, but the leader never exits
    // before its own sleep ends, and the grace runs after that.
    // Linux only: Darwin revokes the terminal when the session leader exits,
    // so the master can read EOF at once and no grace is spent.
    if (builtin.os.tag == .linux) {
        try std.testing.expect(rec.exit_at_ms - started_at >= leader_sleep_ms + exit_drain_grace_ms - 60);
    }
    // Upper bound: the grace, not the descendant's remaining ~1.7 s. The
    // margin absorbs scheduling delay and stays well below that.
    try std.testing.expect(rec.exit_at_ms - reaped_at <= exit_drain_grace_ms + 750);
    try std.testing.expectEqual(@as(?u32, 5), rec.exit_code);
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
}

test "PTY EOF with a live child keeps the session running and release reaps it" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    // The child closes its whole terminal and keeps running.
    const native = try testCreate(&rec, "exec sleep 100 <&- >&- 2>&-", .{});
    const pid = native.handle.child_pid;

    sys.sleepMs(400);
    try std.testing.expect(native.isRunning());
    try std.testing.expectEqual(NativeSessionState.running, native.state());
    try std.testing.expect(native.exitInfo() == null);
    try std.testing.expectEqual(@as(usize, 0), rec.exitCount());
    try std.testing.expect(processExists(pid));

    native.stopForOwnerRelease();
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(native.exitInfo().?.signal != null);
    native.destroy();

    // Killed and reaped: no zombie is left to collect.
    const rc = std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG));
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(rc));
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
}

test "terminate after a natural exit sends no signal" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "exit 0", .{});
    defer native.destroy();
    try rec.waitForExit(10_000);

    // The PID may already belong to another process: nothing may be sent.
    const kills_before = sys.kill_call_count.load(.seq_cst);
    const started = sys.monotonicMs();
    native.terminate();
    native.beginTerminate();
    native.awaitTerminated(sys.monotonicMs() + 50);
    native.stopForOwnerRelease();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));
    // No SIGKILL escalation wait either.
    try std.testing.expect(sys.monotonicMs() - started < terminate_grace_ms);
}

test "a child auto-reaped under ignored SIGCHLD terminates without escalation" {
    if (!supported_os) return error.SkipZigTest;

    var old_action: std.posix.Sigaction = undefined;
    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &ignored, &old_action);
    defer std.posix.sigaction(.CHLD, &old_action, null);

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "exit 0", .{});
    defer native.destroy();
    try rec.waitForExit(10_000);

    // waitpid reported ECHILD: terminated, with no status to decode.
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    const info = native.exitInfo().?;
    try std.testing.expect(info.exit_code == null and info.signal == null);
    try std.testing.expect(rec.exit_code == null and rec.exit_signal == null);

    const kills_before = sys.kill_call_count.load(.seq_cst);
    const started = sys.monotonicMs();
    native.terminate();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));
    try std.testing.expect(sys.monotonicMs() - started < terminate_grace_ms);
}

test "every event carries the generation fixed at create time" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "printf 'ding\\a\\n'; exit 0", .{ .generation = 7 });
    defer native.destroy();
    try rec.waitForExit(10_000);

    try std.testing.expectEqual(@as(u64, 7), native.generation());
    try std.testing.expect(!rec.generation_mismatch);
    try std.testing.expect(rec.outputs >= 1);
    try std.testing.expectEqual(@as(usize, 1), rec.activity);
    try std.testing.expect(rec.bells >= 1);
    try std.testing.expectEqual(@as(usize, 1), rec.exits);

    const info = try native.infoJson(allocator);
    defer allocator.free(info);
    try expectJsonContains(info, "\"generation\":7}");
}

test "clearEventSink returns only after the in-flight callback completes" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{ .output_delay_ms = 150 };
    defer rec.deinit();
    const native = try testCreate(&rec, "echo barrier; exec sleep 100", .{});
    defer native.destroy();

    // Wait until the reader thread is inside the (slow) callback.
    const deadline = sys.monotonicMs() + 10_000;
    while (rec.entered.load(.seq_cst) == 0) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        sys.sleepMs(1);
    }
    try std.testing.expect(rec.completed.load(.seq_cst) < rec.entered.load(.seq_cst));

    const started = sys.monotonicMs();
    native.clearEventSink();
    // The barrier held: every callback that started has finished.
    try std.testing.expectEqual(rec.entered.load(.seq_cst), rec.completed.load(.seq_cst));
    try std.testing.expect(sys.monotonicMs() - started >= 100);

    // And nothing is delivered afterwards, although output keeps arriving
    // (the terminal echoes this input back).
    const entered_after_clear = rec.entered.load(.seq_cst);
    try native.send("echoed-after-clear", true);
    sys.sleepMs(150);
    try std.testing.expectEqual(entered_after_clear, rec.entered.load(.seq_cst));
    const snapshot = try native.scrollbackSnapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "echoed-after-clear") != null);
}

test "setEventSink swaps sinks and null acts as a barrier" {
    if (!supported_os) return error.SkipZigTest;

    var first: Recorder = .{ .output_delay_ms = 80 };
    defer first.deinit();
    var second: Recorder = .{};
    defer second.deinit();
    const native = try testCreate(&first, "echo one; exec sleep 100", .{});
    defer native.destroy();
    try first.waitForOutput("one", 10_000);

    native.setEventSink(null);
    try std.testing.expectEqual(first.entered.load(.seq_cst), first.completed.load(.seq_cst));
    native.setEventSink(second.sink());
    try native.send("two", true);
    try second.waitForOutput("two", 5_000);
    try std.testing.expect(!first.outputContains("two"));
}

const ReleaseInCallback = struct {
    native: std.atomic.Value(?*NativeSession) = .init(null),
    released: std.atomic.Value(bool) = .init(false),

    fn emit(context: *anyopaque, event: Event) void {
        const self: *ReleaseInCallback = @ptrCast(@alignCast(context));
        if (event != .pane_output) return;
        const native = self.native.load(.seq_cst) orelse return;
        if (self.released.swap(true, .seq_cst)) return;
        // Drops the last reference on the reader thread itself.
        native.release();
    }
};

test "releasing the last reference inside a callback tears down without deadlock" {
    if (!supported_os) return error.SkipZigTest;

    var ctx: ReleaseInCallback = .{};
    const teardowns_before = teardown_count.load(.seq_cst);
    // Output starts only after a delay, so the pointer and PID are stored
    // before the callback can release the session.
    const native = try NativeSession.create(std.testing.allocator, std.testing.io, .{
        .id = "release-in-callback",
        .shell = "/bin/sh",
        .command = "sleep 0.3; echo go; exec sleep 100",
        .event_sink = .{ .context = &ctx, .emit = ReleaseInCallback.emit },
    });
    const pid = native.handle.child_pid;
    ctx.native.store(native, .seq_cst);

    const deadline = sys.monotonicMs() + 10_000;
    while (teardown_count.load(.seq_cst) == teardowns_before) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        sys.sleepMs(5);
    }
    try std.testing.expect(ctx.released.load(.seq_cst));
    // The child was terminated and reaped by the detached reader; the
    // testing allocator verifies every allocation was freed.
    try std.testing.expect(waitUntilGone(pid, 2_000));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG))));
}

fn lineBlock(allocator: std.mem.Allocator, total: usize) ![]u8 {
    // Newline-terminated lines: in canonical mode the kernel discards
    // overflow on an unterminated line instead of applying backpressure.
    const data = try allocator.alloc(u8, total);
    for (data, 0..) |*byte, index| byte.* = if (index % 64 == 63) '\n' else 'x';
    return data;
}

const InputStopper = struct {
    native: *NativeSession,
    delay_ms: i64,

    fn run(self: *InputStopper) void {
        sys.sleepMs(self.delay_ms);
        self.native.stopInput();
    }
};

test "input to a child that never reads times out, and stopInput cancels a blocked writer" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const native = try testCreate(null, "exec sleep 100", .{});
    defer native.destroy();
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);

    // The terminal's input queue fills; the write must give up at the
    // deadline instead of blocking the caller (and shutdown) forever.
    const started = sys.monotonicMs();
    try std.testing.expectError(error.InputTimeout, native.send(data, true));
    const elapsed = sys.monotonicMs() - started;
    try std.testing.expect(elapsed >= default_input_deadline_ms);
    try std.testing.expect(elapsed <= default_input_deadline_ms + 100);
    try std.testing.expect(native.isRunning());

    // A writer blocked on the full queue is woken by stopInput.
    var stopper = InputStopper{ .native = native, .delay_ms = 100 };
    const thread = try std.Thread.spawn(.{}, InputStopper.run, .{&stopper});
    const blocked_at = sys.monotonicMs();
    const result = native.writeInput(data);
    const woke_after = sys.monotonicMs() - blocked_at;
    thread.join();
    try std.testing.expectError(error.InputClosed, result);
    try std.testing.expect(woke_after >= 90);
    try std.testing.expect(woke_after <= 100 + 50);

    // Input stays closed, immediately, for every entry point.
    const after = sys.monotonicMs();
    try std.testing.expectError(error.InputClosed, native.send("x", true));
    try std.testing.expectError(error.InputClosed, native.sendKey("Enter"));
    try std.testing.expectError(error.InputClosed, native.writeInput("x"));
    try std.testing.expect(sys.monotonicMs() - after < 50);
    native.stopInput();
}

const BlockSender = struct {
    native: *NativeSession,
    byte: u8,
    failed: bool = false,

    fn run(self: *BlockSender) void {
        var data: [64 * 1024]u8 = undefined;
        @memset(&data, self.byte);
        self.native.send(&data, true) catch {
            self.failed = true;
        };
    }
};

test "concurrent sends are serialized: text plus Enter never interleaves" {
    if (!supported_os) return error.SkipZigTest;
    const block = 64 * 1024;

    var rec: Recorder = .{};
    defer rec.deinit();
    // Raw mode: no line-length limit and no echo, so cat's output is exactly
    // the input byte stream in arrival order.
    const native = try testCreate(&rec, "stty raw -echo; echo READY; exec cat", .{});
    defer native.destroy();
    try rec.waitForOutput("READY", 10_000);

    var sender_a = BlockSender{ .native = native, .byte = 'a' };
    var sender_b = BlockSender{ .native = native, .byte = 'b' };
    const thread_a = try std.Thread.spawn(.{}, BlockSender.run, .{&sender_a});
    const thread_b = try std.Thread.spawn(.{}, BlockSender.run, .{&sender_b});
    thread_a.join();
    thread_b.join();
    try std.testing.expect(!sender_a.failed and !sender_b.failed);

    const deadline = sys.monotonicMs() + 10_000;
    while (rec.countByte('a') + rec.countByte('b') + rec.countByte('\r') < 2 * block + 2) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        sys.sleepMs(5);
    }

    rec.mutex.lockUncancelable(Recorder.io);
    defer rec.mutex.unlock(Recorder.io);
    const ready_at = std.mem.indexOf(u8, rec.output.items, "READY").?;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(std.testing.allocator);
    for (rec.output.items[ready_at + "READY".len ..]) |byte| {
        if (byte == 'a' or byte == 'b' or byte == '\r') try stream.append(std.testing.allocator, byte);
    }
    try std.testing.expectEqual(@as(usize, 2 * block + 2), stream.items.len);
    // Two contiguous blocks, each immediately followed by its own Enter.
    const first = stream.items[0];
    const second: u8 = if (first == 'a') 'b' else 'a';
    try std.testing.expect(std.mem.allEqual(u8, stream.items[0..block], first));
    try std.testing.expectEqual(@as(u8, '\r'), stream.items[block]);
    try std.testing.expect(std.mem.allEqual(u8, stream.items[block + 1 ..][0..block], second));
    try std.testing.expectEqual(@as(u8, '\r'), stream.items[2 * block + 1]);
}

test "an exited session rejects input and resize with SessionTerminated" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "exit 0", .{});
    defer native.destroy();
    try rec.waitForExit(10_000);

    try std.testing.expect(!native.isRunning());
    try std.testing.expectError(error.SessionTerminated, native.send("ls", true));
    try std.testing.expectError(error.SessionTerminated, native.sendKey("Enter"));
    try std.testing.expectError(error.SessionTerminated, native.writeInput("x"));
    try std.testing.expectError(error.SessionTerminated, native.resize(80, 24));
    try std.testing.expectError(error.UnknownKey, native.sendKey("NoSuchKey"));
}

var failed_spawn_child_pid: std.posix.pid_t = 0;

fn failReaderSpawn(child_pid: std.posix.pid_t) std.Thread.SpawnError!void {
    failed_spawn_child_pid = child_pid;
    return error.SystemResources;
}

test "a failed reader-thread start kills and reaps the child" {
    if (!supported_os) return error.SkipZigTest;

    spawn_reader_hook = failReaderSpawn;
    defer spawn_reader_hook = null;
    failed_spawn_child_pid = 0;

    try std.testing.expectError(error.SystemResources, testCreate(null, "exec sleep 100", .{}));
    const pid = failed_spawn_child_pid;
    try std.testing.expect(pid > 0);
    // No live child and no zombie: the PID has already been collected.
    const rc = std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG));
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(rc));
}

fn createDestroyForFailureTest(allocator: std.mem.Allocator) !void {
    const native = try NativeSession.create(allocator, std.testing.io, .{
        .id = "oom",
        .title = "oom title",
        .shell = "/bin/sh",
        .command = "exit 0",
        .cwd = "/",
        .env = &.{"ZMUX_T2_OOM=1"},
        .scrollback_bytes = 4096,
    });
    native.destroy();
}

test "create allocation failures are deterministic and leak nothing" {
    if (!supported_os) return error.SkipZigTest;

    // The reader thread's only allocator use is foreground polling; with it
    // off, the failure indices do not depend on thread scheduling.
    foreground_check_enabled.store(false, .seq_cst);
    defer foreground_check_enabled.store(true, .seq_cst);
    var run: usize = 0;
    while (run < 3) : (run += 1) {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, createDestroyForFailureTest, .{});
    }
}

test "setTitle is reflected by infoJson" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const native = try testCreate(null, "exec sleep 100", .{ .id = "titled" });
    defer native.destroy();
    {
        const info = try native.infoJson(allocator);
        defer allocator.free(info);
        try expectJsonContains(info, "\"id\":\"titled\",\"title\":\"titled\"");
        try expectJsonContains(info, "\"state\":\"running\"");
        try expectJsonContains(info, "\"exitStatus\":null,\"exitCode\":null,\"signal\":null,\"generation\":0}");
    }
    try native.setTitle("build \"logs\"");
    const info = try native.infoJson(allocator);
    defer allocator.free(info);
    try expectJsonContains(info, "\"title\":\"build \\\"logs\\\"\"");
}

test "exit code and terminating signal are reported separately" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    {
        var rec: Recorder = .{};
        defer rec.deinit();
        const native = try testCreate(&rec, "exit 9", .{});
        defer native.destroy();
        try std.testing.expect(native.exitInfo() == null or native.exitInfo().?.exit_code == 9);
        try rec.waitForExit(10_000);

        const info = native.exitInfo().?;
        try std.testing.expectEqual(@as(?u32, 9), info.exit_code);
        try std.testing.expectEqual(@as(?u32, null), info.signal);
        try std.testing.expectEqual(@as(?u32, 9), rec.exit_code);
        try std.testing.expectEqual(@as(?u32, null), rec.exit_signal);
        const json = try native.infoJson(allocator);
        defer allocator.free(json);
        try expectJsonContains(json, "\"state\":\"terminated\"");
        try expectJsonContains(json, "\"exitStatus\":9,\"exitCode\":9,\"signal\":null");
    }
    {
        var rec: Recorder = .{};
        defer rec.deinit();
        const native = try testCreate(&rec, "kill -9 $$", .{});
        defer native.destroy();
        try rec.waitForExit(10_000);

        const info = native.exitInfo().?;
        try std.testing.expectEqual(@as(?u32, null), info.exit_code);
        try std.testing.expectEqual(@as(?u32, 9), info.signal);
        try std.testing.expectEqual(@as(?u32, null), rec.exit_code);
        try std.testing.expectEqual(@as(?u32, 9), rec.exit_signal);
        const json = try native.infoJson(allocator);
        defer allocator.free(json);
        try expectJsonContains(json, "\"exitStatus\":9,\"exitCode\":null,\"signal\":9");
    }
}

test "pane_activity fires on the idle-to-active edge, not per chunk" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(
        &rec,
        "i=0; while [ $i -lt 100 ]; do echo line$i; i=$((i+1)); done; sleep 1.3; echo late; exit 0",
        .{},
    );
    defer native.destroy();
    try rec.waitForExit(15_000);

    try std.testing.expect(rec.outputContains("line99"));
    try std.testing.expect(rec.outputContains("late"));
    try std.testing.expect(rec.outputs >= 2);
    // One edge for the burst, one for the output after more than a second
    // of silence.
    try std.testing.expectEqual(@as(usize, 2), rec.activity);
}

test "an exited session releases its descriptors and reader but keeps scrollback" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "sleep 0.2; echo bye; exit 0", .{});
    defer native.destroy();
    const master_fd = native.handle.master_fd;
    try std.testing.expect(master_fd >= 0);
    try std.testing.expect(std.c.fcntl(master_fd, std.c.F.GETFD) >= 0);
    try rec.waitForExit(10_000);

    const deadline = sys.monotonicMs() + 5_000;
    while (!native.reader_finished.load(.seq_cst)) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        sys.sleepMs(2);
    }
    try std.testing.expectEqual(@as(sys.fd_t, -1), native.handle.master_fd);
    try std.testing.expectEqual(@as(sys.fd_t, -1), native.handle.pid_fd);
    try std.testing.expect(std.c.fcntl(master_fd, std.c.F.GETFD) < 0);
    try std.testing.expectEqual(@as(u64, 0), native.reader_tid.load(.seq_cst));

    const captured = try native.capture(allocator, 10);
    defer allocator.free(captured);
    try std.testing.expect(std.mem.indexOf(u8, captured, "bye") != null);
}

test "scrollbackTail and captureBounded return bounded copies with offsets" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "printf 'one\\ntwo\\nthree\\n'; exit 0", .{});
    defer native.destroy();
    try rec.waitForExit(10_000);

    const full = try native.scrollbackSnapshot(allocator);
    defer allocator.free(full);
    const tail = try native.scrollbackTail(allocator, 5);
    defer allocator.free(tail.bytes);
    try std.testing.expectEqual(@as(usize, 5), tail.bytes.len);
    try std.testing.expectEqualStrings(full[full.len - 5 ..], tail.bytes);
    try std.testing.expectEqual(@as(u64, full.len), tail.end_offset);
    try std.testing.expectEqual(@as(u64, full.len - 5), tail.start_offset);
    try std.testing.expectEqual(rec.next_offset.?, tail.end_offset);

    const whole = try native.scrollbackTail(allocator, 1 << 20);
    defer allocator.free(whole.bytes);
    try std.testing.expectEqual(@as(u64, 0), whole.start_offset);
    try std.testing.expectEqualStrings(full, whole.bytes);

    const last_line = try native.captureBounded(allocator, 1, 1024);
    defer allocator.free(last_line);
    try std.testing.expect(std.mem.indexOf(u8, last_line, "three") != null);
    try std.testing.expect(std.mem.indexOf(u8, last_line, "one") == null);
    const clipped = try native.captureBounded(allocator, 100, 4);
    defer allocator.free(clipped);
    try std.testing.expect(clipped.len <= 4);
}

test "terminate hangs up foreground and background jobs of an interactive shell" {
    if (!supported_os) return error.SkipZigTest;
    // bash forwards SIGHUP to all of its jobs; a job-control shell is needed
    // to put the foreground command in its own process group.
    _ = sys.statAt(sys.cwd_fd, "/bin/bash", true) catch return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, null, .{
        .shell = "/bin/bash",
        // No rc files: a hermetic interactive login shell.
        .env = &.{ "HOME=/nonexistent", "PS1=zmux$ " },
    });
    defer native.destroy();
    const shell_pid = native.handle.child_pid;

    try native.send("sleep 9999 & echo BG=$!=", true);
    var bg_pid: std.posix.pid_t = 0;
    const bg_deadline = sys.monotonicMs() + 10_000;
    while (bg_pid == 0) {
        try std.testing.expect(sys.monotonicMs() < bg_deadline);
        sys.sleepMs(10);
        rec.mutex.lockUncancelable(Recorder.io);
        defer rec.mutex.unlock(Recorder.io);
        var search: usize = 0;
        // Skip the echoed command line, where "BG=" is followed by "$!".
        while (std.mem.indexOfPos(u8, rec.output.items, search, "BG=")) |at| {
            search = at + 3;
            const rest = rec.output.items[search..];
            const end = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
            bg_pid = std.fmt.parseInt(std.posix.pid_t, rest[0..end], 10) catch continue;
            break;
        }
    }
    try native.send("sleep 9998", true);

    var fg_pgid: std.posix.pid_t = 0;
    const fg_deadline = sys.monotonicMs() + 10_000;
    while (true) {
        try std.testing.expect(sys.monotonicMs() < fg_deadline);
        fg_pgid = tcgetpgrp(native.handle.master_fd);
        if (fg_pgid > 1 and fg_pgid != shell_pid) break;
        sys.sleepMs(10);
    }
    try std.testing.expect(processExists(bg_pid));
    try std.testing.expect(processExists(fg_pgid));

    native.terminate();
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(waitUntilGone(fg_pgid, 3_000));
    try std.testing.expect(waitUntilGone(bg_pid, 3_000));
    try std.testing.expect(!processExists(shell_pid));
}

test "terminate lets a HUP trap finish before SIGTERM follows" {
    if (!supported_os) return error.SkipZigTest;

    // Regression: SIGTERM used to be sent in the same instant as SIGHUP, so
    // a job with a HUP handler died of SIGTERM before the handler ran.
    var rec: Recorder = .{};
    defer rec.deinit();
    // The shell waits with the `wait` builtin, which a trapped signal
    // interrupts at once. Waiting on a foreground `sleep` instead defers the
    // trap until that child exits, and a SIGHUP that lands between its fork
    // and exec misses it, so the trap would run up to a second late and lose
    // to the SIGTERM this test is about.
    const native = try testCreate(&rec, "trap 'echo TRAPPED; exit 3' HUP; echo ready; while :; do sleep 1 & wait $!; done", .{});
    defer native.destroy();
    try rec.waitForOutput("ready", 10_000);
    // Let the shell get past the fork and park in `wait`.
    sys.sleepMs(50);

    native.terminate();
    try rec.waitForExit(10_000);
    try std.testing.expect(rec.outputContains("TRAPPED"));
    try std.testing.expectEqual(@as(?u32, 3), rec.exit_code);
    try std.testing.expectEqual(@as(?u32, null), rec.exit_signal);
}

test "terminate escalates to SIGTERM when SIGHUP is ignored" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "trap '' HUP; echo ready; exec sleep 100", .{});
    defer native.destroy();
    try rec.waitForOutput("ready", 10_000);
    // `exec` replaced the shell; give it a moment to be the sleep.
    sys.sleepMs(50);

    const started = sys.monotonicMs();
    native.terminate();
    try rec.waitForExit(10_000);
    // SIGTERM (15) arrived after the HUP grace and before the SIGKILL deadline.
    try std.testing.expectEqual(@as(?u32, 15), rec.exit_signal);
    try std.testing.expect(sys.monotonicMs() - started >= hangup_grace_ms);
}

test "destroy terminates a running child and joins the reader" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "echo up; exec sleep 100", .{});
    const pid = native.handle.child_pid;
    try rec.waitForOutput("up", 10_000);

    native.retain();
    native.release();
    try std.testing.expect(native.isRunning());
    native.destroy();

    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG))));
    // The exit was delivered before destroy returned, with the hangup signal.
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
    try std.testing.expectEqual(@as(?u32, @backingInt(std.posix.SIG.HUP)), rec.exit_signal);
}

/// Type a foreground job that ignores SIGHUP into an interactive shell and
/// return its process group once the terminal reports it.
fn startHupIgnoringJob(native: *NativeSession, seconds: []const u8) !std.posix.pid_t {
    var line_buf: [96]u8 = undefined;
    // An ignored disposition survives exec, so the `sleep` itself ignores
    // the hangup.
    const line = try std.fmt.bufPrint(&line_buf, "sh -c 'trap \"\" HUP; exec sleep {s}'", .{seconds});
    try native.send(line, true);

    const shell_pid = native.handle.child_pid;
    var fg_pgid: std.posix.pid_t = 0;
    const deadline = sys.monotonicMs() + 10_000;
    while (true) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        fg_pgid = tcgetpgrp(native.handle.master_fd);
        if (fg_pgid > 1 and fg_pgid != shell_pid) break;
        sys.sleepMs(10);
    }
    // Let the inner shell install the trap and exec.
    sys.sleepMs(300);
    try std.testing.expect(processExists(fg_pgid));
    return fg_pgid;
}

test "terminate finishes off a foreground job that ignores SIGHUP after its shell exits" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, null, .{ .env = &.{ "HOME=/nonexistent", "PS1=zmux$ " } });
    defer native.destroy();
    const fg_pgid = try startHupIgnoringJob(native, "9993");

    // SIGHUP kills the interactive shell at once; the job ignores it. The
    // ladder must keep going for the job: SIGTERM after the hangup grace.
    native.terminate();
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(waitUntilGone(fg_pgid, 3_000));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), native.handle.orphanedForegroundGroup());
}

test "releasing a pane whose shell died first still terminates its foreground job" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, null, .{ .env = &.{ "HOME=/nonexistent", "PS1=zmux$ " } });
    defer native.destroy();
    const fg_pgid = try startHupIgnoringJob(native, "9992");
    // The reader remembers the foreground group on its polling interval.
    sys.sleepMs(foreground.poll_interval_ms + 200);

    // The shell dies on its own (not through zmux) while the job runs. The
    // hangup the kernel sends to the foreground group is ignored.
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(native.handle.child_pid, .KILL));
    try rec.waitForExit(10_000);
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(processExists(fg_pgid));

    // The pane is already exited; closing it must not leave the job behind.
    native.stopForOwnerRelease();
    try std.testing.expect(waitUntilGone(fg_pgid, 3_000));
}

test "output buffered at exit survives a slow sink beyond the drain grace" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const total = 64 * 1024;

    var rec: Recorder = .{};
    defer rec.deinit();
    // Every callback is slow, so the reader is still working through the
    // kernel buffer long after `exit_drain_grace_ms` has passed since the
    // reap. That buffer holds the only copy of the final output.
    rec.output_delay_ms = 40;
    const native = try testCreate(&rec, "head -c 65536 /dev/zero | tr '\\000' '\\001'", .{});
    defer native.destroy();
    try std.testing.expect(!native.isStreamFinalized());

    try rec.waitForExit(60_000);
    const finalized_deadline = sys.monotonicMs() + 5_000;
    while (!native.isStreamFinalized()) {
        try std.testing.expect(sys.monotonicMs() < finalized_deadline);
        sys.sleepMs(2);
    }

    const snapshot = try native.scrollbackSnapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expectEqual(@as(usize, total), std.mem.count(u8, snapshot, "\x01"));
    try std.testing.expectEqual(@as(usize, total), rec.countByte(0x01));
    rec.mutex.lockUncancelable(Recorder.io);
    defer rec.mutex.unlock(Recorder.io);
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
    try std.testing.expectEqual(EventKind.session_exited, rec.kinds.items[rec.kinds.items.len - 1]);
    try std.testing.expect(rec.offsets_contiguous);
}

test "destroy delivers output that is still buffered when the reader is stopped" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_path);
    const marker = try std.fs.path.join(allocator, &.{ tmp_path, "wrote-mark-last" });
    defer allocator.free(marker);
    const cmd = try std.fmt.allocPrint(allocator, "echo first; sleep 0.1; echo MARK-LAST; : > '{s}'; exec sleep 100", .{marker});
    defer allocator.free(cmd);

    var rec: Recorder = .{};
    defer rec.deinit();
    // The child prints and then idles. The first callback is slow, so
    // MARK-LAST sits unread in the kernel buffer when the owner tears
    // the session down right after the marker file appears.
    rec.output_delay_ms = 1200;
    const native = try testCreate(&rec, cmd, .{});
    try rec.waitForOutput("first", 10_000);
    const marker_deadline = sys.monotonicMs() + 10_000;
    while (true) {
        if (sys.statAt(sys.cwd_fd, marker, false)) |_| break else |_| {}
        if (sys.monotonicMs() >= marker_deadline) return error.Timeout;
        sys.sleepMs(5);
    }
    native.destroy();

    try std.testing.expect(rec.outputContains("MARK-LAST"));
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
    try std.testing.expectEqual(EventKind.session_exited, rec.kinds.items[rec.kinds.items.len - 1]);
}

test "a descendant that never stops writing cannot postpone session_exited forever" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    // `yes` ignores the hangup and floods the terminal after the leader
    // exits. It stops by itself once the master is closed (EIO).
    const native = try testCreate(&rec, "(trap '' HUP; exec yes spam) & sleep 0.3; exit 6", .{ .scrollback_bytes = 64 * 1024 });
    defer native.destroy();

    try rec.waitForExit(20_000);
    try std.testing.expectEqual(@as(?u32, 6), rec.exit_code);
    try std.testing.expectEqual(@as(usize, 1), rec.exitCount());
}

const SpinReaper = struct {
    native: *NativeSession,
    go: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),

    fn run(self: *SpinReaper) void {
        while (!self.go.load(.seq_cst)) std.atomic.spinLoopHint();
        while (!self.stop.load(.seq_cst)) _ = self.native.reapExited();
    }
};

test "concurrent reapers never replace a real exit status with an unknown one" {
    if (!supported_os) return error.SkipZigTest;

    var round: usize = 0;
    while (round < 12) : (round += 1) {
        var rec: Recorder = .{};
        defer rec.deinit();
        const native = try testCreate(&rec, "exit 9", .{});
        defer native.destroy();

        var go: std.atomic.Value(bool) = .init(false);
        var stop: std.atomic.Value(bool) = .init(false);
        var reapers: [4]SpinReaper = undefined;
        var threads: [4]std.Thread = undefined;
        for (&reapers, &threads) |*reaper, *thread| {
            reaper.* = .{ .native = native, .go = &go, .stop = &stop };
            thread.* = try std.Thread.spawn(.{}, SpinReaper.run, .{reaper});
        }
        go.store(true, .seq_cst);
        const waited = rec.waitForExit(15_000);
        stop.store(true, .seq_cst);
        for (threads) |thread| thread.join();
        try waited;

        // Whoever published the transition published the collected status.
        try std.testing.expectEqual(@as(?u32, 9), native.exitInfo().?.exit_code);
        try std.testing.expectEqual(@as(?u32, 9), rec.exit_code);
        const json = try native.infoJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        try expectJsonContains(json, "\"exitCode\":9");
    }
}

const QueuedWriter = struct {
    native: *NativeSession,
    data: []const u8,
    start_delay_ms: i64,
    elapsed_ms: i64 = 0,
    failed: bool = false,

    fn run(self: *QueuedWriter) void {
        sys.sleepMs(self.start_delay_ms);
        const started = sys.monotonicMs();
        if (self.native.writeInput(self.data)) |_| {} else |_| self.failed = true;
        self.elapsed_ms = sys.monotonicMs() - started;
    }
};

test "time queued behind another writer counts against the input deadline" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const native = try testCreate(null, "exec sleep 100", .{});
    defer native.destroy();
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);

    // The first writer holds the input lock for its whole deadline. The
    // second arrives halfway through and must fail at its own deadline, not
    // a full deadline after it finally gets the lock.
    var queued = QueuedWriter{ .native = native, .data = data, .start_delay_ms = @divTrunc(default_input_deadline_ms, 2) };
    const thread = try std.Thread.spawn(.{}, QueuedWriter.run, .{&queued});
    try std.testing.expectError(error.InputTimeout, native.send(data, true));
    thread.join();
    try std.testing.expect(queued.failed);
    try std.testing.expect(queued.elapsed_ms <= default_input_deadline_ms + 300);
}

const BlockedWriter = struct {
    native: *NativeSession,
    data: []const u8,
    finished_at_ms: std.atomic.Value(i64) = .init(0),

    fn run(self: *BlockedWriter) void {
        self.native.writeInput(self.data) catch {};
        self.finished_at_ms.store(sys.monotonicMs(), .seq_cst);
    }
};

test "the reader epilogue wakes a blocked writer instead of waiting out its deadline" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: Recorder = .{};
    defer rec.deinit();
    // The descendant keeps the slave open, so the blocked writer sees no
    // hangup when the shell exits; only the reader can release it.
    const native = try testCreate(&rec, "(trap '' HUP; exec sleep 4) & sleep 0.4; exit 0", .{});
    defer native.destroy();
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);

    const started = sys.monotonicMs();
    var writer = BlockedWriter{ .native = native, .data = data };
    const thread = try std.Thread.spawn(.{}, BlockedWriter.run, .{&writer});
    try rec.waitForExit(10_000);
    const finalized_deadline = sys.monotonicMs() + 5_000;
    while (!native.isStreamFinalized() and sys.monotonicMs() < finalized_deadline) sys.sleepMs(2);
    const finalized_after = sys.monotonicMs() - started;
    thread.join();

    // Shell exit (0.4 s) plus the drain grace, well short of the writer's
    // 2 s deadline that the epilogue used to wait for.
    try std.testing.expect(native.isStreamFinalized());
    try std.testing.expect(finalized_after < default_input_deadline_ms - 400);
    try std.testing.expect(writer.finished_at_ms.load(.seq_cst) - started < default_input_deadline_ms - 400);
}
