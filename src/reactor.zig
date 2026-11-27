//! Cross-platform OS event reactor (`kqueue` on Darwin/BSD, `epoll` on Linux).
//!
//! Multiplexes file descriptors, child process exits, and cross-thread wakeups
//! in O(ready) time without per-pane polling loops.

const std = @import("std");
const builtin = @import("builtin");

const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;

const Backend = switch (builtin.os.tag) {
    .linux => @import("reactor/epoll.zig").Backend,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .freebsd,
    .openbsd,
    .netbsd,
    .dragonfly,
    => @import("reactor/kqueue.zig").Backend,
    else => @compileError("reactor: unsupported operating system"),
};

/// Errors returned by `Reactor` lifecycle, registration, and wait operations.
pub const Error = error{
    OutOfMemory,
    InvalidFd,
    InvalidPid,
    AlreadyWatched,
    NotFound,
    AccessDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    OperationNotSupported,
    Unexpected,
};

/// Bitmask of I/O readiness events to monitor on a file descriptor.
pub const Interests = packed struct {
    /// Monitor readability (`EVFILT_READ` / `EPOLLIN`).
    read: bool = true,
    /// Monitor writability (`EVFILT_WRITE` / `EPOLLOUT`).
    write: bool = false,
};

/// Normalized OS event kind delivered by `Reactor.wait`.
pub const EventKind = enum {
    /// Descriptor has bytes ready to read or an incoming connection.
    fd_readable,
    /// Descriptor can accept bytes without blocking.
    fd_writable,
    /// Peer closed or hung up the descriptor.
    fd_hup,
    /// Kernel reported an error condition on the descriptor.
    fd_err,
    /// Watched process exited.
    pid_exited,
    /// Cross-thread `Reactor.wake` signal arrived.
    wakeup,
};

/// Single normalized event returned by `Reactor.wait`.
pub const Event = struct {
    /// Category of OS event.
    kind: EventKind,
    /// Caller-supplied opaque correlation token (0 for `.wakeup`).
    token: u64,
    /// Associated descriptor, or `-1` for non-fd events.
    fd: posix.fd_t = -1,
    /// Associated process id, or `0` for non-process events.
    pid: posix.pid_t = 0,
    /// Backend-supplied auxiliary data (bytes available, errno, or exit data).
    data: i64 = 0,
};

/// Outcome of `Reactor.watchPid`.
pub const WatchPidResult = enum {
    /// Process exit watch is armed; `wait` will emit `.pid_exited`.
    watching,
    /// Process had already exited (`ESRCH`) before the watch was armed.
    already_exited,
};

/// Cross-platform OS event reactor backed by `kqueue(2)` or `epoll(7)`.
pub const Reactor = struct {
    backend: Backend,

    /// Create a new reactor with close-on-exec internal descriptors.
    pub fn init(allocator: Allocator) Error!Reactor {
        const backend = try Backend.init(allocator);
        assert(backend.isOpen());
        return .{ .backend = backend };
    }

    /// Release all kernel descriptors and internal tables.
    pub fn deinit(self: *Reactor) void {
        assert(self.backend.isOpen());
        self.backend.deinit();
        self.* = undefined;
    }

    /// Register `fd` with correlation `token` and readiness `interests`.
    pub fn watchFd(self: *Reactor, fd: posix.fd_t, token: u64, interests: Interests) Error!void {
        assert(self.backend.isOpen());
        if (fd < 0) return error.InvalidFd;
        try self.backend.watchFd(fd, token, interests);
        assert(self.backend.hasFd(fd));
    }

    /// Update the `token` and `interests` of an already-watched `fd`.
    pub fn modifyFd(self: *Reactor, fd: posix.fd_t, token: u64, interests: Interests) Error!void {
        assert(self.backend.isOpen());
        if (fd < 0) return error.InvalidFd;
        try self.backend.modifyFd(fd, token, interests);
        assert(self.backend.hasFd(fd));
    }

    /// Stop watching `fd`. Safe to call if `fd` is not watched or already closed.
    pub fn unwatchFd(self: *Reactor, fd: posix.fd_t) void {
        assert(self.backend.isOpen());
        if (fd < 0) return;
        self.backend.unwatchFd(fd);
        assert(!self.backend.hasFd(fd));
    }

    /// Watch `pid` for exit. Returns `.already_exited` on `ESRCH` so a
    /// fast-exiting child is never lost.
    pub fn watchPid(self: *Reactor, pid: posix.pid_t, token: u64) Error!WatchPidResult {
        assert(self.backend.isOpen());
        if (pid <= 0) return error.InvalidPid;
        return self.backend.watchPid(pid, token);
    }

    /// Stop watching `pid`. Safe to call if `pid` is not watched or exited.
    pub fn unwatchPid(self: *Reactor, pid: posix.pid_t) void {
        assert(self.backend.isOpen());
        if (pid <= 0) return;
        self.backend.unwatchPid(pid);
        assert(!self.backend.hasPid(pid));
    }

    /// Thread-safely wake a thread blocked in `wait` (or latch a wakeup).
    pub fn wake(self: *Reactor) Error!void {
        assert(self.backend.isOpen());
        try self.backend.wake();
    }

    /// Wait for up to `out.len` events, retrying `EINTR`.
    /// `timeout_ms`: `null` or `< 0` waits indefinitely, `0` polls once,
    /// `> 0` bounds total wait duration across signal interruptions.
    pub fn wait(self: *Reactor, out: []Event, timeout_ms: ?i32) Error![]Event {
        assert(self.backend.isOpen());
        if (out.len == 0) return out[0..0];
        const ready = try self.backend.wait(out, timeout_ms);
        assert(ready.len <= out.len);
        return ready;
    }

    /// Number of currently watched file descriptors.
    pub fn watchedFdCount(self: *const Reactor) usize {
        assert(self.backend.isOpen());
        return self.backend.fdCount();
    }

    /// Number of currently watched process ids.
    pub fn watchedPidCount(self: *const Reactor) usize {
        assert(self.backend.isOpen());
        return self.backend.pidCount();
    }
};

test {
    _ = Backend;
}

test "reactor init and deinit release resources cleanly" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 0), r.watchedFdCount());
    try std.testing.expectEqual(@as(usize, 0), r.watchedPidCount());
}

test "reactor wait with zero timeout returns empty when idle" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    var events: [8]Event = undefined;
    const ready = try r.wait(&events, 0);
    try std.testing.expectEqual(@as(usize, 0), ready.len);
}

test "reactor wait with empty output slice returns empty immediately" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    var events: [0]Event = .{};
    const ready = try r.wait(&events, 5000);
    try std.testing.expectEqual(@as(usize, 0), ready.len);
}

test "reactor wait with positive timeout returns empty after timeout" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    var events: [4]Event = undefined;
    const start = sys.monotonicMs();
    const ready = try r.wait(&events, 15);
    const elapsed = sys.monotonicMs() - start;
    try std.testing.expectEqual(@as(usize, 0), ready.len);
    try std.testing.expect(elapsed >= 5);
}

test "reactor detects pipe readability with exact token and fd" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    const tok: u64 = 0xdead_beef_cafe_1234;
    try r.watchFd(fds[0], tok, .{ .read = true });
    try std.testing.expectEqual(@as(usize, 1), r.watchedFdCount());

    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try r.wait(&events, 0)).len);

    _ = try sys.write(fds[1], "ping");
    const ready = try r.wait(&events, 200);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(EventKind.fd_readable, ready[0].kind);
    try std.testing.expectEqual(tok, ready[0].token);
    try std.testing.expectEqual(fds[0], ready[0].fd);
}

test "reactor detects pipe writability when write interest is set" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    try r.watchFd(fds[1], 42, .{ .read = false, .write = true });
    var events: [4]Event = undefined;
    const ready = try r.wait(&events, 200);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(EventKind.fd_writable, ready[0].kind);
    try std.testing.expectEqual(@as(u64, 42), ready[0].token);
    try std.testing.expectEqual(fds[1], ready[0].fd);
}

test "reactor reports fd_hup when pipe write end closes" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);

    try r.watchFd(fds[0], 77, .{ .read = true });
    sys.close(fds[1]);

    var events: [4]Event = undefined;
    const ready = try r.wait(&events, 200);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(EventKind.fd_hup, ready[0].kind);
    try std.testing.expectEqual(@as(u64, 77), ready[0].token);
    try std.testing.expectEqual(fds[0], ready[0].fd);
}

test "reactor delivers unread data before fd_hup when peer writes and closes" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);

    try r.watchFd(fds[0], 88, .{ .read = true });
    _ = try sys.write(fds[1], "final");
    sys.close(fds[1]);

    var events: [4]Event = undefined;
    const first = try r.wait(&events, 200);
    try std.testing.expect(first.len >= 1);
    try std.testing.expectEqual(EventKind.fd_readable, first[0].kind);

    var buf: [16]u8 = undefined;
    const n = try sys.read(fds[0], &buf);
    try std.testing.expectEqualStrings("final", buf[0..n]);

    const second = try r.wait(&events, 200);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(EventKind.fd_hup, second[0].kind);
}

test "reactor modifyFd updates interests and correlation token" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    try r.watchFd(fds[1], 10, .{ .read = false, .write = false });
    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try r.wait(&events, 0)).len);

    try r.modifyFd(fds[1], 20, .{ .read = false, .write = true });
    const ready = try r.wait(&events, 200);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(EventKind.fd_writable, ready[0].kind);
    try std.testing.expectEqual(@as(u64, 20), ready[0].token);

    try r.modifyFd(fds[1], 30, .{ .read = false, .write = false });
    try std.testing.expectEqual(@as(usize, 0), (try r.wait(&events, 0)).len);
}

test "reactor unwatchFd stops event delivery and is idempotent" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    try r.watchFd(fds[0], 1, .{ .read = true });
    _ = try sys.write(fds[1], "x");
    r.unwatchFd(fds[0]);
    r.unwatchFd(fds[0]);
    r.unwatchFd(-1);
    try std.testing.expectEqual(@as(usize, 0), r.watchedFdCount());

    var events: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try r.wait(&events, 0)).len);
}

test "reactor rejects invalid and duplicate fd operations" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();
    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    try std.testing.expectError(error.InvalidFd, r.watchFd(-1, 1, .{}));
    try std.testing.expectError(error.InvalidFd, r.modifyFd(-1, 1, .{}));
    try std.testing.expectError(error.NotFound, r.modifyFd(fds[0], 1, .{}));

    try r.watchFd(fds[0], 1, .{});
    try std.testing.expectError(error.AlreadyWatched, r.watchFd(fds[0], 2, .{}));
}

test "reactor wake latches before wait and clears after delivery" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    try r.wake();
    try r.wake();

    var events: [4]Event = undefined;
    const first = try r.wait(&events, 200);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqual(EventKind.wakeup, first[0].kind);
    try std.testing.expectEqual(@as(u64, 0), first[0].token);

    const second = try r.wait(&events, 0);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "reactor cross-thread wake interrupts blocking wait promptly" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const Waker = struct {
        fn run(reactor_ptr: *Reactor) void {
            sys.sleepMs(15);
            reactor_ptr.wake() catch return;
        }
    };
    const thread = try std.Thread.spawn(.{}, Waker.run, .{&r});
    defer thread.join();

    var events: [4]Event = undefined;
    const start = sys.monotonicMs();
    const ready = try r.wait(&events, 2000);
    const elapsed = sys.monotonicMs() - start;

    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(EventKind.wakeup, ready[0].kind);
    try std.testing.expect(elapsed < 1000);
}

test "reactor dispatches 64 concurrent readable pipes in one batch" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const count = 64;
    var pipes: [count][2]posix.fd_t = undefined;
    var opened: usize = 0;
    defer for (0..opened) |i| {
        sys.close(pipes[i][0]);
        sys.close(pipes[i][1]);
    };

    for (0..count) |i| {
        pipes[i] = try sys.pipeCloexec();
        opened += 1;
        try r.watchFd(pipes[i][0], 1000 + i, .{ .read = true });
        _ = try sys.write(pipes[i][1], "b");
    }
    try std.testing.expectEqual(@as(usize, count), r.watchedFdCount());

    var seen: [count]bool = @splat(false);
    var total: usize = 0;
    var events: [count]Event = undefined;
    while (total < count) {
        const ready = try r.wait(&events, 500);
        try std.testing.expect(ready.len > 0);
        for (ready) |ev| {
            try std.testing.expectEqual(EventKind.fd_readable, ev.kind);
            const idx: usize = @intCast(ev.token - 1000);
            var b: [1]u8 = undefined;
            _ = try sys.read(pipes[idx][0], &b);
            if (!seen[idx]) {
                seen[idx] = true;
                total += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, count), total);
}

test "reactor watchPid reports exit of live child process" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const fds = try sys.pipeCloexec();
    const pid = try sys.fork();
    if (pid == 0) {
        sys.close(fds[1]);
        var b: [1]u8 = undefined;
        _ = std.c.read(fds[0], &b, 1);
        std.c._exit(0);
    }
    sys.close(fds[0]);
    defer {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
    }

    const res = try r.watchPid(pid, 9001);
    try std.testing.expectEqual(WatchPidResult.watching, res);
    try std.testing.expectEqual(@as(usize, 1), r.watchedPidCount());

    _ = try sys.write(fds[1], "g");
    sys.close(fds[1]);

    var events: [4]Event = undefined;
    const ready = try r.wait(&events, 2000);
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqual(EventKind.pid_exited, ready[0].kind);
    try std.testing.expectEqual(@as(u64, 9001), ready[0].token);
    try std.testing.expectEqual(pid, ready[0].pid);
    try std.testing.expectEqual(@as(usize, 0), r.watchedPidCount());
}

test "reactor watchPid returns already_exited for reaped child" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const pid = try sys.fork();
    if (pid == 0) std.c._exit(0);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const res = try r.watchPid(pid, 555);
    try std.testing.expectEqual(WatchPidResult.already_exited, res);
    try std.testing.expectEqual(@as(usize, 0), r.watchedPidCount());
}

test "reactor watchPid never loses a fast-exiting child" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const pid = try sys.fork();
    if (pid == 0) std.c._exit(0);
    defer {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
    }

    const res = try r.watchPid(pid, 777);
    if (res == .watching) {
        var events: [4]Event = undefined;
        const ready = try r.wait(&events, 2000);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqual(EventKind.pid_exited, ready[0].kind);
        try std.testing.expectEqual(pid, ready[0].pid);
    }
}

test "reactor rejects invalid pid and duplicate watchPid and allows unwatchPid" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    try std.testing.expectError(error.InvalidPid, r.watchPid(0, 1));
    try std.testing.expectError(error.InvalidPid, r.watchPid(-5, 1));
    r.unwatchPid(0);
    r.unwatchPid(-5);

    const fds = try sys.pipeCloexec();
    const pid = try sys.fork();
    if (pid == 0) {
        sys.close(fds[1]);
        var b: [1]u8 = undefined;
        _ = std.c.read(fds[0], &b, 1);
        std.c._exit(0);
    }
    sys.close(fds[0]);
    defer {
        sys.close(fds[1]);
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
    }

    try std.testing.expectEqual(WatchPidResult.watching, try r.watchPid(pid, 10));
    try std.testing.expectError(error.AlreadyWatched, r.watchPid(pid, 11));
    r.unwatchPid(pid);
    r.unwatchPid(pid);
    try std.testing.expectEqual(@as(usize, 0), r.watchedPidCount());
}

test "reactor handles socketpair bidirectional events" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const socks = try sys.socketPair();
    defer sys.close(socks[0]);
    defer sys.close(socks[1]);

    try r.watchFd(socks[0], 0, .{ .read = true, .write = true });
    _ = try sys.send(socks[1], "hello");

    var events: [4]Event = undefined;
    const ready = try r.wait(&events, 200);
    try std.testing.expect(ready.len >= 1);
    var saw_read = false;
    for (ready) |ev| {
        try std.testing.expectEqual(@as(u64, 0), ev.token);
        if (ev.kind == .fd_readable) saw_read = true;
    }
    try std.testing.expect(saw_read);
}

test "reactor unwatchFd works safely after fd is already closed" {
    var r = try Reactor.init(std.testing.allocator);
    defer r.deinit();

    const fds = try sys.pipeCloexec();
    defer sys.close(fds[1]);
    try r.watchFd(fds[0], 123, .{ .read = true });
    sys.close(fds[0]);
    r.unwatchFd(fds[0]);
    try std.testing.expectEqual(@as(usize, 0), r.watchedFdCount());
}

test "reactor propagates OutOfMemory cleanly on watchFd without leaking" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var r = try Reactor.init(failing.allocator());
    defer r.deinit();

    const fds = try sys.pipeCloexec();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    try std.testing.expectError(error.OutOfMemory, r.watchFd(fds[0], 1, .{ .read = true }));
    try std.testing.expectEqual(@as(usize, 0), r.watchedFdCount());
}
