//! Line format for `log`: severity levels, size limits, and the
//! allocation-free JSON encoder that turns one event into one line.

const std = @import("std");

const assert = std.debug.assert;

/// Event severity. Lower values are more severe; a level enables itself and
/// every more severe level.
pub const Level = enum(u8) { err = 0, warn = 1, info = 2, debug = 3 };

/// Upper bound for one formatted line, including the trailing newline.
pub const max_line_bytes: usize = 1024;
/// Smallest `buf` that `format` accepts.
pub const min_buffer_len: usize = 128;

/// Name written in the `"level"` member of a line.
pub fn levelName(level: Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}
/// Format one event into `buf` and return the line, newline included. Pure:
/// the timestamp and pid are parameters so tests can assert exact output.
/// `buf.len` must be at least `min_buffer_len`. Fields that overflow `buf`
/// are dropped whole and replaced by `"truncated":true`; if even the header
/// does not fit, the line is `{"event":"log_header_overflow"}`. The result
/// is always one valid JSON object.
pub fn format(
    buf: []u8,
    level: Level,
    ts_ms: i64,
    pid: i64,
    comptime event: []const u8,
    fields: anytype,
) []const u8 {
    return formatSuppressed(buf, level, ts_ms, pid, event, 0, fields);
}

/// The whole line `format` writes when even the header does not fit.
pub const header_overflow_line = "{\"event\":\"log_header_overflow\"}\n";

/// `format` plus a `"suppressed":N` member after the header when N > 0.
pub fn formatSuppressed(
    buf: []u8,
    level: Level,
    ts_ms: i64,
    pid: i64,
    comptime event: []const u8,
    suppressed: u64,
    fields: anytype,
) []const u8 {
    std.debug.assert(buf.len >= min_buffer_len);
    const truncated_marker = ",\"truncated\":true";
    const tail = "}\n";
    comptime std.debug.assert(min_buffer_len >= header_overflow_line.len + truncated_marker.len + tail.len);
    // Reserve room so the marker and the closing brace always fit.
    var line: Line = .{ .buf = buf[0 .. buf.len - truncated_marker.len - tail.len] };

    line.raw("{\"ts_ms\":");
    line.int(ts_ms);
    line.raw(",\"level\":\"");
    line.raw(levelName(level));
    line.raw("\",\"pid\":");
    line.int(pid);
    line.raw(",\"event\":");
    line.string(event);
    if (suppressed != 0) {
        line.raw(",\"suppressed\":");
        line.int(suppressed);
    }
    if (line.overflow) {
        @memcpy(buf[0..header_overflow_line.len], header_overflow_line);
        return buf[0..header_overflow_line.len];
    }

    var truncated = false;
    inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field_name| {
        const checkpoint = line.len;
        line.raw(",");
        line.string(field_name);
        line.raw(":");
        line.value(@field(fields, field_name));
        if (line.overflow) {
            // Roll back the partial field; keep trying later (shorter) fields.
            line.len = checkpoint;
            line.overflow = false;
            truncated = true;
        }
    }

    var end = line.len;
    // `line.buf` reserved room for the marker and the closing brace.
    assert(end + truncated_marker.len + tail.len <= buf.len);
    if (truncated) {
        @memcpy(buf[end..][0..truncated_marker.len], truncated_marker);
        end += truncated_marker.len;
    }
    @memcpy(buf[end..][0..tail.len], tail);
    end += tail.len;
    return buf[0..end];
}

const Line = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn raw(self: *Line, bytes: []const u8) void {
        if (self.overflow) return;
        if (bytes.len > self.buf.len - self.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        assert(self.len <= self.buf.len);
    }

    fn int(self: *Line, number: anytype) void {
        var tmp: [48]u8 = undefined;
        self.raw(std.fmt.bufPrint(&tmp, "{d}", .{number}) catch "0");
    }

    fn string(self: *Line, bytes: []const u8) void {
        if (self.overflow) return;
        // Every input byte emits at least 1 output byte (escaping only expands),
        // plus 2 bytes for the surrounding quotes. Reject guaranteed overflows
        // in O(1) without scanning the input.
        if (self.buf.len - self.len < bytes.len + 2) {
            self.overflow = true;
            return;
        }
        self.raw("\"");
        var i: usize = 0;
        while (i < bytes.len and !self.overflow) {
            // Fast path: batch-copy contiguous runs of plain printable ASCII.
            const run_start = i;
            while (i < bytes.len) {
                const c = bytes[i];
                if (c < 0x20 or c >= 0x7f or c == '"' or c == '\\') break;
                i += 1;
            }
            if (i > run_start) {
                self.raw(bytes[run_start..i]);
                if (i >= bytes.len or self.overflow) break;
            }

            i += self.escaped(bytes[i..]);
        }
        self.raw("\"");
    }

    /// Write the JSON form of the character starting at `rest[0]`, which the
    /// fast path in `string` did not copy, and return how many input bytes
    /// it consumed (at least one).
    fn escaped(self: *Line, rest: []const u8) usize {
        assert(rest.len > 0);
        const byte = rest[0];
        switch (byte) {
            '"' => self.raw("\\\""),
            '\\' => self.raw("\\\\"),
            '\n' => self.raw("\\n"),
            '\r' => self.raw("\\r"),
            '\t' => self.raw("\\t"),
            0...8, 11, 12, 14...0x1f, 0x7f => {
                var tmp: [6]u8 = undefined;
                self.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch "?");
            },
            0x80...0xff => {
                // Emit valid UTF-8 sequences verbatim; replace each stray
                // invalid byte with an escaped U+FFFD so the output is
                // always valid JSON and never misrepresents the byte.
                const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
                assert(seq_len <= 4);
                if (seq_len > 1 and seq_len <= rest.len and std.unicode.utf8ValidateSlice(rest[0..seq_len])) {
                    self.raw(rest[0..seq_len]);
                    return seq_len;
                }
                self.raw("\\ufffd");
            },
            // Printable ASCII is valid JSON as-is. `string` copies it in its
            // fast path, so this arm is only a fallback.
            else => self.raw(rest[0..1]),
        }
        return 1;
    }

    fn value(self: *Line, v: anytype) void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .int, .comptime_int => self.int(v),
            .bool => self.raw(if (v) "true" else "false"),
            .float, .comptime_float => {
                if (@typeInfo(T) == .float and !std.math.isFinite(v)) {
                    self.raw("null");
                    return;
                }
                var tmp: [64]u8 = undefined;
                self.raw(std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0");
            },
            .@"enum" => self.string(@tagName(v)),
            .enum_literal => self.string(@tagName(v)),
            .error_set => self.string(@errorName(v)),
            .optional => if (v) |inner| self.value(inner) else self.raw("null"),
            .null => self.raw("null"),
            .pointer => |pointer| {
                const is_string = switch (pointer.size) {
                    .slice => pointer.child == u8,
                    .one => switch (@typeInfo(pointer.child)) {
                        .array => |array| array.child == u8,
                        else => false,
                    },
                    else => false,
                };
                if (!is_string) @compileError("log field type not supported: " ++ @typeName(T));
                self.string(v);
            },
            else => @compileError("log field type not supported: " ++ @typeName(T)),
        }
    }
};

test "format writes one JSON line with header and typed fields" {
    var buf: [max_line_bytes]u8 = undefined;
    const maybe_uid: ?u32 = null;
    const line = format(&buf, .warn, 1700000000123, 4242, "accept_error", .{
        .err = error.SystemFdQuotaExceeded,
        .active = @as(usize, 7),
        .ok = false,
        .path = @as([]const u8, "/tmp/z.sock"),
        .peer_euid = maybe_uid,
        .level = Level.info,
    });
    try std.testing.expectEqualStrings(
        "{\"ts_ms\":1700000000123,\"level\":\"warn\",\"pid\":4242,\"event\":\"accept_error\"," ++
            "\"err\":\"SystemFdQuotaExceeded\",\"active\":7,\"ok\":false,\"path\":\"/tmp/z.sock\"," ++
            "\"peer_euid\":null,\"level\":\"info\"}\n",
        line,
    );
}

test "format escapes strings so a field cannot break out of its line" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = format(&buf, .err, 1, 2, "e", .{ .path = @as([]const u8, "a\"b\\c\nd\x01") });
    try std.testing.expectEqualStrings(
        "{\"ts_ms\":1,\"level\":\"error\",\"pid\":2,\"event\":\"e\",\"path\":\"a\\\"b\\\\c\\nd\\u0001\"}\n",
        line,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "format drops fields that overflow and still emits valid JSON" {
    var buf: [max_line_bytes]u8 = undefined;
    const huge: [max_line_bytes * 2]u8 = @splat('x');
    const line = format(&buf, .warn, 1, 2, "big", .{
        .payload = @as([]const u8, &huge),
        .count = @as(u32, 9),
    });
    try std.testing.expect(line.len <= max_line_bytes);
    try std.testing.expectEqualStrings(
        "{\"ts_ms\":1,\"level\":\"warn\",\"pid\":2,\"event\":\"big\",\"count\":9,\"truncated\":true}\n",
        line,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
}
fn expectValidJsonLine(line: []const u8) !std.json.Parsed(std.json.Value) {
    try std.testing.expect(line.len > 0 and line[line.len - 1] == '\n');
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    errdefer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    return parsed;
}

test "format with the smallest buffer still emits valid JSON" {
    var buf: [min_buffer_len]u8 = undefined;
    const line = format(&buf, .warn, std.math.maxInt(i64), std.math.minInt(i64), "accept_error", .{
        .err = error.SystemFdQuotaExceeded,
        .path = @as([]const u8, "/a/fairly/long/socket/path/that/will/not/fit/in/the/small/buffer"),
        .n = @as(u8, 1),
    });
    try std.testing.expect(line.len <= min_buffer_len);
    var parsed = try expectValidJsonLine(line);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("accept_error", parsed.value.object.get("event").?.string);
    try std.testing.expect(parsed.value.object.get("truncated").?.bool);
}

test "format emits a fixed line when the header overflows" {
    const quotes: [max_line_bytes]u8 = @splat('"');
    var buf: [max_line_bytes]u8 = undefined;
    const line = format(&buf, .err, 1, 2, &quotes, .{ .n = @as(u8, 1) });
    try std.testing.expectEqualStrings(header_overflow_line, line);
    var parsed = try expectValidJsonLine(line);
    parsed.deinit();

    var small: [min_buffer_len]u8 = undefined;
    const long_event_bytes: [min_buffer_len - 40]u8 = @splat('e');
    const long_event = &long_event_bytes;
    const small_line = format(&small, .debug, std.math.minInt(i64), std.math.minInt(i64), long_event, .{});
    var parsed_small = try expectValidJsonLine(small_line);
    parsed_small.deinit();
}

test "format replaces invalid UTF-8 with U+FFFD and keeps valid sequences" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = format(&buf, .warn, 1, 2, "e", .{ .name = @as([]const u8, "a\xffb\xc3\xa9\xe2\x82") });
    var parsed = try expectValidJsonLine(line);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{e9}\u{FFFD}\u{FFFD}", parsed.value.object.get("name").?.string);
}

test "format output is valid JSON for every truncation point" {
    const unit = "\"\\\n\x01\xff\xc3\xa9 text ";
    var payload_buf: [unit.len * 8]u8 = undefined;
    for (0..8) |k| @memcpy(payload_buf[k * unit.len ..][0..unit.len], unit);
    const payload: []const u8 = &payload_buf;
    var size: usize = min_buffer_len;
    while (size <= 512) : (size += 1) {
        const buf = try std.testing.allocator.alloc(u8, size);
        defer std.testing.allocator.free(buf);
        const line = format(buf, .info, 1700000000000, 99, "sweep", .{
            .a = @as([]const u8, payload),
            .b = @as(u64, 7),
            .c = @as([]const u8, payload[0..40]),
        });
        try std.testing.expect(line.len <= size);
        var parsed = try expectValidJsonLine(line);
        parsed.deinit();
    }
}

test "formatSuppressed puts the suppressed count inline in the object" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = formatSuppressed(&buf, .warn, 1, 2, "accept_error", 999, .{ .err = error.Unexpected });
    try std.testing.expectEqualStrings(
        "{\"ts_ms\":1,\"level\":\"warn\",\"pid\":2,\"event\":\"accept_error\",\"suppressed\":999,\"err\":\"Unexpected\"}\n",
        line,
    );
    const quiet = formatSuppressed(&buf, .warn, 1, 2, "accept_error", 0, .{});
    try std.testing.expect(std.mem.indexOf(u8, quiet, "suppressed") == null);
}
test "format writes non-finite floats as null and finite floats as numbers" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = format(&buf, .info, 1, 2, "f", .{
        .nan = std.math.nan(f64),
        .inf = std.math.inf(f32),
        .half = @as(f64, 0.5),
        .none = null,
    });
    try std.testing.expectEqualStrings(
        "{\"ts_ms\":1,\"level\":\"info\",\"pid\":2,\"event\":\"f\",\"nan\":null,\"inf\":null," ++
            "\"half\":0.5,\"none\":null}\n",
        line,
    );
}

test "format escapes DEL, tab, and carriage return" {
    var buf: [max_line_bytes]u8 = undefined;
    const line = format(&buf, .warn, 1, 2, "e", .{ .s = @as([]const u8, "a\x7fb\tc\rd") });
    var parsed = try expectValidJsonLine(line);
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, line, "a\\u007fb\\tc\\rd") != null);
    try std.testing.expectEqualStrings("a\x7fb\tc\rd", parsed.value.object.get("s").?.string);
}
