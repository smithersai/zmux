const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_capacity = 10 * 1024 * 1024;
pub const max_capacity = 64 * 1024 * 1024;

pub const Tail = struct { bytes: []u8, start_offset: u64, end_offset: u64 };

pub const ScrollbackBuffer = struct {
    allocator: Allocator,
    data: []u8,
    start: usize = 0,
    len: usize = 0,
    /// Total bytes ever appended.
    total_appended: u64 = 0,

    pub fn init(allocator: Allocator, capacity_bytes: usize) !ScrollbackBuffer {
        const clamped = @max(capacity_bytes, 1);
        const cap = @min(clamped, max_capacity);
        return .{
            .allocator = allocator,
            .data = try allocator.alloc(u8, cap),
        };
    }

    pub fn deinit(self: *ScrollbackBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn capacity(self: *const ScrollbackBuffer) usize {
        return self.data.len;
    }

    pub fn append(self: *ScrollbackBuffer, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.total_appended += bytes.len;

        if (bytes.len >= self.data.len) {
            const tail = bytes[bytes.len - self.data.len ..];
            @memcpy(self.data, tail);
            self.start = 0;
            self.len = self.data.len;
            return;
        }

        const overflow = if (self.len + bytes.len > self.data.len)
            self.len + bytes.len - self.data.len
        else
            0;
        if (overflow > 0) {
            self.start += overflow;
            if (self.start >= self.data.len) self.start -= self.data.len;
            self.len -= overflow;
        }

        var write_at = self.start + self.len;
        if (write_at >= self.data.len) write_at -= self.data.len;
        const first_len = @min(bytes.len, self.data.len - write_at);
        @memcpy(self.data[write_at .. write_at + first_len], bytes[0..first_len]);
        if (first_len < bytes.len) {
            @memcpy(self.data[0 .. bytes.len - first_len], bytes[first_len..]);
        }
        self.len += bytes.len;
    }

    pub fn snapshot(self: *const ScrollbackBuffer, allocator: Allocator) ![]u8 {
        return self.copyRange(allocator, 0);
    }

    /// Total bytes ever appended. Monotonic across wraps; the stream offset
    /// one past the newest byte.
    pub fn endOffset(self: *const ScrollbackBuffer) u64 {
        return self.total_appended;
    }

    /// Stream offset of the oldest retained byte.
    pub fn startOffset(self: *const ScrollbackBuffer) u64 {
        return self.total_appended - self.len;
    }

    /// The retained bytes from logical index `from` (0 = oldest) to the
    /// newest byte, as at most two contiguous spans of the ring.
    fn spans(self: *const ScrollbackBuffer, from: usize) [2][]const u8 {
        std.debug.assert(from <= self.len);
        if (self.len == 0) return .{ &.{}, &.{} };
        const first_len = @min(self.len, self.data.len - self.start);
        if (from >= first_len) {
            const second_from = from - first_len;
            return .{ &.{}, self.data[second_from .. self.len - first_len] };
        }
        return .{ self.data[self.start + from .. self.start + first_len], self.data[0 .. self.len - first_len] };
    }

    fn byteAt(self: *const ScrollbackBuffer, index: usize) u8 {
        return self.data[(self.start + index) % self.data.len];
    }

    fn copyRange(self: *const ScrollbackBuffer, allocator: Allocator, from: usize) ![]u8 {
        const parts = self.spans(from);
        const out = try allocator.alloc(u8, parts[0].len + parts[1].len);
        @memcpy(out[0..parts[0].len], parts[0]);
        @memcpy(out[parts[0].len..], parts[1]);
        return out;
    }

    /// Copy the newest `min(len, max_bytes)` bytes with their stream
    /// offsets. Allocates exactly the returned length, never the whole ring.
    pub fn snapshotTail(self: *const ScrollbackBuffer, allocator: Allocator, max_bytes: usize) !Tail {
        const n = @min(self.len, max_bytes);
        const bytes = try self.copyRange(allocator, self.len - n);
        return .{
            .bytes = bytes,
            .start_offset = self.total_appended - n,
            .end_offset = self.total_appended,
        };
    }

    pub fn captureLastLines(self: *const ScrollbackBuffer, allocator: Allocator, max_lines: usize) ![]u8 {
        return self.captureLastLinesBounded(allocator, max_lines, self.capacity());
    }

    /// The last `max_lines` lines (a trailing newline does not start a new
    /// line), limited to the newest `max_bytes` bytes. Scans the ring
    /// backwards and makes one allocation of the result size. When the byte
    /// cap or ring eviction cuts into a UTF-8 sequence, the start moves
    /// forward to the next lead byte.
    pub fn captureLastLinesBounded(self: *const ScrollbackBuffer, allocator: Allocator, max_lines: usize, max_bytes: usize) ![]u8 {
        if (max_lines == 0 or self.len == 0 or max_bytes == 0) return allocator.alloc(u8, 0);

        const window = @min(self.len, max_bytes);
        const floor = self.len - window;

        var scan_end = self.len;
        if (self.byteAt(scan_end - 1) == '\n') scan_end -= 1;

        var start = floor;
        var seen: usize = 0;
        var i = scan_end;
        while (i > floor) {
            i -= 1;
            if (self.byteAt(i) == '\n') {
                seen += 1;
                if (seen == max_lines) {
                    start = i + 1;
                    break;
                }
            }
        }

        if (start == floor and (floor > 0 or self.startOffset() > 0)) {
            // The start was not chosen at a newline; skip continuation bytes
            // (at most three) of a sequence that began before the window.
            var skipped: usize = 0;
            while (start < self.len and skipped < 3 and (self.byteAt(start) & 0xc0) == 0x80) : (skipped += 1) start += 1;
        }

        return self.copyRange(allocator, start);
    }
};

test "scrollback keeps newest bytes after wrap" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 8);
    defer buffer.deinit();

    buffer.append("hello");
    buffer.append(" world");

    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("lo world", snap);
}

test "scrollback captures last lines" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 128);
    defer buffer.deinit();

    buffer.append("one\ntwo\nthree\nfour\n");

    const capture = try buffer.captureLastLines(std.testing.allocator, 2);
    defer std.testing.allocator.free(capture);
    try std.testing.expectEqualStrings("three\nfour\n", capture);
}

test "scrollback append larger than capacity keeps only the newest tail" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 8);
    defer buffer.deinit();

    buffer.append("0123456789abcdefghijkl");

    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("efghijkl", snap);
}

test "scrollback repeated wrap cycles match a reference tail" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 13);
    defer buffer.deinit();

    var reference = std.ArrayList(u8).empty;
    defer reference.deinit(std.testing.allocator);

    const chunks = [_][]const u8{
        "abc",
        "defgh",
        "ij",
        "klmnop",
        "qrst",
        "uvwxyz",
        "0123456789",
    };
    for (chunks) |chunk| {
        buffer.append(chunk);
        try reference.appendSlice(std.testing.allocator, chunk);
        const snap = try buffer.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snap);
        const expected = if (reference.items.len > buffer.capacity())
            reference.items[reference.items.len - buffer.capacity() ..]
        else
            reference.items;
        try std.testing.expectEqualStrings(expected, snap);
    }
}

test "scrollback captureLastLines handles boundaries and wrapped oldest line" {
    {
        var empty = try ScrollbackBuffer.init(std.testing.allocator, 8);
        defer empty.deinit();
        const capture = try empty.captureLastLines(std.testing.allocator, 10);
        defer std.testing.allocator.free(capture);
        try std.testing.expectEqualStrings("", capture);
    }

    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 32);
    defer buffer.deinit();
    buffer.append("one\ntwo\nthree");

    const zero = try buffer.captureLastLines(std.testing.allocator, 0);
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqualStrings("", zero);

    const all = try buffer.captureLastLines(std.testing.allocator, 99);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqualStrings("one\ntwo\nthree", all);

    const one = try buffer.captureLastLines(std.testing.allocator, 1);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("three", one);

    var wrapped = try ScrollbackBuffer.init(std.testing.allocator, 10);
    defer wrapped.deinit();
    wrapped.append("oldest\nnew\nlast\n");
    const wrapped_capture = try wrapped.captureLastLines(std.testing.allocator, 2);
    defer std.testing.allocator.free(wrapped_capture);
    try std.testing.expectEqualStrings("new\nlast\n", wrapped_capture);
}

test "scrollback exact-capacity append fills the buffer" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 8);
    defer buffer.deinit();

    buffer.append("12345678");

    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("12345678", snap);
}

test "scrollback initialization clamps oversized capacity" {
    const capacity = 3 * 1024 * 1024 * 1024;
    const capped = @min(@max(capacity, 1), max_capacity);
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, capacity);
    defer buffer.deinit();
    try std.testing.expectEqual(capped, buffer.capacity());
}

test "endOffset is monotonic across wraps and matches the tail" {
    const cap = 16;
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, cap);
    defer buffer.deinit();
    try std.testing.expectEqual(@as(u64, 0), buffer.endOffset());

    var expected: u64 = 0;
    const chunk = "abcdefg";
    while (expected < 3 * cap) {
        const n = @min(chunk.len, 3 * cap - expected);
        buffer.append(chunk[0..n]);
        expected += n;
        try std.testing.expectEqual(expected, buffer.endOffset());
    }
    try std.testing.expectEqual(@as(u64, 3 * cap), buffer.endOffset());
    try std.testing.expectEqual(@as(u64, 2 * cap), buffer.startOffset());

    const tail = try buffer.snapshotTail(std.testing.allocator, 1024);
    defer std.testing.allocator.free(tail.bytes);
    try std.testing.expectEqual(buffer.endOffset(), tail.end_offset);
    try std.testing.expectEqual(@as(u64, 2 * cap), tail.start_offset);
    try std.testing.expectEqual(@as(usize, cap), tail.bytes.len);

    const big: [5 * cap]u8 = @splat('x');
    buffer.append(&big);
    try std.testing.expectEqual(@as(u64, 8 * cap), buffer.endOffset());
}

test "snapshotTail copies a wrapped ring exactly with exact offsets" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 10);
    defer buffer.deinit();
    buffer.append("0123456789");
    buffer.append("abcd"); // ring: "456789abcd", wrapped

    const cases = [_]struct { max: usize, want: []const u8 }{
        .{ .max = 0, .want = "" },
        .{ .max = 3, .want = "bcd" },
        .{ .max = 4, .want = "abcd" },
        .{ .max = 6, .want = "89abcd" },
        .{ .max = 10, .want = "456789abcd" },
        .{ .max = 99, .want = "456789abcd" },
    };
    for (cases) |case| {
        const tail = try buffer.snapshotTail(std.testing.allocator, case.max);
        defer std.testing.allocator.free(tail.bytes);
        try std.testing.expectEqualStrings(case.want, tail.bytes);
        try std.testing.expectEqual(@as(u64, 14), tail.end_offset);
        try std.testing.expectEqual(14 - case.want.len, tail.start_offset);
    }

    var empty = try ScrollbackBuffer.init(std.testing.allocator, 4);
    defer empty.deinit();
    const none = try empty.snapshotTail(std.testing.allocator, 4);
    defer std.testing.allocator.free(none.bytes);
    try std.testing.expectEqual(@as(usize, 0), none.bytes.len);
    try std.testing.expectEqual(@as(u64, 0), none.start_offset);
}

test "snapshotTail and bounded capture of a 64 MiB ring allocate only the tail" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, max_capacity);
    defer buffer.deinit();
    var chunk: [64 * 1024]u8 = undefined;
    for (&chunk, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else 'a' + @as(u8, @intCast(i % 26));
    var written: usize = 0;
    // Overfill by half a chunk so the ring is wrapped.
    while (written < max_capacity + chunk.len / 2) : (written += chunk.len) buffer.append(&chunk);

    const max_bytes = 256 * 1024;
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const tail = try buffer.snapshotTail(counting.allocator(), max_bytes);
    defer counting.allocator().free(tail.bytes);
    try std.testing.expectEqual(@as(usize, max_bytes), tail.bytes.len);
    try std.testing.expect(counting.allocated_bytes <= max_bytes);
    try std.testing.expectEqual(tail.end_offset - tail.start_offset, @as(u64, max_bytes));

    var counting_capture = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const capture = try buffer.captureLastLinesBounded(counting_capture.allocator(), 1_000_000, max_bytes);
    defer counting_capture.allocator().free(capture);
    try std.testing.expect(capture.len <= max_bytes);
    try std.testing.expect(counting_capture.allocated_bytes <= max_bytes);
    try std.testing.expectEqual(@as(usize, 1), counting_capture.allocations);
    try std.testing.expect(capture.len > max_bytes - 4);
}

test "captureLastLinesBounded honors the byte cap and line count" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 64);
    defer buffer.deinit();
    buffer.append("one\ntwo\nthree\nfour\n");

    const two = try buffer.captureLastLinesBounded(std.testing.allocator, 2, 64);
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings("three\nfour\n", two);

    // The cap cuts inside "three": lines are counted only inside the window.
    const capped = try buffer.captureLastLinesBounded(std.testing.allocator, 3, 8);
    defer std.testing.allocator.free(capped);
    try std.testing.expectEqualStrings("ee\nfour\n", capped);

    const zero_bytes = try buffer.captureLastLinesBounded(std.testing.allocator, 3, 0);
    defer std.testing.allocator.free(zero_bytes);
    try std.testing.expectEqualStrings("", zero_bytes);

    // Without a trailing newline the partial last line counts as a line.
    buffer.append("five");
    const last = try buffer.captureLastLinesBounded(std.testing.allocator, 1, 64);
    defer std.testing.allocator.free(last);
    try std.testing.expectEqualStrings("five", last);
}

test "captureLastLinesBounded captures a wrapped ring exactly" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 12);
    defer buffer.deinit();
    buffer.append("aaaa\nbbbb\n");
    buffer.append("cc\ndd\n"); // 16 bytes into 12: the ring wraps
    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("\nbbbb\ncc\ndd\n", snap);

    for (1..5) |lines| {
        const got = try buffer.captureLastLinesBounded(std.testing.allocator, lines, 12);
        defer std.testing.allocator.free(got);
        const want: []const u8 = switch (lines) {
            1 => "dd\n",
            2 => "cc\ndd\n",
            3 => "bbbb\ncc\ndd\n",
            else => "\nbbbb\ncc\ndd\n",
        };
        try std.testing.expectEqualStrings(want, got);
    }
}

test "captureLastLinesBounded moves a mid-code-point start forward" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 64);
    defer buffer.deinit();
    // "\u{20ac}" is three bytes: e2 82 ac.
    buffer.append("\u{20ac}\u{20ac}x\n");
    // A 4-byte window starts at the second byte of the second euro sign.
    const cut = try buffer.captureLastLinesBounded(std.testing.allocator, 5, 4);
    defer std.testing.allocator.free(cut);
    try std.testing.expectEqualStrings("x\n", cut);
    // A 5-byte window starts on a lead byte and is kept whole.
    const whole = try buffer.captureLastLinesBounded(std.testing.allocator, 5, 5);
    defer std.testing.allocator.free(whole);
    try std.testing.expectEqualStrings("\u{20ac}x\n", whole);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));

    // Ring eviction can cut a code point too.
    var small = try ScrollbackBuffer.init(std.testing.allocator, 5);
    defer small.deinit();
    // Six bytes into five evicts the euro sign's lead byte.
    small.append("\u{20ac}\u{e9}z");
    const evicted = try small.captureLastLines(std.testing.allocator, 1);
    defer std.testing.allocator.free(evicted);
    try std.testing.expect(std.unicode.utf8ValidateSlice(evicted));
    try std.testing.expectEqualStrings("\u{e9}z", evicted);

    // A fresh buffer that starts with a stray continuation byte is not cut.
    var fresh = try ScrollbackBuffer.init(std.testing.allocator, 8);
    defer fresh.deinit();
    fresh.append("\x80ab");
    const raw = try fresh.captureLastLines(std.testing.allocator, 1);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("\x80ab", raw);
}

fn captureForAllocTest(allocator: Allocator, buffer: *const ScrollbackBuffer) !void {
    const capture = try buffer.captureLastLinesBounded(allocator, 2, 6);
    allocator.free(capture);
    const tail = try buffer.snapshotTail(allocator, 3);
    allocator.free(tail.bytes);
}

test "capture and tail fail cleanly on allocation failure" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 8);
    defer buffer.deinit();
    buffer.append("one\ntwo\nthree\n");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, captureForAllocTest, .{@as(*const ScrollbackBuffer, &buffer)});
}

test "scrollback snapshotTail returns exact newest bytes across wrap boundaries" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 10);
    defer buffer.deinit();

    const empty = (try buffer.snapshotTail(std.testing.allocator, 4)).bytes;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    buffer.append("abcdef");
    buffer.append("ghijkl"); // buffer holds "cdefghijkl" wrapped across boundary

    const zero = (try buffer.snapshotTail(std.testing.allocator, 0)).bytes;
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqualStrings("", zero);

    const tail4 = (try buffer.snapshotTail(std.testing.allocator, 4)).bytes;
    defer std.testing.allocator.free(tail4);
    try std.testing.expectEqualStrings("ijkl", tail4);

    const tail8 = (try buffer.snapshotTail(std.testing.allocator, 8)).bytes;
    defer std.testing.allocator.free(tail8);
    try std.testing.expectEqualStrings("efghijkl", tail8);

    const tail_all = (try buffer.snapshotTail(std.testing.allocator, 100)).bytes;
    defer std.testing.allocator.free(tail_all);
    try std.testing.expectEqualStrings("cdefghijkl", tail_all);
}

test "scrollback captureLastLines matches full snapshot reference across all wrap positions" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 16);
    defer buffer.deinit();

    const inputs = [_][]const u8{
        "a\n",
        "bc\nd",
        "ef\n\ng",
        "hij\nklmn\n",
        "opqr\nstuv\nwxyz",
        "\n\n\n",
    };
    for (inputs) |chunk| {
        buffer.append(chunk);
        const full = try buffer.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(full);

        for (0..6) |lines| {
            const actual = try buffer.captureLastLines(std.testing.allocator, lines);
            defer std.testing.allocator.free(actual);

            // Reference implementation over `full`.
            const expected: []const u8 = blk: {
                if (lines == 0 or full.len == 0) break :blk "";
                var scan_end = full.len;
                if (full[scan_end - 1] == '\n') scan_end -= 1;
                var start: usize = 0;
                var seen: usize = 0;
                var i = scan_end;
                while (i > 0) {
                    i -= 1;
                    if (full[i] == '\n') {
                        seen += 1;
                        if (seen == lines) {
                            start = i + 1;
                            break;
                        }
                    }
                }
                break :blk full[start..];
            };
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
}
