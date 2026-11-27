//! Full VT100/xterm/ECMA-48/OSC terminal emulator state engine combining the
//! streaming parser, primary/alternate cell grids, mode flags, tab stops, and
//! bounded OSC metadata store.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const style_mod = @import("style.zig");
const modes_mod = @import("modes.zig");
const osc_mod = @import("osc.zig");
const grid_mod = @import("grid.zig");
const parser_mod = @import("parser.zig");
const snapshot_mod = @import("snapshot.zig");

const Style = style_mod.Style;
const Cursor = modes_mod.Cursor;
const Modes = modes_mod.Modes;
const DecModeEffect = modes_mod.DecModeEffect;
const OscState = osc_mod.OscState;
const EventCallback = osc_mod.EventCallback;
const Grid = grid_mod.Grid;
const Parser = parser_mod.Parser;
const CsiEvent = parser_mod.CsiEvent;
const ScreenOptions = snapshot_mod.ScreenOptions;

/// Configuration options for creating a `Terminal` instance.
pub const Options = struct {
    /// Initial viewport height in rows (clamped to `[1, 512]`).
    rows: u16 = 24,
    /// Initial viewport width in columns (clamped to `[1, 512]`).
    cols: u16 = 80,
    /// Maximum scrollback lines retained on the primary screen (`0` disables).
    scrollback_lines: usize = grid_mod.default_scrollback,
    /// Optional synchronous hook for OSC and bell events.
    callback: ?EventCallback = null,
};

/// Zero-dependency VT100/xterm/ECMA-48/OSC terminal emulator state machine.
pub const Terminal = struct {
    allocator: Allocator,
    primary: Grid,
    alt: Grid,
    modes: Modes = .{},
    cur: Cursor = .{},
    osc: OscState,
    parser: Parser = .{},
    callback: ?EventCallback = null,
    tab_stops: []bool,
    last_cp: u21 = ' ',
    has_last_cp: bool = false,

    /// Allocate a new terminal with primary grid, alt grid, and default 8-col tab stops.
    pub fn init(allocator: Allocator, opts: Options) !Terminal {
        var primary = try Grid.init(allocator, opts.rows, opts.cols, opts.scrollback_lines);
        errdefer primary.deinit();

        var alt = try Grid.init(allocator, opts.rows, opts.cols, 0);
        errdefer alt.deinit();

        const tab_stops = try allocDefaultTabStops(allocator, primary.cols);
        assert(primary.rows == alt.rows and primary.cols == alt.cols);
        assert(tab_stops.len == primary.cols);
        return .{
            .allocator = allocator,
            .primary = primary,
            .alt = alt,
            .osc = OscState.init(allocator),
            .callback = opts.callback,
            .tab_stops = tab_stops,
        };
    }

    /// Release all grids, scrollback history, OSC buffers, parser buffer, and tab stops.
    pub fn deinit(self: *Terminal) void {
        assert(self.primary.rows == self.alt.rows);
        assert(self.tab_stops.len == self.primary.cols);
        self.allocator.free(self.tab_stops);
        self.parser.deinit(self.allocator);
        self.osc.deinit();
        self.alt.deinit();
        self.primary.deinit();
        self.* = undefined;
    }

    /// Feed raw PTY output bytes into the terminal state machine.
    pub fn feed(self: *Terminal, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.parser.feed(self.allocator, bytes, self);
        assert(self.cur.row < self.rows() and self.cur.col < self.cols());
    }

    /// Atomically resize primary grid, alt grid, and tab stops to `new_rows x new_cols`.
    /// On OOM, existing dimensions and state remain completely intact.
    pub fn resize(self: *Terminal, new_rows: u16, new_cols: u16) !void {
        const p_bufs = try Grid.prepareResize(self.allocator, new_rows, new_cols);
        errdefer p_bufs.deinit(self.allocator);

        const a_bufs = try Grid.prepareResize(self.allocator, new_rows, new_cols);
        errdefer a_bufs.deinit(self.allocator);

        const next_tabs = try allocDefaultTabStops(self.allocator, p_bufs.cols);
        const copy_tabs = @min(self.tab_stops.len, next_tabs.len);
        @memcpy(next_tabs[0..copy_tabs], self.tab_stops[0..copy_tabs]);

        var dummy_cur: Cursor = .{};
        if (self.modes.alt_screen) {
            self.primary.applyResize(p_bufs, &dummy_cur);
            self.alt.applyResize(a_bufs, &self.cur);
        } else {
            self.primary.applyResize(p_bufs, &self.cur);
            self.alt.applyResize(a_bufs, &dummy_cur);
        }
        self.allocator.free(self.tab_stops);
        self.tab_stops = next_tabs;
        assert(self.primary.rows == self.alt.rows and self.primary.cols == self.alt.cols);
        assert(self.cur.row < self.rows() and self.cur.col < self.cols());
    }

    /// Execute RIS (full terminal reset): clear screens, scrollback, modes, cursor, and OSC.
    pub fn reset(self: *Terminal) void {
        self.primary.clearAll(Style.default);
        self.primary.clearScrollback();
        self.primary.resetScrollRegion();
        self.alt.clearAll(Style.default);
        self.alt.resetScrollRegion();
        self.modes.reset();
        self.cur.reset();
        self.osc.reset();
        self.parser.reset();
        resetTabStops(self.tab_stops);
        self.last_cp = ' ';
        self.has_last_cp = false;
        assert(!self.modes.alt_screen);
        assert(self.cur.row == 0 and self.cur.col == 0);
    }

    /// Return a copy of the active cursor state.
    pub fn cursor(self: *const Terminal) Cursor {
        assert(self.cur.row < self.rows() and self.cur.col < self.cols());
        return self.cur;
    }

    /// Return true when the alternate screen buffer is active.
    pub fn isAltScreen(self: *const Terminal) bool {
        return self.modes.alt_screen;
    }

    /// Return the active viewport height in rows.
    pub fn rows(self: *const Terminal) u16 {
        assert(self.primary.rows == self.alt.rows);
        return self.primary.rows;
    }

    /// Return the active viewport width in columns.
    pub fn cols(self: *const Terminal) u16 {
        assert(self.primary.cols == self.alt.cols);
        return self.primary.cols;
    }

    /// Return a read-only pointer to whichever grid (primary or alt) is active.
    pub fn activeGrid(self: *const Terminal) *const Grid {
        return if (self.modes.alt_screen) &self.alt else &self.primary;
    }

    /// Return a mutable pointer to whichever grid (primary or alt) is active.
    pub fn activeGridMut(self: *Terminal) *Grid {
        return if (self.modes.alt_screen) &self.alt else &self.primary;
    }

    /// Render the screen (and optional scrollback lines) as clean trimmed plain text.
    pub fn plainText(self: *const Terminal, allocator: Allocator, opts: ScreenOptions) ![]u8 {
        return snapshot_mod.renderPlainText(self, allocator, opts);
    }

    /// Render a self-contained ANSI/DEC restore sequence for reattaching clients.
    pub fn ansiRestore(self: *const Terminal, allocator: Allocator) ![]u8 {
        return snapshot_mod.renderAnsiRestore(self, allocator);
    }

    /// Stream a structured JSON snapshot of viewport state, metadata, and text.
    pub fn writeScreenJson(self: *const Terminal, writer: *std.Io.Writer, opts: ScreenOptions) !void {
        return snapshot_mod.writeScreenJson(self, writer, opts);
    }

    /// Parser callback: print one decoded Unicode codepoint to the active grid.
    pub fn print(self: *Terminal, cp: u21) void {
        const w = style_mod.wcwidth(cp);
        if (w == 0) return;
        self.activeGridMut().putChar(&self.cur, &self.modes, cp, w);
        self.last_cp = cp;
        self.has_last_cp = true;
    }

    /// Parser callback: execute one C0 control byte.
    pub fn execute(self: *Terminal, byte: u8) void {
        switch (byte) {
            0x07 => EventCallback.emit(self.callback, .bell),
            0x08 => {
                if (self.cur.col > 0) self.cur.col -= 1;
                self.cur.pending_wrap = false;
            },
            0x09 => self.horizontalTab(),
            0x0A, 0x0B, 0x0C => {
                self.indexDown();
                if (self.modes.linefeed_mode) self.cur.col = 0;
            },
            0x0D => {
                self.cur.col = 0;
                self.cur.pending_wrap = false;
            },
            else => {},
        }
    }

    /// Parser callback: execute an ESC sequence.
    pub fn escDispatch(self: *Terminal, intermediates: []const u8, final: u8) void {
        if (intermediates.len > 0) return;
        switch (final) {
            '7' => self.cur.save(self.modes.alt_screen, &self.modes),
            '8' => self.cur.restore(self.modes.alt_screen, &self.modes, self.rows(), self.cols()),
            'D' => self.indexDown(),
            'E' => {
                self.cur.col = 0;
                self.indexDown();
            },
            'M' => self.reverseIndex(),
            'H' => {
                assert(self.cur.col < self.tab_stops.len);
                self.tab_stops[self.cur.col] = true;
            },
            'c' => self.reset(),
            else => {},
        }
    }

    /// Parser callback: execute a decoded CSI sequence.
    pub fn csiDispatch(self: *Terminal, ev: CsiEvent) void {
        if (ev.intermediates.len > 0) return;
        if (ev.private != 0) {
            self.csiPrivate(ev);
            return;
        }
        if (self.csiCursor(ev)) return;
        self.csiEditAndMode(ev);
    }

    /// Parser callback: dispatch one completed OSC payload.
    pub fn oscDispatch(self: *Terminal, payload: []const u8) void {
        self.osc.handle(payload, self.callback);
    }

    fn csiCursor(self: *Terminal, ev: CsiEvent) bool {
        const g = self.activeGridMut();
        switch (ev.final) {
            'A' => self.moveUp(ev.param(0, 1)),
            'B', 'e' => self.moveDown(ev.param(0, 1)),
            'C', 'a' => {
                self.cur.col = @min(self.cur.col +| ev.param(0, 1), g.cols - 1);
                self.cur.pending_wrap = false;
            },
            'D' => {
                self.cur.col -|= ev.param(0, 1);
                self.cur.pending_wrap = false;
            },
            'E' => {
                self.moveDown(ev.param(0, 1));
                self.cur.col = 0;
            },
            'F' => {
                self.moveUp(ev.param(0, 1));
                self.cur.col = 0;
            },
            'G', '`' => {
                self.cur.col = @min(ev.param(0, 1) - 1, g.cols - 1);
                self.cur.pending_wrap = false;
            },
            'H', 'f' => self.cursorPosition(ev.param(0, 1), ev.param(1, 1)),
            'd' => self.cursorVertical(ev.param(0, 1)),
            's' => self.cur.save(self.modes.alt_screen, &self.modes),
            'u' => self.cur.restore(self.modes.alt_screen, &self.modes, g.rows, g.cols),
            else => return false,
        }
        return true;
    }

    fn csiEditAndMode(self: *Terminal, ev: CsiEvent) void {
        const g = self.activeGridMut();
        switch (ev.final) {
            'J' => g.eraseDisplay(ev.param(0, 0), self.cur.row, self.cur.col, self.cur.style),
            'K' => g.eraseLine(ev.param(0, 0), self.cur.row, self.cur.col, self.cur.style),
            'X' => g.eraseChars(self.cur.row, self.cur.col, ev.param(0, 1), self.cur.style),
            'L' => {
                g.insertLines(self.cur.row, ev.param(0, 1), self.cur.style);
                self.cur.col = 0;
                self.cur.pending_wrap = false;
            },
            'M' => {
                g.deleteLines(self.cur.row, ev.param(0, 1), self.cur.style);
                self.cur.col = 0;
                self.cur.pending_wrap = false;
            },
            '@' => g.insertChars(self.cur.row, self.cur.col, ev.param(0, 1), self.cur.style),
            'P' => g.deleteChars(self.cur.row, self.cur.col, ev.param(0, 1), self.cur.style),
            'S' => g.scrollUp(ev.param(0, 1), self.cur.style),
            'T' => g.scrollDown(ev.param(0, 1), self.cur.style),
            'm' => style_mod.applySgr(&self.cur.style, ev.params),
            'r' => self.setScrollMargins(ev),
            'h', 'l' => {
                const enabled = ev.final == 'h';
                for (ev.params) |p| self.modes.applyAnsiMode(p.value, enabled);
            },
            'b' => self.repeatLastChar(ev.param(0, 1)),
            'g' => self.clearTabStops(ev.param(0, 0)),
            else => {},
        }
    }

    fn csiPrivate(self: *Terminal, ev: CsiEvent) void {
        if (ev.private == '?' and (ev.final == 'h' or ev.final == 'l')) {
            const enabled = ev.final == 'h';
            for (ev.params) |p| {
                const effect = self.modes.applyDecMode(p.value, enabled);
                self.applyDecEffect(effect);
            }
            return;
        }
        if (ev.final == 'u') {
            switch (ev.private) {
                '>' => self.modes.pushKittyFlags(@intCast(@min(ev.rawParam(0, 0), 255))),
                '<' => self.modes.popKittyFlags(ev.param(0, 1)),
                '=' => self.modes.setKittyFlags(@intCast(@min(ev.rawParam(0, 0), 255)), ev.param(1, 1)),
                else => {},
            }
        }
    }

    fn applyDecEffect(self: *Terminal, effect: DecModeEffect) void {
        switch (effect) {
            .none => {},
            .origin_changed => self.homeCursor(),
            .enter_alt => self.modes.alt_screen = true,
            .enter_alt_clear => {
                self.modes.alt_screen = true;
                self.alt.clearAll(self.cur.style);
                self.alt.resetScrollRegion();
            },
            .enter_alt_save => {
                if (!self.modes.alt_screen) self.cur.save(false, &self.modes);
                self.modes.alt_screen = true;
                self.alt.clearAll(self.cur.style);
                self.alt.resetScrollRegion();
                self.cur.moveTo(0, 0, self.rows(), self.cols());
            },
            .leave_alt => self.modes.alt_screen = false,
            .leave_alt_clear => {
                self.alt.clearAll(self.cur.style);
                self.modes.alt_screen = false;
            },
            .leave_alt_restore => {
                if (self.modes.alt_screen) {
                    self.modes.alt_screen = false;
                    self.cur.restore(false, &self.modes, self.rows(), self.cols());
                }
            },
        }
        self.cur.clamp(self.rows(), self.cols());
    }

    fn moveUp(self: *Terminal, n: u16) void {
        const g = self.activeGrid();
        const top = if (self.cur.row >= g.scroll_top) g.scroll_top else 0;
        self.cur.row = if (self.cur.row > top + n) self.cur.row - n else top;
        self.cur.pending_wrap = false;
    }

    fn moveDown(self: *Terminal, n: u16) void {
        const g = self.activeGrid();
        const bot = if (self.cur.row <= g.scroll_bottom) g.scroll_bottom else g.rows - 1;
        self.cur.row = @min(self.cur.row +| n, bot);
        self.cur.pending_wrap = false;
    }

    fn cursorPosition(self: *Terminal, row_1: u16, col_1: u16) void {
        assert(row_1 >= 1 and col_1 >= 1);
        const g = self.activeGrid();
        const col = @min(col_1 - 1, g.cols - 1);
        const row = if (self.modes.origin_mode)
            @min(g.scroll_top +| (row_1 - 1), g.scroll_bottom)
        else
            @min(row_1 - 1, g.rows - 1);
        self.cur.moveTo(row, col, g.rows, g.cols);
    }

    fn cursorVertical(self: *Terminal, row_1: u16) void {
        assert(row_1 >= 1);
        const g = self.activeGrid();
        const row = if (self.modes.origin_mode)
            @min(g.scroll_top +| (row_1 - 1), g.scroll_bottom)
        else
            @min(row_1 - 1, g.rows - 1);
        self.cur.row = row;
        self.cur.pending_wrap = false;
    }

    fn homeCursor(self: *Terminal) void {
        const g = self.activeGrid();
        const row = if (self.modes.origin_mode) g.scroll_top else 0;
        self.cur.moveTo(row, 0, g.rows, g.cols);
    }

    fn setScrollMargins(self: *Terminal, ev: CsiEvent) void {
        const g = self.activeGridMut();
        const top = ev.param(0, 1) - 1;
        const bot = ev.param(1, g.rows) - 1;
        if (top == 0 and bot + 1 >= g.rows) {
            g.resetScrollRegion();
        } else {
            g.setScrollRegion(top, bot);
        }
        self.homeCursor();
    }

    fn indexDown(self: *Terminal) void {
        const g = self.activeGridMut();
        if (self.cur.row == g.scroll_bottom) {
            g.scrollUp(1, self.cur.style);
        } else if (self.cur.row + 1 < g.rows) {
            self.cur.row += 1;
        }
        self.cur.pending_wrap = false;
    }

    fn reverseIndex(self: *Terminal) void {
        const g = self.activeGridMut();
        if (self.cur.row == g.scroll_top) {
            g.scrollDown(1, self.cur.style);
        } else if (self.cur.row > 0) {
            self.cur.row -= 1;
        }
        self.cur.pending_wrap = false;
    }

    fn horizontalTab(self: *Terminal) void {
        const cols_n = self.cols();
        assert(self.tab_stops.len == cols_n);
        var next = self.cur.col + 1;
        while (next < cols_n and !self.tab_stops[next]) : (next += 1) {}
        self.cur.col = @min(next, cols_n - 1);
        self.cur.pending_wrap = false;
    }

    fn clearTabStops(self: *Terminal, mode: u16) void {
        assert(self.cur.col < self.tab_stops.len);
        if (mode == 0) {
            self.tab_stops[self.cur.col] = false;
        } else if (mode == 3) {
            @memset(self.tab_stops, false);
        }
    }

    fn repeatLastChar(self: *Terminal, count: u16) void {
        if (!self.has_last_cp) return;
        const max_rep = @as(usize, self.rows()) * @as(usize, self.cols());
        const n = @min(@as(usize, count), max_rep);
        const w = style_mod.wcwidth(self.last_cp);
        if (w == 0) return;
        for (0..n) |_| {
            self.activeGridMut().putChar(&self.cur, &self.modes, self.last_cp, w);
        }
    }
};

fn allocDefaultTabStops(allocator: Allocator, cols: u16) ![]bool {
    assert(cols >= 1);
    const stops = try allocator.alloc(bool, cols);
    resetTabStops(stops);
    return stops;
}

fn resetTabStops(stops: []bool) void {
    for (stops, 0..) |*slot, col| {
        slot.* = (col > 0 and col % 8 == 0);
    }
}

test "Terminal resolves CR overwrite, tabs, REP, and scroll regions" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 20 });
    defer term.deinit();

    term.feed("loading...\rDONE!\n\tX\x1b[3b");
    const txt = try term.plainText(std.testing.allocator, .{});
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("DONE!ng...\n        XXXX", txt);
}

test "Terminal alt screen 1049 preserves primary grid and cursor" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 12 });
    defer term.deinit();

    term.feed("primary\x1b[2;4H");
    term.feed("\x1b[?1049hALT SCREEN");
    try std.testing.expect(term.isAltScreen());
    const alt_txt = try term.plainText(std.testing.allocator, .{});
    defer std.testing.allocator.free(alt_txt);
    try std.testing.expectEqualStrings("ALT SCREEN", alt_txt);

    term.feed("\x1b[?1049l");
    try std.testing.expect(!term.isAltScreen());
    try std.testing.expectEqual(@as(u16, 1), term.cursor().row);
    try std.testing.expectEqual(@as(u16, 3), term.cursor().col);
    const pri_txt = try term.plainText(std.testing.allocator, .{});
    defer std.testing.allocator.free(pri_txt);
    try std.testing.expectEqualStrings("primary", pri_txt);
}

test "Terminal handles DECSTBM + origin mode + RI/IND + DECSC/DECRC" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 10 });
    defer term.deinit();

    term.feed("r0\r\nr1\r\nr2\r\nr3");
    // Scroll region rows 2..3 (1-based), origin mode on, reverse index inserts blank at row 1.
    term.feed("\x1b[2;3r\x1b[?6h\x1b[1;1H\x1bMNEW");
    const txt = try term.plainText(std.testing.allocator, .{});
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("r0\nNEW\nr1\nr3", txt);
}

test "Terminal resize is atomic under OOM and preserves content" {
    var term = try Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 10 });
    defer term.deinit();
    term.feed("hello\r\nworld");

    try term.resize(6, 12);
    try std.testing.expectEqual(@as(u16, 6), term.rows());
    try std.testing.expectEqual(@as(u16, 12), term.cols());

    // Simulate OOM on every possible allocation inside resize.
    for (0..3) |fail_idx| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_idx });
        var oom_term = try Terminal.init(std.testing.allocator, .{ .rows = 3, .cols = 6 });
        defer oom_term.deinit();
        const orig_alloc = oom_term.allocator;
        oom_term.allocator = failing.allocator();
        const res = oom_term.resize(8, 12);
        oom_term.allocator = orig_alloc;
        try std.testing.expectError(error.OutOfMemory, res);
        try std.testing.expectEqual(@as(u16, 3), oom_term.rows());
        try std.testing.expectEqual(@as(u16, 3), oom_term.alt.rows);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}
