//! Structural invariant checks for the mux state graph, used by tests and
//! stateful fuzzing.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const lookup = @import("lookup.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const LayoutNode = layout.LayoutNode;
const cat_opts = mux.test_support.cat_opts;
const replaceOwnedString = types.replaceOwnedString;

/// Assert all internal structural invariants of the mux state graph.
/// Intended for stateful fuzz and model-checking suites.
pub fn checkInvariants(self: *Manager, allocator: Allocator) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var seen_sessions = std.StringHashMap(void).init(allocator);
    defer seen_sessions.deinit();
    var seen_names = std.StringHashMap(void).init(allocator);
    defer seen_names.deinit();
    var seen_windows = std.StringHashMap(void).init(allocator);
    defer seen_windows.deinit();
    var seen_panes = std.StringHashMap(void).init(allocator);
    defer seen_panes.deinit();
    var seen_clients = std.StringHashMap(void).init(allocator);
    defer seen_clients.deinit();

    for (self.sessions.items) |session| {
        if ((try seen_sessions.fetchPut(session.id, {})) != null) return error.DuplicateSessionId;
        if ((try seen_names.fetchPut(session.name, {})) != null) return error.DuplicateSessionName;
        if (session.windows.items.len == 0) return error.EmptySession;

        var active_window_found = false;
        for (session.windows.items) |window| {
            if ((try seen_windows.fetchPut(window.id, {})) != null) return error.DuplicateWindowId;
            if (!std.mem.eql(u8, window.session_id, session.id)) return error.WindowSessionMismatch;
            if (std.mem.eql(u8, window.id, session.active_window_id)) active_window_found = true;
            if (window.panes.items.len == 0) return error.EmptyWindow;

            var layout_leaves = std.StringHashMap(void).init(allocator);
            defer layout_leaves.deinit();
            try collectLayoutLeaves(window.layout, &layout_leaves);

            var active_pane_found = false;
            for (window.panes.items) |pane| {
                if ((try seen_panes.fetchPut(pane.id, {})) != null) return error.DuplicatePaneId;
                if (!std.mem.eql(u8, pane.session_id, session.id)) return error.PaneSessionMismatch;
                if (!std.mem.eql(u8, pane.window_id, window.id)) return error.PaneWindowMismatch;
                if (!std.mem.eql(u8, pane.native.id, pane.id)) return error.PaneNativeIdMismatch;
                if (std.mem.eql(u8, pane.id, window.active_pane_id)) active_pane_found = true;
                if (!layout_leaves.contains(pane.id)) return error.PaneMissingFromLayout;
            }
            if (!active_pane_found) return error.DanglingActivePane;
            if (layout_leaves.count() != window.panes.items.len) return error.LayoutPaneCountMismatch;
        }
        if (!active_window_found) return error.DanglingActiveWindow;
    }

    for (self.sessions.items) |session| {
        if (lookup.idExistsLocked(self, session.name, session)) return error.NameShadowsId;
    }

    for (self.clients.items) |client| {
        if ((try seen_clients.fetchPut(client.id, {})) != null) return error.DuplicateClientId;
        const found = lookup.findPaneWithParentsLocked(self, client.pane_id) orelse return error.DanglingClient;
        if (!std.mem.eql(u8, found.session.id, client.session_id)) return error.ClientSessionMismatch;
        if (!std.mem.eql(u8, found.window.id, client.window_id)) return error.ClientWindowMismatch;
        if (self.clients_by_id.get(client.id) != client) return error.ClientIndexMismatch;
    }
    if (self.panes_by_id.count() != seen_panes.count()) return error.PaneIndexCountMismatch;
    if (self.clients_by_id.count() != seen_clients.count()) return error.ClientIndexCountMismatch;
    assert(self.panes_by_id.count() == seen_panes.count());
    assert(self.clients_by_id.count() == seen_clients.count());
    try checkPaneIndexLocked(self);
    if (self.detached_clients.capacity < self.detached_clients.items.len + self.clients.items.len) {
        return error.DetachedCapacityShort;
    }
}

/// Every pane in the tree has a `panes_by_id` entry pointing back at it.
pub fn checkPaneIndexLocked(self: *Manager) !void {
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                assert(pane.id.len > 0);
                const loc = self.panes_by_id.get(pane.id) orelse return error.PaneIndexMissing;
                const matches = loc.session == session and loc.window == window and loc.pane == pane;
                if (!matches) return error.PaneIndexMismatch;
            }
        }
    }
}

fn collectLayoutLeaves(node: *const LayoutNode, leaves: *std.StringHashMap(void)) !void {
    switch (node.*) {
        .leaf => |pane_id| {
            assert(pane_id.len > 0);
            if ((try leaves.fetchPut(pane_id, {})) != null) return error.DuplicateLayoutLeaf;
        },
        .split => |split| {
            try collectLayoutLeaves(split.first, leaves);
            try collectLayoutLeaves(split.second, leaves);
        },
    }
}

test "checkInvariants catches a dangling client" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    var client = try manager.attachClient(handle.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try manager.checkInvariants(std.testing.allocator);

    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        try replaceOwnedString(manager.allocator, &manager.clients.items[0].pane_id, "pane-ghost");
    }
    try std.testing.expectError(error.DanglingClient, manager.checkInvariants(std.testing.allocator));
    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        try replaceOwnedString(manager.allocator, &manager.clients.items[0].pane_id, handle.pane_id);
    }
    try manager.checkInvariants(std.testing.allocator);
}
