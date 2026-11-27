//! Terminal cell grid with scroll margins, erase/insert/delete operations,
//! wide-character orphan cleanup, autowrap, and atomic OOM-safe resizing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const style_mod = @import("style.zig");
const modes_mod = @import("modes.zig");
const sb_mod = @import("scrollback.zig");

const Cell = style_mod.Cell;
const Style = style_mod.Style;
const Cursor = modes_mod.Cursor;
const Modes = modes_mod.Modes;

/// Maximum supported viewport height in rows.
pub const max_rows: u16 = 512;
/// Maximum supported viewport width in columns.
pub const max_cols: u16 = 512;
/// Default primary-screen scrollback ring capacity in lines.
pub const default_scrollback: usize = sb_mod.default_scrollback;
/// Hard upper bound on scrollback ring capacity in lines.
pub const max_scrollback: usize = sb_mod.max_scrollback;
/// Re-exported scrollback line type.
pub const ScrollbackLine = sb_mod.ScrollbackLine;
/// Re-exported bounded scrollback ring type.
pub const ScrollbackRing = sb_mod.ScrollbackRing;

/// Pre-allocated buffers for an atomic, OOM-safe grid resize.
pub const ResizeBufs = struct {
    cells: []Cell,
    wrapped: []bool,
    rows: u16,
    cols: u16,

    /// Free unused resize buffers if an atomic multi-grid resize aborts.
    pub fn deinit(self: ResizeBufs, allocator: Allocator) void {
        allocator.free(self.wrapped);
        allocator.free(self.cells);
    }
};

/// 2D cell grid with scroll margins and optional bounded scrollback history.
pub const Grid = struct {
    allocator: Allocator,
    rows: u16,
    cols: u16,
    cells: []Cell,
    wrapped: []bool,
    scroll_top: u16,
    scroll_bottom: u16,
    scrollback: ScrollbackRing,

    /// Allocate a `rows x cols` grid (clamped to `[1, max_*]`) with a scrollback
    /// ring of `scrollback_cap` lines (0 disables scrollback, used by alt screen).
    pub fn init(allocator: Allocator, rows: u16, cols: u16, scrollback_cap: usize) !Grid {
        const r = clampDim(rows, max_rows);
        const c = clampDim(cols, max_cols);

        const cells = try allocator.alloc(Cell, @as(usize, r) * @as(usize, c));
        errdefer allocator.free(cells);
        @memset(cells, Cell.blank);

        const wrapped = try allocator.alloc(bool, r);
        errdefer allocator.free(wrapped);
        @memset(wrapped, false);

        const scrollback = try ScrollbackRing.init(allocator, scrollback_cap);
        assert(r >= 1 and c >= 1);
        assert(cells.len == @as(usize, r) * @as(usize, c));
        return .{
            .allocator = allocator,
            .rows = r,
            .cols = c,
            .cells = cells,
            .wrapped = wrapped,
            .scroll_top = 0,
            .scroll_bottom = r - 1,
            .scrollback = scrollback,
        };
    }

    /// Free active cells, wrap flags, and scrollback ring storage.
    pub fn deinit(self: *Grid) void {
        assert(self.cells.len == @as(usize, self.rows) * @as(usize, self.cols));
        self.scrollback.deinit();
        self.allocator.free(self.wrapped);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// Return immutable cells for row `row`.
    pub fn rowSlice(self: *const Grid, row: u16) []const Cell {
        assert(row < self.rows);
        const start = @as(usize, row) * @as(usize, self.cols);
        return self.cells[start .. start + self.cols];
    }

    /// Return mutable cells for row `row`.
    pub fn rowSliceMut(self: *Grid, row: u16) []Cell {
        assert(row < self.rows);
        const start = @as(usize, row) * @as(usize, self.cols);
        return self.cells[start .. start + self.cols];
    }

    /// Return the cell at `(row, col)`.
    pub fn cellAt(self: *const Grid, row: u16, col: u16) Cell {
        assert(row < self.rows and col < self.cols);
        return self.rowSlice(row)[col];
    }

    /// Return the number of retained scrollback lines.
    pub fn scrollbackCount(self: *const Grid) usize {
        return self.scrollback.count();
    }

    /// Return scrollback line `idx` (`0` = oldest, `scrollbackCount()-1` = newest).
    pub fn scrollbackLine(self: *const Grid, idx: usize) []const Cell {
        return self.scrollback.line(idx);
    }

    /// Return whether scrollback line `idx` soft-wrapped onto the following line.
    pub fn scrollbackWrapped(self: *const Grid, idx: usize) bool {
        return self.scrollback.wrapped(idx);
    }

    /// Discard all retained scrollback lines while keeping reusable slot buffers.
    pub fn clearScrollback(self: *Grid) void {
        self.scrollback.clear();
    }

    /// Configure DECSTBM top/bottom scroll margins (`0`-indexed inclusive).
    pub fn setScrollRegion(self: *Grid, top: u16, bottom: u16) void {
        const clamped_bottom = @min(bottom, self.rows - 1);
        if (top < clamped_bottom) {
            self.scroll_top = top;
            self.scroll_bottom = clamped_bottom;
        }
        assert(self.scroll_top <= self.scroll_bottom);
        assert(self.scroll_bottom < self.rows);
    }

    /// Reset scroll margins to the full viewport `[0, rows - 1]`.
    pub fn resetScrollRegion(self: *Grid) void {
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
        assert(self.scroll_top <= self.scroll_bottom);
    }

    /// Fill every active viewport cell with `Cell.blankStyled(style)` and reset wrap flags.
    pub fn clearAll(self: *Grid, style: Style) void {
        @memset(self.cells, Cell.blankStyled(style));
        @memset(self.wrapped, false);
    }

    /// Scroll `[scroll_top..=scroll_bottom]` up by `count` lines, archiving lines
    /// scrolled off row 0 into scrollback when enabled.
    pub fn scrollUp(self: *Grid, count: u16, blank_style: Style) void {
        self.scrollUpInternal(count, blank_style, true);
    }

    fn scrollUpInternal(self: *Grid, count: u16, blank_style: Style, archive: bool) void {
        assert(self.scroll_top <= self.scroll_bottom);
        assert(self.scroll_bottom < self.rows);
        const height = self.scroll_bottom - self.scroll_top + 1;
        const n = @min(count, height);
        if (n == 0) return;

        if (archive and self.scroll_top == 0 and self.scrollback.isEnabled()) {
            for (0..n) |i| {
                self.scrollback.push(self.rowSlice(@intCast(i)), self.wrapped[i], self.cols);
            }
        }

        const blank = Cell.blankStyled(blank_style);
        const stride: usize = self.cols;
        if (n < height) {
            const dst = @as(usize, self.scroll_top) * stride;
            const src = @as(usize, self.scroll_top + n) * stride;
            const move = @as(usize, height - n) * stride;
            std.mem.copyForwards(Cell, self.cells[dst .. dst + move], self.cells[src .. src + move]);
            std.mem.copyForwards(
                bool,
                self.wrapped[self.scroll_top .. self.scroll_bottom + 1 - n],
                self.wrapped[self.scroll_top + n .. self.scroll_bottom + 1],
            );
        }
        const clear_row = self.scroll_bottom + 1 - n;
        for (clear_row..self.scroll_bottom + 1) |r| {
            @memset(self.rowSliceMut(@intCast(r)), blank);
            self.wrapped[r] = false;
        }
    }

    /// Scroll `[scroll_top..=scroll_bottom]` down by `count` lines.
    pub fn scrollDown(self: *Grid, count: u16, blank_style: Style) void {
        assert(self.scroll_top <= self.scroll_bottom);
        assert(self.scroll_bottom < self.rows);
        const height = self.scroll_bottom - self.scroll_top + 1;
        const n = @min(count, height);
        if (n == 0) return;

        const blank = Cell.blankStyled(blank_style);
        const stride: usize = self.cols;
        if (n < height) {
            const src = @as(usize, self.scroll_top) * stride;
            const dst = @as(usize, self.scroll_top + n) * stride;
            const move = @as(usize, height - n) * stride;
            std.mem.copyBackwards(Cell, self.cells[dst .. dst + move], self.cells[src .. src + move]);
            std.mem.copyBackwards(
                bool,
                self.wrapped[self.scroll_top + n .. self.scroll_bottom + 1],
                self.wrapped[self.scroll_top .. self.scroll_bottom + 1 - n],
            );
        }
        for (self.scroll_top..self.scroll_top + n) |r| {
            @memset(self.rowSliceMut(@intCast(r)), blank);
            self.wrapped[r] = false;
        }
    }

    /// Execute ED (`CSI mode J`): 0 = cursor to end, 1 = start to cursor,
    /// 2 = whole display, 3 = clear scrollback.
    pub fn eraseDisplay(self: *Grid, mode: u16, cur_row: u16, cur_col: u16, style: Style) void {
        assert(cur_row < self.rows and cur_col < self.cols);
        const blank = Cell.blankStyled(style);
        switch (mode) {
            0 => {
                self.eraseLine(0, cur_row, cur_col, style);
                for (cur_row + 1..self.rows) |r| {
                    @memset(self.rowSliceMut(@intCast(r)), blank);
                    self.wrapped[r] = false;
                }
            },
            1 => {
                for (0..cur_row) |r| {
                    @memset(self.rowSliceMut(@intCast(r)), blank);
                    self.wrapped[r] = false;
                }
                self.eraseLine(1, cur_row, cur_col, style);
            },
            2 => self.clearAll(style),
            3 => self.clearScrollback(),
            else => {},
        }
    }

    /// Execute EL (`CSI mode K`): 0 = cursor to EOL, 1 = BOL to cursor, 2 = whole line.
    pub fn eraseLine(self: *Grid, mode: u16, cur_row: u16, cur_col: u16, style: Style) void {
        assert(cur_row < self.rows and cur_col < self.cols);
        const blank = Cell.blankStyled(style);
        const row = self.rowSliceMut(cur_row);
        switch (mode) {
            0 => {
                self.clearWideOrphan(cur_row, cur_col, blank);
                @memset(row[cur_col..], blank);
                self.wrapped[cur_row] = false;
            },
            1 => {
                self.clearWideOrphan(cur_row, cur_col, blank);
                @memset(row[0 .. cur_col + 1], blank);
            },
            2 => {
                @memset(row, blank);
                self.wrapped[cur_row] = false;
            },
            else => {},
        }
    }

    /// Execute ECH (`CSI count X`): erase `count` cells at `(row, col)` without shifting.
    pub fn eraseChars(self: *Grid, row: u16, col: u16, count: u16, style: Style) void {
        assert(row < self.rows and col < self.cols);
        const n = @min(count, self.cols - col);
        if (n == 0) return;
        const blank = Cell.blankStyled(style);
        self.clearWideOrphan(row, col, blank);
        self.clearWideOrphan(row, col + n - 1, blank);
        @memset(self.rowSliceMut(row)[col .. col + n], blank);
    }

    /// Execute IL (`CSI count L`): insert `count` blank lines at `row` inside margins.
    pub fn insertLines(self: *Grid, row: u16, count: u16, style: Style) void {
        assert(row < self.rows);
        if (row < self.scroll_top or row > self.scroll_bottom) return;
        const saved_top = self.scroll_top;
        self.scroll_top = row;
        self.scrollDown(count, style);
        self.scroll_top = saved_top;
    }

    /// Execute DL (`CSI count M`): delete `count` lines at `row` inside margins.
    pub fn deleteLines(self: *Grid, row: u16, count: u16, style: Style) void {
        assert(row < self.rows);
        if (row < self.scroll_top or row > self.scroll_bottom) return;
        const saved_top = self.scroll_top;
        self.scroll_top = row;
        self.scrollUpInternal(count, style, false);
        self.scroll_top = saved_top;
    }

    /// Execute ICH (`CSI count @`): insert `count` blank cells at `(row, col)`.
    pub fn insertChars(self: *Grid, row: u16, col: u16, count: u16, style: Style) void {
        assert(row < self.rows and col < self.cols);
        const n = @min(count, self.cols - col);
        if (n == 0) return;
        const blank = Cell.blankStyled(style);
        self.clearWideOrphan(row, col, blank);
        const line = self.rowSliceMut(row);
        const tail_len = self.cols - col - n;
        if (tail_len > 0) {
            std.mem.copyBackwards(Cell, line[col + n .. self.cols], line[col .. col + tail_len]);
        }
        @memset(line[col .. col + n], blank);
        if (line[self.cols - 1].width == 2) line[self.cols - 1] = blank;
        self.wrapped[row] = false;
    }

    /// Execute DCH (`CSI count P`): delete `count` cells at `(row, col)`.
    pub fn deleteChars(self: *Grid, row: u16, col: u16, count: u16, style: Style) void {
        assert(row < self.rows and col < self.cols);
        const n = @min(count, self.cols - col);
        if (n == 0) return;
        const blank = Cell.blankStyled(style);
        self.clearWideOrphan(row, col, blank);
        if (col + n < self.cols) self.clearWideOrphan(row, col + n, blank);
        const line = self.rowSliceMut(row);
        const tail_len = self.cols - col - n;
        if (tail_len > 0) {
            std.mem.copyForwards(Cell, line[col .. col + tail_len], line[col + n .. self.cols]);
        }
        @memset(line[self.cols - n .. self.cols], blank);
        self.wrapped[row] = false;
    }

    /// Write codepoint `cp` (display width `width`) at `cur`, handling autowrap,
    /// insert mode, and wide-character orphan cleanup.
    pub fn putChar(self: *Grid, cur: *Cursor, modes: *const Modes, cp: u21, width: u2) void {
        assert(cur.row < self.rows and cur.col < self.cols);
        if (width == 0) return;
        const eff_width: u2 = if (width == 2 and self.cols < 2) 1 else width;

        if (cur.pending_wrap) {
            if (modes.autowrap) self.wrapAdvance(cur) else cur.pending_wrap = false;
        }
        if (eff_width == 2 and cur.col + 1 >= self.cols) {
            if (modes.autowrap) {
                const blank = Cell.blankStyled(cur.style);
                self.clearWideOrphan(cur.row, cur.col, blank);
                self.rowSliceMut(cur.row)[cur.col] = blank;
                self.wrapAdvance(cur);
            } else {
                cur.col = self.cols - 2;
            }
        }
        if (modes.insert_mode) self.insertChars(cur.row, cur.col, eff_width, cur.style);

        const blank = Cell.blankStyled(cur.style);
        self.clearWideOrphan(cur.row, cur.col, blank);
        if (eff_width == 2) self.clearWideOrphan(cur.row, cur.col + 1, blank);

        const line = self.rowSliceMut(cur.row);
        line[cur.col] = .{ .cp = cp, .width = eff_width, .style = cur.style };
        if (eff_width == 2) line[cur.col + 1] = Cell.continuation(cur.style);

        if (cur.col + eff_width >= self.cols) {
            cur.col = self.cols - 1;
            cur.pending_wrap = modes.autowrap;
        } else {
            cur.col += eff_width;
            cur.pending_wrap = false;
        }
        assert(cur.row < self.rows and cur.col < self.cols);
    }

    /// Pre-allocate buffers for resizing to `new_rows x new_cols` (clamped).
    pub fn prepareResize(allocator: Allocator, new_rows: u16, new_cols: u16) !ResizeBufs {
        const r = clampDim(new_rows, max_rows);
        const c = clampDim(new_cols, max_cols);
        const next_cells = try allocator.alloc(Cell, @as(usize, r) * @as(usize, c));
        errdefer allocator.free(next_cells);
        @memset(next_cells, Cell.blank);

        const next_wrapped = try allocator.alloc(bool, r);
        @memset(next_wrapped, false);
        assert(next_cells.len == @as(usize, r) * @as(usize, c));
        return .{ .cells = next_cells, .wrapped = next_wrapped, .rows = r, .cols = c };
    }

    /// Commit pre-allocated `bufs` infallibly, preserving visible rows and clamping `cur`.
    pub fn applyResize(self: *Grid, bufs: ResizeBufs, cur: *Cursor) void {
        const r = bufs.rows;
        const c = bufs.cols;
        assert(bufs.cells.len == @as(usize, r) * @as(usize, c));
        assert(bufs.wrapped.len == r);

        const shift: u16 = if (r < self.rows and cur.row >= r) cur.row - (r - 1) else 0;
        if (shift > 0 and self.scrollback.isEnabled()) {
            for (0..shift) |i| {
                self.scrollback.push(self.rowSlice(@intCast(i)), self.wrapped[i], self.cols);
            }
        }

        const copy_rows = @min(self.rows - shift, r);
        const copy_cols = @min(self.cols, c);
        for (0..copy_rows) |dst_r| {
            const src_row = self.rowSlice(@intCast(shift + dst_r));
            const dst_start = dst_r * @as(usize, c);
            const dst_row = bufs.cells[dst_start .. dst_start + c];
            @memcpy(dst_row[0..copy_cols], src_row[0..copy_cols]);
            if (copy_cols > 0 and dst_row[copy_cols - 1].width == 2 and copy_cols == c) {
                dst_row[copy_cols - 1] = Cell.blank;
            }
            bufs.wrapped[dst_r] = self.wrapped[shift + dst_r] and (c == self.cols);
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.wrapped);
        self.cells = bufs.cells;
        self.wrapped = bufs.wrapped;
        self.rows = r;
        self.cols = c;
        self.scroll_top = 0;
        self.scroll_bottom = r - 1;
        cur.row -= shift;
        cur.clamp(r, c);
        assert(self.cells.len == @as(usize, self.rows) * @as(usize, self.cols));
    }

    /// Resize the grid atomically to `new_rows x new_cols`, preserving visible
    /// content, archiving top rows when shrinking past the cursor, and clamping `cur`.
    pub fn resize(self: *Grid, new_rows: u16, new_cols: u16, cur: *Cursor) !void {
        const r = clampDim(new_rows, max_rows);
        const c = clampDim(new_cols, max_cols);
        if (r == self.rows and c == self.cols) {
            cur.clamp(r, c);
            return;
        }
        const bufs = try prepareResize(self.allocator, r, c);
        self.applyResize(bufs, cur);
    }

    fn wrapAdvance(self: *Grid, cur: *Cursor) void {
        self.wrapped[cur.row] = true;
        if (cur.row == self.scroll_bottom) {
            self.scrollUp(1, cur.style);
        } else if (cur.row + 1 < self.rows) {
            cur.row += 1;
        }
        cur.col = 0;
        cur.pending_wrap = false;
    }

    fn clearWideOrphan(self: *Grid, row: u16, col: u16, blank: Cell) void {
        assert(row < self.rows and col < self.cols);
        const line = self.rowSliceMut(row);
        if (line[col].isContinuation() and col > 0) {
            if (line[col - 1].width == 2) line[col - 1] = blank;
            line[col] = blank;
        } else if (line[col].width == 2 and col + 1 < self.cols) {
            if (line[col + 1].isContinuation()) line[col + 1] = blank;
        }
    }
};

fn clampDim(val: u16, max_val: u16) u16 {
    return @min(@max(val, 1), max_val);
}

test "Grid putChar handles wide glyphs, orphan cleanup, and autowrap" {
    var g = try Grid.init(std.testing.allocator, 2, 5, 4);
    defer g.deinit();
    var cur: Cursor = .{};
    const modes: Modes = .{};

    g.putChar(&cur, &modes, 0x4E2D, 2);
    try std.testing.expectEqual(@as(u16, 2), cur.col);
    try std.testing.expect(g.cellAt(0, 1).isContinuation());

    cur.moveTo(0, 1, g.rows, g.cols);
    g.putChar(&cur, &modes, 'X', 1);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).cp);
    try std.testing.expectEqual(@as(u21, 'X'), g.cellAt(0, 1).cp);

    cur.moveTo(0, 4, g.rows, g.cols);
    g.putChar(&cur, &modes, 0x1F680, 2);
    try std.testing.expectEqual(@as(u16, 1), cur.row);
    try std.testing.expectEqual(@as(u16, 2), cur.col);
    try std.testing.expectEqual(@as(u21, 0x1F680), g.cellAt(1, 0).cp);
    try std.testing.expect(g.cellAt(1, 1).isContinuation());
}

test "Grid resize preserves cursor content, clips split wide chars, and archives top rows" {
    var g = try Grid.init(std.testing.allocator, 4, 6, 8);
    defer g.deinit();
    var cur: Cursor = .{};
    const modes: Modes = .{};

    cur.moveTo(0, 0, g.rows, g.cols);
    g.putChar(&cur, &modes, 'T', 1);
    cur.moveTo(3, 2, g.rows, g.cols);
    g.putChar(&cur, &modes, 0x4E2D, 2);

    try g.resize(2, 3, &cur);
    try std.testing.expectEqual(@as(u16, 2), g.rows);
    try std.testing.expectEqual(@as(u16, 3), g.cols);
    try std.testing.expectEqual(@as(u16, 1), cur.row);
    try std.testing.expectEqual(@as(u16, 2), cur.col);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(1, 2).cp);
    try std.testing.expectEqual(@as(usize, 2), g.scrollbackCount());
    try std.testing.expectEqual(@as(u21, 'T'), g.scrollbackLine(0)[0].cp);
}
