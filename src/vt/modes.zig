//! Terminal DEC/ANSI mode flags, Kitty keyboard flag stack, and cursor state
//! (including independent primary and alternate saved cursors).

const std = @import("std");
const assert = std.debug.assert;
const style_mod = @import("style.zig");

const Style = style_mod.Style;

/// Maximum depth of the Kitty keyboard protocol flag stack.
pub const max_kitty_stack: usize = 8;

/// Active terminal mouse reporting granularity.
pub const MouseMode = enum(u8) {
    none,
    x10,
    button,
    any,
};

/// Screen-level side effect triggered by toggling a DEC private mode.
pub const DecModeEffect = enum(u8) {
    none,
    enter_alt,
    enter_alt_clear,
    enter_alt_save,
    leave_alt,
    leave_alt_clear,
    leave_alt_restore,
    origin_changed,
};

/// Complete set of DEC private modes, ANSI modes, and Kitty keyboard stack.
pub const Modes = struct {
    /// DECCKM (`?1`): application cursor keys.
    cursor_keys_app: bool = false,
    /// DECOM (`?6`): cursor addressing relative to scroll region.
    origin_mode: bool = false,
    /// DECAWM (`?7`): automatic wraparound at right margin.
    autowrap: bool = true,
    /// DECTCEM (`?25`): cursor visibility.
    cursor_visible: bool = true,
    /// Active screen buffer (`?47` / `?1047` / `?1049`).
    alt_screen: bool = false,
    /// Mouse tracking mode (`?9`/`?1000`, `?1002`, `?1003`).
    mouse_mode: MouseMode = .none,
    /// SGR extended mouse coordinates (`?1006`).
    mouse_sgr: bool = false,
    /// Focus in/out reporting (`?1004`).
    focus_events: bool = false,
    /// Bracketed paste framing (`?2004`).
    bracketed_paste: bool = false,
    /// Synchronized output batching (`?2026`).
    sync_output: bool = false,
    /// ANSI IRM (`4`): insert characters instead of overwriting.
    insert_mode: bool = false,
    /// ANSI LNM (`20`): LF also implies CR.
    linefeed_mode: bool = false,
    /// Bounded Kitty keyboard protocol enhancement stack.
    kitty_stack: [max_kitty_stack]u8 = @splat(0),
    /// Number of active entries on `kitty_stack` (`0..=max_kitty_stack`).
    kitty_len: u8 = 0,

    /// Reset every mode flag and clear the Kitty keyboard stack.
    pub fn reset(self: *Modes) void {
        self.* = .{};
        assert(self.autowrap);
        assert(self.cursor_visible);
        assert(self.kitty_len == 0);
    }

    /// Return the active Kitty keyboard flags (top of stack, or 0 when empty).
    pub fn kittyFlags(self: *const Modes) u8 {
        assert(self.kitty_len <= max_kitty_stack);
        if (self.kitty_len == 0) return 0;
        return self.kitty_stack[self.kitty_len - 1];
    }

    /// Push `flags` onto the bounded Kitty keyboard stack (`CSI > flags u`).
    /// When full, the oldest entry is evicted to preserve the newest entries.
    pub fn pushKittyFlags(self: *Modes, flags: u8) void {
        assert(self.kitty_len <= max_kitty_stack);
        if (self.kitty_len < max_kitty_stack) {
            self.kitty_stack[self.kitty_len] = flags;
            self.kitty_len += 1;
        } else {
            for (1..max_kitty_stack) |i| {
                self.kitty_stack[i - 1] = self.kitty_stack[i];
            }
            self.kitty_stack[max_kitty_stack - 1] = flags;
        }
        assert(self.kitty_len <= max_kitty_stack);
        assert(self.kittyFlags() == flags);
    }

    /// Pop `count` entries from the Kitty keyboard stack (`CSI < count u`).
    pub fn popKittyFlags(self: *Modes, count: u16) void {
        assert(self.kitty_len <= max_kitty_stack);
        const pop_n: u8 = @intCast(@min(count, self.kitty_len));
        self.kitty_len -= pop_n;
        assert(self.kitty_len <= max_kitty_stack);
    }

    /// Modify the top Kitty keyboard stack entry (`CSI = flags ; mode u`).
    pub fn setKittyFlags(self: *Modes, flags: u8, mode: u16) void {
        assert(self.kitty_len <= max_kitty_stack);
        if (self.kitty_len == 0) {
            self.kitty_stack[0] = 0;
            self.kitty_len = 1;
        }
        const top = &self.kitty_stack[self.kitty_len - 1];
        switch (mode) {
            1 => top.* = flags,
            2 => top.* |= flags,
            3 => top.* &= ~flags,
            else => {},
        }
        assert(self.kitty_len >= 1 and self.kitty_len <= max_kitty_stack);
    }

    /// Apply an ANSI SM/RM mode parameter (`4` = IRM, `20` = LNM).
    pub fn applyAnsiMode(self: *Modes, param: u16, enabled: bool) void {
        switch (param) {
            4 => self.insert_mode = enabled,
            20 => self.linefeed_mode = enabled,
            else => {},
        }
    }

    /// Apply a DEC private mode (`DECSET`/`DECRST`) and return any required
    /// screen-switching or origin side effect for `Terminal` to execute.
    pub fn applyDecMode(self: *Modes, param: u16, enabled: bool) DecModeEffect {
        switch (param) {
            1 => self.cursor_keys_app = enabled,
            6 => {
                self.origin_mode = enabled;
                return .origin_changed;
            },
            7 => self.autowrap = enabled,
            25 => self.cursor_visible = enabled,
            47 => return if (enabled) .enter_alt else .leave_alt,
            9, 1000 => self.applyMouseMode(.x10, enabled),
            1002 => self.applyMouseMode(.button, enabled),
            1003 => self.applyMouseMode(.any, enabled),
            1004 => self.focus_events = enabled,
            1006 => self.mouse_sgr = enabled,
            1047 => return if (enabled) .enter_alt_clear else .leave_alt_clear,
            1049 => return if (enabled) .enter_alt_save else .leave_alt_restore,
            2004 => self.bracketed_paste = enabled,
            2026 => self.sync_output = enabled,
            else => {},
        }
        return .none;
    }

    fn applyMouseMode(self: *Modes, mode: MouseMode, enabled: bool) void {
        assert(mode != .none);
        if (enabled) {
            self.mouse_mode = mode;
        } else if (self.mouse_mode == mode) {
            self.mouse_mode = .none;
        }
    }
};

/// Snapshot of cursor coordinates, wrap state, style, and mode flags saved by DECSC.
pub const SavedCursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    pending_wrap: bool = false,
    style: Style = .{},
    origin_mode: bool = false,
    autowrap: bool = true,
};

/// Active terminal cursor plus separate primary and alternate saved cursors.
pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    pending_wrap: bool = false,
    style: Style = .{},
    saved_primary: SavedCursor = .{},
    saved_alt: SavedCursor = .{},

    /// Reset active and saved cursors to origin with default style.
    pub fn reset(self: *Cursor) void {
        self.* = .{};
        assert(self.row == 0 and self.col == 0);
        assert(!self.pending_wrap);
    }

    /// Save the active cursor into the primary or alternate slot.
    pub fn save(self: *Cursor, is_alt: bool, modes: *const Modes) void {
        const snapshot: SavedCursor = .{
            .row = self.row,
            .col = self.col,
            .pending_wrap = self.pending_wrap,
            .style = self.style,
            .origin_mode = modes.origin_mode,
            .autowrap = modes.autowrap,
        };
        if (is_alt) {
            self.saved_alt = snapshot;
        } else {
            self.saved_primary = snapshot;
        }
    }

    /// Restore the active cursor from the primary or alternate slot, clamped to `rows x cols`.
    pub fn restore(self: *Cursor, is_alt: bool, modes: *Modes, rows: u16, cols: u16) void {
        assert(rows >= 1 and cols >= 1);
        const snapshot = if (is_alt) self.saved_alt else self.saved_primary;
        self.row = snapshot.row;
        self.col = snapshot.col;
        self.pending_wrap = snapshot.pending_wrap;
        self.style = snapshot.style;
        modes.origin_mode = snapshot.origin_mode;
        modes.autowrap = snapshot.autowrap;
        self.clamp(rows, cols);
        assert(self.row < rows and self.col < cols);
    }

    /// Clamp cursor coordinates within `[0, rows)` and `[0, cols)`.
    pub fn clamp(self: *Cursor, rows: u16, cols: u16) void {
        assert(rows >= 1 and cols >= 1);
        if (self.row >= rows) self.row = rows - 1;
        if (self.col >= cols) {
            self.col = cols - 1;
            self.pending_wrap = false;
        }
        assert(self.row < rows and self.col < cols);
    }

    /// Move cursor to `(row, col)` clamped to grid dimensions and clear pending wrap.
    pub fn moveTo(self: *Cursor, row: u16, col: u16, rows: u16, cols: u16) void {
        assert(rows >= 1 and cols >= 1);
        self.row = @min(row, rows - 1);
        self.col = @min(col, cols - 1);
        self.pending_wrap = false;
        assert(self.row < rows and self.col < cols);
    }
};

test "Modes DEC and ANSI toggling and mouse mode precedence" {
    var m: Modes = .{};
    try std.testing.expect(m.autowrap);
    try std.testing.expect(m.cursor_visible);
    try std.testing.expectEqual(DecModeEffect.none, m.applyDecMode(1, true));
    try std.testing.expect(m.cursor_keys_app);
    try std.testing.expectEqual(DecModeEffect.origin_changed, m.applyDecMode(6, true));
    try std.testing.expect(m.origin_mode);
    try std.testing.expectEqual(DecModeEffect.enter_alt_save, m.applyDecMode(1049, true));

    _ = m.applyDecMode(1000, true);
    try std.testing.expectEqual(MouseMode.x10, m.mouse_mode);
    _ = m.applyDecMode(1003, true);
    try std.testing.expectEqual(MouseMode.any, m.mouse_mode);
    // Disabling x10 does not clobber active .any mode.
    _ = m.applyDecMode(1000, false);
    try std.testing.expectEqual(MouseMode.any, m.mouse_mode);
    _ = m.applyDecMode(1003, false);
    try std.testing.expectEqual(MouseMode.none, m.mouse_mode);

    m.applyAnsiMode(4, true);
    m.applyAnsiMode(20, true);
    try std.testing.expect(m.insert_mode);
    try std.testing.expect(m.linefeed_mode);
}

test "Kitty keyboard stack stays bounded to 8 entries" {
    var m: Modes = .{};
    try std.testing.expectEqual(@as(u8, 0), m.kittyFlags());
    for (1..12) |v| m.pushKittyFlags(@intCast(v));
    try std.testing.expectEqual(@as(u8, max_kitty_stack), m.kitty_len);
    try std.testing.expectEqual(@as(u8, 11), m.kittyFlags());

    m.setKittyFlags(0x20, 2); // OR
    try std.testing.expectEqual(@as(u8, 11 | 0x20), m.kittyFlags());
    m.setKittyFlags(0x20, 3); // AND-NOT
    try std.testing.expectEqual(@as(u8, 11), m.kittyFlags());

    m.popKittyFlags(3);
    try std.testing.expectEqual(@as(u8, 5), m.kitty_len);
    try std.testing.expectEqual(@as(u8, 8), m.kittyFlags());

    m.popKittyFlags(99);
    try std.testing.expectEqual(@as(u8, 0), m.kitty_len);
    try std.testing.expectEqual(@as(u8, 0), m.kittyFlags());
}

test "Cursor saves and restores primary and alt slots independently" {
    var m: Modes = .{};
    var c: Cursor = .{};
    c.moveTo(5, 12, 24, 80);
    c.style.attr.bold = true;
    c.save(false, &m);

    c.moveTo(1, 2, 24, 80);
    c.style = Style.default;
    c.save(true, &m);

    c.moveTo(20, 70, 24, 80);
    c.restore(true, &m, 24, 80);
    try std.testing.expectEqual(@as(u16, 1), c.row);
    try std.testing.expectEqual(@as(u16, 2), c.col);
    try std.testing.expect(!c.style.attr.bold);

    // Clamping on smaller viewport during restore.
    c.restore(false, &m, 4, 10);
    try std.testing.expectEqual(@as(u16, 3), c.row);
    try std.testing.expectEqual(@as(u16, 9), c.col);
    try std.testing.expect(c.style.attr.bold);
}
