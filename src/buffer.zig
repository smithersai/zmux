//! Per-pane scrollback: a fixed-capacity byte ring that keeps the newest
//! output and tracks absolute stream offsets across wraps.

const std = @import("std");
const capture = @import("buffer/capture.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Read-only view of a ring's retained bytes; see `ScrollbackBuffer.view`.
pub const RingView = capture.RingView;

/// Scrollback capacity in bytes a pane gets when the client does not ask for one.
pub const default_capacity = 10 * 1024 * 1024;
/// Largest ring `ScrollbackBuffer.init` allocates; bigger requests are clamped.
pub const max_capacity = 64 * 1024 * 1024;

/// A copied tail of the ring: `bytes` covers stream offsets
/// `[start_offset, end_offset)`. The caller owns `bytes`.
pub const Tail = struct { bytes: []u8, start_offset: u64, end_offset: u64 };

/// Fixed-capacity byte ring that keeps the newest output of a pane and tracks
/// absolute stream offsets across wraps.
pub const ScrollbackBuffer = struct {
    allocator: Allocator,
    data: []u8,
    start: usize = 0,
    len: usize = 0,
    /// Total bytes ever appended.
    total_appended: u64 = 0,

    /// Allocate a ring of `capacity_bytes`, clamped to `[1, max_capacity]`.
    pub fn init(allocator: Allocator, capacity_bytes: usize) !ScrollbackBuffer {
        const clamped = @max(capacity_bytes, 1);
        const cap = @min(clamped, max_capacity);
        assert(cap >= 1);
        assert(cap <= max_capacity);
        return .{
            .allocator = allocator,
            .data = try allocator.alloc(u8, cap),
        };
    }

    /// Free the ring. The buffer is unusable afterwards.
    pub fn deinit(self: *ScrollbackBuffer) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// Ring size in bytes; the most bytes the buffer retains.
    pub fn capacity(self: *const ScrollbackBuffer) usize {
        return self.data.len;
    }

    /// Append `bytes`, evicting the oldest retained bytes when the ring is full.
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
        assert(self.len <= self.data.len);
        assert(self.start < self.data.len);
    }

    /// Copy every retained byte, oldest first. The caller owns the result.
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

    /// A read-only view of the retained bytes for span math and copies.
    pub fn view(self: *const ScrollbackBuffer) RingView {
        assert(self.len <= self.data.len);
        return .{ .data = self.data, .start = self.start, .len = self.len };
    }

    fn copyRange(self: *const ScrollbackBuffer, allocator: Allocator, from: usize) ![]u8 {
        return self.view().copyRange(allocator, from);
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

    /// The last `max_lines` lines of the whole ring; see `captureLastLinesBounded`.
    pub fn captureLastLines(self: *const ScrollbackBuffer, allocator: Allocator, max_lines: usize) ![]u8 {
        return self.captureLastLinesBounded(allocator, max_lines, self.capacity());
    }

    /// The last `max_lines` lines (a trailing newline does not start a new
    /// line), limited to the newest `max_bytes` bytes. Scans the ring
    /// backwards and makes one allocation of the result size. When the byte
    /// cap or ring eviction cuts into a UTF-8 sequence, the start moves
    /// forward to the next lead byte.
    pub fn captureLastLinesBounded(
        self: *const ScrollbackBuffer,
        allocator: Allocator,
        max_lines: usize,
        max_bytes: usize,
    ) ![]u8 {
        if (max_lines == 0 or self.len == 0 or max_bytes == 0) return allocator.alloc(u8, 0);

        const start = self.view().lastLinesStart(max_lines, max_bytes, self.startOffset());
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

test "append of an empty slice leaves a wrapped ring untouched" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 4);
    defer buffer.deinit();
    buffer.append("abcdef");
    const start = buffer.start;
    buffer.append("");
    try std.testing.expectEqual(start, buffer.start);
    try std.testing.expectEqual(@as(u64, 6), buffer.endOffset());
    try std.testing.expectEqual(@as(u64, 2), buffer.startOffset());
    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("cdef", snap);
}

test "init with zero capacity clamps to a one-byte ring" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 0);
    defer buffer.deinit();
    try std.testing.expectEqual(@as(usize, 1), buffer.capacity());
    buffer.append("ab");
    buffer.append("c");
    const snap = try buffer.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("c", snap);
    try std.testing.expectEqual(@as(u64, 2), buffer.startOffset());
    try std.testing.expectEqual(@as(u64, 3), buffer.endOffset());
}

test "init propagates allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ScrollbackBuffer.init(failing.allocator(), 16));
}

test "snapshotTail with zero or oversized max_bytes uses the ring bounds" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 4);
    defer buffer.deinit();
    buffer.append("0123456");

    const none = try buffer.snapshotTail(std.testing.allocator, 0);
    defer std.testing.allocator.free(none.bytes);
    try std.testing.expectEqual(@as(usize, 0), none.bytes.len);
    try std.testing.expectEqual(@as(u64, 7), none.start_offset);
    try std.testing.expectEqual(@as(u64, 7), none.end_offset);

    const all = try buffer.snapshotTail(std.testing.allocator, 1000);
    defer std.testing.allocator.free(all.bytes);
    try std.testing.expectEqualStrings("3456", all.bytes);
    try std.testing.expectEqual(@as(u64, 3), all.start_offset);
    try std.testing.expectEqual(@as(u64, 7), all.end_offset);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("buffer/capture.zig");
}
