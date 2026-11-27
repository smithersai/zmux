const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const posix = std.posix;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const lifecycle_mod = @import("lifecycle.zig");
const limits_mod = @import("limits.zig");
const socket_io_mod = @import("socket_io.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const LateRegistration = lifecycle_mod.LateRegistration;
const Server = server_mod.Server;
const TestClient = test_support_mod.TestClient;
const accept_backoff_ms = limits_mod.accept_backoff_ms;
const defaultPeerEuid = socket_io_mod.defaultPeerEuid;
const expectRpcError = test_support_mod.expectRpcError;
const first_frame_deadline_ms = limits_mod.first_frame_deadline_ms;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const max_client_connections = server_mod.max_client_connections;
const max_request_bytes = limits_mod.max_request_bytes;
const monotonicSeconds = socket_io_mod.monotonicSeconds;
const partial_frame_deadline_ms = limits_mod.partial_frame_deadline_ms;
const readLineTimeout = test_support_mod.readLineTimeout;
const requireUnixSocketBind = test_support_mod.requireUnixSocketBind;
const setSocketSendTimeout = socket_io_mod.setSocketSendTimeout;
const tempPath = test_support_mod.tempPath;
const test_io = test_support_mod.test_io;
const waitForFlag = test_support_mod.waitForFlag;
const writeAllDeadline = socket_io_mod.writeAllDeadline;

/// Accept and serve connections until a stop condition, then shut down on this thread.
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
                self.io.sleep(.fromMilliseconds(accept_backoff_ms), .awake) catch |sleep_err| {
                    log.debug("accept_backoff_sleep_failed", .{ .err = sleep_err });
                };
                continue;
            },
        };
        assert(client_fd >= 0);
        self.admit(client_fd);
    }
}

/// Open the spare descriptor when it is not held. Failure is expected
/// while the table is full; the next loop iteration tries again.
pub fn armSpareFd(self: *Server) void {
    if (self.spare_fd >= 0) return;
    self.spare_fd = sys.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return;
}

/// Close the spare descriptor, if held. Idempotent.
pub fn releaseSpareFd(self: *Server) void {
    if (self.spare_fd < 0) return;
    sys.close(self.spare_fd);
    self.spare_fd = -1;
    assert(self.spare_fd < 0);
}

/// On descriptor exhaustion, trade the spare descriptor for one more
/// accepted connection. Null when `err` is something else, no spare is
/// held, or the retry fails too.
pub fn acceptWithSpareFd(self: *Server, err: sys.AcceptError) ?posix.fd_t {
    if (err != error.ProcessFdQuotaExceeded and err != error.SystemFdQuotaExceeded) return null;
    if (self.spare_fd < 0) return null;
    self.releaseSpareFd();
    assert(self.spare_fd < 0);
    const client_fd = self.accept_fn(self.listener_fd) catch return null;
    _ = self.spare_fd_admissions.fetchAdd(1, .monotonic);
    log.warnRateLimited("accept_used_spare_fd", &accept_error_limiter, .{
        .active_connections = self.active_connections.load(.seq_cst),
    });
    return client_fd;
}

/// Take ownership of an accepted descriptor: check credentials and the
/// connection limit, then hand it to a worker thread.
pub fn admit(self: *Server, client_fd: posix.fd_t) void {
    assert(client_fd >= 0);
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
pub fn peerAllowed(self: *Server, client_fd: posix.fd_t) bool {
    const peer_euid = self.peer_euid_fn(client_fd);
    if (peer_euid != null and peer_euid.? == sys.geteuid()) return true;
    log.warnRateLimited("peer_cred_rejected", &peer_rejected_limiter, .{
        .peer_euid = peer_euid,
        .euid = sys.geteuid(),
        .socket_path = self.socket_path,
    });
    return false;
}

/// Best-effort `LimitExceeded` reply to a connection refused at the connection limit.
pub fn writeConnectionLimitError(fd: posix.fd_t) void {
    const message =
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"LimitExceeded\"," ++
        "\"data\":{\"kind\":\"limit\",\"detail\":\"server connection limit reached\"}}}\n";
    comptime assert(message.len < 512);
    writeAllDeadline(fd, message, 250) catch |err| {
        log.debug("connection_limit_reply_failed", .{ .err = err });
    };
}

/// Worker thread body: wrap `client_fd` in a connection, serve it, then release it.
pub fn handleClientThread(self: *Server, client_fd: posix.fd_t) void {
    assert(client_fd >= 0);
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

/// Read and dispatch frames until the client disconnects, the server stops, or a deadline passes.
pub fn handleClient(self: *Server, connection: *ClientConnection) void {
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
        assert(line.len <= max_request_bytes);

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
pub fn readFrame(self: *Server, connection: *ClientConnection, first_deadline: ?std.Io.Timestamp) !?[]u8 {
    const reader = &connection.reader;
    assert(reader.start <= reader.end);
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

var accept_error_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

var connection_limit_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

var peer_rejected_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

var spawn_failed_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

fn foreignPeerEuid(_: posix.fd_t) ?sys.uid_t {
    return sys.geteuid() +% 1;
}

fn unknownPeerEuid(_: posix.fd_t) ?sys.uid_t {
    return null;
}

/// `accept` that reports a full descriptor table while the server still
/// holds its spare descriptor.
const ExhaustedAccept = struct {
    pub var server: ?*Server = null;
    pub var refused: std.atomic.Value(usize) = .init(0);

    pub fn accept(listener_fd: posix.fd_t) sys.AcceptError!posix.fd_t {
        if (server.?.spare_fd >= 0) {
            _ = refused.fetchAdd(1, .seq_cst);
            return error.ProcessFdQuotaExceeded;
        }
        return sys.accept(listener_fd);
    }
};

test "peer credential check accepts same-user unix socket peer" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const sockets = sys.socketPair() catch return error.SkipZigTest;
    defer sys.close(sockets[0]);
    defer sys.close(sockets[1]);

    try std.testing.expectEqual(@as(?sys.uid_t, sys.geteuid()), defaultPeerEuid(sockets[0]));
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
