//! Pane/window lifecycle, layout split ratio, zoom, metadata, and client mode RPC handlers.

const std = @import("std");
const assert = std.debug.assert;
const mux = @import("../mux.zig");
const protocol = @import("../protocol.zig");
const Value = std.json.Value;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const params_mod = @import("params.zig");

const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const clientIdParam = params_mod.clientIdParam;
const optionalBool = params_mod.optionalBool;
const optionalFloat = params_mod.optionalFloat;
const optionalString = params_mod.optionalString;
const paneIdParam = params_mod.paneIdParam;
const windowIdParam = params_mod.windowIdParam;

/// `pane.close`: explicitly close a single pane and reply with the updated snapshot.
pub fn closePane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    _ = try optionalBool(params, "force");
    assert(target.len > 0);

    try self.manager.closePane(target);
    try self.replySnapshot(connection, req);
}

/// `window.close`: explicitly close a window and all panes inside it, returning the snapshot.
pub fn closeWindow(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try windowIdParam(params) orelse return error.InvalidParams;
    _ = try optionalBool(params, "force");
    assert(target.len > 0);

    try self.manager.closeWindow(target);
    try self.replySnapshot(connection, req);
}

/// `pane.resizeSplit`: update a split node's ratio by explicit `splitId` or parent of target pane.
pub fn resizeSplit(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params);
    const split_id = try optionalString(params, "splitId");
    if (target == null and split_id == null) return error.InvalidParams;

    const ratio_f64 = try optionalFloat(params, "ratio");
    const delta_f64 = try optionalFloat(params, "delta");
    if (ratio_f64 == null and delta_f64 == null) return error.InvalidParams;

    const ratio: ?f32 = if (ratio_f64) |v| @floatCast(v) else null;
    const delta: ?f32 = if (delta_f64) |v| @floatCast(v) else null;
    try self.manager.setSplitRatio(target, split_id, ratio, delta);
    try self.replySnapshot(connection, req);
}

/// `pane.zoom`: toggle or explicitly set zoom state for a pane within its window.
pub fn zoomPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const zoomed = try optionalBool(params, "zoomed");
    assert(target.len > 0);

    try self.manager.zoomPane(target, zoomed);
    try self.replySnapshot(connection, req);
}

/// `pane.metadata`: read, merge, replace, or remove string metadata pairs on a pane.
pub fn metadataPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const replace = try optionalBool(params, "replace") orelse false;

    const set_entries = try params_mod.metadataEntriesFromParams(self.allocator, params, "set");
    defer if (set_entries) |entries| params_mod.freeMetadataEntries(self.allocator, entries);

    const remove_keys = try parseStringArrayParam(self.allocator, params, "remove");
    defer if (remove_keys) |keys| self.allocator.free(keys);

    var snap = try self.manager.updatePaneMetadata(
        self.allocator,
        target,
        set_entries,
        remove_keys,
        replace,
    );
    defer snap.deinit(self.allocator);
    assert(snap.pane_id.len > 0);

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    try out.writer.print(
        "{{\"paneId\":{f},\"metadata\":{s}}}",
        .{ std.json.fmt(snap.pane_id, .{}), snap.metadata_json },
    );
    try self.replyRaw(connection, req, out.written());
}

/// `client.setMode`: update `readOnly` and/or `resizePolicy` for an attached logical client.
pub fn setClientMode(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const client_id = try clientIdParam(params) orelse return error.InvalidParams;
    const read_only = try optionalBool(params, "readOnly");
    const policy_str = try optionalString(params, "resizePolicy");
    const policy = if (policy_str) |s| (mux.ResizePolicy.parse(s) orelse return error.InvalidParams) else null;
    assert(client_id.len > 0);

    var snapshot = try self.manager.setClientMode(client_id, read_only, policy);
    defer snapshot.deinit(self.allocator);

    const json = try mux.clientJson(self.allocator, &snapshot);
    defer self.allocator.free(json);
    try self.replyRaw(connection, req, json);
}

fn parseStringArrayParam(
    allocator: std.mem.Allocator,
    params: ?Value,
    key: []const u8,
) !?[][]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const val = p.object.get(key) orelse return null;
    if (val == .null) return null;
    if (val != .array) return error.InvalidParams;

    const list = try allocator.alloc([]const u8, val.array.items.len);
    errdefer allocator.free(list);
    for (val.array.items, 0..) |item, idx| {
        if (item != .string or item.string.len == 0) return error.InvalidParams;
        list[idx] = item.string;
    }
    assert(list.len == val.array.items.len);
    return list;
}

test "parseStringArrayParam validates non-empty string arrays" {
    const allocator = std.testing.allocator;
    var ok_val = try std.json.parseFromSlice(Value, allocator, "{\"remove\":[\"a\",\"b\"]}", .{});
    defer ok_val.deinit();
    const keys = (try parseStringArrayParam(allocator, ok_val.value, "remove")).?;
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);

    var bad_val = try std.json.parseFromSlice(Value, allocator, "{\"remove\":[1]}", .{});
    defer bad_val.deinit();
    try std.testing.expectError(error.InvalidParams, parseStringArrayParam(allocator, bad_val.value, "remove"));
}

test "RPC: pane.resizeSplit, pane.zoom, pane.metadata, client.setMode, pane.close, and window.close" {
    const builtin = @import("builtin");
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const fuzz_hooks = @import("fuzz_hooks.zig").fuzz_hooks;
    const ts = @import("test_support.zig");
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, ts.test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try ts.TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"title\":\"ops\"," ++
        "\"shell\":\"/bin/sh\",\"command\":\"exec cat\",\"metadata\":{\"role\":\"lead\"}}}\n");
    var c1 = try client.response(1);
    defer c1.deinit();
    const r1 = try ts.resultOf(&c1);
    const sess_id = try allocator.dupe(u8, r1.get("sessionId").?.string);
    defer allocator.free(sess_id);
    const win1_id = try allocator.dupe(u8, r1.get("windowId").?.string);
    defer allocator.free(win1_id);
    const p1_id = try allocator.dupe(u8, r1.get("paneId").?.string);
    defer allocator.free(p1_id);

    try client.sendFmt("{{\"id\":2,\"method\":\"pane.split\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"axis\":\"horizontal\",\"shell\":\"/bin/sh\",\"command\":\"exec cat\"}}}}\n", .{p1_id});
    var c2 = try client.response(2);
    defer c2.deinit();
    const p2_id = try allocator.dupe(u8, (try ts.resultOf(&c2)).get("paneId").?.string);
    defer allocator.free(p2_id);

    // pane.resizeSplit + out-of-range InvalidRatio.
    try client.sendFmt("{{\"id\":3,\"method\":\"pane.resizeSplit\",\"params\":{{\"paneId\":\"{s}\",\"ratio\":0.65}}}}\n", .{p2_id});
    var rs = try client.response(3);
    defer rs.deinit();
    _ = try ts.resultOf(&rs);

    try client.sendFmt("{{\"id\":4,\"method\":\"pane.resizeSplit\",\"params\":{{\"paneId\":\"{s}\",\"ratio\":0.99}}}}\n", .{p2_id});
    var rs_bad = try client.response(4);
    defer rs_bad.deinit();
    try ts.expectRpcError(&rs_bad, -32602, "invalid_params", "InvalidRatio");

    // pane.zoom toggle on and off.
    try client.sendFmt("{{\"id\":5,\"method\":\"pane.zoom\",\"params\":{{\"paneId\":\"{s}\"}}}}\n", .{p2_id});
    var z1 = try client.response(5);
    defer z1.deinit();
    const zwin = (try ts.resultOf(&z1)).get("sessions").?.array.items[0].object
        .get("windows").?.array.items[0].object;
    try std.testing.expectEqualStrings(p2_id, zwin.get("zoomedPaneId").?.string);

    // pane.metadata merge + remove.
    try client.sendFmt("{{\"id\":6,\"method\":\"pane.metadata\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"set\":{{\"step\":\"2\"}},\"remove\":[\"role\"]}}}}\n", .{p1_id});
    var md = try client.response(6);
    defer md.deinit();
    const md_map = (try ts.resultOf(&md)).get("metadata").?.object;
    try std.testing.expect(md_map.get("role") == null);
    try std.testing.expectEqualStrings("2", md_map.get("step").?.string);

    // client.attach + client.setMode.
    try client.sendFmt("{{\"id\":7,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n", .{p1_id});
    var att = try client.response(7);
    defer att.deinit();
    const cid = try allocator.dupe(u8, (try ts.resultOf(&att)).get("clientId").?.string);
    defer allocator.free(cid);

    try client.sendFmt("{{\"id\":8,\"method\":\"client.setMode\",\"params\":{{\"clientId\":\"{s}\"," ++
        "\"readOnly\":true,\"resizePolicy\":\"smallest\"}}}}\n", .{cid});
    var cm = try client.response(8);
    defer cm.deinit();
    const cm_obj = try ts.resultOf(&cm);
    try std.testing.expect(cm_obj.get("readOnly").?.bool);
    try std.testing.expectEqualStrings("smallest", cm_obj.get("resizePolicy").?.string);

    // pane.close & window.close + not_found checks.
    try client.sendFmt("{{\"id\":9,\"method\":\"pane.close\",\"params\":{{\"paneId\":\"{s}\"}}}}\n", .{p2_id});
    var pc = try client.response(9);
    defer pc.deinit();
    _ = try ts.resultOf(&pc);

    try client.send("{\"id\":10,\"method\":\"pane.close\",\"params\":{\"paneId\":\"pane-nope\"}}\n");
    var pc_miss = try client.response(10);
    defer pc_miss.deinit();
    try ts.expectRpcError(&pc_miss, -32000, "not_found", "PaneNotFound");

    try client.sendFmt("{{\"id\":11,\"method\":\"window.close\",\"params\":{{\"windowId\":\"{s}\"}}}}\n", .{win1_id});
    var wc = try client.response(11);
    defer wc.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try ts.resultOf(&wc)).get("sessions").?.array.items.len);

    try client.send("{\"id\":12,\"method\":\"window.close\",\"params\":{\"windowId\":\"win-nope\"}}\n");
    var wc_miss = try client.response(12);
    defer wc_miss.deinit();
    try ts.expectRpcError(&wc_miss, -32000, "not_found", "WindowNotFound");
}
