const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const sys = @import("../sys.zig");
const posix = std.posix;

const limits_mod = @import("limits.zig");
const socket_send_timeout_seconds = limits_mod.socket_send_timeout_seconds;

/// Write every byte of `bytes` within `timeout_ms` overall. Uses non-blocking
/// sends plus `poll(POLLOUT)` against one monotonic deadline, so a peer that
/// stops reading costs at most the budget on every platform.
///
/// `fd` must have `O_NONBLOCK` set. `MSG_DONTWAIT` alone is not enough: XNU
/// ignores it for sends (`sosendcheck` only honors the socket's own
/// non-blocking state), so a full buffer would block in the kernel.
pub fn writeAllDeadline(fd: posix.fd_t, bytes: []const u8, timeout_ms: i64) !void {
    if (std.debug.runtime_safety) std.debug.assert(sys.isNonBlocking(fd));
    assert(timeout_ms > 0);
    const deadline = sys.monotonicMs() + timeout_ms;
    ensureNonBlocking(fd) catch return error.Unexpected;
    const flags: u32 = std.c.MSG.NOSIGNAL | std.c.MSG.DONTWAIT;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.send(fd, bytes[offset..].ptr, bytes.len - offset, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return error.WriteZero;
                assert(written <= bytes.len - offset);
                offset += written;
            },
            .INTR => {},
            .AGAIN => {
                const remaining = deadline - sys.monotonicMs();
                if (remaining <= 0) return error.WriteTimeout;
                var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&fds, @intCast(@min(remaining, 1000))) catch return error.Unexpected;
            },
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
    assert(offset == bytes.len);
}

/// Set `O_NONBLOCK` unless it is already set (one `fcntl` in the common case).
fn ensureNonBlocking(fd: posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return error.Unexpected;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if ((flags & nonblock) != 0) return;
    if (std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.Unexpected;
}

/// Bound a blocking send in the kernel on every platform (`SO_SNDTIMEO`), as
/// a backstop for `writeAllDeadline`. Returns whether the option was set.
pub fn setSocketSendTimeout(fd: posix.fd_t) bool {
    var timeout: std.c.timeval = .{
        .sec = @intCast(socket_send_timeout_seconds),
        .usec = 0,
    };
    if (std.c.setsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.SNDTIMEO,
        &timeout,
        @intCast(@sizeOf(std.c.timeval)),
    ) != 0) {
        log.warnRateLimited("socket_send_timeout_failed", &sockopt_limiter, .{
            .errno = @backingInt(posix.errno(@as(c_int, -1))),
        });
        return false;
    }
    return true;
}

/// Seconds on the monotonic `.awake` clock, immune to wall-clock changes.
pub fn monotonicSeconds(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toSeconds();
}

/// Effective uid of the peer connected on `fd`, or null when the kernel cannot say.
pub fn defaultPeerEuid(fd: posix.fd_t) ?sys.uid_t {
    return sys.peerEuid(fd) catch null;
}

var sockopt_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

test "SO_SNDTIMEO is set on client sockets on every platform" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = try sys.socketPair();
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);

    try std.testing.expect(setSocketSendTimeout(sockets[0]));

    var timeout: std.c.timeval = undefined;
    var len: std.c.socklen_t = @sizeOf(std.c.timeval);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockopt(sockets[0], std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &timeout, &len));
    try std.testing.expectEqual(@as(i64, socket_send_timeout_seconds), @as(i64, @intCast(timeout.sec)));
    try std.testing.expectEqual(@as(i64, 0), @as(i64, @intCast(timeout.usec)));

    // The untouched end still has no timeout, so the assertion above is not
    // reading a platform default.
    var other: std.c.timeval = undefined;
    var other_len: std.c.socklen_t = @sizeOf(std.c.timeval);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockopt(sockets[1], std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &other, &other_len));
    try std.testing.expectEqual(@as(i64, 0), @as(i64, @intCast(other.sec)));
}

test "a write to a peer that never reads fails at the overall deadline" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = try sys.socketPair();
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);
    try sys.setNonBlocking(sockets[0]);

    const payload = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const start = sys.monotonicMs();
    try std.testing.expectError(error.WriteTimeout, writeAllDeadline(sockets[0], payload, 300));
    const elapsed = sys.monotonicMs() - start;
    try std.testing.expect(elapsed >= 250);
    try std.testing.expect(elapsed < 3000);

    // A reader lets the same call finish.
    const Drain = struct {
        pub fn run(fd: posix.fd_t, total: usize) void {
            var buf: [64 * 1024]u8 = undefined;
            var seen: usize = 0;
            while (seen < total) {
                const n = posix.read(fd, &buf) catch return;
                if (n == 0) return;
                seen += n;
            }
        }
    };
    const fresh = try sys.socketPair();
    defer sys.close(fresh[0]);
    defer sys.close(fresh[1]);
    try sys.setNonBlocking(fresh[0]);
    const drain = try std.Thread.spawn(.{}, Drain.run, .{ fresh[1], payload.len });
    defer drain.join();
    try writeAllDeadline(fresh[0], payload, 5000);
}
