const std = @import("std");
const assert = std.debug.assert;
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");
const NativeSession = native_mod.NativeSession;

const connection_mod = @import("connection.zig");
const limits_mod = @import("limits.zig");
const payload_mod = @import("payload.zig");
const rpc_session_mod = @import("rpc_session.zig");
const Attachment = payload_mod.Attachment;
const ClientConnection = connection_mod.ClientConnection;
const DropStats = payload_mod.DropStats;
const Payload = payload_mod.Payload;
const attach_replay_max_bytes = limits_mod.attach_replay_max_bytes;
const base64Encode = rpc_session_mod.base64Encode;
const client_switched_method = limits_mod.client_switched_method;

/// Record that this connection owns mux client `client_id`, viewing
/// `pane_id`. Attaching subscribes the connection to that pane's output.
pub fn trackMuxClient(self: *ClientConnection, client_id: []const u8, pane_id: []const u8) !void {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);

    for (self.attachments.items) |*active| {
        if (std.mem.eql(u8, active.client_id, client_id)) {
            const next = try self.allocator.dupe(u8, pane_id);
            self.allocator.free(active.pane_id);
            active.pane_id = next;
            return;
        }
    }

    const owned_client = try self.allocator.dupe(u8, client_id);
    errdefer self.allocator.free(owned_client);
    const owned_pane = try self.allocator.dupe(u8, pane_id);
    errdefer self.allocator.free(owned_pane);
    try self.attachments.append(self.allocator, .{ .client_id = owned_client, .pane_id = owned_pane });
    assert(self.attachments.items.len > 0);
}

/// Point an owned client at another pane. False when not owned here.
pub fn switchMuxClientPane(self: *ClientConnection, client_id: []const u8, pane_id: []const u8) !bool {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);
    for (self.attachments.items) |*active| {
        if (std.mem.eql(u8, active.client_id, client_id)) {
            const next = try self.allocator.dupe(u8, pane_id);
            self.allocator.free(active.pane_id);
            active.pane_id = next;
            return true;
        }
    }
    return false;
}

/// Move an owned client to `native`'s pane and queue its
/// `client_switched` notice in one `queue_mutex` critical section. Output
/// is queued under the same mutex, so nothing from the new pane precedes
/// the notice. The replay is read after the route is installed, so output
/// before `replayEndOffset` is in the replay and anything later is
/// delivered (a client drops the overlap by offset).
pub fn switchRouteAndNotify(self: *ClientConnection, client_id: []const u8, native: *NativeSession) !void {
    const next = try self.allocator.dupe(u8, native.id);
    var next_owned = true;
    defer if (next_owned) self.allocator.free(next);

    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    if (self.isClosed()) return error.ConnectionClosed;
    {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);
        const active = for (self.attachments.items) |*active| {
            if (std.mem.eql(u8, active.client_id, client_id)) break active;
        } else return error.ClientNotFound;
        self.allocator.free(active.pane_id);
        active.pane_id = next;
        next_owned = false;
    }

    const generation = native.generation();
    const tail = try native.scrollbackTail(self.allocator, attach_replay_max_bytes);
    defer self.allocator.free(tail.bytes);
    assert(tail.end_offset - tail.start_offset == tail.bytes.len);
    const replay_b64 = try base64Encode(self.allocator, tail.bytes);
    defer self.allocator.free(replay_b64);
    const bytes = try protocol.notification(self.allocator, client_switched_method, .{
        .client_id = client_id,
        .pane_id = native.id,
        .generation = generation,
        .replayBase64 = replay_b64,
        .replayStartOffset = tail.start_offset,
        .replayEndOffset = tail.end_offset,
    });
    const payload = Payload.create(self.allocator, bytes, null) catch |err| {
        self.allocator.free(bytes);
        return err;
    };
    defer payload.release();
    var stats: DropStats = .{};
    try self.enqueueLocked(payload, &stats);
    std.debug.assert(stats.dropped_events == 0);
}

/// Forget `client_id` on this connection. Returns true when it was tracked here.
pub fn untrackMuxClient(self: *ClientConnection, client_id: []const u8) bool {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);

    for (self.attachments.items, 0..) |active, index| {
        if (std.mem.eql(u8, active.client_id, client_id)) {
            const removed = self.attachments.swapRemove(index);
            assert(removed.client_id.ptr == active.client_id.ptr);
            removed.deinit(self.allocator);
            return true;
        }
    }
    return false;
}

/// True when this connection tracks the mux client `client_id`.
pub fn ownsMuxClient(self: *ClientConnection, client_id: []const u8) bool {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);
    for (self.attachments.items) |active| {
        if (std.mem.eql(u8, active.client_id, client_id)) return true;
    }
    return false;
}

/// Number of mux clients this connection currently owns.
pub fn attachedClientCount(self: *ClientConnection) usize {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);
    return self.attachments.items.len;
}

/// Move every tracked attachment out to the caller, who then owns and frees them.
pub fn takeMuxClients(self: *ClientConnection) std.ArrayList(Attachment) {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);

    const attached = self.attachments;
    self.attachments = .empty;
    assert(self.attachments.items.len == 0);
    return attached;
}

/// Replace the `events.subscribe` set. `all` subscribes to every pane.
pub fn setSubscriptions(self: *ClientConnection, all: bool, pane_ids: []const []const u8) !void {
    var next: std.ArrayList([]u8) = .empty;
    errdefer {
        for (next.items) |pane_id| self.allocator.free(pane_id);
        next.deinit(self.allocator);
    }
    try next.ensureTotalCapacity(self.allocator, pane_ids.len);
    for (pane_ids) |pane_id| next.appendAssumeCapacity(try self.allocator.dupe(u8, pane_id));
    assert(next.items.len == pane_ids.len);

    self.attachment_mutex.lockUncancelable(self.io);
    var previous = self.subscribed_panes;
    self.subscribed_panes = next;
    self.subscribe_all = all;
    self.attachment_mutex.unlock(self.io);

    for (previous.items) |pane_id| self.allocator.free(pane_id);
    previous.deinit(self.allocator);
}

/// True when `pane_output` for `pane_id` is delivered here (D1): a mux
/// client attached to the pane, or an `events.subscribe` that covers it.
pub fn wantsPaneOutput(self: *ClientConnection, pane_id: []const u8) bool {
    self.attachment_mutex.lockUncancelable(self.io);
    defer self.attachment_mutex.unlock(self.io);
    if (self.subscribe_all) return true;
    for (self.attachments.items) |active| {
        if (std.mem.eql(u8, active.pane_id, pane_id)) return true;
    }
    for (self.subscribed_panes.items) |subscribed| {
        if (std.mem.eql(u8, subscribed, pane_id)) return true;
    }
    return false;
}
