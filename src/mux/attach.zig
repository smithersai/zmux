//! Logical clients: attach, detach, switch, and resize, plus pruning of
//! clients whose pane or session goes away.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const lookup = @import("lookup.zig");
const creation = @import("creation.zig");
const removal = @import("removal.zig");
const layout_ops = @import("layout_ops.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const AttachOptions = types.AttachOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const AttachResult = types.AttachResult;
const ClientSnapshot = types.ClientSnapshot;
const DetachReason = types.DetachReason;
const DetachedClient = types.DetachedClient;
const Pane = types.Pane;
const cat_opts = mux.test_support.cat_opts;
const waitForNoLivePanes = mux.test_support.waitForNoLivePanes;
const Client = types.Client;
const RemovedItems = types.RemovedItems;
const paneState = mux.test_support.paneState;

/// Attaches a logical client to `target_pane_id` with initial dimensions `(rows, cols)`.
pub fn attachClient(self: *Manager, target_pane_id: []const u8, rows: u16, cols: u16) !ClientSnapshot {
    return attachClientWithOptions(self, target_pane_id, rows, cols, .{});
}

/// Attaches a logical client with explicit observer (`read_only`) and `resize_policy` options.
pub fn attachClientWithOptions(
    self: *Manager,
    target_pane_id: []const u8,
    rows: u16,
    cols: u16,
    opts: AttachOptions,
) !ClientSnapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = lookup.resolveTargetPaneLocked(self, target_pane_id) orelse return error.PaneNotFound;
    return attachClientLocked(self, found, rows, cols, opts);
}

/// Attach a client to `target`, creating a session named `target` first
/// when `create_opts` is non-null and the target does not resolve. One
/// critical section covers lookup, creation, and attach. Never fails on an
/// exited pane; reports `exited` and `exit` instead.
pub fn attachOrCreateClient(
    self: *Manager,
    target: []const u8,
    rows: u16,
    cols: u16,
    create_opts: ?CreateOptions,
) !AttachResult {
    return attachOrCreateClientWithOptions(self, target, rows, cols, create_opts, .{});
}

/// Like `attachOrCreateClient`, honoring observer `read_only` and `resize_policy` options.
pub fn attachOrCreateClientWithOptions(
    self: *Manager,
    target: []const u8,
    rows: u16,
    cols: u16,
    create_opts: ?CreateOptions,
    attach_opts: AttachOptions,
) !AttachResult {
    // Declared before the lock so a rollback tears down after unlock.
    var rollback: RemovedItems = .{};
    defer rollback.deinit(self.allocator);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var created = false;
    const found: PaneRef = lookup.resolveTargetPaneLocked(self, target) orelse blk: {
        var opts = create_opts orelse return error.PaneNotFound;
        if (self.clients.items.len >= self.limits.max_clients) return error.LimitExceeded;
        if (opts.title == null) opts.title = target;
        var handle = try creation.createSessionPaneLocked(self, opts, target);
        // Not the last reference: the pane holds one under this lock.
        defer handle.deinit();
        created = true;
        break :blk lookup.findPaneWithParentsLocked(self, handle.pane_id).?;
    };
    assert(!created or found.window.panes.items.len == 1);
    errdefer if (created) {
        rollback = removal.takeSessionLocked(self, found.session);
    };

    const client = try attachClientLocked(self, found, rows, cols, attach_opts);
    const exit = found.pane.native.finalizedExitInfo();
    return .{
        .client = client,
        .created = created,
        .exited = exit != null,
        .exit = exit,
        .generation = found.pane.native.generation(),
    };
}

/// Detach at the owner's request. Records nothing in `takeDetachedClients`.
pub fn detachClient(self: *Manager, client_id: []const u8) bool {
    return detachClientWithReason(self, client_id, null);
}

/// Detach a client on behalf of a connection that does not own it. The
/// client is reported by `takeDetachedClients` with `.remote_detach` so the
/// server can notify the owner.
pub fn detachClientRemote(self: *Manager, client_id: []const u8) bool {
    return detachClientWithReason(self, client_id, .remote_detach);
}

/// Detaches `client_id` and records `reason` in the detached queue when non-null.
pub fn detachClientWithReason(self: *Manager, client_id: []const u8, reason: ?DetachReason) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const client = self.clients_by_id.get(client_id) orelse return false;
    assert(self.clients.items.len == self.clients_by_id.count());
    const index = std.mem.indexOfScalar(*Client, self.clients.items, client).?;
    removeClientAtLocked(self, index, reason);
    return true;
}

/// Clients pruned by pane or session removal, or detached remotely, since
/// the last call. Caller frees with `freeDetachedClients(allocator, ...)`.
pub fn takeDetachedClients(self: *Manager, allocator: Allocator) ![]DetachedClient {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const result = try allocator.alloc(DetachedClient, self.detached_clients.items.len);
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |item| allocator.free(item.client_id);
        allocator.free(result);
    }
    for (self.detached_clients.items) |item| {
        result[filled] = .{ .client_id = try allocator.dupe(u8, item.client_id), .reason = item.reason };
        filled += 1;
    }
    assert(filled == result.len);
    for (self.detached_clients.items) |item| self.allocator.free(item.client_id);
    self.detached_clients.clearRetainingCapacity();
    return result;
}

/// Moves the client to `pane_id` and resizes that pane to the client's
/// size (last writer wins). All allocation happens before any change.
pub fn switchClient(self: *Manager, client_id: []const u8, pane_id: []const u8) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const client = lookup.findClientLocked(self, client_id) orelse return error.ClientNotFound;
    const found = lookup.findPaneWithParentsLocked(self, pane_id) orelse return error.PaneNotFound;
    const session_id = try self.allocator.dupe(u8, found.session.id);
    errdefer self.allocator.free(session_id);
    const window_id = try self.allocator.dupe(u8, found.window.id);
    errdefer self.allocator.free(window_id);
    const owned_pane_id = try self.allocator.dupe(u8, found.pane.id);
    errdefer self.allocator.free(owned_pane_id);
    if (layout_ops.resolveClientGeometryLocked(
        self,
        found.pane,
        client,
        client.rows,
        client.cols,
        client.read_only,
        client.resize_policy,
    )) |sz| {
        try applyPaneSize(found.pane, sz.rows, sz.cols);
    }

    self.allocator.free(client.session_id);
    client.session_id = session_id;
    self.allocator.free(client.window_id);
    client.window_id = window_id;
    self.allocator.free(client.pane_id);
    client.pane_id = owned_pane_id;
}

/// Resize a pane: the native PTY (when running), the spawn spec used by
/// respawn, and every client attached to the pane. Last writer wins;
/// detaching does not restore an earlier size.
pub fn resizePane(self: *Manager, pane_id: []const u8, rows: u16, cols: u16) !void {
    if (rows == 0 or cols == 0) return error.InvalidDimensions;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const pane = lookup.findPaneLocked(self, pane_id) orelse return error.PaneNotFound;
    try applyPaneSize(pane, rows, cols);
    for (self.clients.items) |client| {
        if (!std.mem.eql(u8, client.pane_id, pane.id)) continue;
        client.rows = rows;
        client.cols = cols;
    }
}

/// All fallible work (limits, reservations, allocation, resize) happens
/// before the client is recorded. Skips the resize on an exited pane or
/// when `opts.read_only` / `opts.resize_policy == .none`.
pub fn attachClientLocked(
    self: *Manager,
    found: PaneRef,
    rows: u16,
    cols: u16,
    opts: AttachOptions,
) !ClientSnapshot {
    if (self.clients.items.len >= self.limits.max_clients) return error.LimitExceeded;
    try self.detached_clients.ensureTotalCapacity(
        self.allocator,
        self.detached_clients.items.len + self.clients.items.len + 1,
    );
    try self.clients.ensureUnusedCapacity(self.allocator, 1);
    try self.clients_by_id.ensureUnusedCapacity(self.allocator, 1);

    const client_id = try creation.nextIdLocked(self, "client", &self.next_client_id);
    errdefer self.allocator.free(client_id);
    const session_id = try self.allocator.dupe(u8, found.session.id);
    errdefer self.allocator.free(session_id);
    const window_id = try self.allocator.dupe(u8, found.window.id);
    errdefer self.allocator.free(window_id);
    const pane_id = try self.allocator.dupe(u8, found.pane.id);
    errdefer self.allocator.free(pane_id);
    const client = try self.allocator.create(Client);
    errdefer self.allocator.destroy(client);
    client.* = .{
        .id = client_id,
        .session_id = session_id,
        .window_id = window_id,
        .pane_id = pane_id,
        .rows = rows,
        .cols = cols,
        .read_only = opts.read_only,
        .resize_policy = opts.resize_policy,
    };
    var snapshot = try ClientSnapshot.fromClient(self.allocator, client);
    errdefer snapshot.deinit(self.allocator);
    if (layout_ops.resolveClientGeometryLocked(
        self,
        found.pane,
        null,
        rows,
        cols,
        opts.read_only,
        opts.resize_policy,
    )) |sz| {
        try applyPaneSize(found.pane, sz.rows, sz.cols);
    }

    assert(self.detached_clients.capacity >= self.detached_clients.items.len + self.clients.items.len + 1);
    self.clients.appendAssumeCapacity(client);
    self.clients_by_id.putAssumeCapacity(client.id, client);
    assert(self.clients.items.len == self.clients_by_id.count());
    return snapshot;
}

/// Resize the native when it runs, then record the size in the spec.
fn applyPaneSize(pane: *Pane, rows: u16, cols: u16) !void {
    if (pane.native.isRunning()) {
        pane.native.resize(cols, rows) catch |err| switch (err) {
            // Exited between the check and the ioctl: same as not running.
            error.SessionTerminated => {},
            else => |other| return other,
        };
    }
    pane.spawn.rows = rows;
    pane.spawn.cols = cols;
}

/// Never allocates: `detached_clients` capacity is reserved at attach.
pub fn removeClientAtLocked(self: *Manager, index: usize, reason: ?DetachReason) void {
    assert(index < self.clients.items.len);
    const client = self.clients.orderedRemove(index);
    _ = self.clients_by_id.remove(client.id);
    if (reason) |why| {
        if (self.detached_clients.items.len < self.detached_clients.capacity) {
            self.detached_clients.appendAssumeCapacity(.{ .client_id = client.id, .reason = why });
            client.deinitKeepId(self.allocator);
            return;
        }
    }
    client.deinit(self.allocator);
}

const ClientLink = enum { session, pane };

/// Detaches all clients linked to `id` (session or pane) while `mutex` is held.
pub fn detachClientsLocked(self: *Manager, link: ClientLink, id: []const u8, reason: DetachReason) void {
    var index: usize = 0;
    while (index < self.clients.items.len) {
        const client = self.clients.items[index];
        const value = switch (link) {
            .session => client.session_id,
            .pane => client.pane_id,
        };
        if (std.mem.eql(u8, value, id)) {
            removeClientAtLocked(self, index, reason);
        } else {
            index += 1;
        }
    }
}

fn attachClientForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    });

    defer pane.deinit();
    var client = try manager.attachClient(pane.pane_id, 30, 100);
    defer client.deinit(allocator);
}

test "switchClient moves a logical client to another pane" {
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

    var client = try manager.attachClient(first_id, 25, 90);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first_id, client.pane_id);

    try manager.switchClient(client.id, second_id);
    try std.testing.expectEqual(@as(u16, 25), client.rows);
    try std.testing.expectEqual(@as(u16, 90), client.cols);

    const clients = try manager.clientsJson(std.testing.allocator);
    defer std.testing.allocator.free(clients);
    try std.testing.expect(std.mem.indexOf(u8, clients, second_id) != null);
}

test "manager attach allocation failures clean up client ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, attachClientForFailureTest, .{});
}

const AttachRace = struct {
    manager: *Manager,
    created: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),

    fn run(self: *AttachRace) void {
        var result = self.manager.attachOrCreateClient("work", 24, 80, cat_opts) catch {
            _ = self.failures.fetchAdd(1, .seq_cst);
            return;
        };
        defer result.client.deinit(std.testing.allocator);
        if (result.created) _ = self.created.fetchAdd(1, .seq_cst);
    }
};

test "attachOrCreateClient creates exactly one session under concurrent callers" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var race: AttachRace = .{ .manager = &manager };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, AttachRace.run, .{&race});
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), race.failures.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), race.created.load(.seq_cst));
    const totals = manager.counts();
    try std.testing.expectEqual(@as(usize, 1), totals.sessions);
    try std.testing.expectEqual(@as(usize, 1), totals.panes);
    try manager.checkInvariants(std.testing.allocator);

    const list = try manager.listJson(std.testing.allocator);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"sessionName\":\"work\"") != null);
}

test "attachOrCreateClient succeeds on an exited pane and reports exit info" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(.{ .title = "done", .shell = "/bin/sh", .command = "true" });
    defer handle.deinit();
    try waitForNoLivePanes(&manager);

    var result = try manager.attachOrCreateClient("done", 30, 100, null);
    defer result.client.deinit(std.testing.allocator);
    try std.testing.expect(!result.created);
    try std.testing.expect(result.exited);
    try std.testing.expectEqual(@as(?u32, 0), result.exit.?.exit_code);
    try std.testing.expectEqual(@as(u64, 0), result.generation);
    try std.testing.expectEqualStrings(handle.pane_id, result.client.pane_id);

    // Plain attach and switch also skip the resize on an exited pane.
    var plain = try manager.attachClient(handle.pane_id, 40, 120);
    defer plain.deinit(std.testing.allocator);
    try manager.switchClient(plain.id, handle.pane_id);
    try std.testing.expectEqual(@as(u16, 40), (try paneState(&manager, handle.pane_id)).rows);
}

test "attachOrCreateClient without create options does not create" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    try std.testing.expectError(error.PaneNotFound, manager.attachOrCreateClient("ghost", 24, 80, null));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectError(error.InvalidName, manager.attachOrCreateClient("", 24, 80, cat_opts));
    try std.testing.expectEqual(@as(usize, 0), manager.spawn_count);
}

test "attachOrCreateClient rolls back the new session when attach fails" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    manager.limits.max_clients = 0;

    try std.testing.expectError(error.LimitExceeded, manager.attachOrCreateClient("work", 24, 80, cat_opts));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 0), manager.spawn_count);
}

test "resizePane updates the spec, attached clients, and respawn geometry" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    var client = try manager.attachClient(handle.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidDimensions, manager.resizePane(handle.pane_id, 0, 80));
    try std.testing.expectError(error.PaneNotFound, manager.resizePane("pane-ghost", 50, 200));
    try manager.resizePane(handle.pane_id, 50, 200);
    const fresh = try manager.respawnPane(handle.pane_id, .{ .kill = true });
    fresh.release();

    const state = try paneState(&manager, handle.pane_id);
    try std.testing.expectEqual(@as(u16, 50), state.rows);
    try std.testing.expectEqual(@as(u16, 200), state.cols);
    const clients = try manager.clientsJson(std.testing.allocator);
    defer std.testing.allocator.free(clients);
    try std.testing.expect(std.mem.indexOf(u8, clients, "\"rows\":50,\"cols\":200") != null);
}

fn switchClientForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var second = try manager.splitPane(first.pane_id, .vertical, cat_opts);
    defer second.deinit();
    var client = try manager.attachClient(first.pane_id, 24, 80);
    defer client.deinit(allocator);

    const result = manager.switchClient(client.id, second.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const expected = if (result) |_| second.pane_id else |_| first.pane_id;
        try std.testing.expectEqualStrings(expected, manager.clients.items[0].pane_id);
    }
    try result;
}

fn attachOrCreateForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const result = manager.attachOrCreateClient("work", 24, 80, cat_opts);
    try manager.checkInvariants(std.testing.allocator);
    var attached = result catch |err| {
        try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
        return err;
    };
    defer attached.client.deinit(allocator);
    try std.testing.expect(attached.created);
}

test "switchClient allocation failures leave the client fully on its old pane" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, switchClientForFailureTest, .{});
}

test "attachOrCreateClient allocation failures leave no session behind" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, attachOrCreateForFailureTest, .{});
}
