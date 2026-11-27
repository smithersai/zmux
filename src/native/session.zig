//! The reference-counted PTY session: lifecycle, state, scrollback, and JSON info.

const std = @import("std");
const buffer = @import("../buffer.zig");
const foreground = @import("../foreground.zig");
const pty = @import("../pty.zig");
const sys = @import("../sys.zig");
const root = @import("../native.zig");
const events = @import("events.zig");
const control = @import("control.zig");
const reader = @import("reader.zig");
const harness = @import("harness.zig");
const assert = std.debug.assert;
const NativeSessionState = events.NativeSessionState;
const NativeSessionOptions = events.NativeSessionOptions;
const EventSink = events.EventSink;
const ExitInfo = root.ExitInfo;
const exit_drain_grace_ms = root.exit_drain_grace_ms;
const exitCodeOf = root.exitCodeOf;
const termSignalOf = root.termSignalOf;
const kill_reap_budget_ms = control.kill_reap_budget_ms;
const supported_os = harness.supported_os;
const Recorder = harness.Recorder;
const testCreate = harness.testCreate;
const expectJsonContains = harness.expectJsonContains;

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
    /// Written only under `mutex` (via `setStateLocked`); read lock-free by
    /// `state()` so hot polling paths never contend with the reader thread.
    state_value: std.atomic.Value(NativeSessionState) = std.atomic.Value(NativeSessionState).init(.creating),
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

        const stop_pipe = try openStopPipe();
        errdefer {
            sys.close(stop_pipe[0]);
            sys.close(stop_pipe[1]);
        }

        const handle = try pty.Pty.spawn(allocator, io, .{
            .shell = opts.shell,
            .command = opts.command,
            .cwd = opts.cwd,
            .env = opts.env,
            .env_mode = opts.env_mode,
            .rows = opts.rows,
            .cols = opts.cols,
        });
        assert(handle.child_pid > 0);
        assert(handle.master_fd >= 0);

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
        if (root.spawn_reader_hook) |hook| try hook(handle.child_pid);
        native.reader_thread = try std.Thread.spawn(.{}, reader.readerLoop, .{native});
        return native;
    }

    /// The `stopInput` wake-up pipe: close-on-exec, non-blocking write end.
    fn openStopPipe() ![2]sys.fd_t {
        const stop_pipe = try sys.pipeCloexec();
        assert(stop_pipe[0] >= 0);
        assert(stop_pipe[1] >= 0);
        errdefer {
            sys.close(stop_pipe[0]);
            sys.close(stop_pipe[1]);
        }
        try sys.setNonBlocking(stop_pipe[1]);
        return stop_pipe;
    }

    pub fn retain(self: *NativeSession) void {
        const previous = self.ref_count.fetchAdd(1, .seq_cst);
        // Retaining a session whose last reference is gone is a use after free.
        assert(previous > 0);
    }

    pub fn release(self: *NativeSession) void {
        const previous = self.ref_count.fetchSub(1, .seq_cst);
        assert(previous > 0);
        if (previous != 1) return;
        if (onReaderThread(self)) {
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
        freeResources(self);
    }

    pub fn state(self: *NativeSession) NativeSessionState {
        return self.state_value.load(.acquire);
    }

    fn setState(self: *NativeSession, next: NativeSessionState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        setStateLocked(self, next);
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
        return exitInfoLocked(self);
    }

    pub fn setTitle(self: *NativeSession, title: []const u8) !void {
        const owned = try self.allocator.dupe(u8, title);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.allocator.free(self.title_value);
        self.title_value = owned;
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

    /// Write the opening `{` and all `NativeSession` JSON fields without the
    /// closing `}`, so callers such as `mux.Manager.listJson` can append more
    /// fields into one output buffer with no intermediate allocation.
    pub fn writeInfoJsonFields(self: *NativeSession, writer: *std.Io.Writer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try writer.print(
            "{{\"id\":{f},\"title\":{f},\"pid\":{},\"state\":{f},\"cwd\":",
            .{
                std.json.fmt(self.id, .{}),
                std.json.fmt(self.title_value, .{}),
                self.handle.child_pid,
                std.json.fmt(self.state_value.load(.monotonic).label(), .{}),
            },
        );
        if (self.cwd_value) |cwd| {
            try writer.print("{f}", .{std.json.fmt(cwd, .{})});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"shell\":");
        if (self.shell_value) |shell| {
            try writer.print("{f}", .{std.json.fmt(shell, .{})});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"scrollbackBytes\":{},\"exitStatus\":", .{self.scrollback.len});
        try writeOptionalU32(writer, self.exit_status);
        // `exitStatus` conflates exit code and signal number and is kept for
        // existing clients; `exitCode` and `signal` separate them.
        const exit: ExitInfo = exitInfoLocked(self) orelse .{ .exit_code = null, .signal = null };
        try writer.writeAll(",\"exitCode\":");
        try writeOptionalU32(writer, exit.exit_code);
        try writer.writeAll(",\"signal\":");
        try writeOptionalU32(writer, exit.signal);
        try writer.print(",\"generation\":{}", .{self.generation_value});
    }

    pub fn infoJson(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        errdefer out.deinit();
        try self.writeInfoJsonFields(&out.writer);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    fn writeOptionalU32(writer: *std.Io.Writer, value: ?u32) !void {
        if (value) |v| {
            try writer.print("{}", .{v});
        } else {
            try writer.writeAll("null");
        }
    }

    // -- Delegated to `native/*.zig` --

    pub const terminate = control.terminate;
    pub const stopForOwnerRelease = control.stopForOwnerRelease;
    pub const beginTerminate = control.beginTerminate;
    pub const awaitTerminated = control.awaitTerminated;
    pub const reapExited = control.reapExited;
    pub const send = control.send;
    pub const sendKey = control.sendKey;
    pub const writeInput = control.writeInput;
    pub const stopInput = control.stopInput;
    pub const resize = control.resize;
    pub const setEventSink = events.setEventSink;
    pub const clearEventSink = events.clearEventSink;
    pub const dropEventSink = events.dropEventSink;
};

/// Final teardown. No other thread may reference the session.
pub fn freeResources(self: *NativeSession) void {
    assert(self.reader_finished.load(.seq_cst));
    assert(self.ref_count.load(.seq_cst) == 0);
    self.handle.close();
    sys.close(self.stop_pipe[0]);
    sys.close(self.stop_pipe[1]);
    self.scrollback.deinit();
    self.allocator.free(self.id);
    self.allocator.free(self.title_value);
    if (self.shell_value) |value| self.allocator.free(value);
    if (self.cwd_value) |value| self.allocator.free(value);
    self.allocator.destroy(self);
    _ = root.teardown_count.fetchAdd(1, .seq_cst);
}

/// Every state write goes through here so the transition table is
/// enforced, not just documented.
pub fn setStateLocked(self: *NativeSession, next: NativeSessionState) void {
    const current = self.state_value.load(.monotonic);
    if (current == next) return;
    std.debug.assert(current.canTransition(next));
    self.state_value.store(next, .release);
}

/// Exit info with `mutex` held; null until the child is reaped.
pub fn exitInfoLocked(self: *NativeSession) ?ExitInfo {
    if (self.state_value.load(.monotonic) != .terminated) return null;
    const status = self.raw_exit_status orelse return .{ .exit_code = null, .signal = null };
    const info: ExitInfo = .{
        .exit_code = exitCodeOf(status),
        .signal = termSignalOf(status),
    };
    assert(info.exit_code == null or info.signal == null);
    return info;
}

/// Nonzero tag of the calling thread.
pub fn currentThreadTag() u64 {
    // Thread ids are never 0 on the supported platforms; 0 means "none".
    return @intCast(std.Thread.getCurrentId());
}

/// Whether the caller runs on this session's reader thread.
pub fn onReaderThread(self: *NativeSession) bool {
    return self.reader_tid.load(.seq_cst) == currentThreadTag();
}

/// Wall-clock milliseconds from the session `io`.
pub fn nowMs(self: *NativeSession) i64 {
    return std.Io.Clock.real.now(self.io).toMilliseconds();
}

/// Monotonic milliseconds from the session `io`.
pub fn monotonicMs(self: *NativeSession) i64 {
    return std.Io.Clock.awake.now(self.io).toMilliseconds();
}

/// Sleep on the session `io`; a cancel just ends the sleep early.
pub fn sleepMs(self: *NativeSession, ms: i64) void {
    // Plain threads are never canceled; a canceled sleep just ends early.
    self.io.sleep(.fromMilliseconds(ms), .awake) catch |err| switch (err) {
        error.Canceled => return,
    };
}

var failed_spawn_child_pid: std.posix.pid_t = 0;

fn failReaderSpawn(child_pid: std.posix.pid_t) std.Thread.SpawnError!void {
    failed_spawn_child_pid = child_pid;
    return error.SystemResources;
}

test "a failed reader-thread start kills and reaps the child" {
    if (!supported_os) return error.SkipZigTest;

    root.spawn_reader_hook = failReaderSpawn;
    defer root.spawn_reader_hook = null;
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
    root.foreground_check_enabled.store(false, .seq_cst);
    defer root.foreground_check_enabled.store(true, .seq_cst);
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
