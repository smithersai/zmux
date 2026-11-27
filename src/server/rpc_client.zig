const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");
const Value = std.json.Value;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const limits_mod = @import("limits.zig");
const params_mod = @import("params.zig");
const rpc_session_mod = @import("rpc_session.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const MuxCreateArgs = params_mod.MuxCreateArgs;
const Server = server_mod.Server;
const TestClient = test_support_mod.TestClient;
const attach_replay_max_bytes = limits_mod.attach_replay_max_bytes;
const base64Decode = rpc_session_mod.base64Decode;
const base64Encode = rpc_session_mod.base64Encode;
const clientIdParam = params_mod.clientIdParam;
const client_switched_method = limits_mod.client_switched_method;
const dimensionParam = params_mod.dimensionParam;
const expectRpcError = test_support_mod.expectRpcError;
const firstStringParam = params_mod.firstStringParam;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const max_response_bytes = server_mod.max_response_bytes;
const muxCreateArgsFromParams = params_mod.muxCreateArgsFromParams;
const objectParam = params_mod.objectParam;
const optionalBool = params_mod.optionalBool;
const optionalString = params_mod.optionalString;
const paneIdParam = params_mod.paneIdParam;
const resultOf = test_support_mod.resultOf;
const test_io = test_support_mod.test_io;

/// Parse an attach's optional `createIfMissing` object, with server
/// defaults applied. The caller deinits the result.
pub fn attachCreateArgs(self: *Server, params: ?Value) !?MuxCreateArgs {
    const create_params = try objectParam(params, "createIfMissing") orelse return null;
    assert(create_params == .object);
    var args = try muxCreateArgsFromParams(self.allocator, create_params, .{ .id_aliases_title = true });
    self.applyCreateDefaults(&args.opts);
    assert(args.opts.rows >= 1 and args.opts.cols >= 1);
    return args;
}

/// `client.attach`: attach a mux client to a pane, creating it when missing, and reply with a replay.
pub fn attachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const rows = try dimensionParam(params, "rows", 24);
    const cols = try dimensionParam(params, "cols", 80);

    var create_args = try self.attachCreateArgs(params);
    defer if (create_args) |*args| args.deinit();

    // Manager attach and connection tracking are one ownership step: a
    // detach or pane removal drained in between would find no owner.
    self.routing_mutex.lockUncancelable(self.io);
    var routing_held = true;
    defer if (routing_held) self.routing_mutex.unlock(self.io);

    const create_opts = if (create_args) |args| args.opts else null;
    var attached = try self.manager.attachOrCreateClient(target, rows, cols, create_opts);
    defer attached.client.deinit(self.allocator);
    const client = &attached.client;
    errdefer _ = self.manager.detachClient(client.id);
    assert(client.id.len > 0);

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
    assert(connection.ownsMuxClient(client.id));
    self.routing_mutex.unlock(self.io);
    routing_held = false;

    // Status, generation, and replay all come from one retained native,
    // read after the write lock: an exit or respawn either shows up here
    // or is announced after this reply, never in between.
    const native = self.manager.find(client.pane_id) orelse return error.PaneNotFound;
    defer native.release();
    try writeAttachReply(self, connection, req, client, attached.created, native);
}

/// Reply to `client.attach` with the pane state and an offset-aligned
/// replay. Caller holds `connection.write_mutex`.
fn writeAttachReply(
    self: *Server,
    connection: *ClientConnection,
    req: *const protocol.Request,
    client: *const mux.ClientSnapshot,
    created: bool,
    native: *native_mod.NativeSession,
) !void {
    const exit = native.finalizedExitInfo();
    const generation = native.generation();
    const tail = try native.scrollbackTail(self.allocator, attach_replay_max_bytes);
    defer self.allocator.free(tail.bytes);
    assert(tail.bytes.len <= attach_replay_max_bytes);
    assert(tail.end_offset - tail.start_offset == tail.bytes.len);
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
        .created = created,
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
    assert(response.len > replay_b64.len);
    try connection.writeLocked(response);
}

/// `client.detach`: detach a mux client and notify its owner when it lives on another connection.
pub fn detachMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
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
pub fn switchMuxClient(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const client_id = try clientIdParam(req.params()) orelse return error.InvalidParams;
    const target = try paneIdParam(req.params()) orelse return error.InvalidParams;

    {
        self.routing_mutex.lockUncancelable(self.io);
        defer self.routing_mutex.unlock(self.io);
        try self.manager.switchClient(client_id, target);

        const native = self.manager.find(target) orelse return error.PaneNotFound;
        defer native.release();
        assert(native.id.len > 0);

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

/// `client.list`: reply with every attached mux client.
pub fn listMuxClients(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const list = try self.manager.clientsJson(self.allocator);
    defer self.allocator.free(list);
    try self.replyRaw(connection, req, list);
}

/// `events.subscribe {"panes":["*"]}` or a list of pane targets: enables
/// `pane_output` for a connection that has no attached client (D1). Each
/// call replaces the previous subscription; an empty list clears it.
pub fn subscribeEvents(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
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
            const native = self.manager.find(item.string) orelse
                break :blk try self.allocator.dupe(u8, item.string);
            defer native.release();
            break :blk try self.allocator.dupe(u8, native.id);
        };
        pane_ids.append(self.allocator, resolved) catch |err| {
            self.allocator.free(resolved);
            return err;
        };
    }
    assert(pane_ids.items.len <= panes_value.array.items.len);

    try connection.setSubscriptions(all, pane_ids.items);
    try self.reply(connection, req, .{ .ok = true, .all = all, .panes = pane_ids.items });
}

/// `key.bind`: bind `key` in a table (default `prefix`) to a command and reply with the bindings.
pub fn bindKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const key = try optionalString(req.params(), "key") orelse return error.InvalidParams;
    const command = try firstStringParam(req.params(), &.{ "command", "cmd" }) orelse return error.InvalidParams;
    const table = try optionalString(req.params(), "table") orelse "prefix";
    const repeat = try optionalBool(req.params(), "repeat") orelse false;
    try self.manager.bindKey(table, key, command, repeat);
    const list = try self.manager.keysJson(self.allocator);
    defer self.allocator.free(list);
    try self.replyRaw(connection, req, list);
}

/// `key.dispatch`: run the binding for `key` on a pane. Replies `handled:false` when unbound.
pub fn dispatchKey(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const pane_id = try paneIdParam(req.params()) orelse return error.InvalidParams;
    const key = try optionalString(req.params(), "key") orelse return error.InvalidParams;
    const table = try optionalString(req.params(), "table") orelse "prefix";
    const command = try self.manager.executeBinding(table, key, pane_id);
    defer if (command) |owned| self.allocator.free(owned);
    if (command == null) return self.reply(connection, req, .{ .handled = false });
    try self.replySnapshot(connection, req);
}

/// `key.list`: reply with every key binding.
pub fn listKeys(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const list = try self.manager.keysJson(self.allocator);
    defer self.allocator.free(list);
    try self.replyRaw(connection, req, list);
}

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
