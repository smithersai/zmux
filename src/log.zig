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

const assert = std.debug.assert;

/// Event severity. Lower values are more severe; a level enables itself and
/// every more severe level.
pub const Level = enum(u8) { err = 0, warn = 1, info = 2, debug = 3 };

/// Level used until `setLevel` or `initFromEnv` picks another one.
pub const default_level: Level = .warn;
/// Environment variable `initFromEnv` reads the level from.
pub const env_var = "ZMUX_LOG_LEVEL";

/// Upper bound for one formatted line, including the trailing newline.
pub const max_line_bytes: usize = 1024;
/// Smallest `buf` that `format` accepts.
pub const min_buffer_len: usize = 128;

/// Shared state for `warnRateLimited`: at most one line per `interval_ms`.
/// Lock-free; safe to share between threads.
pub const RateLimiter = struct {
    interval_ms: i64,
    /// Monotonic time of the last emitted line; 0 means never.
    last_ms: std.atomic.Value(i64) = .init(0),
    suppressed: std.atomic.Value(u64) = .init(0),

    /// Decide whether a call at `now_ms` (monotonic) may emit. Returns the
    /// number of calls suppressed since the previous emit, or null when this
    /// call is suppressed and counted. Pure apart from the atomics, so tests
    /// can drive it with a fake clock.
    pub fn admit(self: *RateLimiter, now_ms: i64) ?u64 {
        // 0 is the "never emitted" sentinel.
        const stamp = if (now_ms == 0) 1 else now_ms;
        assert(stamp != 0);
        const last = self.last_ms.load(.monotonic);
        if (last != 0 and stamp -| last < self.interval_ms) {
            _ = self.suppressed.fetchAdd(1, .monotonic);
            return null;
        }
        if (self.last_ms.cmpxchgStrong(last, stamp, .monotonic, .monotonic) != null) {
            // Another thread won this interval.
            _ = self.suppressed.fetchAdd(1, .monotonic);
            return null;
        }
        return self.suppressed.swap(0, .monotonic);
    }
};

var current_level = std.atomic.Value(u8).init(@backingInt(default_level));
var dropped_lines = std.atomic.Value(u64).init(0);

/// Set the process-wide level. Safe to call from any thread.
pub fn setLevel(level: Level) void {
    current_level.store(@backingInt(level), .seq_cst);
}

/// The process-wide level.
pub fn getLevel() Level {
    const raw = current_level.load(.seq_cst);
    // Only `setLevel` stores, and it stores a valid `Level`.
    assert(raw <= @backingInt(Level.debug));
    return @fromBackingInt(@intCast(raw));
}

/// True when an event at `level` would be written at the current level.
pub fn enabled(level: Level) bool {
    return @backingInt(level) <= current_level.load(.seq_cst);
}

/// Parse a level name (`error`, `err`, `warn`, `warning`, `info`, `debug`),
/// ignoring ASCII case.
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

/// Level for a raw `ZMUX_LOG_LEVEL` value; null or invalid selects `default_level`.
pub fn levelFromEnvValue(value: ?[]const u8) Level {
    const text = value orelse return default_level;
    return parseLevel(text) catch default_level;
}

/// Name written in the `"level"` member of a line.
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
    assert(line.len <= max_line_bytes);
    assert(line[line.len - 1] == '\n');
    writeStderr(line);
}

/// `emit` at `.err`.
pub fn err(comptime event: []const u8, fields: anytype) void {
    emit(.err, event, fields);
}

/// `emit` at `.warn`.
pub fn warn(comptime event: []const u8, fields: anytype) void {
    emit(.warn, event, fields);
}

/// Emit a warning at most once per `limiter.interval_ms`, counting the
/// suppressed calls. When calls were suppressed since the previous line, the
/// next line carries `"suppressed":N` right after `"event"`, so the count
/// survives field truncation. Calls below the configured level neither emit
/// nor touch the limiter.
pub fn warnRateLimited(comptime event: []const u8, limiter: *RateLimiter, fields: anytype) void {
    if (!enabled(.warn)) return;
    const now_ms = std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
    const suppressed = limiter.admit(now_ms) orelse return;

    var buf: [max_line_bytes]u8 = undefined;
    const ts_ms = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    const line = formatSuppressed(&buf, .warn, ts_ms, currentPid(), event, suppressed, fields);
    writeStderr(line);
}

/// `emit` at `.info`.
pub fn info(comptime event: []const u8, fields: anytype) void {
    emit(.info, event, fields);
}

/// `emit` at `.debug`.
pub fn debug(comptime event: []const u8, fields: anytype) void {
    emit(.debug, event, fields);
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
    writeLine(&stderr.file_writer.interface, bytes);
}

/// Write one line to the sink. A failed write cannot be logged through the
/// logger itself, so it is counted in `droppedLines` instead.
fn writeLine(writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch |write_err| switch (write_err) {
        error.WriteFailed => _ = dropped_lines.fetchAdd(1, .monotonic),
    };
}

/// Number of formatted lines lost because the stderr write failed (for
/// example, stderr closed or a full pipe). Monotonic for the process.
pub fn droppedLines() u64 {
    return dropped_lines.load(.monotonic);
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

test "RateLimiter admits one call per interval and counts the rest" {
    var limiter: RateLimiter = .{ .interval_ms = 1000 };
    try std.testing.expectEqual(@as(?u64, 0), limiter.admit(5000));
    for (0..999) |i| {
        try std.testing.expectEqual(@as(?u64, null), limiter.admit(5000 + @as(i64, @intCast(i % 1000))));
    }
    try std.testing.expectEqual(@as(?u64, 999), limiter.admit(6000));
    try std.testing.expectEqual(@as(?u64, null), limiter.admit(6500));
    try std.testing.expectEqual(@as(?u64, 1), limiter.admit(7000));
    try std.testing.expectEqual(@as(?u64, 0), limiter.admit(9000));
}

test "RateLimiter treats a zero clock reading as a real emit" {
    var limiter: RateLimiter = .{ .interval_ms = 10 };
    try std.testing.expectEqual(@as(?u64, 0), limiter.admit(0));
    try std.testing.expectEqual(@as(?u64, null), limiter.admit(5));
}

test "RateLimiter counts every call exactly once across threads" {
    var limiter: RateLimiter = .{ .interval_ms = std.math.maxInt(i64) };
    const Worker = struct {
        fn run(l: *RateLimiter, admitted: *std.atomic.Value(u64)) void {
            for (0..1000) |_| {
                if (l.admit(1234) != null) _ = admitted.fetchAdd(1, .monotonic);
            }
        }
    };
    var admitted: std.atomic.Value(u64) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &limiter, &admitted });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 1), admitted.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3999), limiter.suppressed.load(.monotonic));
}

test "warnRateLimited below the configured level leaves the limiter untouched" {
    const saved = getLevel();
    defer setLevel(saved);
    setLevel(.err);
    var limiter: RateLimiter = .{ .interval_ms = 1000 };
    warnRateLimited("suppressed_in_test", &limiter, .{ .n = @as(u8, 1) });
    try std.testing.expectEqual(@as(i64, 0), limiter.last_ms.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), limiter.suppressed.load(.monotonic));
}

test "levelName round-trips through parseLevel for every level" {
    for ([_]Level{ .err, .warn, .info, .debug }) |level| {
        try std.testing.expectEqual(level, try parseLevel(levelName(level)));
    }
}

test "writeLine counts a failed sink write as a dropped line" {
    var small: [4]u8 = undefined;
    var full: std.Io.Writer = .fixed(&small);
    const before = droppedLines();
    writeLine(&full, "{\"event\":\"x\"}\n");
    try std.testing.expect(droppedLines() >= before + 1);
}

test "writeLine passes a fitting line through unchanged" {
    var storage: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&storage);
    writeLine(&sink, "{\"event\":\"x\"}\n");
    try std.testing.expectEqualStrings("{\"event\":\"x\"}\n", sink.buffered());
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

test "RateLimiter with a zero interval admits every call" {
    var limiter: RateLimiter = .{ .interval_ms = 0 };
    for (0..5) |_| try std.testing.expectEqual(@as(?u64, 0), limiter.admit(42));
    try std.testing.expectEqual(@as(u64, 0), limiter.suppressed.load(.monotonic));
}
