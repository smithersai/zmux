const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const mux = @import("../mux.zig");
const protocol = @import("../protocol.zig");

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const limits_mod = @import("limits.zig");
const params_mod = @import("params.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const TestClient = test_support_mod.TestClient;
const axisParam = params_mod.axisParam;
const compact_reply_reserve_bytes = limits_mod.compact_reply_reserve_bytes;
const expectRpcError = test_support_mod.expectRpcError;
const firstStringParam = params_mod.firstStringParam;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const muxCreateArgsFromParams = params_mod.muxCreateArgsFromParams;
const optionalBool = params_mod.optionalBool;
const paneIdParam = params_mod.paneIdParam;
const resultOf = test_support_mod.resultOf;
const sessionIdParam = params_mod.sessionIdParam;
const test_io = test_support_mod.test_io;
const windowIdParam = params_mod.windowIdParam;

/// `session.create`: create a session from request params and reply with its handles.
pub fn createSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    // session.create is the only place where `id` should also stand in
    // for the session title: for window.new / pane.split the same `id`
    // field is the existing target alias, so it must NOT be repurposed
    // as the new window/pane title.
    var create_args = try muxCreateArgsFromParams(self.allocator, req.params(), .{ .id_aliases_title = true });
    defer create_args.deinit();
    self.applyCreateDefaults(&create_args.opts);

    var handle = try self.manager.createSessionPane(create_args.opts);
    defer handle.deinit();
    assert(handle.pane_id.len > 0);
    self.replyCreatedSession(connection, req, &handle) catch |err| return self.undoCreate(&handle, err);
}

/// The legacy session info object plus the compact identifiers.
pub fn replyCreatedSession(
    self: *Server,
    connection: *ClientConnection,
    req: *const protocol.Request,
    handle: *const mux.PaneHandle,
) !void {
    const info = try handle.native.infoJson(self.allocator);
    defer self.allocator.free(info);
    const trimmed = std.mem.trimEnd(u8, info, " \t\r\n");
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '}') return error.Unexpected;
    assert(trimmed[trimmed.len - 1] == '}');

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
    assert(out.written().len > trimmed.len);
    try self.replyRaw(connection, req, out.written());
}

/// A create whose response could not be built or exceeded a limit is
/// undone, so an error response always means nothing was committed
/// (M40). A reply lost to a closed connection keeps the work: nobody was
/// told it failed, and a named session stays attachable.
pub fn undoCreate(self: *Server, handle: *const mux.PaneHandle, err: anyerror) anyerror {
    if (err != error.ConnectionClosed) _ = self.manager.terminate(handle.pane_id);
    return err;
}

/// Fill create options the request left unset from server defaults (`default_cwd`).
pub fn applyCreateDefaults(self: *Server, opts: *mux.CreateOptions) void {
    if (opts.cwd == null) opts.cwd = self.default_cwd;
    assert(opts.cwd != null or self.default_cwd == null);
}

/// `mux.snapshot`: reply with the current layout snapshot.
pub fn snapshotMux(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    try self.replySnapshot(connection, req);
}

/// `window.new`: open a window in the target session and reply with its handles.
pub fn newWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const session_id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
    var create_args = try muxCreateArgsFromParams(self.allocator, req.params(), .{});
    defer create_args.deinit();
    self.applyCreateDefaults(&create_args.opts);
    var out = try self.reserveCompactReply(req);
    defer out.deinit();
    var handle = try self.manager.newWindow(session_id, create_args.opts);
    defer handle.deinit();
    assert(handle.window_id.len > 0);
    self.replyPaneHandle(connection, req, &handle, &out) catch |err| return self.undoCreate(&handle, err);
}

/// `pane.split`: split the target pane along an axis and reply with the new pane's handles.
pub fn splitPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
    const axis = try axisParam(req.params());
    var create_args = try muxCreateArgsFromParams(self.allocator, req.params(), .{});
    defer create_args.deinit();
    self.applyCreateDefaults(&create_args.opts);
    var out = try self.reserveCompactReply(req);
    defer out.deinit();
    var handle = try self.manager.splitPane(pane_id, axis, create_args.opts);
    defer handle.deinit();
    assert(handle.pane_id.len > 0);
    self.replyPaneHandle(connection, req, &handle, &out) catch |err| return self.undoCreate(&handle, err);
}

/// Reserve the buffer for a compact mutation result before the mutation
/// commits, so building the reply afterwards does not allocate.
pub fn reserveCompactReply(self: *Server, req: *const protocol.Request) !std.Io.Writer.Allocating {
    const capacity = compact_reply_reserve_bytes + req.id_json.len;
    const out = try std.Io.Writer.Allocating.initCapacity(self.allocator, capacity);
    assert(out.writer.buffer.len == capacity);
    return out;
}

/// Compact mutation result: identifiers only, written into the buffer
/// reserved by `reserveCompactReply`, so the reply cannot fail on the size
/// of the whole mux snapshot after the work is committed.
pub fn replyPaneHandle(
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
    assert(out.written().len > req.id_json.len);
    try self.writeResponse(connection, out.written());
}

/// `pane.select`: focus the target pane and reply with the snapshot.
pub fn selectPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
    try self.manager.selectPane(pane_id);
    try self.replySnapshot(connection, req);
}

/// `window.select`: focus the target window and reply with the snapshot.
pub fn selectWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const window_id = try windowIdParam(req.params()) orelse return error.InvalidParams;
    try self.manager.selectWindow(window_id);
    try self.replySnapshot(connection, req);
}

/// `session.rename`: rename the target session and reply with the snapshot.
pub fn renameSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const session_id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
    const name = try firstStringParam(req.params(), &.{ "name", "title" }) orelse return error.InvalidParams;
    try self.manager.renameSession(session_id, name);
    try self.replySnapshot(connection, req);
}

/// `window.rename`: rename the target window and reply with the snapshot.
pub fn renameWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const window_id = try windowIdParam(req.params()) orelse return error.InvalidParams;
    const name = try firstStringParam(req.params(), &.{ "name", "title" }) orelse return error.InvalidParams;
    try self.manager.renameWindow(window_id, name);
    try self.replySnapshot(connection, req);
}

/// `pane.rename`: retitle the target pane (custom by default) and reply with the snapshot.
pub fn renamePane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
    const title = try firstStringParam(req.params(), &.{ "title", "name" }) orelse return error.InvalidParams;
    const custom = try optionalBool(req.params(), "custom") orelse true;
    try self.manager.renamePane(pane_id, title, custom);
    try self.replySnapshot(connection, req);
}

/// `pane.respawn`: restart the target pane, killing a live child only with `kill`.
pub fn respawnPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
    // `kill` defaults to false: respawning a running pane is a conflict
    // (`PaneRunning`) unless the caller asks for the child to be killed.
    const kill = try optionalBool(req.params(), "kill") orelse false;
    // The manager's respawn listener (`handleRespawn`) announces it.
    const active = try self.manager.respawnPane(pane_id, .{ .kill = kill });
    defer active.release();
    try self.replySnapshot(connection, req);
}

/// `command.exec`: run a mux command line against the target pane and reply with the snapshot.
pub fn execCommand(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
    const command = try firstStringParam(req.params(), &.{ "command", "line" }) orelse return error.InvalidParams;
    try self.manager.executeCommandLine(command, pane_id);
    try self.replySnapshot(connection, req);
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
