const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const log = zmux.internal.log;

fn referenceParseLevel(text: []const u8) ?log.Level {
    if (std.ascii.eqlIgnoreCase(text, "error") or std.ascii.eqlIgnoreCase(text, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(text, "warn") or std.ascii.eqlIgnoreCase(text, "warning")) return .warn;
    if (std.ascii.eqlIgnoreCase(text, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(text, "debug")) return .debug;
    return null;
}

fn fuzzLogLevelParsing(_: void, smith: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);

    const expected = referenceParseLevel(raw);
    if (expected) |lvl| {
        try std.testing.expectEqual(lvl, try log.parseLevel(raw));
        try std.testing.expectEqual(lvl, log.levelFromEnvValue(raw));
    } else {
        try std.testing.expectError(error.InvalidLogLevel, log.parseLevel(raw));
        try std.testing.expectEqual(log.default_level, log.levelFromEnvValue(raw));
    }
}

fn fuzzLogFormatJsonInvariants(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    const level = smith.value(log.Level);
    const ts_ms = smith.value(i64);
    const pid = smith.value(i64);
    const count_u64 = smith.value(u64);
    const delta_i64 = smith.value(i64);
    const flag = smith.value(bool);
    const maybe_uid: ?u32 = if (smith.value(bool)) smith.value(u32) else null;
    const float_val: f64 = smith.value(f64);

    var str1_buf: [512]u8 = undefined;
    var str2_buf: [256]u8 = undefined;
    const str1 = corpus.drawBytes(smith, &str1_buf);
    const str2 = corpus.drawBytes(smith, &str2_buf);

    // Test both full max_line_bytes and tighter buffers that force field truncation
    // (still large enough for the fixed header + truncated marker + tail).
    const buf_len: usize = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => 140,
        1 => smith.valueRangeAtMost(u16, 141, 400),
        else => log.max_line_bytes,
    };

    var backing: [log.max_line_bytes]u8 = undefined;
    const line = log.format(backing[0..buf_len], level, ts_ms, pid, "fuzz_event", .{
        .str1 = str1,
        .count = count_u64,
        .delta = delta_i64,
        .ok = flag,
        .uid = maybe_uid,
        .ratio = float_val,
        .str2 = str2,
        .err = error.ConnectionResetByPeer,
        .sev = level,
    });

    // Fundamental invariants of structured JSON stderr logs:
    // 1. Bounded to caller buffer
    try std.testing.expect(line.len <= buf_len);
    // 2. Single physical line terminated by '\n' (no log injection / breakout)
    try std.testing.expect(line.len >= 3);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n'));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\r'));

    // 3. ALWAYS valid RFC 8259 JSON parseable by std.json!
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;

    // 4. Required header fields are always present and exact.
    try std.testing.expectEqual(ts_ms, obj.get("ts_ms").?.integer);
    try std.testing.expectEqualStrings(log.levelName(level), obj.get("level").?.string);
    try std.testing.expectEqual(pid, obj.get("pid").?.integer);
    try std.testing.expectEqualStrings("fuzz_event", obj.get("event").?.string);
}

test "fuzz: log.parseLevel and levelFromEnvValue" {
    try std.testing.fuzz({}, fuzzLogLevelParsing, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("error"),
            corpus.sliceSeed("ERR"),
            corpus.sliceSeed("Warning"),
            corpus.sliceSeed("INFO"),
            corpus.sliceSeed("debug"),
            corpus.sliceSeed("trace"),
            corpus.sliceSeed("warn\n"),
        },
    });
}

test "fuzz: log.format always emits valid single-line JSON under arbitrary payloads and truncation" {
    const nan_bits: u64 = @bitCast(std.math.nan(f64));
    const inf_bits: u64 = @bitCast(std.math.inf(f64));
    try std.testing.fuzz({}, fuzzLogFormatJsonInvariants, .{
        .corpus = &.{
            // Regression seed: raw invalid UTF-8 bytes + NaN float + tight truncation buffer.
            corpus.seed(&.{
                .{ .int = 1 }, // Level.warn
                .{ .int = 1700000000000 },
                .{ .int = 42 },
                .{ .int = 99 },
                .{ .int = @bitCast(@as(i64, -1)) },
                .{ .int = 1 },
                .{ .int = 1 },
                .{ .int = 1000 },
                .{ .int = nan_bits },
                .{ .slice = "\xff\xfe\x80\"\\\n\r\t\x00\x01ok" },
                .{ .slice = "\xc0\xaf\xf5" },
                .{ .int = 0 },
            }),
            // Regression seed: +Inf float.
            corpus.seed(&.{
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = 1 },
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = inf_bits },
                .{ .slice = "valid utf-8: ✓ 日本語" },
                .{ .slice = "" },
                .{ .int = 2 },
            }),
        },
    });
}
