const std = @import("std");
const builtin = @import("builtin");

const buffer_mod = @import("buffer.zig");
const log = @import("log.zig");
const mux = @import("mux.zig");
const native_mod = @import("native.zig");
const protocol = @import("protocol.zig");
const rpc_line_reader = @import("rpc_line_reader.zig");
const socket_path_mod = @import("socket_path.zig");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const LineReader = rpc_line_reader.LineReader;
const Value = std.json.Value;
const posix = std.posix;

const max_request_bytes = 1024 * 1024;

/// Largest response the server writes. Clients size their receive limit to
/// match; a larger result fails with `LimitExceeded` instead of a frame the
/// client would reject.
pub const max_response_bytes: usize = 16 * 1024 * 1024;

/// Cap the raw scrollback replay delivered on attach. 256 KiB comfortably
/// covers a TUI's visible state + a few screenfuls of history while keeping
/// the attach payload bounded. When scrollback is larger, only the tail
/// (most recent bytes) is replayed.
const attach_replay_max_bytes: usize = 256 * 1024;

/// Cap on `session.capture`. The response carries the bytes twice (`text` and
/// `textBase64`), so this keeps the frame under `max_response_bytes`.
const capture_max_bytes: usize = 4 * 1024 * 1024;

/// High-water mark for `pane_output` queued on one connection. Past it the
/// queued output is dropped and replaced by one `pane_output_dropped` notice
/// per pane; the connection stays open.
const broadcast_queue_max_bytes: usize = 1024 * 1024;

/// Cap on queued control notifications (everything except `pane_output`). A
/// connection that exceeds it is not reading at all and is disconnected.
const control_queue_max_bytes: usize = 4 * 1024 * 1024;

/// A single serialized event larger than this is dropped instead of queued,
/// so one oversized event can never count as backlog on every connection.
const max_event_bytes: usize = broadcast_queue_max_bytes;

/// Most payloads one writer-thread wakeup takes from the queue.
const writer_batch_max = 16;
/// Batches up to this size are copied into one buffer and written with a
/// single syscall.
const writer_coalesce_bytes = 64 * 1024;

const socket_send_timeout_seconds: isize = 2;
/// Overall budget for writing one frame to a client, on every platform.
const send_deadline_ms: i64 = 5000;
/// A new connection must deliver its first complete frame within this time.
const first_frame_deadline_ms: i64 = 10_000;
/// Once a frame has started arriving it must complete within this time.
const partial_frame_deadline_ms: i64 = 30_000;

pub const max_client_connections: usize = 256;
/// Room for a compact mutation result (three generated ids, a generation, and
/// the envelope), reserved before the mutation commits.
const compact_reply_reserve_bytes: usize = 512;
const accept_backoff_ms: i64 = 50;
const stale_probe_timeout_ms: i64 = 1000;

/// Longest socket path `bind(2)` accepts: `sun_path` minus its NUL terminator
/// (103 bytes on macOS, 107 on Linux).
pub const max_socket_path_len: usize = sys.max_unix_path_len;

/// Name of the socket inside its private staging directory. Kept to one byte so
/// the staging path fits in `sun_path` for nearly every valid socket path.
const staged_socket_name = "s";
const staging_dir_prefix = ".zmux-";
const staging_dir_random_hex_max = 8;
const staging_dir_random_hex_min = 4;
const staging_dir_attempts = 16;

/// Sent to the owning connection when another connection switches its client.
const client_switched_method = "client_switched";

var accept_error_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var connection_limit_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var peer_rejected_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var spawn_failed_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var backlog_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var output_dropped_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var event_dropped_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var internal_error_limiter: log.RateLimiter = .{ .interval_ms = 1000 };
var sockopt_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

/// Stream position of one `pane_output` event, kept beside its serialized
/// bytes so a dropped event can be reported as `pane_output_dropped`.
const OutputMeta = struct {
    /// Owned by the payload.
    pane_id: []u8,
    /// Raw (pre-base64) byte count.
    data_len: u64,
    /// Stream offset one past the last byte.
    end_offset: u64,
    /// Pane generation; offsets restart at zero in each generation.
    generation: u64 = 0,
};

/// One serialized notification shared by every connection it is queued on.
const Payload = struct {
    allocator: Allocator,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    bytes: []u8,
    /// Set only for `pane_output`.
    output: ?OutputMeta = null,

    /// Takes ownership of `bytes` and `output.pane_id` on success only.
    fn create(allocator: Allocator, bytes: []u8, output: ?OutputMeta) !*Payload {
        const payload = try allocator.create(Payload);
        payload.* = .{ .allocator = allocator, .bytes = bytes, .output = output };
        return payload;
    }

    fn retain(self: *Payload) *Payload {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        return self;
    }

    fn release(self: *Payload) void {
        if (self.ref_count.fetchSub(1, .seq_cst) != 1) return;
        const allocator = self.allocator;
        if (self.output) |meta| allocator.free(meta.pane_id);
        allocator.free(self.bytes);
        allocator.destroy(self);
    }
};

/// Ring deque of queued payloads: O(1) push and pop.
const PayloadQueue = struct {
    items: []*Payload = &[_]*Payload{},
    head: usize = 0,
    len: usize = 0,

    fn deinit(self: *PayloadQueue, allocator: Allocator) void {
        allocator.free(self.items);
        self.* = .{};
    }

    fn push(self: *PayloadQueue, allocator: Allocator, payload: *Payload) !void {
        try self.reserveOne(allocator);
        self.pushAssumeCapacity(payload);
    }

    /// Grow so the next `pushAssumeCapacity` cannot fail.
    fn reserveOne(self: *PayloadQueue, allocator: Allocator) !void {
        if (self.len < self.items.len) return;
        const capacity = if (self.items.len == 0) 16 else self.items.len * 2;
        const next = try allocator.alloc(*Payload, capacity);
        for (0..self.len) |i| next[i] = self.at(i);
        allocator.free(self.items);
        self.items = next;
        self.head = 0;
    }

    fn pushAssumeCapacity(self: *PayloadQueue, payload: *Payload) void {
        std.debug.assert(self.len < self.items.len);
        self.items[(self.head + self.len) % self.items.len] = payload;
        self.len += 1;
    }

    fn pop(self: *PayloadQueue) ?*Payload {
        if (self.len == 0) return null;
        const payload = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return payload;
    }

    fn at(self: *const PayloadQueue, index: usize) *Payload {
        return self.items[(self.head + index) % self.items.len];
    }

    fn set(self: *PayloadQueue, index: usize, payload: *Payload) void {
        self.items[(self.head + index) % self.items.len] = payload;
    }
};

/// Output dropped for one pane on one connection, reported to the client as a
/// single `pane_output_dropped` before any later output of that pane.
const DropRecord = struct {
    pane_id: []u8,
    dropped_bytes: u64,
    resume_offset: u64,
    /// Offsets compare only within one generation.
    generation: u64 = 0,
};

/// Sizes of one output eviction, logged after `queue_mutex` is released.
const DropStats = struct {
    dropped_bytes: usize = 0,
    dropped_events: u64 = 0,

    fn report(self: DropStats) void {
        if (self.dropped_events == 0) return;
        // Sizes only: the queued bytes are PTY output and are never logged.
        log.warnRateLimited("client_output_dropped", &output_dropped_limiter, .{
            .dropped_bytes = self.dropped_bytes,
            .dropped_events = self.dropped_events,
            .max_queued_bytes = broadcast_queue_max_bytes,
        });
    }
};

/// A mux client this connection attached, and the pane it currently views.
const Attachment = struct {
    client_id: []u8,
    pane_id: []u8,

    fn deinit(self: Attachment, allocator: Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.pane_id);
    }
};

const ClientConnection = struct {
    allocator: Allocator,
    io: std.Io,
    fd: posix.fd_t,
    server: ?*Server = null,
    reader: LineReader = .{},
    write_mutex: std.Io.Mutex = .init,
    queue_mutex: std.Io.Mutex = .init,
    queue_condition: std.Io.Condition = .init,
    attachment_mutex: std.Io.Mutex = .init,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Guarded by queue_mutex.
    queue: PayloadQueue = .{},
    queued_output_bytes: usize = 0,
    queued_control_bytes: usize = 0,
    dropped: std.ArrayList(DropRecord) = .empty,
    writer_started: bool = false,
    /// `pane_output` events dropped on this connection since it opened.
    dropped_events: u64 = 0,

    // Guarded by attachment_mutex.
    attachments: std.ArrayList(Attachment) = .empty,
    subscribed_panes: std.ArrayList([]u8) = .empty,
    subscribe_all: bool = false,

    /// Puts `fd` in non-blocking mode: `writeAllDeadline` needs it, and the
    /// poll-driven reader treats `EAGAIN` as "poll again".
    fn create(allocator: Allocator, io: std.Io, fd: posix.fd_t, server: ?*Server) !*ClientConnection {
        try sys.setNonBlocking(fd);
        const connection = try allocator.create(ClientConnection);
        connection.* = .{
            .allocator = allocator,
            .io = io,
            .fd = fd,
            .server = server,
        };
        // Deadlines come from `io`; the reader must compare them on the same
        // clock provider.
        if (comptime @hasField(LineReader, "io")) connection.reader.io = io;
        return connection;
    }

    fn retain(self: *ClientConnection) *ClientConnection {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        return self;
    }

    fn release(self: *ClientConnection) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        if (prev == 1) {
            // Copy the allocator out of `self` before any destroy: reading
            // `self.allocator` after `destroy(self)` is a use-after-free.
            const allocator = self.allocator;
            for (self.attachments.items) |attachment| attachment.deinit(allocator);
            self.attachments.deinit(allocator);
            for (self.subscribed_panes.items) |pane_id| allocator.free(pane_id);
            self.subscribed_panes.deinit(allocator);
            while (self.queue.pop()) |payload| payload.release();
            self.queue.deinit(allocator);
            for (self.dropped.items) |record| allocator.free(record.pane_id);
            self.dropped.deinit(allocator);
            // A frame larger than the reader's fixed buffer lives on the heap.
            self.reader.deinit();
            sys.close(self.fd);
            allocator.destroy(self);
        }
    }

    fn isClosed(self: *const ClientConnection) bool {
        return self.closed.load(.seq_cst);
    }

    /// Payloads queued for the writer thread (drop notices excluded).
    pub fn pendingWriteCount(self: *ClientConnection) usize {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        return self.queue.len;
    }

    /// Mark closed and wake the reader and writer. Takes `queue_mutex`, so a
    /// writer thread is never started after `close` returns. Must not be
    /// called with `queue_mutex` held.
    fn close(self: *ClientConnection) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (!self.closed.swap(true, .seq_cst)) {
            _ = std.c.shutdown(self.fd, @intCast(posix.SHUT.RDWR));
            self.queue_condition.broadcast(self.io);
        }
    }

    fn write(self: *ClientConnection, bytes: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        return self.writeLocked(bytes);
    }

    /// Caller holds `write_mutex`.
    fn writeLocked(self: *ClientConnection, bytes: []const u8) !void {
        if (self.isClosed()) return error.ConnectionClosed;
        writeAllDeadline(self.fd, bytes, send_deadline_ms) catch |err| {
            self.close();
            return err;
        };
    }

    /// Queue a control notification (copying `bytes`).
    fn enqueueBroadcast(self: *ClientConnection, bytes: []const u8) !void {
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
    fn enqueue(self: *ClientConnection, payload: *Payload) !void {
        var stats: DropStats = .{};
        // Logged after the queue lock is released: a stalled log sink must
        // never block `close` or shutdown behind this connection's queue.
        defer stats.report();
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        return self.enqueueLocked(payload, &stats);
    }

    /// Caller holds `queue_mutex`.
    fn enqueueLocked(self: *ClientConnection, payload: *Payload, stats: *DropStats) !void {
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
            }
        } else {
            if (len > control_queue_max_bytes or self.queued_control_bytes > control_queue_max_bytes - len) {
                return error.ConnectionBacklogged;
            }
            try self.queue.reserveOne(self.allocator);
            self.queue.pushAssumeCapacity(payload.retain());
            self.queued_control_bytes += len;
        }

        try self.ensureWriterLocked();
        self.queue_condition.signal(self.io);
    }

    fn noteDropped(self: *ClientConnection, count: u64) void {
        self.dropped_events += count;
        if (self.server) |server| _ = server.dropped_events.fetchAdd(count, .monotonic);
    }

    /// Drop every queued `pane_output`, keeping control notifications in
    /// order. Caller holds `queue_mutex`.
    fn dropQueuedOutputLocked(self: *ClientConnection) !DropStats {
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
        self.queue.len = kept;
        self.queued_output_bytes = 0;
        self.noteDropped(dropped_count);
        return .{ .dropped_bytes = dropped_bytes, .dropped_events = dropped_count };
    }

    /// One record per pane. Offsets restart with each generation, so they
    /// are combined only within a generation: a newer generation resets the
    /// record, and an older one is ignored once a newer one is recorded.
    fn recordDropLocked(self: *ClientConnection, meta: OutputMeta) !void {
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

    /// Start the writer thread on the first queued notification, so a
    /// connection that only exchanges requests and responses costs one
    /// thread. Caller holds `queue_mutex`; `close` takes the same mutex, so
    /// no writer starts after the connection is closed.
    ///
    /// Threads keep the default stack size: `std.Thread.spawn` treats a
    /// stack too small for the process's static TLS as unreachable, and the
    /// default is only reserved address space, not committed memory.
    fn ensureWriterLocked(self: *ClientConnection) !void {
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

    fn writerThread(self: *ClientConnection) void {
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
    fn writeBatch(self: *ClientConnection, batch: []const *Payload) !void {
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
            return self.write(coalesce_buf[0..pos]);
        }

        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        for (batch) |payload| try self.writeLocked(payload.bytes);
    }

    /// Take up to `out.len` payloads in delivery order (drop notices first,
    /// as in `takeWrite`), blocking until at least one is queued. Returns 0
    /// once the connection is closed. The caller releases each payload.
    fn takeQueuedBatch(self: *ClientConnection, out: []*Payload) usize {
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
                        self.queued_output_bytes -= payload.bytes.len;
                    } else {
                        self.queued_control_bytes -= payload.bytes.len;
                    }
                    out[count] = payload;
                } else break;
                count += 1;
            }
            break :blk count;
        };
        // A client that cannot be told about a gap must not keep reading a
        // stream it believes is contiguous.
        if (failed) self.close();
        return count;
    }

    /// Next payload to write, blocking until one is queued or the connection
    /// closes (null). The caller releases the payload.
    fn takeQueuedWrite(self: *ClientConnection) ?*Payload {
        return self.takeWrite(true);
    }

    /// `takeQueuedWrite` that returns null instead of blocking.
    fn tryTakeQueuedWrite(self: *ClientConnection) ?*Payload {
        return self.takeWrite(false);
    }

    fn takeWrite(self: *ClientConnection, wait: bool) ?*Payload {
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
                        self.queued_output_bytes -= payload.bytes.len;
                    } else {
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

    fn takeDropNoticeLocked(self: *ClientConnection) !*Payload {
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

    // -- Subscriptions and attached mux clients ------------------------------

    /// Record that this connection owns mux client `client_id`, viewing
    /// `pane_id`. Attaching subscribes the connection to that pane's output.
    fn trackMuxClient(self: *ClientConnection, client_id: []const u8, pane_id: []const u8) !void {
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
    }

    /// Point an owned client at another pane. False when not owned here.
    fn switchMuxClientPane(self: *ClientConnection, client_id: []const u8, pane_id: []const u8) !bool {
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
    fn switchRouteAndNotify(self: *ClientConnection, client_id: []const u8, native: *NativeSession) !void {
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

    fn untrackMuxClient(self: *ClientConnection, client_id: []const u8) bool {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);

        for (self.attachments.items, 0..) |active, index| {
            if (std.mem.eql(u8, active.client_id, client_id)) {
                const removed = self.attachments.swapRemove(index);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    fn ownsMuxClient(self: *ClientConnection, client_id: []const u8) bool {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);
        for (self.attachments.items) |active| {
            if (std.mem.eql(u8, active.client_id, client_id)) return true;
        }
        return false;
    }

    fn attachedClientCount(self: *ClientConnection) usize {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);
        return self.attachments.items.len;
    }

    fn takeMuxClients(self: *ClientConnection) std.ArrayList(Attachment) {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);

        const attached = self.attachments;
        self.attachments = .empty;
        return attached;
    }

    /// Replace the `events.subscribe` set. `all` subscribes to every pane.
    fn setSubscriptions(self: *ClientConnection, all: bool, pane_ids: []const []const u8) !void {
        var next: std.ArrayList([]u8) = .empty;
        errdefer {
            for (next.items) |pane_id| self.allocator.free(pane_id);
            next.deinit(self.allocator);
        }
        try next.ensureTotalCapacity(self.allocator, pane_ids.len);
        for (pane_ids) |pane_id| next.appendAssumeCapacity(try self.allocator.dupe(u8, pane_id));

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
    fn wantsPaneOutput(self: *ClientConnection, pane_id: []const u8) bool {
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
};

/// JSON-RPC daemon over a private (0600) UNIX socket.
///
/// `init` binds the socket, `run` accepts connections until `daemon.shutdown`,
/// the idle timeout, or the shutdown probe stops it, and `deinit` releases
/// everything. Each connection gets a reader thread, plus a writer thread
/// once a notification is queued for it (`std.Thread`); `io` supplies their
/// mutexes and condition variables, the clocks, sleeps, and randomness. Pass
/// a thread-safe implementation such as `std.Io.Threaded`
/// (`std.process.Init.io` in `main`).
pub const Server = struct {
    pub const ShutdownProbe = *const fn () bool;
    pub const PeerEuidFn = *const fn (fd: posix.fd_t) ?sys.uid_t;

    allocator: Allocator,
    io: std.Io,
    /// Guards `connections` and `stopping`.
    mutex: std.Io.Mutex = .init,
    /// Orders every mux-client ownership transition: attach (manager attach
    /// plus connection tracking), detach, switch (manager, route, notice),
    /// and the detached-client drain. Lock order: `routing_mutex`, then a
    /// connection's `write_mutex`, then `manager.mutex`/`mutex`.
    routing_mutex: std.Io.Mutex = .init,
    socket_path: []u8,
    socket_stat: sys.Stat,
    /// Pinned parent directory of the socket; -1 for an in-memory server.
    socket_dir_fd: posix.fd_t = -1,
    /// True while this server's socket is the one published at `socket_path`.
    published: bool = false,
    listener_fd: posix.fd_t,
    manager: mux.Manager,
    connections: std.ArrayList(*ClientConnection) = .empty,
    /// `connections.items.len`, readable without `mutex`: events skip
    /// serialization entirely while nobody is connected.
    connected_clients: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Set under `mutex` when shutdown begins. A connection that tries to
    /// register afterwards is refused, so `waitForWorkers` cannot hang on a
    /// reader that nobody will close.
    stopping: bool = false,
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_writer_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_mutex: std.Io.Mutex = .init,
    active_condition: std.Io.Condition = .init,
    /// Monotonic (`.awake` clock) seconds of the last client activity.
    last_activity_seconds: std.atomic.Value(i64),
    idle_timeout_seconds: i64,
    shutdown_probe: ?ShutdownProbe = null,
    /// Events dropped instead of delivered (slow clients, oversized events).
    dropped_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Connections refused at admission (limit, credentials, thread spawn).
    rejected_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Working directory for a pane whose creator names none; null leaves
    /// the daemon's own. Borrowed: must outlive the server.
    default_cwd: ?[]const u8 = null,
    /// Spare descriptor held open while the server runs. When `accept` fails
    /// because the descriptor table is full, the server closes it and accepts
    /// once more, so one control connection (`daemon.ping`,
    /// `session.terminate`, `daemon.shutdown`) can still get in and free
    /// resources. Re-armed as soon as a descriptor is available again.
    spare_fd: posix.fd_t = -1,
    /// Connections admitted by giving up `spare_fd`.
    spare_fd_admissions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Test seam for the listener's `accept`.
    accept_fn: *const fn (listener_fd: posix.fd_t) sys.AcceptError!posix.fd_t = sys.accept,
    /// Seam for credential tests: the effective uid of a connected peer.
    peer_euid_fn: PeerEuidFn = defaultPeerEuid,
    /// Test seam: runs on the worker thread before the connection registers.
    before_register_hook: ?*const fn (server: *Server) void = null,

    /// Bind `socket_path` (absolute) and prepare to serve. A server with no
    /// live panes exits from `run` after `idle_timeout_seconds` without
    /// client activity; 0 or less disables the timeout.
    ///
    /// Fails before touching the filesystem with `error.EmptySocketPath`,
    /// `error.SocketPathContainsNul`, `error.SocketPathNotAbsolute`, or
    /// `error.SocketPathTooLong` for a path `bind(2)` can never accept.
    ///
    /// An existing entry at `socket_path` is never removed unless it is a
    /// stale socket owned by this user: a non-socket fails with
    /// `error.SocketPathNotSocket`, a foreign socket with `error.AccessDenied`,
    /// a live server with `error.AddressInUse`, and an undecidable probe with
    /// `error.ProbeInconclusive`.
    pub fn init(allocator: Allocator, io: std.Io, socket_path: []const u8, idle_timeout_seconds: i64) !Server {
        // Reject before touching the filesystem: a path that can never be
        // bound must not leave a parent directory or lock behind.
        try validateSocketPath(socket_path);
        const dir_fd = try openSocketParent(socket_path, socket_path_mod.processEnv);
        errdefer sys.close(dir_fd);
        return initOwnedDir(allocator, io, dir_fd, socket_path, idle_timeout_seconds);
    }

    /// `init` in a socket directory the caller already opened and validated
    /// (with `openSocketParent`). `dir_fd` stays the caller's; the server
    /// keeps its own duplicate, so the caller's lock and PID files and this
    /// socket are always in the same directory, whatever happens to its
    /// name.
    pub fn initAt(allocator: Allocator, io: std.Io, dir_fd: posix.fd_t, socket_path: []const u8, idle_timeout_seconds: i64) !Server {
        try validateSocketPath(socket_path);
        const owned_dir = try dupCloexec(dir_fd);
        errdefer sys.close(owned_dir);
        return initOwnedDir(allocator, io, owned_dir, socket_path, idle_timeout_seconds);
    }

    fn validateSocketPath(socket_path: []const u8) !void {
        if (socket_path.len == 0) return error.EmptySocketPath;
        if (std.mem.indexOfScalar(u8, socket_path, 0) != null) return error.SocketPathContainsNul;
        if (!std.fs.path.isAbsolute(socket_path)) return error.SocketPathNotAbsolute;
        if (socket_path.len > max_socket_path_len) return error.SocketPathTooLong;
        if (socket_path[socket_path.len - 1] == '/') return error.SocketPathNotSocket;
    }

    /// Takes ownership of `dir_fd` on success only.
    fn initOwnedDir(allocator: Allocator, io: std.Io, dir_fd: posix.fd_t, socket_path: []const u8, idle_timeout_seconds: i64) !Server {
        const socket_name = std.fs.path.basename(socket_path);

        try clearStaleSocket(dir_fd, socket_name, socket_path);

        const listener = try sys.unixStreamSocket();
        errdefer sys.close(listener);

        // Bind owner-only (0600) without touching the process-wide umask,
        // start listening before the socket gets its public name, and never
        // replace an entry that appeared since the check above; see
        // bindPrivateSocket.
        const socket_stat = try bindPrivateSocket(io, listener, dir_fd, socket_name, socket_path);
        // Only the inode this server bound is ever removed.
        errdefer unlinkIfSame(dir_fd, socket_name, socket_stat);

        // A non-blocking listener keeps poll-then-accept from stalling the
        // loop when a client resets before accept.
        try sys.setNonBlocking(listener);
        const owned_socket_path = try allocator.dupe(u8, socket_path);

        log.info("server_listening", .{
            .socket_path = socket_path,
            .backlog = max_client_connections,
            .idle_timeout_seconds = idle_timeout_seconds,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .socket_path = owned_socket_path,
            .socket_stat = socket_stat,
            .socket_dir_fd = dir_fd,
            .published = true,
            .listener_fd = listener,
            .manager = mux.Manager.init(allocator, io, null),
            .last_activity_seconds = std.atomic.Value(i64).init(monotonicSeconds(io)),
            .idle_timeout_seconds = idle_timeout_seconds,
        };
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);
        self.unpublish();
        if (self.listener_fd >= 0) sys.close(self.listener_fd);
        self.shutdown();
        self.releaseSpareFd();
        if (self.socket_dir_fd >= 0) sys.close(self.socket_dir_fd);
        self.manager.deinit();
        self.connections.deinit(self.allocator);
        self.allocator.free(self.socket_path);
    }

    /// Remove the socket file if it is still the one this server bound.
    /// Idempotent. The daemon calls it under its start lock so a starting
    /// daemon never observes a half-removed socket.
    pub fn unpublish(self: *Server) void {
        if (!self.published) return;
        self.published = false;
        if (self.socket_dir_fd < 0) return;
        unlinkIfSame(self.socket_dir_fd, std.fs.path.basename(self.socket_path), self.socket_stat);
    }

    pub fn run(self: *Server) !void {
        self.installEventSinks();
        // Every exit path (probe, idle, daemon.shutdown, listener fault) runs
        // the same shutdown sequence on this thread.
        defer self.shutdown();

        while (!self.shouldStop()) {
            // The reaper only records child status; `session_exited` comes
            // from the native session's own event.
            self.manager.reapExitedPanes();
            self.drainDetachedClients();
            self.armSpareFd();
            if (self.shouldExitForIdle()) {
                log.info("server_idle_exit", .{
                    .idle_timeout_seconds = self.idle_timeout_seconds,
                    .idle_seconds = monotonicSeconds(self.io) - self.last_activity_seconds.load(.seq_cst),
                });
                break;
            }

            var fds = [_]posix.pollfd{.{
                .fd = self.listener_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, 250);
            if (ready == 0) continue;
            if ((fds[0].revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0) return;
            if ((fds[0].revents & posix.POLL.IN) == 0) continue;

            const client_fd = self.accept_fn(self.listener_fd) catch |err| switch (err) {
                // The peer went away between poll and accept.
                error.WouldBlock, error.ConnectionAborted => continue,
                else => self.acceptWithSpareFd(err) orelse {
                    log.warnRateLimited("accept_error", &accept_error_limiter, .{
                        .err = err,
                        .active_connections = self.active_connections.load(.seq_cst),
                    });
                    // Fd exhaustion and every other listener-level fault get
                    // the same backoff: it keeps a failing accept from
                    // spinning at 100% CPU while still letting the server
                    // recover.
                    self.io.sleep(.fromMilliseconds(accept_backoff_ms), .awake) catch {};
                    continue;
                },
            };
            self.admit(client_fd);
        }
    }

    /// Open the spare descriptor when it is not held. Failure is expected
    /// while the table is full; the next loop iteration tries again.
    fn armSpareFd(self: *Server) void {
        if (self.spare_fd >= 0) return;
        self.spare_fd = sys.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return;
    }

    fn releaseSpareFd(self: *Server) void {
        if (self.spare_fd < 0) return;
        sys.close(self.spare_fd);
        self.spare_fd = -1;
    }

    /// On descriptor exhaustion, trade the spare descriptor for one more
    /// accepted connection. Null when `err` is something else, no spare is
    /// held, or the retry fails too.
    fn acceptWithSpareFd(self: *Server, err: sys.AcceptError) ?posix.fd_t {
        if (err != error.ProcessFdQuotaExceeded and err != error.SystemFdQuotaExceeded) return null;
        if (self.spare_fd < 0) return null;
        self.releaseSpareFd();
        const client_fd = self.accept_fn(self.listener_fd) catch return null;
        _ = self.spare_fd_admissions.fetchAdd(1, .monotonic);
        log.warnRateLimited("accept_used_spare_fd", &accept_error_limiter, .{
            .active_connections = self.active_connections.load(.seq_cst),
        });
        return client_fd;
    }

    /// Take ownership of an accepted descriptor: check credentials and the
    /// connection limit, then hand it to a worker thread.
    fn admit(self: *Server, client_fd: posix.fd_t) void {
        // Client sockets are non-blocking on every platform: the reader is
        // poll-driven, and `writeAllDeadline` needs `O_NONBLOCK` to bound a
        // send (BSD-derived systems inherit it from the listener; Linux does
        // not).
        sys.setNonBlocking(client_fd) catch {
            _ = self.rejected_connections.fetchAdd(1, .monotonic);
            sys.close(client_fd);
            return;
        };

        if (!self.peerAllowed(client_fd)) {
            _ = self.rejected_connections.fetchAdd(1, .monotonic);
            sys.close(client_fd);
            return;
        }
        _ = setSocketSendTimeout(client_fd);
        sys.tuneUnixSocketBuffers(client_fd);
        self.touch();
        const previous_connections = self.active_connections.fetchAdd(1, .seq_cst);
        if (previous_connections >= max_client_connections) {
            self.finishActiveConnection();
            _ = self.rejected_connections.fetchAdd(1, .monotonic);
            log.warnRateLimited("connection_limit_reached", &connection_limit_limiter, .{
                .active_connections = previous_connections,
                .max_connections = max_client_connections,
            });
            writeConnectionLimitError(client_fd);
            sys.close(client_fd);
            return;
        }
        const thread = std.Thread.spawn(.{}, Server.handleClientThread, .{ self, client_fd }) catch |err| {
            self.finishActiveConnection();
            _ = self.rejected_connections.fetchAdd(1, .monotonic);
            log.warnRateLimited("connection_thread_spawn_failed", &spawn_failed_limiter, .{ .err = err });
            sys.close(client_fd);
            return;
        };
        thread.detach();
    }

    /// Only a peer with this process's effective uid may talk to the server.
    fn peerAllowed(self: *Server, client_fd: posix.fd_t) bool {
        const peer_euid = self.peer_euid_fn(client_fd);
        if (peer_euid != null and peer_euid.? == sys.geteuid()) return true;
        log.warnRateLimited("peer_cred_rejected", &peer_rejected_limiter, .{
            .peer_euid = peer_euid,
            .euid = sys.geteuid(),
            .socket_path = self.socket_path,
        });
        return false;
    }

    fn writeConnectionLimitError(fd: posix.fd_t) void {
        const message =
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"LimitExceeded\",\"data\":{\"kind\":\"limit\",\"detail\":\"server connection limit reached\"}}}\n";
        writeAllDeadline(fd, message, 250) catch {};
    }

    /// The idle interval runs only while there is nothing to keep alive: it
    /// restarts whenever a pane is live or a connection holds an attached
    /// client, so it starts at the live-to-zero transition.
    fn shouldExitForIdle(self: *Server) bool {
        if (self.idle_timeout_seconds <= 0) return false;
        if (self.manager.counts().live_panes > 0 or self.anyAttachedClient()) {
            self.touch();
            return false;
        }
        const idle_for = monotonicSeconds(self.io) - self.last_activity_seconds.load(.seq_cst);
        return idle_for >= self.idle_timeout_seconds;
    }

    fn anyAttachedClient(self: *Server) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |connection| {
            if (connection.attachedClientCount() > 0) return true;
        }
        return false;
    }

    fn shouldStop(self: *Server) bool {
        if (!self.running.load(.seq_cst)) return true;
        if (self.shutdown_probe) |probe| return probe();
        return false;
    }

    fn touch(self: *Server) void {
        self.last_activity_seconds.store(monotonicSeconds(self.io), .seq_cst);
    }

    /// Route native events and respawn announcements to this server. The
    /// server must not move afterwards.
    fn installEventSinks(self: *Server) void {
        self.manager.setRespawnListener(.{ .context = self, .notify = Server.handleRespawn });
        self.manager.setEventSink(.{ .context = self, .emit = Server.handleNativeEvent });
    }

    /// Every respawn path (`pane.respawn`, `command.exec`, `key.dispatch`)
    /// announces here, after the old generation's events and before the new
    /// generation's first event.
    fn handleRespawn(context: *anyopaque, native: *NativeSession) void {
        const self: *Server = @ptrCast(@alignCast(context));
        self.broadcastNotification(protocol.pane_respawned_method, protocol.PaneRespawnedParams{
            .pane_id = native.id,
            .generation = native.generation(),
            .pid = native.handle.child_pid,
        });
    }

    /// Stop accepting work and tear everything down, in an order that cannot
    /// deadlock: refuse and close connections, wake writers blocked on PTY
    /// input, wait for the workers, silence native events, then terminate the
    /// panes. Idempotent.
    fn shutdown(self: *Server) void {
        self.manager.reapExitedPanes();
        self.beginStop();
        self.manager.interruptInput();
        self.waitForWorkers();
        self.manager.clearEventSinks();
        self.manager.terminateAll();
    }

    /// Flip `running` and `stopping` and take the registered connections in
    /// one critical section, then close them. A worker that registers later
    /// sees `stopping` under the same mutex and closes itself.
    fn beginStop(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
        self.running.store(false, .seq_cst);
        self.stopping = true;
        var connections = self.connections;
        self.connections = .empty;
        self.connected_clients.store(0, .release);
        self.mutex.unlock(self.io);

        defer connections.deinit(self.allocator);
        for (connections.items) |connection| {
            connection.close();
            connection.release();
        }
    }

    fn handleClientThread(self: *Server, client_fd: posix.fd_t) void {
        defer self.finishActiveConnection();

        const connection = ClientConnection.create(self.allocator, self.io, client_fd, self) catch {
            sys.close(client_fd);
            return;
        };
        defer connection.release();
        defer connection.close();

        if (self.before_register_hook) |hook| hook(self);
        if (!self.registerConnection(connection)) return;
        defer self.unregisterConnection(connection);

        self.handleClient(connection);
    }

    fn handleClient(self: *Server, connection: *ClientConnection) void {
        // One absolute deadline for the first request: blank lines neither
        // count as a request nor extend it.
        const first_deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(first_frame_deadline_ms));
        var first_frame = true;
        while (self.running.load(.seq_cst)) {
            const line = self.readFrame(connection, if (first_frame) first_deadline else null) catch |err| {
                if (connection.isClosed()) return;
                // Only an oversized frame is answered before closing. A
                // truncated frame is never dispatched, and a silent, stalled,
                // or reset peer just loses its connection. Compared as
                // `anyerror` so the reader's error set can change freely.
                const any_err: anyerror = err;
                if (any_err == error.MessageTooLarge) self.writeErrorFor(connection, "null", any_err);
                return;
            } orelse return;
            defer self.allocator.free(line);
            if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;
            first_frame = false;

            self.touch();
            // A request that arrives after shutdown began is not started.
            if (!self.running.load(.seq_cst)) return;

            var req = protocol.parseRequest(self.allocator, line) catch |err| {
                self.writeErrorFor(connection, "null", err);
                continue;
            };
            defer req.deinit();

            self.dispatch(connection, &req) catch |err| {
                // A notification gets no response for any outcome (D2).
                if (!protocol.isNotification(&req)) self.writeErrorFor(connection, req.id_json, err);
            };
            self.drainDetachedClients();
        }
    }

    /// Read one frame. The first frame of a connection and any frame that has
    /// started arriving are bounded by deadlines; an idle connection between
    /// frames waits without one, so an attached client can sit quietly.
    /// `first_deadline` is set until the connection's first request arrives.
    fn readFrame(self: *Server, connection: *ClientConnection, first_deadline: ?std.Io.Timestamp) !?[]u8 {
        const reader = &connection.reader;
        if (first_deadline == null and reader.end == reader.start) {
            var fds = [_]posix.pollfd{.{
                .fd = connection.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            while (true) {
                if (try posix.poll(&fds, -1) > 0) break;
            }
        }
        const deadline = first_deadline orelse
            std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(partial_frame_deadline_ms));
        return reader.readFrameAllocMaybeDeadline(self.allocator, connection.fd, max_request_bytes, deadline);
    }

    fn dispatch(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        // Positional or scalar params are never valid for this API.
        if (req.params()) |params| switch (params) {
            .object, .null => {},
            else => return error.InvalidParams,
        };

        if (std.mem.eql(u8, req.method, "daemon.ping")) {
            const counts = self.manager.counts();
            return self.reply(connection, req, .{
                .version = protocol.version,
                .pid = std.c.getpid(),
                .socketPath = self.socket_path,
                .sessions = counts.sessions,
                .panes = counts.panes,
                .livePanes = counts.live_panes,
                .connections = self.active_connections.load(.seq_cst),
                .droppedEvents = self.dropped_events.load(.monotonic),
                .rejectedConnections = self.rejected_connections.load(.monotonic),
            });
        }

        if (std.mem.eql(u8, req.method, "daemon.shutdown")) {
            try self.replyOk(connection, req);
            // Stop new work right after the reply. The accept thread runs
            // the shutdown sequence; doing it here would make this worker
            // wait for itself.
            self.running.store(false, .seq_cst);
            return;
        }

        if (std.mem.eql(u8, req.method, "session.create")) return self.createSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.terminate")) return self.terminateSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.list")) return self.listSessions(connection, req);
        if (std.mem.eql(u8, req.method, "session.info")) return self.infoSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.resize")) return self.resizeSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.capture")) return self.captureSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.send")) return self.sendSession(connection, req);
        if (std.mem.eql(u8, req.method, "session.sendKey")) return self.sendKeySession(connection, req);
        if (std.mem.eql(u8, req.method, "mux.snapshot")) return self.snapshotMux(connection, req);
        if (std.mem.eql(u8, req.method, "window.new")) return self.newWindow(connection, req);
        if (std.mem.eql(u8, req.method, "window.select")) return self.selectWindow(connection, req);
        if (std.mem.eql(u8, req.method, "window.rename")) return self.renameWindow(connection, req);
        if (std.mem.eql(u8, req.method, "pane.split")) return self.splitPane(connection, req);
        if (std.mem.eql(u8, req.method, "pane.select")) return self.selectPane(connection, req);
        if (std.mem.eql(u8, req.method, "pane.rename")) return self.renamePane(connection, req);
        if (std.mem.eql(u8, req.method, "pane.respawn")) return self.respawnPane(connection, req);
        if (std.mem.eql(u8, req.method, "session.rename")) return self.renameSession(connection, req);
        if (std.mem.eql(u8, req.method, "client.attach")) return self.attachMuxClient(connection, req);
        if (std.mem.eql(u8, req.method, "client.detach")) return self.detachMuxClient(connection, req);
        if (std.mem.eql(u8, req.method, "client.switch")) return self.switchMuxClient(connection, req);
        if (std.mem.eql(u8, req.method, "client.list")) return self.listMuxClients(connection, req);
        if (std.mem.eql(u8, req.method, "events.subscribe")) return self.subscribeEvents(connection, req);
        if (std.mem.eql(u8, req.method, "key.bind")) return self.bindKey(connection, req);
        if (std.mem.eql(u8, req.method, "key.dispatch")) return self.dispatchKey(connection, req);
        if (std.mem.eql(u8, req.method, "key.list")) return self.listKeys(connection, req);
        if (std.mem.eql(u8, req.method, "command.exec")) return self.execCommand(connection, req);

        return error.MethodNotFound;
    }

    fn createSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        // session.create is the only place where `id` should also stand in
        // for the session title: for window.new / pane.split the same `id`
        // field is the existing target alias, so it must NOT be repurposed
        // as the new window/pane title.
        var create_args = try muxCreateArgsFromParams(self.allocator, req.params(), .{ .id_aliases_title = true });
        defer create_args.deinit();
        self.applyCreateDefaults(&create_args.opts);

        var handle = try self.manager.createSessionPane(create_args.opts);
        defer handle.deinit();
        self.replyCreatedSession(connection, req, &handle) catch |err| return self.undoCreate(&handle, err);
    }

    /// The legacy session info object plus the compact identifiers.
    fn replyCreatedSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request, handle: *const mux.PaneHandle) !void {
        const info = try handle.native.infoJson(self.allocator);
        defer self.allocator.free(info);
        const trimmed = std.mem.trimEnd(u8, info, " \t\r\n");
        if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '}') return error.Unexpected;

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeAll(trimmed[0 .. trimmed.len - 1]);
        try out.writer.writeAll(",\"sessionId\":");
        try std.json.Stringify.value(handle.session_id, .{}, &out.writer);
        try out.writer.writeAll(",\"windowId\":");
        try std.json.Stringify.value(handle.window_id, .{}, &out.writer);
        try out.writer.writeAll(",\"paneId\":");
        try std.json.Stringify.value(handle.pane_id, .{}, &out.writer);
        if (std.mem.indexOf(u8, trimmed, "\"generation\":") == null) {
            try out.writer.print(",\"generation\":{}", .{handle.native.generation()});
        }
        try out.writer.writeAll("}");
        try self.replyRaw(connection, req, out.written());
    }

    /// A create whose response could not be built or exceeded a limit is
    /// undone, so an error response always means nothing was committed
    /// (M40). A reply lost to a closed connection keeps the work: nobody was
    /// told it failed, and a named session stays attachable.
    fn undoCreate(self: *Server, handle: *const mux.PaneHandle, err: anyerror) anyerror {
        if (err != error.ConnectionClosed) _ = self.manager.terminate(handle.pane_id);
        return err;
    }

    fn applyCreateDefaults(self: *Server, opts: *mux.CreateOptions) void {
        if (opts.cwd == null) opts.cwd = self.default_cwd;
    }

    fn snapshotMux(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        try self.replySnapshot(connection, req);
    }

    fn newWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const session_id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
        var create_args = try muxCreateArgsFromParams(self.allocator, req.params(), .{});
        defer create_args.deinit();
        self.applyCreateDefaults(&create_args.opts);
        var out = try self.reserveCompactReply(req);
        defer out.deinit();
        var handle = try self.manager.newWindow(session_id, create_args.opts);
        defer handle.deinit();
        self.replyPaneHandle(connection, req, &handle, &out) catch |err| return self.undoCreate(&handle, err);
    }

    fn splitPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
        const axis = try axisParam(req.params());
        var create_args = try muxCreateArgsFromParams(self.allocator, req.params(), .{});
        defer create_args.deinit();
        self.applyCreateDefaults(&create_args.opts);
        var out = try self.reserveCompactReply(req);
        defer out.deinit();
        var handle = try self.manager.splitPane(pane_id, axis, create_args.opts);
        defer handle.deinit();
        self.replyPaneHandle(connection, req, &handle, &out) catch |err| return self.undoCreate(&handle, err);
    }

    /// Reserve the buffer for a compact mutation result before the mutation
    /// commits, so building the reply afterwards does not allocate.
    fn reserveCompactReply(self: *Server, req: *const protocol.Request) !std.Io.Writer.Allocating {
        return std.Io.Writer.Allocating.initCapacity(self.allocator, compact_reply_reserve_bytes + req.id_json.len);
    }

    /// Compact mutation result: identifiers only, written into the buffer
    /// reserved by `reserveCompactReply`, so the reply cannot fail on the size
    /// of the whole mux snapshot after the work is committed.
    fn replyPaneHandle(
        self: *Server,
        connection: *ClientConnection,
        req: *const protocol.Request,
        handle: *const mux.PaneHandle,
        out: *std.Io.Writer.Allocating,
    ) !void {
        if (protocol.isNotification(req)) return;
        try protocol.writeResult(&out.writer, req.id_json, .{
            .sessionId = handle.session_id,
            .windowId = handle.window_id,
            .paneId = handle.pane_id,
            .generation = handle.native.generation(),
        });
        try self.writeResponse(connection, out.written());
    }

    fn selectPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
        try self.manager.selectPane(pane_id);
        try self.replySnapshot(connection, req);
    }

    fn selectWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const window_id = try windowIdParam(req.params()) orelse return error.InvalidParams;
        try self.manager.selectWindow(window_id);
        try self.replySnapshot(connection, req);
    }

    fn renameSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const session_id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
        const name = try firstStringParam(req.params(), &.{ "name", "title" }) orelse return error.InvalidParams;
        try self.manager.renameSession(session_id, name);
        try self.replySnapshot(connection, req);
    }

    fn renameWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const window_id = try windowIdParam(req.params()) orelse return error.InvalidParams;
        const name = try firstStringParam(req.params(), &.{ "name", "title" }) orelse return error.InvalidParams;
        try self.manager.renameWindow(window_id, name);
        try self.replySnapshot(connection, req);
    }

    fn renamePane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
        const title = try firstStringParam(req.params(), &.{ "title", "name" }) orelse return error.InvalidParams;
        const custom = try optionalBool(req.params(), "custom") orelse true;
        try self.manager.renamePane(pane_id, title, custom);
        try self.replySnapshot(connection, req);
    }

    fn respawnPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
        // `kill` defaults to false: respawning a running pane is a conflict
        // (`PaneRunning`) unless the caller asks for the child to be killed.
        const kill = try optionalBool(req.params(), "kill") orelse false;
        // The manager's respawn listener (`handleRespawn`) announces it.
        const active = try self.manager.respawnPane(pane_id, .{ .kill = kill });
        defer active.release();
        try self.replySnapshot(connection, req);
    }

    fn attachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const params = req.params();
        const target = try paneIdParam(params) orelse return error.InvalidParams;
        const rows = try dimensionParam(params, "rows", 24);
        const cols = try dimensionParam(params, "cols", 80);

        var create_args: ?MuxCreateArgs = null;
        defer if (create_args) |*args| args.deinit();
        if (try objectParam(params, "createIfMissing")) |create_params| {
            create_args = try muxCreateArgsFromParams(self.allocator, create_params, .{ .id_aliases_title = true });
            self.applyCreateDefaults(&create_args.?.opts);
        }

        // Manager attach and connection tracking are one ownership step: a
        // detach or pane removal drained in between would find no owner.
        self.routing_mutex.lockUncancelable(self.io);
        var routing_held = true;
        defer if (routing_held) self.routing_mutex.unlock(self.io);

        var attached = try self.manager.attachOrCreateClient(target, rows, cols, if (create_args) |args| args.opts else null);
        defer attached.client.deinit(self.allocator);
        const client = &attached.client;
        errdefer _ = self.manager.detachClient(client.id);

        // Hold the write side so the response is on the wire before any
        // `pane_output` this attach subscribes to, and before any lifecycle
        // notification (`session_exited`, `pane_respawned`) queued after the
        // state below is read. Subscribing before the snapshot leaves no
        // gap: every output event at or after `replayEndOffset` is delivered,
        // and anything earlier is in the replay.
        connection.write_mutex.lockUncancelable(connection.io);
        defer connection.write_mutex.unlock(connection.io);

        try connection.trackMuxClient(client.id, client.pane_id);
        errdefer _ = connection.untrackMuxClient(client.id);
        self.routing_mutex.unlock(self.io);
        routing_held = false;

        // Status, generation, and replay all come from one retained native,
        // read after the write lock: an exit or respawn either shows up here
        // or is announced after this reply, never in between.
        const native = self.manager.find(client.pane_id) orelse return error.PaneNotFound;
        defer native.release();
        const exit = native.finalizedExitInfo();
        const generation = native.generation();
        const tail = try native.scrollbackTail(self.allocator, attach_replay_max_bytes);
        defer self.allocator.free(tail.bytes);
        const replay_b64 = try base64Encode(self.allocator, tail.bytes);
        defer self.allocator.free(replay_b64);

        const exit_code: ?u32 = if (exit) |info| info.exit_code else null;
        const signal: ?u32 = if (exit) |info| info.signal else null;
        if (protocol.isNotification(req)) return;
        const response = try protocol.result(self.allocator, req.id_json, .{
            .clientId = client.id,
            .sessionId = client.session_id,
            .windowId = client.window_id,
            .paneId = client.pane_id,
            .rows = client.rows,
            .cols = client.cols,
            .created = attached.created,
            .exited = exit != null,
            .exitCode = exit_code,
            .signal = signal,
            .generation = generation,
            .replayBase64 = replay_b64,
            .replayStartOffset = tail.start_offset,
            .replayEndOffset = tail.end_offset,
        });
        defer self.allocator.free(response);
        if (response.len > max_response_bytes) return error.LimitExceeded;
        try connection.writeLocked(response);
    }

    fn detachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const client_id = try clientIdParam(req.params()) orelse return error.InvalidParams;

        {
            self.routing_mutex.lockUncancelable(self.io);
            defer self.routing_mutex.unlock(self.io);
            if (connection.untrackMuxClient(client_id)) {
                // Owned here: nothing to notify.
                if (!self.manager.detachClient(client_id)) return error.ClientNotFound;
            } else {
                // Another connection's client: allowed. The manager records
                // the remote detach and `drainDetachedClients`, which runs
                // after every request, tells the owner (`client_detached`).
                if (!self.manager.detachClientRemote(client_id)) return error.ClientNotFound;
            }
        }
        try self.replyOk(connection, req);
    }

    /// Manager state, output route, and the owner's `client_switched` notice
    /// change as one transition under `routing_mutex`, so conflicting
    /// switches cannot leave the route on a pane the manager no longer
    /// names. A remote owner gets the notice, with the new generation and a
    /// replay, ahead of any output from the new pane; if the route or notice
    /// cannot be installed, the owner's connection is closed.
    fn switchMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const client_id = try clientIdParam(req.params()) orelse return error.InvalidParams;
        const target = try paneIdParam(req.params()) orelse return error.InvalidParams;

        {
            self.routing_mutex.lockUncancelable(self.io);
            defer self.routing_mutex.unlock(self.io);
            try self.manager.switchClient(client_id, target);

            const native = self.manager.find(target) orelse return error.PaneNotFound;
            defer native.release();

            if (connection.ownsMuxClient(client_id)) {
                if (!try connection.switchMuxClientPane(client_id, native.id)) return error.ClientNotFound;
            } else if (self.findClientOwner(client_id)) |owner| {
                defer owner.release();
                owner.switchRouteAndNotify(client_id, native) catch |err| switch (err) {
                    error.ConnectionClosed => {},
                    else => {
                        owner.close();
                        return err;
                    },
                };
            }
        }
        try self.replySnapshot(connection, req);
    }

    fn listMuxClients(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.clientsJson(self.allocator);
        defer self.allocator.free(list);
        try self.replyRaw(connection, req, list);
    }

    /// `events.subscribe {"panes":["*"]}` or a list of pane targets: enables
    /// `pane_output` for a connection that has no attached client (D1). Each
    /// call replaces the previous subscription; an empty list clears it.
    fn subscribeEvents(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const params = req.params() orelse return error.InvalidParams;
        if (params != .object) return error.InvalidParams;
        const panes_value = params.object.get("panes") orelse return error.InvalidParams;
        if (panes_value != .array) return error.InvalidParams;

        var all = false;
        var pane_ids: std.ArrayList([]const u8) = .empty;
        defer {
            for (pane_ids.items) |pane_id| self.allocator.free(pane_id);
            pane_ids.deinit(self.allocator);
        }
        for (panes_value.array.items) |item| {
            if (item != .string) return error.InvalidParams;
            if (std.mem.eql(u8, item.string, "*")) {
                all = true;
                continue;
            }
            // Resolve a session name or alias to its pane id; an unknown
            // target is kept verbatim so a pane can be subscribed by id.
            const resolved = blk: {
                const native = self.manager.find(item.string) orelse break :blk try self.allocator.dupe(u8, item.string);
                defer native.release();
                break :blk try self.allocator.dupe(u8, native.id);
            };
            pane_ids.append(self.allocator, resolved) catch |err| {
                self.allocator.free(resolved);
                return err;
            };
        }

        try connection.setSubscriptions(all, pane_ids.items);
        try self.reply(connection, req, .{ .ok = true, .all = all, .panes = pane_ids.items });
    }

    fn bindKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const key = try optionalString(req.params(), "key") orelse return error.InvalidParams;
        const command = try firstStringParam(req.params(), &.{ "command", "cmd" }) orelse return error.InvalidParams;
        const table = try optionalString(req.params(), "table") orelse "prefix";
        const repeat = try optionalBool(req.params(), "repeat") orelse false;
        try self.manager.bindKey(table, key, command, repeat);
        const list = try self.manager.keysJson(self.allocator);
        defer self.allocator.free(list);
        try self.replyRaw(connection, req, list);
    }

    fn dispatchKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
        const key = try optionalString(req.params(), "key") orelse return error.InvalidParams;
        const table = try optionalString(req.params(), "table") orelse "prefix";
        const command = try self.manager.executeBinding(table, key, pane_id);
        defer if (command) |owned| self.allocator.free(owned);
        if (command == null) return self.reply(connection, req, .{ .handled = false });
        try self.replySnapshot(connection, req);
    }

    fn listKeys(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.keysJson(self.allocator);
        defer self.allocator.free(list);
        try self.replyRaw(connection, req, list);
    }

    fn execCommand(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
        const command = try firstStringParam(req.params(), &.{ "command", "line" }) orelse return error.InvalidParams;
        try self.manager.executeCommandLine(command, pane_id);
        try self.replySnapshot(connection, req);
    }

    fn terminateSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
        if (!self.manager.terminate(id)) return error.SessionNotFound;
        try self.replyOk(connection, req);
    }

    fn listSessions(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.listJson(self.allocator);
        defer self.allocator.free(list);
        try self.replyRaw(connection, req, list);
    }

    fn infoSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(req);
        defer active.release();

        const info = try active.infoJson(self.allocator);
        defer self.allocator.free(info);
        try self.replyRaw(connection, req, info);
    }

    fn resizeSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const cols = try dimensionParam(req.params(), "cols", 80);
        const rows = try dimensionParam(req.params(), "rows", 24);
        const active = try self.requiredSession(req);
        defer active.release();

        // An exited pane has no terminal to resize: the caller learns that
        // (`terminated`) and can respawn, instead of a silent success.
        if (!active.isRunning()) return error.SessionTerminated;
        // Through the manager so the pane's spawn spec records the size and a
        // respawn comes back at the same dimensions.
        try self.manager.resizePane(active.id, rows, cols);
        try self.replyOk(connection, req);
    }

    fn captureSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const lines = try optionalInt(usize, req.params(), "lines") orelse 200;
        const active = try self.requiredSession(req);
        defer active.release();

        const captured = try active.captureBounded(self.allocator, lines, capture_max_bytes);
        defer self.allocator.free(captured);
        // Keep the newest bytes whose worst-case encoding fits the response
        // cap, so a control-heavy capture returns a bounded, useful tail
        // instead of being built at ~6x and then rejected.
        const reserve = capture_envelope_reserve_bytes +| req.id_json.len +| active.id.len;
        const text = captured[captureTailStart(captured, max_response_bytes -| reserve)..];
        const text_b64 = try base64Encode(self.allocator, text);
        defer self.allocator.free(text_b64);

        // `text` is always a JSON string (invalid UTF-8 becomes U+FFFD);
        // `textBase64` carries the exact bytes.
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeAll("{\"sessionId\":");
        try std.json.Stringify.value(active.id, .{}, &out.writer);
        try out.writer.writeAll(",\"text\":");
        try protocol.writeJsonStringLossy(&out.writer, text);
        try out.writer.writeAll(",\"textBase64\":");
        try std.json.Stringify.value(text_b64, .{}, &out.writer);
        try out.writer.writeAll("}");
        try self.replyRaw(connection, req, out.written());
    }

    fn sendSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const params = req.params();
        const encoded = try firstStringParam(params, &.{ "dataBase64", "data_base64" });
        const text = try optionalString(params, "text");
        const enter = try optionalBool(params, "enter") orelse false;
        const active = try self.requiredSession(req);
        defer active.release();

        if (encoded) |data| {
            const bytes = base64Decode(self.allocator, data) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidParams,
            };
            defer self.allocator.free(bytes);
            try active.writeInput(bytes);
        } else {
            try active.send(text orelse "", enter);
        }
        try self.replyOk(connection, req);
    }

    fn sendKeySession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const key = try optionalString(req.params(), "key") orelse return error.InvalidParams;
        const active = try self.requiredSession(req);
        defer active.release();

        // `UnknownKey` maps to invalid params; I/O failures keep their own
        // kind through the shared error table.
        try active.sendKey(key);
        try self.replyOk(connection, req);
    }

    /// Get a required session by ID. Caller MUST call release() on the
    /// returned session.
    fn requiredSession(self: *Server, req: *const protocol.Request) !*NativeSession {
        const id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
        return self.manager.find(id) orelse error.SessionNotFound;
    }

    // -- Responses ------------------------------------------------------------

    fn reply(self: *Server, connection: *ClientConnection, req: *const protocol.Request, value: anytype) !void {
        if (protocol.isNotification(req)) return;
        const response = try protocol.result(self.allocator, req.id_json, value);
        defer self.allocator.free(response);
        try self.writeResponse(connection, response);
    }

    fn replyRaw(self: *Server, connection: *ClientConnection, req: *const protocol.Request, raw_json: []const u8) !void {
        if (protocol.isNotification(req)) return;
        if (raw_json.len > max_response_bytes) return error.LimitExceeded;
        const response = try protocol.resultRaw(self.allocator, req.id_json, raw_json);
        defer self.allocator.free(response);
        try self.writeResponse(connection, response);
    }

    fn replyOk(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        return self.reply(connection, req, .{ .ok = true });
    }

    fn replySnapshot(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        if (protocol.isNotification(req)) return;
        const snapshot = try self.manager.snapshotJson(self.allocator);
        defer self.allocator.free(snapshot);
        try self.replyRaw(connection, req, snapshot);
    }

    fn writeResponse(self: *Server, connection: *ClientConnection, response: []const u8) !void {
        _ = self;
        if (response.len > max_response_bytes) return error.LimitExceeded;
        // A failed write closes the connection; there is nobody left to tell.
        connection.write(response) catch return error.ConnectionClosed;
    }

    /// Send the JSON-RPC error for `err`: the code and `data.kind` come from
    /// the shared table, the message is the stable error name.
    fn writeErrorFor(self: *Server, connection: *ClientConnection, id_json: []const u8, err: anyerror) void {
        // The peer is gone; an error response would only fail again.
        if (err == error.ConnectionClosed) return;
        const mapping = errorMappingFor(err);
        if (mapping.kind == .internal) {
            log.warnRateLimited("rpc_internal_error", &internal_error_limiter, .{ .err = err });
        }
        const response = protocol.errorWithKind(self.allocator, id_json, mapping.code, @errorName(err), mapping.kind) catch return;
        defer self.allocator.free(response);
        connection.write(response) catch {};
    }

    // -- Connection registry ---------------------------------------------------

    /// Add `connection` to the broadcast set. Returns false when the server is
    /// stopping (or out of memory); the caller then closes the connection.
    fn registerConnection(self: *Server, connection: *ClientConnection) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return false;
        self.connections.append(self.allocator, connection.retain()) catch {
            connection.release();
            return false;
        };
        self.connected_clients.store(self.connections.items.len, .release);
        return true;
    }

    fn unregisterConnection(self: *Server, connection: *ClientConnection) void {
        self.detachConnectionClients(connection);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.connections.items, 0..) |active, index| {
            if (active == connection) {
                const removed = self.connections.swapRemove(index);
                self.connected_clients.store(self.connections.items.len, .release);
                removed.release();
                break;
            }
        }
    }

    fn detachConnectionClients(self: *Server, connection: *ClientConnection) void {
        self.routing_mutex.lockUncancelable(self.io);
        defer self.routing_mutex.unlock(self.io);
        var mux_clients = connection.takeMuxClients();
        defer mux_clients.deinit(self.allocator);
        for (mux_clients.items) |attachment| {
            _ = self.manager.detachClient(attachment.client_id);
            attachment.deinit(self.allocator);
        }
    }

    /// The connection that owns mux client `client_id`, retained.
    fn findClientOwner(self: *Server, client_id: []const u8) ?*ClientConnection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |connection| {
            if (connection.ownsMuxClient(client_id)) return connection.retain();
        }
        return null;
    }

    /// `findClientOwner` that also removes the client from its owner.
    fn takeClientOwner(self: *Server, client_id: []const u8) ?*ClientConnection {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.connections.items) |connection| {
            if (connection.untrackMuxClient(client_id)) return connection.retain();
        }
        return null;
    }

    /// Tell owners about clients the manager pruned (pane or session removed,
    /// or detached remotely) and stop tracking them.
    fn drainDetachedClients(self: *Server) void {
        self.routing_mutex.lockUncancelable(self.io);
        defer self.routing_mutex.unlock(self.io);
        const detached = self.manager.takeDetachedClients(self.allocator) catch return;
        defer mux.freeDetachedClients(self.allocator, detached);
        for (detached) |entry| {
            const owner = self.takeClientOwner(entry.client_id) orelse continue;
            defer owner.release();
            self.notifyClientDetached(owner, entry.client_id, @tagName(entry.reason));
        }
    }

    fn notifyClientDetached(self: *Server, owner: *ClientConnection, client_id: []const u8, reason: []const u8) void {
        self.notifyConnection(owner, protocol.client_detached_method, protocol.ClientDetachedParams{
            .client_id = client_id,
            .reason = reason,
        });
    }

    /// Queue one notification on a single connection.
    fn notifyConnection(self: *Server, connection: *ClientConnection, method: []const u8, params: anytype) void {
        const bytes = protocol.notification(self.allocator, method, params) catch return;
        const payload = Payload.create(self.allocator, bytes, null) catch {
            self.allocator.free(bytes);
            return;
        };
        defer payload.release();
        self.deliver(connection, payload);
    }

    fn addActiveWriter(self: *Server) void {
        self.active_mutex.lockUncancelable(self.io);
        _ = self.active_writer_threads.fetchAdd(1, .seq_cst);
        self.active_mutex.unlock(self.io);
    }

    fn finishActiveWriter(self: *Server) void {
        self.active_mutex.lockUncancelable(self.io);
        _ = self.active_writer_threads.fetchSub(1, .seq_cst);
        self.active_condition.broadcast(self.io);
        self.active_mutex.unlock(self.io);
    }

    fn finishActiveConnection(self: *Server) void {
        self.active_mutex.lockUncancelable(self.io);
        _ = self.active_connections.fetchSub(1, .seq_cst);
        self.active_condition.broadcast(self.io);
        self.active_mutex.unlock(self.io);
    }

    fn waitForWorkers(self: *Server) void {
        self.active_mutex.lockUncancelable(self.io);
        defer self.active_mutex.unlock(self.io);
        while (self.active_connections.load(.seq_cst) > 0 or self.active_writer_threads.load(.seq_cst) > 0) {
            self.active_condition.waitUncancelable(self.io, &self.active_mutex);
        }
    }

    // -- Event routing ----------------------------------------------------------

    /// Retained snapshot of the registered connections. With `pane_filter`,
    /// only connections that receive that pane's output (D1).
    fn snapshotConnections(self: *Server, pane_filter: ?[]const u8) !Snapshot {
        var snapshot: Snapshot = .{};
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const total = self.connections.items.len;
        const slots: []*ClientConnection = if (total <= snapshot.stack.len)
            snapshot.stack[0..total]
        else blk: {
            const allocated = try self.allocator.alloc(*ClientConnection, total);
            snapshot.heap = allocated;
            break :blk allocated;
        };
        var count: usize = 0;
        for (self.connections.items) |connection| {
            if (pane_filter) |pane_id| {
                if (!connection.wantsPaneOutput(pane_id)) continue;
            }
            slots[count] = connection.retain();
            count += 1;
        }
        snapshot.len = count;
        return snapshot;
    }

    /// Connections captured by `snapshotConnections`. Up to
    /// `max_client_connections` live on the stack, so routing an event
    /// allocates nothing.
    const Snapshot = struct {
        stack: [max_client_connections]*ClientConnection = undefined,
        heap: ?[]*ClientConnection = null,
        len: usize = 0,

        fn items(self: *Snapshot) []*ClientConnection {
            const slots = if (self.heap) |heap| heap else self.stack[0..];
            return slots[0..self.len];
        }
    };

    fn releaseSnapshot(self: *Server, snapshot: *Snapshot) void {
        for (snapshot.items()) |connection| connection.release();
        if (snapshot.heap) |heap| self.allocator.free(heap);
        snapshot.* = .{};
    }

    /// Queue `payload` on one connection. Any terminal failure closes that
    /// connection (its reader thread then unregisters it); other connections
    /// are unaffected.
    fn deliver(self: *Server, connection: *ClientConnection, payload: *Payload) void {
        connection.enqueue(payload) catch |err| switch (err) {
            error.ConnectionClosed => {},
            else => {
                _ = self.dropped_events.fetchAdd(1, .monotonic);
                // Sizes and error name only: queued bytes are PTY output.
                log.warnRateLimited("client_backlogged", &backlog_limiter, .{
                    .err = err,
                    .rejected_bytes = payload.bytes.len,
                    .max_control_bytes = control_queue_max_bytes,
                });
                connection.close();
            },
        };
    }

    /// Lifecycle notification: delivered to every connection.
    fn broadcastNotification(self: *Server, method: []const u8, params: anytype) void {
        // Skip serialization entirely when nobody can receive it.
        if (self.connected_clients.load(.acquire) == 0) return;
        const bytes = protocol.notification(self.allocator, method, params) catch return;
        self.broadcastControl(bytes);
    }

    /// Takes ownership of `bytes`.
    fn broadcastControl(self: *Server, bytes: []u8) void {
        if (bytes.len > max_event_bytes) {
            // One oversized event must not count as backlog on every client.
            _ = self.dropped_events.fetchAdd(1, .monotonic);
            log.warnRateLimited("event_too_large_dropped", &event_dropped_limiter, .{
                .event_bytes = bytes.len,
                .max_event_bytes = max_event_bytes,
            });
            self.allocator.free(bytes);
            return;
        }
        const payload = Payload.create(self.allocator, bytes, null) catch {
            self.allocator.free(bytes);
            return;
        };
        defer payload.release();

        var targets = self.snapshotConnections(null) catch return;
        defer self.releaseSnapshot(&targets);
        for (targets.items()) |connection| self.deliver(connection, payload);
    }

    /// `pane_output` goes only to connections attached to the pane or
    /// subscribed to it. With no such connection nothing is serialized.
    fn broadcastPaneOutput(self: *Server, params: native_mod.PaneOutputEvent) void {
        if (self.connected_clients.load(.acquire) == 0) return;
        var targets = self.snapshotConnections(params.pane_id) catch return;
        defer self.releaseSnapshot(&targets);
        if (targets.len == 0) return;

        const encoded = base64Encode(self.allocator, params.data) catch return;
        defer self.allocator.free(encoded);
        const bytes = protocol.notification(self.allocator, protocol.pane_output_method, protocol.PaneOutputParams{
            .pane_id = params.pane_id,
            .data_base64 = encoded,
            .offset = params.offset,
            .generation = params.generation,
        }) catch return;
        const pane_id = self.allocator.dupe(u8, params.pane_id) catch {
            self.allocator.free(bytes);
            return;
        };
        const payload = Payload.create(self.allocator, bytes, .{
            .pane_id = pane_id,
            .data_len = params.data.len,
            .end_offset = params.offset + params.data.len,
            .generation = params.generation,
        }) catch {
            self.allocator.free(pane_id);
            self.allocator.free(bytes);
            return;
        };
        defer payload.release();

        for (targets.items()) |connection| self.deliver(connection, payload);
    }

    fn handleNativeEvent(context: *anyopaque, event: native_mod.Event) void {
        const self: *Server = @ptrCast(@alignCast(context));
        switch (event) {
            .foreground_changed => |params| self.broadcastNotification(protocol.foreground_changed_method, params),
            .session_exited => |params| {
                // A stale generation's exit is dropped before any client
                // sees it: the pane already runs its replacement.
                if (!self.manager.markExitedIfCurrent(params.session_id, params.generation)) return;
                // The idle interval starts when the last pane exits, not at
                // the last client request.
                self.touch();
                self.broadcastNotification(protocol.session_exited_method, params);
            },
            // No manager lock or clock read per chunk: the activity alert and
            // its timestamp come from the `pane_activity` edge below. Output
            // of a replaced generation cannot arrive after its respawn
            // announcement (the manager drains the old sink first), and
            // clients order chunks by `generation`.
            .pane_output => |params| self.broadcastPaneOutput(params),
            .pane_activity => |params| {
                // The native session emits this only on the idle-to-active
                // edge (`native.activity_idle_ms`), so every event is
                // forwarded. The alert state records the event's timestamp.
                self.manager.markActivity(params.pane_id, params.generation, params.last_activity_ms);
                self.broadcastNotification(protocol.pane_activity_method, protocol.PaneActivityParams{
                    .pane_id = params.pane_id,
                    .last_activity_ms = params.last_activity_ms,
                    .generation = params.generation,
                });
            },
            .pane_bell => |params| {
                self.manager.markBell(params.pane_id, params.generation, params.last_bell_ms);
                self.broadcastNotification(protocol.pane_bell_method, protocol.PaneBellParams{
                    .pane_id = params.pane_id,
                    .last_bell_ms = params.last_bell_ms,
                    .generation = params.generation,
                });
            },
        }
    }
};

fn monotonicSeconds(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toSeconds();
}

fn defaultPeerEuid(fd: posix.fd_t) ?sys.uid_t {
    return sys.peerEuid(fd) catch null;
}

/// JSON-RPC code and `data.kind` for a handler error. The shared table in
/// `protocol.errorCodeFor` decides; the entries here are request-shape errors
/// raised by this file's own parsing that the table does not name.
fn errorMappingFor(err: anyerror) protocol.ErrorMapping {
    const mapping = protocol.errorCodeFor(err);
    if (mapping.kind != .internal) return mapping;
    return switch (err) {
        error.UnsupportedCommand => .{ .code = protocol.ErrorCode.invalid_params, .kind = .invalid_params },
        else => mapping,
    };
}

// ---------------------------------------------------------------------------
// Socket directory and binding

fn nameZ(buf: *[posix.PATH_MAX]u8, name: []const u8) error{NameTooLong}![*:0]const u8 {
    if (name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0].ptr;
}

fn mkdirAt(dir_fd: posix.fd_t, name: []const u8, mode: std.c.mode_t) !void {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = try nameZ(&buf, name);
    switch (posix.errno(std.c.mkdirat(dir_fd, name_z, mode))) {
        .SUCCESS => {},
        .EXIST => return error.PathAlreadyExists,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOSPC => return error.NoSpaceLeft,
        else => return error.Unexpected,
    }
}

fn rmdirAt(dir_fd: posix.fd_t, name: []const u8) void {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = nameZ(&buf, name) catch return;
    _ = std.c.unlinkat(dir_fd, name_z, std.c.AT.REMOVEDIR);
}

/// `linkat(2)` without following: fails with `error.AddressInUse` when
/// `new_name` exists, so publication never replaces a live entry.
fn linkAt(old_dir_fd: posix.fd_t, old_name: []const u8, new_dir_fd: posix.fd_t, new_name: []const u8) !void {
    var old_buf: [posix.PATH_MAX]u8 = undefined;
    var new_buf: [posix.PATH_MAX]u8 = undefined;
    const old_z = try nameZ(&old_buf, old_name);
    const new_z = try nameZ(&new_buf, new_name);
    while (true) switch (posix.errno(std.c.linkat(old_dir_fd, old_z, new_dir_fd, new_z, 0))) {
        .SUCCESS => return,
        .INTR => continue,
        .EXIST => return error.AddressInUse,
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .NOTDIR => return error.NotDir,
        .NOSPC => return error.NoSpaceLeft,
        else => return error.Unexpected,
    };
}

/// Remove `name` only while it still names the inode `expected`. The check
/// and the unlink are two calls; callers that need exclusion against another
/// publisher hold the daemon start lock.
fn unlinkIfSame(dir_fd: posix.fd_t, name: []const u8, expected: sys.Stat) void {
    const current = sys.statAt(dir_fd, name, false) catch return;
    if (!current.sameFile(expected)) return;
    sys.unlinkAt(dir_fd, name) catch {};
}

fn dupCloexec(fd: posix.fd_t) !posix.fd_t {
    while (true) {
        const rc = std.c.fcntl(fd, posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .BADF => return error.NotOpenForReading,
            else => return error.Unexpected,
        }
    }
}

/// A directory with the sticky bit set lets its owner rename or remove any
/// entry, so a shared sticky parent is trusted only when root or this user
/// owns it.
fn stickyParentTrusted(stat: sys.Stat, euid: sys.uid_t) bool {
    return stat.uid == 0 or stat.uid == euid;
}

/// `openat(dir_fd, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`.
fn openDirAt(dir_fd: posix.fd_t, name: []const u8) !posix.fd_t {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = try nameZ(&buf, name);
    const flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
    while (true) {
        const rc = std.c.openat(dir_fd, name_z, flags, @as(c_uint, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR, .LOOP => return error.NotDir,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

/// Open and validate the directory that holds `socket_path`, creating it
/// private (0700) when it is missing. Returns a pinned descriptor; the caller
/// closes it. Every later lock, PID, and socket operation goes through this
/// descriptor, so swapping the directory name afterwards changes nothing.
///
///   * A daemon-managed default (`$HOME/.smithers`, `/tmp/zmux-<euid>`) must
///     be a self-owned 0700 directory and never a symlink. A self-owned
///     directory left at 0755 by an older release is tightened to 0700; one
///     that is group- or other-writable, or owned by someone else, is refused.
///   * A missing parent is created by zmux and is therefore private too.
///   * An existing user-selected parent must be self-owned with no group or
///     other write permission, or have the sticky bit (such as `/tmp`) and
///     be owned by root or this user. Another user's sticky directory is
///     refused: its owner can rename entries inside it.
pub fn openSocketParent(socket_path: []const u8, getenv: socket_path_mod.GetEnv) !posix.fd_t {
    const parent = std.fs.path.dirname(socket_path) orelse return error.SocketPathNotAbsolute;

    if (socket_path_mod.isDefaultManaged(socket_path, getenv)) return openManagedDir(parent);

    _ = sys.statAt(sys.cwd_fd, parent, true) catch |err| switch (err) {
        error.FileNotFound => return openManagedDir(parent),
        else => return err,
    };

    // A user-selected parent may itself be reached through a symlink (macOS
    // `/tmp`), so the final component is followed; the checks below apply to
    // the directory actually opened.
    const dir_fd = try sys.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    errdefer sys.close(dir_fd);
    const stat = try sys.fstat(dir_fd);
    if (!stat.isDir()) return error.NotDir;
    const sticky = (stat.mode & 0o1000) != 0 and stickyParentTrusted(stat, sys.geteuid());
    const owner_only_write = stat.uid == sys.geteuid() and (stat.mode & 0o022) == 0;
    if (!sticky and !owner_only_write) {
        log.err("socket_dir_insecure", .{
            .dir = parent,
            .mode = stat.permissions(),
            .owner_uid = stat.uid,
            .euid = sys.geteuid(),
        });
        return error.InsecureSocketDirectory;
    }
    return dir_fd;
}

fn openManagedDir(parent: []const u8) !posix.fd_t {
    return sys.ensurePrivateDir(parent) catch |err| switch (err) {
        error.InsecurePermissions => repairManagedDir(parent),
        else => {
            log.err("socket_dir_refused", .{ .dir = parent, .err = err });
            return err;
        },
    };
}

/// A managed directory that already exists with group/other bits. Releases
/// before this one created it 0755, which nobody else can write to, so that
/// case is tightened in place. Group- or other-writable means another user
/// could already have planted entries: refuse.
fn repairManagedDir(parent: []const u8) !posix.fd_t {
    const dir_fd = try sys.openDirNoFollow(parent);
    errdefer sys.close(dir_fd);
    const stat = try sys.fstat(dir_fd);
    if (!stat.isDir()) return error.NotDirectory;
    if (stat.uid != sys.geteuid()) return error.ForeignOwner;
    if ((stat.mode & 0o022) != 0) {
        log.err("socket_dir_refused", .{ .dir = parent, .mode = stat.permissions(), .err = error.InsecurePermissions });
        return error.InsecurePermissions;
    }
    try sys.fchmod(dir_fd, 0o700);
    log.warn("socket_dir_permissions_tightened", .{ .dir = parent, .previous_mode = stat.permissions() });
    return dir_fd;
}

/// Decide what to do with an existing entry at the socket name. Only a stale
/// socket owned by this user is removed; everything else is preserved and
/// reported.
fn clearStaleSocket(dir_fd: posix.fd_t, socket_name: []const u8, socket_path: []const u8) !void {
    const existing = sys.statAt(dir_fd, socket_name, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // A regular file, directory, symlink, or FIFO here is someone's data.
    if (!existing.isSocket()) return error.SocketPathNotSocket;
    if (existing.uid != sys.geteuid()) return error.AccessDenied;

    const probe = sys.connectUnixDeadline(socket_path, sys.monotonicMs() + stale_probe_timeout_ms) catch |err| switch (err) {
        error.ConnectionRefused => {
            // No listener: stale. Remove it only if it is still the entry
            // that was inspected.
            const current = sys.statAt(dir_fd, socket_name, false) catch |stat_err| switch (stat_err) {
                error.FileNotFound => return,
                else => return stat_err,
            };
            if (!current.sameFile(existing)) return error.ProbeInconclusive;
            sys.unlinkAt(dir_fd, socket_name) catch |unlink_err| switch (unlink_err) {
                error.FileNotFound => {},
                else => return unlink_err,
            };
            return;
        },
        error.FileNotFound => return,
        // Timeout, fd exhaustion, or anything else: keep the entry.
        else => return error.ProbeInconclusive,
    };
    defer sys.close(probe);

    const peer = sys.peerEuid(probe) catch return error.ProbeInconclusive;
    if (peer != sys.geteuid()) {
        log.err("socket_owned_by_other_user", .{ .socket_path = socket_path, .peer_euid = peer, .euid = sys.geteuid() });
        return error.AccessDenied;
    }
    return error.AddressInUse;
}

/// Bind `listener` at `socket_path` so the socket file is owner-only (0600)
/// from the instant it becomes reachable, without calling `umask(2)`, and
/// start listening before it gets its public name.
///
/// `umask` is process-wide: narrowing it around `bind` races every other
/// thread that creates a file, which is unacceptable for an embedded server.
/// POSIX has no `bindat`/mode argument for `bind`, so instead:
///
///   1. `mkdirat` a staging directory inside the pinned parent. Its mode is
///      at most 0700 (umask only clears bits) and `mkdirat` fails on any
///      existing name, so nobody else can enter it or have planted it.
///   2. `bind` the socket inside it. Whatever mode the umask yields, the file
///      is unreachable to other users behind the 0700 directory.
///   3. Check ownership, then `fchmodat` the socket to 0600 and verify it.
///   4. `listen`, then `linkat` it to the socket name and drop the staged
///      name. `linkat` is atomic, keeps the bound inode, and fails when the
///      name exists, so the public name only ever refers to a listening 0600
///      socket and a publisher that arrived after `clearStaleSocket` is never
///      replaced (`error.AddressInUse`).
///
/// Returns the identity of the bound inode, taken before publication, so a
/// later cleanup can never remove someone else's socket.
///
/// Every step except `bind` itself is relative to the pinned directory
/// descriptors. The staging path is longer than some valid socket paths. When
/// it cannot fit in `sun_path`, the socket is bound in place only if that is
/// provably private (see bindSocketInPlace); otherwise the bind is refused
/// rather than exposed.
fn bindPrivateSocket(io: std.Io, listener: posix.fd_t, dir_fd: posix.fd_t, socket_name: []const u8, socket_path: []const u8) !sys.Stat {
    // Linux derives the socket file mode from the socket inode's mode, so this
    // makes bind create the file 0600 outright. macOS rejects fchmod on
    // sockets; staging covers both.
    const mode_preset = builtin.os.tag == .linux and blk: {
        sys.fchmod(listener, 0o600) catch break :blk false;
        break :blk true;
    };

    const dir_prefix = socket_path[0 .. socket_path.len - socket_name.len];

    // dir_prefix + staging dir name + "/" + staged_socket_name must fit.
    const fixed_len = dir_prefix.len + staging_dir_prefix.len + 1 + staged_socket_name.len;
    if (fixed_len + staging_dir_random_hex_min > max_socket_path_len) {
        return bindSocketInPlace(listener, dir_fd, socket_name, socket_path, mode_preset);
    }
    const hex_len = @min(staging_dir_random_hex_max, max_socket_path_len - fixed_len);

    var name_buf: [staging_dir_prefix.len + staging_dir_random_hex_max]u8 = undefined;
    var staging_name: []const u8 = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var random: [staging_dir_random_hex_max / 2]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        staging_name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ staging_dir_prefix, hex[0..hex_len] }) catch unreachable;
        mkdirAt(dir_fd, staging_name, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt + 1 >= staging_dir_attempts) return err;
                continue;
            },
            else => return err,
        };
        break;
    }
    defer rmdirAt(dir_fd, staging_name);
    // A restrictive umask (0777) leaves the new directory 000, which its
    // unprivileged owner cannot open. Restore 0700 by name first: in a
    // trusted parent (owner-only, or sticky and owned by root or us) nobody
    // else can replace the entry just created. The fd checks below still
    // verify type, owner, and mode.
    sys.fchmodat(dir_fd, staging_name, 0o700) catch {};

    // Hold the directory by fd and validate that fd, so later checks cannot be
    // redirected by someone swapping the name in a writable parent.
    const staging_fd = try openDirAt(dir_fd, staging_name);
    defer sys.close(staging_fd);
    // Ownership first: never chmod something that is not ours.
    const created = try sys.fstat(staging_fd);
    if (!created.isDir()) return error.PermissionDenied;
    if (created.uid != sys.geteuid()) return error.PermissionDenied;
    // A umask that clears owner bits would make the directory unusable.
    try sys.fchmod(staging_fd, 0o700);
    const dir_stat = try sys.fstat(staging_fd);
    if (dir_stat.permissions() != 0o700) return error.PermissionDenied;

    var staged_buf: [max_socket_path_len]u8 = undefined;
    const staged_path = std.fmt.bufPrint(&staged_buf, "{s}{s}/{s}", .{ dir_prefix, staging_name, staged_socket_name }) catch unreachable;

    const address = try sys.UnixAddress.init(staged_path);
    try sys.bind(listener, &address);
    // The staged name always goes: after a successful link the public name
    // keeps the inode.
    defer sys.unlinkAt(staging_fd, staged_socket_name) catch {};

    const bound = try sys.statAt(staging_fd, staged_socket_name, false);
    if (!bound.isSocket()) return error.PermissionDenied;
    if (bound.uid != sys.geteuid()) return error.PermissionDenied;
    // The path we bound must be the file inside the directory we validated.
    const path_stat = try sys.statAt(sys.cwd_fd, staged_path, false);
    if (!path_stat.sameFile(bound)) return error.PermissionDenied;
    try sys.fchmodat(staging_fd, staged_socket_name, 0o600);
    const socket_stat = try sys.statAt(staging_fd, staged_socket_name, false);
    if (!socket_stat.sameFile(bound)) return error.PermissionDenied;
    if (socket_stat.permissions() != 0o600) return error.PermissionDenied;

    // Size the accept backlog to the connection cap so a burst of clients
    // (e.g. a leader spawning many attachers at once) is queued rather than
    // refused while the accept loop drains it. The kernel silently clamps to
    // somaxconn.
    try sys.listen(listener, @intCast(max_client_connections));
    // No-replace publish; the deferred unlink then drops the staged name.
    try linkAt(staging_fd, staged_socket_name, dir_fd, socket_name);
    return socket_stat;
}

/// Fallback for socket paths too close to the `sun_path` limit to stage.
/// Binding in place is race-free only when no other user can reach the file
/// between `bind` and `chmod`:
///   * Linux, when the pre-bind `fchmod` succeeded: the file is created with
///     at most 0600.
///   * Any OS, when the parent directory is self-owned with no group/other
///     access: nobody else can traverse to the socket.
/// Anything else would briefly expose a umask-mode socket, so it is refused.
fn bindSocketInPlace(
    listener: posix.fd_t,
    dir_fd: posix.fd_t,
    socket_name: []const u8,
    socket_path: []const u8,
    mode_preset: bool,
) !sys.Stat {
    if (!mode_preset) {
        const parent_stat = try sys.fstat(dir_fd);
        const private = parent_stat.isDir() and
            parent_stat.uid == sys.geteuid() and
            (parent_stat.mode & 0o077) == 0;
        if (!private) return error.SocketStagingPathTooLong;
    }

    // `bind` itself fails with `AddressInUse` on an existing name, so this
    // path never replaces an entry either.
    const address = try sys.UnixAddress.init(socket_path);
    try sys.bind(listener, &address);

    var socket_stat = try sys.statAt(dir_fd, socket_name, false);
    // Only the inode just bound is removed on failure.
    const bound = socket_stat;
    errdefer unlinkIfSame(dir_fd, socket_name, bound);
    if (!socket_stat.isSocket() or socket_stat.uid != sys.geteuid()) return error.PermissionDenied;
    // With the preset the mode is already at most 0600; this only widens a
    // umask-narrowed socket back to 0600 so its owner can connect.
    if (socket_stat.permissions() != 0o600) {
        try sys.fchmodat(dir_fd, socket_name, 0o600);
        socket_stat = try sys.statAt(dir_fd, socket_name, false);
    }
    if (socket_stat.permissions() != 0o600) return error.PermissionDenied;
    if (!socket_stat.sameFile(bound)) return error.PermissionDenied;
    try sys.listen(listener, @intCast(max_client_connections));
    return socket_stat;
}

// ---------------------------------------------------------------------------
// Socket I/O

/// Write every byte of `bytes` within `timeout_ms` overall. Uses non-blocking
/// sends plus `poll(POLLOUT)` against one monotonic deadline, so a peer that
/// stops reading costs at most the budget on every platform.
///
/// `fd` must have `O_NONBLOCK` set. `MSG_DONTWAIT` alone is not enough: XNU
/// ignores it for sends (`sosendcheck` only honors the socket's own
/// non-blocking state), so a full buffer would block in the kernel.
fn writeAllDeadline(fd: posix.fd_t, bytes: []const u8, timeout_ms: i64) !void {
    if (std.debug.runtime_safety) std.debug.assert(sys.isNonBlocking(fd));
    const deadline = sys.monotonicMs() + timeout_ms;
    ensureNonBlocking(fd) catch return error.Unexpected;
    const flags: u32 = std.c.MSG.NOSIGNAL | std.c.MSG.DONTWAIT;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.c.send(fd, bytes[offset..].ptr, bytes.len - offset, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return error.WriteZero;
                offset += written;
            },
            .INTR => {},
            .AGAIN => {
                const remaining = deadline - sys.monotonicMs();
                if (remaining <= 0) return error.WriteTimeout;
                var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&fds, @intCast(@min(remaining, 1000))) catch return error.Unexpected;
            },
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

/// Set `O_NONBLOCK` unless it is already set (one `fcntl` in the common case).
fn ensureNonBlocking(fd: posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return error.Unexpected;
    const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if ((flags & nonblock) != 0) return;
    if (std.c.fcntl(fd, std.c.F.SETFL, flags | nonblock) < 0) return error.Unexpected;
}

/// Bound a blocking send in the kernel on every platform (`SO_SNDTIMEO`), as
/// a backstop for `writeAllDeadline`. Returns whether the option was set.
fn setSocketSendTimeout(fd: posix.fd_t) bool {
    var timeout: std.c.timeval = .{
        .sec = @intCast(socket_send_timeout_seconds),
        .usec = 0,
    };
    if (std.c.setsockopt(
        fd,
        std.c.SOL.SOCKET,
        std.c.SO.SNDTIMEO,
        &timeout,
        @intCast(@sizeOf(std.c.timeval)),
    ) != 0) {
        log.warnRateLimited("socket_send_timeout_failed", &sockopt_limiter, .{
            .errno = @backingInt(posix.errno(@as(c_int, -1))),
        });
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Request parameters. A parameter that is present with the wrong type is an
// error (`InvalidParams`), never a silent default. JSON `null` counts as
// absent.

fn paramValue(params: ?Value, key: []const u8) ?Value {
    const params_value = params orelse return null;
    if (params_value != .object) return null;
    const value = params_value.object.get(key) orelse return null;
    if (value == .null) return null;
    return value;
}

fn optionalString(params: ?Value, key: []const u8) !?[]const u8 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidParams,
    };
}

fn firstStringParam(params: ?Value, keys: []const []const u8) !?[]const u8 {
    for (keys) |key| {
        if (try optionalString(params, key)) |value| return value;
    }
    return null;
}

fn optionalBool(params: ?Value, key: []const u8) !?bool {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidParams,
    };
}

/// Absent → null. Wrong type, negative, fractional, or out of range for `T`
/// → `InvalidParams`.
fn optionalInt(comptime T: type, params: ?Value, key: []const u8) !?T {
    const value = paramValue(params, key) orelse return null;
    const integer = switch (value) {
        .integer => |n| n,
        else => return error.InvalidParams,
    };
    if (integer < 0) return error.InvalidParams;
    return std.math.cast(T, integer) orelse error.InvalidParams;
}

fn objectParam(params: ?Value, key: []const u8) !?Value {
    const value = paramValue(params, key) orelse return null;
    if (value != .object) return error.InvalidParams;
    return value;
}

/// Terminal rows or columns: an integer in 1..65535, else `InvalidDimensions`.
fn dimensionParam(params: ?Value, key: []const u8, default: u16) !u16 {
    const value = paramValue(params, key) orelse return default;
    const integer = switch (value) {
        .integer => |n| n,
        else => return error.InvalidParams,
    };
    if (integer < 1 or integer > std.math.maxInt(u16)) return error.InvalidDimensions;
    return @intCast(integer);
}

fn sessionIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "sessionId", "id" });
}

fn paneIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "paneId", "targetPaneId", "target", "sessionId", "id" });
}

fn windowIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "windowId", "targetWindowId", "target", "id" });
}

fn clientIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "clientId", "targetClientId", "id" });
}

fn axisParam(params: ?Value) !mux.Axis {
    const axis = try optionalString(params, "axis") orelse {
        return if (try optionalBool(params, "horizontal") orelse false) .horizontal else .vertical;
    };
    if (std.mem.eql(u8, axis, "horizontal") or std.mem.eql(u8, axis, "h") or std.mem.eql(u8, axis, "-h")) {
        return .horizontal;
    }
    if (std.mem.eql(u8, axis, "vertical") or std.mem.eql(u8, axis, "v") or std.mem.eql(u8, axis, "-v")) {
        return .vertical;
    }
    return error.InvalidAxis;
}

fn scrollbackBytesFromParams(params: ?Value) !usize {
    const bytes = try optionalInt(usize, params, "scrollbackBytes") orelse return buffer_mod.default_capacity;
    if (bytes == 0) return error.InvalidParams;
    if (bytes > buffer_mod.max_capacity) return error.ScrollbackBytesTooLarge;
    return bytes;
}

const MuxCreateArgs = struct {
    allocator: Allocator,
    env_entries: ?[][]const u8 = null,
    opts: mux.CreateOptions,

    pub fn deinit(self: *MuxCreateArgs) void {
        if (self.env_entries) |entries| freeStringSlice(self.allocator, entries);
        self.env_entries = null;
        self.opts = .{};
    }
};

const CreateArgsOptions = struct {
    // When true, `id` falls back into the title slot. Only `session.create`
    // sets this: for `window.new` and `pane.split` the request's `id` field
    // already aliases the *target* (via paneIdParam / sessionIdParam), and
    // repurposing it as the new window/pane title would silently rename
    // them on every call.
    id_aliases_title: bool = false,
};

/// Reject a string the kernel would truncate at its first NUL.
fn spawnString(value: ?[]const u8) !?[]const u8 {
    const text = value orelse return null;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSpawnArgument;
    return text;
}

/// Parse and validate every create parameter before any side effect.
fn muxCreateArgsFromParams(allocator: Allocator, params: ?Value, options: CreateArgsOptions) !MuxCreateArgs {
    if (params) |value| switch (value) {
        .object, .null => {},
        else => return error.InvalidParams,
    };

    const title_keys: []const []const u8 = if (options.id_aliases_title)
        &.{ "title", "name", "id" }
    else
        &.{ "title", "name" };
    const title = try firstStringParam(params, title_keys);
    const shell = try spawnString(try optionalString(params, "shell"));
    const command = try spawnString(try optionalString(params, "command"));
    const cwd = try spawnString(try firstStringParam(params, &.{ "cwd", "workingDirectory" }));
    const rows = try dimensionParam(params, "rows", 24);
    const cols = try dimensionParam(params, "cols", 80);
    const scrollback_bytes = try scrollbackBytesFromParams(params);
    const clear_env = try optionalBool(params, "clearEnv") orelse false;

    const env_entries = try envEntriesFromParams(allocator, params);
    errdefer if (env_entries) |entries| freeStringSlice(allocator, entries);

    // `env` merges over the daemon environment by default (D3); `clearEnv`
    // asks for full replacement.
    const opts: mux.CreateOptions = .{
        .title = title,
        .shell = shell,
        .command = command,
        .cwd = cwd,
        .env = if (env_entries) |entries| entries else null,
        .env_mode = if (clear_env) .replace else .merge,
        .rows = rows,
        .cols = cols,
        .scrollback_bytes = scrollback_bytes,
    };
    return .{
        .allocator = allocator,
        .env_entries = env_entries,
        .opts = opts,
    };
}

/// `env` / `environment`: an object of string values only. Anything else is
/// `InvalidParams`; a key that is empty or contains `=` or NUL, or a value
/// with NUL, is `InvalidSpawnArgument`. Values are never re-serialized.
fn envEntriesFromParams(allocator: Allocator, params: ?Value) !?[][]const u8 {
    const env_value = paramValue(params, "env") orelse paramValue(params, "environment") orelse return null;
    if (env_value != .object) return error.InvalidParams;

    var entries = std.ArrayList([]const u8).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var it = env_value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = switch (entry.value_ptr.*) {
            .string => |text| text,
            else => return error.InvalidParams,
        };
        if (key.len == 0 or std.mem.indexOfAny(u8, key, "=\x00") != null) return error.InvalidSpawnArgument;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSpawnArgument;

        const env_entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
        errdefer allocator.free(env_entry);
        try entries.append(allocator, env_entry);
    }

    return try entries.toOwnedSlice(allocator);
}

fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

/// Response bytes reserved for the capture reply's envelope and keys.
const capture_envelope_reserve_bytes: usize = 4096;

/// Start of the longest tail of `text` whose `text` (lossy JSON string) plus
/// `textBase64` encodings fit in `budget` bytes, costing every byte at its
/// worst case: 6 for a control byte (`\u00XX`), 2 for a quote or backslash,
/// 3 for a byte at or above 0x80 (an invalid byte becomes U+FFFD).
fn captureTailStart(text: []const u8, budget: usize) usize {
    var escaped: usize = 2; // the quotes
    var start = text.len;
    while (start > 0) {
        const byte = text[start - 1];
        const cost: usize = switch (byte) {
            0...0x1f, 0x7f => 6,
            '"', '\\' => 2,
            0x80...0xff => 3,
            else => 1,
        };
        const n = text.len - start + 1;
        const base64_len = 4 * ((n + 2) / 3) + 2;
        if (escaped + cost + base64_len > budget) break;
        escaped += cost;
        start -= 1;
    }
    return start;
}

fn truncatedReplay(scrollback: []const u8, max_bytes: usize) []const u8 {
    if (scrollback.len <= max_bytes) return scrollback;
    return scrollback[scrollback.len - max_bytes ..];
}

fn base64Encode(allocator: Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

fn base64Decode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

/// Internal hooks exposed for the repository's own fuzz suites.
pub const fuzz_hooks = struct {
    pub const Connection = ClientConnection;
    pub const CreateArgs = MuxCreateArgs;
    pub const CreateArgsOpts = CreateArgsOptions;
    pub const max_request_size = max_request_bytes;
    pub const attach_replay_cap = attach_replay_max_bytes;
    pub const broadcast_queue_cap = broadcast_queue_max_bytes;
    pub const control_queue_cap = control_queue_max_bytes;

    pub const muxCreateArgs = muxCreateArgsFromParams;
    pub const envEntries = envEntriesFromParams;
    pub const freeEnvEntries = freeStringSlice;
    pub const scrollbackBytes = scrollbackBytesFromParams;
    pub const axis = axisParam;
    pub const sessionId = sessionIdParam;
    pub const paneId = paneIdParam;
    pub const windowId = windowIdParam;
    pub const clientId = clientIdParam;
    pub const boolParamVal = optionalBool;
    pub const intParamVal = optionalInt;
    pub const dimensionVal = dimensionParam;
    pub const replayTail = truncatedReplay;
    pub const b64Encode = base64Encode;
    pub const b64Decode = base64Decode;
    pub const errorMapping = errorMappingFor;

    pub fn createConnection(allocator: Allocator, io: std.Io, fd: posix.fd_t) !*ClientConnection {
        return ClientConnection.create(allocator, io, fd, null);
    }

    pub fn releaseConnection(conn: *ClientConnection) void {
        conn.release();
    }

    pub fn closeConnection(conn: *ClientConnection) void {
        conn.close();
    }

    pub fn isConnectionClosed(conn: *const ClientConnection) bool {
        return conn.isClosed();
    }

    /// Queue a control notification. A terminal failure closes the
    /// connection, as `Server.deliver` does.
    pub fn enqueueBroadcast(conn: *ClientConnection, bytes: []const u8) !void {
        conn.enqueueBroadcast(bytes) catch |err| {
            if (err != error.ConnectionClosed) conn.close();
            return err;
        };
    }

    /// Queue a synthetic `pane_output` frame of `bytes` for `pane_id`.
    pub fn enqueuePaneOutput(conn: *ClientConnection, pane_id: []const u8, bytes: []const u8, offset: u64) !void {
        const owned = try conn.allocator.dupe(u8, bytes);
        errdefer conn.allocator.free(owned);
        const owned_pane = try conn.allocator.dupe(u8, pane_id);
        errdefer conn.allocator.free(owned_pane);
        const payload = try Payload.create(conn.allocator, owned, .{
            .pane_id = owned_pane,
            .data_len = bytes.len,
            .end_offset = offset + bytes.len,
        });
        defer payload.release();
        return conn.enqueue(payload);
    }

    /// Next queued frame without blocking; the caller frees it.
    pub fn takeQueuedWrite(conn: *ClientConnection) ?[]u8 {
        const payload = conn.tryTakeQueuedWrite() orelse return null;
        defer payload.release();
        return conn.allocator.dupe(u8, payload.bytes) catch null;
    }

    pub fn trackMuxClient(conn: *ClientConnection, client_id: []const u8, pane_id: []const u8) !void {
        return conn.trackMuxClient(client_id, pane_id);
    }

    pub fn untrackMuxClient(conn: *ClientConnection, client_id: []const u8) bool {
        return conn.untrackMuxClient(client_id);
    }

    pub fn wantsPaneOutput(conn: *ClientConnection, pane_id: []const u8) bool {
        return conn.wantsPaneOutput(pane_id);
    }

    /// Take every tracked mux client id; the caller frees each id and the list.
    pub fn takeMuxClients(conn: *ClientConnection) std.ArrayList([]u8) {
        var attachments = conn.takeMuxClients();
        defer attachments.deinit(conn.allocator);
        var ids: std.ArrayList([]u8) = .empty;
        ids.ensureTotalCapacityPrecise(conn.allocator, attachments.items.len) catch {
            for (attachments.items) |attachment| attachment.deinit(conn.allocator);
            return .empty;
        };
        for (attachments.items) |attachment| {
            conn.allocator.free(attachment.pane_id);
            ids.appendAssumeCapacity(attachment.client_id);
        }
        return ids;
    }

    /// Initialize a Server without binding a UNIX socket on disk so wire-level
    /// JSON-RPC fuzzers can drive `handleClient` over an in-memory socketpair.
    pub fn initInMemoryServer(allocator: Allocator, io: std.Io) !Server {
        const owned_socket_path = try allocator.dupe(u8, "/in-memory/zmux-fuzz.sock");
        return .{
            .allocator = allocator,
            .io = io,
            .socket_path = owned_socket_path,
            .socket_stat = .{ .dev = 0, .ino = 0, .mode = 0, .uid = 0 },
            .listener_fd = -1,
            .manager = mux.Manager.init(allocator, io, null),
            .last_activity_seconds = std.atomic.Value(i64).init(monotonicSeconds(io)),
            .idle_timeout_seconds = 0,
        };
    }

    /// Route native session events through the server, as `run` does.
    pub fn enableEvents(server: *Server) void {
        server.installEventSinks();
    }

    pub fn deinitInMemoryServer(server: *Server) void {
        server.deinit();
    }

    /// Drive a single client connection synchronously until EOF / shutdown.
    /// Takes ownership of `client_fd` (closed when the connection is released,
    /// or here when the connection cannot be allocated).
    pub fn driveClient(server: *Server, client_fd: posix.fd_t) !void {
        const connection = ClientConnection.create(server.allocator, server.io, client_fd, server) catch |err| {
            sys.close(client_fd);
            return err;
        };
        defer connection.release();
        defer connection.close();

        if (!server.registerConnection(connection)) return;
        defer server.unregisterConnection(connection);

        server.handleClient(connection);
    }
};

// ---------------------------------------------------------------------------
// Tests

const test_io = std.testing.io;

fn noEnv(_: []const u8) ?[]const u8 {
    return null;
}

fn sleepMs(ms: i64) void {
    test_io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn waitForFlag(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const deadline = sys.monotonicMs() + timeout_ms;
    while (sys.monotonicMs() < deadline) {
        if (flag.load(.seq_cst)) return true;
        sleepMs(5);
    }
    return flag.load(.seq_cst);
}

/// Read one newline-terminated line within `timeout_ms`. The caller frees it.
fn readLineTimeout(allocator: Allocator, fd: posix.fd_t, timeout_ms: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const deadline = sys.monotonicMs() + timeout_ms;
    var byte: [1]u8 = undefined;
    while (true) {
        const remaining = deadline - sys.monotonicMs();
        if (remaining <= 0) return error.ReadTimeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(remaining)) == 0) return error.ReadTimeout;
        // A peer that closed with unread input reports a reset, not EOF.
        const n = posix.read(fd, &byte) catch |err| {
            const any_err: anyerror = err;
            if (any_err == error.ConnectionResetByPeer) return error.EndOfStream;
            return err;
        };
        if (n == 0) return error.EndOfStream;
        try out.append(allocator, byte[0]);
        if (byte[0] == '\n') return out.toOwnedSlice(allocator);
    }
}

fn parseJson(text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, std.testing.allocator, text, .{ .allocate = .alloc_always });
}

/// A client on one end of a socketpair, served by `driveClient` on a thread.
const TestClient = struct {
    fd: posix.fd_t,
    thread: std.Thread,

    fn start(server: *Server) !TestClient {
        const fds = try sys.socketPair();
        errdefer sys.close(fds[1]);
        // Pane children fork from this process: keep them from inheriting
        // either end.
        sys.setCloseOnExec(fds[0]) catch {};
        sys.setCloseOnExec(fds[1]) catch {};
        const thread = std.Thread.spawn(.{}, drive, .{ server, fds[0] }) catch |err| {
            sys.close(fds[0]);
            return err;
        };
        return .{ .fd = fds[1], .thread = thread };
    }

    fn drive(server: *Server, fd: posix.fd_t) void {
        fuzz_hooks.driveClient(server, fd) catch {};
    }

    fn stop(self: *TestClient) void {
        // Shut down first: a forked child that still holds a duplicate of
        // this descriptor must not keep the server side waiting for EOF.
        _ = std.c.shutdown(self.fd, @intCast(posix.SHUT.RDWR));
        sys.close(self.fd);
        self.thread.join();
    }

    fn send(self: *TestClient, bytes: []const u8) !void {
        try sys.writeAll(self.fd, bytes);
    }

    fn sendFmt(self: *TestClient, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
        defer std.testing.allocator.free(text);
        try self.send(text);
    }

    fn nextLine(self: *TestClient) !std.json.Parsed(Value) {
        const line = try readLineTimeout(std.testing.allocator, self.fd, 5000);
        defer std.testing.allocator.free(line);
        return parseJson(line);
    }

    /// The response to request `id`, skipping notifications.
    fn response(self: *TestClient, id: i64) !std.json.Parsed(Value) {
        while (true) {
            var parsed = try self.nextLine();
            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |got| {
                    if (got == .integer and got.integer == id) return parsed;
                }
            }
            parsed.deinit();
        }
    }

    /// The next notification named `method`, skipping everything else.
    fn notification(self: *TestClient, method: []const u8) !std.json.Parsed(Value) {
        while (true) {
            var parsed = try self.nextLine();
            if (parsed.value == .object) {
                if (parsed.value.object.get("method")) |got| {
                    if (got == .string and std.mem.eql(u8, got.string, method)) return parsed;
                }
            }
            parsed.deinit();
        }
    }
};

fn resultOf(parsed: *const std.json.Parsed(Value)) !std.json.ObjectMap {
    if (parsed.value.object.get("error")) |_| return error.UnexpectedRpcError;
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.ResultNotObject;
    return result.object;
}

fn expectRpcError(parsed: *const std.json.Parsed(Value), code: i64, kind: []const u8, message: []const u8) !void {
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expectEqual(code, err_val.object.get("code").?.integer);
    try std.testing.expectEqualStrings(message, err_val.object.get("message").?.string);
    try std.testing.expectEqualStrings(kind, err_val.object.get("data").?.object.get("kind").?.string);
}

/// A registered connection with no reader or writer thread: tests drain its
/// queue with `tryTakeQueuedWrite`.
const QueueProbe = struct {
    server: *Server,
    connection: *ClientConnection,
    peer_fd: posix.fd_t,

    fn init(server: *Server) !QueueProbe {
        const fds = try sys.socketPair();
        errdefer sys.close(fds[1]);
        const connection = ClientConnection.create(std.testing.allocator, test_io, fds[0], null) catch |err| {
            sys.close(fds[0]);
            return err;
        };
        errdefer connection.release();
        if (!server.registerConnection(connection)) return error.ServerStopping;
        return .{ .server = server, .connection = connection, .peer_fd = fds[1] };
    }

    fn deinit(self: *QueueProbe) void {
        self.server.unregisterConnection(self.connection);
        self.connection.release();
        sys.close(self.peer_fd);
    }

    /// Next queued frame, or null. The caller frees it.
    fn take(self: *QueueProbe) ?[]u8 {
        return fuzz_hooks.takeQueuedWrite(self.connection);
    }

    fn expectNext(self: *QueueProbe, needles: []const []const u8) !void {
        const frame = self.take() orelse return error.NothingQueued;
        defer std.testing.allocator.free(frame);
        for (needles) |needle| {
            if (std.mem.indexOf(u8, frame, needle) == null) {
                std.debug.print("frame {s} lacks {s}\n", .{ frame[0..@min(frame.len, 300)], needle });
                return error.FrameMismatch;
            }
        }
    }

    fn expectEmpty(self: *QueueProbe) !void {
        if (self.take()) |frame| {
            defer std.testing.allocator.free(frame);
            std.debug.print("unexpected frame {s}\n", .{frame[0..@min(frame.len, 300)]});
            return error.UnexpectedFrame;
        }
    }
};

fn emitOutput(server: *Server, pane_id: []const u8, data: []const u8, offset: u64) void {
    Server.handleNativeEvent(server, .{ .pane_output = .{
        .pane_id = pane_id,
        .data = data,
        .offset = offset,
        .generation = 3,
    } });
}

test "server parses aliases for session id" {
    var parsed = try parseJson("{\"id\":\"sess-1\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess-1", (try sessionIdParam(parsed.value)).?);
}

test "mux create args treats id as title only for session create" {
    var parsed = try parseJson("{\"id\":\"target-pane\",\"rows\":40,\"cols\":120}");
    defer parsed.deinit();

    var target_args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer target_args.deinit();
    try std.testing.expect(target_args.opts.title == null);
    try std.testing.expectEqual(@as(u16, 40), target_args.opts.rows);
    try std.testing.expectEqual(@as(u16, 120), target_args.opts.cols);

    var create_args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{ .id_aliases_title = true });
    defer create_args.deinit();
    try std.testing.expectEqualStrings("target-pane", create_args.opts.title.?);
}

test "mux create args passes string environment values through unchanged" {
    var parsed = try parseJson("{\"env\":{\"TEXT\":\"one\",\"COUNT\":\"7\",\"EMPTY\":\"\"},\"scrollbackBytes\":4096}");
    defer parsed.deinit();

    var args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 4096), args.opts.scrollback_bytes);
    const entries = args.opts.env orelse return error.MissingEnvEntries;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(envContains(entries, "TEXT=one"));
    try std.testing.expect(envContains(entries, "COUNT=7"));
    try std.testing.expect(envContains(entries, "EMPTY="));
}

test "mux create args rejects non-string env values and unsafe spawn strings" {
    const Case = struct { json: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .json = "{\"env\":{\"COUNT\":7}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"FLAG\":true}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"NESTED\":{\"a\":1}}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"LIST\":[1]}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"NULLED\":null}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":[\"A=1\"]}", .err = error.InvalidParams },
        .{ .json = "{\"env\":\"A=1\"}", .err = error.InvalidParams },
        .{ .json = "{\"environment\":{\"COUNT\":7}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"A=B\":\"x\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"env\":{\"\":\"x\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"env\":{\"A\":\"x\\u0000y\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"env\":{\"A\\u0000B\":\"x\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"shell\":\"/bin/sh\\u0000x\"}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"command\":\"a\\u0000b\"}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"cwd\":\"/tmp\\u0000x\"}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"shell\":7}", .err = error.InvalidParams },
        .{ .json = "{\"title\":false}", .err = error.InvalidParams },
        .{ .json = "{\"clearEnv\":\"yes\"}", .err = error.InvalidParams },
        .{ .json = "{\"rows\":0}", .err = error.InvalidDimensions },
        .{ .json = "{\"cols\":65536}", .err = error.InvalidDimensions },
        .{ .json = "{\"rows\":\"24\"}", .err = error.InvalidParams },
        .{ .json = "{\"scrollbackBytes\":0}", .err = error.InvalidParams },
        .{ .json = "{\"scrollbackBytes\":-1}", .err = error.InvalidParams },
        .{ .json = "{\"scrollbackBytes\":\"big\"}", .err = error.InvalidParams },
        .{ .json = "7", .err = error.InvalidParams },
        .{ .json = "\"text\"", .err = error.InvalidParams },
        .{ .json = "[1,2]", .err = error.InvalidParams },
    };
    for (cases) |case| {
        var parsed = try parseJson(case.json);
        defer parsed.deinit();
        if (muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{})) |created| {
            var args = created;
            args.deinit();
            std.debug.print("accepted {s}\n", .{case.json});
            return error.TestExpectedError;
        } else |err| {
            if (err != case.err) {
                std.debug.print("{s}: got {s}\n", .{ case.json, @errorName(err) });
                return error.TestUnexpectedError;
            }
        }
    }
}

test "mux create args parses clearEnv" {
    var parsed = try parseJson("{\"clearEnv\":true,\"env\":{\"A\":\"1\"}}");
    defer parsed.deinit();
    var args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer args.deinit();
    try std.testing.expect(args.opts.env_mode == .replace);

    var merged = try parseJson("{\"env\":{\"A\":\"1\"}}");
    defer merged.deinit();
    var merge_args = try muxCreateArgsFromParams(std.testing.allocator, merged.value, .{});
    defer merge_args.deinit();
    try std.testing.expect(merge_args.opts.env_mode == .merge);
}

test "mux create args rejects oversize scrollbackBytes" {
    const max = buffer_mod.max_capacity;
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"scrollbackBytes\":{}}}", .{max + 1});
    defer std.testing.allocator.free(payload);

    var parsed = try parseJson(payload);
    defer parsed.deinit();
    try std.testing.expectError(
        error.ScrollbackBytesTooLarge,
        muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{}),
    );
}

test "typed params reject wrong types instead of falling back to defaults" {
    var parsed = try parseJson(
        "{\"n\":5,\"neg\":-1,\"frac\":1.5,\"text\":\"5\",\"flag\":true,\"nil\":null,\"big\":70000,\"huge\":99999999999999999999}",
    );
    defer parsed.deinit();
    const params: ?Value = parsed.value;

    try std.testing.expectEqual(@as(?u16, 5), try optionalInt(u16, params, "n"));
    try std.testing.expectEqual(@as(?u16, null), try optionalInt(u16, params, "missing"));
    try std.testing.expectEqual(@as(?u16, null), try optionalInt(u16, params, "nil"));
    try std.testing.expectEqual(@as(?u16, null), try optionalInt(u16, null, "n"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "neg"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "frac"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "text"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "flag"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "big"));
    try std.testing.expectError(error.InvalidParams, optionalInt(usize, params, "huge"));

    try std.testing.expectEqual(@as(?bool, true), try optionalBool(params, "flag"));
    try std.testing.expectEqual(@as(?bool, null), try optionalBool(params, "missing"));
    try std.testing.expectError(error.InvalidParams, optionalBool(params, "n"));
    try std.testing.expectError(error.InvalidParams, optionalBool(params, "text"));

    try std.testing.expectEqualStrings("5", (try optionalString(params, "text")).?);
    try std.testing.expect((try optionalString(params, "missing")) == null);
    try std.testing.expectError(error.InvalidParams, optionalString(params, "n"));
    try std.testing.expectError(error.InvalidParams, optionalString(params, "flag"));

    try std.testing.expectEqual(@as(u16, 24), try dimensionParam(params, "missing", 24));
    try std.testing.expectEqual(@as(u16, 5), try dimensionParam(params, "n", 24));
    try std.testing.expectError(error.InvalidDimensions, dimensionParam(params, "neg", 24));
    try std.testing.expectError(error.InvalidDimensions, dimensionParam(params, "big", 24));
    try std.testing.expectError(error.InvalidParams, dimensionParam(params, "text", 24));
    try std.testing.expectError(error.InvalidParams, dimensionParam(params, "frac", 24));
}

test "axisParam accepts aliases and rejects unknown axes" {
    var horizontal_string = try parseJson("{\"axis\":\"-h\"}");
    defer horizontal_string.deinit();
    try std.testing.expectEqual(mux.Axis.horizontal, try axisParam(horizontal_string.value));

    var horizontal_bool = try parseJson("{\"horizontal\":true}");
    defer horizontal_bool.deinit();
    try std.testing.expectEqual(mux.Axis.horizontal, try axisParam(horizontal_bool.value));

    var vertical = try parseJson("{\"axis\":\"v\"}");
    defer vertical.deinit();
    try std.testing.expectEqual(mux.Axis.vertical, try axisParam(vertical.value));

    var default_axis = try parseJson("{}");
    defer default_axis.deinit();
    try std.testing.expectEqual(mux.Axis.vertical, try axisParam(default_axis.value));

    var unknown = try parseJson("{\"axis\":\"diagonal\"}");
    defer unknown.deinit();
    try std.testing.expectError(error.InvalidAxis, axisParam(unknown.value));

    var wrong_type = try parseJson("{\"axis\":7}");
    defer wrong_type.deinit();
    try std.testing.expectError(error.InvalidParams, axisParam(wrong_type.value));
}

test "M10: a control-heavy capture keeps a tail whose encoding fits the response cap" {
    const allocator = std.testing.allocator;
    const raw = try allocator.alloc(u8, capture_max_bytes);
    defer allocator.free(raw);
    @memset(raw, 0x01);
    raw[raw.len - 1] = '"';
    raw[raw.len - 2] = 0xff;

    const budget = max_response_bytes - capture_envelope_reserve_bytes;
    const start = captureTailStart(raw, budget);
    try std.testing.expect(start > 0);
    try std.testing.expect(start < raw.len);
    const text = raw[start..];

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try protocol.writeJsonStringLossy(&out.writer, text);
    const b64 = try base64Encode(allocator, text);
    defer allocator.free(b64);
    try std.testing.expect(out.written().len + b64.len + 2 <= budget);
    // Plain text is never trimmed below the cap.
    try std.testing.expectEqual(@as(usize, 0), captureTailStart("hello", budget));
}

test "M08: a failed queue growth releases nothing it did not retain" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer sys.close(fds[1]);
    const connection = try ClientConnection.create(allocator, test_io, fds[0], null);
    defer connection.release();
    // Swap in the failing allocator for the queue only.
    connection.allocator = failing.allocator();
    failing.fail_index = failing.alloc_index;

    for ([_]bool{ false, true }) |output| {
        const bytes = try allocator.dupe(u8, "{}\n");
        const pane_id = if (output) try allocator.dupe(u8, "p") else null;
        const payload = Payload.create(allocator, bytes, if (output) OutputMeta{ .pane_id = pane_id.?, .data_len = 1, .end_offset = 1 } else null) catch unreachable;
        try std.testing.expectError(error.OutOfMemory, connection.enqueue(payload));
        // The only reference left is ours: the leak checker fails otherwise.
        try std.testing.expectEqual(@as(u32, 1), payload.ref_count.load(.seq_cst));
        payload.release();
    }
    connection.allocator = allocator;
}

test "M09: drop records reset on a newer generation and ignore an older one" {
    const allocator = std.testing.allocator;
    var fds: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer sys.close(fds[1]);
    const connection = try ClientConnection.create(allocator, test_io, fds[0], null);
    defer connection.release();

    var pane = "p".*;
    try connection.recordDropLocked(.{ .pane_id = &pane, .data_len = 900, .end_offset = 1000, .generation = 1 });
    try connection.recordDropLocked(.{ .pane_id = &pane, .data_len = 10, .end_offset = 10, .generation = 2 });
    try connection.recordDropLocked(.{ .pane_id = &pane, .data_len = 5, .end_offset = 2000, .generation = 1 });
    try std.testing.expectEqual(@as(usize, 1), connection.dropped.items.len);
    const record = connection.dropped.items[0];
    try std.testing.expectEqual(@as(u64, 2), record.generation);
    try std.testing.expectEqual(@as(u64, 10), record.resume_offset);
    try std.testing.expectEqual(@as(u64, 10), record.dropped_bytes);

    const notice = try connection.takeDropNoticeLocked();
    defer notice.release();
    try std.testing.expect(std.mem.indexOf(u8, notice.bytes, "\"resume_offset\":10") != null);
}

test "truncatedReplay keeps tail when larger than cap" {
    const full = "abcdefghij";
    try std.testing.expectEqualStrings("ghij", truncatedReplay(full, 4));
    try std.testing.expectEqualStrings("abcdefghij", truncatedReplay(full, 128));
}

test "error mapping routes every handler error through the shared table" {
    const Case = struct { err: anyerror, code: i32, kind: protocol.ErrorKind };
    const cases = [_]Case{
        .{ .err = error.ParseError, .code = -32700, .kind = .parse },
        .{ .err = error.InvalidRequest, .code = -32600, .kind = .invalid_request },
        .{ .err = error.MessageTooLarge, .code = -32600, .kind = .invalid_request },
        .{ .err = error.MethodNotFound, .code = -32601, .kind = .method_not_found },
        .{ .err = error.InvalidParams, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidDimensions, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidAxis, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidSpawnArgument, .code = -32602, .kind = .invalid_params },
        .{ .err = error.UnknownKey, .code = -32602, .kind = .invalid_params },
        .{ .err = error.UnsupportedCommand, .code = -32602, .kind = .invalid_params },
        .{ .err = error.SessionNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.PaneNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.ClientNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.SessionTerminated, .code = -32000, .kind = .terminated },
        .{ .err = error.PaneRunning, .code = -32000, .kind = .conflict },
        .{ .err = error.DuplicateSessionName, .code = -32000, .kind = .conflict },
        .{ .err = error.LimitExceeded, .code = -32000, .kind = .limit },
        .{ .err = error.InputTimeout, .code = -32000, .kind = .io },
        .{ .err = error.OutOfMemory, .code = -32603, .kind = .internal },
        .{ .err = error.Unexpected, .code = -32603, .kind = .internal },
    };
    for (cases) |case| {
        const mapping = errorMappingFor(case.err);
        try std.testing.expectEqual(case.code, mapping.code);
        try std.testing.expectEqual(case.kind, mapping.kind);
    }
}

test "peer credential check accepts same-user unix socket peer" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = sys.socketPair() catch return error.SkipZigTest;
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);

    try std.testing.expectEqual(@as(?sys.uid_t, sys.geteuid()), defaultPeerEuid(sockets[0]));
}

fn foreignPeerEuid(_: posix.fd_t) ?sys.uid_t {
    return sys.geteuid() +% 1;
}

fn unknownPeerEuid(_: posix.fd_t) ?sys.uid_t {
    return null;
}

test "a peer with another uid or unknown credentials is refused at admission" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);

    const Seam = struct { peer: Server.PeerEuidFn };
    for ([_]Seam{ .{ .peer = foreignPeerEuid }, .{ .peer = unknownPeerEuid } }, 1..) |seam, expected_rejections| {
        server.peer_euid_fn = seam.peer;
        const sockets = try sys.socketPair();
        defer sys.close(sockets[1]);
        try std.testing.expect(!server.peerAllowed(sockets[0]));

        // admit owns the descriptor: the rejected peer sees EOF, no worker
        // is started, and the rejection is counted.
        server.admit(sockets[0]);
        try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, sockets[1], 1000));
        try std.testing.expectEqual(@as(usize, 0), server.active_connections.load(.seq_cst));
        try std.testing.expectEqual(@as(u64, expected_rejections), server.rejected_connections.load(.monotonic));
    }

    server.peer_euid_fn = defaultPeerEuid;
    const sockets = try sys.socketPair();
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);
    try std.testing.expect(server.peerAllowed(sockets[0]));
}

test "SO_SNDTIMEO is set on client sockets on every platform" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = try sys.socketPair();
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);

    try std.testing.expect(setSocketSendTimeout(sockets[0]));

    var timeout: std.c.timeval = undefined;
    var len: std.c.socklen_t = @sizeOf(std.c.timeval);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockopt(sockets[0], std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &timeout, &len));
    try std.testing.expectEqual(@as(i64, socket_send_timeout_seconds), @as(i64, @intCast(timeout.sec)));
    try std.testing.expectEqual(@as(i64, 0), @as(i64, @intCast(timeout.usec)));

    // The untouched end still has no timeout, so the assertion above is not
    // reading a platform default.
    var other: std.c.timeval = undefined;
    var other_len: std.c.socklen_t = @sizeOf(std.c.timeval);
    try std.testing.expectEqual(@as(c_int, 0), std.c.getsockopt(sockets[1], std.c.SOL.SOCKET, std.c.SO.SNDTIMEO, &other, &other_len));
    try std.testing.expectEqual(@as(i64, 0), @as(i64, @intCast(other.sec)));
}

test "a write to a peer that never reads fails at the overall deadline" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = try sys.socketPair();
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);
    try sys.setNonBlocking(sockets[0]);

    const payload = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const start = sys.monotonicMs();
    try std.testing.expectError(error.WriteTimeout, writeAllDeadline(sockets[0], payload, 300));
    const elapsed = sys.monotonicMs() - start;
    try std.testing.expect(elapsed >= 250);
    try std.testing.expect(elapsed < 3000);

    // A reader lets the same call finish.
    const Drain = struct {
        fn run(fd: posix.fd_t, total: usize) void {
            var buf: [64 * 1024]u8 = undefined;
            var seen: usize = 0;
            while (seen < total) {
                const n = posix.read(fd, &buf) catch return;
                if (n == 0) return;
                seen += n;
            }
        }
    };
    const fresh = try sys.socketPair();
    defer sys.close(fresh[0]);
    defer sys.close(fresh[1]);
    try sys.setNonBlocking(fresh[0]);
    const drain = try std.Thread.spawn(.{}, Drain.run, .{ fresh[1], payload.len });
    defer drain.join();
    try writeAllDeadline(fresh[0], payload, 5000);
}

test "a connection write to a peer that never reads meets the deadline on a blocking socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    // A blocking descriptor, as `accept` returns on Linux and as test and
    // fuzz harnesses pass in. SO_SNDTIMEO (2 s) turns a regression into a
    // late failure instead of a hang.
    const sockets = try sys.socketPair();
    defer sys.close(sockets[1]);
    try std.testing.expect(setSocketSendTimeout(sockets[0]));
    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    defer connection.release();
    try std.testing.expect(sys.isNonBlocking(connection.fd));

    const payload = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const start = sys.monotonicMs();
    try std.testing.expectError(error.WriteTimeout, writeAllDeadline(connection.fd, payload, 300));
    try std.testing.expect(sys.monotonicMs() - start < 1500);
}

test "a failed connection write closes the connection" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = try sys.socketPair();
    sys.close(sockets[1]);
    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    defer connection.release();

    try std.testing.expectError(error.BrokenPipe, connection.write("hello\n"));
    try std.testing.expect(connection.isClosed());
    try std.testing.expectError(error.ConnectionClosed, connection.write("again\n"));
    try std.testing.expectError(error.ConnectionClosed, connection.enqueueBroadcast("event\n"));
}

// -- D1: scoped pane_output routing ------------------------------------------

test "pane_output reaches only attached or subscribed connections; lifecycle events reach all" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);

    var attached = try QueueProbe.init(&server);
    defer attached.deinit();
    var wildcard = try QueueProbe.init(&server);
    defer wildcard.deinit();
    var other_pane = try QueueProbe.init(&server);
    defer other_pane.deinit();
    var plain = try QueueProbe.init(&server);
    defer plain.deinit();

    try attached.connection.trackMuxClient("client-1", "pane-1");
    try wildcard.connection.setSubscriptions(true, &.{});
    try other_pane.connection.setSubscriptions(false, &.{"pane-2"});

    emitOutput(&server, "pane-1", "hello", 10);
    const output_needles = [_][]const u8{ "\"method\":\"pane_output\"", "\"pane_id\":\"pane-1\"", "\"offset\":10", "\"generation\":3", "aGVsbG8=" };
    try attached.expectNext(&output_needles);
    try wildcard.expectNext(&output_needles);
    try other_pane.expectEmpty();
    try plain.expectEmpty();

    emitOutput(&server, "pane-2", "x", 0);
    try attached.expectEmpty();
    try wildcard.expectNext(&.{"\"pane_id\":\"pane-2\""});
    try other_pane.expectNext(&.{"\"pane_id\":\"pane-2\""});
    try plain.expectEmpty();

    // Lifecycle events stay global.
    Server.handleNativeEvent(&server, .{ .pane_bell = .{ .pane_id = "pane-1", .last_bell_ms = 5, .generation = 3 } });
    Server.handleNativeEvent(&server, .{ .session_exited = .{ .session_id = "pane-1", .pid = 1, .exit_code = 0, .generation = 3 } });
    inline for (.{ &attached, &wildcard, &other_pane, &plain }) |probe| {
        try probe.expectNext(&.{"\"method\":\"pane_bell\""});
        try probe.expectNext(&.{ "\"method\":\"session_exited\"", "\"generation\":3" });
        try probe.expectEmpty();
    }

    // Routing follows a switched client and stops after detach.
    try std.testing.expect(try attached.connection.switchMuxClientPane("client-1", "pane-2"));
    emitOutput(&server, "pane-1", "y", 15);
    try attached.expectEmpty();
    emitOutput(&server, "pane-2", "z", 1);
    try attached.expectNext(&.{"\"pane_id\":\"pane-2\""});
    try std.testing.expect(attached.connection.untrackMuxClient("client-1"));
    emitOutput(&server, "pane-2", "w", 2);
    try attached.expectEmpty();

    // Replacing a subscription with an empty list unsubscribes.
    try wildcard.connection.setSubscriptions(false, &.{});
    while (wildcard.take()) |frame| std.testing.allocator.free(frame);
    emitOutput(&server, "pane-1", "q", 16);
    try wildcard.expectEmpty();
}

test "every native pane_activity edge is forwarded; pane_output is not an activity notification" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var probe = try QueueProbe.init(&server);
    defer probe.deinit();

    // The native session decides the idle-to-active edge; the server adds no
    // second throttle, so two edges are two notifications.
    Server.handleNativeEvent(&server, .{ .pane_activity = .{ .pane_id = "busy", .last_activity_ms = 100, .generation = 2 } });
    try probe.expectNext(&.{ "\"method\":\"pane_activity\"", "\"pane_id\":\"busy\"", "\"last_activity_ms\":100", "\"generation\":2" });
    Server.handleNativeEvent(&server, .{ .pane_activity = .{ .pane_id = "busy", .last_activity_ms = 1200, .generation = 2 } });
    try probe.expectNext(&.{ "\"pane_id\":\"busy\"", "\"last_activity_ms\":1200" });

    // Output chunks reach only subscribers and never become activity events.
    var chunk: u64 = 0;
    while (chunk < 100) : (chunk += 1) {
        Server.handleNativeEvent(&server, .{ .pane_output = .{ .pane_id = "busy", .data = "x", .offset = chunk, .generation = 2 } });
    }
    try probe.expectEmpty();
}

test "a flooded slow subscriber gets pane_output_dropped and stays connected; quiet clients are untouched" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);

    var slow = try QueueProbe.init(&server);
    defer slow.deinit();
    var quiet = try QueueProbe.init(&server);
    defer quiet.deinit();
    var control = try QueueProbe.init(&server);
    defer control.deinit();

    try slow.connection.trackMuxClient("client-noisy", "noisy");
    try quiet.connection.trackMuxClient("client-quiet", "quiet");

    // 3 MiB of output for the noisy pane; nobody drains `slow`.
    const chunk = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'y');
    const chunks: u64 = 384;
    var index: u64 = 0;
    while (index < chunks) : (index += 1) emitOutput(&server, "noisy", chunk, index * chunk.len);

    // A lifecycle event after the flood still reaches everyone.
    Server.handleNativeEvent(&server, .{ .pane_bell = .{ .pane_id = "noisy", .last_bell_ms = 9, .generation = 3 } });

    try std.testing.expect(!slow.connection.isClosed());
    try std.testing.expect(!quiet.connection.isClosed());
    try std.testing.expect(!control.connection.isClosed());
    try std.testing.expect(slow.connection.dropped_events > 0);
    try std.testing.expectEqual(@as(u64, 0), quiet.connection.dropped_events);
    try std.testing.expectEqual(@as(u64, 0), control.connection.dropped_events);
    try std.testing.expect(slow.connection.queued_output_bytes <= broadcast_queue_max_bytes);

    // The quiet-pane client and the control connection saw only the bell.
    try quiet.expectNext(&.{"\"method\":\"pane_bell\""});
    try quiet.expectEmpty();
    try control.expectNext(&.{"\"method\":\"pane_bell\""});
    try control.expectEmpty();

    // The slow client is told exactly what it lost, before any later output.
    const notice = slow.take() orelse return error.NothingQueued;
    defer std.testing.allocator.free(notice);
    var parsed = try parseJson(notice);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(protocol.pane_output_dropped_method, parsed.value.object.get("method").?.string);
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("noisy", params.get("pane_id").?.string);
    const dropped_bytes: u64 = @intCast(params.get("dropped_bytes").?.integer);
    const resume_offset: u64 = @intCast(params.get("resume_offset").?.integer);
    try std.testing.expectEqual(slow.connection.dropped_events * chunk.len, dropped_bytes);
    try std.testing.expectEqual(dropped_bytes, resume_offset);

    // Everything still queued continues the stream from the resume offset
    // with no gap, and the bell kept its place among the control frames.
    var expected_offset = resume_offset;
    var saw_bell = false;
    while (slow.take()) |frame| {
        defer std.testing.allocator.free(frame);
        var event = try parseJson(frame);
        defer event.deinit();
        const method = event.value.object.get("method").?.string;
        if (std.mem.eql(u8, method, "pane_bell")) {
            saw_bell = true;
            continue;
        }
        try std.testing.expectEqualStrings("pane_output", method);
        const offset: u64 = @intCast(event.value.object.get("params").?.object.get("offset").?.integer);
        try std.testing.expectEqual(expected_offset, offset);
        expected_offset += chunk.len;
    }
    try std.testing.expect(saw_bell);
    try std.testing.expectEqual(chunks * chunk.len, expected_offset);
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

test "one oversized event is dropped without disconnecting anyone" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var first = try QueueProbe.init(&server);
    defer first.deinit();
    var second = try QueueProbe.init(&server);
    defer second.deinit();

    const huge = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    @memset(huge, 'h');
    server.broadcastControl(huge);

    try std.testing.expectEqual(@as(u64, 1), server.dropped_events.load(.monotonic));
    inline for (.{ &first, &second }) |probe| {
        try std.testing.expect(!probe.connection.isClosed());
        try probe.expectEmpty();
    }

    // A backlogged control queue closes only that connection.
    const chunk = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'c');
    var queued: usize = 0;
    while (queued < control_queue_max_bytes) : (queued += chunk.len) try first.connection.enqueueBroadcast(chunk);
    server.broadcastNotification(protocol.pane_bell_method, protocol.PaneBellParams{ .pane_id = "p", .last_bell_ms = 1 });
    try std.testing.expect(first.connection.isClosed());
    try std.testing.expect(!second.connection.isClosed());
    try second.expectNext(&.{"\"method\":\"pane_bell\""});
}

// -- D2: error codes and notifications -----------------------------------------

test "handler errors carry the table code, the stable name, and data.kind" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    {
        try client.send("not-json\n");
        var parsed = try client.nextLine();
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("id").? == .null);
        try expectRpcError(&parsed, -32700, "parse", "ParseError");
    }
    {
        try client.send("{\"id\":1,\"method\":7}\n");
        var parsed = try client.nextLine();
        defer parsed.deinit();
        try expectRpcError(&parsed, -32600, "invalid_request", "InvalidRequest");
    }

    const Case = struct { request: []const u8, code: i64, kind: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .request = "{\"id\":2,\"method\":\"missing.method\",\"params\":{}}\n", .code = -32601, .kind = "method_not_found", .message = "MethodNotFound" },
        .{ .request = "{\"id\":3,\"method\":\"session.info\",\"params\":{}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":4,\"method\":\"client.detach\",\"params\":{\"clientId\":\"client-missing\"}}\n", .code = -32000, .kind = "not_found", .message = "ClientNotFound" },
        .{ .request = "{\"id\":5,\"method\":\"session.info\",\"params\":{\"sessionId\":\"nope\"}}\n", .code = -32000, .kind = "not_found", .message = "SessionNotFound" },
        .{ .request = "{\"id\":6,\"method\":\"session.create\",\"params\":[1,2]}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":7,\"method\":\"session.create\",\"params\":{\"rows\":0}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidDimensions" },
        .{ .request = "{\"id\":8,\"method\":\"session.create\",\"params\":{\"env\":{\"A\":1}}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":9,\"method\":\"pane.split\",\"params\":{\"paneId\":\"x\",\"axis\":\"diagonal\"}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidAxis" },
        .{ .request = "{\"id\":10,\"method\":\"session.terminate\",\"params\":{\"sessionId\":\"nope\"}}\n", .code = -32000, .kind = "not_found", .message = "SessionNotFound" },
        .{ .request = "{\"id\":11,\"method\":\"session.send\",\"params\":{\"sessionId\":\"nope\",\"dataBase64\":7}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":12,\"method\":\"events.subscribe\",\"params\":{}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":13,\"method\":\"events.subscribe\",\"params\":{\"panes\":[1]}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":14,\"method\":\"client.attach\",\"params\":{\"paneId\":\"nope\"}}\n", .code = -32000, .kind = "not_found", .message = "PaneNotFound" },
        .{ .request = "{\"id\":15,\"method\":\"client.attach\",\"params\":{\"paneId\":\"nope\",\"createIfMissing\":true}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
        .{ .request = "{\"id\":16,\"method\":\"pane.respawn\",\"params\":{\"paneId\":\"nope\",\"kill\":\"yes\"}}\n", .code = -32602, .kind = "invalid_params", .message = "InvalidParams" },
    };
    for (cases, 2..) |case, id| {
        try client.send(case.request);
        var parsed = try client.response(@intCast(id));
        defer parsed.deinit();
        expectRpcError(&parsed, case.code, case.kind, case.message) catch |err| {
            std.debug.print("request {s}", .{case.request});
            return err;
        };
    }

    // The connection survived every error.
    try client.send("{\"id\":99,\"method\":\"daemon.ping\"}\n");
    var ping = try client.response(99);
    defer ping.deinit();
    const result = try resultOf(&ping);
    try std.testing.expectEqualStrings(protocol.version, result.get("version").?.string);
    try std.testing.expect(result.get("droppedEvents").? == .integer);
    try std.testing.expect(result.get("rejectedConnections").? == .integer);
    try std.testing.expect(result.get("livePanes").? == .integer);
}

test "a request without an id gets no response for any outcome" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    // Success, unknown method, invalid params, domain error, snapshot result.
    try client.send(
        "{\"method\":\"daemon.ping\"}\n" ++
            "{\"method\":\"missing.method\"}\n" ++
            "{\"method\":\"session.info\",\"params\":{}}\n" ++
            "{\"method\":\"session.info\",\"params\":{\"sessionId\":\"nope\"}}\n" ++
            "{\"method\":\"mux.snapshot\"}\n" ++
            "{\"method\":\"session.list\"}\n" ++
            "{\"method\":\"events.subscribe\",\"params\":{\"panes\":[\"*\"]}}\n" ++
            "{\"id\":42,\"method\":\"daemon.ping\"}\n",
    );
    var parsed = try client.nextLine();
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("id").?.integer);
    try std.testing.expect(parsed.value.object.get("result") != null);

    // The notifications still ran: the subscription took effect.
    try std.testing.expectEqual(@as(usize, 1), server.connections.items.len);
    try std.testing.expect(server.connections.items[0].wantsPaneOutput("any-pane"));

    // An explicit null id is a request and is answered.
    try client.send("{\"id\":null,\"method\":\"missing.method\"}\n");
    var answered = try client.nextLine();
    defer answered.deinit();
    try expectRpcError(&answered, -32601, "method_not_found", "MethodNotFound");
}

test "an oversized request gets MessageTooLarge and the connection closes" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    const oversized = try std.testing.allocator.alloc(u8, max_request_bytes + 2);
    defer std.testing.allocator.free(oversized);
    @memset(oversized[0 .. oversized.len - 1], 'x');
    oversized[oversized.len - 1] = '\n';
    try client.send(oversized);

    var parsed = try client.nextLine();
    defer parsed.deinit();
    try expectRpcError(&parsed, -32600, "invalid_request", "MessageTooLarge");
    try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, client.fd, 2000));
}

test "a frame cut off before its newline is never dispatched" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);

    try client.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\"}}");
    _ = std.c.shutdown(client.fd, @intCast(posix.SHUT.WR));
    try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, client.fd, 2000));
    client.stop();

    try std.testing.expectEqual(@as(usize, 0), server.manager.counts().sessions);
}

test "daemon.shutdown replies, stops new work, and leaves teardown to the server" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();
    var bystander = try TestClient.start(&server);
    defer bystander.stop();

    // The bystander is live before the shutdown request.
    try bystander.send("{\"id\":1,\"method\":\"daemon.ping\"}\n");
    var ping = try bystander.response(1);
    ping.deinit();

    try client.send("{\"id\":6,\"method\":\"daemon.shutdown\"}\n");
    var reply = try client.response(6);
    defer reply.deinit();
    try std.testing.expect((try resultOf(&reply)).get("ok").?.bool);
    // The worker that served the request returns instead of waiting on itself.
    try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, client.fd, 2000));
    try std.testing.expect(!server.running.load(.seq_cst));

    // A concurrent mutation after shutdown began is refused: the connection
    // closes and nothing is created.
    try bystander.send("{\"id\":2,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\"}}\n");
    try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, bystander.fd, 2000));
    try std.testing.expectEqual(@as(usize, 0), server.manager.counts().sessions);
}

// -- RPC wiring against real panes ---------------------------------------------

test "client.attach creates when missing and returns an offset-aligned replay" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    fuzz_hooks.enableEvents(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"client.attach\",\"params\":{\"paneId\":\"work\",\"rows\":30,\"cols\":100," ++
        "\"createIfMissing\":{\"title\":\"work\",\"shell\":\"/bin/sh\",\"command\":\"stty -echo; printf ready; exec cat\"}}}\n");
    var first = try client.response(1);
    defer first.deinit();
    const created = try resultOf(&first);
    try std.testing.expect(created.get("created").?.bool);
    try std.testing.expect(!created.get("exited").?.bool);
    try std.testing.expect(created.get("exitCode").? == .null);
    try std.testing.expect(created.get("signal").? == .null);
    try std.testing.expectEqual(@as(i64, 0), created.get("generation").?.integer);
    try std.testing.expectEqual(@as(i64, 30), created.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 100), created.get("cols").?.integer);
    try std.testing.expect(created.get("clientId").? == .string);
    const pane_id = try allocator.dupe(u8, created.get("paneId").?.string);
    defer allocator.free(pane_id);

    // The stream the client reassembles: replay, then every pane_output at
    // or after replayEndOffset. It must be gap-free and duplicate-free.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    {
        const start: u64 = @intCast(created.get("replayStartOffset").?.integer);
        const end: u64 = @intCast(created.get("replayEndOffset").?.integer);
        const replay = try base64Decode(allocator, created.get("replayBase64").?.string);
        defer allocator.free(replay);
        try std.testing.expectEqual(end - start, @as(u64, replay.len));
        try std.testing.expectEqual(@as(u64, 0), start);
        try stream.appendSlice(allocator, replay);
    }

    // Wait for the shell's own output first, so the marker below is not
    // echoed by the terminal before `stty -echo` runs. A notification (no
    // id) carries the input: it runs and gets no reply.
    const needles = [_][]const u8{ "ready", "marker-one" };
    for (needles, 0..) |needle, step| {
        if (step == 1) {
            try client.sendFmt("{{\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"marker-one\",\"enter\":true}}}}\n", .{pane_id});
        }
        while (std.mem.indexOf(u8, stream.items, needle) == null) {
            var event = try client.notification("pane_output");
            defer event.deinit();
            const params = event.value.object.get("params").?.object;
            try std.testing.expectEqualStrings(pane_id, params.get("pane_id").?.string);
            const offset: u64 = @intCast(params.get("offset").?.integer);
            const data = try base64Decode(allocator, params.get("data_base64").?.string);
            defer allocator.free(data);
            // An event the replay already covers is a duplicate the client
            // skips; every other event starts exactly where the stream ends.
            if (offset + data.len <= stream.items.len) continue;
            try std.testing.expectEqual(@as(u64, stream.items.len), offset);
            try stream.appendSlice(allocator, data);
        }
    }

    // A second attach by name finds the session and replays what the first
    // client has already seen, ending at the same offset.
    try client.send("{\"id\":2,\"method\":\"client.attach\",\"params\":{\"paneId\":\"work\",\"createIfMissing\":{\"title\":\"work\"}}}\n");
    var second = try client.response(2);
    defer second.deinit();
    const reattached = try resultOf(&second);
    try std.testing.expect(!reattached.get("created").?.bool);
    try std.testing.expectEqualStrings(pane_id, reattached.get("paneId").?.string);
    const replay_end: u64 = @intCast(reattached.get("replayEndOffset").?.integer);
    try std.testing.expect(replay_end >= stream.items.len);
    const replay = try base64Decode(allocator, reattached.get("replayBase64").?.string);
    defer allocator.free(replay);
    try std.testing.expect(std.mem.indexOf(u8, replay, "marker-one") != null);
    try std.testing.expectEqual(@as(usize, 1), server.manager.counts().sessions);
}

test "events.subscribe enables pane_output for an unattached observer only" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    fuzz_hooks.enableEvents(&server);
    var owner = try TestClient.start(&server);
    defer owner.stop();
    var subscriber = try TestClient.start(&server);
    defer subscriber.stop();
    var bystander = try TestClient.start(&server);
    defer bystander.stop();

    try owner.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"title\":\"feed\",\"shell\":\"/bin/sh\",\"command\":\"stty -echo; exec cat\"}}\n");
    var created = try owner.response(1);
    defer created.deinit();
    const info = try resultOf(&created);
    // Legacy fields and the compact identifiers are both present.
    try std.testing.expect(info.get("pid").? == .integer);
    try std.testing.expect(info.get("sessionId").? == .string);
    try std.testing.expect(info.get("windowId").? == .string);
    try std.testing.expectEqual(@as(i64, 0), info.get("generation").?.integer);
    try std.testing.expectEqualStrings(info.get("id").?.string, info.get("paneId").?.string);
    const pane_id = try allocator.dupe(u8, info.get("paneId").?.string);
    defer allocator.free(pane_id);

    // Subscribe by session name; the server resolves it to the pane id.
    try subscriber.send("{\"id\":1,\"method\":\"events.subscribe\",\"params\":{\"panes\":[\"feed\"]}}\n");
    var subscribed = try subscriber.response(1);
    defer subscribed.deinit();
    const sub_result = try resultOf(&subscribed);
    try std.testing.expect(sub_result.get("ok").?.bool);
    try std.testing.expectEqualStrings(pane_id, sub_result.get("panes").?.array.items[0].string);

    // The bystander is registered (it has been answered) but unsubscribed.
    try bystander.send("{\"id\":1,\"method\":\"daemon.ping\"}\n");
    var ping = try bystander.response(1);
    ping.deinit();

    try owner.sendFmt("{{\"id\":2,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"scoped-output\",\"enter\":true}}}}\n", .{pane_id});
    var sent = try owner.response(2);
    sent.deinit();

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    while (std.mem.indexOf(u8, seen.items, "scoped-output") == null) {
        var event = try subscriber.notification("pane_output");
        defer event.deinit();
        const params = event.value.object.get("params").?.object;
        try std.testing.expectEqualStrings(pane_id, params.get("pane_id").?.string);
        const data = try base64Decode(allocator, params.get("data_base64").?.string);
        defer allocator.free(data);
        try seen.appendSlice(allocator, data);
    }

    // A global lifecycle event marks the end of the window: neither the
    // bystander nor the unattached owner received any pane_output before it.
    try owner.sendFmt("{{\"id\":3,\"method\":\"pane.respawn\",\"params\":{{\"paneId\":\"{s}\",\"kill\":true}}}}\n", .{pane_id});
    for ([_]*TestClient{ &bystander, &owner }) |observer| {
        while (true) {
            var line = try observer.nextLine();
            defer line.deinit();
            const method = line.value.object.get("method") orelse continue;
            try std.testing.expect(!std.mem.eql(u8, method.string, "pane_output"));
            if (std.mem.eql(u8, method.string, protocol.pane_respawned_method)) break;
        }
    }
}

test "pane.respawn needs kill for a running pane and announces the new generation" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    fuzz_hooks.enableEvents(&server);
    var client = try TestClient.start(&server);
    defer client.stop();
    var observer = try TestClient.start(&server);
    defer observer.stop();

    try client.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}\n");
    var created = try client.response(1);
    defer created.deinit();
    const pane_id = try allocator.dupe(u8, (try resultOf(&created)).get("paneId").?.string);
    defer allocator.free(pane_id);

    try observer.send("{\"id\":1,\"method\":\"daemon.ping\"}\n");
    var ping = try observer.response(1);
    ping.deinit();

    try client.sendFmt("{{\"id\":2,\"method\":\"pane.respawn\",\"params\":{{\"paneId\":\"{s}\"}}}}\n", .{pane_id});
    var refused = try client.response(2);
    defer refused.deinit();
    try expectRpcError(&refused, -32000, "conflict", "PaneRunning");

    try client.sendFmt("{{\"id\":3,\"method\":\"pane.respawn\",\"params\":{{\"paneId\":\"{s}\",\"kill\":true}}}}\n", .{pane_id});
    var respawned = try client.response(3);
    defer respawned.deinit();
    try std.testing.expect((try resultOf(&respawned)).get("sessions") != null);

    var event = try observer.notification(protocol.pane_respawned_method);
    defer event.deinit();
    const params = event.value.object.get("params").?.object;
    try std.testing.expectEqualStrings(pane_id, params.get("pane_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), params.get("generation").?.integer);
    try std.testing.expect(params.get("pid").?.integer > 0);
}

test "window.new and pane.split return compact identifiers" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}\n");
    var created = try client.response(1);
    defer created.deinit();
    const info = try resultOf(&created);
    const session_id = try allocator.dupe(u8, info.get("sessionId").?.string);
    defer allocator.free(session_id);
    const pane_id = try allocator.dupe(u8, info.get("paneId").?.string);
    defer allocator.free(pane_id);

    try client.sendFmt("{{\"id\":2,\"method\":\"window.new\",\"params\":{{\"sessionId\":\"{s}\",\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}}}\n", .{session_id});
    var window = try client.response(2);
    defer window.deinit();
    const window_result = try resultOf(&window);
    try std.testing.expectEqualStrings(session_id, window_result.get("sessionId").?.string);
    try std.testing.expect(window_result.get("windowId").? == .string);
    try std.testing.expect(window_result.get("paneId").? == .string);
    try std.testing.expectEqual(@as(i64, 0), window_result.get("generation").?.integer);
    try std.testing.expect(window_result.get("sessions") == null);

    try client.sendFmt("{{\"id\":3,\"method\":\"pane.split\",\"params\":{{\"paneId\":\"{s}\",\"axis\":\"h\",\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}}}\n", .{pane_id});
    var split = try client.response(3);
    defer split.deinit();
    const split_result = try resultOf(&split);
    try std.testing.expectEqualStrings(session_id, split_result.get("sessionId").?.string);
    try std.testing.expect(!std.mem.eql(u8, pane_id, split_result.get("paneId").?.string));
    try std.testing.expect(split_result.get("sessions") == null);
    try std.testing.expectEqual(@as(usize, 3), server.manager.counts().panes);
}

test "detaching another connection's client notifies its owner" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var owner = try TestClient.start(&server);
    defer owner.stop();
    var other = try TestClient.start(&server);
    defer other.stop();

    try owner.send("{\"id\":1,\"method\":\"client.attach\",\"params\":{\"paneId\":\"shared\"," ++
        "\"createIfMissing\":{\"title\":\"shared\",\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}}\n");
    var attached = try owner.response(1);
    defer attached.deinit();
    const client_id = try allocator.dupe(u8, (try resultOf(&attached)).get("clientId").?.string);
    defer allocator.free(client_id);

    try other.sendFmt("{{\"id\":1,\"method\":\"client.detach\",\"params\":{{\"clientId\":\"{s}\"}}}}\n", .{client_id});
    var detached = try other.response(1);
    defer detached.deinit();
    try std.testing.expect((try resultOf(&detached)).get("ok").?.bool);

    var event = try owner.notification(protocol.client_detached_method);
    defer event.deinit();
    const params = event.value.object.get("params").?.object;
    try std.testing.expectEqualStrings(client_id, params.get("client_id").?.string);
    try std.testing.expectEqualStrings("remote_detach", params.get("reason").?.string);

    // The owner no longer tracks it, so nothing is detached twice.
    try other.sendFmt("{{\"id\":2,\"method\":\"client.detach\",\"params\":{{\"clientId\":\"{s}\"}}}}\n", .{client_id});
    var again = try other.response(2);
    defer again.deinit();
    try expectRpcError(&again, -32000, "not_found", "ClientNotFound");
}

test "H10: a remote switch moves the owner's route and notifies it with generation and replay" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var owner = try TestClient.start(&server);
    defer owner.stop();
    var other = try TestClient.start(&server);
    defer other.stop();

    try owner.send("{\"id\":1,\"method\":\"client.attach\",\"params\":{\"paneId\":\"one\"," ++
        "\"createIfMissing\":{\"title\":\"one\",\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}}\n");
    var attached = try owner.response(1);
    defer attached.deinit();
    const client_id = try allocator.dupe(u8, (try resultOf(&attached)).get("clientId").?.string);
    defer allocator.free(client_id);

    try other.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"title\":\"two\",\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}\n");
    var created = try other.response(1);
    defer created.deinit();
    const pane_two = try allocator.dupe(u8, (try resultOf(&created)).get("paneId").?.string);
    defer allocator.free(pane_two);

    try other.sendFmt("{{\"id\":2,\"method\":\"client.switch\",\"params\":{{\"clientId\":\"{s}\",\"paneId\":\"{s}\"}}}}\n", .{ client_id, pane_two });
    var switched = try other.response(2);
    defer switched.deinit();

    var event = try owner.notification(client_switched_method);
    defer event.deinit();
    const params = event.value.object.get("params").?.object;
    try std.testing.expectEqualStrings(client_id, params.get("client_id").?.string);
    try std.testing.expectEqualStrings(pane_two, params.get("pane_id").?.string);
    try std.testing.expectEqual(@as(i64, 0), params.get("generation").?.integer);
    try std.testing.expect(params.get("replayBase64").? == .string);
    try std.testing.expect(params.get("replayEndOffset").? == .integer);
}

test "session.capture returns lossy text and the exact bytes" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"printf 'a\\\\377b'; exec cat\"}}\n");
    var created = try client.response(1);
    defer created.deinit();
    const pane_id = try allocator.dupe(u8, (try resultOf(&created)).get("paneId").?.string);
    defer allocator.free(pane_id);

    const deadline = sys.monotonicMs() + 5000;
    var id: i64 = 2;
    while (true) : (id += 1) {
        try client.sendFmt("{{\"id\":{},\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":50}}}}\n", .{ id, pane_id });
        var captured = try client.response(id);
        defer captured.deinit();
        const result = try resultOf(&captured);
        const exact = try base64Decode(allocator, result.get("textBase64").?.string);
        defer allocator.free(exact);
        if (std.mem.indexOf(u8, exact, "a\xffb") != null) {
            // `text` is valid UTF-8 JSON with the bad byte replaced.
            try std.testing.expect(std.mem.indexOf(u8, result.get("text").?.string, "a\u{FFFD}b") != null);
            break;
        }
        if (sys.monotonicMs() >= deadline) return error.CaptureNeverShowedOutput;
        sleepMs(20);
    }
}

// -- C2: shutdown with a late-registering connection ----------------------------

const LateRegistration = struct {
    var calls = std.atomic.Value(usize).init(0);
    var entered = std.atomic.Value(bool).init(false);
    var released = std.atomic.Value(bool).init(false);
    var stop = std.atomic.Value(bool).init(false);

    fn reset() void {
        calls.store(0, .seq_cst);
        entered.store(false, .seq_cst);
        released.store(false, .seq_cst);
        stop.store(false, .seq_cst);
    }

    /// Parks the first worker between accept and registration.
    fn hook(server: *Server) void {
        if (calls.fetchAdd(1, .seq_cst) != 0) return;
        entered.store(true, .seq_cst);
        while (!released.load(.seq_cst)) server.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }

    fn probe() bool {
        return stop.load(.seq_cst);
    }

    const Runner = struct {
        server: *Server,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *Runner) void {
            self.server.run() catch {};
            self.done.store(true, .seq_cst);
        }
    };

    const Trigger = enum { probe, rpc, idle };

    /// Accept a connection, park its worker before it registers, trigger
    /// shutdown, then release the worker. `run` must return promptly, and
    /// the late connection must be closed rather than served.
    fn expectShutdownCompletes(trigger: Trigger) !void {
        if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
        const allocator = std.testing.allocator;
        reset();

        const socket_path = try tempPath(allocator, "zmx-late-register");
        defer allocator.free(socket_path);
        defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
        try requireUnixSocketBind(socket_path);

        var server = try Server.init(allocator, test_io, socket_path, if (trigger == .idle) 1 else 0);
        defer server.deinit();
        server.before_register_hook = hook;
        server.shutdown_probe = probe;

        var runner = Runner{ .server = &server };
        const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
        defer {
            released.store(true, .seq_cst);
            thread.join();
        }

        // Closed before the join above, so a regression fails instead of
        // hanging the test run.
        const late = try sys.connectUnix(socket_path);
        defer sys.close(late);
        try std.testing.expect(waitForFlag(&entered, 3000));

        switch (trigger) {
            .probe => stop.store(true, .seq_cst),
            .rpc => {
                const admin = try sys.connectUnix(socket_path);
                defer sys.close(admin);
                try sys.writeAll(admin, "{\"id\":1,\"method\":\"daemon.shutdown\"}\n");
                const reply = try readLineTimeout(allocator, admin, 3000);
                defer allocator.free(reply);
                try std.testing.expect(std.mem.indexOf(u8, reply, "\"ok\":true") != null);
            },
            .idle => sleepMs(2100),
        }

        // The accept loop has stopped and closed every registered connection;
        // it is waiting for the parked worker.
        sleepMs(700);
        try std.testing.expect(!runner.done.load(.seq_cst));
        try std.testing.expect(!server.running.load(.seq_cst));

        released.store(true, .seq_cst);
        try std.testing.expect(waitForFlag(&runner.done, 1000));
        try std.testing.expectEqual(@as(usize, 0), server.active_connections.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 0), server.connections.items.len);
        try std.testing.expectError(error.EndOfStream, readLineTimeout(allocator, late, 1000));
    }
};

test "shutdown probe: a connection that registers late cannot hang run" {
    try LateRegistration.expectShutdownCompletes(.probe);
}

test "daemon.shutdown: a connection that registers late cannot hang run" {
    try LateRegistration.expectShutdownCompletes(.rpc);
}

test "idle exit: a connection that registers late cannot hang run" {
    try LateRegistration.expectShutdownCompletes(.idle);
}

test "a stopping server refuses registration under the same mutex that closes connections" {
    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);

    var before = try QueueProbe.init(&server);
    defer before.deinit();
    server.beginStop();
    try std.testing.expect(!server.running.load(.seq_cst));
    try std.testing.expect(before.connection.isClosed());
    try std.testing.expectEqual(@as(usize, 0), server.connections.items.len);

    const sockets = try sys.socketPair();
    defer sys.close(sockets[1]);
    const late = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    defer late.release();
    try std.testing.expect(!server.registerConnection(late));
    try std.testing.expectEqual(@as(usize, 0), server.connections.items.len);
    // Refused, not adopted: the caller still holds the only reference.
    try std.testing.expectEqual(@as(u32, 1), late.ref_count.load(.seq_cst));
}

test "run shuts down in order and a second shutdown is a no-op" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    LateRegistration.reset();

    const socket_path = try tempPath(allocator, "zmx-run-shutdown");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();
    server.shutdown_probe = LateRegistration.probe;
    var handle = try server.manager.createSessionPane(.{ .shell = "/bin/sh", .command = "exec cat" });
    handle.deinit();

    var runner = LateRegistration.Runner{ .server = &server };
    const thread = try std.Thread.spawn(.{}, LateRegistration.Runner.run, .{&runner});

    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
    try sys.writeAll(client, "{\"id\":1,\"method\":\"daemon.ping\"}\n");
    const reply = try readLineTimeout(allocator, client, 3000);
    allocator.free(reply);

    LateRegistration.stop.store(true, .seq_cst);
    try std.testing.expect(waitForFlag(&runner.done, 5000));
    thread.join();

    // Connections closed, panes terminated, event sink cleared.
    try std.testing.expectError(error.EndOfStream, readLineTimeout(allocator, client, 1000));
    try std.testing.expectEqual(@as(usize, 0), server.manager.counts().sessions);
    try std.testing.expect(server.manager.event_sink == null);
    server.shutdown();
}

/// `accept` that reports a full descriptor table while the server still
/// holds its spare descriptor.
const ExhaustedAccept = struct {
    var server: ?*Server = null;
    var refused: std.atomic.Value(usize) = .init(0);

    fn accept(listener_fd: posix.fd_t) sys.AcceptError!posix.fd_t {
        if (server.?.spare_fd >= 0) {
            _ = refused.fetchAdd(1, .seq_cst);
            return error.ProcessFdQuotaExceeded;
        }
        return sys.accept(listener_fd);
    }
};

test "H21: at descriptor exhaustion the spare descriptor admits a control connection" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    LateRegistration.reset();

    const socket_path = try tempPath(allocator, "zmx-spare-fd");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();
    server.shutdown_probe = LateRegistration.probe;
    ExhaustedAccept.server = &server;
    ExhaustedAccept.refused.store(0, .seq_cst);
    server.accept_fn = ExhaustedAccept.accept;

    var runner = LateRegistration.Runner{ .server = &server };
    const thread = try std.Thread.spawn(.{}, LateRegistration.Runner.run, .{&runner});

    // Two clients in a row: each first accept is refused, the spare is given
    // up, the retry succeeds, and the spare is re-armed for the next one.
    for (0..2) |round| {
        const client = try sys.connectUnix(socket_path);
        defer sys.close(client);
        try sys.writeAll(client, "{\"id\":1,\"method\":\"daemon.ping\"}\n");
        const reply = try readLineTimeout(allocator, client, 3000);
        defer allocator.free(reply);
        try std.testing.expect(std.mem.indexOf(u8, reply, "\"result\"") != null);
        try std.testing.expectEqual(@as(u64, round + 1), server.spare_fd_admissions.load(.monotonic));
    }
    try std.testing.expectEqual(@as(usize, 2), ExhaustedAccept.refused.load(.seq_cst));

    LateRegistration.stop.store(true, .seq_cst);
    try std.testing.expect(waitForFlag(&runner.done, 5000));
    thread.join();
}

test "M40: a create whose reply cannot be built is undone; a reply lost to a closed peer is kept" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);

    var kept = try server.manager.createSessionPane(.{ .title = "kept", .shell = "/bin/sh", .command = "exec cat" });
    defer kept.deinit();
    try std.testing.expectEqual(@as(anyerror, error.ConnectionClosed), server.undoCreate(&kept, error.ConnectionClosed));
    try std.testing.expectEqual(@as(usize, 1), server.manager.counts().panes);

    var undone = try server.manager.splitPane(kept.pane_id, .vertical, .{ .shell = "/bin/sh", .command = "exec cat" });
    defer undone.deinit();
    try std.testing.expectEqual(@as(usize, 2), server.manager.counts().panes);
    try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), server.undoCreate(&undone, error.OutOfMemory));
    try std.testing.expectEqual(@as(usize, 1), server.manager.counts().panes);
}

// -- Socket path safety ----------------------------------------------------------

test "server init rejects paths bind can never accept, with no side effects" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SocketPathNotAbsolute, Server.init(allocator, test_io, "zmx-relative.sock", 0));
    try std.testing.expectError(error.SocketPathNotAbsolute, Server.init(allocator, test_io, "./zmx-relative.sock", 0));
    try std.testing.expectError(error.SocketPathNotAbsolute, Server.init(allocator, test_io, "sub/zmx-relative.sock", 0));
    try std.testing.expectError(error.EmptySocketPath, Server.init(allocator, test_io, "", 0));
    try std.testing.expectError(error.SocketPathContainsNul, Server.init(allocator, test_io, "/tmp/zmx\x00.sock", 0));
    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, "/tmp/zmx-dir-like/", 0));

    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "zmx-relative.sock", false));
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "sub", false));
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "/tmp/zmx-dir-like", false));
}

test "server init never unlinks a regular file at the socket path" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const path = try tempPath(allocator, "zmx-notes");
    defer allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};

    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, path, .{});
        defer file.close(test_io);
        try file.writeStreamingAll(test_io, "keep these notes\n");
    }

    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, path, 0));

    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, path, allocator, .limited(64));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("keep these notes\n", text);
    try std.testing.expectEqual(@as(u32, posix.S.IFREG), (try socketPathStat(path)).kind());
}

test "server init never unlinks a directory or follows a symlink at the socket path" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const dir_path = try tempPath(allocator, "zmx-is-dir");
    defer allocator.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir_path) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir_path, .default_dir);
    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, dir_path, 0));
    try std.testing.expect((try socketPathStat(dir_path)).isDir());

    // A symlink whose target is a stale socket: the link is not a socket, so
    // neither the link nor its target is touched.
    const target = try tempPath(allocator, "zmx-link-target");
    defer allocator.free(target);
    defer std.Io.Dir.deleteFileAbsolute(test_io, target) catch {};
    const stale = bindRawUnixListener(target) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    sys.close(stale);

    const link = try tempPath(allocator, "zmx-link");
    defer allocator.free(link);
    defer std.Io.Dir.deleteFileAbsolute(test_io, link) catch {};
    const target_z = try allocator.dupeSentinel(u8, target, 0);
    defer allocator.free(target_z);
    const link_z = try allocator.dupeSentinel(u8, link, 0);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target_z.ptr, link_z.ptr));

    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, link, 0));
    try std.testing.expectEqual(@as(u32, posix.S.IFLNK), (try socketPathStat(link)).kind());
    try std.testing.expect((try socketPathStat(target)).isSocket());
}

test "a second server cannot displace a live one" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const socket_path = try tempPath(allocator, "zmx-live-server");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();
    const before = try socketPathStat(socket_path);

    try std.testing.expectError(error.AddressInUse, Server.init(allocator, test_io, socket_path, 0));

    const after = try socketPathStat(socket_path);
    try std.testing.expect(before.sameFile(after));
    try std.testing.expectEqual(@as(usize, 1), try countMatchingEntries(std.fs.path.dirname(socket_path).?, std.fs.path.basename(socket_path)));
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "H02: publication never replaces a socket that appeared after the stale check" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const socket_path = try tempPath(allocator, "zmx-publish-race");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    // The first publisher wins; the second already passed `clearStaleSocket`
    // (simulated by calling the publication step directly).
    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();
    const before = try socketPathStat(socket_path);

    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    const parent = std.fs.path.dirname(socket_path).?;
    const dir_fd = try sys.openDirNoFollow(parent);
    defer sys.close(dir_fd);
    try std.testing.expectError(
        error.AddressInUse,
        bindPrivateSocket(test_io, listener, dir_fd, std.fs.path.basename(socket_path), socket_path),
    );

    const after = try socketPathStat(socket_path);
    try std.testing.expect(before.sameFile(after));
    const client = try sys.connectUnix(socket_path);
    sys.close(client);

    // Cleanup removes only the inode this server bound.
    server.socket_stat.ino +%= 1;
    server.unpublish();
    try std.testing.expect((try socketPathStat(socket_path)).sameFile(before));
    server.socket_stat.ino -%= 1;
    server.published = true;
}

test "H03: a sticky parent is trusted only when root or this user owns it" {
    const euid: sys.uid_t = 1000;
    const sticky = 0o41777;
    try std.testing.expect(stickyParentTrusted(.{ .dev = 0, .ino = 0, .mode = sticky, .uid = 0 }, euid));
    try std.testing.expect(stickyParentTrusted(.{ .dev = 0, .ino = 0, .mode = sticky, .uid = euid }, euid));
    try std.testing.expect(!stickyParentTrusted(.{ .dev = 0, .ino = 0, .mode = sticky, .uid = 1234 }, euid));
}

test "M13: startup and restart succeed under umask 0777" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    if (sys.geteuid() == 0) return error.SkipZigTest; // root ignores mode bits
    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-umask777");
    defer allocator.free(parent);
    sys.close(try sys.ensurePrivateDir(parent));
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    const socket_path = try std.fs.path.join(allocator, &.{ parent, "s.sock" });
    defer allocator.free(socket_path);

    const original_umask = std.c.umask(0o777);
    defer _ = std.c.umask(original_umask);

    for (0..2) |_| {
        var server = try Server.init(allocator, test_io, socket_path, 0);
        const stat = try socketPathStat(socket_path);
        try std.testing.expect(stat.isSocket());
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
        server.deinit();
    }
}

test "self-created socket parent is validated as private 0700" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-created-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    // The parent does not exist yet, so zmux owns its creation: Server.init
    // must bring it up as a private 0700 directory owned by the current uid.
    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    server.deinit();
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
}

test "existing socket parent permissions are left unchanged" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-existing-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    // A pre-existing self-owned parent of an explicit socket path is accepted
    // as-is and left at its original mode (here 0755), never chmod'd.
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    server.deinit();
    try std.testing.expectEqual(@as(u32, 0o755), try dirMode(parent));
}

test "a user-selected parent that others can write to is refused unless sticky" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-writable-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    for ([_]std.c.mode_t{ 0o777, 0o775, 0o757 }) |mode| {
        try chmodAbsolute(allocator, parent, mode);
        try std.testing.expectError(error.InsecureSocketDirectory, Server.init(allocator, test_io, socket_path, 0));
        try std.testing.expectEqual(@as(usize, 0), try countDirEntries(parent));
    }

    // The sticky bit (as on /tmp) makes a world-writable parent acceptable.
    try chmodAbsolute(allocator, parent, 0o1777);
    var server = try Server.init(allocator, test_io, socket_path, 0);
    server.deinit();
    try std.testing.expectEqual(@as(u32, 0o1777), try dirMode(parent));
}

const ManagedHome = struct {
    threadlocal var home: ?[]const u8 = null;

    fn get(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "HOME")) return home;
        return null;
    }
};

test "a daemon-managed parent must be private: created 0700, 0755 tightened, writable refused" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const home = try tempPath(allocator, "zmx-home");
    defer allocator.free(home);
    defer std.Io.Dir.cwd().deleteTree(test_io, home) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, home, .default_dir);
    ManagedHome.home = home;
    defer ManagedHome.home = null;

    const managed = try std.fs.path.join(allocator, &.{ home, ".smithers" });
    defer allocator.free(managed);
    const socket_path = try std.fs.path.join(allocator, &.{ managed, "sessions.sock" });
    defer allocator.free(socket_path);
    try std.testing.expect(socket_path_mod.isDefaultManaged(socket_path, ManagedHome.get));

    // Missing: created private even under a permissive umask.
    {
        const original_umask = std.c.umask(0);
        defer _ = std.c.umask(original_umask);
        const dir_fd = try openSocketParent(socket_path, ManagedHome.get);
        sys.close(dir_fd);
        try std.testing.expectEqual(@as(u32, 0o700), try dirMode(managed));
    }

    // 0755 from an older release: nobody else could write, so it is tightened.
    try chmodAbsolute(allocator, managed, 0o755);
    {
        const dir_fd = try openSocketParent(socket_path, ManagedHome.get);
        sys.close(dir_fd);
        try std.testing.expectEqual(@as(u32, 0o700), try dirMode(managed));
    }

    // Group- or other-writable: refused and left exactly as found.
    for ([_]std.c.mode_t{ 0o777, 0o770, 0o707, 0o1777 }) |mode| {
        try chmodAbsolute(allocator, managed, mode);
        try std.testing.expectError(error.InsecurePermissions, openSocketParent(socket_path, ManagedHome.get));
        try std.testing.expectEqual(@as(u32, mode), try dirMode(managed));
    }

    // A symlink standing in for the managed directory is refused.
    try chmodAbsolute(allocator, managed, 0o700);
    const moved = try std.fs.path.join(allocator, &.{ home, "real-dir" });
    defer allocator.free(moved);
    try sys.rename(managed, moved);
    const moved_z = try allocator.dupeSentinel(u8, moved, 0);
    defer allocator.free(moved_z);
    const managed_z = try allocator.dupeSentinel(u8, managed, 0);
    defer allocator.free(managed_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(moved_z.ptr, managed_z.ptr));
    if (openSocketParent(socket_path, ManagedHome.get)) |dir_fd| {
        sys.close(dir_fd);
        return error.SymlinkedManagedDirAccepted;
    } else |_| {}
}

test "self-created socket parent is 0700 under umask 0022" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-created-umask022");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    const original_umask = std.c.umask(0o022);
    defer _ = std.c.umask(original_umask);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit();

    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
    const stat = try socketPathStat(socket_path);
    try std.testing.expect(stat.isSocket());
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
}

test "new socket parent is private" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-new-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    const dir_fd = try openSocketParent(socket_path, noEnv);
    defer sys.close(dir_fd);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
    // The descriptor is the directory itself, not a path that can be swapped.
    try std.testing.expect((try sys.fstat(dir_fd)).sameFile(try sys.statAt(sys.cwd_fd, parent, false)));
}

test "server init rejects a socket path longer than sun_path before touching the filesystem" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-too-long");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    const socket_path = try paddedSocketPath(allocator, parent, max_socket_path_len + 1);
    defer allocator.free(socket_path);

    try std.testing.expectError(error.SocketPathTooLong, Server.init(allocator, test_io, socket_path, 0));
    // Rejected up front: not even the parent directory was created.
    try std.testing.expectError(error.FileNotFound, socketPathStat(parent));
}

test "max_socket_path_len matches the platform sun_path capacity" {
    const expected: usize = switch (builtin.os.tag) {
        .linux => 107,
        .macos, .ios, .tvos, .watchos, .visionos => 103,
        else => return error.SkipZigTest,
    };
    try std.testing.expectEqual(expected, max_socket_path_len);
}

test "server socket is 0600 without mutating the process umask" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-umask");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);
    // A shared (0755) parent forces the staged bind rather than the
    // private-parent shortcut.
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);
    try requireUnixSocketBind(socket_path);

    // The most permissive umask: a plain bind would create a 0777 socket, so a
    // 0600 result proves the mode does not come from the umask. umask(2) can
    // only be read by setting it, so read it back the same way afterwards.
    const permissive_umask: std.c.mode_t = 0;
    const original_umask = std.c.umask(permissive_umask);
    defer _ = std.c.umask(original_umask);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();

    const umask_after_init = std.c.umask(permissive_umask);
    try std.testing.expectEqual(permissive_umask, umask_after_init);

    const stat = try socketPathStat(socket_path);
    try std.testing.expect(stat.isSocket());
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    try std.testing.expectEqual(sys.geteuid(), stat.uid);

    // The staging directory is gone: the socket is the parent's only entry.
    try std.testing.expectEqual(@as(usize, 1), try countDirEntries(parent));

    // The published socket is already listening: a client can connect.
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "server init replaces a stale socket with a private one" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-stale-replace");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};

    const stale = bindRawUnixListener(socket_path) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    sys.close(stale);
    // Confirm the stale socket file is genuinely unreachable before replacement.
    try std.testing.expectError(error.ConnectionRefused, sys.connectUnix(socket_path));

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();

    const stat = try socketPathStat(socket_path);
    try std.testing.expect(stat.isSocket());
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    // Linux filesystems can immediately recycle the freed inode number after
    // unlink(), so verify replacement by connecting to the newly bound server.
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "socket path at the sun_path limit binds in place under a private parent" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-limit-private");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    // Parent does not exist, so Server.init creates it 0700. The path is
    // exactly the limit, which leaves no room for a staging directory.
    const socket_path = try paddedSocketPath(allocator, parent, max_socket_path_len);
    defer allocator.free(socket_path);

    const original_umask = std.c.umask(0);
    defer _ = std.c.umask(original_umask);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit();

    try std.testing.expectEqual(@as(std.c.mode_t, 0), std.c.umask(0));
    const stat = try socketPathStat(socket_path);
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "socket path at the sun_path limit is never exposed under a shared parent" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-limit-shared");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try paddedSocketPath(allocator, parent, max_socket_path_len);
    defer allocator.free(socket_path);

    const original_umask = std.c.umask(0);
    defer _ = std.c.umask(original_umask);

    if (Server.init(allocator, test_io, socket_path, 0)) |created| {
        // Linux creates the file 0600 at bind time via the pre-bind fchmod.
        var server = created;
        defer server.deinit();
        const stat = try socketPathStat(socket_path);
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    } else |err| switch (err) {
        // Elsewhere there is no race-free way to bind here, so it is refused
        // and nothing is left behind.
        error.SocketStagingPathTooLong => {
            try std.testing.expect(builtin.os.tag != .linux);
            try std.testing.expectEqual(@as(usize, 0), try countDirEntries(parent));
        },
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    }
    try std.testing.expectEqual(@as(std.c.mode_t, 0), std.c.umask(0));
}

test "server deinit does not unlink a replacement socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-replaced-socket");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    try std.testing.expect(socketExists(socket_path));

    try std.Io.Dir.deleteFileAbsolute(test_io, socket_path);
    const replacement = try bindRawUnixListener(socket_path);
    defer sys.close(replacement);

    server.deinit();
    try std.testing.expect(socketExists(socket_path));
}

test "server deinit unlinks its owned socket, and unpublish is idempotent" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-owned-socket");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    try std.testing.expect(socketExists(socket_path));

    server.unpublish();
    try std.testing.expect(!socketExists(socket_path));

    // A successor binds the same name; the first server must leave it alone.
    const successor = try bindRawUnixListener(socket_path);
    defer sys.close(successor);
    server.unpublish();
    server.deinit();
    try std.testing.expect(socketExists(socket_path));
}

test "server connection reader keeps leftover request bytes" {
    const fds = try sys.pipe();
    var read_fd_owned = true;
    defer if (read_fd_owned) sys.close(fds[0]);
    defer sys.close(fds[1]);

    _ = try sys.write(fds[1], "{\"id\":1}\n{\"id\":2}\n");

    var connection = try ClientConnection.create(std.testing.allocator, test_io, fds[0], null);
    read_fd_owned = false;
    defer connection.release();

    const first = (try connection.reader.readLineAllocMaybe(std.testing.allocator, fds[0], 64)).?;
    defer std.testing.allocator.free(first);
    const second = (try connection.reader.readLineAllocMaybe(std.testing.allocator, fds[0], 64)).?;
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("{\"id\":1}\n", first);
    try std.testing.expectEqualStrings("{\"id\":2}\n", second);
}

test "client connection close shuts down without releasing the fd number" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = sys.socketPair() catch return error.SkipZigTest;
    defer sys.close(sockets[1]);

    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0], null);
    const original_fd = connection.fd;
    connection.close();

    const devnull = try sys.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer sys.close(devnull);
    try std.testing.expect(devnull != original_fd);

    connection.release();
}

test "payload queue is a ring: FIFO across wraparound and growth" {
    const allocator = std.testing.allocator;
    var queue: PayloadQueue = .{};
    defer queue.deinit(allocator);

    var next_push: usize = 0;
    var next_pop: usize = 0;
    const push = struct {
        fn one(q: *PayloadQueue, a: Allocator, value: usize) !void {
            const bytes = try a.alloc(u8, @sizeOf(usize));
            std.mem.writeInt(usize, bytes[0..@sizeOf(usize)], value, .little);
            const payload = Payload.create(a, bytes, null) catch |err| {
                a.free(bytes);
                return err;
            };
            q.push(a, payload) catch |err| {
                payload.release();
                return err;
            };
        }
    }.one;

    // Interleave pushes and pops so head wraps before each growth.
    var round: usize = 0;
    while (round < 40) : (round += 1) {
        var burst: usize = 0;
        while (burst < 7) : (burst += 1) {
            try push(&queue, allocator, next_push);
            next_push += 1;
        }
        var drain: usize = 0;
        while (drain < 5) : (drain += 1) {
            const payload = queue.pop().?;
            defer payload.release();
            try std.testing.expectEqual(next_pop, std.mem.readInt(usize, payload.bytes[0..@sizeOf(usize)], .little));
            next_pop += 1;
        }
    }
    while (queue.pop()) |payload| {
        defer payload.release();
        try std.testing.expectEqual(next_pop, std.mem.readInt(usize, payload.bytes[0..@sizeOf(usize)], .little));
        next_pop += 1;
    }
    try std.testing.expectEqual(next_push, next_pop);
}

test "server idle timeout ignores terminated panes" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-idle-terminated");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 1);
    defer server.deinit();

    var handle = try server.manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" });
    handle.deinit();

    const deadline = std.Io.Clock.awake.now(test_io).addDuration(.fromSeconds(2));
    while (std.Io.Clock.awake.now(test_io).compare(.lt, deadline)) {
        server.manager.reapExitedPanes();
        if (server.manager.count() == 0) break;
        test_io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 0), server.manager.count());

    server.last_activity_seconds.store(monotonicSeconds(test_io) - 2, .seq_cst);
    try std.testing.expect(server.shouldExitForIdle());
}

test "idle interval restarts while a pane is live or a client is attached" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var server = try fuzz_hooks.initInMemoryServer(std.testing.allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    server.idle_timeout_seconds = 5;

    // Nothing to keep alive and long idle: exit.
    server.last_activity_seconds.store(monotonicSeconds(test_io) - 60, .seq_cst);
    try std.testing.expect(server.shouldExitForIdle());

    // An attached client holds the daemon and restarts the interval.
    var probe = try QueueProbe.init(&server);
    defer probe.deinit();
    try probe.connection.trackMuxClient("client-1", "pane-1");
    server.last_activity_seconds.store(monotonicSeconds(test_io) - 60, .seq_cst);
    try std.testing.expect(!server.shouldExitForIdle());
    try std.testing.expect(monotonicSeconds(test_io) - server.last_activity_seconds.load(.seq_cst) < 5);
    try std.testing.expect(probe.connection.untrackMuxClient("client-1"));

    // A live pane does the same, so the interval starts when it exits.
    var handle = try server.manager.createSessionPane(.{ .shell = "/bin/sh", .command = "exec cat" });
    handle.deinit();
    server.last_activity_seconds.store(monotonicSeconds(test_io) - 60, .seq_cst);
    try std.testing.expect(!server.shouldExitForIdle());
    try std.testing.expect(monotonicSeconds(test_io) - server.last_activity_seconds.load(.seq_cst) < 5);

    // session_exited restarts it as well.
    server.last_activity_seconds.store(monotonicSeconds(test_io) - 60, .seq_cst);
    Server.handleNativeEvent(&server, .{ .session_exited = .{ .session_id = "gone", .pid = 1, .exit_code = 0 } });
    try std.testing.expect(monotonicSeconds(test_io) - server.last_activity_seconds.load(.seq_cst) < 5);
}

fn tempPath(allocator: Allocator, prefix: []const u8) ![]u8 {
    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}-{x:0>16}", .{ root, prefix, nonce });
}

/// `<parent>/ssss…` padded to exactly `total_len` bytes.
fn paddedSocketPath(allocator: Allocator, parent: []const u8, total_len: usize) ![]u8 {
    const path = try allocator.alloc(u8, total_len);
    @memset(path, 's');
    @memcpy(path[0..parent.len], parent);
    path[parent.len] = '/';
    return path;
}

fn countDirEntries(path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(test_io, path, .{ .iterate = true });
    defer dir.close(test_io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(test_io)) |_| count += 1;
    return count;
}

/// Entries in `dir_path` whose name starts with `prefix`: the socket itself
/// plus anything a failed bind left beside it.
fn countMatchingEntries(dir_path: []const u8, prefix: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(test_io, dir_path, .{ .iterate = true });
    defer dir.close(test_io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(test_io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) count += 1;
    }
    return count;
}

fn envContains(entries: []const []const u8, expected: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, expected)) return true;
    }
    return false;
}

fn bindRawUnixListener(path: []const u8) !posix.fd_t {
    const address = try sys.UnixAddress.init(path);
    const listener = try sys.unixStreamSocket();
    errdefer sys.close(listener);
    try sys.bind(listener, &address);
    try sys.listen(listener, 1);
    return listener;
}

fn requireUnixSocketBind(path: []const u8) !void {
    const listener = bindRawUnixListener(path) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    sys.close(listener);
    std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};
}

fn socketExists(path: []const u8) bool {
    _ = socketPathStat(path) catch return false;
    return true;
}

fn socketPathStat(path: []const u8) !sys.Stat {
    return sys.statAt(sys.cwd_fd, path, false);
}

fn chmodAbsolute(allocator: Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

fn dirMode(path: []const u8) !u32 {
    const stat = try sys.statAt(sys.cwd_fd, path, true);
    return stat.permissions();
}
