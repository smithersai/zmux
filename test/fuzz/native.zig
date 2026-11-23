const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const native = zmux.native;

fn referenceKeySequence(key: []const u8) ?[]const u8 {
    if (key.len == 3 and (key[0] == 'C' or key[0] == 'c') and key[1] == '-' and std.ascii.isAlphabetic(key[2])) {
        const Static = struct {
            const tbl = blk: {
                var t: [26][1]u8 = undefined;
                for (0..26) |i| t[i] = .{@intCast(i + 1)};
                break :blk t;
            };
        };
        return &Static.tbl[std.ascii.toUpper(key[2]) - 'A'];
    }
    const entries = [_]struct { name: []const u8, seq: []const u8 }{
        .{ .name = "enter", .seq = "\r" },
        .{ .name = "return", .seq = "\r" },
        .{ .name = "tab", .seq = "\t" },
        .{ .name = "backspace", .seq = "\x7f" },
        .{ .name = "escape", .seq = "\x1b" },
        .{ .name = "esc", .seq = "\x1b" },
        .{ .name = "space", .seq = " " },
        .{ .name = "arrowup", .seq = "\x1b[A" },
        .{ .name = "up", .seq = "\x1b[A" },
        .{ .name = "arrowdown", .seq = "\x1b[B" },
        .{ .name = "down", .seq = "\x1b[B" },
        .{ .name = "arrowright", .seq = "\x1b[C" },
        .{ .name = "right", .seq = "\x1b[C" },
        .{ .name = "arrowleft", .seq = "\x1b[D" },
        .{ .name = "left", .seq = "\x1b[D" },
        .{ .name = "home", .seq = "\x1b[H" },
        .{ .name = "end", .seq = "\x1b[F" },
        .{ .name = "pageup", .seq = "\x1b[5~" },
        .{ .name = "pagedown", .seq = "\x1b[6~" },
        .{ .name = "insert", .seq = "\x1b[2~" },
        .{ .name = "delete", .seq = "\x1b[3~" },
        .{ .name = "f1", .seq = "\x1bOP" },
        .{ .name = "f2", .seq = "\x1bOQ" },
        .{ .name = "f3", .seq = "\x1bOR" },
        .{ .name = "f4", .seq = "\x1bOS" },
        .{ .name = "f5", .seq = "\x1b[15~" },
        .{ .name = "f6", .seq = "\x1b[17~" },
        .{ .name = "f7", .seq = "\x1b[18~" },
        .{ .name = "f8", .seq = "\x1b[19~" },
        .{ .name = "f9", .seq = "\x1b[20~" },
        .{ .name = "f10", .seq = "\x1b[21~" },
        .{ .name = "f11", .seq = "\x1b[23~" },
        .{ .name = "f12", .seq = "\x1b[24~" },
    };
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(key, entry.name)) return entry.seq;
    }
    return null;
}

fn fuzzKeySequence(_: void, smith: *std.testing.Smith) !void {
    var buf: [64]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);

    const actual = native.keySequence(raw);
    const expected = referenceKeySequence(raw);

    if (expected) |want| {
        const got = actual orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, want, got);
        try std.testing.expect(got.len > 0);
    } else {
        try std.testing.expect(actual == null);
    }

    // Also test case-insensitivity invariant on ASCII-flipped copy.
    var flipped: [64]u8 = undefined;
    for (raw, 0..) |b, i| {
        flipped[i] = if (std.ascii.isUpper(b))
            std.ascii.toLower(b)
        else if (std.ascii.isLower(b))
            std.ascii.toUpper(b)
        else
            b;
    }
    const flipped_actual = native.keySequence(flipped[0..raw.len]);
    if (actual) |a| {
        try std.testing.expectEqualSlices(u8, a, flipped_actual.?);
    } else {
        try std.testing.expect(flipped_actual == null);
    }
}

fn fuzzStateAndExitStatus(_: void, smith: *std.testing.Smith) !void {
    const from = smith.value(native.NativeSessionState);
    const to = smith.value(native.NativeSessionState);
    const allowed = from.canTransition(to);
    const expected = switch (from) {
        .creating => to == .running or to == .terminated,
        .running => to == .terminated,
        .terminated => false,
    };
    try std.testing.expectEqual(expected, allowed);
    try std.testing.expect(from.label().len > 0);

    const status = smith.value(u32);
    const decoded = native.decodedExitStatus(status);
    if (std.posix.W.IFEXITED(status)) {
        try std.testing.expectEqual(std.posix.W.EXITSTATUS(status), decoded);
    } else if (std.posix.W.IFSIGNALED(status)) {
        try std.testing.expectEqual(@as(u32, @backingInt(std.posix.W.TERMSIG(status))), decoded);
    } else {
        try std.testing.expectEqual(status, decoded);
    }
}

test "fuzz: native.keySequence differential oracle and case-insensitivity" {
    try std.testing.fuzz({}, fuzzKeySequence, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("Enter"),
            corpus.sliceSeed("C-a"),
            corpus.sliceSeed("c-Z"),
            corpus.sliceSeed("C-["),
            corpus.sliceSeed("F1"),
            corpus.sliceSeed("F12"),
            corpus.sliceSeed("F13"),
            corpus.sliceSeed("ArrowUp"),
            corpus.sliceSeed("PageDown"),
        },
    });
}

test "fuzz: NativeSessionState transitions and decodedExitStatus" {
    try std.testing.fuzz({}, fuzzStateAndExitStatus, .{});
}
