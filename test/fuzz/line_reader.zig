const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const LineReader = zmux.internal.rpc_line_reader.LineReader;
const sys = zmux.sys;

fn fuzzLineReaderStreaming(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    // Build an arbitrary byte stream by generating a sequence of small chunks
    // (including embedded newlines, NULs, binary bytes, and multi-buffer spans
    // exceeding LineReader's 4096-byte internal buffer).
    var full_stream: std.ArrayList(u8) = .empty;
    defer full_stream.deinit(allocator);

    const stream_mode = smith.valueRangeAtMost(u8, 0, 3);
    if (stream_mode == 3) {
        // Deliberately cross the 4096-byte internal buffer boundary!
        const prefix_len = smith.valueRangeAtMost(u16, 4090, 5000);
        const fill_byte = smith.value(u8);
        const safe_byte: u8 = if (fill_byte == '\n') 'x' else fill_byte;
        try full_stream.appendNTimes(allocator, safe_byte, prefix_len);
        if (smith.value(bool)) try full_stream.append(allocator, '\n');
        var tail_buf: [128]u8 = undefined;
        const tail = corpus.drawBytes(smith, &tail_buf);
        try full_stream.appendSlice(allocator, tail);
    } else {
        const weights: []const std.testing.Smith.Weight = &.{
            .value(u8, '\n', 5),
            .value(u8, '\r', 2),
            .value(u8, 0x00, 1),
            .rangeAtMost(u8, 0x20, 0x7e, 2),
            .rangeAtMost(u8, 0x80, 0xff, 1),
        };
        var buf: [512]u8 = undefined;
        const len = smith.sliceWeightedBytes(&buf, weights);
        try full_stream.appendSlice(allocator, buf[0..len]);
    }

    const max_len: usize = switch (smith.valueRangeAtMost(u8, 0, 4)) {
        0 => 0,
        1 => 1,
        2 => smith.valueRangeAtMost(u16, 2, 64),
        3 => smith.valueRangeAtMost(u16, 65, 6000),
        else => 16384,
    };
    const strict_mode = smith.value(bool);
    const use_timeout_api = smith.value(bool);
    const drain_buffered_first = smith.value(bool);

    // Pipe the stream and close write end so reads never block forever.
    // Keep stream <= 16 KiB so pipe write never blocks on macOS/Linux pipe capacity (16-64 KiB).
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    try sys.writeAll(fds[1], full_stream.items);
    sys.close(fds[1]);

    var reader: LineReader = .{};
    defer reader.deinit();
    var cursor: usize = 0;

    while (true) {
        // Compute expected next segment from `full_stream.items[cursor..]`.
        const remaining = full_stream.items[cursor..];
        const nl_opt = std.mem.indexOfScalar(u8, remaining, '\n');

        const got_result: anyerror!?[]u8 = blk: {
            if (drain_buffered_first) {
                if (reader.nextBufferedLineAlloc(allocator, max_len)) |maybe_buf| {
                    if (maybe_buf) |line| break :blk line;
                } else |err| {
                    break :blk err;
                }
            }
            if (strict_mode) {
                const line_res = if (use_timeout_api)
                    reader.readLineAllocTimeout(allocator, std.testing.io, fds[0], max_len, .{
                        .duration = .{ .raw = .fromSeconds(2), .clock = .awake },
                    })
                else
                    reader.readLineAlloc(allocator, fds[0], max_len);
                break :blk if (line_res) |l| @as(?[]u8, l) else |e| e;
            } else {
                break :blk if (use_timeout_api)
                    reader.readLineAllocMaybeTimeout(allocator, std.testing.io, fds[0], max_len, .{
                        .duration = .{ .raw = .fromSeconds(2), .clock = .awake },
                    })
                else
                    reader.readLineAllocMaybe(allocator, fds[0], max_len);
            }
        };

        if (remaining.len == 0) {
            if (strict_mode) {
                try std.testing.expectError(error.ConnectionClosed, got_result);
            } else {
                const maybe = try got_result;
                try std.testing.expect(maybe == null);
            }
            break;
        }

        if (nl_opt) |nl_idx| {
            const expected_line = remaining[0 .. nl_idx + 1];
            if (expected_line.len > max_len) {
                try std.testing.expectError(error.MessageTooLarge, got_result);
                break;
            }
            const actual = (try got_result).?;
            defer allocator.free(actual);
            try std.testing.expectEqualSlices(u8, expected_line, actual);
            try std.testing.expect(actual.len <= max_len);
            cursor += expected_line.len;
        } else {
            // Unterminated final segment at EOF.
            if (remaining.len > max_len) {
                try std.testing.expectError(error.MessageTooLarge, got_result);
                break;
            }
            if (strict_mode) {
                try std.testing.expectError(error.ConnectionClosed, got_result);
            } else {
                const actual = (try got_result).?;
                defer allocator.free(actual);
                try std.testing.expectEqualSlices(u8, remaining, actual);
                cursor += remaining.len;
            }
            break;
        }
    }
}

fn fuzzLineReaderBufferedAndOom(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var data_buf: [512]u8 = undefined;
    const data = corpus.drawBytes(smith, &data_buf);
    const max_len = smith.valueRangeAtMost(u16, 0, 600);
    const fail_idx = smith.valueRangeAtMost(u8, 0, 4);

    var reader: LineReader = .{};
    @memcpy(reader.buffer[0..data.len], data);
    reader.start = 0;
    reader.end = data.len;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();

    // An oversized frame is MessageTooLarge, after which the reader
    // resynchronizes on the next frame, so keep extracting. A trailing
    // partial line moves into `pending` (owned by the reader until deinit).
    var rounds: usize = 0;
    while (rounds <= data.len + 1) : (rounds += 1) {
        const res = reader.nextBufferedLineAlloc(fa, max_len) catch |err| {
            if (err == error.MessageTooLarge) continue;
            try std.testing.expectEqual(error.OutOfMemory, err);
            break;
        };
        const line = res orelse break;
        defer fa.free(line);
        try std.testing.expect(line.len >= 1);
        try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
        try std.testing.expect(line.len <= max_len);
        try std.testing.expect(std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') == null);
    }
    try std.testing.expect(rounds <= data.len + 1);

    try std.testing.expect(reader.start <= reader.end);
    try std.testing.expect(reader.end <= reader.buffer.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, reader.pending.items, '\n') == null);
    try std.testing.expect(reader.pending.items.len <= max_len);
    reader.deinit();
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "fuzz: LineReader streaming differential oracle across buffer and max_len boundaries" {
    try std.testing.fuzz({}, fuzzLineReaderStreaming, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .int = 0 },
                .{ .slice = "one\ntwo\nthree" },
                .{ .int = 2 },
                .{ .int = 64 },
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = 1 },
            }),
            corpus.seed(&.{
                .{ .int = 3 },
                .{ .int = 4096 },
                .{ .int = 'a' },
                .{ .int = 1 },
                .{ .slice = "after\n" },
                .{ .int = 3 },
                .{ .int = 4100 },
                .{ .int = 1 },
                .{ .int = 0 },
                .{ .int = 0 },
            }),
        },
    });
}

test "fuzz: LineReader buffered extraction and OOM safety" {
    try std.testing.fuzz({}, fuzzLineReaderBufferedAndOom, .{});
}
