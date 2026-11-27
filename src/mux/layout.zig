//! Binary layout tree of a window and its split axis.

const std = @import("std");

const mux = @import("../mux.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;

/// Split direction of a layout node.
pub const Axis = enum {
    horizontal,
    vertical,

    pub fn label(self: Axis) []const u8 {
        return @tagName(self);
    }
};

/// Binary layout tree of a window: leaves hold pane ids, splits hold two
/// children and an axis.
pub const LayoutNode = union(enum) {
    leaf: []u8,
    split: Split,

    const RemoveLeafResult = enum {
        not_found,
        removed,
        self_is_target,
    };

    pub const Split = struct {
        id: []u8,
        axis: Axis,
        ratio: f32 = 0.5,
        first: *LayoutNode,
        second: *LayoutNode,
    };

    pub const LeafHit = struct {
        node: *LayoutNode,
        /// Number of splits above the leaf; a root leaf has depth 0.
        depth: usize,
    };

    pub fn leafNode(allocator: Allocator, pane_id: []const u8) !*LayoutNode {
        const node = try allocator.create(LayoutNode);
        errdefer allocator.destroy(node);
        node.* = .{ .leaf = try allocator.dupe(u8, pane_id) };
        return node;
    }

    pub fn deinit(self: *LayoutNode, allocator: Allocator) void {
        switch (self.*) {
            .leaf => |pane_id| allocator.free(pane_id),
            .split => |split| {
                assert(split.first != split.second);
                allocator.free(split.id);
                split.first.deinit(allocator);
                allocator.destroy(split.first);
                split.second.deinit(allocator);
                allocator.destroy(split.second);
            },
        }
    }

    /// Recursion depth is bounded by `Limits.max_layout_depth`.
    pub fn findLeaf(self: *LayoutNode, pane_id: []const u8, depth: usize) ?LeafHit {
        switch (self.*) {
            .leaf => |existing| {
                if (!std.mem.eql(u8, existing, pane_id)) return null;
                return .{ .node = self, .depth = depth };
            },
            .split => |split| {
                assert(split.first != split.second);
                return split.first.findLeaf(pane_id, depth + 1) orelse split.second.findLeaf(pane_id, depth + 1);
            },
        }
    }

    /// Replaces the leaf `target_pane_id` with a split of copies of the leaf
    /// and `new_pane_id`. Returns false, allocating nothing, when the leaf is
    /// absent. OutOfMemory leaves the tree unchanged.
    pub fn replaceLeafWithSplit(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        new_pane_id: []const u8,
        split_id: []const u8,
    ) !bool {
        if (self.findLeaf(target_pane_id, 0) == null) return false;
        const first = try LayoutNode.leafNode(allocator, target_pane_id);
        errdefer {
            first.deinit(allocator);
            allocator.destroy(first);
        }
        const second = try LayoutNode.leafNode(allocator, new_pane_id);
        errdefer {
            second.deinit(allocator);
            allocator.destroy(second);
        }
        const owned_split_id = try allocator.dupe(u8, split_id);
        // The leaf was found above and nothing since touched the tree.
        const replaced = self.replaceLeafWithSplitOwned(allocator, target_pane_id, axis, owned_split_id, first, second);
        assert(replaced);
        return replaced;
    }

    /// Like `replaceLeafWithSplit`, but takes ownership of `split_id`,
    /// `first`, and `second` only when it returns true. Never allocates.
    pub fn replaceLeafWithSplitOwned(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        split_id: []u8,
        first: *LayoutNode,
        second: *LayoutNode,
    ) bool {
        assert(first != second);
        assert(first != self);
        assert(second != self);
        const hit = self.findLeaf(target_pane_id, 0) orelse return false;
        assert(hit.node.* == .leaf);
        allocator.free(hit.node.leaf);
        hit.node.* = .{ .split = .{ .id = split_id, .axis = axis, .first = first, .second = second } };
        return true;
    }

    pub fn removeLeaf(self: *LayoutNode, allocator: Allocator, pane_id: []const u8) bool {
        return self.removeLeafInternal(allocator, pane_id) != .not_found;
    }

    fn removeLeafInternal(self: *LayoutNode, allocator: Allocator, pane_id: []const u8) RemoveLeafResult {
        switch (self.*) {
            .leaf => |existing| return if (std.mem.eql(u8, existing, pane_id)) .self_is_target else .not_found,
            .split => |split| {
                assert(split.first != split.second);
                switch (split.first.removeLeafInternal(allocator, pane_id)) {
                    .self_is_target => {
                        const replacement = split.second.*;
                        split.first.deinit(allocator);
                        allocator.destroy(split.first);
                        allocator.free(split.id);
                        allocator.destroy(split.second);
                        self.* = replacement;
                        return .removed;
                    },
                    .removed => return .removed,
                    .not_found => {},
                }
                switch (split.second.removeLeafInternal(allocator, pane_id)) {
                    .self_is_target => {
                        const replacement = split.first.*;
                        split.second.deinit(allocator);
                        allocator.destroy(split.second);
                        allocator.free(split.id);
                        allocator.destroy(split.first);
                        self.* = replacement;
                        return .removed;
                    },
                    .removed => return .removed,
                    .not_found => {},
                }
                return .not_found;
            },
        }
    }

    /// Find the split node matching `split_id`, or null if absent.
    pub fn findSplit(self: *LayoutNode, split_id: []const u8) ?*Split {
        switch (self.*) {
            .leaf => return null,
            .split => |*split| {
                if (std.mem.eql(u8, split.id, split_id)) return split;
                return split.first.findSplit(split_id) orelse split.second.findSplit(split_id);
            },
        }
    }

    /// Find the innermost split node containing leaf `pane_id`, or null when root leaf.
    pub fn findParentSplit(self: *LayoutNode, pane_id: []const u8) ?*Split {
        switch (self.*) {
            .leaf => return null,
            .split => |*split| {
                if (split.first.findParentSplit(pane_id)) |hit| return hit;
                if (split.second.findParentSplit(pane_id)) |hit| return hit;
                if (layoutContainsPane(split.first, pane_id) or layoutContainsPane(split.second, pane_id)) {
                    return split;
                }
                return null;
            },
        }
    }

    pub fn writeJson(self: *const LayoutNode, writer: *std.Io.Writer) !void {
        switch (self.*) {
            .leaf => |pane_id| {
                try writer.print("{{\"kind\":\"leaf\",\"paneId\":{f}}}", .{std.json.fmt(pane_id, .{})});
            },
            .split => |split| {
                assert(split.first != split.second);
                try writer.print(
                    "{{\"kind\":\"split\",\"id\":{f},\"axis\":{f},\"ratio\":",
                    .{ std.json.fmt(split.id, .{}), std.json.fmt(split.axis.label(), .{}) },
                );
                try writeRatioJson(writer, split.ratio);
                try writer.writeAll(",\"first\":");
                try split.first.writeJson(writer);
                try writer.writeAll(",\"second\":");
                try split.second.writeJson(writer);
                try writer.writeByte('}');
            },
        }
    }
};

fn writeRatioJson(writer: *std.Io.Writer, ratio: f32) !void {
    const clamped: f64 = std.math.clamp(@as(f64, ratio), 0.05, 0.95);
    const scaled: u32 = @intFromFloat(@round(clamped * 10000.0));
    const whole = scaled / 10000;
    const frac = scaled % 10000;
    if (frac == 0) {
        try writer.print("{d}.0", .{whole});
        return;
    }
    var buf = [4]u8{
        '0' + @as(u8, @intCast((frac / 1000) % 10)),
        '0' + @as(u8, @intCast((frac / 100) % 10)),
        '0' + @as(u8, @intCast((frac / 10) % 10)),
        '0' + @as(u8, @intCast(frac % 10)),
    };
    var len: usize = 4;
    while (len > 1 and buf[len - 1] == '0') len -= 1;
    assert(len >= 1 and len <= 4);
    try writer.print("{d}.{s}", .{ whole, buf[0..len] });
}

fn layoutContainsPane(node: *const LayoutNode, pane_id: []const u8) bool {
    return switch (node.*) {
        .leaf => |existing| std.mem.eql(u8, existing, pane_id),
        .split => |split| layoutContainsPane(split.first, pane_id) or layoutContainsPane(split.second, pane_id),
    };
}

test "mux manager splits panes and records layout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first_id, second.pane_id));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"axis\":\"horizontal\"") != null);
}

test "removing a nested pane keeps the surviving sibling subtree in layout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    const second_id = try std.testing.allocator.dupe(u8, second.pane_id);
    defer std.testing.allocator.free(second_id);
    var third = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    defer third.deinit();
    const third_id = try std.testing.allocator.dupe(u8, third.pane_id);
    defer std.testing.allocator.free(third_id);

    try std.testing.expect(manager.terminate(first_id));

    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const window = manager.sessions.items[0].windows.items[0];
        try std.testing.expect(window.layout.* == .split);
        try std.testing.expect(!layoutContainsPane(window.layout, first_id));
        try std.testing.expect(layoutContainsPane(window.layout, second_id));
        try std.testing.expect(layoutContainsPane(window.layout, third_id));
    }

    var fourth = try manager.splitPane(third_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });

    defer fourth.deinit();
    try std.testing.expect(!std.mem.eql(u8, fourth.pane_id, third_id));
}

test "terminating a split pane collapses layout and keeps the remaining pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    const second_id = try std.testing.allocator.dupe(u8, second.pane_id);
    defer std.testing.allocator.free(second_id);

    try std.testing.expectEqual(@as(usize, 2), manager.count());
    try std.testing.expect(manager.terminate(second_id));
    try std.testing.expectEqual(@as(usize, 1), manager.count());

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, first_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, second_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") == null);
}
