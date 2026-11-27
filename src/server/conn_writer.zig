const std = @import("std");
const assert = std.debug.assert;
const sys = @import("../sys.zig");

const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const limits_mod = @import("limits.zig");
const payload_mod = @import("payload.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const Payload = payload_mod.Payload;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const test_io = test_support_mod.test_io;
const writer_batch_max = limits_mod.writer_batch_max;
const writer_coalesce_bytes = limits_mod.writer_coalesce_bytes;

/// Start the writer thread on the first queued notification, so a
/// connection that only exchanges requests and responses costs one
/// thread. Caller holds `queue_mutex`; `close` takes the same mutex, so
/// no writer starts after the connection is closed.
///
/// Threads keep the default stack size: `std.Thread.spawn` treats a
/// stack too small for the process's static TLS as unreachable, and the
/// default is only reserved address space, not committed memory.
pub fn ensureWriterLocked(self: *ClientConnection) !void {
    if (self.writer_started) return;
    const server = self.server orelse return;
    _ = self.retain();
    server.addActiveWriter();
    const thread = std.Thread.spawn(.{}, ClientConnection.writerThread, .{self}) catch |err| {
        server.finishActiveWriter();
        // The caller still holds a reference, so this is never the last.
        _ = self.ref_count.fetchSub(1, .seq_cst);
        return err;
    };
    thread.detach();
    self.writer_started = true;
}

/// Writer thread body: drains the queue to the socket until the connection closes, then releases its reference.
pub fn writerThread(self: *ClientConnection) void {
    defer {
        // Release before signalling the server: when this thread holds the
        // last reference, release() frees the connection and its queued
        // payloads, and waitForWorkers must not let deinit (and the test
        // runner's leak check) proceed until that has happened. Copy the
        // server pointer out first: `self` is invalid after release().
        const server = self.server;
        self.release();
        if (server) |active| active.finishActiveWriter();
    }

    var batch: [writer_batch_max]*Payload = undefined;
    while (true) {
        const count = self.takeQueuedBatch(&batch);
        if (count == 0) return;
        defer for (batch[0..count]) |payload| payload.release();
        self.writeBatch(batch[0..count]) catch return;
    }
}

/// Write `batch` in queue order under one `write_mutex` hold. Frames that
/// fit in `writer_coalesce_bytes` go out in one syscall.
pub fn writeBatch(self: *ClientConnection, batch: []const *Payload) !void {
    assert(batch.len > 0);
    if (batch.len == 1) return self.write(batch[0].bytes);

    var total: usize = 0;
    for (batch) |payload| total += payload.bytes.len;

    if (total <= writer_coalesce_bytes) {
        var coalesce_buf: [writer_coalesce_bytes]u8 = undefined;
        var pos: usize = 0;
        for (batch) |payload| {
            @memcpy(coalesce_buf[pos..][0..payload.bytes.len], payload.bytes);
            pos += payload.bytes.len;
        }
        assert(pos == total);
        return self.write(coalesce_buf[0..pos]);
    }

    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    for (batch) |payload| try self.writeLocked(payload.bytes);
}

/// Take up to `out.len` payloads in delivery order (drop notices first,
/// as in `takeWrite`), blocking until at least one is queued. Returns 0
/// once the connection is closed. The caller releases each payload.
pub fn takeQueuedBatch(self: *ClientConnection, out: []*Payload) usize {
    assert(out.len > 0);
    var failed = false;
    const count: usize = blk: {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        while (!self.isClosed() and self.dropped.items.len == 0 and self.queue.len == 0) {
            self.queue_condition.waitUncancelable(self.io, &self.queue_mutex);
        }
        if (self.isClosed()) break :blk 0;

        var count: usize = 0;
        while (count < out.len) {
            if (self.dropped.items.len > 0) {
                out[count] = self.takeDropNoticeLocked() catch {
                    // Write what is already taken; a later call retries.
                    if (count == 0) failed = true;
                    break;
                };
            } else if (self.queue.pop()) |payload| {
                if (payload.output != null) {
                    assert(self.queued_output_bytes >= payload.bytes.len);
                    self.queued_output_bytes -= payload.bytes.len;
                } else {
                    assert(self.queued_control_bytes >= payload.bytes.len);
                    self.queued_control_bytes -= payload.bytes.len;
                }
                out[count] = payload;
            } else break;
            count += 1;
        }
        assert(count <= out.len);
        break :blk count;
    };
    // A client that cannot be told about a gap must not keep reading a
    // stream it believes is contiguous.
    if (failed) self.close();
    return count;
}

/// Next payload to write, blocking until one is queued or the connection
/// closes (null). The caller releases the payload.
pub fn takeQueuedWrite(self: *ClientConnection) ?*Payload {
    return self.takeWrite(true);
}

/// `takeQueuedWrite` that returns null instead of blocking.
pub fn tryTakeQueuedWrite(self: *ClientConnection) ?*Payload {
    return self.takeWrite(false);
}

/// Next payload to send, drop notices first. Blocks for one when `wait` is set; null once closed or empty.
pub fn takeWrite(self: *ClientConnection, wait: bool) ?*Payload {
    var failed = false;
    const taken: ?*Payload = blk: {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        while (true) {
            if (self.isClosed()) break :blk null;
            // Drop notices go first: every output still queued for the
            // pane starts at or after the notice's resume offset.
            if (self.dropped.items.len > 0) {
                break :blk self.takeDropNoticeLocked() catch {
                    failed = true;
                    break :blk null;
                };
            }
            if (self.queue.pop()) |payload| {
                if (payload.output != null) {
                    assert(self.queued_output_bytes >= payload.bytes.len);
                    self.queued_output_bytes -= payload.bytes.len;
                } else {
                    assert(self.queued_control_bytes >= payload.bytes.len);
                    self.queued_control_bytes -= payload.bytes.len;
                }
                break :blk payload;
            }
            if (!wait) break :blk null;
            self.queue_condition.waitUncancelable(self.io, &self.queue_mutex);
        }
    };
    // A client that cannot be told about a gap must not keep reading a
    // stream it believes is contiguous.
    if (failed) self.close();
    return taken;
}

test "writer batches keep drop notices first and coalesce frames in order" {
    const sockets = try sys.socketPair();
    defer sys.close(sockets[1]);
    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    defer connection.release();

    const chunk = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'o');

    try connection.enqueueBroadcast("control-1\n");
    var index: u64 = 0;
    while (index < 16) : (index += 1) try fuzz_hooks.enqueuePaneOutput(connection, "pane-a", chunk, index * chunk.len);
    try connection.enqueueBroadcast("control-2\n");
    try std.testing.expectEqual(@as(usize, 18), connection.pendingWriteCount());
    // Past 1 MiB: the 16 queued chunks drop; one notice, then both controls.
    try fuzz_hooks.enqueuePaneOutput(connection, "pane-a", "tail", 16 * chunk.len);
    try std.testing.expectEqual(@as(usize, 3), connection.pendingWriteCount());

    var batch: [writer_batch_max]*Payload = undefined;
    const count = connection.takeQueuedBatch(&batch);
    defer for (batch[0..count]) |payload| payload.release();
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expect(std.mem.indexOf(u8, batch[0].bytes, "\"resume_offset\":1048576") != null);
    try std.testing.expectEqualStrings("control-1\n", batch[1].bytes);
    try std.testing.expectEqualStrings("control-2\n", batch[2].bytes);
    try std.testing.expectEqualStrings("tail", batch[3].bytes);
    try std.testing.expectEqual(@as(usize, 0), connection.queued_output_bytes);
    try std.testing.expectEqual(@as(usize, 0), connection.queued_control_bytes);

    try connection.writeBatch(batch[0..count]);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (batch[0..count]) |payload| try expected.appendSlice(std.testing.allocator, payload.bytes);
    var received: [4096]u8 = undefined;
    var got: usize = 0;
    while (got < expected.items.len) {
        const n = std.c.read(sockets[1], received[got..].ptr, received.len - got);
        try std.testing.expect(n > 0);
        got += @intCast(n);
    }
    try std.testing.expectEqualSlices(u8, expected.items, received[0..got]);

    connection.close();
    try std.testing.expectEqual(@as(usize, 0), connection.takeQueuedBatch(&batch));
}
