const std = @import("std");

const Allocator = std.mem.Allocator;

pub const default_capacity = 10 * 1024 * 1024;
pub const max_capacity = 64 * 1024 * 1024;

pub const ScrollbackBuffer = struct {
    allocator: Allocator,
    data: []u8,
    start: usize = 0,
    len: usize = 0,

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
        return self.snapshotTail(allocator, self.len);
    }

    /// Copy at most the newest `max_bytes` from the ring buffer without
    /// duplicating older history.
    pub fn snapshotTail(self: *const ScrollbackBuffer, allocator: Allocator, max_bytes: usize) ![]u8 {
        const take = @min(self.len, max_bytes);
        const out = try allocator.alloc(u8, take);
        if (take == 0) return out;

        const skip = self.len - take;
        var read_start = self.start + skip;
        if (read_start >= self.data.len) read_start -= self.data.len;
        const first_len = @min(take, self.data.len - read_start);
        @memcpy(out[0..first_len], self.data[read_start .. read_start + first_len]);
        if (first_len < take) {
            @memcpy(out[first_len..], self.data[0 .. take - first_len]);
        }
        return out;
    }

    pub fn captureLastLines(self: *const ScrollbackBuffer, allocator: Allocator, max_lines: usize) ![]u8 {
        if (max_lines == 0 or self.len == 0) return allocator.dupe(u8, "");

        // Scan backwards directly over the 1 or 2 contiguous ring slices so
        // capturing a small tail from a 10 MiB scrollback buffer never copies
        // the full ring.
        const first_len = @min(self.len, self.data.len - self.start);
        const first = self.data[self.start .. self.start + first_len];
        const second_len = self.len - first_len;
        const second = self.data[0..second_len];

        var scan_len = self.len;
        const last_byte = if (second_len > 0) second[second_len - 1] else first[first_len - 1];
        if (last_byte == '\n') scan_len -= 1;

        var seen: usize = 0;
        var logical_start: usize = 0;
        var found = false;

        if (scan_len > first_len) {
            var pos = scan_len - first_len;
            while (std.mem.lastIndexOfScalar(u8, second[0..pos], '\n')) |idx| {
                seen += 1;
                if (seen == max_lines) {
                    logical_start = first_len + idx + 1;
                    found = true;
                    break;
                }
                pos = idx;
            }
        }
        if (!found) {
            var pos = @min(scan_len, first_len);
            while (std.mem.lastIndexOfScalar(u8, first[0..pos], '\n')) |idx| {
                seen += 1;
                if (seen == max_lines) {
                    logical_start = idx + 1;
                    break;
                }
                pos = idx;
            }
        }

        return self.snapshotTail(allocator, self.len - logical_start);
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

test "scrollback snapshotTail returns exact newest bytes across wrap boundaries" {
    var buffer = try ScrollbackBuffer.init(std.testing.allocator, 10);
    defer buffer.deinit();

    const empty = try buffer.snapshotTail(std.testing.allocator, 4);
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    buffer.append("abcdef");
    buffer.append("ghijkl"); // buffer holds "cdefghijkl" wrapped across boundary

    const zero = try buffer.snapshotTail(std.testing.allocator, 0);
    defer std.testing.allocator.free(zero);
    try std.testing.expectEqualStrings("", zero);

    const tail4 = try buffer.snapshotTail(std.testing.allocator, 4);
    defer std.testing.allocator.free(tail4);
    try std.testing.expectEqualStrings("ijkl", tail4);

    const tail8 = try buffer.snapshotTail(std.testing.allocator, 8);
    defer std.testing.allocator.free(tail8);
    try std.testing.expectEqualStrings("efghijkl", tail8);

    const tail_all = try buffer.snapshotTail(std.testing.allocator, 100);
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
