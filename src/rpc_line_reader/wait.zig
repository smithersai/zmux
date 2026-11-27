//! Deadline arithmetic and the single `poll(2)` wait that the blocking
//! `LineReader` reads use between buffer drains.

const std = @import("std");

const assert = std.debug.assert;
const posix = std.posix;

const sys = @import("../sys.zig");
const LineReader = @import("../rpc_line_reader.zig").LineReader;

/// An absolute point on `io`'s clock after which reads fail with
/// `error.ReadTimeout`.
pub const Deadline = struct {
    io: std.Io,
    at: std.Io.Clock.Timestamp,

    /// Absolute deadline for `timeout` on `io`, or null for no limit.
    pub fn init(io: std.Io, timeout: std.Io.Timeout) ?Deadline {
        const at = timeout.toTimestamp(io) orelse return null;
        return .{ .io = io, .at = at };
    }

    /// Milliseconds left, recomputed from the absolute deadline on every
    /// call; 0 once expired.
    pub fn remainingMs(self: Deadline) i64 {
        const now = self.at.clock.now(self.io);
        return remainingMsBetween(now.nanoseconds, self.at.raw.nanoseconds);
    }
};

/// `deadline_ns - now_ns` in milliseconds, rounded up so a
/// sub-millisecond remainder still polls once, saturating instead of
/// overflowing, and clamped to `maxInt(i64)`.
pub fn remainingMsBetween(now_ns: i96, deadline_ns: i96) i64 {
    const ns = deadline_ns -| now_ns;
    if (ns <= 0) return 0;
    const ms = @divFloor(ns, std.time.ns_per_ms) + @intFromBool(@mod(ns, std.time.ns_per_ms) != 0);
    assert(ms > 0);
    return @intCast(@min(ms, std.math.maxInt(i64)));
}

/// One `poll(2)` timeout for `remaining_ms` (> 0). Long waits are capped
/// at `maxInt(i32)`; the caller re-checks the deadline when a capped poll
/// returns 0 instead of reporting a timeout early.
pub fn pollTimeoutMs(remaining_ms: i64) i32 {
    assert(remaining_ms > 0);
    return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
}

/// Outcome of one `waitReadable` call.
pub const Wait = enum {
    /// `fd` is readable or hung up; the caller should read once.
    readable,
    /// Nothing to read yet; the caller re-drains and waits again.
    retry,
};

/// Wait once for `fd` to become readable. Fails with `error.ReadTimeout`
/// when `deadline` has already passed and with `error.ConnectionClosed`
/// when the descriptor reports an error without readable data.
pub fn waitReadable(fd: posix.fd_t, deadline: ?Deadline) !Wait {
    const poll_timeout_ms: i32 = if (deadline) |d| blk: {
        const remaining_ms = d.remainingMs();
        if (remaining_ms <= 0) return error.ReadTimeout;
        break :blk pollTimeoutMs(remaining_ms);
    } else -1;
    assert(poll_timeout_ms == -1 or poll_timeout_ms > 0);

    var fds = [_]posix.pollfd{.{
        .fd = fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    // A capped poll that expires loops back to the deadline check.
    if (try posix.poll(&fds, poll_timeout_ms) == 0) return .retry;

    if ((fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0 and
        (fds[0].revents & posix.POLL.IN) == 0)
    {
        return error.ConnectionClosed;
    }
    if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) == 0) return .retry;
    return .readable;
}

test "readLineAllocTimeout returns ReadTimeout" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var reader: LineReader = .{};
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readLineAllocTimeout(std.testing.allocator, std.testing.io, fds[0], 64, .{
            .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake },
        }),
    );
}

const DelayedWrite = struct {
    fd: posix.fd_t,
    bytes: []const u8,
    delay_ms: i64,

    /// `std.Thread` reports a returned error on stderr; the reading test
    /// then fails on its own expectation.
    fn run(self: DelayedWrite) !void {
        try std.testing.io.sleep(.fromMilliseconds(self.delay_ms), .awake);
        _ = try sys.write(self.fd, self.bytes);
    }
};

test "line reader assembles a line split across multiple reads" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    _ = try sys.write(fds[1], "par");
    const writer = try std.Thread.spawn(.{}, DelayedWrite.run, .{DelayedWrite{
        .fd = fds[1],
        .bytes = "tial\n",
        .delay_ms = 20,
    }});
    defer writer.join();

    var reader: LineReader = .{};
    const line = try reader.readLineAlloc(std.testing.allocator, fds[0], 64);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("partial\n", line);
}

fn shortTimeout(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

test "ReadTimeout keeps a partial frame and the next call resumes it" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var reader: LineReader = .{};
    defer reader.deinit();

    // Longer than the internal buffer, so part of it lands in `pending`.
    var first_half: [6000]u8 = undefined;
    @memset(&first_half, 'a');
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.fd_t, bytes: []const u8) void {
            sys.writeAll(fd, bytes) catch {};
        }
    }.run, .{ fds[1], @as([]const u8, &first_half) });
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readLineAllocMaybeTimeout(std.testing.allocator, std.testing.io, fds[0], 64 * 1024, shortTimeout(50)),
    );
    writer.join();
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readLineAllocTimeout(std.testing.allocator, std.testing.io, fds[0], 64 * 1024, shortTimeout(10)),
    );

    _ = try sys.write(fds[1], "bbb\nnext\n");
    const line = try reader.readLineAllocTimeout(std.testing.allocator, std.testing.io, fds[0], 64 * 1024, shortTimeout(1000));
    defer std.testing.allocator.free(line);
    try std.testing.expectEqual(@as(usize, 6004), line.len);
    try std.testing.expect(std.mem.allEqual(u8, line[0..6000], 'a'));
    try std.testing.expectEqualStrings("bbb\n", line[6000..]);

    const next = try reader.readLineAlloc(std.testing.allocator, fds[0], 64);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("next\n", next);
}

test "readFrameAllocMaybeDeadline measures the deadline on the reader's io" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    // Default: no provider set, the debug io is used.
    var fallback: LineReader = .{};
    defer fallback.deinit();
    try std.testing.expect(fallback.io == null);
    const past = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(-1));
    try std.testing.expectError(
        error.ReadTimeout,
        fallback.readFrameAllocMaybeDeadline(std.testing.allocator, fds[0], 1024, past),
    );

    // A caller that derives deadlines from its own io hands the same io to
    // the reader, so both sides of the comparison share one clock.
    var reader: LineReader = .{};
    defer reader.deinit();
    reader.io = std.testing.io;
    const soon = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(20));
    const started = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readFrameAllocMaybeDeadline(std.testing.allocator, fds[0], 1024, soon),
    );
    const waited = started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds();
    try std.testing.expect(waited >= 15);

    _ = try sys.write(fds[1], "{}\n");
    const later = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromSeconds(5));
    const frame = (try reader.readFrameAllocMaybeDeadline(std.testing.allocator, fds[0], 1024, later)).?;
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("{}\n", frame);
}

test "readFrameAllocMaybeDeadline resumes a frame after a timeout" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var reader: LineReader = .{};
    defer reader.deinit();
    _ = try sys.write(fds[1], "{\"method\":");
    const soon = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromMilliseconds(20));
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readFrameAllocMaybeDeadline(std.testing.allocator, fds[0], 1024, soon),
    );

    _ = try sys.write(fds[1], "\"x\"}\n");
    const later = std.Io.Clock.awake.now(std.testing.io).addDuration(.fromSeconds(5));
    const frame = (try reader.readFrameAllocMaybeDeadline(std.testing.allocator, fds[0], 1024, later)).?;
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("{\"method\":\"x\"}\n", frame);
}

test "readFrameAllocMaybe distinguishes clean EOF from a truncated frame" {
    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        _ = try sys.write(fds[1], "{\"method\":\"x\"}");
        sys.close(fds[1]);

        var reader: LineReader = .{};
        defer reader.deinit();
        try std.testing.expectError(error.TruncatedFrame, reader.readFrameAllocMaybe(std.testing.allocator, fds[0], 1024));
        try std.testing.expect((try reader.readFrameAllocMaybe(std.testing.allocator, fds[0], 1024)) == null);
    }
    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        _ = try sys.write(fds[1], "{\"method\":\"x\"}\n");
        sys.close(fds[1]);

        var reader: LineReader = .{};
        defer reader.deinit();
        const frame = (try reader.readFrameAllocMaybe(std.testing.allocator, fds[0], 1024)).?;
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqualStrings("{\"method\":\"x\"}\n", frame);
        try std.testing.expect((try reader.readFrameAllocMaybe(std.testing.allocator, fds[0], 1024)) == null);
    }
    {
        // A long unterminated frame spills into `pending` before EOF.
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        var long: [9000]u8 = undefined;
        @memset(&long, 'z');
        const writer = try std.Thread.spawn(.{}, struct {
            fn run(fd: posix.fd_t, bytes: []const u8) void {
                sys.writeAll(fd, bytes) catch {};
                sys.close(fd);
            }
        }.run, .{ fds[1], @as([]const u8, &long) });
        defer writer.join();

        var reader: LineReader = .{};
        defer reader.deinit();
        try std.testing.expectError(error.TruncatedFrame, reader.readFrameAllocMaybe(std.testing.allocator, fds[0], 64 * 1024));
    }
}

test "a far deadline does not overflow and still reads a line" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    _ = try sys.write(fds[1], "hi\n");

    var reader: LineReader = .{};
    defer reader.deinit();
    const far: std.Io.Timestamp = .{ .nanoseconds = std.math.maxInt(i96) };
    const frame = (try reader.readFrameAllocMaybeDeadline(std.testing.allocator, fds[0], 64, far)).?;
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("hi\n", frame);
}

test "deinit frees a partial frame held in pending" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    _ = try sys.write(fds[1], "abc");

    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readLineAllocMaybeTimeout(std.testing.allocator, std.testing.io, fds[0], 64, .{
            .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake },
        }),
    );
    try std.testing.expectEqualStrings("abc", reader.pending.items);
}

test "readLineAlloc reports ConnectionClosed on clean EOF" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    sys.close(fds[1]);

    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectError(error.ConnectionClosed, reader.readLineAlloc(std.testing.allocator, fds[0], 64));
    try std.testing.expectEqual(@as(?[]u8, null), try reader.readLineAllocMaybe(std.testing.allocator, fds[0], 64));
}
