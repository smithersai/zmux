const std = @import("std");

const Allocator = std.mem.Allocator;
const posix = std.posix;

const sys = @import("sys.zig");

/// Buffered newline-delimited reader over a raw, blocking descriptor.
///
/// Reads use `poll(2)` + `read(2)` directly on the descriptor so a reader can
/// share a socket with a concurrent writer thread. Only the timeout variants
/// need an `std.Io`, to read the monotonic clock.
///
/// A line longer than the 4 KiB buffer accumulates in `pending`, which
/// survives `error.ReadTimeout` so the next call resumes the same frame.
/// Every call on one reader must pass the same allocator; call `deinit`
/// before dropping a reader that may hold a partial frame.
pub const LineReader = struct {
    buffer: [32 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Bytes of the current frame that no longer fit in `buffer`. Never
    /// contains a newline.
    pending: std.ArrayList(u8) = .empty,
    pending_allocator: ?Allocator = null,
    /// After `error.MessageTooLarge`, input is dropped through the next
    /// newline so the stream resynchronizes on the following frame.
    discarding: bool = false,
    /// Clock provider for `readFrameAllocMaybeDeadline`. Set it to the `Io`
    /// the deadline was derived from; null falls back to
    /// `std.Options.debug_io`.
    io: ?std.Io = null,

    pub fn deinit(self: *LineReader) void {
        self.dropPending();
    }

    /// An absolute point on `io`'s clock after which reads fail with
    /// `error.ReadTimeout`.
    const Deadline = struct {
        io: std.Io,
        at: std.Io.Clock.Timestamp,

        fn init(io: std.Io, timeout: std.Io.Timeout) ?Deadline {
            const at = timeout.toTimestamp(io) orelse return null;
            return .{ .io = io, .at = at };
        }

        /// Milliseconds left, recomputed from the absolute deadline on every
        /// call; 0 once expired.
        fn remainingMs(self: Deadline) i64 {
            const now = self.at.clock.now(self.io);
            return remainingMsBetween(now.nanoseconds, self.at.raw.nanoseconds);
        }
    };

    /// `deadline_ns - now_ns` in milliseconds, rounded up so a
    /// sub-millisecond remainder still polls once, saturating instead of
    /// overflowing, and clamped to `maxInt(i64)`.
    fn remainingMsBetween(now_ns: i96, deadline_ns: i96) i64 {
        const ns = deadline_ns -| now_ns;
        if (ns <= 0) return 0;
        const ms = @divFloor(ns, std.time.ns_per_ms) + @intFromBool(@mod(ns, std.time.ns_per_ms) != 0);
        return @intCast(@min(ms, std.math.maxInt(i64)));
    }

    /// One `poll(2)` timeout for `remaining_ms` (> 0). Long waits are capped
    /// at `maxInt(i32)`; the caller re-checks the deadline when a capped poll
    /// returns 0 instead of reporting a timeout early.
    fn pollTimeoutMs(remaining_ms: i64) i32 {
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }

    /// Read one complete line (newline included), blocking without a time
    /// limit. EOF before a newline is `error.ConnectionClosed`.
    pub fn readLineAlloc(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) ![]u8 {
        return requireNewline(allocator, try self.readLineAllocMaybeDeadline(allocator, fd, max_len, null));
    }

    /// Like `readLineAlloc`, but fails with `error.ReadTimeout` once `timeout`
    /// (measured on `io`'s clock) elapses. A partial line stays buffered.
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
        while (true) {
            if (try self.nextBufferedLineAlloc(allocator, max_len)) |line| return line;

            const poll_timeout_ms: i32 = if (deadline) |d| blk: {
                const remaining_ms = d.remainingMs();
                if (remaining_ms <= 0) return error.ReadTimeout;
                break :blk pollTimeoutMs(remaining_ms);
            } else -1;

            var fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            // A capped poll that expires loops back to the deadline check.
            if (try posix.poll(&fds, poll_timeout_ms) == 0) continue;

            if ((fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0 and
                (fds[0].revents & posix.POLL.IN) == 0)
            {
                return error.ConnectionClosed;
            }
            if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP)) == 0) continue;

            switch (try self.fillOnce(fd)) {
                .data, .would_block => {},
                .eof => return self.takeAtEof(allocator),
            }
        }
    }

    /// EOF: hand back the unterminated remainder of the current frame, or
    /// null at a frame boundary (including mid-discard, whose error was
    /// already reported).
    fn takeAtEof(self: *LineReader, allocator: Allocator) !?[]u8 {
        if (self.discarding) {
            self.discarding = false;
            self.start = 0;
            self.end = 0;
            self.dropPending();
            return null;
        }
        const buffered = self.buffer[self.start..self.end];
        if (self.pending.items.len == 0 and buffered.len == 0) return null;

        const line = try allocator.alloc(u8, self.pending.items.len + buffered.len);
        @memcpy(line[0..self.pending.items.len], self.pending.items);
        @memcpy(line[self.pending.items.len..], buffered);
        self.start = 0;
        self.end = 0;
        self.dropPending();
        return line;
    }

    /// Server framing: `null` on clean EOF between frames;
    /// `error.TruncatedFrame` on EOF mid-frame.
    pub fn readFrameAllocMaybe(self: *LineReader, allocator: Allocator, fd: posix.fd_t, max_len: usize) !?[]u8 {
        return frameOrTruncated(allocator, try self.readLineAllocMaybeDeadline(allocator, fd, max_len, null));
    }

    /// `readFrameAllocMaybe` that fails with `error.ReadTimeout` at the
    /// absolute `deadline` on the awake (monotonic) clock, as returned by
    /// `std.Io.Clock.awake.now(io)` for the reader's `io` field. A partial frame stays buffered across the
    /// timeout and the next call resumes it.
    pub fn readFrameAllocMaybeDeadline(
        self: *LineReader,
        allocator: Allocator,
        fd: posix.fd_t,
        max_len: usize,
        deadline: std.Io.Timestamp,
    ) !?[]u8 {
        const at: Deadline = .{ .io = self.io orelse std.Options.debug_io, .at = deadline.withClock(.awake) };
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

    /// True when a complete line is buffered, so `nextBufferedLineAlloc`
    /// returns it without reading.
    pub fn hasBufferedLine(self: *const LineReader) bool {
        const buffered = self.buffer[self.start..self.end];
        const first = std.mem.indexOfScalar(u8, buffered, '\n') orelse return false;
        if (!self.discarding) return true;
        // The first newline only ends the discarded frame.
        return std.mem.indexOfScalar(u8, buffered[first + 1 ..], '\n') != null;
    }

    pub const FillResult = enum { data, would_block, eof };

    /// One read into the internal buffer, never blocking on a non-blocking
    /// descriptor. Used by poll-driven loops, which then drain complete lines
    /// with `nextBufferedLineAlloc` until it returns null. When the buffer is
    /// already full (the caller has not drained it), returns `.data` without
    /// reading.
    pub fn fillOnce(self: *LineReader, fd: posix.fd_t) !FillResult {
        if (self.start != 0) {
            const len = self.bufferedLen();
            std.mem.copyForwards(u8, self.buffer[0..len], self.buffer[self.start..self.end]);
            self.start = 0;
            self.end = len;
        }
        if (self.end == self.buffer.len) return .data;
        const n = posix.read(fd, self.buffer[self.end..]) catch |err| switch (err) {
            error.WouldBlock => return .would_block,
            else => return err,
        };
        if (n == 0) return .eof;
        self.end += n;
        return .data;
    }

    /// Return the next complete buffered line, or null when none is
    /// buffered. A partial line is moved into `pending` so the buffer always
    /// has room for the next `fillOnce`. Fails with `error.MessageTooLarge`
    /// once the current frame exceeds `max_len` bytes (newline included);
    /// the rest of that frame is then discarded.
    pub fn nextBufferedLineAlloc(self: *LineReader, allocator: Allocator, max_len: usize) !?[]u8 {
        if (self.discarding) {
            const buffered = self.buffer[self.start..self.end];
            if (std.mem.indexOfScalar(u8, buffered, '\n')) |index| {
                self.start += index + 1;
                self.discarding = false;
                self.compact();
            } else {
                self.start = 0;
                self.end = 0;
                return null;
            }
        }

        const buffered = self.buffer[self.start..self.end];
        const pending_len = self.pending.items.len;
        if (std.mem.indexOfScalar(u8, buffered, '\n')) |index| {
            const line_len = index + 1;
            if (pending_len > max_len or line_len > max_len - pending_len) {
                self.start += line_len;
                self.compact();
                self.dropPending();
                return error.MessageTooLarge;
            }
            const line = try allocator.alloc(u8, pending_len + line_len);
            @memcpy(line[0..pending_len], self.pending.items);
            @memcpy(line[pending_len..], buffered[0..line_len]);
            self.start += line_len;
            self.compact();
            self.dropPending();
            return line;
        }

        if (buffered.len == 0) return null;
        if (pending_len > max_len or buffered.len > max_len - pending_len) {
            self.start = 0;
            self.end = 0;
            self.dropPending();
            self.discarding = true;
            return error.MessageTooLarge;
        }
        self.pending_allocator = allocator;
        try self.pending.appendSlice(allocator, buffered);
        self.start = 0;
        self.end = 0;
        return null;
    }

    fn dropPending(self: *LineReader) void {
        if (self.pending_allocator) |allocator| self.pending.deinit(allocator);
        self.pending = .empty;
        self.pending_allocator = null;
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

test "nextBufferedLineAlloc keeps a partial line until its newline arrives" {
    var reader: LineReader = .{};
    defer reader.deinit();
    @memcpy(reader.buffer[0..3], "abc");
    reader.start = 0;
    reader.end = 3;

    try std.testing.expect((try reader.nextBufferedLineAlloc(std.testing.allocator, 16)) == null);
    try std.testing.expect(!reader.hasBufferedLine());

    reader.buffer[0] = '\n';
    reader.end = 1;
    try std.testing.expect(reader.hasBufferedLine());
    const line = (try reader.nextBufferedLineAlloc(std.testing.allocator, 16)).?;
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("abc\n", line);
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

test "line reader resynchronizes after an oversized line" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var reader: LineReader = .{};
    defer reader.deinit();

    var big: [10_000]u8 = undefined;
    @memset(&big, 'x');
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.fd_t, bytes: []const u8) void {
            sys.writeAll(fd, bytes) catch {};
            sys.writeAll(fd, "\n{\"ok\":1}\n") catch {};
        }
    }.run, .{ fds[1], @as([]const u8, &big) });
    defer writer.join();

    try std.testing.expectError(error.MessageTooLarge, reader.readLineAlloc(std.testing.allocator, fds[0], 1024));
    const next = try reader.readLineAlloc(std.testing.allocator, fds[0], 1024);
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("{\"ok\":1}\n", next);
}

test "line reader resynchronizes after an oversized buffered line" {
    var reader: LineReader = .{};
    defer reader.deinit();
    const input = "toolong\nok\n";
    @memcpy(reader.buffer[0..input.len], input);
    reader.end = input.len;

    try std.testing.expectError(error.MessageTooLarge, reader.nextBufferedLineAlloc(std.testing.allocator, 4));
    const ok = (try reader.nextBufferedLineAlloc(std.testing.allocator, 4)).?;
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("ok\n", ok);
}

test "max_len of maxInt(usize) does not overflow" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);

    var reader: LineReader = .{};
    defer reader.deinit();
    var long: [5000]u8 = undefined;
    @memset(&long, 'q');
    long[long.len - 1] = '\n';
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.fd_t, bytes: []const u8) void {
            sys.writeAll(fd, bytes) catch {};
        }
    }.run, .{ fds[1], @as([]const u8, &long) });
    defer writer.join();

    const line = try reader.readLineAlloc(std.testing.allocator, fds[0], std.math.maxInt(usize));
    defer std.testing.allocator.free(line);
    try std.testing.expectEqual(long.len, line.len);
}

test "deadline arithmetic saturates and rounds up" {
    const max = std.math.maxInt(i96);
    const min = std.math.minInt(i96);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), LineReader.remainingMsBetween(0, max));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), LineReader.remainingMsBetween(min, max));
    try std.testing.expectEqual(@as(i64, 0), LineReader.remainingMsBetween(max, min));
    try std.testing.expectEqual(@as(i64, 0), LineReader.remainingMsBetween(10, 10));
    try std.testing.expectEqual(@as(i64, 1), LineReader.remainingMsBetween(0, 1));
    try std.testing.expectEqual(@as(i64, 2), LineReader.remainingMsBetween(0, std.time.ns_per_ms + 1));
    try std.testing.expectEqual(@as(i64, 1), LineReader.remainingMsBetween(0, std.time.ns_per_ms));

    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), LineReader.pollTimeoutMs(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), LineReader.pollTimeoutMs(@as(i64, 1) << 31));
    try std.testing.expectEqual(@as(i32, 5), LineReader.pollTimeoutMs(5));
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

test "hasBufferedLine reports buffered lines after one read" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    _ = try sys.write(fds[1], "one\ntwo\n");

    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expect(!reader.hasBufferedLine());
    const first = try reader.readLineAlloc(std.testing.allocator, fds[0], 64);
    defer std.testing.allocator.free(first);
    try std.testing.expect(reader.hasBufferedLine());
    const second = (try reader.nextBufferedLineAlloc(std.testing.allocator, 64)).?;
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("two\n", second);
    try std.testing.expect(!reader.hasBufferedLine());
}

test "fillOnce reports would_block, data, and eof on a non-blocking socket" {
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    try sys.setNonBlocking(pair[0]);

    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectEqual(LineReader.FillResult.would_block, try reader.fillOnce(pair[0]));

    try sys.writeAll(pair[1], "a\nb");
    try std.testing.expectEqual(LineReader.FillResult.data, try reader.fillOnce(pair[0]));
    try std.testing.expect(reader.hasBufferedLine());
    const a = (try reader.nextBufferedLineAlloc(std.testing.allocator, 64)).?;
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("a\n", a);
    try std.testing.expect((try reader.nextBufferedLineAlloc(std.testing.allocator, 64)) == null);

    sys.close(pair[1]);
    try std.testing.expectEqual(LineReader.FillResult.eof, try reader.fillOnce(pair[0]));
}

test "fillOnce with drained lines handles frames larger than the buffer" {
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.setNonBlocking(pair[0]);

    var reader: LineReader = .{};
    defer reader.deinit();
    // Larger than both the reader buffer and the kernel socket buffer
    // (8 KiB on macOS), so the writer runs on its own thread.
    const big = try std.testing.allocator.alloc(u8, 3 * reader.buffer.len);
    defer std.testing.allocator.free(big);
    @memset(big, 'm');
    big[big.len - 1] = '\n';
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: posix.fd_t, bytes: []const u8) void {
            sys.writeAll(fd, bytes) catch {};
        }
    }.run, .{ pair[1], big });
    defer writer.join();

    var got: ?[]u8 = null;
    defer if (got) |line| std.testing.allocator.free(line);
    var spins: usize = 0;
    while (got == null) : (spins += 1) {
        try std.testing.expect(spins < 10_000);
        if (try reader.fillOnce(pair[0]) == .would_block) {
            std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        got = try reader.nextBufferedLineAlloc(std.testing.allocator, 256 * 1024);
    }
    try std.testing.expectEqual(big.len, got.?.len);
}
