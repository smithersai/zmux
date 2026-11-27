const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const limits_mod = @import("limits.zig");
const payload_mod = @import("payload.zig");
const rpc_session_mod = @import("rpc_session.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const Payload = payload_mod.Payload;
const QueueProbe = test_support_mod.QueueProbe;
const Server = server_mod.Server;
const base64Encode = rpc_session_mod.base64Encode;
const broadcast_queue_max_bytes = limits_mod.broadcast_queue_max_bytes;
const control_queue_max_bytes = limits_mod.control_queue_max_bytes;
const emitOutput = test_support_mod.emitOutput;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const max_client_connections = server_mod.max_client_connections;
const max_event_bytes = limits_mod.max_event_bytes;
const parseJson = test_support_mod.parseJson;
const test_io = test_support_mod.test_io;

/// Retained snapshot of the registered connections. With `pane_filter`,
/// only connections that receive that pane's output (D1).
pub fn snapshotConnections(self: *Server, pane_filter: ?[]const u8) !Snapshot {
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
    assert(slots.len == total);
    var count: usize = 0;
    for (self.connections.items) |connection| {
        if (pane_filter) |pane_id| {
            if (!connection.wantsPaneOutput(pane_id)) continue;
        }
        slots[count] = connection.retain();
        count += 1;
    }
    assert(count <= total);
    snapshot.len = count;
    return snapshot;
}

/// Connections captured by `snapshotConnections`. Up to
/// `max_client_connections` live on the stack, so routing an event
/// allocates nothing.
pub const Snapshot = struct {
    stack: [max_client_connections]*ClientConnection = undefined,
    heap: ?[]*ClientConnection = null,
    len: usize = 0,

    fn items(self: *Snapshot) []*ClientConnection {
        const slots = if (self.heap) |heap| heap else self.stack[0..];
        assert(self.len <= slots.len);
        return slots[0..self.len];
    }
};

/// Release every connection reference in `snapshot` and free its heap storage.
pub fn releaseSnapshot(self: *Server, snapshot: *Snapshot) void {
    for (snapshot.items()) |connection| connection.release();
    if (snapshot.heap) |heap| self.allocator.free(heap);
    snapshot.* = .{};
    assert(snapshot.len == 0 and snapshot.heap == null);
}

/// Queue `payload` on one connection. Any terminal failure closes that
/// connection (its reader thread then unregisters it); other connections
/// are unaffected.
pub fn deliver(self: *Server, connection: *ClientConnection, payload: *Payload) void {
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
pub fn broadcastNotification(self: *Server, method: []const u8, params: anytype) void {
    // Skip serialization entirely when nobody can receive it.
    if (self.connected_clients.load(.acquire) == 0) return;
    const bytes = protocol.notification(self.allocator, method, params) catch return;
    self.broadcastControl(bytes);
}

/// Takes ownership of `bytes`.
pub fn broadcastControl(self: *Server, bytes: []u8) void {
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
    assert(bytes.len <= max_event_bytes);
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
pub fn broadcastPaneOutput(self: *Server, params: native_mod.PaneOutputEvent) void {
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

/// Event sink for native sessions: turns each event into a client notification. `context` is the `*Server`.
pub fn handleNativeEvent(context: *anyopaque, event: native_mod.Event) void {
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

/// Tell `owner` that its mux client `client_id` was detached, and why.
pub fn notifyClientDetached(self: *Server, owner: *ClientConnection, client_id: []const u8, reason: []const u8) void {
    assert(reason.len > 0);
    self.notifyConnection(owner, protocol.client_detached_method, protocol.ClientDetachedParams{
        .client_id = client_id,
        .reason = reason,
    });
}

/// Queue one notification on a single connection.
pub fn notifyConnection(self: *Server, connection: *ClientConnection, method: []const u8, params: anytype) void {
    assert(method.len > 0);
    const bytes = protocol.notification(self.allocator, method, params) catch return;
    assert(bytes.len > method.len);
    const payload = Payload.create(self.allocator, bytes, null) catch {
        self.allocator.free(bytes);
        return;
    };
    defer payload.release();
    self.deliver(connection, payload);
}

var backlog_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

var event_dropped_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

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
