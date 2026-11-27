//! Bounded reusable-line scrollback ring buffer owned by primary terminal grids.
//! Steady-state scrolling after fill reuses existing line buffers with zero
//! allocations per scrolled-off row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const style_mod = @import("style.zig");

const Cell = style_mod.Cell;

/// Default primary-screen scrollback ring capacity in lines.
pub const default_scrollback: usize = 2000;
/// Hard upper bound on scrollback ring capacity in lines.
pub const max_scrollback: usize = 100_000;

/// One trimmed line stored in the bounded scrollback ring buffer.
pub const ScrollbackLine = struct {
    buf: []Cell = &.{},
    len: u16 = 0,
    wrapped: bool = false,

    /// Return the populated cells of this scrollback line.
    pub fn slice(self: *const ScrollbackLine) []const Cell {
        assert(self.len <= self.buf.len);
        return self.buf[0..self.len];
    }
};

/// Fixed-capacity ring of `ScrollbackLine` slots with buffer reuse on wrap.
pub const ScrollbackRing = struct {
    allocator: Allocator,
    slots: []ScrollbackLine = &.{},
    head: usize = 0,
    len: usize = 0,
    oom_drops: u64 = 0,

    /// Allocate a ring holding up to `capacity` lines (clamped to `max_scrollback`).
    /// Passing `0` creates a zero-allocation disabled ring (used by alternate screens).
    pub fn init(allocator: Allocator, capacity: usize) !ScrollbackRing {
        const cap = @min(capacity, max_scrollback);
        const slots: []ScrollbackLine = if (cap > 0)
            try allocator.alloc(ScrollbackLine, cap)
        else
            &.{};
        if (cap > 0) @memset(slots, .{});
        assert(slots.len == cap);
        return .{ .allocator = allocator, .slots = slots };
    }

    /// Release all per-slot cell buffers and the slot slice itself.
    pub fn deinit(self: *ScrollbackRing) void {
        assert(self.len <= self.slots.len);
        for (self.slots) |slot| {
            if (slot.buf.len > 0) self.allocator.free(slot.buf);
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Return true when scrollback recording is enabled (`capacity > 0`).
    pub fn isEnabled(self: *const ScrollbackRing) bool {
        return self.slots.len > 0;
    }

    /// Return the number of currently retained scrollback lines.
    pub fn count(self: *const ScrollbackRing) usize {
        assert(self.len <= self.slots.len);
        return self.len;
    }

    /// Return line `idx` (`0` = oldest retained line, `count() - 1` = newest).
    pub fn line(self: *const ScrollbackRing, idx: usize) []const Cell {
        assert(idx < self.len);
        const slot_idx = (self.head + idx) % self.slots.len;
        return self.slots[slot_idx].slice();
    }

    /// Return whether line `idx` soft-wrapped onto the following line.
    pub fn wrapped(self: *const ScrollbackRing, idx: usize) bool {
        assert(idx < self.len);
        const slot_idx = (self.head + idx) % self.slots.len;
        return self.slots[slot_idx].wrapped;
    }

    /// Discard retained lines while preserving already-allocated slot buffers for reuse.
    pub fn clear(self: *ScrollbackRing) void {
        self.head = 0;
        self.len = 0;
        assert(self.len == 0);
    }

    /// Push one viewport row into the ring, trimming trailing default-blank cells
    /// and evicting the oldest line when full.
    pub fn push(self: *ScrollbackRing, row: []const Cell, is_wrapped: bool, min_alloc_cols: u16) void {
        if (self.slots.len == 0) return;
        var trimmed_len = row.len;
        while (trimmed_len > 0 and row[trimmed_len - 1].isDefaultBlank()) {
            trimmed_len -= 1;
        }

        const slot_idx = if (self.len < self.slots.len) blk: {
            const idx = (self.head + self.len) % self.slots.len;
            self.len += 1;
            break :blk idx;
        } else blk: {
            const idx = self.head;
            self.head = (self.head + 1) % self.slots.len;
            break :blk idx;
        };

        const slot = &self.slots[slot_idx];
        slot.wrapped = is_wrapped;
        if (trimmed_len == 0) {
            slot.len = 0;
            return;
        }
        if (slot.buf.len < trimmed_len) {
            const alloc_len = @max(trimmed_len, min_alloc_cols);
            const next = self.allocator.alloc(Cell, alloc_len) catch {
                self.oom_drops += 1;
                slot.len = 0;
                return;
            };
            if (slot.buf.len > 0) self.allocator.free(slot.buf);
            slot.buf = next;
        }
        @memcpy(slot.buf[0..trimmed_len], row[0..trimmed_len]);
        slot.len = @intCast(trimmed_len);
        assert(self.len <= self.slots.len);
    }
};

test "ScrollbackRing trims trailing blanks, evicts oldest, and clears cleanly" {
    var ring = try ScrollbackRing.init(std.testing.allocator, 2);
    defer ring.deinit();

    var row_a = [_]Cell{ .{ .cp = 'A' }, Cell.blank, Cell.blank };
    var row_b = [_]Cell{ .{ .cp = 'B' }, .{ .cp = '2' }, Cell.blank };
    var row_c = [_]Cell{ Cell.blank, Cell.blank, Cell.blank };

    ring.push(&row_a, false, 3);
    ring.push(&row_b, true, 3);
    ring.push(&row_c, false, 3);

    try std.testing.expectEqual(@as(usize, 2), ring.count());
    try std.testing.expectEqual(@as(usize, 2), ring.line(0).len);
    try std.testing.expectEqual(@as(u21, 'B'), ring.line(0)[0].cp);
    try std.testing.expect(ring.wrapped(0));
    try std.testing.expectEqual(@as(usize, 0), ring.line(1).len);

    ring.clear();
    try std.testing.expectEqual(@as(usize, 0), ring.count());
}

test "ScrollbackRing disabled when capacity is zero and handles OOM gracefully" {
    var disabled = try ScrollbackRing.init(std.testing.allocator, 0);
    defer disabled.deinit();
    try std.testing.expect(!disabled.isEnabled());
    var row = [_]Cell{.{ .cp = 'Z' }};
    disabled.push(&row, false, 1);
    try std.testing.expectEqual(@as(usize, 0), disabled.count());

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var ring = try ScrollbackRing.init(failing.allocator(), 2);
    defer ring.deinit();
    ring.push(&row, false, 4);
    try std.testing.expectEqual(@as(u64, 1), ring.oom_drops);
    try std.testing.expectEqual(@as(usize, 0), ring.line(0).len);
}
