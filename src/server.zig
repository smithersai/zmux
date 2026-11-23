const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");
const mux = @import("mux.zig");
const native_mod = @import("native.zig");
const protocol = @import("protocol.zig");
const rpc_line_reader = @import("rpc_line_reader.zig");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const LineReader = rpc_line_reader.LineReader;
const Value = std.json.Value;
const posix = std.posix;

const max_request_bytes = 1024 * 1024;

/// Cap the raw scrollback replay delivered on attach. 256 KiB comfortably
/// covers a TUI's visible state + a few screenfuls of history while keeping
/// the attach payload bounded. When scrollback is larger, only the tail
/// (most recent bytes) is replayed.
const attach_replay_max_bytes: usize = 256 * 1024;
const broadcast_queue_max_bytes: usize = 1024 * 1024;
const socket_send_timeout_seconds: isize = 2;
pub const max_client_connections: usize = 256;
const accept_backoff_ms: i64 = 50;

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

const BroadcastPayload = struct {
    allocator: Allocator,
    ref_count: std.atomic.Value(u32),
    data: []u8,

    fn createOwned(allocator: Allocator, owned_data: []u8) !*BroadcastPayload {
        const self = try allocator.create(BroadcastPayload);
        self.* = .{
            .allocator = allocator,
            .ref_count = std.atomic.Value(u32).init(1),
            .data = owned_data,
        };
        return self;
    }

    fn createCopy(allocator: Allocator, bytes: []const u8) !*BroadcastPayload {
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        return createOwned(allocator, owned);
    }

    fn retain(self: *BroadcastPayload) *BroadcastPayload {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    fn release(self: *BroadcastPayload) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            allocator.free(self.data);
            allocator.destroy(self);
        }
    }

    /// Consume one reference and return an allocator-owned slice. When this
    /// reference is the last owner, transfers `self.data` directly with zero copy.
    fn intoOwnedBytes(self: *BroadcastPayload) Allocator.Error![]u8 {
        if (self.ref_count.load(.acquire) == 1) {
            const allocator = self.allocator;
            const data = self.data;
            allocator.destroy(self);
            return data;
        }
        const duped = try self.allocator.dupe(u8, self.data);
        self.release();
        return duped;
    }
};

/// O(1) power-of-two ring queue of ref-counted broadcast frames.
const BroadcastQueue = struct {
    items: []*BroadcastPayload = &.{},
    head: usize = 0,
    len: usize = 0,

    fn push(self: *BroadcastQueue, allocator: Allocator, payload: *BroadcastPayload) !void {
        if (self.len == self.items.len) {
            const new_cap: usize = if (self.items.len == 0) 16 else self.items.len * 2;
            const new_items = try allocator.alloc(*BroadcastPayload, new_cap);
            if (self.len > 0) {
                const first_len = @min(self.len, self.items.len - self.head);
                @memcpy(new_items[0..first_len], self.items[self.head .. self.head + first_len]);
                if (first_len < self.len) {
                    @memcpy(new_items[first_len..self.len], self.items[0 .. self.len - first_len]);
                }
            }
            if (self.items.len > 0) allocator.free(self.items);
            self.items = new_items;
            self.head = 0;
        }
        const mask = self.items.len - 1;
        self.items[(self.head + self.len) & mask] = payload;
        self.len += 1;
    }

    fn pop(self: *BroadcastQueue) ?*BroadcastPayload {
        if (self.len == 0) return null;
        const mask = self.items.len - 1;
        const payload = self.items[self.head];
        self.head = (self.head + 1) & mask;
        self.len -= 1;
        return payload;
    }

    fn deinit(self: *BroadcastQueue, allocator: Allocator) void {
        while (self.pop()) |payload| payload.release();
        if (self.items.len > 0) allocator.free(self.items);
        self.* = .{};
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
    pending_writes: BroadcastQueue = .{},
    queued_bytes: usize = 0,
    attached_mux_clients: std.ArrayList([]u8) = .empty,

    fn create(allocator: Allocator, io: std.Io, fd: posix.fd_t) !*ClientConnection {
        const connection = try allocator.create(ClientConnection);
        connection.* = .{
            .allocator = allocator,
            .io = io,
            .fd = fd,
        };
        return connection;
    }

    fn startBroadcastWriter(self: *ClientConnection, server: *Server) !void {
        self.server = server;
        _ = self.retain();
        server.addActiveWriter();
        const thread = std.Thread.spawn(.{}, ClientConnection.writerThread, .{self}) catch |err| {
            server.finishActiveWriter();
            self.server = null;
            self.release();
            return err;
        };
        thread.detach();
    }

    fn retain(self: *ClientConnection) *ClientConnection {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
        return self;
    }

    fn release(self: *ClientConnection) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        if (prev == 1) {
            // Copy the allocator out of `self` before any destroy: the
            // queue's deinit + the destroy(self) below both need the
            // allocator, but reading `self.allocator` after `destroy(self)`
            // is a use-after-free that the testing allocator's poisoning
            // turns into a segfault.
            const allocator = self.allocator;
            var mux_clients = self.takeMuxClients();
            for (mux_clients.items) |client_id| allocator.free(client_id);
            mux_clients.deinit(allocator);
            self.queue_mutex.lockUncancelable(self.io);
            var pending = self.pending_writes;
            self.pending_writes = .{};
            self.queued_bytes = 0;
            self.queue_mutex.unlock(self.io);
            pending.deinit(allocator);
            sys.close(self.fd);
            allocator.destroy(self);
        }
    }

    fn isClosed(self: *const ClientConnection) bool {
        return self.closed.load(.seq_cst);
    }

    pub fn pendingWriteCount(self: *const ClientConnection) usize {
        return self.pending_writes.len;
    }

    fn close(self: *ClientConnection) void {
        if (!self.closed.swap(true, .seq_cst)) {
            _ = std.c.shutdown(self.fd, @intCast(posix.SHUT.RDWR));
            self.queue_mutex.lockUncancelable(self.io);
            self.queue_condition.broadcast(self.io);
            self.queue_mutex.unlock(self.io);
        }
    }

    fn write(self: *ClientConnection, bytes: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);

        if (self.isClosed()) return error.ConnectionClosed;
        writeAll(self.fd, bytes) catch |err| {
            self.close();
            return err;
        };
    }

    fn writeBatch(self: *ClientConnection, batch: []*BroadcastPayload) !void {
        if (batch.len == 1) return self.write(batch[0].data);

        var total: usize = 0;
        for (batch) |item| total += item.data.len;

        // Coalesce small/medium queued frames into one syscall under one lock.
        if (total <= 64 * 1024) {
            var coalesce_buf: [64 * 1024]u8 = undefined;
            var pos: usize = 0;
            for (batch) |item| {
                @memcpy(coalesce_buf[pos..][0..item.data.len], item.data);
                pos += item.data.len;
            }
            return self.write(coalesce_buf[0..pos]);
        }

        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.isClosed()) return error.ConnectionClosed;
        for (batch) |item| {
            writeAll(self.fd, item.data) catch |err| {
                self.close();
                return err;
            };
        }
    }

    fn enqueueBroadcastPayload(self: *ClientConnection, payload: *BroadcastPayload) !void {
        const len = payload.data.len;
        self.queue_mutex.lockUncancelable(self.io);
        if (self.isClosed()) {
            self.queue_mutex.unlock(self.io);
            return error.ConnectionClosed;
        }
        if (len > broadcast_queue_max_bytes or self.queued_bytes > broadcast_queue_max_bytes - len) {
            const queued_bytes = self.queued_bytes;
            self.queue_mutex.unlock(self.io);
            // Sizes only: the queued bytes are PTY output and are never logged.
            log.warn("client_backlogged", .{
                .queued_bytes = queued_bytes,
                .rejected_bytes = len,
                .max_queued_bytes = broadcast_queue_max_bytes,
            });
            self.close();
            return error.ConnectionBacklogged;
        }

        const retained = payload.retain();
        self.pending_writes.push(self.allocator, retained) catch |err| {
            self.queue_mutex.unlock(self.io);
            retained.release();
            return err;
        };
        self.queued_bytes += len;
        self.queue_condition.signal(self.io);
        self.queue_mutex.unlock(self.io);
    }

    fn enqueueBroadcast(self: *ClientConnection, bytes: []const u8) !void {
        const payload = try BroadcastPayload.createCopy(self.allocator, bytes);
        defer payload.release();
        try self.enqueueBroadcastPayload(payload);
    }

    fn writerThread(self: *ClientConnection) void {
        defer {
            // Release before signalling the server: when this thread holds the
            // last reference, release() frees the connection and its queued
            // payloads, and waitForWorkers must not let deinit (and the test
            // runner's leak check) proceed until that has happened. Copy the
            // server pointer out first — `self` is invalid after release().
            const server = self.server;
            self.release();
            if (server) |active| active.finishActiveWriter();
        }

        var batch: [16]*BroadcastPayload = undefined;
        while (true) {
            const n = self.takeQueuedBatch(&batch);
            if (n == 0) return;
            defer {
                for (batch[0..n]) |payload| payload.release();
            }
            self.writeBatch(batch[0..n]) catch return;
        }
    }

    fn takeQueuedBatch(self: *ClientConnection, out: []*BroadcastPayload) usize {
        self.queue_mutex.lockUncancelable(self.io);
        defer self.queue_mutex.unlock(self.io);

        while (self.pending_writes.len == 0 and !self.isClosed()) {
            self.queue_condition.waitUncancelable(self.io, &self.queue_mutex);
        }

        var count: usize = 0;
        while (count < out.len) {
            const payload = self.pending_writes.pop() orelse break;
            self.queued_bytes -= payload.data.len;
            out[count] = payload;
            count += 1;
        }
        return count;
    }

    fn takeQueuedWrite(self: *ClientConnection) ?[]u8 {
        self.queue_mutex.lockUncancelable(self.io);
        while (self.pending_writes.len == 0 and !self.isClosed()) {
            self.queue_condition.waitUncancelable(self.io, &self.queue_mutex);
        }

        const payload = self.pending_writes.pop() orelse {
            self.queue_mutex.unlock(self.io);
            return null;
        };
        self.queued_bytes -= payload.data.len;
        self.queue_mutex.unlock(self.io);

        return payload.intoOwnedBytes() catch {
            payload.release();
            return null;
        };
    }

    fn trackMuxClient(self: *ClientConnection, client_id: []const u8) !void {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);

        for (self.attached_mux_clients.items) |active| {
            if (std.mem.eql(u8, active, client_id)) return;
        }

        const owned = try self.allocator.dupe(u8, client_id);
        errdefer self.allocator.free(owned);
        try self.attached_mux_clients.append(self.allocator, owned);
    }

    fn untrackMuxClient(self: *ClientConnection, client_id: []const u8) bool {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);

        for (self.attached_mux_clients.items, 0..) |active, index| {
            if (std.mem.eql(u8, active, client_id)) {
                const removed = self.attached_mux_clients.swapRemove(index);
                self.allocator.free(removed);
                return true;
            }
        }
        return false;
    }

    fn takeMuxClients(self: *ClientConnection) std.ArrayList([]u8) {
        self.attachment_mutex.lockUncancelable(self.io);
        defer self.attachment_mutex.unlock(self.io);

        const attached = self.attached_mux_clients;
        self.attached_mux_clients = .empty;
        return attached;
    }
};

/// JSON-RPC daemon over a private (0600) UNIX socket.
///
/// `init` binds the socket, `run` accepts connections until `daemon.shutdown`,
/// the idle timeout, or the shutdown probe stops it, and `deinit` releases
/// everything. Each connection gets a reader thread and a broadcast writer
/// thread (`std.Thread`); `io` supplies their mutexes and condition variables,
/// the clocks, sleeps, randomness, and filesystem access. Pass a thread-safe
/// implementation such as `std.Io.Threaded` (`std.process.Init.io` in `main`).
pub const Server = struct {
    pub const ShutdownProbe = *const fn () bool;

    allocator: Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    socket_path: []u8,
    socket_stat: sys.Stat,
    listener_fd: posix.fd_t,
    manager: mux.Manager,
    connections: std.ArrayList(*ClientConnection) = .empty,
    connected_clients: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_writer_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_mutex: std.Io.Mutex = .init,
    active_condition: std.Io.Condition = .init,
    /// Monotonic (`.awake` clock) seconds of the last client activity.
    last_activity_seconds: std.atomic.Value(i64),
    idle_timeout_seconds: i64,
    shutdown_probe: ?ShutdownProbe = null,

    /// Bind `socket_path` (absolute) and prepare to serve. A server with no
    /// live panes exits from `run` after `idle_timeout_seconds` without
    /// client activity; 0 or less disables the timeout.
    ///
    /// Fails with `error.SocketPathTooLong` before touching the filesystem when
    /// the path exceeds `max_socket_path_len`.
    pub fn init(allocator: Allocator, io: std.Io, socket_path: []const u8, idle_timeout_seconds: i64) !Server {
        // Reject before touching the filesystem: an over-long path can never
        // be bound, and must not leave a parent directory or lock behind.
        if (socket_path.len > max_socket_path_len) return error.SocketPathTooLong;

        try ensureSocketParent(socket_path);
        std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const listener = try sys.unixStreamSocket();
        errdefer sys.close(listener);

        // Bind owner-only (0600) without touching the process-wide umask; see
        // bindPrivateSocket for why the socket is never visible with a wider
        // mode.
        try bindPrivateSocket(io, listener, socket_path);
        errdefer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

        // Size the accept backlog to the connection cap so a burst of clients
        // (e.g. a fleader spawning many attachers at once) is queued rather
        // than refused while the accept loop drains it. The kernel silently
        // clamps to somaxconn.
        try sys.listen(listener, @intCast(max_client_connections));
        const socket_stat = try socketPathStat(socket_path);
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
            .listener_fd = listener,
            .manager = mux.Manager.init(allocator, io, null),
            .last_activity_seconds = std.atomic.Value(i64).init(monotonicSeconds(io)),
            .idle_timeout_seconds = idle_timeout_seconds,
        };
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);
        self.unlinkSocketPathIfOwned();
        sys.close(self.listener_fd);
        self.closeConnections();
        self.waitForWorkers();
        self.manager.event_sink = null;
        self.manager.deinit();
        self.connections.deinit(self.allocator);
        self.allocator.free(self.socket_path);
    }

    fn unlinkSocketPathIfOwned(self: *Server) void {
        const path_stat = socketPathStat(self.socket_path) catch return;
        if (self.socket_stat.dev == path_stat.dev and self.socket_stat.ino == path_stat.ino) {
            std.Io.Dir.deleteFileAbsolute(self.io, self.socket_path) catch {};
        }
    }

    pub fn run(self: *Server) !void {
        self.manager.event_sink = .{
            .context = self,
            .emit = Server.handleNativeEvent,
        };
        while (!self.shouldStop()) {
            self.manager.reapExitedPanes();
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

            const client_fd = sys.accept(self.listener_fd) catch |err| {
                log.warn("accept_error", .{
                    .err = err,
                    .active_connections = self.active_connections.load(.seq_cst),
                });
                // Fd exhaustion and every other listener-level fault get the
                // same backoff: it keeps a failing accept from spinning at
                // 100% CPU while still letting the server recover.
                self.io.sleep(.fromMilliseconds(accept_backoff_ms), .awake) catch {};
                continue;
            };
            const peer_euid = peerEuid(client_fd);
            if (peer_euid == null or peer_euid.? != sys.geteuid()) {
                log.warn("peer_cred_rejected", .{
                    .peer_euid = peer_euid,
                    .euid = sys.geteuid(),
                    .socket_path = self.socket_path,
                });
                sys.close(client_fd);
                continue;
            }
            setSocketSendTimeout(client_fd);
            sys.tuneUnixSocketBuffers(client_fd);
            self.touch();
            const previous_connections = self.active_connections.fetchAdd(1, .seq_cst);
            if (previous_connections >= max_client_connections) {
                _ = self.active_connections.fetchSub(1, .seq_cst);
                log.warn("connection_limit_reached", .{
                    .active_connections = previous_connections,
                    .max_connections = max_client_connections,
                });
                writeConnectionLimitError(client_fd);
                sys.close(client_fd);
                continue;
            }
            const thread = std.Thread.spawn(.{}, Server.handleClientThread, .{ self, client_fd }) catch {
                _ = self.active_connections.fetchSub(1, .seq_cst);
                sys.close(client_fd);
                continue;
            };
            thread.detach();
        }

        self.manager.reapExitedPanes();
        self.closeConnections();
        self.waitForWorkers();
    }

    fn writeConnectionLimitError(fd: posix.fd_t) void {
        const message =
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"server connection limit reached\"}}\n";
        writeAll(fd, message) catch {};
    }

    fn shouldExitForIdle(self: *Server) bool {
        if (self.idle_timeout_seconds <= 0) return false;
        if (self.manager.count() > 0) return false;
        const idle_for = monotonicSeconds(self.io) - self.last_activity_seconds.load(.seq_cst);
        return idle_for >= self.idle_timeout_seconds;
    }

    fn shouldStop(self: *Server) bool {
        if (!self.running.load(.seq_cst)) return true;
        if (self.shutdown_probe) |probe| return probe();
        return false;
    }

    fn touch(self: *Server) void {
        self.last_activity_seconds.store(monotonicSeconds(self.io), .seq_cst);
    }

    fn handleClientThread(self: *Server, client_fd: posix.fd_t) void {
        defer self.finishActiveConnection();

        const connection = ClientConnection.create(self.allocator, self.io, client_fd) catch {
            sys.close(client_fd);
            return;
        };
        defer connection.release();
        defer connection.close();

        connection.startBroadcastWriter(self) catch return;

        self.registerConnection(connection);
        defer self.unregisterConnection(connection);

        self.handleClient(connection);
    }

    fn handleClient(self: *Server, connection: *ClientConnection) void {
        while (self.running.load(.seq_cst)) {
            const line = connection.reader.readLineAllocMaybe(self.allocator, connection.fd, max_request_bytes) catch |err| {
                if (connection.isClosed()) return;
                self.writeError(connection, "null", protocol.ErrorCode.parse_error, @errorName(err)) catch {};
                return;
            } orelse return;
            defer self.allocator.free(line);
            if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;

            self.touch();
            var req = protocol.parseRequest(self.allocator, line) catch |err| {
                self.writeError(connection, "null", protocol.ErrorCode.invalid_request, @errorName(err)) catch {};
                continue;
            };
            defer req.deinit();

            self.dispatch(connection, &req) catch |err| {
                self.writeError(connection, req.id_json, protocol.ErrorCode.internal_error, @errorName(err)) catch {};
            };
        }
    }

    fn dispatch(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        if (std.mem.eql(u8, req.method, "daemon.ping")) {
            const response = try protocol.result(self.allocator, req.id_json, .{
                .version = protocol.version,
                .pid = std.c.getpid(),
                .socketPath = self.socket_path,
                .sessions = self.manager.sessionCount(),
                .panes = self.manager.paneCount(),
            });
            defer self.allocator.free(response);
            return connection.write(response);
        }

        if (std.mem.eql(u8, req.method, "daemon.shutdown")) {
            const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
            defer self.allocator.free(response);
            try connection.write(response);
            self.manager.terminateAll();
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
        if (std.mem.eql(u8, req.method, "key.bind")) return self.bindKey(connection, req);
        if (std.mem.eql(u8, req.method, "key.dispatch")) return self.dispatchKey(connection, req);
        if (std.mem.eql(u8, req.method, "key.list")) return self.listKeys(connection, req);
        if (std.mem.eql(u8, req.method, "command.exec")) return self.execCommand(connection, req);

        try self.writeError(connection, req.id_json, protocol.ErrorCode.method_not_found, "unknown method");
    }

    fn createSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        // session.create is the only place where `id` should also stand in
        // for the session title — for window.new / pane.split the same `id`
        // field is the existing target alias, so it must NOT be repurposed
        // as the new window/pane title.
        var create_args = muxCreateArgsFromParams(self.allocator, req.params(), .{ .id_aliases_title = true }) catch |err| {
            switch (err) {
                error.ScrollbackBytesTooLarge => {
                    try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "scrollbackBytes exceeds maximum");
                    return;
                },
                else => return err,
            }
        };
        defer create_args.deinit();

        const created = try self.manager.create(create_args.opts);
        defer created.release();

        const info = try created.infoJson(self.allocator);
        defer self.allocator.free(info);
        const response = try protocol.resultRaw(self.allocator, req.id_json, info);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn snapshotMux(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn newWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const session_id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        var create_args = muxCreateArgsFromParams(self.allocator, req.params(), .{}) catch |err| {
            switch (err) {
                error.ScrollbackBytesTooLarge => {
                    try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "scrollbackBytes exceeds maximum");
                    return;
                },
                else => return err,
            }
        };
        defer create_args.deinit();
        _ = try self.manager.newWindow(session_id, create_args.opts);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn splitPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        var create_args = muxCreateArgsFromParams(self.allocator, req.params(), .{}) catch |err| {
            switch (err) {
                error.ScrollbackBytesTooLarge => {
                    try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "scrollbackBytes exceeds maximum");
                    return;
                },
                else => return err,
            }
        };
        defer create_args.deinit();
        _ = try self.manager.splitPane(pane_id, axisParam(req.params()), create_args.opts);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn selectPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        try self.manager.selectPane(pane_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn selectWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const window_id = windowIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "windowId is required");
        };
        try self.manager.selectWindow(window_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn renameSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const session_id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        const name = firstStringParam(req.params(), &.{ "name", "title" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "name is required");
        };
        try self.manager.renameSession(session_id, name);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn renameWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const window_id = windowIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "windowId is required");
        };
        const name = firstStringParam(req.params(), &.{ "name", "title" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "name is required");
        };
        try self.manager.renameWindow(window_id, name);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn renamePane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const title = firstStringParam(req.params(), &.{ "title", "name" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "title is required");
        };
        try self.manager.renamePane(pane_id, title, boolParam(req.params(), "custom", true));
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn respawnPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const active = try self.manager.respawnPane(pane_id);
        defer active.release();
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn attachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        var client = try self.manager.attachClient(
            pane_id,
            intParam(u16, req.params(), "rows", 24),
            intParam(u16, req.params(), "cols", 80),
        );
        defer client.deinit(self.allocator);
        errdefer _ = self.manager.detachClient(client.id);
        try connection.trackMuxClient(client.id);
        errdefer _ = connection.untrackMuxClient(client.id);
        const replay_bytes = try self.manager.paneScrollbackTail(self.allocator, client.pane_id, attach_replay_max_bytes);
        defer self.allocator.free(replay_bytes);
        const response = try protocol.attachResult(
            self.allocator,
            req.id_json,
            client.id,
            client.session_id,
            client.window_id,
            client.pane_id,
            client.rows,
            client.cols,
            replay_bytes,
        );
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn detachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const client_id = clientIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "clientId is required");
        };
        _ = connection.untrackMuxClient(client_id);
        if (!self.manager.detachClient(client_id)) {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "client not found");
        }
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn switchMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const client_id = clientIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "clientId is required");
        };
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        try self.manager.switchClient(client_id, pane_id);
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn listMuxClients(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.clientsJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn bindKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const key = stringParam(req.params(), "key") orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "key is required");
        };
        const command = firstStringParam(req.params(), &.{ "command", "cmd" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "command is required");
        };
        try self.manager.bindKey(stringParam(req.params(), "table") orelse "prefix", key, command, boolParam(req.params(), "repeat", false));
        const list = try self.manager.keysJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn dispatchKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const key = stringParam(req.params(), "key") orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "key is required");
        };
        const command = self.manager.executeBinding(stringParam(req.params(), "table") orelse "prefix", key, pane_id) catch |err| switch (err) {
            error.UnsupportedCommand => {
                try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, @errorName(err));
                return;
            },
            else => return err,
        };
        defer if (command) |owned| self.allocator.free(owned);
        if (command == null) {
            const response = try protocol.result(self.allocator, req.id_json, .{ .handled = false });
            defer self.allocator.free(response);
            return connection.write(response);
        }
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn listKeys(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.keysJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn execCommand(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const pane_id = paneIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "paneId is required");
        };
        const command = firstStringParam(req.params(), &.{ "command", "line" }) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "command is required");
        };
        self.manager.executeCommandLine(command, pane_id) catch |err| switch (err) {
            error.UnsupportedCommand => {
                try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, @errorName(err));
                return;
            },
            else => return err,
        };
        try self.writeSnapshotResponse(connection, req.id_json);
    }

    fn terminateSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const id = sessionIdParam(req.params()) orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
        };
        if (!self.manager.terminate(id)) {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "session not found");
        }
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn listSessions(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const list = try self.manager.listJson(self.allocator);
        defer self.allocator.free(list);
        const response = try protocol.resultRaw(self.allocator, req.id_json, list);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn infoSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        const info = try active.infoJson(self.allocator);
        defer self.allocator.free(info);
        const response = try protocol.resultRaw(self.allocator, req.id_json, info);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn resizeSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        active.resize(intParam(u16, req.params(), "cols", 80), intParam(u16, req.params(), "rows", 24)) catch |err| switch (err) {
            error.SessionTerminated => {
                try self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, @errorName(err));
                return;
            },
            else => return err,
        };
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn captureSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        const text = try active.capture(self.allocator, intParam(usize, req.params(), "lines", 200));
        defer self.allocator.free(text);
        const response = try protocol.result(self.allocator, req.id_json, .{
            .sessionId = active.id,
            .text = text,
        });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn sendSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        if (firstStringParam(req.params(), &.{ "dataBase64", "data_base64" })) |encoded| {
            const bytes = base64Decode(self.allocator, encoded) catch |err| {
                try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, @errorName(err));
                return;
            };
            defer self.allocator.free(bytes);
            try active.writeInput(bytes);
        } else {
            try active.send(stringParam(req.params(), "text") orelse "", boolParam(req.params(), "enter", false));
        }
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn sendKeySession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
        const active = try self.requiredSession(connection, req) orelse return;
        defer active.release();

        const key = stringParam(req.params(), "key") orelse {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "key is required");
        };
        active.sendKey(key) catch |err| {
            return self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, @errorName(err));
        };
        const response = try protocol.result(self.allocator, req.id_json, .{ .ok = true });
        defer self.allocator.free(response);
        try connection.write(response);
    }

    /// Get a required session by ID. Caller MUST call release() on the returned session.
    fn requiredSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !?*NativeSession {
        const id = sessionIdParam(req.params()) orelse {
            try self.writeError(connection, req.id_json, protocol.ErrorCode.invalid_params, "sessionId is required");
            return null;
        };
        return self.manager.find(id) orelse {
            try self.writeError(connection, req.id_json, protocol.ErrorCode.session_error, "session not found");
            return null;
        };
    }

    fn writeSnapshotResponse(self: *Server, connection: *ClientConnection, id_json: []const u8) !void {
        const snapshot = try self.manager.snapshotJson(self.allocator);
        defer self.allocator.free(snapshot);
        const response = try protocol.resultRaw(self.allocator, id_json, snapshot);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn writeError(self: *Server, connection: *ClientConnection, id_json: []const u8, code: i32, message: []const u8) !void {
        const response = try protocol.@"error"(self.allocator, id_json, code, message);
        defer self.allocator.free(response);
        try connection.write(response);
    }

    fn registerConnection(self: *Server, connection: *ClientConnection) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.connections.append(self.allocator, connection.retain()) catch {
            connection.close();
            connection.release();
            return;
        };
        self.connected_clients.store(self.connections.items.len, .release);
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
        var mux_clients = connection.takeMuxClients();
        defer mux_clients.deinit(self.allocator);
        for (mux_clients.items) |client_id| {
            _ = self.manager.detachClient(client_id);
            self.allocator.free(client_id);
        }
    }

    fn closeConnections(self: *Server) void {
        self.mutex.lockUncancelable(self.io);
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

    fn broadcastOwned(self: *Server, owned_payload: []u8) void {
        var stack_snapshot: [max_client_connections]*ClientConnection = undefined;
        var heap_snapshot: ?[]*ClientConnection = null;

        self.mutex.lockUncancelable(self.io);
        const count = self.connections.items.len;
        if (count == 0) {
            self.mutex.unlock(self.io);
            self.allocator.free(owned_payload);
            return;
        }
        const snapshot: []*ClientConnection = if (count <= stack_snapshot.len)
            stack_snapshot[0..count]
        else blk: {
            const allocated = self.allocator.alloc(*ClientConnection, count) catch {
                self.mutex.unlock(self.io);
                self.allocator.free(owned_payload);
                return;
            };
            heap_snapshot = allocated;
            break :blk allocated;
        };
        for (self.connections.items, 0..) |connection, index| {
            snapshot[index] = connection.retain();
        }
        self.mutex.unlock(self.io);
        defer if (heap_snapshot) |buf| self.allocator.free(buf);

        const shared = BroadcastPayload.createOwned(self.allocator, owned_payload) catch {
            self.allocator.free(owned_payload);
            for (snapshot) |connection| connection.release();
            return;
        };
        defer shared.release();

        for (snapshot) |connection| {
            defer connection.release();
            connection.enqueueBroadcastPayload(shared) catch {
                self.unregisterConnection(connection);
            };
        }
    }

    fn handleNativeEvent(context: *anyopaque, event: native_mod.Event) void {
        const self: *Server = @ptrCast(@alignCast(context));
        switch (event) {
            .session_exited => |params| self.manager.markExited(params.session_id),
            .pane_output => |params| self.manager.markActivity(params.pane_id),
            .pane_activity => |params| self.manager.markActivityAt(params.pane_id, params.last_activity_ms),
            .pane_bell => |params| self.manager.markBellAt(params.pane_id, params.last_bell_ms),
            .foreground_changed => {},
        }

        // Skip base64 encoding and JSON serialization entirely when no clients
        // are connected to receive broadcasts.
        if (self.connected_clients.load(.acquire) == 0) return;

        const payload = switch (event) {
            .foreground_changed => |params| protocol.notification(
                self.allocator,
                protocol.foreground_changed_method,
                params,
            ),
            .session_exited => |params| protocol.notification(
                self.allocator,
                protocol.session_exited_method,
                params,
            ),
            .pane_output => |params| protocol.paneOutputNotification(
                self.allocator,
                params.pane_id,
                params.data,
            ),
            .pane_activity => |params| protocol.notification(
                self.allocator,
                protocol.pane_activity_method,
                protocol.PaneActivityParams{
                    .pane_id = params.pane_id,
                    .last_activity_ms = params.last_activity_ms,
                },
            ),
            .pane_bell => |params| protocol.notification(
                self.allocator,
                protocol.pane_bell_method,
                protocol.PaneBellParams{
                    .pane_id = params.pane_id,
                    .last_bell_ms = params.last_bell_ms,
                },
            ),
        } catch return;

        self.broadcastOwned(payload);
    }
};

fn monotonicSeconds(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toSeconds();
}

fn ensureSocketParent(socket_path: []const u8) !void {
    const parent = std.fs.path.dirname(socket_path) orelse return;
    _ = sys.statAt(sys.cwd_fd, parent, false) catch |err| switch (err) {
        // A missing parent is one zmux owns (the uid-scoped fallback such as
        // /tmp/zmux-<uid> or ~/.smithers): create it private and validate that
        // it really is a self-owned 0700 directory before binding there.
        error.FileNotFound => return createPrivateSocketParent(parent),
        else => return err,
    };
    // A pre-existing parent belongs to a user-specified socket path (e.g.
    // /tmp): use it as-is — no chmod, no rejection. The socket file itself is
    // 0600 and every connection is still gated by a same-uid peer-credential
    // check, so a sticky world-writable parent is an acceptable trust boundary,
    // matching tmux's model for explicit socket paths.
}

/// Create a parent directory that zmux owns, then enforce that it is a private
/// (0700), self-owned, non-symlink directory. Only used for the fallback paths
/// zmux itself creates.
fn createPrivateSocketParent(parent: []const u8) !void {
    sys.mkdir(parent, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open with O_RDONLY | O_DIRECTORY | O_NOFOLLOW (never O_PATH): Linux
    // rejects fchmod(2) with EBADF on O_PATH handles returned by non-iterable
    // std.Io.Dir.openDirAbsolute.
    const dir_fd = try sys.openDirNoFollow(parent);
    defer sys.close(dir_fd);

    const opened = try sys.fstat(dir_fd);
    if (!opened.isDir()) return error.NotDir;
    if (opened.uid != sys.geteuid()) return error.PermissionDenied;
    try sys.fchmod(dir_fd, 0o700);

    const stat = try sys.statAt(sys.cwd_fd, parent, false);
    if (!stat.isDir()) return error.NotDir;
    if (!stat.sameFile(opened)) return error.PermissionDenied;
    if (stat.uid != sys.geteuid()) return error.PermissionDenied;
    if (stat.permissions() != 0o700) return error.PermissionDenied;
}

/// Bind `listener` at `socket_path` so the socket file is owner-only (0600)
/// from the instant it becomes reachable, without calling `umask(2)`.
///
/// `umask` is process-wide: narrowing it around `bind` races every other
/// thread that creates a file, which is unacceptable for an embedded server.
/// POSIX has no `bindat`/mode argument for `bind`, so instead:
///
///   1. `mkdir` a staging directory beside the target. Its mode is at most
///      0700 (umask only clears bits) and `mkdir` fails on any existing name,
///      so nobody else can enter it or have planted it.
///   2. `bind` the socket inside it. Whatever mode the umask yields, the file
///      is unreachable to other users behind the 0700 directory.
///   3. `chmod` the socket to 0600 and verify it.
///   4. `rename` it onto `socket_path`. Rename is atomic and keeps the bound
///      inode, so the public name only ever refers to a 0600 socket.
///
/// The staging path is longer than some valid socket paths. When it cannot fit
/// in `sun_path`, the socket is bound in place only if that is provably
/// private (see bindSocketInPlace); otherwise the bind is refused rather than
/// exposed.
fn bindPrivateSocket(io: std.Io, listener: posix.fd_t, socket_path: []const u8) !void {
    // Linux derives the socket file mode from the socket inode's mode, so this
    // makes bind create the file 0600 outright. macOS rejects fchmod on
    // sockets; staging covers both.
    const mode_preset = builtin.os.tag == .linux and blk: {
        sys.fchmod(listener, 0o600) catch break :blk false;
        break :blk true;
    };

    const dir_prefix = if (std.mem.lastIndexOfScalar(u8, socket_path, '/')) |slash|
        socket_path[0 .. slash + 1]
    else
        "";

    // dir_prefix + staging dir name + "/" + staged_socket_name must fit.
    const fixed_len = dir_prefix.len + staging_dir_prefix.len + 1 + staged_socket_name.len;
    if (fixed_len + staging_dir_random_hex_min > max_socket_path_len) {
        return bindSocketInPlace(io, listener, socket_path, dir_prefix, mode_preset);
    }
    const hex_len = @min(staging_dir_random_hex_max, max_socket_path_len - fixed_len);

    var dir_buf: [max_socket_path_len]u8 = undefined;
    var staging_dir: []const u8 = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var random: [staging_dir_random_hex_max / 2]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        staging_dir = std.fmt.bufPrint(&dir_buf, "{s}{s}{s}", .{
            dir_prefix,
            staging_dir_prefix,
            hex[0..hex_len],
        }) catch unreachable;
        sys.mkdir(staging_dir, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt + 1 >= staging_dir_attempts) return err;
                continue;
            },
            else => return err,
        };
        break;
    }
    defer sys.rmdir(staging_dir) catch {};

    // Hold the directory by fd and validate that fd, so later checks cannot be
    // redirected by someone swapping the name in a writable parent.
    const dir_fd = try sys.openDirNoFollow(staging_dir);
    defer sys.close(dir_fd);
    // A umask that clears owner bits would make the directory unusable.
    try sys.fchmod(dir_fd, 0o700);
    const dir_stat = try sys.fstat(dir_fd);
    if (dir_stat.uid != sys.geteuid()) return error.PermissionDenied;
    if (dir_stat.permissions() != 0o700) return error.PermissionDenied;

    var staged_buf: [max_socket_path_len]u8 = undefined;
    const staged_path = std.fmt.bufPrint(&staged_buf, "{s}/{s}", .{ staging_dir, staged_socket_name }) catch unreachable;

    const address = try sys.UnixAddress.init(staged_path);
    try sys.bind(listener, &address);
    var staged = true;
    defer if (staged) sys.unlinkAt(dir_fd, staged_socket_name) catch {};

    try sys.fchmodat(dir_fd, staged_socket_name, 0o600);
    const socket_stat = try sys.statAt(dir_fd, staged_socket_name, false);
    if (!socket_stat.isSocket()) return error.PermissionDenied;
    if (socket_stat.permissions() != 0o600) return error.PermissionDenied;
    // The path we bound must be the file inside the directory we validated.
    const path_stat = try sys.statAt(sys.cwd_fd, staged_path, false);
    if (path_stat.dev != socket_stat.dev or path_stat.ino != socket_stat.ino) return error.PermissionDenied;

    try sys.rename(staged_path, socket_path);
    staged = false;
}

/// Fallback for socket paths too close to the `sun_path` limit to stage.
/// Binding in place is race-free only when no other user can reach the file
/// between `bind` and `chmod`:
///   * Linux, when the pre-bind `fchmod` succeeded: the file is created 0600.
///   * Any OS, when the parent directory is self-owned with no group/other
///     access: nobody else can traverse to the socket.
/// Anything else would briefly expose a umask-mode socket, so it is refused.
fn bindSocketInPlace(
    io: std.Io,
    listener: posix.fd_t,
    socket_path: []const u8,
    dir_prefix: []const u8,
    mode_preset: bool,
) !void {
    if (!mode_preset) {
        const parent = if (dir_prefix.len == 0) "." else dir_prefix;
        const parent_stat = try sys.statAt(sys.cwd_fd, parent, true);
        const private = parent_stat.isDir() and
            parent_stat.uid == sys.geteuid() and
            (parent_stat.mode & 0o077) == 0;
        if (!private) return error.SocketStagingPathTooLong;
    }

    const address = try sys.UnixAddress.init(socket_path);
    try sys.bind(listener, &address);
    errdefer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    try sys.fchmodat(sys.cwd_fd, socket_path, 0o600);
    const socket_stat = try socketPathStat(socket_path);
    if (socket_stat.permissions() != 0o600) return error.PermissionDenied;
}

const writeAll = sys.sendAll;

fn setSocketSendTimeout(fd: posix.fd_t) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => return,
        else => {},
    }

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
        _ = std.c._errno().*;
    }
}

fn sessionIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "sessionId", "id" });
}

fn firstStringParam(params: ?Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (stringParam(params, key)) |value| return value;
    }
    return null;
}

fn stringParam(params: ?Value, key: []const u8) ?[]const u8 {
    const params_value = params orelse return null;
    if (params_value != .object) return null;
    const value = params_value.object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn boolParam(params: ?Value, key: []const u8, default: bool) bool {
    const params_value = params orelse return default;
    if (params_value != .object) return default;
    const value = params_value.object.get(key) orelse return default;
    return switch (value) {
        .bool => |flag| flag,
        else => default,
    };
}

fn intParam(comptime T: type, params: ?Value, key: []const u8, default: T) T {
    const params_value = params orelse return default;
    if (params_value != .object) return default;
    const value = params_value.object.get(key) orelse return default;
    const integer = switch (value) {
        .integer => |n| n,
        else => return default,
    };
    if (integer < 0) return default;
    return std.math.cast(T, integer) orelse default;
}

fn scrollbackBytesFromParams(params: ?Value) !usize {
    const bytes = intParam(usize, params, "scrollbackBytes", @import("buffer.zig").default_capacity);
    if (bytes > @import("buffer.zig").max_capacity) return error.ScrollbackBytesTooLarge;
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
    // sets this — for `window.new` and `pane.split` the request's `id` field
    // already aliases the *target* (via paneIdParam / sessionIdParam), and
    // repurposing it as the new window/pane title would silently rename
    // them on every call.
    id_aliases_title: bool = false,
};

fn muxCreateArgsFromParams(allocator: Allocator, params: ?Value, options: CreateArgsOptions) !MuxCreateArgs {
    const env_entries = try envEntriesFromParams(allocator, params);
    errdefer if (env_entries) |entries| freeStringSlice(allocator, entries);
    const title_keys: []const []const u8 = if (options.id_aliases_title)
        &.{ "title", "name", "id" }
    else
        &.{ "title", "name" };
    return .{
        .allocator = allocator,
        .env_entries = env_entries,
        .opts = .{
            .title = firstStringParam(params, title_keys),
            .shell = stringParam(params, "shell"),
            .command = stringParam(params, "command"),
            .cwd = firstStringParam(params, &.{ "cwd", "workingDirectory" }),
            .env = if (env_entries) |entries| entries else null,
            .rows = intParam(u16, params, "rows", 24),
            .cols = intParam(u16, params, "cols", 80),
            .scrollback_bytes = try scrollbackBytesFromParams(params),
        },
    };
}

fn paneIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "paneId", "targetPaneId", "target", "sessionId", "id" });
}

fn windowIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "windowId", "targetWindowId", "target", "id" });
}

fn clientIdParam(params: ?Value) ?[]const u8 {
    return firstStringParam(params, &.{ "clientId", "targetClientId", "id" });
}

fn axisParam(params: ?Value) mux.Axis {
    const axis = stringParam(params, "axis") orelse return if (boolParam(params, "horizontal", false)) .horizontal else .vertical;
    if (std.mem.eql(u8, axis, "horizontal") or std.mem.eql(u8, axis, "h") or std.mem.eql(u8, axis, "-h")) {
        return .horizontal;
    }
    return .vertical;
}

fn envEntriesFromParams(allocator: Allocator, params: ?Value) !?[][]const u8 {
    const params_value = params orelse return null;
    if (params_value != .object) return null;
    const env_value = params_value.object.get("env") orelse params_value.object.get("environment") orelse return null;
    if (env_value != .object) return null;

    var entries = std.ArrayList([]const u8).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var it = env_value.object.iterator();
    while (it.next()) |entry| {
        const value_text = try envValueString(allocator, entry.value_ptr.*);
        defer allocator.free(value_text);
        const env_entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, value_text });
        errdefer allocator.free(env_entry);
        try entries.append(allocator, env_entry);
    }

    return try entries.toOwnedSlice(allocator);
}

fn envValueString(allocator: Allocator, value: Value) ![]u8 {
    return switch (value) {
        .string => |text| allocator.dupe(u8, text),
        .integer => |n| std.fmt.allocPrint(allocator, "{}", .{n}),
        .float => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .bool => |flag| allocator.dupe(u8, if (flag) "true" else "false"),
        .null => allocator.dupe(u8, ""),
        else => protocol.jsonValueAlloc(allocator, value),
    };
}

fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
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

fn peerHasSameEuid(fd: posix.fd_t) bool {
    const uid = peerEuid(fd) orelse return false;
    return uid == sys.geteuid();
}

/// Effective uid of the connected peer, or null when the OS cannot report it.
fn peerEuid(fd: posix.fd_t) ?std.c.uid_t {
    const uid = switch (builtin.os.tag) {
        .linux => linuxPeerUid(fd),
        .macos, .ios, .tvos, .watchos, .visionos => darwinPeerUid(fd),
        else => return null,
    };
    return if (uid == std.math.maxInt(std.c.uid_t)) null else uid;
}

fn linuxPeerUid(fd: posix.fd_t) std.c.uid_t {
    const linux = std.os.linux;
    const UCred = extern struct {
        pid: posix.pid_t,
        uid: std.c.uid_t,
        gid: std.c.gid_t,
    };
    var cred: UCred = undefined;
    var len: std.c.socklen_t = @sizeOf(UCred);
    if (std.c.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, &cred, &len) != 0 or len != @sizeOf(UCred)) {
        return std.math.maxInt(std.c.uid_t);
    }
    return cred.uid;
}

fn darwinPeerUid(fd: posix.fd_t) std.c.uid_t {
    var uid: std.c.uid_t = undefined;
    var gid: std.c.gid_t = undefined;
    if (getpeereid(fd, &uid, &gid) != 0) return std.math.maxInt(std.c.uid_t);
    return uid;
}

extern "c" fn getpeereid(socket: c_int, euid: *std.c.uid_t, egid: *std.c.gid_t) c_int;

/// Internal hooks exposed for the repository's own fuzz suites.
pub const fuzz_hooks = struct {
    pub const Connection = ClientConnection;
    pub const CreateArgs = MuxCreateArgs;
    pub const CreateArgsOpts = CreateArgsOptions;
    pub const max_request_size = max_request_bytes;
    pub const attach_replay_cap = attach_replay_max_bytes;
    pub const broadcast_queue_cap = broadcast_queue_max_bytes;

    pub const muxCreateArgs = muxCreateArgsFromParams;
    pub const envEntries = envEntriesFromParams;
    pub const envValue = envValueString;
    pub const freeEnvEntries = freeStringSlice;
    pub const scrollbackBytes = scrollbackBytesFromParams;
    pub const axis = axisParam;
    pub const sessionId = sessionIdParam;
    pub const paneId = paneIdParam;
    pub const windowId = windowIdParam;
    pub const clientId = clientIdParam;
    pub const boolParamVal = boolParam;
    pub const intParamVal = intParam;
    pub const replayTail = truncatedReplay;
    pub const b64Encode = base64Encode;
    pub const b64Decode = base64Decode;

    pub fn createConnection(allocator: Allocator, io: std.Io, fd: posix.fd_t) !*ClientConnection {
        return ClientConnection.create(allocator, io, fd);
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

    pub fn enqueueBroadcast(conn: *ClientConnection, bytes: []const u8) !void {
        return conn.enqueueBroadcast(bytes);
    }

    pub fn takeQueuedWrite(conn: *ClientConnection) ?[]u8 {
        return conn.takeQueuedWrite();
    }

    pub fn trackMuxClient(conn: *ClientConnection, client_id: []const u8) !void {
        return conn.trackMuxClient(client_id);
    }

    pub fn untrackMuxClient(conn: *ClientConnection, client_id: []const u8) bool {
        return conn.untrackMuxClient(client_id);
    }

    pub fn takeMuxClients(conn: *ClientConnection) std.ArrayList([]u8) {
        return conn.takeMuxClients();
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

    pub fn deinitInMemoryServer(server: *Server) void {
        server.running.store(false, .seq_cst);
        server.closeConnections();
        server.waitForWorkers();
        server.manager.event_sink = null;
        server.manager.deinit();
        server.connections.deinit(server.allocator);
        server.allocator.free(server.socket_path);
    }

    /// Drive a single client connection synchronously until EOF / shutdown.
    /// Takes ownership of `client_fd` (closed when the connection is released).
    pub fn driveClient(server: *Server, client_fd: posix.fd_t) !void {
        const connection = try ClientConnection.create(server.allocator, server.io, client_fd);
        defer connection.release();
        defer connection.close();

        server.registerConnection(connection);
        defer server.unregisterConnection(connection);

        server.handleClient(connection);
    }
};

test "server parses aliases for session id" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"id\":\"sess-1\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess-1", sessionIdParam(parsed.value).?);
}

test "mux create args treats id as title only for session create" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"id\":\"target-pane\",\"rows\":40,\"cols\":120}", .{});
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

test "mux create args converts environment values for native spawn" {
    var parsed = try std.json.parseFromSlice(
        Value,
        std.testing.allocator,
        "{\"env\":{\"TEXT\":\"one\",\"COUNT\":7,\"FLAG\":true,\"EMPTY\":null},\"scrollbackBytes\":4096}",
        .{},
    );
    defer parsed.deinit();

    var args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 4096), args.opts.scrollback_bytes);
    const entries = args.opts.env orelse return error.MissingEnvEntries;
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expect(envContains(entries, "TEXT=one"));
    try std.testing.expect(envContains(entries, "COUNT=7"));
    try std.testing.expect(envContains(entries, "FLAG=true"));
    try std.testing.expect(envContains(entries, "EMPTY="));
}

test "mux create args rejects oversize scrollbackBytes" {
    const max = @import("buffer.zig").max_capacity;
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"scrollbackBytes\":{}}}",
        .{max + 1},
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.ScrollbackBytesTooLarge,
        muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{}),
    );
}

test "axisParam accepts string and boolean horizontal aliases" {
    var horizontal_string = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"axis\":\"-h\"}", .{});
    defer horizontal_string.deinit();
    try std.testing.expectEqual(mux.Axis.horizontal, axisParam(horizontal_string.value));

    var horizontal_bool = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"horizontal\":true}", .{});
    defer horizontal_bool.deinit();
    try std.testing.expectEqual(mux.Axis.horizontal, axisParam(horizontal_bool.value));

    var default_axis = try std.json.parseFromSlice(Value, std.testing.allocator, "{}", .{});
    defer default_axis.deinit();
    try std.testing.expectEqual(mux.Axis.vertical, axisParam(default_axis.value));
}

test "truncatedReplay keeps tail when larger than cap" {
    const full = "abcdefghij";
    try std.testing.expectEqualStrings("ghij", truncatedReplay(full, 4));
    try std.testing.expectEqualStrings("abcdefghij", truncatedReplay(full, 128));
}

const test_io = std.testing.io;

test "peer credential check accepts same-user unix socket peer" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = sys.socketPair() catch return error.SkipZigTest;
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);

    try std.testing.expect(peerHasSameEuid(sockets[0]));
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

    // A pre-existing parent of an explicit socket path must be accepted as-is
    // and left at its original mode (here 0755), never chmod'd or rejected.
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

    try ensureSocketParent(socket_path);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
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

    // The renamed socket is the bound one: a client can connect through it.
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

test "server deinit unlinks its owned socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-owned-socket");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    try std.testing.expect(socketExists(socket_path));

    server.deinit();
    try std.testing.expect(!socketExists(socket_path));
}

test "server connection reader keeps leftover request bytes" {
    const fds = try sys.pipe();
    var read_fd_owned = true;
    defer if (read_fd_owned) sys.close(fds[0]);
    defer sys.close(fds[1]);

    _ = try sys.write(fds[1], "{\"id\":1}\n{\"id\":2}\n");

    var connection = try ClientConnection.create(std.testing.allocator, test_io, fds[0]);
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

    var connection = try ClientConnection.create(std.testing.allocator, test_io, sockets[0]);
    const original_fd = connection.fd;
    connection.close();

    const devnull = try sys.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    defer sys.close(devnull);
    try std.testing.expect(devnull != original_fd);

    connection.release();
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

    _ = try server.manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" });

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
