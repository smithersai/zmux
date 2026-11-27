const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const limits_mod = @import("limits.zig");
const params_mod = @import("params.zig");
const rpc_screen_mod = @import("rpc_screen.zig");
const test_support_mod = @import("test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const TestClient = test_support_mod.TestClient;
const capture_envelope_reserve_bytes = limits_mod.capture_envelope_reserve_bytes;
const capture_max_bytes = limits_mod.capture_max_bytes;
const dimensionParam = params_mod.dimensionParam;
const firstStringParam = params_mod.firstStringParam;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;
const max_response_bytes = server_mod.max_response_bytes;
const optionalBool = params_mod.optionalBool;
const optionalInt = params_mod.optionalInt;
const optionalString = params_mod.optionalString;
const resultOf = test_support_mod.resultOf;
const sessionIdParam = params_mod.sessionIdParam;
const sleepMs = test_support_mod.sleepMs;
const test_io = test_support_mod.test_io;

/// `session.terminate`: kill the named session. Fails with `SessionNotFound` for an unknown id.
pub fn terminateSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const id = try sessionIdParam(req.params()) orelse return error.InvalidParams;
    assert(req.method.len > 0);
    if (!self.manager.terminate(id)) return error.SessionNotFound;
    try self.replyOk(connection, req);
}

/// `session.list`: reply with every session as JSON.
pub fn listSessions(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const list = try self.manager.listJson(self.allocator);
    defer self.allocator.free(list);
    try self.replyRaw(connection, req, list);
}

/// `session.info`: reply with one session's details.
pub fn infoSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const active = try self.requiredSession(req);
    defer active.release();

    const info = try active.infoJson(self.allocator);
    defer self.allocator.free(info);
    try self.replyRaw(connection, req, info);
}

/// `session.resize`: set a session's terminal size (defaults 80x24).
pub fn resizeSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const cols = try dimensionParam(req.params(), "cols", 80);
    const rows = try dimensionParam(req.params(), "rows", 24);
    assert(cols >= 1 and rows >= 1);
    const active = try self.requiredSession(req);
    defer active.release();

    // An exited pane has no terminal to resize: the caller learns that
    // (`terminated`) and can respawn, instead of a silent success.
    if (!active.isRunning()) return error.SessionTerminated;
    // Through the manager so the pane's spawn spec records the size and a
    // respawn comes back at the same dimensions.
    try self.manager.resizePane(active.id, rows, cols);
    try self.replyOk(connection, req);
}

/// `session.capture`: reply with the last `lines` lines (default 200) as text and base64, size-bounded.
pub fn captureSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const lines = try optionalInt(usize, req.params(), "lines") orelse 200;
    const format = try optionalString(req.params(), "format");
    const active = try self.requiredSession(req);
    defer active.release();

    if (format) |fmt| {
        if (!std.mem.eql(u8, fmt, "raw")) {
            return rpc_screen_mod.captureSessionFormatted(self, connection, req, active, lines, fmt);
        }
    }

    const captured = try active.captureBounded(self.allocator, lines, capture_max_bytes);
    defer self.allocator.free(captured);
    // Keep the newest bytes whose worst-case encoding fits the response
    // cap, so a control-heavy capture returns a bounded, useful tail
    // instead of being built at ~6x and then rejected.
    const reserve = capture_envelope_reserve_bytes +| req.id_json.len +| active.id.len;
    const text = captured[captureTailStart(captured, max_response_bytes -| reserve)..];
    const text_b64 = try base64Encode(self.allocator, text);
    defer self.allocator.free(text_b64);

    // `text` is always a JSON string (invalid UTF-8 becomes U+FFFD);
    // `textBase64` carries the exact bytes.
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try std.json.Stringify.value(active.id, .{}, &out.writer);
    try out.writer.writeAll(",\"text\":");
    try protocol.writeJsonStringLossy(&out.writer, text);
    try out.writer.writeAll(",\"textBase64\":");
    try std.json.Stringify.value(text_b64, .{}, &out.writer);
    try out.writer.writeAll("}");
    try self.replyRaw(connection, req, out.written());
}

/// `session.send`: write text or base64 bytes to a session, optionally followed by Enter.
pub fn sendSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const encoded = try firstStringParam(params, &.{ "dataBase64", "data_base64" });
    const text = try optionalString(params, "text");
    const enter = try optionalBool(params, "enter") orelse false;
    const active = try self.requiredSession(req);
    defer active.release();

    if (encoded) |data| {
        const bytes = base64Decode(self.allocator, data) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidParams,
        };
        defer self.allocator.free(bytes);
        try active.writeInput(bytes);
    } else {
        try active.send(text orelse "", enter);
    }
    try self.replyOk(connection, req);
}

/// `session.sendKey`: send one named key to a session.
pub fn sendKeySession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const key = try optionalString(req.params(), "key") orelse return error.InvalidParams;
    const active = try self.requiredSession(req);
    defer active.release();

    // `UnknownKey` maps to invalid params; I/O failures keep their own
    // kind through the shared error table.
    try active.sendKey(key);
    try self.replyOk(connection, req);
}

/// Start of the longest tail of `text` whose `text` (lossy JSON string) plus
/// `textBase64` encodings fit in `budget` bytes, costing every byte at its
/// worst case: 6 for a control byte (`\u00XX`), 2 for a quote or backslash,
/// 3 for a byte at or above 0x80 (an invalid byte becomes U+FFFD).
pub fn captureTailStart(text: []const u8, budget: usize) usize {
    var escaped: usize = 2; // the quotes
    var start = text.len;
    while (start > 0) {
        const byte = text[start - 1];
        const cost: usize = switch (byte) {
            0...0x1f, 0x7f => 6,
            '"', '\\' => 2,
            0x80...0xff => 3,
            else => 1,
        };
        const n = text.len - start + 1;
        const base64_len = 4 * ((n + 2) / 3) + 2;
        if (escaped + cost + base64_len > budget) break;
        escaped += cost;
        start -= 1;
    }
    assert(start <= text.len);
    return start;
}

/// The last `max_bytes` of `scrollback`, or all of it when it already fits.
pub fn truncatedReplay(scrollback: []const u8, max_bytes: usize) []const u8 {
    if (scrollback.len <= max_bytes) return scrollback;
    const tail = scrollback[scrollback.len - max_bytes ..];
    assert(tail.len == max_bytes);
    return tail;
}

/// Standard base64 of `bytes` in a new allocation the caller frees.
pub fn base64Encode(allocator: Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    const encoded = encoder.encode(out, bytes);
    assert(encoded.len == out.len);
    return out;
}

/// Decode standard base64 into a new allocation the caller frees. Fails on malformed input.
pub fn base64Decode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

test "session.capture returns lossy text and the exact bytes" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"printf 'a\\\\377b'; exec cat\"}}\n");
    var created = try client.response(1);
    defer created.deinit();
    const pane_id = try allocator.dupe(u8, (try resultOf(&created)).get("paneId").?.string);
    defer allocator.free(pane_id);

    const deadline = sys.monotonicMs() + 5000;
    var id: i64 = 2;
    while (true) : (id += 1) {
        try client.sendFmt("{{\"id\":{},\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":50}}}}\n", .{ id, pane_id });
        var captured = try client.response(id);
        defer captured.deinit();
        const result = try resultOf(&captured);
        const exact = try base64Decode(allocator, result.get("textBase64").?.string);
        defer allocator.free(exact);
        if (std.mem.indexOf(u8, exact, "a\xffb") != null) {
            // `text` is valid UTF-8 JSON with the bad byte replaced.
            try std.testing.expect(std.mem.indexOf(u8, result.get("text").?.string, "a\u{FFFD}b") != null);
            break;
        }
        if (sys.monotonicMs() >= deadline) return error.CaptureNeverShowedOutput;
        sleepMs(20);
    }
}

test "M10: a control-heavy capture keeps a tail whose encoding fits the response cap" {
    const allocator = std.testing.allocator;
    const raw = try allocator.alloc(u8, capture_max_bytes);
    defer allocator.free(raw);
    @memset(raw, 0x01);
    raw[raw.len - 1] = '"';
    raw[raw.len - 2] = 0xff;

    const budget = max_response_bytes - capture_envelope_reserve_bytes;
    const start = captureTailStart(raw, budget);
    try std.testing.expect(start > 0);
    try std.testing.expect(start < raw.len);
    const text = raw[start..];

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try protocol.writeJsonStringLossy(&out.writer, text);
    const b64 = try base64Encode(allocator, text);
    defer allocator.free(b64);
    try std.testing.expect(out.written().len + b64.len + 2 <= budget);
    // Plain text is never trimmed below the cap.
    try std.testing.expectEqual(@as(usize, 0), captureTailStart("hello", budget));
}

test "truncatedReplay keeps tail when larger than cap" {
    const full = "abcdefghij";
    try std.testing.expectEqualStrings("ghij", truncatedReplay(full, 4));
    try std.testing.expectEqualStrings("abcdefghij", truncatedReplay(full, 128));
}

test "events.subscribe enables pane_output for an unattached observer only" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    fuzz_hooks.enableEvents(&server);
    var owner = try TestClient.start(&server);
    defer owner.stop();
    var subscriber = try TestClient.start(&server);
    defer subscriber.stop();
    var bystander = try TestClient.start(&server);
    defer bystander.stop();

    try owner.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"title\":\"feed\",\"shell\":\"/bin/sh\",\"command\":\"stty -echo; exec cat\"}}\n");
    var created = try owner.response(1);
    defer created.deinit();
    const info = try resultOf(&created);
    // Legacy fields and the compact identifiers are both present.
    try std.testing.expect(info.get("pid").? == .integer);
    try std.testing.expect(info.get("sessionId").? == .string);
    try std.testing.expect(info.get("windowId").? == .string);
    try std.testing.expectEqual(@as(i64, 0), info.get("generation").?.integer);
    try std.testing.expectEqualStrings(info.get("id").?.string, info.get("paneId").?.string);
    const pane_id = try allocator.dupe(u8, info.get("paneId").?.string);
    defer allocator.free(pane_id);

    // Subscribe by session name; the server resolves it to the pane id.
    try subscriber.send("{\"id\":1,\"method\":\"events.subscribe\",\"params\":{\"panes\":[\"feed\"]}}\n");
    var subscribed = try subscriber.response(1);
    defer subscribed.deinit();
    const sub_result = try resultOf(&subscribed);
    try std.testing.expect(sub_result.get("ok").?.bool);
    try std.testing.expectEqualStrings(pane_id, sub_result.get("panes").?.array.items[0].string);

    // The bystander is registered (it has been answered) but unsubscribed.
    try bystander.send("{\"id\":1,\"method\":\"daemon.ping\"}\n");
    var ping = try bystander.response(1);
    ping.deinit();

    try owner.sendFmt("{{\"id\":2,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"scoped-output\",\"enter\":true}}}}\n", .{pane_id});
    var sent = try owner.response(2);
    sent.deinit();

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    while (std.mem.indexOf(u8, seen.items, "scoped-output") == null) {
        var event = try subscriber.notification("pane_output");
        defer event.deinit();
        const params = event.value.object.get("params").?.object;
        try std.testing.expectEqualStrings(pane_id, params.get("pane_id").?.string);
        const data = try base64Decode(allocator, params.get("data_base64").?.string);
        defer allocator.free(data);
        try seen.appendSlice(allocator, data);
    }

    // A global lifecycle event marks the end of the window: neither the
    // bystander nor the unattached owner received any pane_output before it.
    try owner.sendFmt("{{\"id\":3,\"method\":\"pane.respawn\",\"params\":{{\"paneId\":\"{s}\",\"kill\":true}}}}\n", .{pane_id});
    for ([_]*TestClient{ &bystander, &owner }) |observer| {
        while (true) {
            var line = try observer.nextLine();
            defer line.deinit();
            const method = line.value.object.get("method") orelse continue;
            try std.testing.expect(!std.mem.eql(u8, method.string, "pane_output"));
            if (std.mem.eql(u8, method.string, protocol.pane_respawned_method)) break;
        }
    }
}
