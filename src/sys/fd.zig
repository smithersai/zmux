//! Raw descriptor I/O: close, write, send, dup2, pipes, descriptor flags, the
//! Darwin fork lock, and the async-signal-safe clock and sleep helpers.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../sys.zig");

const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const fd_t = sys.fd_t;
const UnexpectedError = sys.UnexpectedError;

const is_darwin = builtin.os.tag.isDarwin();

/// Async-signal-safe: unlike `std.posix.unexpectedErrno` this never prints or
/// captures a stack trace, so wrappers stay usable between `fork` and `exec`.
pub fn unexpected(err: posix.E) UnexpectedError {
    _ = err;
    return error.Unexpected;
}

/// Async-signal-safe sleep that needs no `std.Io`.
pub fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    var none: [1]c.pollfd = undefined;
    _ = c.poll(&none, 0, @intCast(@min(ms, std.math.maxInt(c_int))));
}

/// Milliseconds on the monotonic (awake) clock.
pub fn monotonicMs() i64 {
    return std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
}

/// Guards the Darwin-only windows where a descriptor exists without
/// `FD_CLOEXEC` (`socket`, `accept`, `pipe`, `openpty` have no atomic
/// close-on-exec form there). Descriptor creators hold it shared; `fork`
/// holds it exclusive, so a forked child never observes a half-initialised
/// descriptor. The exclusive side waits a bounded time: `closeFrom` in the
/// child is the backstop, so `fork` must never deadlock behind a reader.
pub const ForkLock = struct {
    /// > 0: number of shared holders; -1: exclusive holder.
    state: std.atomic.Value(i32) = .init(0),

    pub fn lockShared(self: *ForkLock) void {
        while (true) {
            const current = self.state.load(.seq_cst);
            if (current >= 0 and self.state.cmpxchgWeak(current, current + 1, .seq_cst, .seq_cst) == null) return;
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockShared(self: *ForkLock) void {
        const previous = self.state.fetchSub(1, .seq_cst);
        assert(previous > 0);
    }

    /// Returns false when shared holders did not drain within `budget_ms`.
    pub fn lockExclusiveBounded(self: *ForkLock, budget_ms: i64) bool {
        assert(budget_ms >= 0);
        const deadline = monotonicMs() + budget_ms;
        while (true) {
            if (self.state.cmpxchgStrong(0, -1, .seq_cst, .seq_cst) == null) return true;
            if (monotonicMs() >= deadline) return false;
            sleepMs(1);
        }
    }

    pub fn unlockExclusive(self: *ForkLock) void {
        assert(self.state.load(.seq_cst) == -1);
        self.state.store(0, .seq_cst);
    }
};

/// Take the global fork lock shared on Darwin; a no-op elsewhere.
pub inline fn forkLockShared() void {
    if (is_darwin) sys.fork_lock.lockShared();
}

/// Release a shared hold taken by `forkLockShared`.
pub inline fn forkUnlockShared() void {
    if (is_darwin) sys.fork_lock.unlockShared();
}

/// Close `fd`, ignoring errors. Matches the Zig 0.15 `std.posix.close` contract:
/// EINTR still releases the descriptor, so retrying would be a bug.
pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

/// Errors from `write` and `send`.
pub const WriteError = error{
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
} || UnexpectedError;

/// Largest count passed to one `write(2)` or `send(2)` call.
const max_io_count: usize = if (is_darwin) std.math.maxInt(i32) else 0x7ffff000;

fn writeErr(err: posix.E) WriteError {
    return switch (err) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionResetByPeer,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .ACCES, .PERM => error.AccessDenied,
        else => unexpected(err),
    };
}

/// `write(2)`, retrying `EINTR`. Returns the bytes written, which may be
/// fewer than `bytes.len`. Writes nothing and returns 0 for an empty slice.
pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    const count = @min(bytes.len, max_io_count);
    assert(count > 0);
    while (true) {
        const rc = c.write(fd, bytes.ptr, count);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                assert(written <= count);
                return written;
            },
            .INTR => continue,
            else => |err| return writeErr(err),
        }
    }
}

/// Write every byte, retrying short writes. A zero-length write is reported as
/// `error.WriteZero` instead of spinning.
pub fn writeAll(fd: fd_t, bytes: []const u8) (WriteError || error{WriteZero})!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try write(fd, bytes[offset..]);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
    assert(offset == bytes.len);
}

/// Send bytes on a connected socket with `MSG_NOSIGNAL` so a closed peer
/// reports `error.BrokenPipe` instead of raising `SIGPIPE` in an embedding
/// process that leaves `SIGPIPE` at its default disposition.
pub fn send(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    const count = @min(bytes.len, max_io_count);
    assert(count > 0);
    while (true) {
        const rc = c.send(fd, bytes.ptr, count, c.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const sent: usize = @intCast(rc);
                assert(sent <= count);
                return sent;
            },
            .INTR => continue,
            else => |err| return writeErr(err),
        }
    }
}

/// Send every byte on a socket with `MSG_NOSIGNAL`, retrying short writes.
pub fn sendAll(fd: fd_t, bytes: []const u8) (WriteError || error{WriteZero})!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try send(fd, bytes[offset..]);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
    assert(offset == bytes.len);
}

/// `dup2(2)`: make `new_fd` refer to the same open file as `old_fd`.
/// Async-signal-safe; suitable for use between `fork` and `exec`.
/// When `old_fd == new_fd`, clears `FD_CLOEXEC` instead so the descriptor
/// survives `exec`.
pub fn dup2(old_fd: fd_t, new_fd: fd_t) UnexpectedError!void {
    if (old_fd == new_fd) return clearCloseOnExec(new_fd);
    while (true) {
        switch (posix.errno(c.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .INTR, .BUSY => continue,
            else => |err| return unexpected(err),
        }
    }
}

/// Errors from `pipe` and `pipeCloexec`.
pub const PipeError = error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded } || UnexpectedError;

fn pipeResult(err: posix.E, fds: [2]fd_t) PipeError![2]fd_t {
    switch (err) {
        .SUCCESS => {
            assert(fds[0] >= 0 and fds[1] >= 0);
            assert(fds[0] != fds[1]);
            return fds;
        },
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => return unexpected(err),
    }
}

/// Create a pipe. Both ends are blocking and inherited across exec, like the
/// Zig 0.15 `std.posix.pipe()`.
pub fn pipe() PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    const err = posix.errno(c.pipe(&fds));
    return pipeResult(err, fds);
}

/// Create a pipe whose ends are both close-on-exec, with no window in which a
/// concurrent `fork` could inherit them.
pub fn pipeCloexec() PipeError![2]fd_t {
    if (builtin.os.tag == .linux) {
        var fds: [2]fd_t = undefined;
        const err = posix.errno(c.pipe2(&fds, .{ .CLOEXEC = true }));
        return pipeResult(err, fds);
    }
    forkLockShared();
    defer forkUnlockShared();
    const fds = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    try setCloseOnExec(fds[0]);
    try setCloseOnExec(fds[1]);
    return fds;
}

/// Set `FD_CLOEXEC` on `fd`.
pub fn setCloseOnExec(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

/// Async-signal-safe.
pub fn clearCloseOnExec(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC)) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

/// The `O_NONBLOCK` bit as a `fcntl(F_GETFL)` flag word.
const nonblock_flag: c_int = @bitCast(c.O{ .NONBLOCK = true });

comptime {
    assert(nonblock_flag != 0);
}

/// Set `O_NONBLOCK` on `fd`.
pub fn setNonBlocking(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock_flag) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

/// Clear `O_NONBLOCK` on `fd`.
pub fn clearNonBlocking(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFL, flags & ~nonblock_flag) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

/// True when `fd` has `O_NONBLOCK`; false also when `fcntl` fails.
pub fn isNonBlocking(fd: fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFL);
    return flags >= 0 and (flags & nonblock_flag) != 0;
}

/// True when `fd` has `FD_CLOEXEC`.
pub fn isCloseOnExec(fd: fd_t) UnexpectedError!bool {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    return (flags & c.FD_CLOEXEC) != 0;
}

/// True when `fd` refers to a terminal.
pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) == 1;
}

test "pipeCloexec marks both ends close-on-exec" {
    const fds = try pipeCloexec();
    defer close(fds[0]);
    defer close(fds[1]);
    try std.testing.expect(try isCloseOnExec(fds[0]));
    try std.testing.expect(try isCloseOnExec(fds[1]));
}

test "pipe round-trips bytes and reports end of stream" {
    const fds = try pipe();
    defer close(fds[0]);
    try writeAll(fds[1], "ping");
    close(fds[1]);

    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try sys.read(fds[0], &buffer));
    try std.testing.expectEqualStrings("ping", buffer[0..4]);
    try std.testing.expectEqual(@as(usize, 0), try sys.read(fds[0], &buffer));
}

test "dup2 onto the same descriptor clears close-on-exec" {
    const fds = try pipeCloexec();
    defer close(fds[0]);
    defer close(fds[1]);
    try std.testing.expect(try isCloseOnExec(fds[0]));
    try dup2(fds[0], fds[0]);
    try std.testing.expect(!(try isCloseOnExec(fds[0])));

    // A distinct target is a plain dup2 and never inherits FD_CLOEXEC.
    try dup2(fds[1], fds[0]);
    try std.testing.expect(!(try isCloseOnExec(fds[0])));
    try std.testing.expectError(error.Unexpected, dup2(-1, fds[0]));
}

test "clearCloseOnExec and setCloseOnExec round-trip" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try setCloseOnExec(fds[0]);
    try std.testing.expect(try isCloseOnExec(fds[0]));
    try clearCloseOnExec(fds[0]);
    try std.testing.expect(!(try isCloseOnExec(fds[0])));
}

test "monotonicMs never goes backwards and sleepMs waits" {
    const before = monotonicMs();
    sleepMs(20);
    const after = monotonicMs();
    try std.testing.expect(after - before >= 19);
}

test "fork lock excludes exclusive holders while shared holders exist" {
    var lock: ForkLock = .{};
    lock.lockShared();
    lock.lockShared();
    try std.testing.expect(!lock.lockExclusiveBounded(20));
    lock.unlockShared();
    lock.unlockShared();
    try std.testing.expect(lock.lockExclusiveBounded(20));
    try std.testing.expect(!lock.lockExclusiveBounded(5));
    lock.unlockExclusive();
    lock.lockShared();
    lock.unlockShared();
}
