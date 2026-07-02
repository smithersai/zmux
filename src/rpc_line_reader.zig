const std = @import("std");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const LineReader = struct {
    buffer: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn readLineAlloc(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) ![]u8 {
        const line = try self.readLineAllocMaybeWithDeadline(allocator, fd, max_len, std.math.maxInt(i64)) orelse return error.ConnectionClosed;
        if (line.len == 0 or line[line.len - 1] != '\n') {
            allocator.free(line);
            return error.ConnectionClosed;
        }
        return line;
    }

    pub fn readLineAllocWithDeadline(
        self: *LineReader,
        allocator: Allocator,
        fd: posix.fd_t,
        max_len: usize,
        deadline_ms: i64,
    ) ![]u8 {
        const line = try self.readLineAllocMaybeWithDeadline(allocator, fd, max_len, deadline_ms) orelse return error.ConnectionClosed;
        if (line.len == 0 or line[line.len - 1] != '\n') {
            allocator.free(line);
            return error.ConnectionClosed;
        }
        return line;
    }

    pub fn readLineAllocMaybe(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) !?[]u8 {
        return self.readLineAllocMaybeWithDeadline(allocator, fd, max_len, std.math.maxInt(i64));
    }

    pub fn readLineAllocMaybeWithDeadline(
        self: *LineReader,
        allocator: Allocator,
        fd: posix.fd_t,
        max_len: usize,
        deadline_ms: i64,
    ) !?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        while (true) {
            if (try self.appendBufferedLine(allocator, &out, max_len)) |line| return line;
            if (self.bufferedLen() != 0) try self.appendBufferedBytes(allocator, &out, max_len);

            const now = std.time.milliTimestamp();
            if (now >= deadline_ms) return error.ReadTimeout;

            var fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const remaining_ms = @min(deadline_ms - now, std.math.maxInt(i32));
            const ready = try posix.poll(&fds, @intCast(remaining_ms));
            if (ready == 0) return error.ReadTimeout;

            if ((fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0 and
                (fds[0].revents & posix.POLL.IN) == 0)
            {
                return error.ConnectionClosed;
            }
            if ((fds[0].revents & posix.POLL.IN) == 0) continue;

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
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const fds = try std.posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    _ = try posix.write(fds[1], "one\ntwo\n");

    var reader: LineReader = .{};
    const first = (try reader.readLineAllocMaybe(std.testing.allocator, fds[0], 64)).?;
    defer std.testing.allocator.free(first);
    const second = (try reader.nextBufferedLineAlloc(std.testing.allocator, 64)).?;
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("one\n", first);
    try std.testing.expectEqualStrings("two\n", second);
}

test "readLineAllocWithDeadline returns ReadTimeout" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const fds = try std.posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var reader: LineReader = .{};
    const deadline = std.time.milliTimestamp() + 20;
    try std.testing.expectError(
        error.ReadTimeout,
        reader.readLineAllocWithDeadline(std.testing.allocator, fds[0], 64, deadline),
    );
}
