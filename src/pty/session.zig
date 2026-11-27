//! The `Pty` handle: descriptor ownership, input and output on the master,
//! window size, and reaping. Signal delivery lives in `signal.zig`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const pty = @import("../pty.zig");
const child_mod = @import("child.zig");
const spawn_mod = @import("spawn.zig");
const signal = @import("signal.zig");
const proc = @import("proc.zig");

const SpawnOptions = pty.SpawnOptions;
const ExitObserver = pty.ExitObserver;
const ReapState = pty.ReapState;
const supported_os = proc.supported_os;

/// A child process running on the slave end of a pseudo-terminal, owned
/// through the non-blocking master descriptor.
pub const Pty = struct {
    /// Used only for `wait_mutex`; PTY reads and writes are non-blocking
    /// syscalls on `master_fd` driven by `poll(2)`, so callers can run them
    /// from plain `std.Thread`s.
    io: std.Io,
    /// Non-blocking. -1 once `close` ran. `read`, `pollReadable`, and `write`
    /// read this field without a lock: the owner must not call `close`
    /// concurrently with them. `resize`, `kill`, `terminate`, and
    /// `hangupForeground` are safe against a concurrent `close`.
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    /// Linux pidfd for `child_pid`, readable once the child exits; -1 when
    /// unavailable. Lets a poll loop learn of the exit without a timeout.
    pid_fd: posix.fd_t = -1,
    /// Serializes `waitpid` against every signal sent to the child, so a
    /// signal can never reach a PID the kernel has recycled after the reap.
    wait_mutex: std.Io.Mutex = .init,
    reaped: bool = false,
    exit_status: ?u32 = null,
    exit_observer: ?ExitObserver = null,
    /// Last terminal foreground process group seen that was not the shell's
    /// own group; 0 when none. Remembered so teardown can finish signalling
    /// a foreground job after the shell (the session leader) has exited and
    /// the terminal no longer reports a foreground group. Guarded by
    /// `wait_mutex`. Never signalled without `rememberedForegroundLocked`
    /// re-verifying that the group still belongs to this session.
    foreground_pgid: posix.pid_t = 0,

    /// Open a PTY pair and start `opts.shell` on its slave end. Fails with
    /// `error.ChildSetupFailed` (see `pty.last_child_setup_failure`) when the
    /// child could not reach `exec`.
    pub fn spawn(allocator: Allocator, io: std.Io, opts: SpawnOptions) !Pty {
        try pty.validateSpawnOptions(opts);

        const fds = try child_mod.openPty(.{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 });
        assert(fds.master_fd != fds.slave_fd);
        return spawn_mod.spawnOnFds(allocator, io, opts, fds.master_fd, fds.slave_fd);
    }

    /// SIGTERM to the foreground job and the shell group; see `signal.terminate`.
    pub const terminate = signal.terminate;
    /// SIGKILL to the foreground job and the shell group; see `signal.kill`.
    pub const kill = signal.kill;
    /// SIGHUP+SIGCONT to the foreground job and the shell group.
    pub const hangupForeground = signal.hangupForeground;
    /// Remember the terminal's current foreground group.
    pub const captureForeground = signal.captureForeground;
    /// A remembered foreground group still in this session, or null.
    pub const orphanedForegroundGroup = signal.orphanedForegroundGroup;

    /// Close the master (hanging up the terminal) and the pidfd. Idempotent.
    pub fn close(self: *Pty) void {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.master_fd >= 0) sys.close(self.master_fd);
        self.master_fd = -1;
        if (self.pid_fd >= 0) sys.close(self.pid_fd);
        self.pid_fd = -1;
        assert(self.master_fd == -1);
    }

    /// Install the reap callback. Fires at once when the child is already reaped.
    pub fn setExitObserver(self: *Pty, observer: ExitObserver) void {
        assert(self.child_pid > 0);
        var should_emit = false;
        var emit_status: ?u32 = null;

        self.wait_mutex.lockUncancelable(self.io);
        self.exit_observer = observer;
        if (self.reaped) {
            should_emit = true;
            emit_status = self.exit_status;
        }
        self.wait_mutex.unlock(self.io);

        if (should_emit) {
            observer.callback(observer.context, self.child_pid, emit_status);
        }
    }

    /// Wait up to `timeout_ms` for output, hangup, or an error on the master.
    pub fn pollReadable(self: *const Pty, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.master_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        return (try posix.poll(&fds, timeout_ms)) > 0 and
            (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0;
    }

    /// Non-blocking: `error.WouldBlock` when no output is pending.
    pub fn read(self: *const Pty, buffer: []u8) !usize {
        const n = try posix.read(self.master_fd, buffer);
        assert(n <= buffer.len);
        return n;
    }

    /// Why `write` stopped before delivering every byte.
    pub const WriteError = error{ InputTimeout, InputClosed, WriteZero, BrokenPipe, InputOutput };

    /// Write every byte before the monotonic `deadline_ms` (`sys.monotonicMs`).
    /// The deadline and `stop_fd` are checked before every write attempt,
    /// including after a short write and after `EINTR`, so a terminal that
    /// keeps accepting a few bytes cannot extend the call: `InputClosed` as
    /// soon as `stop_fd` is readable, `InputTimeout` at the deadline (also
    /// when it has already passed on entry). The master is non-blocking; a
    /// full input queue (the child is not reading) is waited out in the same
    /// `poll`. Pass -1 for no stop descriptor.
    pub fn write(self: *Pty, bytes: []const u8, deadline_ms: i64, stop_fd: posix.fd_t) WriteError!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const fd = self.master_fd;
            if (fd < 0) return error.InputClosed;
            const remaining = deadline_ms - sys.monotonicMs();
            if (remaining <= 0) return error.InputTimeout;
            var fds = [_]posix.pollfd{
                .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 },
                .{ .fd = stop_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            const rc = std.c.poll(&fds, fds.len, @intCast(@min(remaining, std.math.maxInt(c_int))));
            if (rc < 0) {
                // The remaining time is recomputed at the top of the loop.
                if (posix.errno(rc) == .INTR) continue;
                return error.InputOutput;
            }
            if (fds[1].revents != 0) return error.InputClosed;
            if (fds[0].revents == 0) continue;

            if (sys.write(fd, bytes[offset..])) |n| {
                if (n == 0) return error.WriteZero;
                offset += n;
                assert(offset <= bytes.len);
            } else |err| switch (err) {
                // poll said writable but the write still would block: back
                // off instead of spinning until the deadline.
                error.WouldBlock => sys.sleepMs(1),
                error.BrokenPipe, error.ConnectionResetByPeer => return error.BrokenPipe,
                else => return error.InputOutput,
            }
        }
    }

    /// Set the terminal window size, which delivers SIGWINCH to the foreground job.
    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var wsz: posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.master_fd < 0) return error.ResizeFailed;
        if (sys.ioctl(self.master_fd, child_mod.tiocswinsz, @intFromPtr(&wsz)) != 0) return error.ResizeFailed;
    }

    /// Current window size, read back from the terminal.
    pub fn windowSize(self: *Pty) !posix.winsize {
        var wsz: posix.winsize = undefined;
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.master_fd < 0) return error.ResizeFailed;
        if (sys.ioctl(self.master_fd, child_mod.tiocgwinsz, @intFromPtr(&wsz)) != 0) return error.ResizeFailed;
        return wsz;
    }

    /// Try to reap and report the result as one tagged state. The reap flag
    /// and the cached wait status are read under the same lock, so a caller
    /// can never observe "reaped" without the status another thread
    /// collected.
    pub fn reap(self: *Pty) ReapState {
        self.wait_mutex.lockUncancelable(self.io);
        const notify = self.refreshReapLocked();
        const result: ReapState = if (self.reaped) .{ .exited = self.exit_status } else .running;
        self.wait_mutex.unlock(self.io);
        self.notifyExit(notify);
        return result;
    }

    /// The wait status when the child has been reaped with one. Null both
    /// while it runs and when it was collected without a status; use `reap`
    /// to tell those apart.
    pub fn reapExited(self: *Pty) ?u32 {
        return switch (self.reap()) {
            .running => null,
            .exited => |status| status,
        };
    }

    /// An observer call deferred until `wait_mutex` is released.
    pub const ExitNotice = struct { observer: ExitObserver, status: ?u32 };

    /// One non-blocking `waitpid` unless already reaped. Returns the
    /// observer to call (after unlocking) when this call collected the child.
    pub fn refreshReapLocked(self: *Pty) ?ExitNotice {
        if (self.reaped) return null;
        switch (child_mod.waitPidNoHang(self.child_pid)) {
            .running => return null,
            .exited => |status| {
                assert(!self.reaped);
                self.reaped = true;
                self.exit_status = status;
                assert(self.reaped);
                const observer = self.exit_observer orelse return null;
                return .{ .observer = observer, .status = status };
            },
        }
    }

    /// Run a deferred observer call. Call without holding `wait_mutex`.
    pub fn notifyExit(self: *Pty, notice: ?ExitNotice) void {
        const active = notice orelse return;
        assert(self.child_pid > 0);
        active.observer.callback(active.observer.context, self.child_pid, active.status);
    }

    /// Whether the child has been collected.
    pub fn isReaped(self: *Pty) bool {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        return self.reaped;
    }

    /// Reap until the child is collected or `timeout_ms` elapses. Returns
    /// whether the child was reaped.
    pub fn waitBlocking(self: *Pty, timeout_ms: i64) bool {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (true) {
            if (self.reap() != .running) return true;
            if (sys.monotonicMs() >= deadline) return false;
            sys.sleepMs(2);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests

test "reap reports a tagged state with the cached wait status" {
    if (!supported_os) return error.SkipZigTest;

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "sleep 0.2; exit 7",
    });
    defer child.close();
    try std.testing.expect(child.reap() == .running);
    try std.testing.expect(child.waitBlocking(5000));
    // Every later caller sees the same status, never a bare "reaped".
    for (0..3) |_| {
        const status = child.reap().exited.?;
        try std.testing.expectEqual(@as(u32, 7), posix.W.EXITSTATUS(status));
    }
}

test "write checks the deadline before every attempt, even when writable" {
    if (!supported_os) return error.SkipZigTest;

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "exec sleep 100",
    });
    defer proc.cleanupPtyForTest(&child);
    // The terminal is writable, but the deadline has passed.
    try std.testing.expectError(error.InputTimeout, child.write("x\n", sys.monotonicMs() - 1, -1));

    // A readable stop descriptor wins over a writable terminal.
    const stop = try sys.pipeCloexec();
    defer sys.close(stop[0]);
    defer sys.close(stop[1]);
    _ = try sys.write(stop[1], "x");
    try std.testing.expectError(error.InputClosed, child.write("x\n", sys.monotonicMs() + 2000, stop[0]));
    // An empty write has nothing to wait for.
    try child.write("", sys.monotonicMs() - 1, stop[0]);
}

fn lineBlock(allocator: Allocator, total: usize) ![]u8 {
    // Newline-terminated lines: in canonical mode the kernel discards
    // overflow on an unterminated line instead of applying backpressure.
    const data = try allocator.alloc(u8, total);
    for (data, 0..) |*byte, index| byte.* = if (index % 64 == 63) '\n' else 'x';
    return data;
}

test "write times out when the child never reads" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer proc.cleanupPtyForTest(&child);
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);

    const started = sys.monotonicMs();
    try std.testing.expectError(error.InputTimeout, child.write(data, started + 300, -1));
    const elapsed = sys.monotonicMs() - started;
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < 600);

    // An already-expired deadline fails without waiting once the queue is full.
    const again = sys.monotonicMs();
    try std.testing.expectError(error.InputTimeout, child.write(data, again - 1, -1));
    try std.testing.expect(sys.monotonicMs() - again < 100);
}

const StopWriter = struct {
    fd: posix.fd_t,
    delay_ms: i64,

    fn run(self: *StopWriter) void {
        sys.sleepMs(self.delay_ms);
        _ = sys.write(self.fd, "x") catch |err| log.warn("pty_test_stop_write_failed", .{ .err = err });
    }
};

test "write is cancelled by the stop descriptor" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer proc.cleanupPtyForTest(&child);
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);
    const stop = try sys.pipeCloexec();
    defer sys.close(stop[0]);
    defer sys.close(stop[1]);

    var stopper = StopWriter{ .fd = stop[1], .delay_ms = 100 };
    const thread = try std.Thread.spawn(.{}, StopWriter.run, .{&stopper});
    const started = sys.monotonicMs();
    const result = child.write(data, started + 30_000, stop[0]);
    const elapsed = sys.monotonicMs() - started;
    thread.join();
    try std.testing.expectError(error.InputClosed, result);
    try std.testing.expect(elapsed >= 90);
    try std.testing.expect(elapsed < 100 + 150);
}

test "write delivers input to a reading child and fails after close" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "read line; echo echoed=[$line]",
    });
    defer proc.cleanupPtyForTest(&child);
    try child.write("", sys.monotonicMs() + 1000, -1);
    try child.write("hello\n", sys.monotonicMs() + 2000, -1);
    const output = try proc.collectOutput(allocator, &child, 10_000);
    defer allocator.free(output);
    try proc.expectContains(output, "echoed=[hello]");

    child.close();
    try std.testing.expectError(error.InputClosed, child.write("late", sys.monotonicMs() + 1000, -1));
    try std.testing.expectError(error.ResizeFailed, child.resize(80, 24));
    child.close();
}

test "resize round-trips the window size through the terminal" {
    if (!supported_os) return error.SkipZigTest;

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "exec sleep 100",
        .rows = 30,
        .cols = 100,
    });
    defer proc.cleanupPtyForTest(&child);
    const initial = try child.windowSize();
    try std.testing.expectEqual(@as(u16, 30), initial.row);
    try std.testing.expectEqual(@as(u16, 100), initial.col);

    try child.resize(132, 43);
    const resized = try child.windowSize();
    try std.testing.expectEqual(@as(u16, 43), resized.row);
    try std.testing.expectEqual(@as(u16, 132), resized.col);
}
