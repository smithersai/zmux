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

const format_mod = @import("log/format.zig");

/// Event severity. Lower values are more severe; a level enables itself and
/// every more severe level.
pub const Level = format_mod.Level;

/// Level used until `setLevel` or `initFromEnv` picks another one.
pub const default_level: Level = .warn;
/// Environment variable `initFromEnv` reads the level from.
pub const env_var = "ZMUX_LOG_LEVEL";

/// Upper bound for one formatted line, including the trailing newline.
pub const max_line_bytes = format_mod.max_line_bytes;
/// Smallest `buf` that `format` accepts.
pub const min_buffer_len = format_mod.min_buffer_len;

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
pub const levelName = format_mod.levelName;

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
    assert(line.len <= max_line_bytes and line[line.len - 1] == '\n');
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
pub const format = format_mod.format;

/// The whole line `format` writes when even the header does not fit.
pub const header_overflow_line = format_mod.header_overflow_line;

/// `format` plus a `"suppressed":N` member after the header when N > 0.
pub const formatSuppressed = format_mod.formatSuppressed;

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

test "emit below the configured level writes nothing and does not crash" {
    const saved = getLevel();
    defer setLevel(saved);
    setLevel(.err);
    warn("suppressed_in_test", .{ .n = @as(u8, 1) });
    info("suppressed_in_test", .{});
    debug("suppressed_in_test", .{});
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

test "RateLimiter with a zero interval admits every call" {
    var limiter: RateLimiter = .{ .interval_ms = 0 };
    for (0..5) |_| try std.testing.expectEqual(@as(?u64, 0), limiter.admit(42));
    try std.testing.expectEqual(@as(u64, 0), limiter.suppressed.load(.monotonic));
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("log/format.zig");
}
