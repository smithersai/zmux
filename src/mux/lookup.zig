//! Id and name resolution, selection, renames, and per-pane alert marks.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const Client = types.Client;
const Pane = types.Pane;
const Session = types.Session;
const WindowRef = types.WindowRef;
const cat_opts = mux.test_support.cat_opts;
const discardHandle = types.discardHandle;
const replaceOwnedString = types.replaceOwnedString;
const validateNameText = types.validateNameText;
const paneState = mux.test_support.paneState;

/// Selects `pane_id` as the active pane of its window and activates that window.
pub fn selectPane(self: *Manager, pane_id: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = findPaneWithParentsLocked(self, pane_id) orelse return error.PaneNotFound;
    assert(std.mem.eql(u8, found.pane.window_id, found.window.id));
    const active_pane = try self.allocator.dupe(u8, found.pane.id);
    errdefer self.allocator.free(active_pane);
    const active_window = try self.allocator.dupe(u8, found.window.id);
    self.allocator.free(found.window.active_pane_id);
    found.window.active_pane_id = active_pane;
    self.allocator.free(found.session.active_window_id);
    found.session.active_window_id = active_window;
}

/// Selects `window_id` as the active window of its session.
pub fn selectWindow(self: *Manager, window_id: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = findWindowWithParentLocked(self, window_id) orelse return error.WindowNotFound;
    assert(std.mem.eql(u8, found.window.session_id, found.session.id));
    try replaceOwnedString(self.allocator, &found.session.active_window_id, found.window.id);
}

/// `session_id` may be a pane id, a session id, or a session name. Fails
/// with `InvalidName`, `DuplicateSessionName`, or `NameShadowsId`.
pub fn renameSession(self: *Manager, session_id: []const u8, title: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const session = resolveTargetSessionLocked(self, session_id) orelse return error.SessionNotFound;
    if (std.mem.eql(u8, session.name, title)) return;
    try validateSessionNameLocked(self, title, session);
    try replaceOwnedString(self.allocator, &session.name, title);
    assert(std.mem.eql(u8, session.name, title));
}

/// Renames `window_id` after validating `title`.
pub fn renameWindow(self: *Manager, window_id: []const u8, title: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const found = findWindowWithParentLocked(self, window_id) orelse return error.WindowNotFound;
    try validateNameText(title);
    try replaceOwnedString(self.allocator, &found.window.name, title);
    assert(std.mem.eql(u8, found.window.name, title));
}

/// Updates the pane title and the native title, so `session.info`,
/// `session.list`, and `mux.snapshot` agree.
pub fn renamePane(self: *Manager, pane_id: []const u8, title: []const u8, custom: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = findPaneLocked(self, pane_id) orelse return error.PaneNotFound;
    try validateNameText(title);
    const owned = try self.allocator.dupe(u8, title);
    errdefer self.allocator.free(owned);
    try pane.native.setTitle(title);
    self.allocator.free(pane.title);
    pane.title = owned;
    pane.has_custom_title = custom;
}

/// Stores the event's `ts_ms`. Ignores events from a stale `generation`.
pub fn markActivity(self: *Manager, pane_id: []const u8, generation: u64, ts_ms: i64) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = findPaneLocked(self, pane_id) orelse return;
    if (pane.native.generation() != generation) return;
    pane.alerts.activity = true;
    pane.alerts.last_activity_ms = ts_ms;
}

/// Stores the event's `ts_ms`. Ignores events from a stale `generation`.
pub fn markBell(self: *Manager, pane_id: []const u8, generation: u64, ts_ms: i64) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = findPaneLocked(self, pane_id) orelse return;
    if (pane.native.generation() != generation) return;
    pane.alerts.bell = true;
    pane.alerts.last_bell_ms = ts_ms;
}

/// `pane_id` is the `session_exited` event's id, which is a pane id.
/// Ignores events from a stale `generation`.
pub fn markExited(self: *Manager, pane_id: []const u8, generation: u64) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = findPaneLocked(self, pane_id) orelse return;
    if (pane.native.generation() != generation) return;
    pane.alerts.exited = true;
}

/// `markExited` that reports whether the event is current. False only when
/// the pane exists and runs another generation: the event is stale and
/// must not be broadcast. An unknown pane (removed, or never a pane) is
/// not stale.
pub fn markExitedIfCurrent(self: *Manager, pane_id: []const u8, generation: u64) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = findPaneLocked(self, pane_id) orelse return true;
    if (pane.native.generation() != generation) return false;
    pane.alerts.exited = true;
    return true;
}

/// False only when `pane_id` exists and runs another generation.
pub fn isCurrentGeneration(self: *Manager, pane_id: []const u8, generation: u64) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = findPaneLocked(self, pane_id) orelse return true;
    return pane.native.generation() == generation;
}

/// Resolves `id` (pane id, session id, or session name) and returns a retained `NativeSession`.
pub fn find(self: *Manager, id: []const u8) ?*NativeSession {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = (resolveTargetPaneLocked(self, id) orelse return null).pane;
    pane.native.retain();
    return pane.native;
}

/// A session name must be valid text, must not equal any existing id
/// (ids always win lookups, so the name would be unreachable), and must
/// be unique. `exclude` is the session being renamed.
pub fn validateSessionNameLocked(self: *Manager, name: []const u8, exclude: ?*Session) !void {
    try validateNameText(name);
    if (idExistsLocked(self, name, exclude)) return error.NameShadowsId;
    for (self.sessions.items) |session| {
        if (session == exclude) continue;
        if (std.mem.eql(u8, session.name, name)) return error.DuplicateSessionName;
    }
}

/// True when `text` equals a session, window, or pane id. The id of
/// `exclude` itself does not count.
pub fn idExistsLocked(self: *Manager, text: []const u8, exclude: ?*Session) bool {
    for (self.sessions.items) |session| {
        if (session != exclude and std.mem.eql(u8, session.id, text)) return true;
        for (session.windows.items) |window| {
            if (std.mem.eql(u8, window.id, text)) return true;
            for (window.panes.items) |pane| {
                if (std.mem.eql(u8, pane.id, text)) return true;
            }
        }
    }
    return false;
}

/// Exact id first, then name, so an id always wins.
pub fn findSessionLocked(self: *Manager, id: []const u8) ?*Session {
    for (self.sessions.items) |session| {
        if (std.mem.eql(u8, session.id, id)) return session;
    }
    for (self.sessions.items) |session| {
        if (std.mem.eql(u8, session.name, id)) return session;
    }
    return null;
}

/// Exact id first, then name. Window names are only unique per session,
/// so a name lookup returns the first match.
pub fn findWindowWithParentLocked(self: *Manager, id: []const u8) ?WindowRef {
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            if (std.mem.eql(u8, window.id, id)) return .{ .session = session, .window = window };
        }
    }
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            if (std.mem.eql(u8, window.name, id)) return .{ .session = session, .window = window };
        }
    }
    return null;
}

/// Looks up a pane and its owning `(session, window)` by exact pane id while `mutex` is held.
pub fn findPaneWithParentsLocked(self: *Manager, id: []const u8) ?PaneRef {
    return self.panes_by_id.get(id);
}

/// Resolves a target identifier to a pane: tries pane id first, then session
/// id, then session name (selecting that session's active window and pane).
pub fn resolveTargetPaneLocked(self: *Manager, id: []const u8) ?PaneRef {
    if (findPaneWithParentsLocked(self, id)) |hit| return hit;

    const session = findSessionLocked(self, id) orelse return null;
    for (session.windows.items) |window| {
        if (!std.mem.eql(u8, window.id, session.active_window_id)) continue;
        const hit = self.panes_by_id.get(window.active_pane_id) orelse return null;
        return if (hit.window == window) hit else null;
    }
    return null;
}

/// Resolves a pane id, session id, or session name to its owning `Session` while `mutex` is held.
pub fn resolveTargetSessionLocked(self: *Manager, id: []const u8) ?*Session {
    if (findPaneWithParentsLocked(self, id)) |hit| return hit.session;
    return findSessionLocked(self, id);
}

/// Looks up a `Pane` by exact id while `mutex` is held.
pub fn findPaneLocked(self: *Manager, id: []const u8) ?*Pane {
    const found = findPaneWithParentsLocked(self, id) orelse return null;
    assert(std.mem.eql(u8, found.pane.id, id));
    return found.pane;
}

/// Looks up an attached `Client` by exact id while `mutex` is held.
pub fn findClientLocked(self: *Manager, id: []const u8) ?*Client {
    return self.clients_by_id.get(id);
}

test "attachClient resolves a session name to its active pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });

    defer pane.deinit();
    const expected_pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
    defer std.testing.allocator.free(expected_pane_id);

    var client = try manager.attachClient("work", 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected_pane_id, client.pane_id);
}

test "attachClient still resolves an explicit pane id" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });

    defer pane.deinit();
    const pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
    defer std.testing.allocator.free(pane_id);

    var client = try manager.attachClient(pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(pane_id, client.pane_id);
}

test "attachClient on an unknown name returns PaneNotFound" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    discardHandle(try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    }));
    try std.testing.expectError(error.PaneNotFound, manager.attachClient("ghost", 24, 80));
}

test "session-targeted APIs resolve pane id session id and session name" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });

    defer pane.deinit();
    const pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
    defer std.testing.allocator.free(pane_id);
    const session_id = try std.testing.allocator.dupe(u8, pane.session_id);
    defer std.testing.allocator.free(session_id);

    const by_session_id = manager.find(session_id) orelse return error.MissingSession;
    defer by_session_id.release();
    try std.testing.expectEqualStrings(pane_id, by_session_id.id);

    const by_name = manager.find("work") orelse return error.MissingSession;
    defer by_name.release();
    try std.testing.expectEqualStrings(pane_id, by_name.id);

    try manager.renameSession(pane_id, "renamed-work");
    const by_renamed = manager.find("renamed-work") orelse return error.MissingSession;
    defer by_renamed.release();
    try std.testing.expectEqualStrings(pane_id, by_renamed.id);
}

test "session names reject duplicates, id shadowing, and invalid text" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var work = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });
    defer work.deinit();
    var other = try manager.createSessionPane(cat_opts);
    defer other.deinit();
    const spawned = manager.spawn_count;

    try std.testing.expectError(error.DuplicateSessionName, manager.createSessionPane(.{ .title = "work", .command = "cat" }));
    try std.testing.expectError(error.NameShadowsId, manager.createSessionPane(.{ .title = other.session_id, .command = "cat" }));
    try std.testing.expectError(error.NameShadowsId, manager.createSessionPane(.{ .title = work.pane_id, .command = "cat" }));
    try std.testing.expectError(error.InvalidName, manager.createSessionPane(.{ .title = "", .command = "cat" }));
    try std.testing.expectError(error.InvalidName, manager.createSessionPane(.{ .title = "a\x00b", .command = "cat" }));
    try std.testing.expectEqual(spawned, manager.spawn_count);

    try std.testing.expectError(error.DuplicateSessionName, manager.renameSession(other.session_id, "work"));
    try std.testing.expectError(error.NameShadowsId, manager.renameSession(other.session_id, work.window_id));
    try std.testing.expectError(error.InvalidName, manager.renameSession(other.session_id, ""));
    try manager.renameSession("work", "work");
    try manager.renameSession(other.session_id, "play");
    try std.testing.expectError(error.InvalidName, manager.renameWindow(work.window_id, ""));
    try std.testing.expectError(error.InvalidName, manager.renamePane(work.pane_id, "x\x00", true));
    try manager.checkInvariants(std.testing.allocator);
}

test "mark functions ignore stale generations and keep the event timestamp" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    const fresh = try manager.respawnPane(handle.pane_id, .{ .kill = true });
    fresh.release();

    manager.markActivity(handle.pane_id, 0, 111);
    manager.markBell(handle.pane_id, 0, 222);
    manager.markExited(handle.pane_id, 0);
    var state = try paneState(&manager, handle.pane_id);
    try std.testing.expect(!state.alerts.activity);
    try std.testing.expect(!state.alerts.bell);
    try std.testing.expect(!state.alerts.exited);

    manager.markActivity(handle.pane_id, 1, 333);
    manager.markBell(handle.pane_id, 1, 444);
    manager.markExited(handle.pane_id, 1);
    state = try paneState(&manager, handle.pane_id);
    try std.testing.expectEqual(@as(i64, 333), state.alerts.last_activity_ms);
    try std.testing.expectEqual(@as(i64, 444), state.alerts.last_bell_ms);
    try std.testing.expect(state.alerts.exited);

    // markExited takes a pane id; a session name must not match.
    manager.markExited(handle.session_id, 1);
}

test "renamePane updates the native title so list, info, and snapshot agree" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });
    defer handle.deinit();
    try manager.renamePane(handle.pane_id, "editor", true);

    const info = try handle.native.infoJson(std.testing.allocator);
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "\"title\":\"editor\"") != null);
    const list = try manager.listJson(std.testing.allocator);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"sessionName\":\"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"paneTitle\":\"editor\"") != null);
    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"title\":\"editor\"") != null);
}

fn selectPaneForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var other_window = try manager.newWindow(first.session_id, cat_opts);
    defer other_window.deinit();

    const result = manager.selectPane(first.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const session = manager.sessions.items[0];
        // All or nothing: the active window moves only with the pane.
        const expected = if (result) |_| first.window_id else |_| other_window.window_id;
        try std.testing.expectEqualStrings(expected, session.active_window_id);
    }
    try result;
}

test "selectPane allocation failures commit both selections or neither" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, selectPaneForFailureTest, .{});
}
