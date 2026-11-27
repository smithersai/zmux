//! Linux `epoll(7)` backend for `src/reactor.zig`.
//!
//! Uses `epoll_create1(EPOLL_CLOEXEC)`, `eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)`
//! for lock-free cross-thread wakeups, and `pidfd_open(2)` for race-free child
//! exit notifications.

const std = @import("std");

const reactor = @import("../reactor.zig");
const sys = @import("../sys.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;

const max_batch: usize = 128;

const KeyTag = enum(u2) {
    wake = 0,
    fd = 1,
    pidfd = 2,
};

const wake_key: u64 = 0;

const FdEntry = struct {
    token: u64,
    interests: reactor.Interests,
};

const PidEntry = struct {
    pid: posix.pid_t,
    token: u64,
};

/// Linux `epoll(7)` reactor backend implementation.
pub const Backend = struct {
    allocator: Allocator,
    epfd: posix.fd_t,
    wake_fd: posix.fd_t,
    fds: std.AutoHashMapUnmanaged(posix.fd_t, FdEntry) = .empty,
    pidfds: std.AutoHashMapUnmanaged(posix.fd_t, PidEntry) = .empty,
    pid_to_pidfd: std.AutoHashMapUnmanaged(posix.pid_t, posix.fd_t) = .empty,

    /// Create an `EPOLL_CLOEXEC` epoll instance and register a non-blocking `eventfd`.
    pub fn init(allocator: Allocator) reactor.Error!Backend {
        const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        switch (linux.errno(ep_rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        const epfd: posix.fd_t = @intCast(ep_rc);
        assert(epfd >= 0);
        errdefer sys.close(epfd);

        const ev_rc = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        switch (linux.errno(ev_rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        const wake_fd: posix.fd_t = @intCast(ev_rc);
        assert(wake_fd >= 0);
        errdefer sys.close(wake_fd);

        var wake_ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = wake_key },
        };
        try epollCtl(epfd, linux.EPOLL.CTL_ADD, wake_fd, &wake_ev);
        return .{ .allocator = allocator, .epfd = epfd, .wake_fd = wake_fd };
    }

    /// Close all watched pidfds, the eventfd, the epoll fd, and free tracking maps.
    pub fn deinit(self: *Backend) void {
        assert(self.epfd >= 0);
        assert(self.wake_fd >= 0);
        var it = self.pidfds.keyIterator();
        while (it.next()) |pidfd_ptr| sys.close(pidfd_ptr.*);
        self.fds.deinit(self.allocator);
        self.pidfds.deinit(self.allocator);
        self.pid_to_pidfd.deinit(self.allocator);
        sys.close(self.wake_fd);
        sys.close(self.epfd);
        self.wake_fd = -1;
        self.epfd = -1;
    }

    /// True while the epoll and wakeup descriptors are open.
    pub fn isOpen(self: *const Backend) bool {
        return self.epfd >= 0 and self.wake_fd >= 0;
    }

    /// True if `fd` is tracked in this backend.
    pub fn hasFd(self: *const Backend, fd: posix.fd_t) bool {
        return self.fds.contains(fd);
    }

    /// True if `pid` is tracked in this backend.
    pub fn hasPid(self: *const Backend, pid: posix.pid_t) bool {
        return self.pid_to_pidfd.contains(pid);
    }

    /// Count of watched file descriptors.
    pub fn fdCount(self: *const Backend) usize {
        return self.fds.count();
    }

    /// Count of watched process ids.
    pub fn pidCount(self: *const Backend) usize {
        return self.pid_to_pidfd.count();
    }

    /// Register `fd` with `interests` and correlation `token`.
    pub fn watchFd(
        self: *Backend,
        fd: posix.fd_t,
        token: u64,
        interests: reactor.Interests,
    ) reactor.Error!void {
        assert(self.epfd >= 0);
        assert(fd >= 0);
        if (self.fds.contains(fd)) return error.AlreadyWatched;
        try self.fds.ensureUnusedCapacity(self.allocator, 1);

        var ev: linux.epoll_event = .{
            .events = interestsToMask(interests),
            .data = .{ .u64 = encodeKey(.fd, fd) },
        };
        try epollCtl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
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
        assert(self.epfd >= 0);
        assert(fd >= 0);
        const entry = self.fds.getPtr(fd) orelse return error.NotFound;
        var ev: linux.epoll_event = .{
            .events = interestsToMask(interests),
            .data = .{ .u64 = encodeKey(.fd, fd) },
        };
        try epollCtl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
        entry.* = .{ .token = token, .interests = interests };
        assert(entry.token == token);
    }

    /// Remove `fd` from the epoll set and tracking table.
    pub fn unwatchFd(self: *Backend, fd: posix.fd_t) void {
        assert(self.epfd >= 0);
        if (!self.fds.remove(fd)) return;
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
    }

    /// Open a `pidfd` for `pid` and register it on epoll; returns `.already_exited` on `ESRCH`.
    pub fn watchPid(self: *Backend, pid: posix.pid_t, token: u64) reactor.Error!reactor.WatchPidResult {
        assert(self.epfd >= 0);
        assert(pid > 0);
        if (self.pid_to_pidfd.contains(pid)) return error.AlreadyWatched;
        try self.pid_to_pidfd.ensureUnusedCapacity(self.allocator, 1);
        try self.pidfds.ensureUnusedCapacity(self.allocator, 1);

        const rc = linux.pidfd_open(pid, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .SRCH => return .already_exited,
            .INVAL => return error.InvalidPid,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            .NOSYS => return error.OperationNotSupported,
            else => return error.Unexpected,
        }
        const pidfd: posix.fd_t = @intCast(rc);
        assert(pidfd >= 0);
        errdefer sys.close(pidfd);

        var ev: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{ .u64 = encodeKey(.pidfd, pidfd) },
        };
        try epollCtl(self.epfd, linux.EPOLL.CTL_ADD, pidfd, &ev);
        self.pid_to_pidfd.putAssumeCapacity(pid, pidfd);
        self.pidfds.putAssumeCapacity(pidfd, .{ .pid = pid, .token = token });
        assert(self.pid_to_pidfd.contains(pid));
        return .watching;
    }

    /// Remove and close the `pidfd` tracking `pid`.
    pub fn unwatchPid(self: *Backend, pid: posix.pid_t) void {
        assert(self.epfd >= 0);
        const removed = self.pid_to_pidfd.fetchRemove(pid) orelse return;
        _ = self.pidfds.remove(removed.value);
        _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, removed.value, null);
        sys.close(removed.value);
    }

    /// Increment the `eventfd` counter to wake a thread blocked in `wait`.
    pub fn wake(self: *Backend) reactor.Error!void {
        assert(self.wake_fd >= 0);
        const one: u64 = 1;
        const bytes = std.mem.asBytes(&one);
        while (true) {
            const rc = linux.write(self.wake_fd, bytes.ptr, bytes.len);
            switch (linux.errno(rc)) {
                .SUCCESS, .AGAIN => return,
                .INTR => continue,
                .BADF => return error.InvalidFd,
                else => return error.Unexpected,
            }
        }
    }

    /// Block in `epoll_wait(2)` up to `timeout_ms`, retrying `EINTR`.
    pub fn wait(self: *Backend, out: []reactor.Event, timeout_ms: ?i32) reactor.Error![]reactor.Event {
        assert(self.epfd >= 0);
        assert(out.len > 0);
        const deadline_ms: ?i64 = if (timeout_ms) |ms|
            if (ms > 0) sys.monotonicMs() + @as(i64, ms) else null
        else
            null;

        var raw: [max_batch]linux.epoll_event = undefined;
        const max_events: u32 = @intCast(@min(out.len, raw.len));

        while (true) {
            const step_ms = computeWaitMs(timeout_ms, deadline_ms) orelse return out[0..0];
            const rc = linux.epoll_wait(self.epfd, &raw, max_events, step_ms);
            switch (linux.errno(rc)) {
                .SUCCESS => return self.decodeBatch(raw[0..rc], out),
                .INTR => continue,
                .BADF => return error.InvalidFd,
                else => return error.Unexpected,
            }
        }
    }

    fn decodeBatch(self: *Backend, raw: []const linux.epoll_event, out: []reactor.Event) []reactor.Event {
        var count: usize = 0;
        for (raw) |ev| {
            if (count >= out.len) break;
            count += self.decodeRawEvent(ev, out[count..]);
        }
        assert(count <= out.len);
        return out[0..count];
    }

    fn decodeRawEvent(self: *Backend, ev: linux.epoll_event, dst: []reactor.Event) usize {
        assert(dst.len > 0);
        const key = ev.data.u64;
        const tag = decodeTag(key);
        switch (tag) {
            .wake => {
                self.drainWakeFd();
                dst[0] = .{ .kind = .wakeup, .token = 0 };
                return 1;
            },
            .pidfd => {
                const pidfd = decodeFd(key);
                const removed = self.pidfds.fetchRemove(pidfd) orelse return 0;
                _ = self.pid_to_pidfd.remove(removed.value.pid);
                _ = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, pidfd, null);
                sys.close(pidfd);
                dst[0] = .{ .kind = .pid_exited, .token = removed.value.token, .pid = removed.value.pid };
                return 1;
            },
            .fd => return self.decodeFdEvent(decodeFd(key), ev.events, dst),
        }
    }

    fn decodeFdEvent(self: *Backend, fd: posix.fd_t, mask: u32, dst: []reactor.Event) usize {
        assert(dst.len > 0);
        const entry = self.fds.get(fd) orelse return 0;
        var written: usize = 0;
        if ((mask & linux.EPOLL.ERR) != 0) {
            dst[written] = .{ .kind = .fd_err, .token = entry.token, .fd = fd };
            return 1;
        }
        if ((mask & linux.EPOLL.IN) != 0) {
            dst[written] = .{ .kind = .fd_readable, .token = entry.token, .fd = fd };
            written += 1;
        } else if ((mask & (linux.EPOLL.HUP | linux.EPOLL.RDHUP)) != 0) {
            dst[written] = .{ .kind = .fd_hup, .token = entry.token, .fd = fd };
            written += 1;
        }
        if ((mask & linux.EPOLL.OUT) != 0 and written < dst.len) {
            dst[written] = .{ .kind = .fd_writable, .token = entry.token, .fd = fd };
            written += 1;
        }
        return written;
    }

    fn drainWakeFd(self: *Backend) void {
        var val: u64 = 0;
        const bytes = std.mem.asBytes(&val);
        while (true) {
            const rc = linux.read(self.wake_fd, bytes.ptr, bytes.len);
            if (linux.errno(rc) != .INTR) return;
        }
    }
};

fn encodeKey(tag: KeyTag, fd: posix.fd_t) u64 {
    assert(fd >= 0);
    const fd_bits: u64 = @as(u32, @bitCast(fd));
    return (@as(u64, @backingInt(tag)) << 62) | fd_bits;
}

fn decodeTag(key: u64) KeyTag {
    const bits: u2 = @intCast(key >> 62);
    return switch (bits) {
        0 => .wake,
        1 => .fd,
        else => .pidfd,
    };
}

fn decodeFd(key: u64) posix.fd_t {
    const raw: u32 = @truncate(key);
    return @bitCast(raw);
}

fn interestsToMask(interests: reactor.Interests) u32 {
    var mask: u32 = 0;
    if (interests.read) mask |= linux.EPOLL.IN | linux.EPOLL.RDHUP;
    if (interests.write) mask |= linux.EPOLL.OUT;
    return mask;
}

fn computeWaitMs(timeout_ms: ?i32, deadline_ms: ?i64) ?i32 {
    const ms = timeout_ms orelse return -1;
    if (ms < 0) return -1;
    if (ms == 0) return 0;
    const rem = deadline_ms.? - sys.monotonicMs();
    if (rem <= 0) return null;
    return @intCast(@min(rem, std.math.maxInt(i32)));
}

fn epollCtl(epfd: posix.fd_t, op: u32, fd: posix.fd_t, ev: ?*linux.epoll_event) reactor.Error!void {
    assert(epfd >= 0);
    assert(fd >= 0);
    const rc = linux.epoll_ctl(epfd, op, fd, ev);
    switch (linux.errno(rc)) {
        .SUCCESS => return,
        .BADF => return error.InvalidFd,
        .EXIST => return error.AlreadyWatched,
        .NOENT => return error.NotFound,
        .NOMEM, .NOSPC => return error.SystemResources,
        .PERM => return error.OperationNotSupported,
        else => return error.Unexpected,
    }
}

test "epoll key encoding roundtrips fd and pidfd tags without colliding with wake" {
    const fd_key = encodeKey(.fd, 17);
    try std.testing.expect(fd_key != wake_key);
    try std.testing.expectEqual(KeyTag.fd, decodeTag(fd_key));
    try std.testing.expectEqual(@as(posix.fd_t, 17), decodeFd(fd_key));

    const pid_key = encodeKey(.pidfd, 42);
    try std.testing.expect(pid_key != wake_key);
    try std.testing.expect(pid_key != fd_key);
    try std.testing.expectEqual(KeyTag.pidfd, decodeTag(pid_key));
    try std.testing.expectEqual(@as(posix.fd_t, 42), decodeFd(pid_key));
    try std.testing.expectEqual(KeyTag.wake, decodeTag(wake_key));
}

test "epoll interestsToMask maps read and write flags accurately" {
    try std.testing.expectEqual(@as(u32, 0), interestsToMask(.{ .read = false, .write = false }));
    try std.testing.expectEqual(
        @as(u32, linux.EPOLL.IN | linux.EPOLL.RDHUP),
        interestsToMask(.{ .read = true, .write = false }),
    );
    try std.testing.expectEqual(@as(u32, linux.EPOLL.OUT), interestsToMask(.{ .read = false, .write = true }));
    try std.testing.expectEqual(
        @as(u32, linux.EPOLL.IN | linux.EPOLL.RDHUP | linux.EPOLL.OUT),
        interestsToMask(.{ .read = true, .write = true }),
    );
}

test "epoll computeWaitMs handles infinite, zero, and expired deadlines" {
    try std.testing.expectEqual(@as(?i32, -1), computeWaitMs(null, null));
    try std.testing.expectEqual(@as(?i32, -1), computeWaitMs(-5, null));
    try std.testing.expectEqual(@as(?i32, 0), computeWaitMs(0, null));
    try std.testing.expectEqual(@as(?i32, null), computeWaitMs(10, sys.monotonicMs() - 1));
}
