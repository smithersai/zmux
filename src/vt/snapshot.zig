//! Terminal snapshot renderers: trimmed plain text (`renderPlainText`),
//! self-contained ANSI/DEC restore sequences (`renderAnsiRestore`), and
//! structured JSON screen dumps (`writeScreenJson`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const style_mod = @import("style.zig");
const grid_mod = @import("grid.zig");
const terminal_mod = @import("terminal.zig");

const Cell = style_mod.Cell;
const Color = style_mod.Color;
const Style = style_mod.Style;
const Grid = grid_mod.Grid;
const Terminal = terminal_mod.Terminal;

/// Default maximum scrollback lines embedded by `renderAnsiRestore`.
pub const default_restore_scrollback: usize = 64;

/// Controls what `renderPlainText` and `writeScreenJson` include in output.
pub const ScreenOptions = struct {
    /// Number of scrollback lines preceding the viewport to include (`0` = viewport only).
    include_scrollback: usize = 0,
    /// When true, `writeScreenJson` includes per-cell codepoint/width/style data.
    include_cells: bool = false,
    /// When true, `renderPlainText` omits trailing empty rows at the bottom of the screen.
    trim_trailing_blank_lines: bool = true,
};

/// Render the terminal's visible viewport (plus up to `opts.include_scrollback`
/// scrollback lines) as clean UTF-8 plain text with zero ANSI escape sequences.
pub fn renderPlainText(term: *const Terminal, allocator: Allocator, opts: ScreenOptions) ![]u8 {
    const g = term.activeGrid();
    const sb_take = @min(opts.include_scrollback, g.scrollbackCount());
    const total = sb_take + g.rows;
    assert(total >= 1);

    var end_line = total;
    if (opts.trim_trailing_blank_lines) {
        while (end_line > 0 and trimmedTextLen(lineAt(g, sb_take, end_line - 1)) == 0) {
            end_line -= 1;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..end_line) |idx| {
        if (idx > 0) try out.append(allocator, '\n');
        try appendPlainRow(&out, allocator, lineAt(g, sb_take, idx));
    }
    const owned = try out.toOwnedSlice(allocator);
    assert(std.unicode.utf8ValidateSlice(owned));
    return owned;
}

/// Render a self-contained ANSI/DEC restore byte stream capturing screen contents,
/// compact delta-encoded SGR styles, DEC/ANSI modes, alt screen, cursor, title, and CWD.
pub fn renderAnsiRestore(term: *const Terminal, allocator: Allocator) ![]u8 {
    return renderAnsiRestoreWithScrollback(term, allocator, default_restore_scrollback);
}

/// Like `renderAnsiRestore`, allowing the caller to specify how many scrollback
/// lines to emit before painting the primary viewport.
pub fn renderAnsiRestoreWithScrollback(
    term: *const Terminal,
    allocator: Allocator,
    max_scrollback_tail: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // Baseline reset, hide cursor and disable autowrap/origin/insert while painting.
    try w.writeAll("\x1b[0m\x1b[?25l\x1b[?6l\x1b[?7l\x1b[4l\x1b[20l");
    try writeOscRestore(term, w);
    try writePrePaintModes(term, w);

    if (term.isAltScreen()) {
        try w.writeAll("\x1b[?1049h\x1b[2J\x1b[H");
    } else {
        try w.writeAll("\x1b[2J\x1b[H");
    }

    const g = term.activeGrid();
    const sb_take = if (term.isAltScreen()) 0 else @min(max_scrollback_tail, g.scrollbackCount());
    const total = sb_take + g.rows;
    assert(total >= g.rows);

    var cur_style = Style.default;
    for (0..total) |idx| {
        if (idx > 0) {
            if (!cur_style.bg.eql(.default)) {
                try w.writeAll("\x1b[49m");
                cur_style.bg = .default;
            }
            try w.writeAll("\r\n");
        }
        try writeStyledRow(w, lineAt(g, sb_take, idx), g.cols, &cur_style);
    }

    try writePostPaintState(term, w, &cur_style);
    return out.toOwnedSlice();
}

/// Stream a valid JSON snapshot of the terminal state to `writer`.
pub fn writeScreenJson(term: *const Terminal, writer: *std.Io.Writer, opts: ScreenOptions) !void {
    const g = term.activeGrid();
    const cur = term.cursor();
    const m = term.modes;
    const sb_take = @min(opts.include_scrollback, g.scrollbackCount());
    const total = sb_take + g.rows;
    assert(cur.row < g.rows and cur.col < g.cols);

    try writer.print(
        "{{\"rows\":{d},\"cols\":{d},\"cursor\":{{\"row\":{d},\"col\":{d},\"visible\":{s}}}," ++
            "\"altScreen\":{s},\"title\":",
        .{
            g.rows,
            g.cols,
            cur.row,
            cur.col,
            boolStr(m.cursor_visible),
            boolStr(m.alt_screen),
        },
    );
    try std.json.Stringify.value(term.osc.title(), .{}, writer);
    try writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(term.osc.cwd(), .{}, writer);
    try writer.print(",\"promptState\":{f},\"lastCommandExitCode\":", .{
        std.json.fmt(@tagName(term.osc.prompt_state), .{}),
    });
    if (term.osc.last_command_exit) |code| {
        try writer.print("{d}", .{code});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"commandSeq\":{d},\"agentStatus\":{f},\"modes\":", .{
        term.osc.command_seq,
        std.json.fmt(@tagName(term.osc.agent_status), .{}),
    });
    try writeModesJson(term, writer);
    try writer.writeAll(",\"text\":");
    try writePlainTextJsonString(g, sb_take, total, opts.trim_trailing_blank_lines, writer);
    try writer.writeAll(",\"lines\":[");
    for (0..total) |idx| {
        if (idx > 0) try writer.writeByte(',');
        try writeRowJsonString(lineAt(g, sb_take, idx), writer);
    }
    try writer.writeByte(']');
    if (opts.include_cells) {
        try writer.writeAll(",\"cells\":");
        try writeCellsJson(g, sb_take, total, writer);
    }
    try writer.writeByte('}');
}

fn lineAt(g: *const Grid, sb_take: usize, idx: usize) []const Cell {
    assert(sb_take <= g.scrollbackCount());
    if (idx < sb_take) {
        const sb_start = g.scrollbackCount() - sb_take;
        return g.scrollbackLine(sb_start + idx);
    }
    const row_idx = idx - sb_take;
    assert(row_idx < g.rows);
    return g.rowSlice(@intCast(row_idx));
}

fn trimmedTextLen(row: []const Cell) usize {
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

fn trimmedStyledLen(row: []const Cell, max_cols: u16) usize {
    var end = @min(row.len, max_cols);
    while (end > 0 and row[end - 1].isDefaultBlank()) end -= 1;
    assert(end <= max_cols);
    return end;
}

fn appendPlainRow(out: *std.ArrayList(u8), allocator: Allocator, row: []const Cell) !void {
    const end = trimmedTextLen(row);
    var utf8_buf: [4]u8 = undefined;
    for (row[0..end]) |cell| {
        if (cell.isContinuation()) continue;
        const cp: u21 = if (cell.cp == 0) ' ' else cell.cp;
        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
        if (cp <= 0x10FFFF) {
            try out.appendSlice(allocator, utf8_buf[0..n]);
        } else {
            try out.append(allocator, ' ');
        }
    }
}

fn writeOscRestore(term: *const Terminal, w: *std.Io.Writer) !void {
    const title = term.osc.title();
    if (title.len > 0) {
        try w.writeAll("\x1b]2;");
        try w.writeAll(title);
        try w.writeAll("\x1b\\");
    }
    const cwd = term.osc.cwd();
    if (cwd.len > 0) {
        try w.writeAll("\x1b]7;file://");
        for (cwd) |b| {
            if (b == '%' or b == ' ' or b < 0x21 or b == 0x7F) {
                try w.print("%{X:0>2}", .{b});
            } else {
                try w.writeByte(b);
            }
        }
        try w.writeAll("\x1b\\");
    }
}

fn writePrePaintModes(term: *const Terminal, w: *std.Io.Writer) !void {
    const m = term.modes;
    try w.writeAll(if (m.cursor_keys_app) "\x1b[?1h" else "\x1b[?1l");
    try w.writeAll(if (m.focus_events) "\x1b[?1004h" else "\x1b[?1004l");
    try w.writeAll(if (m.mouse_sgr) "\x1b[?1006h" else "\x1b[?1006l");
    try w.writeAll(if (m.bracketed_paste) "\x1b[?2004h" else "\x1b[?2004l");
    try w.writeAll(if (m.sync_output) "\x1b[?2026h" else "\x1b[?2026l");
    switch (m.mouse_mode) {
        .none => try w.writeAll("\x1b[?1000l\x1b[?1002l\x1b[?1003l"),
        .x10 => try w.writeAll("\x1b[?1000h"),
        .button => try w.writeAll("\x1b[?1002h"),
        .any => try w.writeAll("\x1b[?1003h"),
    }
}

fn writePostPaintState(term: *const Terminal, w: *std.Io.Writer, cur_style: *Style) !void {
    const g = term.activeGrid();
    const m = term.modes;
    const cur = term.cursor();

    if (g.scroll_top != 0 or g.scroll_bottom != g.rows - 1) {
        try w.print("\x1b[{d};{d}r", .{ g.scroll_top + 1, g.scroll_bottom + 1 });
    }
    try writeStyleDelta(w, cur_style.*, cur.style);
    cur_style.* = cur.style;

    try w.writeAll(if (m.autowrap) "\x1b[?7h" else "\x1b[?7l");
    try w.writeAll(if (m.insert_mode) "\x1b[4h" else "\x1b[4l");
    try w.writeAll(if (m.linefeed_mode) "\x1b[20h" else "\x1b[20l");
    if (m.origin_mode) {
        try w.writeAll("\x1b[?6h");
        const rel_row = if (cur.row >= g.scroll_top) cur.row - g.scroll_top else 0;
        try w.print("\x1b[{d};{d}H", .{ rel_row + 1, cur.col + 1 });
    } else {
        try w.print("\x1b[{d};{d}H", .{ cur.row + 1, cur.col + 1 });
    }
    const kitty = m.kittyFlags();
    if (kitty != 0) try w.print("\x1b[>{d}u", .{kitty});
    try w.writeAll(if (m.cursor_visible) "\x1b[?25h" else "\x1b[?25l");
}

fn writeStyledRow(w: *std.Io.Writer, row: []const Cell, max_cols: u16, cur_style: *Style) !void {
    const end = trimmedStyledLen(row, max_cols);
    var utf8_buf: [4]u8 = undefined;
    for (row[0..end]) |cell| {
        if (cell.isContinuation()) continue;
        if (!cur_style.eql(cell.style)) {
            try writeStyleDelta(w, cur_style.*, cell.style);
            cur_style.* = cell.style;
        }
        const cp: u21 = if (cell.cp == 0) ' ' else cell.cp;
        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
        if (n > 0) {
            try w.writeAll(utf8_buf[0..n]);
        } else {
            try w.writeByte(' ');
        }
    }
}

fn writeStyleDelta(w: *std.Io.Writer, prev: Style, next: Style) !void {
    if (prev.eql(next)) return;
    if (next.eql(Style.default)) {
        try w.writeAll("\x1b[0m");
        return;
    }
    try w.writeAll("\x1b[");
    var sep = false;
    try writeAttrDelta(w, prev.attr, next.attr, &sep);
    if (!prev.fg.eql(next.fg)) try writeColorCode(w, next.fg, true, &sep);
    if (!prev.bg.eql(next.bg)) try writeColorCode(w, next.bg, false, &sep);
    try w.writeByte('m');
}

fn writeAttrDelta(w: *std.Io.Writer, prev: style_mod.Attr, next: style_mod.Attr, sep: *bool) !void {
    if (prev.eql(next)) return;
    if ((prev.bold and !next.bold) or (prev.dim and !next.dim)) {
        try writeSgrNum(w, 22, sep);
        if (next.bold) try writeSgrNum(w, 1, sep);
        if (next.dim) try writeSgrNum(w, 2, sep);
    } else {
        if (!prev.bold and next.bold) try writeSgrNum(w, 1, sep);
        if (!prev.dim and next.dim) try writeSgrNum(w, 2, sep);
    }
    if (prev.italic != next.italic) try writeSgrNum(w, if (next.italic) 3 else 23, sep);
    if (prev.underline != next.underline) try writeSgrNum(w, if (next.underline) 4 else 24, sep);
    if (prev.blink != next.blink) try writeSgrNum(w, if (next.blink) 5 else 25, sep);
    if (prev.inverse != next.inverse) try writeSgrNum(w, if (next.inverse) 7 else 27, sep);
    if (prev.hidden != next.hidden) try writeSgrNum(w, if (next.hidden) 8 else 28, sep);
    if (prev.strikethrough != next.strikethrough) try writeSgrNum(w, if (next.strikethrough) 9 else 29, sep);
}

fn writeColorCode(w: *std.Io.Writer, color: Color, is_fg: bool, sep: *bool) !void {
    switch (color) {
        .default => try writeSgrNum(w, if (is_fg) 39 else 49, sep),
        .indexed => |idx| {
            if (idx < 8) {
                try writeSgrNum(w, (if (is_fg) @as(u16, 30) else 40) + idx, sep);
            } else if (idx < 16) {
                try writeSgrNum(w, (if (is_fg) @as(u16, 90) else 100) + (idx - 8), sep);
            } else {
                try writeSgrNum(w, if (is_fg) 38 else 48, sep);
                try w.print(";5;{d}", .{idx});
            }
        },
        .rgb => |rgb| {
            try writeSgrNum(w, if (is_fg) 38 else 48, sep);
            try w.print(";2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b });
        },
    }
}

fn writeSgrNum(w: *std.Io.Writer, code: u16, sep: *bool) !void {
    if (sep.*) try w.writeByte(';');
    try w.print("{d}", .{code});
    sep.* = true;
}

fn writeModesJson(term: *const Terminal, w: *std.Io.Writer) !void {
    const m = term.modes;
    try w.print(
        "{{\"cursorKeysApp\":{s},\"originMode\":{s},\"autowrap\":{s}," ++
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

fn writePlainTextJsonString(
    g: *const Grid,
    sb_take: usize,
    total: usize,
    trim_blank: bool,
    w: *std.Io.Writer,
) !void {
    var end_line = total;
    if (trim_blank) {
        while (end_line > 0 and trimmedTextLen(lineAt(g, sb_take, end_line - 1)) == 0) {
            end_line -= 1;
        }
    }
    try w.writeByte('"');
    for (0..end_line) |idx| {
        if (idx > 0) try w.writeAll("\\n");
        try writeRowJsonBody(lineAt(g, sb_take, idx), w);
    }
    try w.writeByte('"');
}

fn writeRowJsonString(row: []const Cell, w: *std.Io.Writer) !void {
    try w.writeByte('"');
    try writeRowJsonBody(row, w);
    try w.writeByte('"');
}

fn writeRowJsonBody(row: []const Cell, w: *std.Io.Writer) !void {
    const end = trimmedTextLen(row);
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

fn writeCellsJson(g: *const Grid, sb_take: usize, total: usize, w: *std.Io.Writer) !void {
    assert(total >= g.rows);
    try w.writeByte('[');
    for (0..total) |idx| {
        if (idx > 0) try w.writeByte(',');
        const row = lineAt(g, sb_take, idx);
        try w.writeByte('[');
        for (row, 0..) |cell, c_idx| {
            if (c_idx > 0) try w.writeByte(',');
            const attr_bits: u8 = @bitCast(cell.style.attr);
            try w.print("{{\"cp\":{d},\"w\":{d},\"attr\":{d},\"fg\":", .{
                cell.cp,
                cell.width,
                attr_bits,
            });
            try writeColorJson(cell.style.fg, w);
            try w.writeAll(",\"bg\":");
            try writeColorJson(cell.style.bg, w);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    try w.writeByte(']');
}

fn writeColorJson(color: Color, w: *std.Io.Writer) !void {
    switch (color) {
        .default => try w.writeAll("null"),
        .indexed => |idx| try w.print("{d}", .{idx}),
        .rgb => |rgb| try w.print("[{d},{d},{d}]", .{ rgb.r, rgb.g, rgb.b }),
    }
}

fn boolStr(v: bool) []const u8 {
    return if (v) "true" else "false";
}

test "renderAnsiRestore roundtrips grid cells, styles, modes, cursor, title, and cwd" {
    var src = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 16 });
    defer src.deinit();

    src.feed("\x1b]2;nvim foo.zig\x1b\\");
    src.feed("\x1b]7;file://host/tmp/my%20dir\x1b\\");
    src.feed("\x1b[?2004h\x1b[?1006h\x1b[?1002h");
    src.feed("\x1b[1;38;2;255;128;0mHi\x1b[0m \x1b[48;5;24m世界\x1b[0m\r\n");
    src.feed("line2\r\nline3\r\nline4\r\nline5");
    src.feed("\x1b[2;5H\x1b[?25l");

    const restore = try renderAnsiRestore(&src, std.testing.allocator);
    defer std.testing.allocator.free(restore);

    var dst = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 16 });
    defer dst.deinit();
    dst.feed(restore);

    try std.testing.expectEqualStrings(src.osc.title(), dst.osc.title());
    try std.testing.expectEqualStrings(src.osc.cwd(), dst.osc.cwd());
    try std.testing.expectEqual(src.cursor().row, dst.cursor().row);
    try std.testing.expectEqual(src.cursor().col, dst.cursor().col);
    try std.testing.expectEqual(src.modes.cursor_visible, dst.modes.cursor_visible);
    try std.testing.expectEqual(src.modes.bracketed_paste, dst.modes.bracketed_paste);
    try std.testing.expectEqual(src.modes.mouse_mode, dst.modes.mouse_mode);
    try std.testing.expectEqual(src.activeGrid().scrollbackCount(), dst.activeGrid().scrollbackCount());

    for (0..src.rows()) |r| {
        for (0..src.cols()) |c| {
            const a = src.activeGrid().cellAt(@intCast(r), @intCast(c));
            const b = dst.activeGrid().cellAt(@intCast(r), @intCast(c));
            try std.testing.expect(a.eql(b));
        }
    }
}

test "writeScreenJson emits valid parseable JSON with metadata, lines, and optional cells" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 3, .cols = 10 });
    defer term.deinit();
    term.feed("\x1b]2;agent\x07\x1b]133;C\x07\x1b]7501;working\x07hello \"w\"");

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeScreenJson(&term, &out.writer, .{ .include_cells = true });

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 3), obj.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 10), obj.get("cols").?.integer);
    try std.testing.expectEqualStrings("agent", obj.get("title").?.string);
    try std.testing.expectEqualStrings("running", obj.get("promptState").?.string);
    try std.testing.expectEqualStrings("working", obj.get("agentStatus").?.string);
    try std.testing.expectEqualStrings("hello \"w\"", obj.get("text").?.string);
    try std.testing.expectEqual(@as(usize, 3), obj.get("lines").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), obj.get("cells").?.array.items.len);
}
