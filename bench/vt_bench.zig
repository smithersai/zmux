const std = @import("std");
const bench = @import("bench");
const vt = @import("vt");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "vt", argv);
    defer runner.deinit();

    // 1. Plain ASCII 64 KiB feed throughput (80-column lines with CRLF).
    const plain_64k = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(plain_64k);
    fillPlainAscii(plain_64k, 80);

    {
        var term = try vt.Terminal.init(allocator, .{ .rows = 24, .cols = 80 });
        defer term.deinit();
        // Warm scrollback ring to steady-state buffer reuse.
        for (0..4) |_| term.feed(plain_64k);

        const FeedCtx = struct { term: *vt.Terminal, bytes: []const u8 };
        try runner.run(
            "feed_plain_ascii_64KiB",
            .{ .bytes_per_op = plain_64k.len },
            FeedCtx{ .term = &term, .bytes = plain_64k },
            struct {
                fn f(ctx: FeedCtx) void {
                    ctx.term.feed(ctx.bytes);
                    bench.doNotOptimize(ctx.term.cursor().row);
                }
            }.f,
        );
    }

    // 2. SGR-heavy colored output 64 KiB (256-color + truecolor + attributes).
    const sgr_64k = try buildSgrHeavy(allocator, 64 * 1024);
    defer allocator.free(sgr_64k);

    {
        var term = try vt.Terminal.init(allocator, .{ .rows = 24, .cols = 80 });
        defer term.deinit();
        for (0..4) |_| term.feed(sgr_64k);

        const FeedCtx = struct { term: *vt.Terminal, bytes: []const u8 };
        try runner.run(
            "feed_sgr_heavy_64KiB",
            .{ .bytes_per_op = sgr_64k.len },
            FeedCtx{ .term = &term, .bytes = sgr_64k },
            struct {
                fn f(ctx: FeedCtx) void {
                    ctx.term.feed(ctx.bytes);
                    bench.doNotOptimize(ctx.term.cursor().col);
                }
            }.f,
        );
    }

    // 3. TUI cursor-addressed full-frame redraw loop (nvim/htop/btop pattern).
    const tui_frame = try buildTuiRedrawFrame(allocator, 24, 80);
    defer allocator.free(tui_frame);

    {
        var term = try vt.Terminal.init(allocator, .{ .rows = 24, .cols = 80 });
        defer term.deinit();
        term.feed("\x1b[?1049h\x1b[?25l");

        const FrameCtx = struct { term: *vt.Terminal, frame: []const u8 };
        try runner.run(
            "tui_cursor_redraw_24x80",
            .{ .bytes_per_op = tui_frame.len },
            FrameCtx{ .term = &term, .frame = tui_frame },
            struct {
                fn f(ctx: FrameCtx) void {
                    ctx.term.feed(ctx.frame);
                    bench.doNotOptimize(ctx.term.cursor().row);
                }
            }.f,
        );
    }

    // 4-6. Snapshot renderers on a densely populated styled 24x80 terminal with scrollback.
    {
        var term = try vt.Terminal.init(allocator, .{ .rows = 24, .cols = 80 });
        defer term.deinit();
        term.feed("\x1b]2;htop - zmux\x1b\\\x1b]7;file://host/Users/dev/zmux\x1b\\");
        term.feed(sgr_64k);
        term.feed(tui_frame);

        const PlainCtx = struct { term: *const vt.Terminal, allocator: std.mem.Allocator, sb: usize };
        try runner.run(
            "render_plain_text_24x80",
            .{ .bytes_per_op = 24 * 80 },
            PlainCtx{ .term = &term, .allocator = allocator, .sb = 0 },
            struct {
                fn f(ctx: PlainCtx) !void {
                    const out = try ctx.term.plainText(ctx.allocator, .{ .include_scrollback = ctx.sb });
                    bench.doNotOptimize(out.ptr);
                    ctx.allocator.free(out);
                }
            }.f,
        );

        try runner.run(
            "render_plain_text_200sb",
            .{ .bytes_per_op = 224 * 80 },
            PlainCtx{ .term = &term, .allocator = allocator, .sb = 200 },
            struct {
                fn f(ctx: PlainCtx) !void {
                    const out = try ctx.term.plainText(ctx.allocator, .{ .include_scrollback = ctx.sb });
                    bench.doNotOptimize(out.ptr);
                    ctx.allocator.free(out);
                }
            }.f,
        );

        const RestoreCtx = struct { term: *const vt.Terminal, allocator: std.mem.Allocator };
        try runner.run(
            "render_ansi_restore_24x80",
            .{ .bytes_per_op = 24 * 80 },
            RestoreCtx{ .term = &term, .allocator = allocator },
            struct {
                fn f(ctx: RestoreCtx) !void {
                    const out = try ctx.term.ansiRestore(ctx.allocator);
                    bench.doNotOptimize(out.ptr);
                    ctx.allocator.free(out);
                }
            }.f,
        );

        const JsonCtx = struct { term: *const vt.Terminal, allocator: std.mem.Allocator, cells: bool };
        try runner.run(
            "write_screen_json_24x80",
            .{ .bytes_per_op = 24 * 80 },
            JsonCtx{ .term = &term, .allocator = allocator, .cells = false },
            struct {
                fn f(ctx: JsonCtx) !void {
                    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
                    defer out.deinit();
                    try ctx.term.writeScreenJson(&out.writer, .{ .include_cells = ctx.cells });
                    bench.doNotOptimize(out.written().ptr);
                }
            }.f,
        );
    }

    try runner.finish();
}

fn fillPlainAscii(buf: []u8, line_len: usize) void {
    var col: usize = 0;
    for (buf, 0..) |*byte, i| {
        if (col + 2 == line_len) {
            byte.* = '\r';
            col += 1;
        } else if (col + 1 >= line_len) {
            byte.* = '\n';
            col = 0;
        } else {
            byte.* = 'a' + @as(u8, @intCast(i % 26));
            col += 1;
        }
    }
}

fn buildSgrHeavy(allocator: std.mem.Allocator, target_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const patterns = [_][]const u8{
        "\x1b[1;38;2;255;120;40mERROR\x1b[0m ",
        "\x1b[3;38;5;114;48;5;235msrc/vt/parser.zig:42\x1b[0m ",
        "\x1b[32mPASS\x1b[0m ",
        "\x1b[38;2;80;180;250m[worker-01]\x1b[0m ok\r\n",
    };
    var idx: usize = 0;
    while (out.items.len < target_bytes) : (idx += 1) {
        const p = patterns[idx % patterns.len];
        const rem = target_bytes - out.items.len;
        try out.appendSlice(allocator, p[0..@min(p.len, rem)]);
    }
    return out.toOwnedSlice(allocator);
}

fn buildTuiRedrawFrame(allocator: std.mem.Allocator, rows: u16, cols: u16) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x1b[?2026h\x1b[H");
    for (0..rows) |r| {
        const fg: u8 = @intCast(30 + (r % 8));
        try w.print("\x1b[{d};1H\x1b[1;{d};48;5;236m", .{ r + 1, fg });
        for (0..cols) |c| {
            const ch: u8 = if (c < 12) 'A' + @as(u8, @intCast((r + c) % 26)) else if (c % 5 == 0) '|' else '.';
            try w.writeByte(ch);
        }
        try w.writeAll("\x1b[0m");
    }
    try w.writeAll("\x1b[24;1H\x1b[?2026l");
    return out.toOwnedSlice();
}
