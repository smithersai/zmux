//! Layout split ratio adjustment, pane zoom toggle, and explicit pane/window close.

const std = @import("std");
const mux = @import("../mux.zig");
const types = @import("types.zig");
const layout = @import("layout.zig");
const lookup = @import("lookup.zig");
const removal = @import("removal.zig");

const assert = std.debug.assert;
const Manager = mux.Manager;
const LayoutNode = layout.LayoutNode;
const RemovedItems = types.RemovedItems;

/// Lower bound for a layout split ratio.
pub const min_split_ratio: f32 = 0.05;
/// Upper bound for a layout split ratio.
pub const max_split_ratio: f32 = 0.95;

/// Update a split node's ratio by explicit `split_id` or the parent split of `pane_target`.
/// Validates `0.05 <= ratio <= 0.95` and `-0.9 <= delta <= 0.9`.
pub fn setSplitRatio(
    self: *Manager,
    pane_target: ?[]const u8,
    split_id: ?[]const u8,
    ratio: ?f32,
    delta: ?f32,
) !void {
    if (ratio == null and delta == null) return error.InvalidParams;
    if (ratio) |r| {
        if (!std.math.isFinite(r) or r < min_split_ratio or r > max_split_ratio) {
            return error.InvalidRatio;
        }
    }
    if (delta) |d| {
        if (!std.math.isFinite(d) or d < -0.9 or d > 0.9) return error.InvalidRatio;
    }

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const split = try resolveSplitLocked(self, pane_target, split_id);
    const next_ratio = if (ratio) |r|
        r
    else
        std.math.clamp(split.ratio + delta.?, min_split_ratio, max_split_ratio);
    assert(next_ratio >= min_split_ratio and next_ratio <= max_split_ratio);
    split.ratio = next_ratio;
}

fn resolveSplitLocked(
    self: *Manager,
    pane_target: ?[]const u8,
    split_id: ?[]const u8,
) !*LayoutNode.Split {
    if (split_id) |sid| {
        if (sid.len == 0) return error.InvalidParams;
        if (pane_target) |target| {
            const found = lookup.resolveTargetPaneLocked(self, target) orelse return error.PaneNotFound;
            return found.window.layout.findSplit(sid) orelse return error.SplitNotFound;
        }
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                if (window.layout.findSplit(sid)) |split| return split;
            }
        }
        return error.SplitNotFound;
    }
    const target = pane_target orelse return error.InvalidParams;
    const found = lookup.resolveTargetPaneLocked(self, target) orelse return error.PaneNotFound;
    return found.window.layout.findParentSplit(found.pane.id) orelse return error.SplitNotFound;
}

/// Set or toggle zoom state for `pane_target` within its owning window.
pub fn zoomPane(self: *Manager, pane_target: []const u8, zoomed: ?bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = lookup.resolveTargetPaneLocked(self, pane_target) orelse return error.PaneNotFound;
    const window = found.window;
    const already_zoomed = if (window.zoomed_pane_id) |zid| std.mem.eql(u8, zid, found.pane.id) else false;
    const want_zoom = zoomed orelse !already_zoomed;

    if (want_zoom) {
        const owned = try self.allocator.dupe(u8, found.pane.id);
        if (window.zoomed_pane_id) |old| self.allocator.free(old);
        window.zoomed_pane_id = owned;
        assert(std.mem.eql(u8, window.zoomed_pane_id.?, found.pane.id));
    } else if (window.zoomed_pane_id) |old| {
        self.allocator.free(old);
        window.zoomed_pane_id = null;
    }
}

/// Explicitly close a single pane (pruning its window or session if last).
/// Fails with `PaneNotFound` if `target` does not resolve to a pane.
pub fn closePane(self: *Manager, target: []const u8) !void {
    const removed: RemovedItems = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const found = lookup.resolveTargetPaneLocked(self, target) orelse return error.PaneNotFound;
        if (found.window.panes.items.len == 1 and found.session.windows.items.len == 1) {
            break :blk removal.takeSessionLocked(self, found.session);
        }
        break :blk try removal.takePaneLocked(self, found);
    };
    removed.deinit(self.allocator);
}

/// Explicitly close a window and all panes inside it (pruning its session if last).
/// Fails with `WindowNotFound` if `target` does not resolve to a window.
pub fn closeWindow(self: *Manager, target: []const u8) !void {
    const removed: RemovedItems = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const found = lookup.findWindowWithParentLocked(self, target) orelse return error.WindowNotFound;
        if (found.session.windows.items.len == 1) {
            break :blk removal.takeSessionLocked(self, found.session);
        }
        break :blk try removal.takeWindowLocked(self, found);
    };
    removed.deinit(self.allocator);
}

/// Effective `(rows, cols)` resolved by multi-client resize policy.
pub const EffectiveSize = struct { rows: u16, cols: u16 };

/// Compute the effective PTY size for `pane` when a client with `(rows, cols,
/// read_only, policy)` attaches, switches, or changes mode. Returns null when
/// the PTY geometry must be left unchanged (`read_only`, `.none`, or `.fixed`).
pub fn resolveClientGeometryLocked(
    self: *const Manager,
    pane: *const types.Pane,
    exclude_client: ?*const types.Client,
    rows: u16,
    cols: u16,
    read_only: bool,
    policy: types.ResizePolicy,
) ?EffectiveSize {
    if (read_only or policy == .none or policy == .fixed or pane.resize_policy == .fixed) return null;
    assert(rows >= 1 and cols >= 1);
    const active_policy = if (policy != .latest) policy else pane.resize_policy;
    return switch (active_policy) {
        .none, .fixed => null,
        .latest => .{ .rows = rows, .cols = cols },
        .smallest => aggregateClientsLocked(self, pane.id, exclude_client, rows, cols, true),
        .largest => aggregateClientsLocked(self, pane.id, exclude_client, rows, cols, false),
    };
}

fn aggregateClientsLocked(
    self: *const Manager,
    pane_id: []const u8,
    exclude_client: ?*const types.Client,
    init_rows: u16,
    init_cols: u16,
    smallest: bool,
) EffectiveSize {
    var eff_rows = init_rows;
    var eff_cols = init_cols;
    for (self.clients.items) |client| {
        if (exclude_client != null and client == exclude_client.?) continue;
        if (!std.mem.eql(u8, client.pane_id, pane_id)) continue;
        if (client.read_only or client.resize_policy == .none or client.resize_policy == .fixed) continue;
        if (smallest) {
            eff_rows = @min(eff_rows, client.rows);
            eff_cols = @min(eff_cols, client.cols);
        } else {
            eff_rows = @max(eff_rows, client.rows);
            eff_cols = @max(eff_cols, client.cols);
        }
    }
    assert(eff_rows >= 1 and eff_cols >= 1);
    return .{ .rows = eff_rows, .cols = eff_cols };
}

/// Update `read_only` and/or `resize_policy` for an attached logical client
/// and recompute effective pane geometry if the client is interactive.
pub fn setClientMode(
    self: *Manager,
    client_id: []const u8,
    read_only: ?bool,
    resize_policy: ?types.ResizePolicy,
) !types.ClientSnapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const client = lookup.findClientLocked(self, client_id) orelse return error.ClientNotFound;
    const next_ro = read_only orelse client.read_only;
    const next_policy = resize_policy orelse client.resize_policy;
    const found = lookup.findPaneWithParentsLocked(self, client.pane_id) orelse return error.PaneNotFound;

    if (resolveClientGeometryLocked(self, found.pane, client, client.rows, client.cols, next_ro, next_policy)) |sz| {
        if (found.pane.native.isRunning()) {
            found.pane.native.resize(sz.cols, sz.rows) catch |err| switch (err) {
                error.SessionTerminated => {},
                else => return err,
            };
        }
        found.pane.spawn.rows = sz.rows;
        found.pane.spawn.cols = sz.cols;
    }

    client.read_only = next_ro;
    client.resize_policy = next_policy;
    return types.ClientSnapshot.fromClient(self.allocator, client);
}

test "setSplitRatio, zoomPane, closePane, and closeWindow preserve mux invariants" {
    const allocator = std.testing.allocator;
    const cat = mux.test_support.cat_opts;
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var p1 = try manager.createSessionPane(cat);
    defer p1.deinit();
    var p2 = try manager.splitPane(p1.pane_id, .horizontal, cat);
    defer p2.deinit();

    try std.testing.expectError(error.InvalidRatio, manager.setSplitRatio(p2.pane_id, null, 0.01, null));
    try manager.setSplitRatio(p2.pane_id, null, 0.7, null);
    try manager.setSplitRatio(p2.pane_id, null, null, -0.1);
    const snap1 = try manager.snapshotJson(allocator);
    defer allocator.free(snap1);
    try std.testing.expect(std.mem.indexOf(u8, snap1, "\"ratio\":0.6") != null);

    try manager.zoomPane(p2.pane_id, null);
    try manager.checkInvariants(allocator);
    const snap2 = try manager.snapshotJson(allocator);
    defer allocator.free(snap2);
    try std.testing.expect(std.mem.indexOf(u8, snap2, "\"zoomedPaneId\":\"pane-") != null);

    // Closing the zoomed pane must clear zoomedPaneId automatically.
    try manager.closePane(p2.pane_id);
    try manager.checkInvariants(allocator);
    const snap3 = try manager.snapshotJson(allocator);
    defer allocator.free(snap3);
    try std.testing.expect(std.mem.indexOf(u8, snap3, "\"zoomedPaneId\":null") != null);
    try std.testing.expectError(error.PaneNotFound, manager.closePane("pane-missing"));

    var w2 = try manager.newWindow(p1.session_id, cat);
    defer w2.deinit();
    var c2 = try manager.attachClient(w2.pane_id, 24, 80);
    defer c2.deinit(allocator);
    try manager.closeWindow(w2.window_id);
    try manager.checkInvariants(allocator);
    try std.testing.expectError(error.WindowNotFound, manager.closeWindow("win-missing"));

    // Closing the last window prunes the owning session.
    try manager.closeWindow(p1.window_id);
    try manager.checkInvariants(allocator);
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
}

test "read-only observers and multi-client resize policies control PTY geometry" {
    const allocator = std.testing.allocator;
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var p1 = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "exec cat",
        .rows = 24,
        .cols = 80,
    });
    defer p1.deinit();

    // Read-only observer with different geometry must not resize the PTY.
    var ro = try manager.attachClientWithOptions(p1.pane_id, 10, 40, .{ .read_only = true, .resize_policy = .latest });
    defer ro.deinit(allocator);
    try std.testing.expect(ro.read_only);
    try std.testing.expectEqual(@as(u16, 24), p1.native.vt.rows());
    try std.testing.expectEqual(@as(u16, 80), p1.native.vt.cols());

    // Resize policy `.none` also leaves PTY geometry unchanged.
    var none_c = try manager.attachClientWithOptions(p1.pane_id, 12, 50, .{ .resize_policy = .none });
    defer none_c.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 24), p1.native.vt.rows());

    // Two interactive clients: `.smallest` picks min across non-readonly interactive clients.
    var big = try manager.attachClientWithOptions(p1.pane_id, 40, 120, .{ .resize_policy = .latest });
    defer big.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 40), p1.native.vt.rows());

    var small = try manager.attachClientWithOptions(p1.pane_id, 20, 60, .{ .resize_policy = .smallest });
    defer small.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 20), p1.native.vt.rows());
    try std.testing.expectEqual(@as(u16, 60), p1.native.vt.cols());

    // Switching `small` to `.largest` expands to max (40x120), ignoring the 10x40 read-only observer.
    var updated = try manager.setClientMode(small.id, null, .largest);
    defer updated.deinit(allocator);
    try std.testing.expectEqual(types.ResizePolicy.largest, updated.resize_policy);
    try std.testing.expectEqual(@as(u16, 40), p1.native.vt.rows());
    try std.testing.expectEqual(@as(u16, 120), p1.native.vt.cols());
    try manager.checkInvariants(allocator);
}
