const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const NativeSession = native_mod.NativeSession;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const socket_io_mod = @import("socket_io.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const QueueProbe = test_support_mod.QueueProbe;
const Server = server_mod.Server;
const deleteTestFile = test_support_mod.deleteTestFile;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const monotonicSeconds = socket_io_mod.monotonicSeconds;
const readLineTimeout = test_support_mod.readLineTimeout;
const requireUnixSocketBind = test_support_mod.requireUnixSocketBind;
const sleepMs = test_support_mod.sleepMs;
const tempPath = test_support_mod.tempPath;
const test_io = test_support_mod.test_io;
const waitForFlag = test_support_mod.waitForFlag;

/// The idle interval runs only while there is nothing to keep alive: it
/// restarts whenever a pane is live or a connection holds an attached
/// client, so it starts at the live-to-zero transition.
pub fn shouldExitForIdle(self: *Server) bool {
    if (self.idle_timeout_seconds <= 0) return false;
    assert(self.idle_timeout_seconds > 0);
    if (self.manager.counts().live_panes > 0 or self.anyAttachedClient()) {
        self.touch();
        return false;
    }
    const idle_for = monotonicSeconds(self.io) - self.last_activity_seconds.load(.seq_cst);
    return idle_for >= self.idle_timeout_seconds;
}

/// True when any connection owns at least one mux client.
pub fn anyAttachedClient(self: *Server) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items) |connection| {
        if (connection.attachedClientCount() > 0) return true;
    }
    return false;
}

/// True once the server stops running or the shutdown probe asks it to.
pub fn shouldStop(self: *Server) bool {
    if (!self.running.load(.seq_cst)) return true;
    if (self.shutdown_probe) |probe| return probe();
    return false;
}

/// Record client activity now, restarting the idle timeout.
pub fn touch(self: *Server) void {
    self.last_activity_seconds.store(monotonicSeconds(self.io), .seq_cst);
}

/// Route native events and respawn announcements to this server. The
/// server must not move afterwards.
pub fn installEventSinks(self: *Server) void {
    self.manager.setRespawnListener(.{ .context = self, .notify = Server.handleRespawn });
    self.manager.setEventSink(.{
        .context = self,
        .emit = Server.handleNativeEvent,
        .emit_osc = Server.handleNativeOscEvent,
    });
}

/// Every respawn path (`pane.respawn`, `command.exec`, `key.dispatch`)
/// announces here, after the old generation's events and before the new
/// generation's first event.
pub fn handleRespawn(context: *anyopaque, native: *NativeSession) void {
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
pub fn shutdown(self: *Server) void {
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
pub fn beginStop(self: *Server) void {
    self.mutex.lockUncancelable(self.io);
    self.running.store(false, .seq_cst);
    self.stopping = true;
    assert(!self.running.load(.seq_cst));
    var connections = self.connections;
    self.connections = .empty;
    self.connected_clients.store(0, .release);
    self.mutex.unlock(self.io);

    defer connections.deinit(self.allocator);
    for (connections.items) |connection| {
        connection.close();
        assert(connection.isClosed());
        connection.release();
    }
}

/// Add `connection` to the broadcast set. Returns false when the server is
/// stopping (or out of memory); the caller then closes the connection.
pub fn registerConnection(self: *Server, connection: *ClientConnection) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.stopping) return false;
    self.connections.append(self.allocator, connection.retain()) catch {
        connection.release();
        return false;
    };
    assert(self.connections.items.len > 0);
    self.connected_clients.store(self.connections.items.len, .release);
    return true;
}

/// Detach the connection's mux clients and remove it from the registry.
pub fn unregisterConnection(self: *Server, connection: *ClientConnection) void {
    self.detachConnectionClients(connection);
    // Only this connection's own reader attaches clients to it, and it has
    // stopped reading.
    assert(connection.attachedClientCount() == 0);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items, 0..) |active, index| {
        if (active == connection) {
            const removed = self.connections.swapRemove(index);
            assert(removed == connection);
            self.connected_clients.store(self.connections.items.len, .release);
            removed.release();
            break;
        }
    }
}

/// Detach every mux client `connection` owns from the manager.
pub fn detachConnectionClients(self: *Server, connection: *ClientConnection) void {
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
pub fn findClientOwner(self: *Server, client_id: []const u8) ?*ClientConnection {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items) |connection| {
        if (connection.ownsMuxClient(client_id)) return connection.retain();
    }
    return null;
}

/// `findClientOwner` that also removes the client from its owner.
pub fn takeClientOwner(self: *Server, client_id: []const u8) ?*ClientConnection {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    for (self.connections.items) |connection| {
        if (connection.untrackMuxClient(client_id)) return connection.retain();
    }
    return null;
}

/// Tell owners about clients the manager pruned (pane or session removed,
/// or detached remotely) and stop tracking them.
pub fn drainDetachedClients(self: *Server) void {
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

/// Count one more live writer thread for `waitForWorkers`.
pub fn addActiveWriter(self: *Server) void {
    self.active_mutex.lockUncancelable(self.io);
    _ = self.active_writer_threads.fetchAdd(1, .seq_cst);
    self.active_mutex.unlock(self.io);
}

/// Count one writer thread as finished and wake `waitForWorkers`.
pub fn finishActiveWriter(self: *Server) void {
    self.active_mutex.lockUncancelable(self.io);
    const previous = self.active_writer_threads.fetchSub(1, .seq_cst);
    assert(previous > 0);
    self.active_condition.broadcast(self.io);
    self.active_mutex.unlock(self.io);
}

/// Count one connection worker as finished and wake `waitForWorkers`.
pub fn finishActiveConnection(self: *Server) void {
    self.active_mutex.lockUncancelable(self.io);
    const previous = self.active_connections.fetchSub(1, .seq_cst);
    assert(previous > 0);
    self.active_condition.broadcast(self.io);
    self.active_mutex.unlock(self.io);
}

/// Block until every connection worker and writer thread has finished.
pub fn waitForWorkers(self: *Server) void {
    self.active_mutex.lockUncancelable(self.io);
    defer self.active_mutex.unlock(self.io);
    while (self.active_connections.load(.seq_cst) > 0 or self.active_writer_threads.load(.seq_cst) > 0) {
        self.active_condition.waitUncancelable(self.io, &self.active_mutex);
    }
    assert(self.active_connections.load(.seq_cst) == 0);
    assert(self.active_writer_threads.load(.seq_cst) == 0);
}

/// Test seam that parks the first worker between accept and registration to race shutdown.
pub const LateRegistration = struct {
    pub var calls = std.atomic.Value(usize).init(0);
    pub var entered = std.atomic.Value(bool).init(false);
    pub var released = std.atomic.Value(bool).init(false);
    pub var stop = std.atomic.Value(bool).init(false);

    pub fn reset() void {
        calls.store(0, .seq_cst);
        entered.store(false, .seq_cst);
        released.store(false, .seq_cst);
        stop.store(false, .seq_cst);
    }

    /// Parks the first worker between accept and registration.
    pub fn hook(server: *Server) void {
        if (calls.fetchAdd(1, .seq_cst) != 0) return;
        entered.store(true, .seq_cst);
        while (!released.load(.seq_cst)) server.io.sleep(.fromMilliseconds(1), .awake) catch |err| {
            log.debug("test_hook_sleep_failed", .{ .err = err });
        };
    }

    pub fn probe() bool {
        return stop.load(.seq_cst);
    }

    pub const Runner = struct {
        server: *Server,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn run(self: *Runner) void {
            self.server.run() catch |err| {
                log.debug("test_server_run_failed", .{ .err = err });
            };
            self.done.store(true, .seq_cst);
        }
    };

    pub const Trigger = enum { probe, rpc, idle };

    /// Accept a connection, park its worker before it registers, trigger
    /// shutdown, then release the worker. `run` must return promptly, and
    /// the late connection must be closed rather than served.
    pub fn expectShutdownCompletes(trigger: Trigger) !void {
        if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
        const allocator = std.testing.allocator;
        reset();

        const socket_path = try tempPath(allocator, "zmx-late-register");
        defer allocator.free(socket_path);
        defer deleteTestFile(socket_path);
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
