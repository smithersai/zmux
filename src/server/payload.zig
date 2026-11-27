const std = @import("std");
const assert = std.debug.assert;
const log = @import("../log.zig");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const connection_mod = @import("connection.zig");
const limits_mod = @import("limits.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const broadcast_queue_max_bytes = limits_mod.broadcast_queue_max_bytes;
const test_io = test_support_mod.test_io;

/// Stream position of one `pane_output` event, kept beside its serialized
/// bytes so a dropped event can be reported as `pane_output_dropped`.
pub const OutputMeta = struct {
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
pub const Payload = struct {
    allocator: Allocator,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    bytes: []u8,
    /// Set only for `pane_output`.
    output: ?OutputMeta = null,

    /// Takes ownership of `bytes` and `output.pane_id` on success only.
    pub fn create(allocator: Allocator, bytes: []u8, output: ?OutputMeta) !*Payload {
        const payload = try allocator.create(Payload);
        payload.* = .{ .allocator = allocator, .bytes = bytes, .output = output };
        return payload;
    }

    pub fn retain(self: *Payload) *Payload {
        const previous = self.ref_count.fetchAdd(1, .seq_cst);
        assert(previous > 0);
        return self;
    }

    pub fn release(self: *Payload) void {
        const previous = self.ref_count.fetchSub(1, .seq_cst);
        assert(previous > 0);
        if (previous != 1) return;
        const allocator = self.allocator;
        if (self.output) |meta| allocator.free(meta.pane_id);
        allocator.free(self.bytes);
        allocator.destroy(self);
    }
};

/// Ring deque of queued payloads: O(1) push and pop.
pub const PayloadQueue = struct {
    items: []*Payload = &[_]*Payload{},
    head: usize = 0,
    len: usize = 0,

    pub fn deinit(self: *PayloadQueue, allocator: Allocator) void {
        allocator.free(self.items);
        self.* = .{};
    }

    pub fn push(self: *PayloadQueue, allocator: Allocator, payload: *Payload) !void {
        try self.reserveOne(allocator);
        self.pushAssumeCapacity(payload);
    }

    /// Grow so the next `pushAssumeCapacity` cannot fail.
    pub fn reserveOne(self: *PayloadQueue, allocator: Allocator) !void {
        if (self.len < self.items.len) return;
        const capacity = if (self.items.len == 0) 16 else self.items.len * 2;
        assert(capacity > self.len);
        const next = try allocator.alloc(*Payload, capacity);
        for (0..self.len) |i| next[i] = self.at(i);
        allocator.free(self.items);
        self.items = next;
        self.head = 0;
        assert(self.len < self.items.len);
    }

    pub fn pushAssumeCapacity(self: *PayloadQueue, payload: *Payload) void {
        std.debug.assert(self.len < self.items.len);
        self.items[(self.head + self.len) % self.items.len] = payload;
        self.len += 1;
        assert(self.len <= self.items.len);
    }

    pub fn pop(self: *PayloadQueue) ?*Payload {
        if (self.len == 0) return null;
        assert(self.head < self.items.len);
        const payload = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        return payload;
    }

    pub fn at(self: *const PayloadQueue, index: usize) *Payload {
        assert(index < self.len);
        return self.items[(self.head + index) % self.items.len];
    }

    pub fn set(self: *PayloadQueue, index: usize, payload: *Payload) void {
        assert(index < self.len);
        self.items[(self.head + index) % self.items.len] = payload;
    }
};

/// Output dropped for one pane on one connection, reported to the client as a
/// single `pane_output_dropped` before any later output of that pane.
pub const DropRecord = struct {
    pane_id: []u8,
    dropped_bytes: u64,
    resume_offset: u64,
    /// Offsets compare only within one generation.
    generation: u64 = 0,
};

/// Sizes of one output eviction, logged after `queue_mutex` is released.
pub const DropStats = struct {
    dropped_bytes: usize = 0,
    dropped_events: u64 = 0,

    pub fn report(self: DropStats) void {
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
pub const Attachment = struct {
    client_id: []u8,
    pane_id: []u8,

    pub fn deinit(self: Attachment, allocator: Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.pane_id);
    }
};

var output_dropped_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

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

test "payload queue is a ring: FIFO across wraparound and growth" {
    const allocator = std.testing.allocator;
    var queue: PayloadQueue = .{};
    defer queue.deinit(allocator);

    var next_push: usize = 0;
    var next_pop: usize = 0;
    const push = struct {
        pub fn one(q: *PayloadQueue, a: Allocator, value: usize) !void {
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
