//! Async-signal-safe helpers a forked child runs before `exec`: closing every
//! inherited descriptor above a floor and resetting signal state.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../sys.zig");
const fd_io = @import("fd.zig");

const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const fd_t = sys.fd_t;

const is_darwin = builtin.os.tag.isDarwin();

/// Upper bound of the last-resort descriptor scan of `closeFrom`.
const close_from_scan_cap: fd_t = 65536;

/// Async-signal-safe. Close every descriptor `>= low_fd`.
///
/// `close_range(2)` on Linux. Otherwise (Darwin, and Linux kernels without
/// `close_range`) the open descriptors are enumerated from the kernel
/// (`proc_pidinfo` on Darwin, `/proc/self/fd` on Linux), so a descriptor that
/// was opened before `RLIMIT_NOFILE` was lowered is closed even though it
/// lies above the current soft limit. Only when enumeration fails does this
/// fall back to a numeric scan, bounded by the larger of the soft and hard
/// limits and capped so an unlimited rlimit cannot stall the child.
pub fn closeFrom(low_fd: fd_t) void {
    assert(low_fd >= 0);
    if (builtin.os.tag == .linux) {
        if (!sys.force_close_from_fallback) {
            const rc = std.os.linux.close_range(low_fd, std.math.maxInt(fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
            if (std.os.linux.errno(rc) == .SUCCESS) return;
        }
        if (closeFromProcSelfFd(low_fd)) return;
    } else if (is_darwin) {
        if (closeFromDarwinFdList(low_fd)) return;
    }
    var limit: c.rlimit = undefined;
    const max_fd: fd_t = if (c.getrlimit(.NOFILE, &limit) == 0)
        @intCast(@min(@max(limit.cur, limit.max), close_from_scan_cap))
    else
        close_from_scan_cap;
    assert(max_fd <= close_from_scan_cap);
    var fd = low_fd;
    while (fd < max_fd) : (fd += 1) _ = c.close(fd);
}

const darwin = struct {
    const proc_pidlistfds: c_int = 1;
    const ProcFdInfo = extern struct { proc_fd: i32, proc_fdtype: u32 };
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
};

/// Async-signal-safe: `proc_pidinfo` is a bare system call and the list
/// lives on the stack. Returns false when the kernel list is unavailable.
fn closeFromDarwinFdList(low_fd: fd_t) bool {
    if (!is_darwin) return false;
    var entries: [1024]darwin.ProcFdInfo = undefined;
    const pid = c.getpid();
    // Each pass closes every listed descriptor at or above the floor, so a
    // table larger than the buffer drains over several passes. The cap only
    // guards against a kernel that keeps reporting descriptors that cannot
    // be closed.
    var pass: usize = 0;
    while (pass < 4096) : (pass += 1) {
        const bytes = darwin.proc_pidinfo(pid, darwin.proc_pidlistfds, 0, &entries, @sizeOf(@TypeOf(entries)));
        if (bytes <= 0) return false;
        const count = @as(usize, @intCast(bytes)) / @sizeOf(darwin.ProcFdInfo);
        assert(count <= entries.len);
        var closed: usize = 0;
        for (entries[0..count]) |entry| {
            if (entry.proc_fd < low_fd) continue;
            if (c.close(entry.proc_fd) == 0) closed += 1;
        }
        // A short list is the whole table: nothing at or above the floor
        // is left once this pass closed nothing.
        if (closed == 0) return count < entries.len;
    }
    return false;
}

/// Async-signal-safe: raw `open`/`getdents64` with a stack buffer, no
/// `opendir`. Returns false when `/proc/self/fd` cannot be read.
fn closeFromProcSelfFd(low_fd: fd_t) bool {
    if (builtin.os.tag != .linux) return false;
    const linux = std.os.linux;
    const dir_flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const dir_fd = c.open("/proc/self/fd", dir_flags, @as(c.mode_t, 0));
    if (dir_fd < 0) return false;
    defer _ = c.close(dir_fd);

    var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    // Closing entries invalidates the directory position, so every pass
    // restarts from the top until one closes nothing.
    var pass: usize = 0;
    while (pass < 4096) : (pass += 1) {
        if (linux.errno(linux.lseek(dir_fd, 0, 0)) != .SUCCESS) return false;
        var closed: usize = 0;
        while (true) {
            const rc = linux.getdents64(dir_fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return false,
            }
            if (rc == 0) break;
            var offset: usize = 0;
            while (offset < rc) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&buf[offset]);
                const name: [*:0]const u8 = @ptrCast(&buf[offset + @offsetOf(linux.dirent64, "name")]);
                assert(entry.reclen > 0);
                offset += entry.reclen;
                const fd = parseFdName(name) orelse continue;
                if (fd < low_fd or fd == dir_fd) continue;
                if (c.close(fd) == 0) closed += 1;
            }
        }
        if (closed == 0) return true;
    }
    return false;
}

/// Decimal descriptor number, or null for `.`, `..` and anything else.
fn parseFdName(name: [*:0]const u8) ?fd_t {
    var value: u32 = 0;
    var index: usize = 0;
    while (name[index] != 0) : (index += 1) {
        const digit = name[index];
        if (digit < '0' or digit > '9' or index >= 9) return null;
        value = value * 10 + (digit - '0');
    }
    if (index == 0) return null;
    assert(index <= 9);
    assert(value <= 999_999_999);
    return @intCast(value);
}

/// Signals `resetChildSignals` restores to `SIG_DFL`.
pub const child_reset_signals = [_]posix.SIG{ .HUP, .INT, .QUIT, .TERM, .PIPE, .CHLD, .TSTP, .TTIN, .TTOU, .WINCH };

/// Async-signal-safe. Restore default dispositions for job-control and
/// termination signals and clear the signal mask, so a pane child does not
/// inherit the daemon's ignored `SIGHUP`/`SIGPIPE` or a blocked mask.
pub fn resetChildSignals() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (child_reset_signals) |sig| posix.sigaction(sig, &act, null);
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
}

// ---------------------------------------------------------------------------

/// Fork a child that runs `body` and reports one status byte via `_exit`.
fn forkAndCollect(comptime body: fn () u8) !u8 {
    const pid = try sys.fork();
    if (pid == 0) c._exit(body());
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        if (rc == pid) break;
        if (posix.errno(rc) != .INTR) return error.WaitFailed;
    }
    const raw: u32 = @bitCast(status);
    if (!posix.W.IFEXITED(raw)) return error.ChildCrashed;
    return posix.W.EXITSTATUS(raw);
}

fn closeFromChildBody() u8 {
    // Fds 40 and 60 were opened by the parent; after closeFrom(41) only 40
    // may survive.
    closeFrom(41);
    if (c.fcntl(40, c.F.GETFD) < 0) return 1;
    if (c.fcntl(60, c.F.GETFD) >= 0) return 2;
    if (c.fcntl(41, c.F.GETFD) >= 0) return 3;
    closeFrom(3);
    if (c.fcntl(40, c.F.GETFD) >= 0) return 4;
    if (c.fcntl(2, c.F.GETFD) < 0) return 5;
    return 0;
}

test "closeFrom closes every descriptor at or above the floor" {
    const fds = try fd_io.pipe();
    defer fd_io.close(fds[0]);
    defer fd_io.close(fds[1]);
    try fd_io.dup2(fds[0], 40);
    defer fd_io.close(40);
    try fd_io.dup2(fds[0], 41);
    defer fd_io.close(41);
    try fd_io.dup2(fds[1], 60);
    defer fd_io.close(60);

    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(closeFromChildBody));
    // The parent's descriptors are untouched.
    try std.testing.expect(c.fcntl(60, c.F.GETFD) >= 0);
}

fn closeFromAboveLimitChildBody() u8 {
    // Fd 200 was opened under the original limit. Lower the soft and hard
    // limits beneath it: a scan bounded by RLIMIT_NOFILE would miss it.
    const lowered: c.rlimit = .{ .cur = 64, .max = 64 };
    if (c.setrlimit(.NOFILE, &lowered) != 0) return 10;
    if (c.fcntl(200, c.F.GETFD) < 0) return 11;
    closeFrom(3);
    if (c.fcntl(200, c.F.GETFD) >= 0) return 1;
    if (c.fcntl(40, c.F.GETFD) >= 0) return 2;
    if (c.fcntl(2, c.F.GETFD) < 0) return 3;
    return 0;
}

test "closeFrom closes descriptors above a lowered descriptor limit" {
    const fds = try fd_io.pipe();
    defer fd_io.close(fds[0]);
    defer fd_io.close(fds[1]);
    try fd_io.dup2(fds[0], 40);
    defer fd_io.close(40);
    try fd_io.dup2(fds[1], 200);
    defer fd_io.close(200);

    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(closeFromAboveLimitChildBody));

    // The enumeration path, which Linux otherwise reaches only on kernels
    // without close_range(2).
    sys.force_close_from_fallback = true;
    defer sys.force_close_from_fallback = false;
    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(closeFromAboveLimitChildBody));
    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(closeFromChildBody));
    try std.testing.expect(c.fcntl(200, c.F.GETFD) >= 0);
}

fn closeFromManyChildBody() u8 {
    // More descriptors than one enumeration buffer holds.
    var made: usize = 0;
    while (made < 1500) : (made += 1) {
        if (c.dup(0) < 0) break;
    }
    if (made < 1100) return 20;
    closeFrom(3);
    var fd: fd_t = 3;
    while (fd < 2000) : (fd += 1) {
        if (c.fcntl(fd, c.F.GETFD) >= 0) return 1;
    }
    return 0;
}

test "closeFrom drains a descriptor table larger than its enumeration buffer" {
    var limit: c.rlimit = undefined;
    if (c.getrlimit(.NOFILE, &limit) != 0 or limit.cur < 1600) return error.SkipZigTest;
    sys.force_close_from_fallback = true;
    defer sys.force_close_from_fallback = false;
    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(closeFromManyChildBody));
}

test "parseFdName accepts only decimal descriptor numbers" {
    try std.testing.expectEqual(@as(?fd_t, 0), parseFdName("0"));
    try std.testing.expectEqual(@as(?fd_t, 1234), parseFdName("1234"));
    try std.testing.expectEqual(@as(?fd_t, null), parseFdName("."));
    try std.testing.expectEqual(@as(?fd_t, null), parseFdName(".."));
    try std.testing.expectEqual(@as(?fd_t, null), parseFdName(""));
    try std.testing.expectEqual(@as(?fd_t, null), parseFdName("12a"));
    try std.testing.expectEqual(@as(?fd_t, null), parseFdName("12345678901"));
}

fn signalResetChildBody() u8 {
    resetChildSignals();
    for (child_reset_signals, 0..) |sig, index| {
        var current: posix.Sigaction = undefined;
        posix.sigaction(sig, null, &current);
        if (current.handler.handler != posix.SIG.DFL) return @intCast(10 + index);
    }
    var mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.SETMASK, null, &mask);
    if (!std.mem.eql(u8, std.mem.asBytes(&mask), std.mem.asBytes(&posix.sigemptyset()))) return 1;
    return 0;
}

test "resetChildSignals restores default dispositions and an empty mask" {
    // Give the forked child something to undo: ignored HUP/PIPE and a blocked
    // TERM, as a daemon would have.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old_hup: posix.Sigaction = undefined;
    var old_pipe: posix.Sigaction = undefined;
    posix.sigaction(.HUP, &ignore, &old_hup);
    defer posix.sigaction(.HUP, &old_hup, null);
    posix.sigaction(.PIPE, &ignore, &old_pipe);
    defer posix.sigaction(.PIPE, &old_pipe, null);

    var blocked = posix.sigemptyset();
    posix.sigaddset(&blocked, .TERM);
    var old_mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &blocked, &old_mask);
    defer posix.sigprocmask(posix.SIG.SETMASK, &old_mask, null);

    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(signalResetChildBody));
}
