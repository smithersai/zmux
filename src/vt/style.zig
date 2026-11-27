//! Terminal cell styles, colors, attributes, Unicode display width (`wcwidth`),
//! and SGR (Select Graphic Rendition) parameter evaluation.

const std = @import("std");
const assert = std.debug.assert;

/// Maximum colon-separated subparameters retained per SGR parameter item.
pub const max_subparams: usize = 6;

/// 24-bit RGB color triplet for truecolor SGR (`38;2;r;g;b` / `48;2;r;g;b`).
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Foreground or background terminal color.
pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: Rgb,

    /// Return true when `a` and `b` represent the same color value.
    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |ai| switch (b) {
                .indexed => |bi| ai == bi,
                else => false,
            },
            .rgb => |ar| switch (b) {
                .rgb => |br| ar.r == br.r and ar.g == br.g and ar.b == br.b,
                else => false,
            },
        };
    }
};

/// Packed bitfield of standard ECMA-48 text attributes.
pub const Attr = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    /// Return true when both attribute sets have identical flags.
    pub fn eql(a: Attr, b: Attr) bool {
        const ab: u8 = @bitCast(a);
        const bb: u8 = @bitCast(b);
        return ab == bb;
    }

    /// Return true when no text attributes are active.
    pub fn isEmpty(self: Attr) bool {
        const bits: u8 = @bitCast(self);
        return bits == 0;
    }
};

/// Complete rendering style attached to a terminal cell or cursor.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},

    /// Default terminal style (default colors, no attributes).
    pub const default: Style = .{};

    /// Return true when two styles are visually identical.
    pub fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attr.eql(b.attr);
    }

    /// Return the erase style preserving only background color (xterm BCE).
    pub fn eraseStyle(self: Style) Style {
        return .{ .fg = .default, .bg = self.bg, .attr = .{} };
    }
};

/// Single terminal screen cell storing a Unicode scalar, display width, and style.
pub const Cell = struct {
    cp: u21 = ' ',
    width: u2 = 1,
    style: Style = .{},

    /// Default blank space cell with default style.
    pub const blank: Cell = .{};

    /// Return a blank space cell carrying the BCE background of `style`.
    pub fn blankStyled(style: Style) Cell {
        const cell: Cell = .{ .cp = ' ', .width = 1, .style = style.eraseStyle() };
        assert(cell.width == 1);
        return cell;
    }

    /// Return the trailing spacer cell placed in the second column of a wide glyph.
    pub fn continuation(style: Style) Cell {
        const cell: Cell = .{ .cp = 0, .width = 0, .style = style };
        assert(cell.isContinuation());
        return cell;
    }

    /// Return true when this cell is the second half of a 2-column glyph.
    pub fn isContinuation(self: Cell) bool {
        return self.width == 0 and self.cp == 0;
    }

    /// Return true when this cell is an unstyled blank space.
    pub fn isDefaultBlank(self: Cell) bool {
        return self.cp == ' ' and self.width == 1 and self.style.eql(Style.default);
    }

    /// Return true when two cells match in codepoint, width, and style.
    pub fn eql(a: Cell, b: Cell) bool {
        return a.cp == b.cp and a.width == b.width and a.style.eql(b.style);
    }
};

/// One CSI parameter item with optional colon-delimited subparameters (ITU T.416).
pub const SgrParam = struct {
    value: u16 = 0,
    sub_count: u8 = 0,
    subs: [max_subparams]u16 = @splat(0),

    /// Construct a plain SGR parameter without subparameters.
    pub fn plain(value: u16) SgrParam {
        return .{ .value = value };
    }
};

const CodeRange = struct { lo: u21, hi: u21 };

const zero_width_ranges = [_]CodeRange{
    .{ .lo = 0x0000, .hi = 0x001F },
    .{ .lo = 0x007F, .hi = 0x009F },
    .{ .lo = 0x0300, .hi = 0x036F },
    .{ .lo = 0x0483, .hi = 0x0489 },
    .{ .lo = 0x0591, .hi = 0x05BD },
    .{ .lo = 0x05BF, .hi = 0x05BF },
    .{ .lo = 0x05C1, .hi = 0x05C2 },
    .{ .lo = 0x05C4, .hi = 0x05C5 },
    .{ .lo = 0x05C7, .hi = 0x05C7 },
    .{ .lo = 0x0610, .hi = 0x061A },
    .{ .lo = 0x064B, .hi = 0x065F },
    .{ .lo = 0x0670, .hi = 0x0670 },
    .{ .lo = 0x06D6, .hi = 0x06DC },
    .{ .lo = 0x06DF, .hi = 0x06E4 },
    .{ .lo = 0x06E7, .hi = 0x06E8 },
    .{ .lo = 0x06EA, .hi = 0x06ED },
    .{ .lo = 0x0711, .hi = 0x0711 },
    .{ .lo = 0x0730, .hi = 0x074A },
    .{ .lo = 0x0901, .hi = 0x0902 },
    .{ .lo = 0x093C, .hi = 0x093C },
    .{ .lo = 0x0941, .hi = 0x0948 },
    .{ .lo = 0x094D, .hi = 0x094D },
    .{ .lo = 0x0951, .hi = 0x0957 },
    .{ .lo = 0x0E31, .hi = 0x0E31 },
    .{ .lo = 0x0E34, .hi = 0x0E3A },
    .{ .lo = 0x0E47, .hi = 0x0E4E },
    .{ .lo = 0x1AB0, .hi = 0x1AFF },
    .{ .lo = 0x1DC0, .hi = 0x1DFF },
    .{ .lo = 0x200B, .hi = 0x200F },
    .{ .lo = 0x202A, .hi = 0x202E },
    .{ .lo = 0x2060, .hi = 0x206F },
    .{ .lo = 0x20D0, .hi = 0x20FF },
    .{ .lo = 0xFE00, .hi = 0xFE0F },
    .{ .lo = 0xFE20, .hi = 0xFE2F },
    .{ .lo = 0xFEFF, .hi = 0xFEFF },
    .{ .lo = 0xE0100, .hi = 0xE01EF },
};

const wide_ranges = [_]CodeRange{
    .{ .lo = 0x1100, .hi = 0x115F },
    .{ .lo = 0x231A, .hi = 0x231B },
    .{ .lo = 0x2329, .hi = 0x232A },
    .{ .lo = 0x23E9, .hi = 0x23F3 },
    .{ .lo = 0x23F8, .hi = 0x23FA },
    .{ .lo = 0x25FD, .hi = 0x25FE },
    .{ .lo = 0x2614, .hi = 0x2615 },
    .{ .lo = 0x2648, .hi = 0x2653 },
    .{ .lo = 0x267F, .hi = 0x267F },
    .{ .lo = 0x2693, .hi = 0x2693 },
    .{ .lo = 0x26A1, .hi = 0x26A1 },
    .{ .lo = 0x26AA, .hi = 0x26AB },
    .{ .lo = 0x26BD, .hi = 0x26BE },
    .{ .lo = 0x26C4, .hi = 0x26C5 },
    .{ .lo = 0x26CE, .hi = 0x26CE },
    .{ .lo = 0x26D4, .hi = 0x26D4 },
    .{ .lo = 0x26EA, .hi = 0x26EA },
    .{ .lo = 0x26F2, .hi = 0x26F3 },
    .{ .lo = 0x26F5, .hi = 0x26F5 },
    .{ .lo = 0x26FA, .hi = 0x26FA },
    .{ .lo = 0x26FD, .hi = 0x26FD },
    .{ .lo = 0x2705, .hi = 0x2705 },
    .{ .lo = 0x270A, .hi = 0x270B },
    .{ .lo = 0x2728, .hi = 0x2728 },
    .{ .lo = 0x274C, .hi = 0x274C },
    .{ .lo = 0x274E, .hi = 0x274E },
    .{ .lo = 0x2753, .hi = 0x2755 },
    .{ .lo = 0x2757, .hi = 0x2757 },
    .{ .lo = 0x2795, .hi = 0x2797 },
    .{ .lo = 0x27B0, .hi = 0x27B0 },
    .{ .lo = 0x27BF, .hi = 0x27BF },
    .{ .lo = 0x2B1B, .hi = 0x2B1C },
    .{ .lo = 0x2B50, .hi = 0x2B50 },
    .{ .lo = 0x2B55, .hi = 0x2B55 },
    .{ .lo = 0x2E80, .hi = 0x303E },
    .{ .lo = 0x3041, .hi = 0x33FF },
    .{ .lo = 0x3400, .hi = 0x4DBF },
    .{ .lo = 0x4E00, .hi = 0xA4CF },
    .{ .lo = 0xA960, .hi = 0xA97C },
    .{ .lo = 0xAC00, .hi = 0xD7A3 },
    .{ .lo = 0xF900, .hi = 0xFAFF },
    .{ .lo = 0xFE10, .hi = 0xFE19 },
    .{ .lo = 0xFE30, .hi = 0xFE6F },
    .{ .lo = 0xFF00, .hi = 0xFF60 },
    .{ .lo = 0xFFE0, .hi = 0xFFE6 },
    .{ .lo = 0x16FE0, .hi = 0x16FE4 },
    .{ .lo = 0x17000, .hi = 0x187F7 },
    .{ .lo = 0x18800, .hi = 0x18CD5 },
    .{ .lo = 0x1B000, .hi = 0x1B122 },
    .{ .lo = 0x1B132, .hi = 0x1B167 },
    .{ .lo = 0x1B170, .hi = 0x1B2FB },
    .{ .lo = 0x1F004, .hi = 0x1F004 },
    .{ .lo = 0x1F0CF, .hi = 0x1F0CF },
    .{ .lo = 0x1F18E, .hi = 0x1F18E },
    .{ .lo = 0x1F191, .hi = 0x1F19A },
    .{ .lo = 0x1F1E6, .hi = 0x1F1FF },
    .{ .lo = 0x1F200, .hi = 0x1F2FF },
    .{ .lo = 0x1F300, .hi = 0x1F64F },
    .{ .lo = 0x1F680, .hi = 0x1F6FF },
    .{ .lo = 0x1F900, .hi = 0x1F9FF },
    .{ .lo = 0x1FA00, .hi = 0x1FAFF },
    .{ .lo = 0x20000, .hi = 0x2FFFD },
    .{ .lo = 0x30000, .hi = 0x3FFFD },
};

fn inRanges(ranges: []const CodeRange, cp: u21) bool {
    assert(ranges.len > 0);
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].lo) {
            hi = mid;
        } else if (cp > ranges[mid].hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Return the terminal column width of Unicode codepoint `cp`:
/// 0 for C0/C1/DEL/combining/format characters, 2 for East Asian Wide and
/// emoji codepoints, and 1 for standard printable characters.
pub fn wcwidth(cp: u21) u2 {
    if (cp >= 0x20 and cp <= 0x7E) return 1;
    if (cp > 0x10FFFF) return 0;
    const width: u2 = if (inRanges(&zero_width_ranges, cp))
        0
    else if (inRanges(&wide_ranges, cp))
        2
    else
        1;
    assert(width <= 2);
    return width;
}

/// Apply a slice of parsed SGR parameters (including colon subparameters) to `style`.
pub fn applySgr(style: *Style, params: []const SgrParam) void {
    if (params.len == 0) {
        style.* = Style.default;
        return;
    }
    var i: usize = 0;
    while (i < params.len) {
        const p = params[i];
        assert(p.sub_count <= max_subparams);
        if (p.value == 38 or p.value == 48 or p.value == 58) {
            i += applyExtendedColor(style, params[i..]);
        } else {
            applyBasicSgr(style, p);
            i += 1;
        }
    }
    assert(i == params.len);
}

/// Apply plain integer SGR parameters without subparameters to `style`.
pub fn applySgrFlat(style: *Style, raw_params: []const u16) void {
    var buf: [32]SgrParam = undefined;
    const n = @min(raw_params.len, buf.len);
    for (0..n) |idx| buf[idx] = SgrParam.plain(raw_params[idx]);
    assert(n <= buf.len);
    applySgr(style, buf[0..n]);
}

fn applyBasicSgr(style: *Style, p: SgrParam) void {
    switch (p.value) {
        0 => style.* = Style.default,
        1 => style.attr.bold = true,
        2 => style.attr.dim = true,
        3 => style.attr.italic = true,
        4 => style.attr.underline = p.sub_count == 0 or p.subs[0] != 0,
        5, 6 => style.attr.blink = true,
        7 => style.attr.inverse = true,
        8 => style.attr.hidden = true,
        9 => style.attr.strikethrough = true,
        21 => style.attr.underline = true,
        22 => {
            style.attr.bold = false;
            style.attr.dim = false;
        },
        23 => style.attr.italic = false,
        24 => style.attr.underline = false,
        25 => style.attr.blink = false,
        27 => style.attr.inverse = false,
        28 => style.attr.hidden = false,
        29 => style.attr.strikethrough = false,
        30...37 => style.fg = .{ .indexed = @intCast(p.value - 30) },
        39 => style.fg = .default,
        40...47 => style.bg = .{ .indexed = @intCast(p.value - 40) },
        49 => style.bg = .default,
        90...97 => style.fg = .{ .indexed = @intCast(8 + (p.value - 90)) },
        100...107 => style.bg = .{ .indexed = @intCast(8 + (p.value - 100)) },
        else => {},
    }
}

fn applyExtendedColor(style: *Style, tail: []const SgrParam) usize {
    assert(tail.len >= 1);
    const head = tail[0];
    assert(head.value == 38 or head.value == 48 or head.value == 58);
    if (head.sub_count > 0) {
        if (parseColonColor(head)) |color| assignTargetColor(style, head.value, color);
        return 1;
    }
    if (tail.len < 2) return 1;
    const mode = tail[1].value;
    if (mode == 5 and tail.len >= 3) {
        assignTargetColor(style, head.value, .{ .indexed = @intCast(@min(tail[2].value, 255)) });
        return 3;
    }
    if (mode == 2 and tail.len >= 5) {
        assignTargetColor(style, head.value, .{ .rgb = .{
            .r = @intCast(@min(tail[2].value, 255)),
            .g = @intCast(@min(tail[3].value, 255)),
            .b = @intCast(@min(tail[4].value, 255)),
        } });
        return 5;
    }
    return 1;
}

fn parseColonColor(p: SgrParam) ?Color {
    assert(p.sub_count > 0);
    assert(p.sub_count <= max_subparams);
    const mode = p.subs[0];
    if (mode == 5 and p.sub_count >= 2) {
        return .{ .indexed = @intCast(@min(p.subs[1], 255)) };
    }
    if (mode == 2) {
        if (p.sub_count >= 5) {
            return .{ .rgb = .{
                .r = @intCast(@min(p.subs[2], 255)),
                .g = @intCast(@min(p.subs[3], 255)),
                .b = @intCast(@min(p.subs[4], 255)),
            } };
        }
        if (p.sub_count == 4) {
            return .{ .rgb = .{
                .r = @intCast(@min(p.subs[1], 255)),
                .g = @intCast(@min(p.subs[2], 255)),
                .b = @intCast(@min(p.subs[3], 255)),
            } };
        }
    }
    return null;
}

fn assignTargetColor(style: *Style, code: u16, color: Color) void {
    assert(code == 38 or code == 48 or code == 58);
    if (code == 38) {
        style.fg = color;
    } else if (code == 48) {
        style.bg = color;
    }
}

comptime {
    for (1..zero_width_ranges.len) |i| {
        assert(zero_width_ranges[i - 1].hi < zero_width_ranges[i].lo);
    }
    for (1..wide_ranges.len) |i| {
        assert(wide_ranges[i - 1].hi < wide_ranges[i].lo);
    }
}

test "wcwidth covers ASCII, control, combining, CJK, and emoji" {
    try std.testing.expectEqual(@as(u2, 1), wcwidth('A'));
    try std.testing.expectEqual(@as(u2, 1), wcwidth(' '));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x00));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x1B));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x7F));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x200D)); // ZWJ
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x4E2D)); // CJK '中'
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x3042)); // Hiragana 'あ'
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x1F680)); // rocket emoji
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x1FFFFF)); // out-of-range u21
}

test "applySgr handles basic attributes, 16/256/RGB, and colon subparams" {
    var st = Style.default;
    applySgrFlat(&st, &.{ 1, 3, 4, 31, 48, 5, 236 });
    try std.testing.expect(st.attr.bold);
    try std.testing.expect(st.attr.italic);
    try std.testing.expect(st.attr.underline);
    try std.testing.expect(st.fg.eql(.{ .indexed = 1 }));
    try std.testing.expect(st.bg.eql(.{ .indexed = 236 }));

    applySgrFlat(&st, &.{ 22, 38, 2, 10, 20, 30, 102 });
    try std.testing.expect(!st.attr.bold);
    try std.testing.expect(st.fg.eql(.{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }));
    try std.testing.expect(st.bg.eql(.{ .indexed = 10 }));

    // Colon subparams: curly underline 4:3, ITU RGB 38:2::1:2:3, indexed 48:5:196
    const colon_params = [_]SgrParam{
        .{ .value = 4, .sub_count = 1, .subs = .{ 0, 0, 0, 0, 0, 0 } },
        .{ .value = 38, .sub_count = 5, .subs = .{ 2, 0, 1, 2, 3, 0 } },
        .{ .value = 48, .sub_count = 2, .subs = .{ 5, 196, 0, 0, 0, 0 } },
    };
    applySgr(&st, &colon_params);
    try std.testing.expect(!st.attr.underline);
    try std.testing.expect(st.fg.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    try std.testing.expect(st.bg.eql(.{ .indexed = 196 }));

    // Empty params resets to default.
    applySgr(&st, &.{});
    try std.testing.expect(st.eql(Style.default));
}

test "Cell helpers preserve BCE background and continuation markers" {
    const st: Style = .{ .fg = .{ .indexed = 2 }, .bg = .{ .indexed = 4 }, .attr = .{ .bold = true } };
    const blank = Cell.blankStyled(st);
    try std.testing.expectEqual(@as(u21, ' '), blank.cp);
    try std.testing.expect(blank.style.fg.eql(.default));
    try std.testing.expect(blank.style.bg.eql(.{ .indexed = 4 }));
    try std.testing.expect(blank.style.attr.isEmpty());

    const cont = Cell.continuation(st);
    try std.testing.expect(cont.isContinuation());
    try std.testing.expect(!blank.isContinuation());
}
