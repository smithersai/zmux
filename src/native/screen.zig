//! OpenRPC-conformant VT screen and styled cell matrix JSON serialization
//! for `NativeSession.screenJson` and `NativeSession.cellsJson`.

const std = @import("std");
const vt_mod = @import("../vt.zig");
const session = @import("session.zig");
const vt_bridge = @import("vt_bridge.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const NativeSession = session.NativeSession;

/// Options controlling `NativeSession.screenJson` serialization.
pub const ScreenJsonOptions = struct {
    /// Scrollback lines above the viewport to include (`0` = viewport only).
    include_scrollback: usize = 0,
    /// When true, include the styled per-cell matrix in OpenRPC `TerminalCell` format.
    include_cells: bool = false,
    /// When true, include a self-contained ANSI/DEC restore sequence string.
    include_ansi_restore: bool = false,
};

/// Serialize a structured JSON screen snapshot conforming to OpenRPC `ScreenSnapshot`
/// plus `paneId`, `generation`, and `semanticStatus`.
pub fn screenJson(self: *NativeSession, allocator: Allocator, opts: ScreenJsonOptions) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer out.deinit();
    const w = &out.writer;

    const term = &self.vt;
    const g = term.activeGrid();
    const cur = term.cursor();
    const m = term.modes;
    const sb_take = @min(opts.include_scrollback, g.scrollbackCount());
    const total = sb_take + g.rows;
    assert(g.rows >= 1 and g.cols >= 1);
    assert(cur.row < g.rows and cur.col < g.cols);

    try w.print(
        "{{\"paneId\":{f},\"generation\":{d},\"semanticStatus\":{f}," ++
            "\"rows\":{d},\"cols\":{d}," ++
            "\"cursor\":{{\"row\":{d},\"col\":{d},\"visible\":{s}}},\"altScreen\":{s},\"title\":",
        .{
            std.json.fmt(self.id, .{}),
            self.generation_value,
            std.json.fmt(vt_bridge.semanticStatusLocked(self).label(), .{}),
            g.rows,
            g.cols,
            cur.row,
            cur.col,
            boolStr(m.cursor_visible),
            boolStr(m.alt_screen),
        },
    );
    try writeScreenMetadata(self, w);
    try writeScreenModes(term, w);
    try writeScreenTextAndLines(g, sb_take, total, w);
    if (opts.include_cells) {
        try w.writeAll(",\"cells\":");
        try writeOpenRpcCells(g, sb_take, total, w);
    }
    if (opts.include_ansi_restore) {
        const restore = try vt_mod.renderAnsiRestore(term, allocator);
        defer allocator.free(restore);
        try w.writeAll(",\"ansiRestore\":");
        try std.json.Stringify.value(restore, .{}, w);
    }
    try w.writeByte('}');
    return out.toOwnedSlice();
}

/// Serialize the styled OpenRPC cell matrix for `include_scrollback` + visible rows.
pub fn cellsJson(self: *NativeSession, allocator: Allocator, include_scrollback: usize) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const g = self.vt.activeGrid();
    assert(g.rows >= 1 and g.cols >= 1);
    const sb_take = @min(include_scrollback, g.scrollbackCount());
    const total = sb_take + g.rows;
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 1024);
    errdefer out.deinit();
    try writeOpenRpcCells(g, sb_take, total, &out.writer);
    return out.toOwnedSlice();
}

fn writeScreenMetadata(self: *const NativeSession, w: *std.Io.Writer) !void {
    const osc = &self.vt.osc;
    try std.json.Stringify.value(osc.title(), .{}, w);
    try w.writeAll(",\"cwd\":");
    const osc_cwd = osc.cwd();
    if (osc_cwd.len > 0) {
        try std.json.Stringify.value(osc_cwd, .{}, w);
    } else if (self.cwd_value) |cwd| {
        try std.json.Stringify.value(cwd, .{}, w);
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"promptState\":{f},\"lastCommandExitCode\":", .{
        std.json.fmt(@tagName(osc.prompt_state), .{}),
    });
    if (osc.last_command_exit) |code| {
        try w.print("{d}", .{code});
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"commandSeq\":{d},\"agentStatus\":{f},\"modes\":", .{
        osc.command_seq,
        std.json.fmt(@tagName(osc.agent_status), .{}),
    });
}

fn writeScreenModes(term: *const vt_mod.Terminal, w: *std.Io.Writer) !void {
    const m = term.modes;
    try w.print(
        "{{\"decckm\":{s},\"origin\":{s},\"autowrap\":{s}," ++
            "\"cursorVisible\":{s},\"altScreen\":{s},\"mouseMode\":{f}," ++
            "\"mouseSgr\":{s},\"focusEvents\":{s},\"bracketedPaste\":{s}," ++
            "\"syncOutput\":{s},\"insertMode\":{s},\"linefeedMode\":{s}," ++
            "\"kittyKeyboardFlags\":{d}}}",
        .{
            boolStr(m.cursor_keys_app),
            boolStr(m.origin_mode),
            boolStr(m.autowrap),
            boolStr(m.cursor_visible),
            boolStr(m.alt_screen),
            std.json.fmt(@tagName(m.mouse_mode), .{}),
            boolStr(m.mouse_sgr),
            boolStr(m.focus_events),
            boolStr(m.bracketed_paste),
            boolStr(m.sync_output),
            boolStr(m.insert_mode),
            boolStr(m.linefeed_mode),
            m.kittyFlags(),
        },
    );
}

fn writeScreenTextAndLines(
    g: *const vt_mod.grid.Grid,
    sb_take: usize,
    total: usize,
    w: *std.Io.Writer,
) !void {
    assert(total >= g.rows);
    var end_line = total;
    while (end_line > 0 and trimmedRowLen(gridLineAt(g, sb_take, end_line - 1)) == 0) {
        end_line -= 1;
    }
    try w.writeAll(",\"text\":\"");
    for (0..end_line) |idx| {
        if (idx > 0) try w.writeAll("\\n");
        try writeRowJsonChars(gridLineAt(g, sb_take, idx), w);
    }
    try w.writeAll("\",\"lines\":[");
    for (0..total) |idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeRowJsonChars(gridLineAt(g, sb_take, idx), w);
        try w.writeByte('"');
    }
    try w.writeByte(']');
}

fn writeOpenRpcCells(
    g: *const vt_mod.grid.Grid,
    sb_take: usize,
    total: usize,
    w: *std.Io.Writer,
) !void {
    assert(total >= g.rows);
    try w.writeByte('[');
    for (0..total) |idx| {
        if (idx > 0) try w.writeByte(',');
        const row = gridLineAt(g, sb_take, idx);
        assert(row.len == g.cols);
        try w.writeByte('[');
        for (row, 0..) |cell, c_idx| {
            if (c_idx > 0) try w.writeByte(',');
            try writeOpenRpcCell(cell, w);
        }
        try w.writeByte(']');
    }
    try w.writeByte(']');
}

fn writeOpenRpcCell(cell: vt_mod.Cell, w: *std.Io.Writer) !void {
    var utf8_buf: [4]u8 = undefined;
    const cp: u21 = if (cell.isContinuation()) 0 else if (cell.cp == 0) ' ' else cell.cp;
    const ch: []const u8 = if (cp == 0) "" else blk: {
        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
        break :blk if (n > 0) utf8_buf[0..n] else " ";
    };
    assert(cell.width <= 2);
    try w.writeAll("{\"char\":");
    try std.json.Stringify.value(ch, .{}, w);
    try w.print(",\"width\":{d},\"fg\":", .{cell.width});
    try writeOpenRpcColor(cell.style.fg, w);
    try w.writeAll(",\"bg\":");
    try writeOpenRpcColor(cell.style.bg, w);
    const a = cell.style.attr;
    try w.print(
        ",\"bold\":{s},\"dim\":{s},\"italic\":{s},\"underline\":{s}," ++
            "\"blink\":{s},\"inverse\":{s},\"hidden\":{s},\"strikethrough\":{s}}}",
        .{
            boolStr(a.bold),
            boolStr(a.dim),
            boolStr(a.italic),
            boolStr(a.underline),
            boolStr(a.blink),
            boolStr(a.inverse),
            boolStr(a.hidden),
            boolStr(a.strikethrough),
        },
    );
}

fn writeOpenRpcColor(color: vt_mod.Color, w: *std.Io.Writer) !void {
    switch (color) {
        .default => try w.writeAll("null"),
        .indexed => |idx| try w.print("{{\"kind\":\"indexed\",\"index\":{d}}}", .{idx}),
        .rgb => |rgb| try w.print(
            "{{\"kind\":\"rgb\",\"r\":{d},\"g\":{d},\"b\":{d}}}",
            .{ rgb.r, rgb.g, rgb.b },
        ),
    }
}

fn gridLineAt(g: *const vt_mod.grid.Grid, sb_take: usize, idx: usize) []const vt_mod.Cell {
    assert(sb_take <= g.scrollbackCount());
    if (idx < sb_take) {
        return g.scrollbackLine(g.scrollbackCount() - sb_take + idx);
    }
    const row_idx = idx - sb_take;
    assert(row_idx < g.rows);
    return g.rowSlice(@intCast(row_idx));
}

fn trimmedRowLen(row: []const vt_mod.Cell) usize {
    var end = row.len;
    while (end > 0) {
        const c = row[end - 1];
        if (c.isContinuation()) break;
        if (c.cp != ' ' and c.cp != 0) break;
        end -= 1;
    }
    assert(end <= row.len);
    return end;
}

fn writeRowJsonChars(row: []const vt_mod.Cell, w: *std.Io.Writer) !void {
    const end = trimmedRowLen(row);
    var utf8_buf: [4]u8 = undefined;
    for (row[0..end]) |cell| {
        if (cell.isContinuation()) continue;
        const cp: u21 = if (cell.cp == 0) ' ' else cell.cp;
        switch (cp) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0...0x1F => try w.print("\\u{x:0>4}", .{cp}),
            else => {
                const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
                if (n > 0) try w.writeAll(utf8_buf[0..n]) else try w.writeByte(' ');
            },
        }
    }
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

test "screenJson and cellsJson emit OpenRPC ScreenSnapshot fields, styles, and resize" {
    const harness = @import("harness.zig");
    if (!harness.supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: harness.Recorder = .{};
    defer rec.deinit();
    const native = try NativeSession.create(allocator, std.testing.io, .{
        .id = "screen-test",
        .shell = "/bin/sh",
        .command = "printf '\\033[1;38;2;10;20;30mRGB\\033[0m\\n'; sleep 30",
        .rows = 6,
        .cols = 24,
        .event_sink = rec.sink(),
    });
    defer native.destroy();

    try rec.waitForOutput("RGB", 5_000);
    const json = try native.screenJson(allocator, .{ .include_cells = true, .include_ansi_restore = true });
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("screen-test", obj.get("paneId").?.string);
    try std.testing.expectEqual(@as(i64, 6), obj.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 24), obj.get("cols").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, obj.get("text").?.string, "RGB") != null);
    try std.testing.expect(obj.get("modes").?.object.get("decckm").? == .bool);
    try std.testing.expect(obj.get("modes").?.object.get("origin").? == .bool);
    try std.testing.expect(obj.get("ansiRestore").?.string.len > 0);
    const cell0 = obj.get("cells").?.array.items[0].array.items[0].object;
    try std.testing.expectEqualStrings("R", cell0.get("char").?.string);
    try std.testing.expect(cell0.get("bold").?.bool);
    try std.testing.expectEqualStrings("rgb", cell0.get("fg").?.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 10), cell0.get("fg").?.object.get("r").?.integer);

    try native.resize(50, 12);
    const resized = try native.screenJson(allocator, .{});
    defer allocator.free(resized);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, allocator, resized, .{});
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(i64, 12), parsed2.value.object.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 50), parsed2.value.object.get("cols").?.integer);

    const cells_only = try native.cellsJson(allocator, 0);
    defer allocator.free(cells_only);
    try std.testing.expect(std.mem.indexOf(u8, cells_only, "\"char\":\"R\"") != null);
}
