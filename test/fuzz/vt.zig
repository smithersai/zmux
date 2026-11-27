const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const vt = zmux.vt;

fn checkTerminalInvariants(term: *const vt.Terminal) !void {
    try std.testing.expect(term.rows() >= 1 and term.cols() >= 1);
    try std.testing.expectEqual(term.primary.rows, term.alt.rows);
    try std.testing.expectEqual(term.primary.cols, term.alt.cols);
    try std.testing.expectEqual(@as(usize, term.cols()), term.tab_stops.len);

    const cur = term.cursor();
    try std.testing.expect(cur.row < term.rows());
    try std.testing.expect(cur.col < term.cols());

    try std.testing.expect(term.osc.title().len <= vt.osc.max_title_bytes);
    try std.testing.expect(term.osc.cwd().len <= vt.osc.max_cwd_bytes);
    try std.testing.expect(term.osc.clipboardData().len <= vt.osc.max_clipboard_bytes);
    try std.testing.expect(term.osc.notification().len <= vt.osc.max_notification_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(term.osc.title()));
    try std.testing.expect(std.unicode.utf8ValidateSlice(term.osc.cwd()));
    try std.testing.expect(std.unicode.utf8ValidateSlice(term.osc.notification()));
}

fn checkJsonAndPlainText(allocator: std.mem.Allocator, term: *const vt.Terminal, include_cells: bool) !void {
    const plain = try term.plainText(allocator, .{ .include_scrollback = 8 });
    defer allocator.free(plain);
    try std.testing.expect(std.unicode.utf8ValidateSlice(plain));
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, plain, 0x1B));

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try term.writeScreenJson(&out.writer, .{
        .include_scrollback = 4,
        .include_cells = include_cells,
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(i64, term.rows()), parsed.value.object.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, term.cols()), parsed.value.object.get("cols").?.integer);
}

fn fuzzChunkEquivalence(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const rows = smith.valueRangeAtMost(u16, 1, 20);
    const cols = smith.valueRangeAtMost(u16, 1, 40);
    const sb = smith.valueRangeAtMost(u16, 0, 12);

    var buf: [512]u8 = undefined;
    const stream = corpus.drawBytes(smith, &buf);

    var whole = try vt.Terminal.init(allocator, .{ .rows = rows, .cols = cols, .scrollback_lines = sb });
    defer whole.deinit();
    whole.feed(stream);

    var by_one = try vt.Terminal.init(allocator, .{ .rows = rows, .cols = cols, .scrollback_lines = sb });
    defer by_one.deinit();
    for (stream) |b| by_one.feed(&.{b});

    try checkTerminalInvariants(&whole);
    try checkTerminalInvariants(&by_one);
    try std.testing.expectEqual(whole.cursor().row, by_one.cursor().row);
    try std.testing.expectEqual(whole.cursor().col, by_one.cursor().col);
    try std.testing.expectEqual(whole.isAltScreen(), by_one.isAltScreen());
    try std.testing.expectEqualStrings(whole.osc.title(), by_one.osc.title());
    try std.testing.expectEqualStrings(whole.osc.cwd(), by_one.osc.cwd());
    try std.testing.expectEqual(whole.osc.prompt_state, by_one.osc.prompt_state);
    try std.testing.expectEqual(whole.osc.agent_status, by_one.osc.agent_status);

    for (0..whole.rows()) |r| {
        for (0..whole.cols()) |c| {
            const a = whole.activeGrid().cellAt(@intCast(r), @intCast(c));
            const b = by_one.activeGrid().cellAt(@intCast(r), @intCast(c));
            try std.testing.expect(a.eql(b));
        }
    }

    try checkJsonAndPlainText(allocator, &whole, false);
}

fn drawEscapeBiased(smith: *std.testing.Smith, buf: []u8) []const u8 {
    const weights: []const std.testing.Smith.Weight = &.{
        .value(u8, 0x1B, 6),
        .value(u8, '[', 5),
        .value(u8, ']', 3),
        .value(u8, ';', 4),
        .value(u8, ':', 2),
        .value(u8, '?', 3),
        .value(u8, 0x07, 3),
        .value(u8, '\\', 2),
        .value(u8, '\r', 2),
        .value(u8, '\n', 3),
        .rangeAtMost(u8, '0', '9', 5),
        .rangeAtMost(u8, 'A', 'Z', 4),
        .rangeAtMost(u8, 'a', 'z', 4),
        .rangeAtMost(u8, 0x80, 0xFF, 2),
    };
    const len = smith.sliceWeightedBytes(buf, weights);
    return buf[0..len];
}

fn fuzzStatefulTerminalChaos(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const init_rows = smith.valueRangeAtMost(u16, 1, 16);
    const init_cols = smith.valueRangeAtMost(u16, 1, 32);
    const sb = smith.valueRangeAtMost(u16, 0, 16);

    var term = try vt.Terminal.init(allocator, .{ .rows = init_rows, .cols = init_cols, .scrollback_lines = sb });
    defer term.deinit();

    const Op = enum(u8) {
        feed_raw,
        feed_escaped,
        feed_osc,
        resize,
        toggle_alt,
        ansi_roundtrip,
        screen_json,
        reset,
        oom_ops,
    };

    var chunk_buf: [256]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 64) : (steps += 1) {
        switch (smith.value(Op)) {
            .feed_raw => term.feed(corpus.drawBytes(smith, &chunk_buf)),
            .feed_escaped => term.feed(drawEscapeBiased(smith, &chunk_buf)),
            .feed_osc => {
                const payload = corpus.drawBytes(smith, &chunk_buf);
                term.feed("\x1b]");
                term.feed(payload);
                term.feed(if (smith.value(bool)) "\x07" else "\x1b\\");
            },
            .resize => {
                const nr = smith.valueRangeAtMost(u16, 1, 24);
                const nc = smith.valueRangeAtMost(u16, 1, 48);
                try term.resize(nr, nc);
            },
            .toggle_alt => {
                const seq = switch (smith.valueRangeAtMost(u8, 0, 5)) {
                    0 => "\x1b[?47h",
                    1 => "\x1b[?47l",
                    2 => "\x1b[?1047h",
                    3 => "\x1b[?1047l",
                    4 => "\x1b[?1049h",
                    else => "\x1b[?1049l",
                };
                term.feed(seq);
            },
            .ansi_roundtrip => {
                const restore = try term.ansiRestore(allocator);
                defer allocator.free(restore);
                var cloned = try vt.Terminal.init(allocator, .{
                    .rows = term.rows(),
                    .cols = term.cols(),
                    .scrollback_lines = @max(sb, vt.snapshot.default_restore_scrollback),
                });
                defer cloned.deinit();
                cloned.feed(restore);

                try std.testing.expectEqual(term.isAltScreen(), cloned.isAltScreen());
                try std.testing.expectEqual(term.cursor().row, cloned.cursor().row);
                try std.testing.expectEqual(term.cursor().col, cloned.cursor().col);
                try std.testing.expectEqualStrings(term.osc.title(), cloned.osc.title());
                try std.testing.expectEqualStrings(term.osc.cwd(), cloned.osc.cwd());
                for (0..term.rows()) |r| {
                    for (0..term.cols()) |c| {
                        const a = term.activeGrid().cellAt(@intCast(r), @intCast(c));
                        const b = cloned.activeGrid().cellAt(@intCast(r), @intCast(c));
                        try std.testing.expect(a.eql(b));
                    }
                }
            },
            .screen_json => try checkJsonAndPlainText(allocator, &term, smith.value(bool)),
            .reset => term.reset(),
            .oom_ops => {
                const fail_idx = smith.valueRangeAtMost(u8, 0, 4);
                var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
                const fa = failing.allocator();
                switch (smith.valueRangeAtMost(u8, 0, 2)) {
                    0 => {
                        if (term.plainText(fa, .{ .include_scrollback = 8 })) |s| fa.free(s) else |err| {
                            try std.testing.expectEqual(error.OutOfMemory, err);
                        }
                    },
                    1 => {
                        if (term.ansiRestore(fa)) |s| fa.free(s) else |err| {
                            try std.testing.expectEqual(error.OutOfMemory, err);
                        }
                    },
                    else => {
                        const orig_alloc = term.allocator;
                        term.allocator = fa;
                        const nr = smith.valueRangeAtMost(u16, 1, 20);
                        const nc = smith.valueRangeAtMost(u16, 1, 40);
                        const res = term.resize(nr, nc);
                        term.allocator = orig_alloc;
                        if (res) |_| {} else |err| {
                            try std.testing.expectEqual(error.OutOfMemory, err);
                            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                        }
                    },
                }
            },
        }
        try checkTerminalInvariants(&term);
    }
    try checkJsonAndPlainText(allocator, &term, false);
}

test "fuzz: VT chunk-split equivalence (1-byte feed == whole-buffer feed)" {
    try std.testing.fuzz({}, fuzzChunkEquivalence, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .int = 6 },
                .{ .int = 20 },
                .{ .int = 4 },
                .{ .slice = "\x1b]2;nvim\x1b\\\x1b[1;38:2::10:20:30mHi 世界🚀\x1b[0m\r\n\x1b[2;4H\x1b[K" },
            }),
            corpus.seed(&.{
                .{ .int = 1 },
                .{ .int = 1 },
                .{ .int = 0 },
                .{ .slice = "中\x1b[?1049h\xff\xe2\x82\x1b[?1049l\x1b[5b" },
            }),
            corpus.seed(&.{
                .{ .int = 4 },
                .{ .int = 12 },
                .{ .int = 4 },
                .{ .slice = "\x1b]7;file://h/a%20b\x07\x1b]133;C\x07\x1b]133;D;-1\x07\x1b]7501;working\x07\x1b]52;c;QUJD\x07" },
            }),
        },
    });
}

test "fuzz: VT stateful chaos, resize, alt-screen, OSC, ANSI roundtrip, and OOM" {
    try std.testing.fuzz({}, fuzzStatefulTerminalChaos, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .int = 4 },
                .{ .int = 12 },
                .{ .int = 4 },
                .{ .eos = false },
                .{ .int = 0 }, // feed_raw
                .{ .slice = "\x1b[31;44mhello 世界\r\nline2\r\n" },
                .{ .eos = false },
                .{ .int = 2 }, // feed_osc
                .{ .slice = "2;title-test" },
                .{ .int = 1 },
                .{ .eos = false },
                .{ .int = 5 }, // ansi_roundtrip
                .{ .eos = false },
                .{ .int = 3 }, // resize
                .{ .int = 2 },
                .{ .int = 6 },
                .{ .eos = false },
                .{ .int = 4 }, // toggle_alt
                .{ .int = 4 }, // 1049h
                .{ .eos = false },
                .{ .int = 5 }, // ansi_roundtrip in alt
                .{ .eos = false },
                .{ .int = 6 }, // screen_json
                .{ .int = 1 }, // include_cells = true
                .{ .eos = false },
                .{ .int = 8 }, // oom_ops
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .eos = true },
            }),
        },
    });
}
