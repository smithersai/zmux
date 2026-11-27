//! Termination ladder, reaping, and serialized input for `NativeSession`.

const std = @import("std");
const foreground = @import("../foreground.zig");
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const root = @import("../native.zig");
const session = @import("session.zig");
const reader = @import("reader.zig");
const keys = @import("keys.zig");
const harness = @import("harness.zig");
const assert = std.debug.assert;
const NativeSession = session.NativeSession;
const default_input_deadline_ms = root.default_input_deadline_ms;
const exit_drain_grace_ms = root.exit_drain_grace_ms;
const terminate_grace_ms = root.terminate_grace_ms;
const hangup_grace_ms = root.hangup_grace_ms;
const decodedExitStatus = root.decodedExitStatus;
const keySequence = keys.keySequence;
const supported_os = harness.supported_os;
const Recorder = harness.Recorder;
const testCreate = harness.testCreate;

/// After SIGKILL the reap normally completes within milliseconds. This bounds
/// the wait so an unkillable child (uninterruptible I/O) cannot hang shutdown.
pub const kill_reap_budget_ms: i64 = 5000;

/// `beginTerminate` then `awaitTerminated` with `terminate_grace_ms`.
pub fn terminate(self: *NativeSession) void {
    assert(terminate_grace_ms > 0);
    self.beginTerminate();
    self.awaitTerminated(sys.monotonicMs() + terminate_grace_ms);
}

/// Terminate the child unless it has already been reaped. A reaped
/// child can still leave a foreground job behind (it ignored the hangup
/// and outlived its shell); that job is terminated too.
pub fn stopForOwnerRelease(self: *NativeSession) void {
    assert(self.id.len > 0);
    if (!self.handle.isReaped() or self.handle.orphanedForegroundGroup() != null) self.terminate();
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
    assert(self.input_stopped.load(.seq_cst));
    const term_at = sys.monotonicMs() + hangup_grace_ms;
    if (self.term_at_ms.cmpxchgStrong(0, term_at, .seq_cst, .seq_cst) != null) return;
    _ = self.reapExited();
    self.handle.hangupForeground();
}

/// Reap until the monotonic `deadline_ms` (`sys.monotonicMs`). After a
/// `beginTerminate`, SIGTERM follows the SIGHUP once `hangup_grace_ms`
/// passed. At the deadline, and only if the child is still not reaped,
/// escalate to SIGKILL for the foreground and shell groups and keep
/// reaping until
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
        const reaped = reapIsDone(self);
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
                std.log.warn(
                    "zmux-native: child {d} not reaped {d} ms after SIGKILL",
                    .{ self.handle.child_pid, kill_reap_budget_ms },
                );
                return;
            }
        } else if (now >= deadline_ms) {
            self.handle.kill();
            kill_give_up_ms = now + kill_reap_budget_ms;
        }
        session.sleepMs(self, if (kill_give_up_ms != null) 2 else 5);
    }

    if (session.onReaderThread(self)) return;
    const reader_deadline = sys.monotonicMs() + exit_drain_grace_ms + 150;
    while (!self.reader_finished.load(.seq_cst) and sys.monotonicMs() < reader_deadline) {
        session.sleepMs(self, 2);
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
            markTerminated(self, status);
            return status;
        },
    }
}

/// `reapExited`, reporting whether the child has been reaped at all
/// (with or without a status).
pub fn reapIsDone(self: *NativeSession) bool {
    switch (self.handle.reap()) {
        .running => return false,
        .exited => |status| {
            markTerminated(self, status);
            return true;
        },
    }
}

/// Only called once `waitpid` returned a status or `ECHILD`.
fn markTerminated(self: *NativeSession, status: ?u32) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.state_value.load(.monotonic) == .terminated) return;
    session.setStateLocked(self, .terminated);
    assert(self.state_value.load(.monotonic) == .terminated);
    self.exit_status = if (status) |value| decodedExitStatus(value) else null;
    self.raw_exit_status = status;
}

/// Write `text`, then Enter when `enter` is set, as one atomic input.
/// The `default_input_deadline_ms` budget starts when the call does, so
/// time spent queued behind another writer counts against it.
pub fn send(self: *NativeSession, text: []const u8, enter: bool) !void {
    const deadline_ms = sys.monotonicMs() + default_input_deadline_ms;
    self.input_mutex.lockUncancelable(self.io);
    defer self.input_mutex.unlock(self.io);
    try admitInputLocked(self);
    try writeLocked(self, text, deadline_ms);
    if (enter) try writeLocked(self, "\r", deadline_ms);
}

/// Write the terminal sequence for a tmux-style key name.
pub fn sendKey(self: *NativeSession, key: []const u8) !void {
    const sequence = keySequence(key) orelse return error.UnknownKey;
    assert(sequence.len > 0);
    try self.writeInput(sequence);
}

/// Budgeted like `send`: queueing time counts.
pub fn writeInput(self: *NativeSession, bytes: []const u8) !void {
    const deadline_ms = sys.monotonicMs() + default_input_deadline_ms;
    self.input_mutex.lockUncancelable(self.io);
    defer self.input_mutex.unlock(self.io);
    try admitInputLocked(self);
    try writeLocked(self, bytes, deadline_ms);
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
    // A full pipe (WouldBlock) already holds a wake-up byte.
    _ = sys.write(self.stop_pipe[1], "x") catch |err| log.debug("native_stop_input_write_failed", .{ .err = err });
}

/// Resize the terminal; fails once the session has terminated.
pub fn resize(self: *NativeSession, cols: u16, rows: u16) !void {
    if (self.state() == .terminated) return error.SessionTerminated;
    try self.handle.resize(cols, rows);
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
    var queued = QueuedWriter{
        .native = native,
        .data = data,
        .start_delay_ms = @divTrunc(default_input_deadline_ms, 2),
    };
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
        // The writer is expected to fail (InputClosed); only its timing matters.
        self.native.writeInput(self.data) catch |err| log.debug("native_test_blocked_write_ended", .{ .err = err });
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
