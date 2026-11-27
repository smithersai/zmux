//! Background reader thread: PTY drain, activity, bell, and foreground events.

const std = @import("std");
const builtin = @import("builtin");
const buffer = @import("../buffer.zig");
const foreground = @import("../foreground.zig");
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const root = @import("../native.zig");
const session = @import("session.zig");
const events = @import("events.zig");
const control = @import("control.zig");
const harness = @import("harness.zig");
const assert = std.debug.assert;
const NativeSession = session.NativeSession;
const ExitInfo = root.ExitInfo;
const exit_drain_grace_ms = root.exit_drain_grace_ms;
const exit_drain_max_bytes = root.exit_drain_max_bytes;
const activity_idle_ms = root.activity_idle_ms;
const supported_os = harness.supported_os;
const EventKind = harness.EventKind;
const Recorder = harness.Recorder;
const testCreate = harness.testCreate;
const Reaper = harness.Reaper;

/// Extra lookups (with doubling backoff) for a foreground group whose
/// process info could not be read, before the fallback form is accepted.
const foreground_degraded_retries: u8 = 4;

/// Reader thread body: drain PTY output until the child is reaped and the
/// stream is final, then run the epilogue.
pub fn readerLoop(self: *NativeSession) void {
    assert(!self.reader_finished.load(.seq_cst));
    self.reader_tid.store(session.currentThreadTag(), .seq_cst);

    var read_buf: [32 * 1024]u8 = undefined;
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

        if (exit_seen_ms == null and control.reapIsDone(self)) exit_seen_ms = session.monotonicMs(self);

        const wait = switch (readerWait(self, stopping, pty_eof, exit_seen_ms, overtime_bytes)) {
            .done => break,
            .wait => |wait| wait,
        };
        const overtime = wait.overtime;

        // Negative descriptors are ignored by poll(2). After PTY EOF with
        // a live child (it closed its terminal) only the exit is awaited.
        const master_fd = if (pty_eof) -1 else self.handle.master_fd;
        const pid_fd = if (exit_seen_ms == null) self.handle.pid_fd else -1;
        var fds = [_]std.posix.pollfd{
            .{ .fd = master_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = pid_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, wait.timeout_ms) catch {
            if (overtime) break;
            session.sleepMs(self, 10);
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
        assert(n <= read_buf.len);
        if (overtime) overtime_bytes += n;
        handleOutput(self, read_buf[0..n]);
    }

    finishReader(self);
}

const ReaderWait = union(enum) {
    /// The child is reaped and the stream is drained (or abandoned).
    done,
    wait: struct {
        timeout_ms: i32,
        /// No more waiting, only draining what is already readable.
        overtime: bool,
    },
};

/// Decide how long the reader's next poll may block. Also runs the
/// periodic foreground-process check while the child is alive.
fn readerWait(
    self: *NativeSession,
    stopping: bool,
    pty_eof: bool,
    exit_seen_ms: ?i64,
    overtime_bytes: usize,
) ReaderWait {
    // With a pidfd the exit wakes the poll; without one (Darwin) a
    // short timeout bounds how late the exit is noticed.
    var timeout_ms: i32 = if (self.handle.pid_fd >= 0) 100 else 25;
    var overtime = false;
    if (stopping) {
        if (pty_eof) return .done;
        overtime = true;
    } else if (exit_seen_ms) |seen| {
        if (pty_eof) return .done;
        // A descendant still holds the slave open: stop waiting for
        // an EOF that may never come.
        const remaining = exit_drain_grace_ms - (session.monotonicMs(self) - seen);
        if (remaining <= 0) overtime = true else timeout_ms = @intCast(remaining);
    } else if (!pty_eof) {
        // A failed lookup is retried on the next poll interval.
        pollForegroundChange(self) catch |err| log.debug("native_foreground_poll_failed", .{ .err = err });
    }
    if (overtime) {
        if (overtime_bytes >= exit_drain_max_bytes) return .done;
        timeout_ms = 0;
    }
    assert(timeout_ms >= 0);
    return .{ .wait = .{ .timeout_ms = timeout_ms, .overtime = overtime } };
}

fn handleOutput(self: *NativeSession, data: []const u8) void {
    assert(data.len > 0);
    // The offset is taken under the same lock as the append, so
    // consecutive events carry contiguous offsets.
    self.mutex.lockUncancelable(self.io);
    const offset = self.scrollback.endOffset();
    self.scrollback.append(data);
    assert(self.scrollback.endOffset() == offset + data.len);
    self.mutex.unlock(self.io);

    _ = events.emitEvent(self, .{ .pane_output = .{
        .pane_id = self.id,
        .data = data,
        .offset = offset,
        .generation = self.generation_value,
    } });

    const now_ms = session.nowMs(self);
    const mono_ms = session.monotonicMs(self);
    const was_idle = if (self.last_output_ms) |last| mono_ms - last >= activity_idle_ms else true;
    self.last_output_ms = mono_ms;
    if (was_idle) {
        _ = events.emitEvent(self, .{ .pane_activity = .{
            .pane_id = self.id,
            .last_activity_ms = now_ms,
            .generation = self.generation_value,
        } });
    }
    if (std.mem.indexOfScalar(u8, data, 0x07) != null) {
        _ = events.emitEvent(self, .{ .pane_bell = .{
            .pane_id = self.id,
            .last_bell_ms = now_ms,
            .generation = self.generation_value,
        } });
    }
}

/// Reader epilogue: emit `session_exited` once (after every
/// `pane_output`), release the master, and hand off or finish teardown.
fn finishReader(self: *NativeSession) void {
    assert(session.onReaderThread(self));
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
        _ = events.emitEvent(self, .{ .session_exited = .{
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
        session.freeResources(self);
    }
}

fn pollForegroundChange(self: *NativeSession) !void {
    const now_ms = session.monotonicMs(self);
    if (now_ms < self.next_foreground_check_ms) return;
    self.next_foreground_check_ms = now_ms + foreground.poll_interval_ms;

    // Remember the foreground group while the shell is alive: if the
    // shell dies first, teardown still needs to reach that job.
    self.handle.captureForeground();
    if (!root.foreground_check_enabled.load(.seq_cst)) return;

    // Without a sink nothing can be delivered: skip the lookup and leave
    // the change uncommitted for whoever subscribes later.
    if (!events.hasEventSink(self)) return;
    const polled = try self.foreground_tracker.poll(self.allocator, self.io, self.handle.master_fd);
    var process = polled orelse return;
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
        assert(self.foreground_degraded_polls >= 1);
        assert(self.foreground_degraded_polls <= foreground_degraded_retries);
        const shift: u6 = @intCast(self.foreground_degraded_polls - 1);
        self.next_foreground_check_ms = now_ms + (foreground.poll_interval_ms << shift);
        if (!first) return;
    } else {
        self.foreground_degraded_pgid = null;
    }

    const delivered = events.emitEvent(self, .{ .foreground_changed = .{
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
    const cmd = try std.fmt.allocPrint(
        allocator,
        "echo first; sleep 0.1; echo MARK-LAST; : > '{s}'; exec sleep 100",
        .{marker},
    );
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
    const native = try testCreate(&rec, "(trap '' HUP; exec yes spam) & sleep 0.3; exit 6", .{
        .scrollback_bytes = 64 * 1024,
    });
    defer native.destroy();

    try rec.waitForExit(20_000);
    try std.testing.expectEqual(@as(?u32, 6), rec.exit_code);
    try std.testing.expectEqual(@as(usize, 1), rec.exitCount());
}
