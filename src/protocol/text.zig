//! JSON string text helpers: lossy UTF-8 string writing, UTF-8
//! sanitizing, and the plain-ASCII check behind the fast frame paths.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const assert = std.debug.assert;

/// Always emits a JSON string. Invalid UTF-8 sequences become U+FFFD.
pub fn writeJsonStringLossy(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try std.json.Stringify.value(bytes, .{}, writer);
        return;
    }
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len == 0 or i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        }
        assert(i + len <= bytes.len);
        try writeJsonStringBody(writer, bytes[i .. i + len]);
        i += len;
    }
    try writer.writeByte('"');
}

fn writeJsonStringBody(writer: *std.Io.Writer, valid_utf8: []const u8) !void {
    for (valid_utf8) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

/// Copy `bytes`, replacing each invalid UTF-8 byte with U+FFFD.
pub fn sanitizeUtf8Alloc(allocator: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len == 0 or i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        }
        assert(i + len <= bytes.len);
        try out.appendSlice(allocator, bytes[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(allocator);
}

/// True when every byte is printable ASCII that JSON needs no escape for.
pub fn isPlainJsonAscii(bytes: []const u8) bool {
    const Vec = @Vector(16, u8);
    const low: Vec = @splat(0x20);
    const high: Vec = @splat(0x7f);
    const quote: Vec = @splat('"');
    const backslash: Vec = @splat('\\');

    var i: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        const chunk: Vec = bytes[i..][0..16].*;
        const bad = (chunk < low) | (chunk >= high) | (chunk == quote) | (chunk == backslash);
        if (@reduce(.Or, bad)) return false;
    }
    assert(bytes.len - i < 16);
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b < 0x20 or b >= 0x7f or b == '"' or b == '\\') return false;
    }
    return true;
}

test "writeJsonStringLossy replaces invalid UTF-8 and stays a JSON string" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonStringLossy(&out.writer, "\xff\xfe");
    try std.testing.expectEqualStrings("\"\u{FFFD}\u{FFFD}\"", out.written());

    out.clearRetainingCapacity();
    try writeJsonStringLossy(&out.writer, "a\"\\\n\x01\xc3\xa9\xe2\x82");
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"\\\n\x01\u{e9}\u{FFFD}\u{FFFD}", parsed.value.string);

    out.clearRetainingCapacity();
    // Encoded surrogate and overlong NUL are invalid UTF-8.
    try writeJsonStringLossy(&out.writer, "\xed\xa0\x80\xc0\x80");
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.written()));
}

test "sanitizeUtf8Alloc keeps valid text and replaces invalid bytes" {
    const valid = try sanitizeUtf8Alloc(std.testing.allocator, "h\u{e9}llo");
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqualStrings("h\u{e9}llo", valid);

    const fixed = try sanitizeUtf8Alloc(std.testing.allocator, "a\xffb\xc3");
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", fixed);
}
