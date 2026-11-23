//! Shared helpers for constructing Zig 0.17 `std.testing.Smith` corpus seeds
//! and verifying wire/JSON invariants across all zmux fuzz suites.

const std = @import("std");

pub const Value = union(enum) {
    eos: bool,
    int: u64,
    bytes: []const u8,
    slice: []const u8,
};

/// Encode a sequence of `Smith` draws into the exact binary wire format read
/// by both non-fuzz smoke execution (`Smith.in`) and coverage-guided fuzzing
/// (`fuzzer_new_input`).
pub fn seed(comptime values: []const Value) []const u8 {
    const result = comptime blk: {
        var total_len: usize = 0;
        for (values) |v| total_len += switch (v) {
            .eos => 1,
            .int => 8,
            .bytes => |b| b.len,
            .slice => |s| 4 + s.len,
        };
        var buf: [total_len]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (values) |v| switch (v) {
            .eos => |e| w.writeByte(@intFromBool(e)) catch unreachable,
            .int => |i| w.writeInt(u64, i, .little) catch unreachable,
            .bytes => |b| w.writeAll(b) catch unreachable,
            .slice => |s| {
                w.writeInt(u32, @intCast(s.len), .little) catch unreachable;
                w.writeAll(s) catch unreachable;
            },
        };
        break :blk buf;
    };
    return &result;
}

/// Convenience helper for fuzzers whose first draw is a single `smith.slice`.
pub fn sliceSeed(comptime bytes: []const u8) []const u8 {
    return seed(&.{.{ .slice = bytes }});
}

/// Draw a printable ASCII string (safe for JSON/shell/identifiers) into `buf`.
pub fn drawAsciiSlice(smith: *std.testing.Smith, buf: []u8) []const u8 {
    const byte_weights: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, 0x20, 0x7e, 1),
    };
    const len = smith.sliceWeightedBytes(buf, byte_weights);
    return buf[0..len];
}

/// Draw arbitrary bytes (full 0x00..0xff range) into `buf`.
pub fn drawBytes(smith: *std.testing.Smith, buf: []u8) []const u8 {
    const len = smith.slice(buf);
    return buf[0..len];
}

/// Assert that `frame` is a single physical JSON line:
///   * ends with '\n'
///   * contains no earlier '\n'
///   * parses cleanly as a JSON object via `std.json.parseFromSlice`
pub fn parseSingleLineJsonObject(allocator: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    try std.testing.expect(frame.len >= 3);
    try std.testing.expectEqual(@as(u8, '\n'), frame[frame.len - 1]);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, frame[0 .. frame.len - 1], '\n'));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame[0 .. frame.len - 1], .{});
    errdefer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    return parsed;
}
