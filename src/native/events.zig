//! Session state, creation options, events, and event-sink delivery.

const std = @import("std");
const buffer = @import("../buffer.zig");
const pty = @import("../pty.zig");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const root = @import("../native.zig");
const session = @import("session.zig");
const reader = @import("reader.zig");
const harness = @import("harness.zig");
const assert = std.debug.assert;
const NativeSession = session.NativeSession;
const activity_idle_ms = root.activity_idle_ms;
const supported_os = harness.supported_os;
const Recorder = harness.Recorder;
const testCreate = harness.testCreate;
const waitUntilGone = harness.waitUntilGone;
const expectJsonContains = harness.expectJsonContains;

/// Session lifecycle: `creating` -> `running` -> `terminated`, or straight
/// from `creating` to `terminated` when startup fails.
pub const NativeSessionState = enum(u8) {
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

/// What `NativeSession.create` spawns and how its scrollback and events are
/// configured.
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

/// One notification delivered to an `EventSink` from the reader thread.
pub const Event = union(enum) {
    foreground_changed: protocol.ForegroundChangedParams,
    session_exited: protocol.SessionExitedParams,
    pane_output: PaneOutputEvent,
    pane_activity: PaneActivityEvent,
    pane_bell: PaneBellEvent,
};

/// A chunk of PTY output, borrowed for the duration of the callback.
pub const PaneOutputEvent = struct {
    pane_id: []const u8,
    data: []const u8,
    /// Stream offset of `data[0]`.
    offset: u64,
    generation: u64,
};

/// Output resumed after at least `activity_idle_ms` of silence.
pub const PaneActivityEvent = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
    generation: u64,
};

/// The pane's output contained a BEL byte.
pub const PaneBellEvent = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
    generation: u64,
};

/// Callback receiving every `Event`; called from the reader thread.
pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) void,
};

// -- Event sink delivery (methods of `NativeSession`) --

/// Whether a sink is installed right now.
pub fn hasEventSink(self: *NativeSession) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.event_sink != null;
}

/// Returns false when no sink was installed, so nothing was delivered.
pub fn emitEvent(self: *NativeSession, event: Event) bool {
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
    assert(self.in_flight > 0);
    self.in_flight -= 1;
    if (self.in_flight == 0) self.emit_idle.broadcast(self.io);
    self.mutex.unlock(self.io);
    return true;
}

/// Replace the sink. Passing null from any thread other than the reader
/// also waits for in-flight callbacks, like `clearEventSink`; from inside
/// a callback it only prevents further events.
pub fn setEventSink(self: *NativeSession, sink: ?EventSink) void {
    const wait_for_idle = sink == null and !session.onReaderThread(self);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.event_sink = sink;
    if (wait_for_idle) {
        while (self.in_flight != 0) self.emit_idle.waitUncancelable(self.io, &self.mutex);
        assert(self.in_flight == 0);
    }
}

/// Remove the sink and block until no callback is in flight: once this
/// returns, the sink's context may be freed. Must not be called from the
/// reader thread (that is, from inside a sink callback), where it would
/// wait for itself.
pub fn clearEventSink(self: *NativeSession) void {
    std.debug.assert(!session.onReaderThread(self));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.event_sink = null;
    while (self.in_flight != 0) self.emit_idle.waitUncancelable(self.io, &self.mutex);
    assert(self.in_flight == 0);
}

/// Remove the sink without waiting: no new callback starts, but one that
/// is already running may finish after this returns. For callers that
/// hold a lock the sink itself may take.
pub fn dropEventSink(self: *NativeSession) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.event_sink = null;
}

test "native session state machine keeps PTY running until termination" {
    try std.testing.expect(NativeSessionState.creating.canTransition(.running));
    try std.testing.expect(NativeSessionState.running.canTransition(.terminated));
    try std.testing.expect(!NativeSessionState.terminated.canTransition(.running));
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
    const teardowns_before = root.teardown_count.load(.seq_cst);
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
    while (root.teardown_count.load(.seq_cst) == teardowns_before) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        sys.sleepMs(5);
    }
    try std.testing.expect(ctx.released.load(.seq_cst));
    // The child was terminated and reaped by the detached reader; the
    // testing allocator verifies every allocation was freed.
    try std.testing.expect(waitUntilGone(pid, 2_000));
    const wait_rc = std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(wait_rc));
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
