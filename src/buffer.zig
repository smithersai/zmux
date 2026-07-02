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
            self.start = (self.start + overflow) % self.data.len;
            self.len -= overflow;
        }

        var write_at = (self.start + self.len) % self.data.len;
        var remaining = bytes;
        while (remaining.len > 0) {
            const chunk_len = @min(remaining.len, self.data.len - write_at);
            @memcpy(self.data[write_at .. write_at + chunk_len], remaining[0..chunk_len]);
            remaining = remaining[chunk_len..];
            write_at = (write_at + chunk_len) % self.data.len;
        }
        self.len += bytes.len;
    }

    pub fn snapshot(self: *const ScrollbackBuffer, allocator: Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.len);
        if (self.len == 0) return out;

        const first_len = @min(self.len, self.data.len - self.start);
        @memcpy(out[0..first_len], self.data[self.start .. self.start + first_len]);
        if (first_len < self.len) {
            @memcpy(out[first_len..], self.data[0 .. self.len - first_len]);
        }
        return out;
    }

    pub fn captureLastLines(self: *const ScrollbackBuffer, allocator: Allocator, max_lines: usize) ![]u8 {
        if (max_lines == 0 or self.len == 0) return allocator.dupe(u8, "");

        const snap = try self.snapshot(allocator);
        defer allocator.free(snap);

        var scan_end = snap.len;
        if (scan_end > 0 and snap[scan_end - 1] == '\n') scan_end -= 1;

        var start: usize = 0;
        var seen: usize = 0;
        var i = scan_end;
        while (i > 0) {
            i -= 1;
            if (snap[i] == '\n') {
                seen += 1;
                if (seen == max_lines) {
                    start = i + 1;
                    break;
                }
            }
        }

        return allocator.dupe(u8, snap[start..]);
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
