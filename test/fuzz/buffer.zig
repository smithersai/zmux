const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const ScrollbackBuffer = zmux.buffer.ScrollbackBuffer;
const max_capacity = zmux.buffer.max_capacity;

fn referenceCaptureLastLines(allocator: std.mem.Allocator, data: []const u8, max_lines: usize) ![]u8 {
    if (max_lines == 0 or data.len == 0) return allocator.dupe(u8, "");

    var end = data.len;
    if (end > 0 and data[end - 1] == '\n') end -= 1;

    var newlines: usize = 0;
    var cut: usize = 0;
    var idx: usize = end;
    while (idx > 0) {
        idx -= 1;
        if (data[idx] == '\n') {
            newlines += 1;
            if (newlines == max_lines) {
                cut = idx + 1;
                break;
            }
        }
    }
    return allocator.dupe(u8, data[cut..]);
}

fn fuzzScrollbackModel(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    // Exercise capacity edge cases including 0 (clamped to 1), 1, small primes,
    // powers of two, and multi-KB buffers.
    const cap_mode = smith.valueRangeAtMost(u8, 0, 5);
    const requested_cap: usize = switch (cap_mode) {
        0 => 0,
        1 => 1,
        2 => smith.valueRangeAtMost(u16, 2, 16),
        3 => smith.valueRangeAtMost(u16, 17, 128),
        4 => smith.valueRangeAtMost(u16, 129, 2048),
        else => 4096,
    };

    var ring = try ScrollbackBuffer.init(allocator, requested_cap);
    defer ring.deinit();

    const expected_cap = @min(@max(requested_cap, 1), max_capacity);
    try std.testing.expectEqual(expected_cap, ring.capacity());
    try std.testing.expectEqual(@as(usize, 0), ring.len);
    try std.testing.expectEqual(@as(usize, 0), ring.start);

    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(allocator);

    const Op = enum(u8) {
        append_raw,
        append_lines,
        snapshot,
        capture_lines,
        oom_snapshot_or_capture,
    };

    var chunk_buf: [512]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 128) : (steps += 1) {
        switch (smith.value(Op)) {
            .append_raw => {
                const chunk = corpus.drawBytes(smith, &chunk_buf);
                ring.append(chunk);
                try reference.appendSlice(allocator, chunk);
            },
            .append_lines => {
                // Bias toward newlines, carriage returns, NULs, and BEL to stress
                // line boundary calculations heavily.
                const weights: []const std.testing.Smith.Weight = &.{
                    .value(u8, '\n', 4),
                    .value(u8, '\r', 1),
                    .value(u8, 0x00, 1),
                    .value(u8, 0x07, 1),
                    .rangeAtMost(u8, 'a', 'z', 2),
                };
                const len = smith.sliceWeightedBytes(&chunk_buf, weights);
                const chunk = chunk_buf[0..len];
                ring.append(chunk);
                try reference.appendSlice(allocator, chunk);
            },
            .snapshot => {
                const snap = try ring.snapshot(allocator);
                defer allocator.free(snap);

                const expected = if (reference.items.len > expected_cap)
                    reference.items[reference.items.len - expected_cap ..]
                else
                    reference.items;
                try std.testing.expectEqualSlices(u8, expected, snap);
            },
            .capture_lines => {
                const line_mode = smith.valueRangeAtMost(u8, 0, 3);
                const max_lines: usize = switch (line_mode) {
                    0 => 0,
                    1 => 1,
                    2 => smith.valueRangeAtMost(u16, 2, 64),
                    else => std.math.maxInt(usize),
                };

                const actual = try ring.captureLastLines(allocator, max_lines);
                defer allocator.free(actual);

                const expected_tail = if (reference.items.len > expected_cap)
                    reference.items[reference.items.len - expected_cap ..]
                else
                    reference.items;
                const expected = try referenceCaptureLastLines(allocator, expected_tail, max_lines);
                defer allocator.free(expected);

                try std.testing.expectEqualSlices(u8, expected, actual);
                // Captured lines are always a suffix of the snapshot.
                try std.testing.expect(std.mem.endsWith(u8, expected_tail, actual));
            },
            .oom_snapshot_or_capture => {
                const fail_idx = smith.valueRangeAtMost(u8, 0, 3);
                var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
                const fa = failing.allocator();
                if (smith.value(bool)) {
                    if (ring.snapshot(fa)) |s| fa.free(s) else |err| {
                        try std.testing.expectEqual(error.OutOfMemory, err);
                    }
                } else {
                    const max_lines = smith.valueRangeAtMost(u8, 0, 16);
                    if (ring.captureLastLines(fa, max_lines)) |c| fa.free(c) else |err| {
                        try std.testing.expectEqual(error.OutOfMemory, err);
                    }
                }
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            },
        }

        // Core structural invariants hold after every single operation.
        try std.testing.expect(ring.len <= ring.capacity());
        try std.testing.expect(ring.start < ring.capacity());
        const expected_len = @min(reference.items.len, expected_cap);
        try std.testing.expectEqual(expected_len, ring.len);
    }

    // Final full comparison at end of trace.
    const final_snap = try ring.snapshot(allocator);
    defer allocator.free(final_snap);
    const expected_final = if (reference.items.len > expected_cap)
        reference.items[reference.items.len - expected_cap ..]
    else
        reference.items;
    try std.testing.expectEqualSlices(u8, expected_final, final_snap);
}

test "fuzz: ScrollbackBuffer differential state machine and OOM safety" {
    try std.testing.fuzz({}, fuzzScrollbackModel, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .int = 2 }, // small cap mode
                .{ .int = 8 }, // cap = 8
                .{ .eos = false },
                .{ .int = 0 }, // append_raw
                .{ .slice = "hello" },
                .{ .eos = false },
                .{ .int = 0 }, // append_raw
                .{ .slice = " world\nnext\n" },
                .{ .eos = false },
                .{ .int = 2 }, // snapshot
                .{ .eos = false },
                .{ .int = 3 }, // capture_lines
                .{ .int = 1 }, // 1 line
                .{ .eos = true },
            }),
            corpus.seed(&.{
                .{ .int = 0 }, // cap = 0 -> clamped to 1
                .{ .eos = false },
                .{ .int = 0 },
                .{ .slice = "abcdef" },
                .{ .eos = false },
                .{ .int = 3 },
                .{ .int = 3 },
                .{ .eos = true },
            }),
        },
    });
}
