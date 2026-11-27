//! Zero-dependency pure-Zig VT100/xterm/ECMA-48/OSC terminal state engine.
//!
//! Provides a streaming VT500 + UTF-8 parser, 2D cell grid with bounded
//! scrollback, DEC/ANSI/Kitty mode tracking, bounded OSC metadata handling,
//! plain-text extraction, ANSI restore generation, and JSON screen snapshots.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Cell colors, attributes, `Style`, `Cell`, `wcwidth`, and SGR evaluation.
pub const style = @import("vt/style.zig");
/// DEC/ANSI/Kitty mode flags and primary/alternate cursor state.
pub const modes = @import("vt/modes.zig");
/// Bounded OSC state handler (titles, CWD, clipboard, shell integration, agent status).
pub const osc = @import("vt/osc.zig");
/// 2D terminal cell grid and bounded scrollback ring buffer.
pub const grid = @import("vt/grid.zig");
/// Bounded reusable-line scrollback ring buffer.
pub const scrollback = @import("vt/scrollback.zig");
/// Streaming Paul Williams / VT500 state machine and UTF-8 decoder.
pub const parser = @import("vt/parser.zig");
/// Complete terminal emulator combining parser, grids, modes, and OSC state.
pub const terminal = @import("vt/terminal.zig");
/// Plain-text, ANSI restore, and JSON snapshot renderers.
pub const snapshot = @import("vt/snapshot.zig");

/// Primary VT100/xterm/OSC terminal emulator state engine.
pub const Terminal = terminal.Terminal;
/// Construction options for `Terminal.init`.
pub const Options = terminal.Options;
/// Single terminal screen cell (codepoint, display width, and style).
pub const Cell = style.Cell;
/// Complete rendering style (foreground, background, attributes).
pub const Style = style.Style;
/// Foreground or background terminal color (default, 256-color, or 24-bit RGB).
pub const Color = style.Color;
/// Packed bitfield of ECMA-48 text attributes.
pub const Attr = style.Attr;
/// Active DEC/ANSI modes and bounded Kitty keyboard stack.
pub const Modes = modes.Modes;
/// Cursor coordinates, wrap flag, style, and primary/alternate saved cursors.
pub const Cursor = modes.Cursor;
/// Bounded OSC metadata store (OSC 0/2, 7, 9, 52, 133, 777, 7501).
pub const OscState = osc.OscState;
/// Shell integration prompt lifecycle state (OSC 133).
pub const PromptState = osc.PromptState;
/// Semantic agent activity status (OSC 7501 / 9;4 / 777).
pub const AgentStatus = osc.AgentStatus;
/// Snapshot rendering options for plain text and JSON exports.
pub const ScreenOptions = snapshot.ScreenOptions;
/// Semantic terminal event emitted to `EventCallback`.
pub const VtEvent = osc.VtEvent;
/// Optional callback hook invoked on OSC and bell events.
pub const EventCallback = osc.EventCallback;

/// Compute the terminal column width (0, 1, or 2) of Unicode codepoint `cp`.
pub fn wcwidth(cp: u21) u2 {
    const w = style.wcwidth(cp);
    assert(w <= 2);
    return w;
}

/// Render `term` as clean UTF-8 plain text without ANSI escape sequences.
pub fn renderPlainText(term: *const Terminal, allocator: Allocator, opts: ScreenOptions) ![]u8 {
    assert(term.rows() >= 1 and term.cols() >= 1);
    return snapshot.renderPlainText(term, allocator, opts);
}

/// Render a self-contained ANSI/DEC restore byte sequence for `term`.
pub fn renderAnsiRestore(term: *const Terminal, allocator: Allocator) ![]u8 {
    assert(term.rows() >= 1 and term.cols() >= 1);
    return snapshot.renderAnsiRestore(term, allocator);
}

/// Stream a valid JSON screen snapshot of `term` to `writer`.
pub fn writeScreenJson(term: *const Terminal, writer: *std.Io.Writer, opts: ScreenOptions) !void {
    assert(term.rows() >= 1 and term.cols() >= 1);
    return snapshot.writeScreenJson(term, writer, opts);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(style);
    std.testing.refAllDecls(modes);
    std.testing.refAllDecls(osc);
    std.testing.refAllDecls(grid);
    std.testing.refAllDecls(scrollback);
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(terminal);
    std.testing.refAllDecls(snapshot);
}

test "vt facade end-to-end TUI workflow (nvim/claude style)" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 6, .cols = 30 });
    defer term.deinit();

    term.feed("\x1b]2;claude-code\x1b\\\x1b]7;file://local/work/zmux\x1b\\");
    term.feed("\x1b]133;A\x07$ \x1b]133;B\x07zig test\r\n\x1b]133;C\x07");
    term.feed("\x1b[32mPASS\x1b[0m 🚀\r\n\x1b]133;D;0\x07\x1b]7501;done\x07");

    const text = try renderPlainText(&term, std.testing.allocator, .{});
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("$ zig test\nPASS 🚀", text);
    try std.testing.expectEqualStrings("claude-code", term.osc.title());
    try std.testing.expectEqualStrings("/work/zmux", term.osc.cwd());
    try std.testing.expectEqual(@as(?i32, 0), term.osc.last_command_exit);
    try std.testing.expectEqual(AgentStatus.done, term.osc.agent_status);
}

test "vt facade chunk-split equivalence on complex mixed escape stream" {
    const stream =
        "\x1b]0;hi\x07\x1b[1;38:2::12:34:56mHello\x1b[0m 世界\r\n" ++
        "\x1b[?1049h\x1b[2;3Halt\x1b[K\x1b[?1049l\x1b[2;1Hback\x1b[3b";

    var t1 = try Terminal.init(std.testing.allocator, .{ .rows = 5, .cols = 16 });
    defer t1.deinit();
    t1.feed(stream);

    var t2 = try Terminal.init(std.testing.allocator, .{ .rows = 5, .cols = 16 });
    defer t2.deinit();
    for (stream) |b| t2.feed(&.{b});

    const p1 = try renderPlainText(&t1, std.testing.allocator, .{ .include_scrollback = 10 });
    defer std.testing.allocator.free(p1);
    const p2 = try renderPlainText(&t2, std.testing.allocator, .{ .include_scrollback = 10 });
    defer std.testing.allocator.free(p2);
    try std.testing.expectEqualStrings(p1, p2);
    try std.testing.expectEqual(t1.cursor().row, t2.cursor().row);
    try std.testing.expectEqual(t1.cursor().col, t2.cursor().col);
}

test "CSI erase variants (ED 0/1/2/3, EL 0/1/2, ECH) and BCE background" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 3, .cols = 8 });
    defer term.deinit();

    term.feed("11111111\r\n22222222\r\n33333333\r\n44444444");
    try std.testing.expectEqual(@as(usize, 1), term.activeGrid().scrollbackCount());

    // ED 3 clears scrollback only.
    term.feed("\x1b[3J");
    try std.testing.expectEqual(@as(usize, 0), term.activeGrid().scrollbackCount());

    // Move to row 2 col 4, erase 2 chars with blue BCE bg, then EL 0 on row 3.
    term.feed("\x1b[44m\x1b[2;4H\x1b[2X\x1b[3;5H\x1b[0K");
    try std.testing.expect(term.activeGrid().cellAt(1, 3).style.bg.eql(.{ .indexed = 4 }));
    try std.testing.expectEqual(@as(u21, ' '), term.activeGrid().cellAt(1, 4).cp);
    try std.testing.expectEqual(@as(u21, '3'), term.activeGrid().cellAt(1, 5).cp);

    const txt = try renderPlainText(&term, std.testing.allocator, .{});
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("22222222\n333  333\n4444", txt);
}

test "CSI cursor motion suite (CUU/CUD/CUF/CUB/CNL/CPL/CHA/VPA/VPR/HPR/SU/SD)" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 10 });
    defer term.deinit();

    term.feed("\x1b[2;5H*\x1b[1A\x1b[2D+\x1b[2E!\x1b[1F?\x1b[8G#\x1b[4d\x1b[2a@");
    try std.testing.expectEqual(@as(u21, '*'), term.activeGrid().cellAt(1, 4).cp);
    try std.testing.expectEqual(@as(u21, '+'), term.activeGrid().cellAt(0, 3).cp);
    try std.testing.expectEqual(@as(u21, '!'), term.activeGrid().cellAt(2, 0).cp);
    try std.testing.expectEqual(@as(u21, '?'), term.activeGrid().cellAt(1, 0).cp);
    try std.testing.expectEqual(@as(u21, '#'), term.activeGrid().cellAt(1, 7).cp);
    try std.testing.expectEqual(@as(u21, '@'), term.activeGrid().cellAt(3, 9).cp);

    term.feed("\x1b[1S\x1b[1T");
    try std.testing.expectEqual(@as(u21, ' '), term.activeGrid().cellAt(0, 3).cp);
    try std.testing.expectEqual(@as(u21, '*'), term.activeGrid().cellAt(1, 4).cp);
}

test "CSI insert/linefeed modes, Kitty keyboard protocol, and RIS reset" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 3, .cols = 10 });
    defer term.deinit();

    term.feed("abcd\x1b[1;2H\x1b[4hXY\x1b[4l\x1b[20h\nZ\x1b[>5u\x1b[=2;2u");
    try std.testing.expectEqual(@as(u8, 7), term.modes.kittyFlags());
    const txt = try renderPlainText(&term, std.testing.allocator, .{});
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("aXYbcd\nZ", txt);

    term.feed("\x1b[<1u");
    try std.testing.expectEqual(@as(u8, 0), term.modes.kittyFlags());

    // ESC c (RIS) resets screen, modes, cursor, and OSC state completely.
    term.feed("\x1b]2;gone\x07\x1bc");
    try std.testing.expectEqualStrings("", term.osc.title());
    try std.testing.expect(!term.modes.linefeed_mode);
    const empty = try renderPlainText(&term, std.testing.allocator, .{});
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "ESC HTS and CSI TBC manage custom tab stops and BEL fires callback" {
    const Bell = struct {
        count: usize = 0,
        fn onEvent(ctx: ?*anyopaque, ev: VtEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (ev == .bell) self.count += 1;
        }
    };
    var bell: Bell = .{};
    var term = try Terminal.init(std.testing.allocator, .{
        .rows = 2,
        .cols = 16,
        .callback = .{ .ctx = &bell, .on_event = Bell.onEvent },
    });
    defer term.deinit();

    // Clear all tabs (TBC 3), set custom tab at col 4 (HTS), then tab and ring BEL.
    term.feed("\x1b[3g\x1b[1;5H\x1bH\r\tX\x07");
    try std.testing.expectEqual(@as(u21, 'X'), term.activeGrid().cellAt(0, 4).cp);
    try std.testing.expectEqual(@as(usize, 1), bell.count);
}

test "alt-screen ANSI restore roundtrip preserves alt screen and styled content" {
    var src = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 14 });
    defer src.deinit();
    src.feed("primary\x1b[?1049h\x1b[7;31mSTATUS\x1b[0m\r\n\x1b[>3u\x1b[2;4H");

    const restore = try renderAnsiRestore(&src, std.testing.allocator);
    defer std.testing.allocator.free(restore);

    var dst = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 14 });
    defer dst.deinit();
    dst.feed(restore);

    try std.testing.expect(dst.isAltScreen());
    try std.testing.expectEqual(@as(u8, 3), dst.modes.kittyFlags());
    try std.testing.expectEqual(@as(u16, 1), dst.cursor().row);
    try std.testing.expectEqual(@as(u16, 3), dst.cursor().col);
    const txt = try renderPlainText(&dst, std.testing.allocator, .{});
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("STATUS", txt);
}

test "plainText and writeScreenJson include requested scrollback tail" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 2, .cols = 10, .scrollback_lines = 5 });
    defer term.deinit();
    term.feed("L1\r\nL2\r\nL3\r\nL4");

    const vp = try renderPlainText(&term, std.testing.allocator, .{});
    defer std.testing.allocator.free(vp);
    try std.testing.expectEqualStrings("L3\nL4", vp);

    const with_sb = try renderPlainText(&term, std.testing.allocator, .{ .include_scrollback = 2 });
    defer std.testing.allocator.free(with_sb);
    try std.testing.expectEqualStrings("L1\nL2\nL3\nL4", with_sb);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeScreenJson(&term, &out.writer, .{ .include_scrollback = 2 });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("L1\nL2\nL3\nL4", parsed.value.object.get("text").?.string);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.get("lines").?.array.items.len);
}

test "Grid scrollback ring evicts oldest lines and reuses buffers" {
    var g = try grid.Grid.init(std.testing.allocator, 2, 4, 3);
    defer g.deinit();
    var cur: Cursor = .{};
    const m: Modes = .{};

    for ("ABCDEFGH") |ch| {
        cur.moveTo(0, 0, g.rows, g.cols);
        g.putChar(&cur, &m, ch, 1);
        g.scrollUp(1, Style.default);
    }
    try std.testing.expectEqual(@as(usize, 3), g.scrollbackCount());
    try std.testing.expectEqual(@as(u21, 'F'), g.scrollbackLine(0)[0].cp);
    try std.testing.expectEqual(@as(u21, 'G'), g.scrollbackLine(1)[0].cp);
    try std.testing.expectEqual(@as(u21, 'H'), g.scrollbackLine(2)[0].cp);
}

test "Grid insert/delete lines and chars respect scroll margins" {
    var g = try grid.Grid.init(std.testing.allocator, 4, 5, 4);
    defer g.deinit();
    var cur: Cursor = .{};
    const m: Modes = .{};

    for (0..4) |r| {
        cur.moveTo(@intCast(r), 0, g.rows, g.cols);
        g.putChar(&cur, &m, @intCast('0' + r), 1);
    }
    g.setScrollRegion(1, 2);
    g.insertLines(1, 1, Style.default);
    try std.testing.expectEqual(@as(u21, '0'), g.cellAt(0, 0).cp);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(1, 0).cp);
    try std.testing.expectEqual(@as(u21, '1'), g.cellAt(2, 0).cp);
    try std.testing.expectEqual(@as(u21, '3'), g.cellAt(3, 0).cp);

    g.deleteLines(1, 1, Style.default);
    try std.testing.expectEqual(@as(u21, '1'), g.cellAt(1, 0).cp);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(2, 0).cp);

    g.insertChars(0, 0, 2, Style.default);
    try std.testing.expectEqual(@as(u21, '0'), g.cellAt(0, 2).cp);
    g.deleteChars(0, 0, 2, Style.default);
    try std.testing.expectEqual(@as(u21, '0'), g.cellAt(0, 0).cp);
}
