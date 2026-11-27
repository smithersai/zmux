//! Pane and session removal, reaping, and scrollback reads. Natives are
//! always torn down after the manager mutex is released.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const attach = @import("attach.zig");
const buffer = @import("../buffer.zig");
const lookup = @import("lookup.zig");
const sys = @import("../sys.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const RemovedItems = types.RemovedItems;
const Session = types.Session;
const cat_opts = mux.test_support.cat_opts;
const discardHandle = types.discardHandle;
const Pane = types.Pane;
const freeDetachedClients = types.freeDetachedClients;
const waitForNoLivePanes = mux.test_support.waitForNoLivePanes;
const DetachReason = types.DetachReason;
const Window = types.Window;
const terminate_all_deadline_ms = types.terminate_all_deadline_ms;

/// Reap only panes whose native still runs; exited panes cost nothing.
pub fn reapExitedPanes(self: *Manager) void {
    _ = reapExitedPanesCounted(self);
}

/// Returns how many natives were visited.
pub fn reapExitedPanesCounted(self: *Manager) usize {
    self.mutex.lockUncancelable(self.io);
    var live: usize = 0;
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                if (pane.native.isRunning()) live += 1;
            }
        }
    }
    if (live == 0) {
        self.mutex.unlock(self.io);
        return 0;
    }
    var stack_buf: [64]*NativeSession = undefined;
    var heap_buf: ?[]*NativeSession = null;
    defer if (heap_buf) |buf| self.allocator.free(buf);
    const natives: []*NativeSession = if (live <= stack_buf.len) stack_buf[0..live] else blk: {
        const allocated = self.allocator.alloc(*NativeSession, live) catch {
            self.mutex.unlock(self.io);
            return 0;
        };
        heap_buf = allocated;
        break :blk allocated;
    };
    assert(natives.len == live);
    var used: usize = 0;
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                if (used == natives.len) break;
                if (!pane.native.isRunning()) continue;
                pane.native.retain();
                natives[used] = pane.native;
                used += 1;
            }
        }
    }
    assert(used <= natives.len);
    self.mutex.unlock(self.io);

    for (natives[0..used]) |native| {
        _ = native.reapExited();
        native.release();
    }
    return used;
}

/// Returns a newly allocated copy of `pane_id`'s full scrollback ring buffer.
pub fn paneScrollbackSnapshot(self: *Manager, allocator: Allocator, pane_id: []const u8) ![]u8 {
    const native = try retainPaneNative(self, pane_id);
    defer native.release();
    return native.scrollbackSnapshot(allocator);
}

/// Returns up to the last `max_bytes` of `pane_id`'s scrollback plus its end offset.
pub fn paneScrollbackTail(
    self: *Manager,
    allocator: Allocator,
    pane_id: []const u8,
    max_bytes: usize,
) !buffer.Tail {
    const native = try retainPaneNative(self, pane_id);
    defer native.release();
    return native.scrollbackTail(allocator, max_bytes);
}

/// `native.stopInput` on every pane: wakes writers blocked on a full PTY.
pub fn interruptInput(self: *Manager) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| pane.native.stopInput();
        }
    }
}

/// Remove a pane (by id) or a whole session (by id, then name). Removing
/// the last pane removes its session. Returns false when nothing matches,
/// and also on OutOfMemory, in which case nothing changed.
pub fn terminate(self: *Manager, id: []const u8) bool {
    const removed = blk: {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (lookup.findPaneWithParentsLocked(self, id)) |found| {
            if (found.window.panes.items.len == 1 and found.session.windows.items.len == 1) {
                break :blk takeSessionLocked(self, found.session);
            }
            break :blk takePaneLocked(self, found) catch return false;
        }
        const session = lookup.findSessionLocked(self, id) orelse return false;
        break :blk takeSessionLocked(self, session);
    };
    removed.deinit(self.allocator);
    return true;
}

/// Remove every session and client. Starts teardown of every native, then
/// waits for all of them against one shared deadline with the mutex
/// released.
pub fn terminateAll(self: *Manager) void {
    self.mutex.lockUncancelable(self.io);
    var sessions = self.sessions;
    self.sessions = .empty;
    self.panes_by_id.clearRetainingCapacity();
    while (self.clients.items.len > 0) attach.removeClientAtLocked(self, self.clients.items.len - 1, .session_removed);
    assert(self.clients.items.len == 0);
    assert(self.clients_by_id.count() == 0);
    self.mutex.unlock(self.io);

    // `sessions` is now private to this call.
    for (sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                if (pane.native.state() != .terminated) pane.native.beginTerminate();
            }
        }
    }
    const deadline_ms = sys.monotonicMs() + terminate_all_deadline_ms;
    for (sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                if (pane.native.state() != .terminated) pane.native.awaitTerminated(deadline_ms);
            }
        }
    }
    for (sessions.items) |session| session.deinit(self.allocator);
    sessions.deinit(self.allocator);
}

/// Retains and returns the `NativeSession` backing `pane_id`, or `PaneNotFound`.
pub fn retainPaneNative(self: *Manager, pane_id: []const u8) !*NativeSession {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = lookup.findPaneLocked(self, pane_id) orelse return error.PaneNotFound;
    pane.native.retain();
    return pane.native;
}

/// Never fails. Prunes clients of the session.
pub fn takeSessionLocked(self: *Manager, session: *Session) RemovedItems {
    const index = std.mem.indexOfScalar(*Session, self.sessions.items, session) orelse return .{};
    assert(session.windows.items.len > 0);
    attach.detachClientsLocked(self, .session, session.id, .session_removed);
    for (session.windows.items) |window| {
        for (window.panes.items) |pane| _ = self.panes_by_id.remove(pane.id);
    }
    return .{ .session = self.sessions.swapRemove(index) };
}

/// Removes one pane, and its window when that was the window's last pane.
/// Allocates the successor active ids first, so OutOfMemory changes
/// nothing. Prunes clients of the pane. The caller handles the
/// last-pane-of-last-window case with `takeSessionLocked`.
pub fn takePaneLocked(self: *Manager, found: PaneRef) !RemovedItems {
    const session = found.session;
    const window = found.window;
    const index = std.mem.indexOfScalar(*Pane, window.panes.items, found.pane) orelse return .{};
    const removes_window = window.panes.items.len == 1;
    std.debug.assert(!removes_window or session.windows.items.len > 1);

    var new_active_pane: ?[]u8 = null;
    errdefer if (new_active_pane) |value| self.allocator.free(value);
    if (!removes_window and std.mem.eql(u8, window.active_pane_id, found.pane.id)) {
        const successor = window.panes.items[if (index == 0) 1 else 0];
        assert(successor != found.pane);
        new_active_pane = try self.allocator.dupe(u8, successor.id);
    }
    var new_active_window: ?[]u8 = null;
    if (removes_window and std.mem.eql(u8, session.active_window_id, window.id)) {
        // `session.windows.items.len > 1` (asserted above) and `window`
        // is one of them, so the other end of the list is a successor.
        const first_window = session.windows.items[0];
        const successor = if (first_window == window) session.windows.items[1] else first_window;
        assert(successor != window);
        new_active_window = try self.allocator.dupe(u8, successor.id);
    }

    // Commit: nothing below can fail.
    attach.detachClientsLocked(self, .pane, found.pane.id, .pane_removed);
    const removed = window.panes.swapRemove(index);
    _ = self.panes_by_id.remove(removed.id);
    _ = window.layout.removeLeaf(self.allocator, removed.id);
    if (new_active_pane) |value| {
        self.allocator.free(window.active_pane_id);
        window.active_pane_id = value;
    }
    if (!removes_window) return .{ .pane = removed };

    const window_index = std.mem.indexOfScalar(*Window, session.windows.items, window).?;
    const removed_window = session.windows.swapRemove(window_index);
    if (new_active_window) |value| {
        self.allocator.free(session.active_window_id);
        session.active_window_id = value;
    }
    return .{ .window = removed_window, .pane = removed };
}

test "terminate by session id removes the whole session" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    const session_id = try std.testing.allocator.dupe(u8, first.session_id);
    defer std.testing.allocator.free(session_id);
    discardHandle(try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" }));

    try std.testing.expectEqual(@as(usize, 1), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 2), manager.paneCount());
    try std.testing.expect(manager.terminate(session_id));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 0), manager.paneCount());
}

test "manager count ignores terminated panes for idle accounting" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    discardHandle(try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" }));

    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (std.Io.Clock.awake.now(io).compare(.lt, deadline)) {
        manager.reapExitedPanes();
        if (manager.count() == 0) return;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.PaneStillCountedAsLive;
}

test "terminate by id removes the intended session after a swapRemove" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var a = try manager.createSessionPane(.{ .title = "a", .shell = "/bin/sh", .command = "cat" });
    defer a.deinit();
    var b = try manager.createSessionPane(.{ .title = "b", .shell = "/bin/sh", .command = "cat" });
    defer b.deinit();
    var c = try manager.createSessionPane(.{ .title = "c", .shell = "/bin/sh", .command = "cat" });
    defer c.deinit();

    try std.testing.expect(manager.terminate(a.session_id));
    try std.testing.expect(manager.terminate(c.session_id));
    try std.testing.expect(!manager.terminate(c.session_id));
    const remaining = manager.find("b") orelse return error.MissingSession;
    defer remaining.release();
    try std.testing.expectEqualStrings(b.pane_id, remaining.id);
    try std.testing.expectEqual(@as(usize, 1), manager.sessionCount());
}

test "removing panes and sessions prunes clients into takeDetachedClients" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var second = try manager.splitPane(first.pane_id, .vertical, cat_opts);
    defer second.deinit();
    var on_first = try manager.attachClient(first.pane_id, 24, 80);
    defer on_first.deinit(std.testing.allocator);
    var on_second = try manager.attachClient(second.pane_id, 24, 80);
    defer on_second.deinit(std.testing.allocator);
    var remote = try manager.attachClient(first.pane_id, 24, 80);
    defer remote.deinit(std.testing.allocator);

    try std.testing.expect(manager.terminate(second.pane_id));
    try manager.checkInvariants(std.testing.allocator);
    {
        const detached = try manager.takeDetachedClients(std.testing.allocator);
        defer freeDetachedClients(std.testing.allocator, detached);
        try std.testing.expectEqual(@as(usize, 1), detached.len);
        try std.testing.expectEqualStrings(on_second.id, detached[0].client_id);
        try std.testing.expectEqual(DetachReason.pane_removed, detached[0].reason);
    }

    try std.testing.expect(manager.detachClientRemote(remote.id));
    try std.testing.expect(!manager.detachClientRemote(remote.id));
    try std.testing.expect(manager.terminate(first.session_id));
    const clients = try manager.clientsJson(std.testing.allocator);
    defer std.testing.allocator.free(clients);
    try std.testing.expectEqualStrings("[]", clients);

    const detached = try manager.takeDetachedClients(std.testing.allocator);
    defer freeDetachedClients(std.testing.allocator, detached);
    try std.testing.expectEqual(@as(usize, 2), detached.len);
    try std.testing.expectEqualStrings(remote.id, detached[0].client_id);
    try std.testing.expectEqual(DetachReason.remote_detach, detached[0].reason);
    try std.testing.expectEqualStrings(on_first.id, detached[1].client_id);
    try std.testing.expectEqual(DetachReason.session_removed, detached[1].reason);

    const empty = try manager.takeDetachedClients(std.testing.allocator);
    defer freeDetachedClients(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "terminateAll prunes clients with session_removed" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    var client = try manager.attachClient(handle.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    manager.terminateAll();

    const detached = try manager.takeDetachedClients(std.testing.allocator);
    defer freeDetachedClients(std.testing.allocator, detached);
    try std.testing.expectEqual(@as(usize, 1), detached.len);
    try std.testing.expectEqual(DetachReason.session_removed, detached[0].reason);
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
}

test "reapExitedPanes visits only live panes" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    for (0..3) |_| discardHandle(try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" }));
    try waitForNoLivePanes(&manager);
    discardHandle(try manager.createSessionPane(cat_opts));
    try std.testing.expectEqual(@as(usize, 1), reapExitedPanesCounted(&manager));
    const totals = manager.counts();
    try std.testing.expectEqual(@as(usize, 4), totals.sessions);
    try std.testing.expectEqual(@as(usize, 4), totals.panes);
    try std.testing.expectEqual(@as(usize, 1), totals.live_panes);
}

test "terminateAll shares one deadline across panes that ignore SIGTERM" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    for (0..20) |_| discardHandle(try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "trap '' TERM; sleep 100", .scrollback_bytes = 4096 }));
    const io = std.testing.io;
    io.sleep(.fromMilliseconds(300), .awake) catch {};

    const start = std.Io.Clock.awake.now(io);
    manager.terminateAll();
    const elapsed_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expect(elapsed_ms < 1000);
}

test "paneScrollbackTail returns pane output and rejects unknown panes" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "printf hello; cat" });
    defer handle.deinit();
    try std.testing.expectError(error.PaneNotFound, manager.paneScrollbackTail(std.testing.allocator, "pane-ghost", 64));

    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(3));
    while (true) {
        const tail = try manager.paneScrollbackTail(std.testing.allocator, handle.pane_id, 64);
        defer std.testing.allocator.free(tail.bytes);
        if (std.mem.indexOf(u8, tail.bytes, "hello") != null) break;
        if (std.Io.Clock.awake.now(io).compare(.gt, deadline)) return error.MissingOutput;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
}

fn terminatePaneForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var second = try manager.splitPane(first.pane_id, .vertical, cat_opts);
    defer second.deinit();
    var lone = try manager.newWindow(first.session_id, cat_opts);
    defer lone.deinit();
    var client = try manager.attachClient(second.pane_id, 24, 80);
    defer client.deinit(allocator);

    // `second` is the active pane; `lone` is the active window.
    const removed_pane = manager.terminate(second.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    if (!removed_pane) return error.OutOfMemory;
    const removed_window = manager.terminate(lone.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    if (!removed_window) return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 1), manager.paneCount());
}

test "pane and window removal allocation failures keep invariants" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, terminatePaneForFailureTest, .{});
}
