const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const log = @import("../log.zig");
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");
const NativeSession = native_mod.NativeSession;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const params_mod = @import("params.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const TestClient = test_support_mod.TestClient;
const expectRpcError = test_support_mod.expectRpcError;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const max_response_bytes = server_mod.max_response_bytes;
const readLineTimeout = test_support_mod.readLineTimeout;
const resultOf = test_support_mod.resultOf;
const sessionIdParam = params_mod.sessionIdParam;
const test_io = test_support_mod.test_io;

/// Route one request to its method handler. Fails with `InvalidParams` for non-object params.
pub fn dispatch(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    // Positional or scalar params are never valid for this API.
    if (req.params()) |params| switch (params) {
        .object, .null => {},
        else => return error.InvalidParams,
    };
    assert(req.id_json.len > 0);

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
        assert(self.shouldStop());
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

/// Send `value` as the request's JSON result. Notifications get no reply.
pub fn reply(self: *Server, connection: *ClientConnection, req: *const protocol.Request, value: anytype) !void {
    if (protocol.isNotification(req)) return;
    assert(req.id_json.len > 0);
    const response = try protocol.result(self.allocator, req.id_json, value);
    defer self.allocator.free(response);
    assert(response.len > req.id_json.len);
    try self.writeResponse(connection, response);
}

/// Send already-serialized `raw_json` as the result. Fails with `LimitExceeded` when too large.
pub fn replyRaw(
    self: *Server,
    connection: *ClientConnection,
    req: *const protocol.Request,
    raw_json: []const u8,
) !void {
    if (protocol.isNotification(req)) return;
    if (raw_json.len > max_response_bytes) return error.LimitExceeded;
    assert(req.id_json.len > 0);
    const response = try protocol.resultRaw(self.allocator, req.id_json, raw_json);
    defer self.allocator.free(response);
    assert(response.len > raw_json.len);
    try self.writeResponse(connection, response);
}

/// Reply `{"ok":true}`.
pub fn replyOk(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    return self.reply(connection, req, .{ .ok = true });
}

/// Reply with the current mux layout snapshot.
pub fn replySnapshot(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    if (protocol.isNotification(req)) return;
    const snapshot = try self.manager.snapshotJson(self.allocator);
    defer self.allocator.free(snapshot);
    try self.replyRaw(connection, req, snapshot);
}

/// Write one response frame. `LimitExceeded` when oversized, `ConnectionClosed` when the write fails.
pub fn writeResponse(self: *Server, connection: *ClientConnection, response: []const u8) !void {
    _ = self;
    if (response.len > max_response_bytes) return error.LimitExceeded;
    assert(response.len > 0);
    // A failed write closes the connection; there is nobody left to tell.
    connection.write(response) catch return error.ConnectionClosed;
}

/// Send the JSON-RPC error for `err`: the code and `data.kind` come from
/// the shared table, the message is the stable error name.
pub fn writeErrorFor(self: *Server, connection: *ClientConnection, id_json: []const u8, err: anyerror) void {
    // The peer is gone; an error response would only fail again.
    if (err == error.ConnectionClosed) return;
    assert(id_json.len > 0);
    const mapping = errorMappingFor(err);
    if (mapping.kind == .internal) {
        log.warnRateLimited("rpc_internal_error", &internal_error_limiter, .{ .err = err });
    }
    const response = protocol.errorWithKind(
        self.allocator,
        id_json,
        mapping.code,
        @errorName(err),
        mapping.kind,
    ) catch return;
    defer self.allocator.free(response);
    connection.write(response) catch |write_err| {
        log.debug("error_reply_write_failed", .{ .err = write_err });
    };
}

/// Get a required session by ID. Caller MUST call release() on the
/// returned session.
pub fn requiredSession(self: *Server, req: *const protocol.Request) !*NativeSession {
    const id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
    return self.manager.find(id) orelse error.SessionNotFound;
}

/// JSON-RPC code and `data.kind` for a handler error. The shared table in
/// `protocol.errorCodeFor` decides; the entries here are request-shape errors
/// raised by this file's own parsing that the table does not name.
pub fn errorMappingFor(err: anyerror) protocol.ErrorMapping {
    const mapping = protocol.errorCodeFor(err);
    // JSON-RPC reserves negative codes for errors.
    assert(mapping.code < 0);
    if (mapping.kind != .internal) return mapping;
    return switch (err) {
        error.UnsupportedCommand => .{ .code = protocol.ErrorCode.invalid_params, .kind = .invalid_params },
        else => mapping,
    };
}

var internal_error_limiter: log.RateLimiter = .{ .interval_ms = 1000 };

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
    var shutdown_reply = try client.response(6);
    defer shutdown_reply.deinit();
    try std.testing.expect((try resultOf(&shutdown_reply)).get("ok").?.bool);
    // The worker that served the request returns instead of waiting on itself.
    try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, client.fd, 2000));
    try std.testing.expect(!server.running.load(.seq_cst));

    // A concurrent mutation after shutdown began is refused: the server may
    // already have closed the bystander's socket (BrokenPipe / ConnectionResetByPeer),
    // or close it before replying (EndOfStream). Either way, nothing is created.
    if (bystander.send("{\"id\":2,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\"}}\n")) |_| {
        try std.testing.expectError(error.EndOfStream, readLineTimeout(std.testing.allocator, bystander.fd, 2000));
    } else |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => {},
        else => return err,
    }
    try std.testing.expectEqual(@as(usize, 0), server.manager.counts().sessions);
}
