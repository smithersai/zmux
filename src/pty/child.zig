//! Child-side process plumbing: opening the PTY pair, the async-signal-safe
//! code that runs between `fork` and `exec`, the startup receipt protocol,
//! and the low-level `waitpid` helpers.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const posix = std.posix;
const sys = @import("../sys.zig");
const pty = @import("../pty.zig");

const ChildSetupStage = pty.ChildSetupStage;
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();
const supported_os = is_linux or is_darwin;

extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
/// The terminal's foreground process group, from libc.
pub extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;

/// Budget for collecting a child that was sent SIGKILL after a failed
/// handshake.
pub const child_setup_reap_budget_ms: i64 = 2000;

/// Test seam: the forked child blocks before any setup step, as if `chdir`
/// or `exec` hung.
pub var test_stall_child_setup: bool = false;

// ioctl request numbers at their native `unsigned long` width (see
// `sys.ioctl`). Darwin's are spelled out: its `_IOW` requests have the top
// bit set and must not be sign-extended.
/// `TIOCSWINSZ`: set the window size.
pub const tiocswinsz: c_ulong = if (is_darwin) 0x80087467 else posix.T.IOCSWINSZ;
/// `TIOCGWINSZ`: read the window size.
pub const tiocgwinsz: c_ulong = if (is_darwin) 0x40087468 else posix.T.IOCGWINSZ;
const tiocsctty: c_ulong = if (is_darwin) 0x20007461 else posix.T.IOCSCTTY;

/// Both ends of a freshly opened PTY pair.
pub const OpenPtyResult = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
};

/// Open a PTY pair. Both ends are close-on-exec; the master is non-blocking.
pub fn openPty(wsz: posix.winsize) !OpenPtyResult {
    var master_fd: posix.fd_t = undefined;
    var slave_fd: posix.fd_t = undefined;

    if (is_linux) {
        // Atomic close-on-exec on both ends: no window for a concurrent fork.
        const flags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        master_fd = posix_openpt(@bitCast(flags));
        if (master_fd < 0) return error.OpenPtyFailed;
        errdefer sys.close(master_fd);
        var name_buf: [128]u8 = undefined;
        if (grantpt(master_fd) != 0 or unlockpt(master_fd) != 0 or
            ptsname_r(master_fd, &name_buf, name_buf.len) != 0) return error.OpenPtyFailed;
        const name: [*:0]const u8 = @ptrCast(&name_buf);
        slave_fd = sys.openZ(name, flags, 0) catch return error.OpenPtyFailed;
        errdefer sys.close(slave_fd);
        var size = wsz;
        if (sys.ioctl(master_fd, tiocswinsz, @intFromPtr(&size)) != 0) return error.OpenPtyFailed;
    } else {
        // No atomic form: hold the fork lock until both ends are marked.
        if (is_darwin) sys.fork_lock.lockShared();
        defer if (is_darwin) sys.fork_lock.unlockShared();
        if (openpty(&master_fd, &slave_fd, null, null, &wsz) != 0) return error.OpenPtyFailed;
        errdefer sys.close(master_fd);
        errdefer sys.close(slave_fd);
        try sys.setCloseOnExec(master_fd);
        try sys.setCloseOnExec(slave_fd);
    }
    errdefer sys.close(master_fd);
    errdefer sys.close(slave_fd);

    assert(master_fd >= 0);
    assert(slave_fd >= 0);
    try sys.setNonBlocking(master_fd);
    return .{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
    };
}

/// A Linux pidfd for `pid`, or -1 when unavailable (other systems, old kernels).
pub fn openPidFd(pid: posix.pid_t) posix.fd_t {
    assert(pid > 0);
    if (!is_linux) return -1;
    // pidfds are close-on-exec by construction. ENOSYS on kernels < 5.3.
    const rc = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return -1;
    return @intCast(rc);
}

/// Result of one non-blocking `waitpid`.
pub const WaitPidNoHangResult = union(enum) {
    running,
    exited: ?u32,
};

/// One `waitpid(WNOHANG)`, retried on `EINTR`. A child collected elsewhere
/// counts as exited with an unknown status.
pub fn waitPidNoHang(pid: posix.pid_t) WaitPidNoHangResult {
    assert(pid > 0);
    while (true) {
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, @intCast(posix.W.NOHANG));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return .running;
                return .{ .exited = @bitCast(status) };
            },
            .INTR => continue,
            // Already collected elsewhere (for example SIGCHLD is ignored).
            .CHILD => return .{ .exited = null },
            // Nothing else is documented for waitpid; treat it as "gone with
            // an unknown status" instead of crashing the daemon.
            else => |err| {
                std.log.warn("zmux-pty: waitpid({d}) failed: {s}", .{ pid, @tagName(err) });
                return .{ .exited = null };
            },
        }
    }
}

/// Blocking reap for a child known to be exiting.
pub fn reapBlocking(pid: posix.pid_t) void {
    assert(pid > 0);
    while (true) {
        const rc = std.c.waitpid(pid, null, 0);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return;
    }
}

/// SIGKILL a child whose setup handshake did not complete, then reap it
/// within `child_setup_reap_budget_ms`. The group is addressed too: the
/// child may already have called `setsid` and, after an unconfirmed `exec`,
/// started other processes.
pub fn killAndReap(pid: posix.pid_t) void {
    assert(pid > 0);
    _ = sys.kill(-pid, .KILL);
    _ = sys.kill(pid, .KILL);
    const deadline = sys.monotonicMs() + child_setup_reap_budget_ms;
    while (true) {
        switch (waitPidNoHang(pid)) {
            .exited => return,
            .running => {},
        }
        if (sys.monotonicMs() >= deadline) {
            std.log.warn("zmux-pty: child {d} not reaped {d} ms after SIGKILL", .{ pid, child_setup_reap_budget_ms });
            return;
        }
        sys.sleepMs(1);
    }
}

/// Bytes in a startup failure report: one stage byte and an `i32` errno.
pub const child_report_len = 1 + @sizeOf(i32);

/// What the startup pipe said about a forked child.
pub const ChildReport = union(enum) {
    /// EOF with no bytes: the close-on-exec write end vanished in `exec`.
    exec_ok,
    /// The child reported a failed setup step and called `_exit`. A partial
    /// report (the child died mid-write) has stage `unknown`.
    failed: struct { stage: ChildSetupStage, errno: posix.E },
    /// Neither EOF nor a complete report arrived before the deadline.
    timed_out,
    /// Reading the pipe failed; nothing is known about the child.
    io_error: posix.E,
};

/// Wait for the child's startup receipt until the monotonic `deadline_ms`.
pub fn readChildReport(fd: posix.fd_t, deadline_ms: i64) ChildReport {
    assert(fd >= 0);
    var report: [child_report_len]u8 = undefined;
    var got: usize = 0;
    while (got < report.len) {
        const remaining = deadline_ms - sys.monotonicMs();
        if (remaining <= 0) return .timed_out;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&fds, fds.len, @intCast(@min(remaining, std.math.maxInt(c_int))));
        if (ready < 0) {
            if (posix.errno(ready) == .INTR) continue;
            return .{ .io_error = posix.errno(ready) };
        }
        if (ready == 0) continue;

        const rc = std.c.read(fd, report[got..].ptr, report.len - got);
        if (rc < 0) {
            switch (posix.errno(rc)) {
                .INTR, .AGAIN => continue,
                else => |err| return .{ .io_error = err },
            }
        }
        if (rc == 0) break;
        got += @intCast(rc);
        assert(got <= report.len);
    }
    if (got == 0) return .exec_ok;
    if (got < report.len) return .{ .failed = .{ .stage = .unknown, .errno = .SUCCESS } };
    const raw_errno = std.mem.readInt(i32, report[1..5], .little);
    return .{ .failed = .{
        .stage = std.enums.fromInt(ChildSetupStage, report[0]) orelse .unknown,
        .errno = errnoFromReport(raw_errno),
    } };
}

/// The errno a child reported, or `.SUCCESS` when it is out of range.
pub fn errnoFromReport(raw_errno: i32) posix.E {
    if (raw_errno < 0 or raw_errno > std.math.maxInt(u16)) return .SUCCESS;
    return @fromBackingInt(@intCast(@as(u16, @intCast(raw_errno))));
}

/// Async-signal-safe. Report `stage` and the current `errno` to the parent,
/// then exit. The write is retried on `EINTR` and after a short write, so a
/// signal cannot turn a failure report into a partial one.
fn childFail(err_fd: posix.fd_t, stage: ChildSetupStage, errno_value: c_int) noreturn {
    var report: [child_report_len]u8 = undefined;
    report[0] = @backingInt(stage);
    std.mem.writeInt(i32, report[1..5], @intCast(errno_value), .little);
    var sent: usize = 0;
    while (sent < report.len) {
        const rc = std.c.write(err_fd, report[sent..].ptr, report.len - sent);
        if (rc < 0) {
            if (std.c._errno().* == @backingInt(posix.E.INTR)) continue;
            break;
        }
        if (rc == 0) break;
        sent += @intCast(rc);
    }
    std.c._exit(127);
}

/// Runs in the forked child. Async-signal-safe: no allocation, no locks, no
/// `getenv`, no formatted output. Never returns.
///
/// Descriptor plan: stdio (0-2) becomes the slave; the error pipe is parked
/// on fd 3 with `FD_CLOEXEC`, so `closeFrom(4)` plus `exec` leaves the
/// program with exactly 0, 1 and 2. This holds even when the parent had
/// stdio closed and the slave or the pipe was allocated at 0-2.
pub fn childExec(
    slave_fd_in: posix.fd_t,
    err_fd_in: posix.fd_t,
    cwd_z: ?[*:0]const u8,
    candidates: [*:null]const ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    sys.resetChildSignals();

    if (builtin.is_test and test_stall_child_setup) {
        // Block forever, like a `chdir` onto a dead mount. The parent's
        // handshake deadline must kill this process.
        var none: [0]posix.pollfd = .{};
        while (true) _ = std.c.poll(&none, 0, -1);
    }

    // Lift both descriptors out of the stdio range before it is rewritten.
    var err_fd = err_fd_in;
    if (err_fd < 3) {
        const moved = std.c.fcntl(err_fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) std.c._exit(127);
        err_fd = moved;
    }
    var slave_fd = slave_fd_in;
    if (slave_fd < 3) {
        const moved = std.c.fcntl(slave_fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) childFail(err_fd, .dup2, std.c._errno().*);
        slave_fd = moved;
    }

    if (std.c.setsid() < 0) childFail(err_fd, .setsid, std.c._errno().*);
    if (sys.ioctl(slave_fd, tiocsctty, 0) != 0) childFail(err_fd, .ctty, std.c._errno().*);

    var stdio: posix.fd_t = 0;
    while (stdio < 3) : (stdio += 1) {
        sys.dup2(slave_fd, stdio) catch childFail(err_fd, .dup2, std.c._errno().*);
    }
    if (err_fd != 3) {
        sys.dup2(err_fd, 3) catch childFail(err_fd, .dup2, std.c._errno().*);
        err_fd = 3;
        if (std.c.fcntl(err_fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) {
            childFail(err_fd, .dup2, std.c._errno().*);
        }
    }
    sys.closeFrom(4);

    if (cwd_z) |cwd| {
        if (std.c.chdir(cwd) != 0) childFail(err_fd, .chdir, std.c._errno().*);
    }

    // execvp(3) semantics over the pre-resolved candidates: keep searching on
    // "not here", but remember a permission failure so a later miss does not
    // hide it.
    var last_errno: c_int = @backingInt(posix.E.NOENT);
    var index: usize = 0;
    while (candidates[index]) |candidate| : (index += 1) {
        _ = std.c.execve(candidate, argv, envp);
        const errno_value = std.c._errno().*;
        switch (@as(posix.E, @fromBackingInt(@intCast(errno_value)))) {
            .NOENT, .NOTDIR => {},
            .ACCES, .PERM => last_errno = errno_value,
            else => childFail(err_fd, .exec, errno_value),
        }
    }
    childFail(err_fd, .exec, last_errno);
}

// ---------------------------------------------------------------------------
// Tests

test "open pty marks both ends close-on-exec and the master non-blocking" {
    if (!supported_os) return error.SkipZigTest;

    const fds = try openPty(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    defer sys.close(fds.master_fd);
    defer sys.close(fds.slave_fd);

    try std.testing.expect(try sys.isCloseOnExec(fds.master_fd));
    try std.testing.expect(try sys.isCloseOnExec(fds.slave_fd));
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds.master_fd, &buf));
}

test "the startup receipt distinguishes exec, failure, timeout and read errors" {
    if (!supported_os) return error.SkipZigTest;

    {
        // EOF with no bytes is the only confirmation of a successful exec.
        const fds = try sys.pipeCloexec();
        defer sys.close(fds[0]);
        sys.close(fds[1]);
        try std.testing.expect(readChildReport(fds[0], sys.monotonicMs() + 1000) == .exec_ok);
    }
    {
        const fds = try sys.pipeCloexec();
        defer sys.close(fds[0]);
        var report: [child_report_len]u8 = undefined;
        report[0] = @backingInt(ChildSetupStage.chdir);
        std.mem.writeInt(i32, report[1..5], @backingInt(posix.E.NOENT), .little);
        try sys.writeAll(fds[1], &report);
        sys.close(fds[1]);
        const result = readChildReport(fds[0], sys.monotonicMs() + 1000);
        try std.testing.expectEqual(ChildSetupStage.chdir, result.failed.stage);
        try std.testing.expectEqual(posix.E.NOENT, result.failed.errno);
    }
    {
        // A partial report followed by EOF: the child died mid-write.
        const fds = try sys.pipeCloexec();
        defer sys.close(fds[0]);
        try sys.writeAll(fds[1], "\x04\x02");
        sys.close(fds[1]);
        const result = readChildReport(fds[0], sys.monotonicMs() + 1000);
        try std.testing.expectEqual(ChildSetupStage.unknown, result.failed.stage);
    }
    {
        // The write end stays open and silent: a timeout, not a success.
        const fds = try sys.pipeCloexec();
        defer sys.close(fds[0]);
        defer sys.close(fds[1]);
        const started = sys.monotonicMs();
        try std.testing.expect(readChildReport(fds[0], started + 60) == .timed_out);
        try std.testing.expect(sys.monotonicMs() - started >= 60);
        // A partial report does not turn a timeout into a result either.
        try sys.writeAll(fds[1], "\x04");
        try std.testing.expect(readChildReport(fds[0], sys.monotonicMs() + 60) == .timed_out);
        try std.testing.expect(readChildReport(fds[0], sys.monotonicMs() - 1) == .timed_out);
    }
    {
        // A read failure is an error, never a confirmed exec. Reading from
        // the write end of a pipe fails with EBADF.
        const fds = try sys.pipeCloexec();
        defer sys.close(fds[0]);
        defer sys.close(fds[1]);
        try sys.writeAll(fds[1], "x");
        const result = readChildReport(fds[1], sys.monotonicMs() + 200);
        try std.testing.expect(result == .io_error or result == .timed_out);
        try std.testing.expect(result != .exec_ok);
    }
}
