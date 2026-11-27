//! Darwin and BSD `kqueue(2)` backend for `src/reactor.zig`.
//!
//! Uses `EVFILT_READ` / `EVFILT_WRITE` for descriptors, `EVFILT_PROC` +
//! `NOTE_EXIT` for process exits, and `EVFILT_USER` + `NOTE_TRIGGER` for
//! lock-free cross-thread wakeups.

const std = @import("std");
const builtin = @import("builtin");

const reactor = @import("../reactor.zig");
const sys = @import("../sys.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;

const is_darwin = builtin.os.tag.isDarwin();
const wake_ident: usize = 0x5A4D_5558;
const max_batch: usize = 128;

const FdEntry = struct {
    token: u64,
    interests: reactor.Interests,
};

/// `kqueue(2)` reactor backend implementation.
pub const Backend = struct {
    allocator: Allocator,
    kq: posix.fd_t,
    fds: std.AutoHashMapUnmanaged(posix.fd_t, FdEntry) = .empty,
    pids: std.AutoHashMapUnmanaged(posix.pid_t, u64) = .empty,

    /// Create a close-on-exec kqueue and register the `EVFILT_USER` wake knote.
    pub fn init(allocator: Allocator) reactor.Error!Backend {
        const kq = try openKqueueCloexec();
        assert(kq >= 0);
        errdefer sys.close(kq);

        const reg: c.Kevent = .{
            .ident = wake_ident,
            .filter = c.EVFILT.USER,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
            .fflags = c.NOTE.FFNOP,
            .data = 0,
            .udata = 0,
        };
        try applyChange(kq, reg);
        return .{ .allocator = allocator, .kq = kq };
    }

    /// Close the kqueue descriptor and free tracking maps.
    pub fn deinit(self: *Backend) void {
        assert(self.kq >= 0);
        self.fds.deinit(self.allocator);
        self.pids.deinit(self.allocator);
        sys.close(self.kq);
        self.kq = -1;
    }

    /// True while the underlying kqueue descriptor is open.
    pub fn isOpen(self: *const Backend) bool {
        return self.kq >= 0;
    }

    /// True if `fd` is tracked in this backend.
    pub fn hasFd(self: *const Backend, fd: posix.fd_t) bool {
        return self.fds.contains(fd);
    }

    /// True if `pid` is tracked in this backend.
    pub fn hasPid(self: *const Backend, pid: posix.pid_t) bool {
        return self.pids.contains(pid);
    }

    /// Count of watched file descriptors.
    pub fn fdCount(self: *const Backend) usize {
        return self.fds.count();
    }

    /// Count of watched process ids.
    pub fn pidCount(self: *const Backend) usize {
        return self.pids.count();
    }

    /// Register `fd` with `interests` and correlation `token`.
    pub fn watchFd(
        self: *Backend,
        fd: posix.fd_t,
        token: u64,
        interests: reactor.Interests,
    ) reactor.Error!void {
        assert(self.kq >= 0);
        assert(fd >= 0);
        if (self.fds.contains(fd)) return error.AlreadyWatched;
        try self.fds.ensureUnusedCapacity(self.allocator, 1);

        const none: reactor.Interests = .{ .read = false, .write = false };
        try syncFilters(self.kq, fd, token, none, token, interests);
        self.fds.putAssumeCapacity(fd, .{ .token = token, .interests = interests });
        assert(self.fds.contains(fd));
    }

    /// Update `token` and `interests` for an already-watched `fd`.
    pub fn modifyFd(
        self: *Backend,
        fd: posix.fd_t,
        token: u64,
        interests: reactor.Interests,
    ) reactor.Error!void {
        assert(self.kq >= 0);
        assert(fd >= 0);
        const entry = self.fds.getPtr(fd) orelse return error.NotFound;
        try syncFilters(self.kq, fd, entry.token, entry.interests, token, interests);
        entry.* = .{ .token = token, .interests = interests };
        assert(entry.token == token);
    }

    /// Remove any registered filters for `fd` and drop it from the table.
    pub fn unwatchFd(self: *Backend, fd: posix.fd_t) void {
        assert(self.kq >= 0);
        const removed = self.fds.fetchRemove(fd) orelse return;
        if (removed.value.interests.read) deleteFilter(self.kq, fd, c.EVFILT.READ);
        if (removed.value.interests.write) deleteFilter(self.kq, fd, c.EVFILT.WRITE);
    }

    /// Arm an `EVFILT_PROC` + `NOTE_EXIT` watch for `pid`.
    pub fn watchPid(self: *Backend, pid: posix.pid_t, token: u64) reactor.Error!reactor.WatchPidResult {
        assert(self.kq >= 0);
        assert(pid > 0);
        if (self.pids.contains(pid)) return error.AlreadyWatched;
        try self.pids.ensureUnusedCapacity(self.allocator, 1);

        const change: c.Kevent = .{
            .ident = @intCast(pid),
            .filter = c.EVFILT.PROC,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
            .fflags = c.NOTE.EXIT,
            .data = 0,
            .udata = @truncate(token),
        };
        applyChange(self.kq, change) catch |err| switch (err) {
            error.NotFound => return .already_exited,
            else => return err,
        };
        self.pids.putAssumeCapacity(pid, token);
        assert(self.pids.contains(pid));
        return .watching;
    }

    /// Remove an active `EVFILT_PROC` watch for `pid`.
    pub fn unwatchPid(self: *Backend, pid: posix.pid_t) void {
        assert(self.kq >= 0);
        if (!self.pids.remove(pid)) return;
        deleteFilter(self.kq, pid, c.EVFILT.PROC);
    }

    /// Trigger the `EVFILT_USER` wake knote from any thread.
    pub fn wake(self: *Backend) reactor.Error!void {
        assert(self.kq >= 0);
        const trigger: c.Kevent = .{
            .ident = wake_ident,
            .filter = c.EVFILT.USER,
            .flags = 0,
            .fflags = c.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        };
        try applyChange(self.kq, trigger);
    }

    /// Block in `kevent(2)` up to `timeout_ms`, retrying `EINTR`.
    pub fn wait(self: *Backend, out: []reactor.Event, timeout_ms: ?i32) reactor.Error![]reactor.Event {
        assert(self.kq >= 0);
        assert(out.len > 0);
        const deadline_ms: ?i64 = if (timeout_ms) |ms|
            if (ms > 0) sys.monotonicMs() + @as(i64, ms) else null
        else
            null;

        var raw: [max_batch]c.Kevent = undefined;
        const cap: c_int = @intCast(@min(out.len, raw.len));
        const empty_changes: [0]c.Kevent = .{};

        while (true) {
            var ts: c.timespec = undefined;
            const ts_ptr = computeTimespec(&ts, timeout_ms, deadline_ms) orelse return out[0..0];
            const rc = c.kevent(self.kq, &empty_changes, 0, &raw, cap, ts_ptr);
            switch (posix.errno(rc)) {
                .SUCCESS => return self.decodeBatch(raw[0..@intCast(rc)], out),
                .INTR => continue,
                else => |err| return mapKeventErrno(err),
            }
        }
    }

    fn decodeBatch(self: *Backend, raw: []const c.Kevent, out: []reactor.Event) []reactor.Event {
        assert(raw.len <= out.len);
        var count: usize = 0;
        for (raw) |kev| {
            if (self.decodeEvent(kev)) |ev| {
                out[count] = ev;
                count += 1;
            }
        }
        assert(count <= out.len);
        return out[0..count];
    }

    fn decodeEvent(self: *Backend, kev: c.Kevent) ?reactor.Event {
        if (kev.filter == c.EVFILT.USER and kev.ident == wake_ident) {
            return .{ .kind = .wakeup, .token = 0 };
        }
        if (kev.filter == c.EVFILT.PROC) {
            const pid: posix.pid_t = @intCast(kev.ident);
            const token = if (self.pids.fetchRemove(pid)) |kv| kv.value else @as(u64, kev.udata);
            return .{ .kind = .pid_exited, .token = token, .pid = pid, .data = @intCast(kev.data) };
        }
        const fd: posix.fd_t = @intCast(kev.ident);
        const token = if (self.fds.get(fd)) |entry| entry.token else @as(u64, kev.udata);
        if ((kev.flags & c.EV.ERROR) != 0) {
            return .{ .kind = .fd_err, .token = token, .fd = fd, .data = @intCast(kev.data) };
        }
        if (kev.filter == c.EVFILT.READ) {
            const is_eof = (kev.flags & c.EV.EOF) != 0;
            const kind: reactor.EventKind = if (is_eof and kev.data == 0) .fd_hup else .fd_readable;
            return .{ .kind = kind, .token = token, .fd = fd, .data = @intCast(kev.data) };
        }
        if (kev.filter == c.EVFILT.WRITE) {
            const kind: reactor.EventKind = if ((kev.flags & c.EV.EOF) != 0) .fd_hup else .fd_writable;
            return .{ .kind = kind, .token = token, .fd = fd, .data = @intCast(kev.data) };
        }
        return null;
    }
};

fn openKqueueCloexec() reactor.Error!posix.fd_t {
    if (is_darwin) sys.fork_lock.lockShared();
    defer if (is_darwin) sys.fork_lock.unlockShared();
    const rc = c.kqueue();
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    }
    const kq: posix.fd_t = @intCast(rc);
    assert(kq >= 0);
    sys.setCloseOnExec(kq) catch {
        sys.close(kq);
        return error.Unexpected;
    };
    return kq;
}

fn syncFilters(
    kq: posix.fd_t,
    fd: posix.fd_t,
    old_token: u64,
    old: reactor.Interests,
    new_token: u64,
    new: reactor.Interests,
) reactor.Error!void {
    assert(kq >= 0);
    assert(fd >= 0);
    if (new.read) {
        try applyChange(kq, makeFdKevent(fd, c.EVFILT.READ, c.EV.ADD | c.EV.ENABLE, new_token));
    } else if (old.read) {
        deleteFilter(kq, fd, c.EVFILT.READ);
    }

    if (new.write) {
        applyChange(kq, makeFdKevent(fd, c.EVFILT.WRITE, c.EV.ADD | c.EV.ENABLE, new_token)) catch |err| {
            rollbackReadFilter(kq, fd, old_token, old.read, new.read);
            return err;
        };
    } else if (old.write) {
        deleteFilter(kq, fd, c.EVFILT.WRITE);
    }
}

fn rollbackReadFilter(kq: posix.fd_t, fd: posix.fd_t, old_token: u64, had_read: bool, added_read: bool) void {
    if (had_read) {
        applyChange(kq, makeFdKevent(fd, c.EVFILT.READ, c.EV.ADD | c.EV.ENABLE, old_token)) catch return;
    } else if (added_read) {
        deleteFilter(kq, fd, c.EVFILT.READ);
    }
}

fn makeFdKevent(fd: posix.fd_t, filter: i16, flags: u16, token: u64) c.Kevent {
    return .{
        .ident = @intCast(fd),
        .filter = filter,
        .flags = flags,
        .fflags = 0,
        .data = 0,
        .udata = @truncate(token),
    };
}

fn deleteFilter(kq: posix.fd_t, ident: anytype, filter: i16) void {
    const change: c.Kevent = .{
        .ident = @intCast(ident),
        .filter = filter,
        .flags = c.EV.DELETE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    };
    const empty_events: [0]c.Kevent = .{};
    while (true) {
        const rc = c.kevent(kq, @ptrCast(&change), 1, &empty_events, 0, null);
        if (posix.errno(rc) != .INTR) return;
    }
}

fn applyChange(kq: posix.fd_t, change: c.Kevent) reactor.Error!void {
    assert(kq >= 0);
    const empty_events: [0]c.Kevent = .{};
    while (true) {
        const rc = c.kevent(kq, @ptrCast(&change), 1, &empty_events, 0, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return mapKeventErrno(err),
        }
    }
}

/// Returns `null` when a positive deadline has already expired, or `?*const timespec`
/// to pass into `kevent(2)` (where `.?` may itself be `null` for infinite wait).
fn computeTimespec(ts: *c.timespec, timeout_ms: ?i32, deadline_ms: ?i64) ??*const c.timespec {
    const ms = timeout_ms orelse return @as(?*const c.timespec, null);
    if (ms < 0) return @as(?*const c.timespec, null);
    if (ms == 0) {
        ts.* = .{ .sec = 0, .nsec = 0 };
        return @as(?*const c.timespec, ts);
    }
    const rem = deadline_ms.? - sys.monotonicMs();
    if (rem <= 0) return null;
    ts.* = .{
        .sec = @intCast(@divTrunc(rem, 1000)),
        .nsec = @intCast(@rem(rem, 1000) * std.time.ns_per_ms),
    };
    return @as(?*const c.timespec, ts);
}

fn mapKeventErrno(err: posix.E) reactor.Error {
    return switch (err) {
        .BADF => error.InvalidFd,
        .SRCH, .NOENT => error.NotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => error.Unexpected,
    };
}

test "kqueue backend descriptor is close-on-exec" {
    var b = try Backend.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expect(try sys.isCloseOnExec(b.kq));
}

test "kqueue backend rejects closed descriptor with InvalidFd" {
    var b = try Backend.init(std.testing.allocator);
    defer b.deinit();
    const fds = try sys.pipeCloexec();
    sys.close(fds[0]);
    sys.close(fds[1]);
    try std.testing.expectError(error.InvalidFd, b.watchFd(fds[0], 1, .{ .read = true }));
}

test "kqueue backend computes zero and positive timespecs accurately" {
    var ts: c.timespec = undefined;
    const inf = computeTimespec(&ts, null, null).?;
    try std.testing.expect(inf == null);

    const neg = computeTimespec(&ts, -1, null).?;
    try std.testing.expect(neg == null);

    const zero = computeTimespec(&ts, 0, null).?.?;
    try std.testing.expectEqual(@as(@TypeOf(ts.sec), 0), zero.sec);
    try std.testing.expectEqual(@as(@TypeOf(ts.nsec), 0), zero.nsec);

    const expired = computeTimespec(&ts, 10, sys.monotonicMs() - 1);
    try std.testing.expect(expired == null);
}
