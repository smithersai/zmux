const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const mux = zmux.mux;
const LayoutNode = mux.LayoutNode;
const Axis = mux.Axis;
const Manager = mux.Manager;

fn collectTreeLeaves(node: *const LayoutNode, leaves: *std.StringHashMap(void)) !void {
    switch (node.*) {
        .leaf => |pane_id| {
            try std.testing.expect((try leaves.fetchPut(pane_id, {})) == null);
        },
        .split => |split| {
            try collectTreeLeaves(split.first, leaves);
            try collectTreeLeaves(split.second, leaves);
        },
    }
}

fn verifyLayoutJsonMatchesTree(node: *const LayoutNode, val: std.json.Value) !void {
    try std.testing.expect(val == .object);
    const kind = val.object.get("kind").?.string;
    switch (node.*) {
        .leaf => |pane_id| {
            try std.testing.expectEqualStrings("leaf", kind);
            try std.testing.expectEqualStrings(pane_id, val.object.get("paneId").?.string);
        },
        .split => |split| {
            try std.testing.expectEqualStrings("split", kind);
            try std.testing.expectEqualStrings(split.id, val.object.get("id").?.string);
            try std.testing.expectEqualStrings(split.axis.label(), val.object.get("axis").?.string);
            try verifyLayoutJsonMatchesTree(split.first, val.object.get("first").?);
            try verifyLayoutJsonMatchesTree(split.second, val.object.get("second").?);
        },
    }
}

fn fuzzLayoutTreeModel(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    const root = try LayoutNode.leafNode(allocator, "pane-0");
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var live_panes: std.ArrayList([]u8) = .empty;
    defer {
        for (live_panes.items) |id| allocator.free(id);
        live_panes.deinit(allocator);
    }
    try live_panes.append(allocator, try allocator.dupe(u8, "pane-0"));

    var next_pane_num: usize = 1;
    var next_split_num: usize = 1;

    const Op = enum(u8) {
        split_existing,
        split_owned_existing,
        split_missing,
        remove_existing,
        remove_missing,
        check_json,
    };

    var steps: usize = 0;
    while (!smith.eos() and steps < 64) : (steps += 1) {
        switch (smith.value(Op)) {
            .split_existing => {
                if (live_panes.items.len >= 32) continue;
                const idx = smith.index(live_panes.items.len);
                const target = live_panes.items[idx];
                const axis = smith.value(Axis);
                const new_id = try std.fmt.allocPrint(allocator, "pane-{d}", .{next_pane_num});
                errdefer allocator.free(new_id);
                next_pane_num += 1;
                const split_id = try std.fmt.allocPrint(allocator, "split-{d}", .{next_split_num});
                defer allocator.free(split_id);
                next_split_num += 1;

                const replaced = try root.replaceLeafWithSplit(allocator, target, axis, new_id, split_id);
                try std.testing.expect(replaced);
                try live_panes.append(allocator, new_id);
            },
            .split_owned_existing => {
                if (live_panes.items.len >= 32) continue;
                const idx = smith.index(live_panes.items.len);
                const target = live_panes.items[idx];
                const axis = smith.value(Axis);
                const new_id = try std.fmt.allocPrint(allocator, "pane-{d}", .{next_pane_num});
                errdefer allocator.free(new_id);
                next_pane_num += 1;
                const split_id = try std.fmt.allocPrint(allocator, "split-{d}", .{next_split_num});
                var split_id_owned = true;
                errdefer if (split_id_owned) allocator.free(split_id);
                next_split_num += 1;

                const first = try LayoutNode.leafNode(allocator, target);
                errdefer {
                    first.deinit(allocator);
                    allocator.destroy(first);
                }
                const second = try LayoutNode.leafNode(allocator, new_id);
                errdefer {
                    second.deinit(allocator);
                    allocator.destroy(second);
                }

                const replaced = root.replaceLeafWithSplitOwned(allocator, target, axis, split_id, first, second);
                try std.testing.expect(replaced);
                split_id_owned = false;
                try live_panes.append(allocator, new_id);
            },
            .split_missing => {
                const axis = smith.value(Axis);
                const replaced = try root.replaceLeafWithSplit(allocator, "pane-does-not-exist", axis, "pane-x", "split-x");
                try std.testing.expect(!replaced);
            },
            .remove_existing => {
                // Only remove when > 1 pane exists (a single-leaf root returns true for
                // self_is_target without removing itself, which we test explicitly too).
                const idx = smith.index(live_panes.items.len);
                const target = live_panes.items[idx];
                const removed = root.removeLeaf(allocator, target);
                try std.testing.expect(removed);
                if (live_panes.items.len > 1) {
                    const owned = live_panes.swapRemove(idx);
                    allocator.free(owned);
                } else {
                    // Single leaf root stays intact on self_is_target.
                    try std.testing.expect(root.* == .leaf);
                    try std.testing.expectEqualStrings(target, root.leaf);
                }
            },
            .remove_missing => {
                try std.testing.expect(!root.removeLeaf(allocator, "pane-nonexistent"));
            },
            .check_json => {
                var out: std.Io.Writer.Allocating = .init(allocator);
                defer out.deinit();
                try root.writeJson(&out.writer);

                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out.written(), .{});
                defer parsed.deinit();
                try verifyLayoutJsonMatchesTree(root, parsed.value);
            },
        }

        // Invariant: exact bijection between layout leaves and `live_panes`.
        var leaves = std.StringHashMap(void).init(allocator);
        defer leaves.deinit();
        try collectTreeLeaves(root, &leaves);
        try std.testing.expectEqual(live_panes.items.len, leaves.count());
        for (live_panes.items) |id| {
            try std.testing.expect(leaves.contains(id));
        }
    }
}

fn fuzzLayoutNodeOom(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const axis = smith.value(Axis);
    const fail_idx = smith.valueRangeAtMost(u8, 0, 10);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();

    const root = LayoutNode.leafNode(fa, "p0") catch |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        return;
    };
    defer {
        root.deinit(fa);
        fa.destroy(root);
    }

    if (root.replaceLeafWithSplit(fa, "p0", axis, "p1", "s1")) |ok| {
        try std.testing.expect(ok);
        _ = root.replaceLeafWithSplit(fa, "p1", .vertical, "p2", "s2") catch {};
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        // Must still be the intact leaf "p0"
        try std.testing.expect(root.* == .leaf);
        try std.testing.expectEqualStrings("p0", root.leaf);
    }
}

fn fuzzMuxCommandLineParser(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    // Generate either raw bytes or semi-structured tmux command lines.
    var line_buf: [512]u8 = undefined;
    const line: []const u8 = blk: {
        if (smith.value(bool)) {
            break :blk corpus.drawBytes(smith, &line_buf);
        }
        var w: std.Io.Writer = .fixed(&line_buf);
        const cmds = [_][]const u8{
            "split-window", "splitw", "new-window", "neww", "respawn-pane", "respawnp", "unknown", "",
        };
        const cmd = cmds[smith.index(cmds.len)];
        w.writeAll(cmd) catch {};
        var n_toks: usize = 0;
        while (!smith.eos() and n_toks < 8) : (n_toks += 1) {
            w.writeByte(' ') catch break;
            const tok_kind = smith.valueRangeAtMost(u8, 0, 5);
            const tok: []const u8 = switch (tok_kind) {
                0 => "-h",
                1 => "-v",
                2 => "-n",
                3 => "-x",
                4 => "--bad",
                else => tok_blk: {
                    var tbuf: [32]u8 = undefined;
                    break :tok_blk corpus.drawAsciiSlice(smith, &tbuf);
                },
            };
            w.writeAll(tok) catch break;
        }
        break :blk w.buffered();
    };

    var parsed = Manager.parseCommandLine(allocator, line) catch |err| {
        try std.testing.expectEqual(error.UnsupportedCommand, err);
        return;
    };
    defer parsed.deinit(allocator);

    // Verify invariants of parsed commands.
    var iter = std.mem.tokenizeScalar(u8, line, ' ');
    const first = iter.next();
    switch (parsed) {
        .noop => try std.testing.expect(first == null),
        .split_window => |sw| {
            try std.testing.expect(std.mem.eql(u8, first.?, "split-window") or std.mem.eql(u8, first.?, "splitw"));
            if (sw.command) |c| try std.testing.expect(c.len > 0);
        },
        .new_window => |nw| {
            try std.testing.expect(std.mem.eql(u8, first.?, "new-window") or std.mem.eql(u8, first.?, "neww"));
            if (nw.command) |c| try std.testing.expect(c.len > 0);
        },
        .respawn_pane => {
            try std.testing.expect(std.mem.eql(u8, first.?, "respawn-pane") or std.mem.eql(u8, first.?, "respawnp"));
            try std.testing.expect(iter.next() == null);
        },
    }

    // OOM safety check on parseCommandLine
    const fail_idx = smith.valueRangeAtMost(u8, 0, 6);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (Manager.parseCommandLine(fa, line)) |*p| {
        var owned = p.*;
        owned.deinit(fa);
    } else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzMuxKeyBindingsAndOom(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const tables = [_][]const u8{ "prefix", "root", "copy-mode", "" };
    const keys = [_][]const u8{ "%", "\"", "c", "r", "C-a", "\\", "\n", "x" };

    var cmd_buf: [128]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 32) : (steps += 1) {
        const table = tables[smith.index(tables.len)];
        const key = keys[smith.index(keys.len)];
        const cmd = corpus.drawAsciiSlice(smith, &cmd_buf);
        const repeat = smith.value(bool);

        try manager.bindKey(table, key, cmd, repeat);

        // Keys JSON must always be a valid single-line JSON array.
        const keys_json = try manager.keysJson(allocator);
        defer allocator.free(keys_json);
        var parsed_keys = try std.json.parseFromSlice(std.json.Value, allocator, keys_json, .{});
        defer parsed_keys.deinit();
        try std.testing.expect(parsed_keys.value == .array);

        // Snapshot JSON must also remain valid JSON.
        const snap = try manager.snapshotJson(allocator);
        defer allocator.free(snap);
        var parsed_snap = try std.json.parseFromSlice(std.json.Value, allocator, snap, .{});
        defer parsed_snap.deinit();
        try std.testing.expect(parsed_snap.value == .object);
    }

    // OOM safety on bindKey (both insert AND overwrite of existing binding!).
    const fail_idx = smith.valueRangeAtMost(u8, 0, 12);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    {
        var oom_mgr = Manager.init(fa, std.testing.io, null);
        defer oom_mgr.deinit();
        oom_mgr.bindKey("prefix", "%", "split-window -h", false) catch {};
        oom_mgr.bindKey("prefix", "%", "split-window -v /bin/sh", true) catch {};
        oom_mgr.bindKey("root", "c", "new-window -n shell", false) catch {};
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "fuzz: LayoutNode binary tree differential state machine" {
    try std.testing.fuzz({}, fuzzLayoutTreeModel, .{});
}

test "fuzz: LayoutNode replaceLeafWithSplit OOM safety" {
    try std.testing.fuzz({}, fuzzLayoutNodeOom, .{});
}

test "fuzz: mux.Manager.parseCommandLine and OOM safety" {
    try std.testing.fuzz({}, fuzzMuxCommandLineParser, .{
        .corpus = &.{
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "split-window -h /bin/echo hi" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "splitw -v -h cmd -arg" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "new-window -n logs tail -f /tmp/a" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "neww -n" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "respawn-pane" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "respawnp extra" } }),
        },
    });
}

test "fuzz: mux.Manager key bindings JSON and OOM safety" {
    try std.testing.fuzz({}, fuzzMuxKeyBindingsAndOom, .{});
}
