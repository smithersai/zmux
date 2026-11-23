//! Structured diagnostics for zmux daemons and embedders.
//!
//! Every event is one JSON object on one stderr line:
//!
//!     {"ts_ms":1732300000000,"level":"warn","pid":4242,"event":"accept_error","err":"Unexpected"}
//!
//! Rules for callers:
//!   * Log identifiers, counts, sizes, and error names only. NEVER log PTY
//!     bytes, request/response payloads, environment values, or secrets.
//!   * `emit` never allocates and never fails: a line is formatted into a fixed
//!     stack buffer and written with a single `write(2)`. Fields that do not
//!     fit are dropped and the line is marked `"truncated":true`.
//!   * The default level is `.warn`, so a healthy run writes nothing.
//!
//! Like `std.log`, the logger is process-global and does not take an `Io`
//! parameter: it reads the wall clock through `std.Options.debug_io` and
//! serializes lines with `std.debug.lockStderr`, the same stderr lock that
//! `std.debug.print` and `std.log` use, so zmux lines never interleave with
//! other stderr diagnostics in an embedding process.

const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum(u8) { err = 0, warn = 1, info = 2, debug = 3 };

pub const default_level: Level = .warn;
pub const env_var = "ZMUX_LOG_LEVEL";

/// Upper bound for one formatted line, including the trailing newline.
pub const max_line_bytes: usize = 1024;

var current_level = std.atomic.Value(u8).init(@backingInt(default_level));

pub fn setLevel(level: Level) void {
    current_level.store(@backingInt(level), .seq_cst);
}

pub fn getLevel() Level {
    return @fromBackingInt(@intCast(current_level.load(.seq_cst)));
}

/// True when an event at `level` would be written at the current level.
pub fn enabled(level: Level) bool {
    return @backingInt(level) <= current_level.load(.seq_cst);
}

pub fn parseLevel(text: []const u8) error{InvalidLogLevel}!Level {
    const names = [_]struct { name: []const u8, level: Level }{
        .{ .name = "error", .level = .err },
        .{ .name = "err", .level = .err },
        .{ .name = "warn", .level = .warn },
        .{ .name = "warning", .level = .warn },
        .{ .name = "info", .level = .info },
        .{ .name = "debug", .level = .debug },
    };
    for (names) |entry| {
        if (std.ascii.eqlIgnoreCase(text, entry.name)) return entry.level;
    }
    return error.InvalidLogLevel;
}

/// Set the level from `ZMUX_LOG_LEVEL` in `environ` (for example
/// `std.process.Init.environ_map`). Unset or unparseable values select the
/// default (`.warn`) so a typo in the environment cannot make a daemon noisy.
pub fn initFromEnv(environ: *const std.process.Environ.Map) void {
    setLevel(levelFromEnvValue(environ.get(env_var)));
}

pub fn levelFromEnvValue(value: ?[]const u8) Level {
    const text = value orelse return default_level;
    return parseLevel(text) catch default_level;
}

pub fn levelName(level: Level) []const u8 {
    return switch (level) {
        .err => "error",
        .warn => "warn",
        .info => "info",
        .debug => "debug",
    };
}

/// Write one structured event to stderr if `level` is enabled.
///
/// `fields` is an anonymous struct. Supported field types: integers, floats,
/// bools, strings (`[]const u8` and string literals), enums, errors, and
/// optionals of those.
pub fn emit(level: Level, comptime event: []const u8, fields: anytype) void {
    if (!enabled(level)) return;

    var buf: [max_line_bytes]u8 = undefined;
    const now_ms = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    const line = format(&buf, level, now_ms, currentPid(), event, fields);
    writeStderr(line);
}

pub fn err(comptime event: []const u8, fields: anytype) void {
    emit(.err, event, fields);
}

pub fn warn(comptime event: []const u8, fields: anytype) void {
    emit(.warn, event, fields);
}

pub fn info(comptime event: []const u8, fields: anytype) void {
    emit(.info, event, fields);
}

pub fn debug(comptime event: []const u8, fields: anytype) void {
    emit(.debug, event, fields);
}

/// Format one event into `buf` and return the line, newline included. Pure:
/// the timestamp and pid are parameters so tests can assert exact output.
/// `buf` must hold at least the header; fields that overflow it are dropped
/// whole and replaced by `"truncated":true`, so the result is always one
/// valid JSON object.
pub fn format(
    buf: []u8,
    level: Level,
    ts_ms: i64,
    pid: i64,
    comptime event: []const u8,
    fields: anytype,
) []const u8 {
    const truncated_marker = ",\"truncated\":true";
    const tail = "}\n";
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

    var truncated = line.overflow;
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
    }

    fn int(self: *Line, number: anytype) void {
        var tmp: [48]u8 = undefined;
        self.raw(std.fmt.bufPrint(&tmp, "{d}", .{number}) catch "0");
    }

    fn string(self: *Line, bytes: []const u8) void {
        self.raw("\"");
        var i: usize = 0;
        while (i < bytes.len) {
            const byte = bytes[i];
            switch (byte) {
                '"' => {
                    self.raw("\\\"");
                    i += 1;
                },
                '\\' => {
                    self.raw("\\\\");
                    i += 1;
                },
                '\n' => {
                    self.raw("\\n");
                    i += 1;
                },
                '\r' => {
                    self.raw("\\r");
                    i += 1;
                },
                '\t' => {
                    self.raw("\\t");
                    i += 1;
                },
                0...8, 11, 12, 14...0x1f, 0x7f => {
                    var tmp: [6]u8 = undefined;
                    self.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch "?");
                    i += 1;
                },
                0x80...0xff => {
                    // Emit valid UTF-8 sequences verbatim; escape stray invalid
                    // UTF-8 bytes as \u00XX so the output is always valid JSON.
                    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
                    if (seq_len > 1 and i + seq_len <= bytes.len and
                        std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len]))
                    {
                        self.raw(bytes[i .. i + seq_len]);
                        i += seq_len;
                    } else {
                        var tmp: [6]u8 = undefined;
                        self.raw(std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{byte}) catch "?");
                        i += 1;
                    }
                },
                else => {
                    self.raw(&.{byte});
                    i += 1;
                },
            }
        }
        self.raw("\"");
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

fn currentPid() i64 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        .windows, .wasi => 0,
        else => std.c.getpid(),
    };
}

fn writeStderr(bytes: []const u8) void {
    // An empty buffer makes the locked writer hand `bytes` straight to one
    // `write(2)` (retried only on a short write).
    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.writeAll(bytes) catch {};
}

test "parseLevel accepts documented names case-insensitively" {
    try std.testing.expectEqual(Level.err, try parseLevel("error"));
    try std.testing.expectEqual(Level.err, try parseLevel("ERR"));
    try std.testing.expectEqual(Level.warn, try parseLevel("warn"));
    try std.testing.expectEqual(Level.warn, try parseLevel("Warning"));
    try std.testing.expectEqual(Level.info, try parseLevel("INFO"));
    try std.testing.expectEqual(Level.debug, try parseLevel("Debug"));
}

test "parseLevel rejects unknown names" {
    try std.testing.expectError(error.InvalidLogLevel, parseLevel(""));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("trace"));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("warn "));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("2"));
}

test "default level is warn and the environment cannot select an invalid level" {
    try std.testing.expectEqual(Level.warn, default_level);
    try std.testing.expectEqual(Level.warn, levelFromEnvValue(null));
    try std.testing.expectEqual(Level.warn, levelFromEnvValue(""));
    try std.testing.expectEqual(Level.warn, levelFromEnvValue("loud"));
    try std.testing.expectEqual(Level.debug, levelFromEnvValue("debug"));
    try std.testing.expectEqual(Level.err, levelFromEnvValue("ERROR"));
}

test "level filtering passes only events at or above the configured severity" {
    const saved = getLevel();
    defer setLevel(saved);

    setLevel(.warn);
    try std.testing.expect(enabled(.err));
    try std.testing.expect(enabled(.warn));
    try std.testing.expect(!enabled(.info));
    try std.testing.expect(!enabled(.debug));

    setLevel(.err);
    try std.testing.expect(enabled(.err));
    try std.testing.expect(!enabled(.warn));

    setLevel(.debug);
    try std.testing.expect(enabled(.info));
    try std.testing.expect(enabled(.debug));
    try std.testing.expectEqual(Level.debug, getLevel());
}

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

test "emit below the configured level writes nothing and does not crash" {
    const saved = getLevel();
    defer setLevel(saved);
    setLevel(.err);
    warn("suppressed_in_test", .{ .n = @as(u8, 1) });
    info("suppressed_in_test", .{});
    debug("suppressed_in_test", .{});
}
