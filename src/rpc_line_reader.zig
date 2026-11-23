const std = @import("std");

const Allocator = std.mem.Allocator;
const posix = std.posix;

const sys = @import("sys.zig");

/// Buffered newline-delimited reader over a raw, blocking descriptor.
///
/// Reads use `poll(2)` + `read(2)` directly on the descriptor so a reader can
/// share a socket with a concurrent writer thread. Only the timeout variants
/// need an `std.Io`, to read the monotonic clock.
pub const LineReader = struct {
    buffer: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    /// An absolute point on `io`'s clock after which reads fail with
    /// `error.ReadTimeout`.
    const Deadline = struct {
        io: std.Io,
        at: std.Io.Clock.Timestamp,

        fn init(io: std.Io, timeout: std.Io.Timeout) ?Deadline {
            const at = timeout.toTimestamp(io) orelse return null;
            return .{ .io = io, .at = at };
        }

        /// Milliseconds left, rounded up so a sub-millisecond remainder still
        /// polls once instead of timing out early; 0 once expired.
        fn remainingMs(self: Deadline) i64 {
            const ns = self.at.durationFromNow(self.io).raw.toNanoseconds();
            if (ns <= 0) return 0;
            return @intCast(@divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        }
    };

    /// Read one complete line (newline included), blocking without a time
    /// limit. EOF before a newline is `error.ConnectionClosed`.
    pub fn readLineAlloc(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) ![]u8 {
        return requireNewline(allocator, try self.readLineAllocMaybeDeadline(allocator, fd, max_len, null));
    }

    /// Like `readLineAlloc`, but fails with `error.ReadTimeout` once `timeout`
    /// (measured on `io`'s clock) elapses.
    pub fn readLineAllocTimeout(
        self: *LineReader,
        allocator: Allocator,
        io: std.Io,
        fd: posix.fd_t,
        max_len: usize,
        timeout: std.Io.Timeout,
    ) ![]u8 {
        return requireNewline(allocator, try self.readLineAllocMaybeDeadline(allocator, fd, max_len, .init(io, timeout)));
    }

    /// Read one line, returning `null` on EOF with nothing buffered and the
    /// unterminated remainder on EOF after a partial line.
    pub fn readLineAllocMaybe(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) !?[]u8 {
        return self.readLineAllocMaybeDeadline(allocator, fd, max_len, null);
    }

    /// `readLineAllocMaybe` with a timeout on `io`'s clock.
    pub fn readLineAllocMaybeTimeout(
        self: *LineReader,
        allocator: Allocator,
        io: std.Io,
        fd: posix.fd_t,
        max_len: usize,
        timeout: std.Io.Timeout,
    ) !?[]u8 {
        return self.readLineAllocMaybeDeadline(allocator, fd, max_len, .init(io, timeout));
    }

    fn requireNewline(allocator: Allocator, maybe_line: ?[]u8) ![]u8 {
        const line = maybe_line orelse return error.ConnectionClosed;
        if (line.len == 0 or line[line.len - 1] != '\n') {
            allocator.free(line);
            return error.ConnectionClosed;
        }
        return line;
    }

    fn readLineAllocMaybeDeadline(
        self: *LineReader,
        allocator: Allocator,
        fd: posix.fd_t,
        max_len: usize,
        deadline: ?Deadline,
    ) !?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        while (true) {
            if (try self.appendBufferedLine(allocator, &out, max_len)) |line| return line;
            if (self.bufferedLen() != 0) try self.appendBufferedBytes(allocator, &out, max_len);

            const poll_timeout_ms: i32 = if (deadline) |d| blk: {
                const remaining_ms = d.remainingMs();
                if (remaining_ms <= 0) return error.ReadTimeout;
                break :blk @intCast(@min(remaining_ms, std.math.maxInt(i32)));
            } else -1;

            var fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, poll_timeout_ms);
            if (ready == 0) return error.ReadTimeout;

            if ((fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0 and
                (fds[0].revents & posix.POLL.IN) == 0)
            {
                return error.ConnectionClosed;
            }
            if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) == 0) continue;

            const n = posix.read(fd, self.buffer[0..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) {
                if (out.items.len == 0) return null;
                return try out.toOwnedSlice(allocator);
            }
            self.start = 0;
            self.end = n;
        }
    }

    /// Server framing: `null` on clean EOF between frames;
    /// `error.TruncatedFrame` on EOF mid-frame.
    /// Phase 0 stub (T1 owns): blocks without a deadline.
    pub fn readFrameAllocMaybe(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) !?[]u8 {
        return frameOrTruncated(allocator, try self.readLineAllocMaybeDeadline(allocator, fd, max_len, null));
    }

    /// `readFrameAllocMaybe` that fails with `error.ReadTimeout` at the
    /// absolute monotonic `deadline`.
    /// Phase 0 stub (T1 owns): reads `deadline` on the debug Io's awake clock.
    pub fn readFrameAllocMaybeDeadline(
        self: *LineReader,
        allocator: Allocator,
        fd: posix.fd_t,
        max_len: usize,
        deadline: std.Io.Timestamp,
    ) !?[]u8 {
        const at: Deadline = .{ .io = std.Options.debug_io, .at = deadline.withClock(.awake) };
        return frameOrTruncated(allocator, try self.readLineAllocMaybeDeadline(allocator, fd, max_len, at));
    }

    fn frameOrTruncated(allocator: Allocator, maybe_line: ?[]u8) !?[]u8 {
        const line = maybe_line orelse return null;
        if (line.len == 0 or line[line.len - 1] != '\n') {
            allocator.free(line);
            return error.TruncatedFrame;
        }
        return line;
    }

    pub fn hasBufferedLine(self: *const LineReader) bool {
        return std.mem.indexOfScalar(u8, self.buffer[self.start..self.end], '\n') != null;
    }

    pub const FillResult = enum { data, would_block, eof };

    /// One non-blocking read into the internal buffer. Used by poll-driven
    /// loops. Phase 0 stub (T1 owns): returns `would_block` when the buffer is
    /// full.
    pub fn fillOnce(self: *LineReader, fd: posix.fd_t) !FillResult {
        if (self.start != 0) {
            const len = self.bufferedLen();
            std.mem.copyForwards(u8, self.buffer[0..len], self.buffer[self.start..self.end]);
            self.start = 0;
            self.end = len;
        }
        if (self.end == self.buffer.len) return .would_block;
        const n = posix.read(fd, self.buffer[self.end..]) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            else => return err,
        };
        if (n == 0) return .eof;
        self.end += n;
        return .data;
    }

    pub fn nextBufferedLineAlloc(self: *LineReader, allocator: Allocator, max_len: usize) !?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        return try self.appendBufferedLine(allocator, &out, max_len);
    }

    fn appendBufferedLine(
        self: *LineReader,
        allocator: Allocator,
        out: *std.ArrayList(u8),
        max_len: usize,
    ) !?[]u8 {
        const pending = self.buffer[self.start..self.end];
        const newline_index = std.mem.indexOfScalar(u8, pending, '\n') orelse return null;
        const line_len = newline_index + 1;
        if (out.items.len + line_len > max_len) return error.MessageTooLarge;
        try out.appendSlice(allocator, pending[0..line_len]);
        self.start += line_len;
        self.compact();
        return try out.toOwnedSlice(allocator);
    }

    fn appendBufferedBytes(
        self: *LineReader,
        allocator: Allocator,
        out: *std.ArrayList(u8),
        max_len: usize,
    ) !void {
        const pending = self.buffer[self.start..self.end];
        if (out.items.len + pending.len > max_len) return error.MessageTooLarge;
        try out.appendSlice(allocator, pending);
        self.start = self.end;
        self.compact();
    }

    fn bufferedLen(self: *const LineReader) usize {
        return self.end - self.start;
    }

    fn compact(self: *LineReader) void {
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
    }
};

test "line reader keeps leftover bytes for the next line" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    _ = try sys.write(fds[1], "one\ntwo\n");

    var reader: LineReader = .{};
    const first = (try reader.readLineAllocMaybe(std.testing.allocator, fds[0], 64)).?;
    defer std.testing.allocator.free(first);
    const second = (try reader.nextBufferedLineAlloc(std.testing.allocator, 64)).?;
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("one\n", first);
    try std.testing.expectEqualStrings("two\n", second);
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

    fn run(self: DelayedWrite) void {
        std.testing.io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch {};
        _ = sys.write(self.fd, self.bytes) catch {};
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

test "line reader enforces max_len while accumulating a partial line" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var bytes: [2048]u8 = undefined;
    @memset(&bytes, 'x');
    _ = try sys.write(fds[1], &bytes);

    var reader: LineReader = .{};
    try std.testing.expectError(
        error.MessageTooLarge,
        reader.readLineAllocMaybe(std.testing.allocator, fds[0], 1024),
    );
}

test "line reader max_len accepts an exact boundary and rejects one byte over" {
    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        defer sys.close(fds[1]);

        _ = try sys.write(fds[1], "1234\n");
        var reader: LineReader = .{};
        const line = try reader.readLineAlloc(std.testing.allocator, fds[0], 5);
        defer std.testing.allocator.free(line);
        try std.testing.expectEqualStrings("1234\n", line);
    }

    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        defer sys.close(fds[1]);

        _ = try sys.write(fds[1], "12345\n");
        var reader: LineReader = .{};
        try std.testing.expectError(
            error.MessageTooLarge,
            reader.readLineAlloc(std.testing.allocator, fds[0], 5),
        );
    }
}

test "line reader distinguishes EOF partial lines for strict and maybe reads" {
    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        _ = try sys.write(fds[1], "noeol");
        sys.close(fds[1]);

        var reader: LineReader = .{};
        try std.testing.expectError(
            error.ConnectionClosed,
            reader.readLineAlloc(std.testing.allocator, fds[0], 64),
        );
    }

    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        _ = try sys.write(fds[1], "noeol");
        sys.close(fds[1]);

        var reader: LineReader = .{};
        const line = (try reader.readLineAllocMaybe(std.testing.allocator, fds[0], 64)).?;
        defer std.testing.allocator.free(line);
        try std.testing.expectEqualStrings("noeol", line);
    }
}

test "nextBufferedLineAlloc leaves partial buffered data until newline arrives" {
    var reader: LineReader = .{};
    @memcpy(reader.buffer[0..3], "abc");
    reader.start = 0;
    reader.end = 3;

    try std.testing.expect((try reader.nextBufferedLineAlloc(std.testing.allocator, 16)) == null);
    try std.testing.expectEqual(@as(usize, 0), reader.start);
    try std.testing.expectEqual(@as(usize, 3), reader.end);

    reader.buffer[3] = '\n';
    reader.end = 4;
    const line = (try reader.nextBufferedLineAlloc(std.testing.allocator, 16)).?;
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("abc\n", line);
}
