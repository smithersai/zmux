const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");

const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const limits_mod = @import("limits.zig");
const payload_mod = @import("payload.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const DropStats = payload_mod.DropStats;
const OutputMeta = payload_mod.OutputMeta;
const Payload = payload_mod.Payload;
const broadcast_queue_max_bytes = limits_mod.broadcast_queue_max_bytes;
const control_queue_max_bytes = limits_mod.control_queue_max_bytes;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const test_io = test_support_mod.test_io;

/// Queue a control notification (copying `bytes`).
pub fn enqueueBroadcast(self: *ClientConnection, bytes: []const u8) !void {
    const owned = try self.allocator.dupe(u8, bytes);
    const payload = Payload.create(self.allocator, owned, null) catch |err| {
        self.allocator.free(owned);
        return err;
    };
    defer payload.release();
    return self.enqueue(payload);
}

/// Queue `payload` for the writer thread. Errors other than
/// `ConnectionClosed` are terminal: the caller must `close()` the
/// connection.
///
/// `pane_output` past the high-water mark is never an error: the queued
/// output is dropped, recorded for a `pane_output_dropped` notice, and the
/// new event is queued. Control notifications past their own cap return
/// `ConnectionBacklogged`.
pub fn enqueue(self: *ClientConnection, payload: *Payload) !void {
    var stats: DropStats = .{};
    // Logged after the queue lock is released: a stalled log sink must
    // never block `close` or shutdown behind this connection's queue.
    defer stats.report();
    self.queue_mutex.lockUncancelable(self.io);
    defer self.queue_mutex.unlock(self.io);
    return self.enqueueLocked(payload, &stats);
}

/// Caller holds `queue_mutex`.
pub fn enqueueLocked(self: *ClientConnection, payload: *Payload, stats: *DropStats) !void {
    if (self.isClosed()) return error.ConnectionClosed;
    const len = payload.bytes.len;

    if (payload.output) |meta| {
        if (len > broadcast_queue_max_bytes) {
            try self.recordDropLocked(meta);
            self.noteDropped(1);
        } else {
            if (self.queued_output_bytes > broadcast_queue_max_bytes - len) {
                stats.* = try self.dropQueuedOutputLocked();
            }
            // Capacity first: a failed growth must not leak the ref.
            try self.queue.reserveOne(self.allocator);
            self.queue.pushAssumeCapacity(payload.retain());
            self.queued_output_bytes += len;
            assert(self.queued_output_bytes <= broadcast_queue_max_bytes);
        }
    } else {
        if (len > control_queue_max_bytes or self.queued_control_bytes > control_queue_max_bytes - len) {
            return error.ConnectionBacklogged;
        }
        try self.queue.reserveOne(self.allocator);
        self.queue.pushAssumeCapacity(payload.retain());
        self.queued_control_bytes += len;
        assert(self.queued_control_bytes <= control_queue_max_bytes);
    }

    try self.ensureWriterLocked();
    self.queue_condition.signal(self.io);
}

/// Count `count` undelivered events on this connection and on the server total.
pub fn noteDropped(self: *ClientConnection, count: u64) void {
    self.dropped_events += count;
    if (self.server) |server| _ = server.dropped_events.fetchAdd(count, .monotonic);
}

/// Drop every queued `pane_output`, keeping control notifications in
/// order. Caller holds `queue_mutex`.
pub fn dropQueuedOutputLocked(self: *ClientConnection) !DropStats {
    // Record first so an allocation failure leaves the queue untouched.
    var dropped_bytes: usize = 0;
    var dropped_count: u64 = 0;
    for (0..self.queue.len) |index| {
        const queued = self.queue.at(index);
        const meta = queued.output orelse continue;
        try self.recordDropLocked(meta);
        dropped_bytes += queued.bytes.len;
        dropped_count += 1;
    }

    var kept: usize = 0;
    const total = self.queue.len;
    for (0..total) |index| {
        const queued = self.queue.at(index);
        if (queued.output != null) {
            queued.release();
        } else {
            self.queue.set(kept, queued);
            kept += 1;
        }
    }
    assert(kept <= total);
    assert(kept + dropped_count == total);
    self.queue.len = kept;
    self.queued_output_bytes = 0;
    self.noteDropped(dropped_count);
    return .{ .dropped_bytes = dropped_bytes, .dropped_events = dropped_count };
}

/// One record per pane. Offsets restart with each generation, so they
/// are combined only within a generation: a newer generation resets the
/// record, and an older one is ignored once a newer one is recorded.
pub fn recordDropLocked(self: *ClientConnection, meta: OutputMeta) !void {
    for (self.dropped.items) |*record| {
        if (std.mem.eql(u8, record.pane_id, meta.pane_id)) {
            if (meta.generation < record.generation) return;
            if (meta.generation > record.generation) {
                record.generation = meta.generation;
                record.dropped_bytes = meta.data_len;
                record.resume_offset = meta.end_offset;
                return;
            }
            record.dropped_bytes += meta.data_len;
            record.resume_offset = @max(record.resume_offset, meta.end_offset);
            return;
        }
    }
    const pane_id = try self.allocator.dupe(u8, meta.pane_id);
    errdefer self.allocator.free(pane_id);
    try self.dropped.append(self.allocator, .{
        .pane_id = pane_id,
        .dropped_bytes = meta.data_len,
        .resume_offset = meta.end_offset,
        .generation = meta.generation,
    });
}

/// Pop the oldest drop record as a `pane_output_dropped` notification. Caller holds `queue_mutex`.
pub fn takeDropNoticeLocked(self: *ClientConnection) !*Payload {
    assert(self.dropped.items.len > 0);
    const record = self.dropped.items[0];
    var params: protocol.PaneOutputDroppedParams = .{
        .pane_id = record.pane_id,
        .dropped_bytes = record.dropped_bytes,
        .resume_offset = record.resume_offset,
    };
    if (comptime @hasField(protocol.PaneOutputDroppedParams, "generation")) params.generation = record.generation;
    const bytes = try protocol.notification(self.allocator, protocol.pane_output_dropped_method, params);
    const payload = Payload.create(self.allocator, bytes, null) catch |err| {
        self.allocator.free(bytes);
        return err;
    };
    _ = self.dropped.orderedRemove(0);
    self.allocator.free(record.pane_id);
    return payload;
}

test "queued control notifications survive an output drop in order" {
    const sockets = try sys.socketPair();
    defer sys.close(sockets[1]);
    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    defer connection.release();

    const chunk = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'o');

    try connection.enqueueBroadcast("control-1\n");
    var index: u64 = 0;
    while (index < 8) : (index += 1) try fuzz_hooks.enqueuePaneOutput(connection, "pane-a", chunk, index * chunk.len);
    try connection.enqueueBroadcast("control-2\n");
    while (index < 16) : (index += 1) try fuzz_hooks.enqueuePaneOutput(connection, "pane-b", chunk, index * chunk.len);
    try std.testing.expectEqual(@as(u64, 0), connection.dropped_events);

    // One more chunk passes the 1 MiB mark: all 16 queued chunks are dropped.
    try fuzz_hooks.enqueuePaneOutput(connection, "pane-a", chunk, 16 * chunk.len);
    try std.testing.expectEqual(@as(u64, 16), connection.dropped_events);
    try std.testing.expect(!connection.isClosed());

    const expected = [_][]const u8{
        "\"pane_id\":\"pane-a\",\"dropped_bytes\":524288,\"resume_offset\":524288",
        "\"pane_id\":\"pane-b\",\"dropped_bytes\":524288,\"resume_offset\":1048576",
        "control-1\n",
        "control-2\n",
    };
    for (expected) |needle| {
        const frame = fuzz_hooks.takeQueuedWrite(connection) orelse return error.NothingQueued;
        defer std.testing.allocator.free(frame);
        if (std.mem.indexOf(u8, frame, needle) == null) {
            std.debug.print("frame {s} lacks {s}\n", .{ frame[0..@min(frame.len, 200)], needle });
            return error.FrameMismatch;
        }
    }
    const survivor = fuzz_hooks.takeQueuedWrite(connection) orelse return error.NothingQueued;
    defer std.testing.allocator.free(survivor);
    try std.testing.expectEqual(chunk.len, survivor.len);
    try std.testing.expect(fuzz_hooks.takeQueuedWrite(connection) == null);
}

test "control backlog past its own cap is the only queue condition that fails" {
    const sockets = try sys.socketPair();
    defer sys.close(sockets[1]);
    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    defer connection.release();

    const chunk = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'c');

    var queued: usize = 0;
    while (queued < control_queue_max_bytes) : (queued += chunk.len) try connection.enqueueBroadcast(chunk);
    try std.testing.expectError(error.ConnectionBacklogged, connection.enqueueBroadcast(chunk));
    // enqueue reports; the caller (Server.deliver) closes.
    try std.testing.expect(!connection.isClosed());
}
