const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const rpc_line_reader = @import("../rpc_line_reader.zig");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const LineReader = rpc_line_reader.LineReader;
const posix = std.posix;

const conn_queue_mod = @import("conn_queue.zig");
const conn_routes_mod = @import("conn_routes.zig");
const conn_writer_mod = @import("conn_writer.zig");
const server_mod = @import("../server.zig");
const limits_mod = @import("limits.zig");
const payload_mod = @import("payload.zig");
const socket_io_mod = @import("socket_io.zig");
const test_support_mod = @import("test_support.zig");
const Attachment = payload_mod.Attachment;
const DropRecord = payload_mod.DropRecord;
const PayloadQueue = payload_mod.PayloadQueue;
const Server = server_mod.Server;
const send_deadline_ms = limits_mod.send_deadline_ms;
const setSocketSendTimeout = socket_io_mod.setSocketSendTimeout;
const test_io = test_support_mod.test_io;
const writeAllDeadline = socket_io_mod.writeAllDeadline;

/// One accepted client socket: its frame reader, outbound notification
/// queue, lazily started writer thread, and the mux clients it owns.
/// Reference counted; the last `release` closes the socket and frees it.
pub const ClientConnection = struct {
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
    pub fn create(allocator: Allocator, io: std.Io, fd: posix.fd_t, server: ?*Server) !*ClientConnection {
        assert(fd >= 0);
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
        assert(connection.ref_count.load(.seq_cst) == 1);
        assert(!connection.isClosed());
        return connection;
    }

    pub fn retain(self: *ClientConnection) *ClientConnection {
        const previous = self.ref_count.fetchAdd(1, .seq_cst);
        assert(previous > 0);
        return self;
    }

    pub fn release(self: *ClientConnection) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        assert(prev > 0);
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

    pub fn isClosed(self: *const ClientConnection) bool {
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
    pub fn close(self: *ClientConnection) void {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);
        if (!self.closed.swap(true, .seq_cst)) {
            _ = std.c.shutdown(self.fd, @intCast(posix.SHUT.RDWR));
            self.queue_condition.broadcast(self.io);
        }
        assert(self.isClosed());
    }

    pub fn write(self: *ClientConnection, bytes: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        return self.writeLocked(bytes);
    }

    /// Caller holds `write_mutex`.
    pub fn writeLocked(self: *ClientConnection, bytes: []const u8) !void {
        if (self.isClosed()) return error.ConnectionClosed;
        writeAllDeadline(self.fd, bytes, send_deadline_ms) catch |err| {
            self.close();
            return err;
        };
    }

    // -- Subscriptions and attached mux clients ------------------------------

    pub const enqueueBroadcast = conn_queue_mod.enqueueBroadcast;
    pub const enqueue = conn_queue_mod.enqueue;
    pub const enqueueLocked = conn_queue_mod.enqueueLocked;
    pub const noteDropped = conn_queue_mod.noteDropped;
    pub const dropQueuedOutputLocked = conn_queue_mod.dropQueuedOutputLocked;
    pub const recordDropLocked = conn_queue_mod.recordDropLocked;
    pub const takeDropNoticeLocked = conn_queue_mod.takeDropNoticeLocked;
    pub const ensureWriterLocked = conn_writer_mod.ensureWriterLocked;
    pub const writerThread = conn_writer_mod.writerThread;
    pub const writeBatch = conn_writer_mod.writeBatch;
    pub const takeQueuedBatch = conn_writer_mod.takeQueuedBatch;
    pub const takeQueuedWrite = conn_writer_mod.takeQueuedWrite;
    pub const tryTakeQueuedWrite = conn_writer_mod.tryTakeQueuedWrite;
    pub const takeWrite = conn_writer_mod.takeWrite;
    pub const trackMuxClient = conn_routes_mod.trackMuxClient;
    pub const switchMuxClientPane = conn_routes_mod.switchMuxClientPane;
    pub const switchRouteAndNotify = conn_routes_mod.switchRouteAndNotify;
    pub const untrackMuxClient = conn_routes_mod.untrackMuxClient;
    pub const ownsMuxClient = conn_routes_mod.ownsMuxClient;
    pub const attachedClientCount = conn_routes_mod.attachedClientCount;
    pub const takeMuxClients = conn_routes_mod.takeMuxClients;
    pub const setSubscriptions = conn_routes_mod.setSubscriptions;
    pub const wantsPaneOutput = conn_routes_mod.wantsPaneOutput;
};

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
