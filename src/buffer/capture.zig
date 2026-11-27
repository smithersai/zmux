//! Read-only ring view: span math, exact-size copies, and the backwards
//! line scan behind `ScrollbackBuffer.captureLastLinesBounded`.

const std = @import("std");
const scrollback = @import("../buffer.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ScrollbackBuffer = scrollback.ScrollbackBuffer;
const max_capacity = scrollback.max_capacity;

/// The retained bytes of a ring: `len` bytes from index `start` of `data`,
/// wrapping at `data.len`. Logical index 0 is the oldest retained byte.
pub const RingView = struct {
    data: []const u8,
    start: usize,
    len: usize,

    /// The retained bytes from logical index `from` (0 = oldest) to the
    /// newest byte, as at most two contiguous spans of the ring.
    pub fn spans(self: RingView, from: usize) [2][]const u8 {
        std.debug.assert(from <= self.len);
        if (self.len == 0) return .{ &.{}, &.{} };
        const first_len = @min(self.len, self.data.len - self.start);
        if (from >= first_len) {
            const second_from = from - first_len;
            return .{ &.{}, self.data[second_from .. self.len - first_len] };
        }
        return .{ self.data[self.start + from .. self.start + first_len], self.data[0 .. self.len - first_len] };
    }

    fn byteAt(self: RingView, index: usize) u8 {
        return self.data[(self.start + index) % self.data.len];
    }

    /// Copy logical bytes `[from, len)` in one allocation of exactly that size.
    pub fn copyRange(self: RingView, allocator: Allocator, from: usize) ![]u8 {
        const parts = self.spans(from);
        const out = try allocator.alloc(u8, parts[0].len + parts[1].len);
        @memcpy(out[0..parts[0].len], parts[0]);
        @memcpy(out[parts[0].len..], parts[1]);
        assert(out.len == self.len - from);
        return out;
    }

    /// Logical index where the last `max_lines` lines start inside the newest
    /// `max_bytes` bytes. `start_offset` is the stream offset of logical index
    /// 0; when it or the byte cap cut into a UTF-8 sequence, the start moves
    /// forward past its continuation bytes. Requires a non-empty ring and
    /// non-zero `max_lines` and `max_bytes`.
    pub fn lastLinesStart(self: RingView, max_lines: usize, max_bytes: usize, start_offset: u64) usize {
        assert(max_lines > 0 and max_bytes > 0);
        assert(self.len > 0);
        const window = @min(self.len, max_bytes);
        const floor = self.len - window;
        assert(floor < self.len);

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

        if (start == floor and (floor > 0 or start_offset > 0)) {
            // The start was not chosen at a newline; skip continuation bytes
            // (at most three) of a sequence that began before the window.
            var skipped: usize = 0;
            while (start < self.len and skipped < 3 and (self.byteAt(start) & 0xc0) == 0x80) : (skipped += 1) {
                start += 1;
            }
        }
        assert(start <= self.len);
        return start;
    }
};

test "scrollback captures last lines" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 128);
    defer buffer.deinit();

    buffer.append("one\ntwo\nthree\nfour\n");

    const capture = try buffer.captureLastLines(std.testing.allocator, 2);
    defer std.testing.allocator.free(capture);
    try std.testing.expectEqualStrings("three\nfour\n", capture);
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

test "captureLastLinesBounded returns empty for zero lines, zero bytes, or an empty ring" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 16);
    defer buffer.deinit();
    const empty_ring = try buffer.captureLastLinesBounded(std.testing.allocator, 3, 16);
    defer std.testing.allocator.free(empty_ring);
    try std.testing.expectEqual(@as(usize, 0), empty_ring.len);

    buffer.append("a\nb\n");
    const zero_lines = try buffer.captureLastLinesBounded(std.testing.allocator, 0, 16);
    defer std.testing.allocator.free(zero_lines);
    try std.testing.expectEqual(@as(usize, 0), zero_lines.len);
    const zero_bytes = try buffer.captureLastLinesBounded(std.testing.allocator, 3, 0);
    defer std.testing.allocator.free(zero_bytes);
    try std.testing.expectEqual(@as(usize, 0), zero_bytes.len);
}

test "captureLastLines without a newline returns the whole retained text" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 32);
    defer buffer.deinit();
    buffer.append("no newline here");
    const capture = try buffer.captureLastLines(std.testing.allocator, 5);
    defer std.testing.allocator.free(capture);
    try std.testing.expectEqualStrings("no newline here", capture);
}
