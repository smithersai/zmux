//! Session, window, and pane creation. Every path checks limits and
//! allocates before the native spawn, which is the last fallible step.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const lookup = @import("lookup.zig");
const layout = @import("layout.zig");
const metadata_mod = @import("metadata.zig");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const Axis = layout.Axis;
const Session = types.Session;
const cat_opts = mux.test_support.cat_opts;
const discardHandle = types.discardHandle;
const LayoutNode = layout.LayoutNode;
const Window = types.Window;
const Pane = types.Pane;
const SpawnSpec = types.SpawnSpec;

/// Returns a retained native session. Caller owns one release(). The
/// reference is taken under the mutex, so a concurrent terminate cannot
/// free the native first.
pub fn create(self: *Manager, opts: CreateOptions) !*NativeSession {
    var handle = try self.createSessionPane(opts);
    defer handle.deinit();
    handle.native.retain();
    return handle.native;
}

/// `opts.title`, when set, names the session (see `validateSessionNameLocked`).
pub fn createSessionPane(self: *Manager, opts: CreateOptions) !PaneHandle {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return createSessionPaneLocked(self, opts, opts.title);
}

/// Creates a new window with one pane inside `session_id` and selects it.
pub fn newWindow(self: *Manager, session_id: []const u8, opts: CreateOptions) !PaneHandle {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const session = lookup.findSessionLocked(self, session_id) orelse return error.SessionNotFound;
    try checkPaneLimitsLocked(self, opts.scrollback_bytes);
    const window_id = try nextIdLocked(self, "win", &self.next_window_id);
    defer self.allocator.free(window_id);
    const pane_id = try nextIdLocked(self, "pane", &self.next_pane_id);
    defer self.allocator.free(pane_id);
    var handle = try PaneHandle.initIds(self.allocator, session.id, window_id, pane_id);
    errdefer handle.freeIds();

    const window_name = try self.allocator.dupe(u8, opts.title orelse "window");
    errdefer self.allocator.free(window_name);
    const window_owned_id = try self.allocator.dupe(u8, window_id);
    errdefer self.allocator.free(window_owned_id);
    const window_session_id = try self.allocator.dupe(u8, session.id);
    errdefer self.allocator.free(window_session_id);
    const window_active_pane_id = try self.allocator.dupe(u8, pane_id);
    errdefer self.allocator.free(window_active_pane_id);
    const window_layout = try LayoutNode.leafNode(self.allocator, pane_id);
    errdefer {
        window_layout.deinit(self.allocator);
        self.allocator.destroy(window_layout);
    }

    const window = try self.allocator.create(Window);
    errdefer self.allocator.destroy(window);
    window.* = .{
        .id = window_owned_id,
        .session_id = window_session_id,
        .index = session.next_window_index + 1,
        .name = window_name,
        .active_pane_id = window_active_pane_id,
        .layout = window_layout,
    };

    try window.panes.ensureUnusedCapacity(self.allocator, 1);
    errdefer window.panes.deinit(self.allocator);
    try session.windows.ensureUnusedCapacity(self.allocator, 1);
    try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
    const active_window_id = try self.allocator.dupe(u8, window.id);
    errdefer self.allocator.free(active_window_id);

    // Last fallible step; everything after it commits.
    const pane = try createPaneLocked(self, session, window, pane_id, opts);
    window.panes.appendAssumeCapacity(pane);
    session.windows.appendAssumeCapacity(window);
    self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = session, .window = window, .pane = pane });

    session.next_window_index += 1;
    self.allocator.free(session.active_window_id);
    session.active_window_id = active_window_id;
    assert(window.panes.items.len == 1);
    assert(std.mem.eql(u8, session.active_window_id, window.id));
    return handle.adopt(pane.native);
}

/// Splits `target_pane_id` along `axis` and spawns a new pane in the same window.
pub fn splitPane(self: *Manager, target_pane_id: []const u8, axis: Axis, opts: CreateOptions) !PaneHandle {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = lookup.findPaneWithParentsLocked(self, target_pane_id) orelse return error.PaneNotFound;
    // The pane list and the layout agree (checkInvariants); a missing
    // leaf is reported, never assumed away.
    const leaf = found.window.layout.findLeaf(found.pane.id, 0) orelse return error.PaneNotFound;
    if (leaf.depth + 1 > self.limits.max_layout_depth) return error.LimitExceeded;
    try checkPaneLimitsLocked(self, opts.scrollback_bytes);

    const pane_id = try nextIdLocked(self, "pane", &self.next_pane_id);
    defer self.allocator.free(pane_id);
    var handle = try PaneHandle.initIds(self.allocator, found.session.id, found.window.id, pane_id);
    errdefer handle.freeIds();
    const split_id = try nextIdLocked(self, "split", &self.next_split_id);
    errdefer self.allocator.free(split_id);

    const first = try self.allocator.create(LayoutNode);
    errdefer self.allocator.destroy(first);
    const second = try LayoutNode.leafNode(self.allocator, pane_id);
    errdefer {
        second.deinit(self.allocator);
        self.allocator.destroy(second);
    }
    try found.window.panes.ensureUnusedCapacity(self.allocator, 1);
    try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
    const active_pane_id = try self.allocator.dupe(u8, pane_id);
    errdefer self.allocator.free(active_pane_id);

    // Last fallible step; everything after it commits.
    const pane = try createPaneLocked(self, found.session, found.window, pane_id, opts);
    assert(leaf.node.* == .leaf);
    first.* = .{ .leaf = leaf.node.leaf };
    leaf.node.* = .{ .split = .{ .id = split_id, .axis = axis, .first = first, .second = second } };
    found.window.panes.appendAssumeCapacity(pane);
    self.panes_by_id.putAssumeCapacity(pane.id, .{
        .session = found.session,
        .window = found.window,
        .pane = pane,
    });
    self.allocator.free(found.window.active_pane_id);
    found.window.active_pane_id = active_pane_id;
    assert(found.window.panes.items.len >= 2);
    return handle.adopt(pane.native);
}

// ---- internals (all *Locked functions require the mutex) ----

/// Creates a session whose name is `name orelse <session id>`. Checks the
/// name and limits before any allocation or fork.
pub fn createSessionPaneLocked(self: *Manager, opts: CreateOptions, name: ?[]const u8) !PaneHandle {
    if (name) |value| try lookup.validateSessionNameLocked(self, value, null);
    try checkPaneLimitsLocked(self, opts.scrollback_bytes);

    const session_id = try nextIdLocked(self, "sess", &self.next_session_id);
    errdefer self.allocator.free(session_id);
    const window_id = try nextIdLocked(self, "win", &self.next_window_id);
    defer self.allocator.free(window_id);
    const pane_id = try nextIdLocked(self, "pane", &self.next_pane_id);
    defer self.allocator.free(pane_id);
    var handle = try PaneHandle.initIds(self.allocator, session_id, window_id, pane_id);
    errdefer handle.freeIds();

    const session_name = try self.allocator.dupe(u8, name orelse session_id);
    errdefer self.allocator.free(session_name);
    const window_name = try self.allocator.dupe(u8, opts.title orelse "1");
    errdefer self.allocator.free(window_name);
    const session_active_window_id = try self.allocator.dupe(u8, window_id);
    errdefer self.allocator.free(session_active_window_id);

    var session = try self.allocator.create(Session);
    errdefer self.allocator.destroy(session);
    session.* = .{
        .id = session_id,
        .name = session_name,
        .active_window_id = session_active_window_id,
    };

    const window_owned_id = try self.allocator.dupe(u8, window_id);
    errdefer self.allocator.free(window_owned_id);
    const window_session_id = try self.allocator.dupe(u8, session_id);
    errdefer self.allocator.free(window_session_id);
    const window_active_pane_id = try self.allocator.dupe(u8, pane_id);
    errdefer self.allocator.free(window_active_pane_id);
    const window_layout = try LayoutNode.leafNode(self.allocator, pane_id);
    errdefer {
        window_layout.deinit(self.allocator);
        self.allocator.destroy(window_layout);
    }

    var window = try self.allocator.create(Window);
    errdefer self.allocator.destroy(window);
    window.* = .{
        .id = window_owned_id,
        .session_id = window_session_id,
        .index = 0,
        .name = window_name,
        .active_pane_id = window_active_pane_id,
        .layout = window_layout,
    };

    try window.panes.ensureUnusedCapacity(self.allocator, 1);
    errdefer window.panes.deinit(self.allocator);
    try session.windows.ensureUnusedCapacity(self.allocator, 1);
    errdefer session.windows.deinit(self.allocator);
    try self.sessions.ensureUnusedCapacity(self.allocator, 1);
    try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
    // Last fallible step; everything after it commits.
    const pane = try createPaneLocked(self, session, window, pane_id, opts);
    window.panes.appendAssumeCapacity(pane);
    session.windows.appendAssumeCapacity(window);
    self.sessions.appendAssumeCapacity(session);
    self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = session, .window = window, .pane = pane });
    assert(session.windows.items.len == 1);
    assert(window.panes.items.len == 1);
    return handle.adopt(pane.native);
}

/// Spawns the native as the final fallible step, so callers commit
/// infallibly after it and never tear a native down under the mutex.
pub fn createPaneLocked(
    self: *Manager,
    session: *Session,
    window: *Window,
    pane_id: []const u8,
    opts: CreateOptions,
) !*Pane {
    assert(pane_id.len > 0);
    assert(std.mem.eql(u8, window.session_id, session.id));
    var spawn = try SpawnSpec.fromOptions(self.allocator, opts);
    errdefer spawn.deinit(self.allocator);

    const pane = try self.allocator.create(Pane);
    errdefer self.allocator.destroy(pane);
    const title = try self.allocator.dupe(u8, opts.title orelse pane_id);
    errdefer self.allocator.free(title);
    const owned_pane_id = try self.allocator.dupe(u8, pane_id);
    errdefer self.allocator.free(owned_pane_id);
    const owned_window_id = try self.allocator.dupe(u8, window.id);
    errdefer self.allocator.free(owned_window_id);
    const owned_session_id = try self.allocator.dupe(u8, session.id);
    errdefer self.allocator.free(owned_session_id);

    var metadata = try metadata_mod.MetadataMap.fromEntries(self.allocator, opts.metadata);
    errdefer metadata.deinit(self.allocator);

    const native_opts = spawn.nativeOptions(pane_id, events.nativeSinkLocked(self));
    const native = try NativeSession.create(self.allocator, self.io, native_opts);
    self.spawn_count += 1;

    pane.* = .{
        .id = owned_pane_id,
        .window_id = owned_window_id,
        .session_id = owned_session_id,
        .index = session.next_pane_index,
        .title = title,
        .spawn = spawn,
        .native = native,
        .metadata = metadata,
    };
    session.next_pane_index += 1;
    return pane;
}

/// Verifies pane count and aggregate scrollback byte limits while `mutex` is held.
pub fn checkPaneLimitsLocked(self: *Manager, scrollback_bytes: usize) !void {
    var panes: usize = 0;
    var scrollback: usize = 0;
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                panes += 1;
                scrollback +|= pane.spawn.scrollback_bytes;
            }
        }
    }
    if (panes >= self.limits.max_panes) return error.LimitExceeded;
    const total = std.math.add(usize, scrollback, scrollback_bytes) catch return error.LimitExceeded;
    if (total > self.limits.max_total_scrollback_bytes) return error.LimitExceeded;
}

/// Allocates the next unique monotonic identifier with `prefix` while `mutex` is held.
pub fn nextIdLocked(self: *Manager, prefix: []const u8, next: *usize) ![]u8 {
    assert(prefix.len > 0);
    next.* += 1;
    const stamp = std.Io.Clock.real.now(self.io).nanoseconds;
    return std.fmt.allocPrint(self.allocator, "{s}-{d}-{x}", .{ prefix, next.*, stamp });
}

fn createNewWindowAndSplitForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const opts: CreateOptions = .{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    };
    var first = try manager.createSessionPane(opts);
    defer first.deinit();
    discardHandle(try manager.newWindow(first.session_id, opts));
    discardHandle(try manager.splitPane(first.pane_id, .horizontal, opts));
}

test "manager pane creation allocation failures clean up without native teardown under lock" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createNewWindowAndSplitForFailureTest, .{});
}

const StressContext = struct {
    manager: *Manager,
    iterations: usize,
    failures: std.atomic.Value(usize) = .init(0),
    creates: std.atomic.Value(usize) = .init(0),

    fn createLoop(self: *StressContext) void {
        for (0..self.iterations) |_| {
            var opts = cat_opts;
            opts.title = "w";
            const native = self.manager.create(opts) catch |err| {
                if (err != error.DuplicateSessionName) _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };
            _ = self.creates.fetchAdd(1, .seq_cst);
            // Touch the native after create returned: a UAF shows up here.
            if (native.generation() != 0) _ = self.failures.fetchAdd(1, .seq_cst);
            if (native.infoJson(std.testing.allocator)) |info| {
                std.testing.allocator.free(info);
            } else |_| _ = self.failures.fetchAdd(1, .seq_cst);
            native.release();
        }
    }

    fn terminateLoop(self: *StressContext) void {
        for (0..self.iterations) |_| _ = self.manager.terminate("w");
    }
};

test "C1: concurrent create and terminate by name never use a freed native" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var ctx: StressContext = .{ .manager = &manager, .iterations = 300 };
    const creator = try std.Thread.spawn(.{}, StressContext.createLoop, .{&ctx});
    const terminator = try std.Thread.spawn(.{}, StressContext.terminateLoop, .{&ctx});
    creator.join();
    terminator.join();

    try std.testing.expectEqual(@as(usize, 0), ctx.failures.load(.seq_cst));
    try std.testing.expect(ctx.creates.load(.seq_cst) > 0);
    try manager.checkInvariants(std.testing.allocator);
    try std.testing.expect(manager.sessionCount() <= 1);
}

test "limits reject panes, clients, bindings, scrollback, and depth before any spawn" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    manager.limits = .{ .max_panes = 2, .max_clients = 1, .max_bindings = 1, .max_total_scrollback_bytes = 3 * 4096, .max_layout_depth = 32 };

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    discardHandle(try manager.splitPane(first.pane_id, .vertical, cat_opts));
    const spawned = manager.spawn_count;
    try std.testing.expectEqual(@as(usize, 2), spawned);
    try std.testing.expectError(error.LimitExceeded, manager.createSessionPane(cat_opts));
    try std.testing.expectError(error.LimitExceeded, manager.newWindow(first.session_id, cat_opts));
    try std.testing.expectError(error.LimitExceeded, manager.splitPane(first.pane_id, .vertical, cat_opts));
    try std.testing.expectEqual(spawned, manager.spawn_count);

    manager.limits.max_panes = 10;
    try std.testing.expectError(error.LimitExceeded, manager.createSessionPane(.{ .command = "cat", .scrollback_bytes = 8192 }));
    try std.testing.expectEqual(spawned, manager.spawn_count);

    var client = try manager.attachClient(first.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectError(error.LimitExceeded, manager.attachClient(first.pane_id, 24, 80));

    try manager.bindKey("prefix", "%", "split-window -h", false);
    try manager.bindKey("prefix", "%", "split-window -v", true);
    try std.testing.expectError(error.LimitExceeded, manager.bindKey("prefix", "c", "new-window", false));
    try manager.checkInvariants(std.testing.allocator);
}

test "split enforces max_layout_depth" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    manager.limits.max_layout_depth = 3;

    var root = try manager.createSessionPane(cat_opts);
    defer root.deinit();
    var target = try std.testing.allocator.dupe(u8, root.pane_id);
    defer std.testing.allocator.free(target);
    for (0..3) |_| {
        var next = try manager.splitPane(target, .vertical, cat_opts);
        defer next.deinit();
        std.testing.allocator.free(target);
        target = try std.testing.allocator.dupe(u8, next.pane_id);
    }
    const spawned = manager.spawn_count;
    try std.testing.expectError(error.LimitExceeded, manager.splitPane(target, .vertical, cat_opts));
    try std.testing.expectEqual(spawned, manager.spawn_count);
    // A shallower leaf can still split.
    discardHandle(try manager.splitPane(root.pane_id, .horizontal, cat_opts));
    try manager.checkInvariants(std.testing.allocator);
}
