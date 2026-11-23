const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const version = "0.3.0";

pub const foreground_changed_method = "foreground_changed";
pub const session_exited_method = "session_exited";
pub const pane_output_method = "pane_output";
pub const pane_activity_method = "pane_activity";
pub const pane_bell_method = "pane_bell";

pub const ErrorCode = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const session_error = -32000;
};

pub const Request = struct {
    allocator: Allocator,
    parsed: std.json.Parsed(Value),
    id_json: []u8,
    method: []u8,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.id_json);
        self.allocator.free(self.method);
        self.parsed.deinit();
    }

    pub fn params(self: *const Request) ?Value {
        if (self.parsed.value != .object) return null;
        return self.parsed.value.object.get("params");
    }
};

pub const ForegroundChangedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    comm: []const u8,
    argv: []const []const u8,
};

pub const SessionExitedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
};

pub const PaneOutputParams = struct {
    pane_id: []const u8,
    data_base64: []const u8,
};

pub const PaneActivityParams = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
};

pub const PaneBellParams = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
};

pub fn parseRequest(allocator: Allocator, line: []const u8) !Request {
    var parsed = try std.json.parseFromSlice(Value, allocator, line, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const method_value = parsed.value.object.get("method") orelse return error.InvalidRequest;
    if (method_value != .string) return error.InvalidRequest;

    const id_value = parsed.value.object.get("id") orelse Value.null;
    const id_json = try jsonValueAlloc(allocator, id_value);
    errdefer allocator.free(id_json);

    const method = try allocator.dupe(u8, method_value.string);
    errdefer allocator.free(method);

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .id_json = id_json,
        .method = method,
    };
}

pub fn result(allocator: Allocator, id_json: []const u8, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_json});
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn resultRaw(allocator: Allocator, id_json: []const u8, raw_json: []const u8) ![]u8 {
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":";
    const mid = ",\"result\":";
    const suffix = "}\n";
    const total = prefix.len + id_json.len + mid.len + raw_json.len + suffix.len;
    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    @memcpy(out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out[pos..][0..id_json.len], id_json);
    pos += id_json.len;
    @memcpy(out[pos..][0..mid.len], mid);
    pos += mid.len;
    @memcpy(out[pos..][0..raw_json.len], raw_json);
    pos += raw_json.len;
    @memcpy(out[pos..][0..suffix.len], suffix);
    return out;
}

/// Format a `pane_output` notification directly from raw PTY bytes in a single
/// pre-sized allocation, avoiding intermediate base64 buffers and redundant
/// JSON escape scans over the base64 alphabet.
pub fn paneOutputNotification(allocator: Allocator, pane_id: []const u8, raw_bytes: []const u8) ![]u8 {
    const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":";
    const mid = ",\"data_base64\":\"";
    const suffix = "\"}}\n";
    const b64_len = std.base64.standard.Encoder.calcSize(raw_bytes.len);

    if (isPlainJsonAscii(pane_id)) {
        const total = prefix.len + 1 + pane_id.len + 1 + mid.len + b64_len + suffix.len;
        const out = try allocator.alloc(u8, total);
        var pos: usize = 0;
        @memcpy(out[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        out[pos] = '"';
        pos += 1;
        @memcpy(out[pos..][0..pane_id.len], pane_id);
        pos += pane_id.len;
        out[pos] = '"';
        pos += 1;
        @memcpy(out[pos..][0..mid.len], mid);
        pos += mid.len;
        _ = std.base64.standard.Encoder.encode(out[pos..][0..b64_len], raw_bytes);
        pos += b64_len;
        @memcpy(out[pos..][0..suffix.len], suffix);
        return out;
    }

    var escaped_id: std.Io.Writer.Allocating = try .initCapacity(allocator, pane_id.len + 16);
    defer escaped_id.deinit();
    try std.json.Stringify.value(pane_id, .{}, &escaped_id.writer);
    const id_slice = escaped_id.written();

    const total = prefix.len + id_slice.len + mid.len + b64_len + suffix.len;
    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    @memcpy(out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out[pos..][0..id_slice.len], id_slice);
    pos += id_slice.len;
    @memcpy(out[pos..][0..mid.len], mid);
    pos += mid.len;
    _ = std.base64.standard.Encoder.encode(out[pos..][0..b64_len], raw_bytes);
    pos += b64_len;
    @memcpy(out[pos..][0..suffix.len], suffix);
    return out;
}

/// Format a `client.attach` JSON-RPC result in a single pre-sized allocation,
/// base64-encoding `replay_bytes` directly into the output frame.
pub fn attachResult(
    allocator: Allocator,
    id_json: []const u8,
    client_id: []const u8,
    session_id: []const u8,
    window_id: []const u8,
    pane_id: []const u8,
    rows: u16,
    cols: u16,
    replay_bytes: []const u8,
) ![]u8 {
    var head: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer head.deinit();
    try head.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"clientId\":{f},\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f},\"rows\":{},\"cols\":{},\"replayBase64\":\"",
        .{
            id_json,
            std.json.fmt(client_id, .{}),
            std.json.fmt(session_id, .{}),
            std.json.fmt(window_id, .{}),
            std.json.fmt(pane_id, .{}),
            rows,
            cols,
        },
    );
    const head_slice = head.written();
    const b64_len = std.base64.standard.Encoder.calcSize(replay_bytes.len);
    const suffix = "\"}}\n";
    const out = try allocator.alloc(u8, head_slice.len + b64_len + suffix.len);
    @memcpy(out[0..head_slice.len], head_slice);
    _ = std.base64.standard.Encoder.encode(out[head_slice.len..][0..b64_len], replay_bytes);
    @memcpy(out[head_slice.len + b64_len ..][0..suffix.len], suffix);
    return out;
}

pub fn notification(allocator: Allocator, method: []const u8, params: anytype) ![]u8 {
    if (@TypeOf(params) == PaneOutputParams and
        std.mem.eql(u8, method, pane_output_method) and
        isPlainJsonAscii(params.pane_id) and
        isPlainJsonAscii(params.data_base64))
    {
        const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"";
        const mid = "\",\"data_base64\":\"";
        const suffix = "\"}}\n";
        const total = prefix.len + params.pane_id.len + mid.len + params.data_base64.len + suffix.len;
        const out = try allocator.alloc(u8, total);
        var pos: usize = 0;
        @memcpy(out[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        @memcpy(out[pos..][0..params.pane_id.len], params.pane_id);
        pos += params.pane_id.len;
        @memcpy(out[pos..][0..mid.len], mid);
        pos += mid.len;
        @memcpy(out[pos..][0..params.data_base64.len], params.data_base64);
        pos += params.data_base64.len;
        @memcpy(out[pos..][0..suffix.len], suffix);
        return out;
    }

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try std.json.Stringify.value(method, .{}, &out.writer);
    try out.writer.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn @"error"(allocator: Allocator, id_json: []const u8, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 160);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":",
        .{ id_json, code },
    );
    try std.json.Stringify.value(message, .{}, &out.writer);
    try out.writer.writeAll("}}\n");
    return out.toOwnedSlice();
}

pub fn jsonValueAlloc(allocator: Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn isPlainJsonAscii(bytes: []const u8) bool {
    const Vec = @Vector(16, u8);
    const low: Vec = @splat(0x20);
    const high: Vec = @splat(0x7f);
    const quote: Vec = @splat('"');
    const backslash: Vec = @splat('\\');

    var i: usize = 0;
    while (i + 16 <= bytes.len) : (i += 16) {
        const chunk: Vec = bytes[i..][0..16].*;
        const bad = (chunk < low) | (chunk >= high) | (chunk == quote) | (chunk == backslash);
        if (@reduce(.Or, bad)) return false;
    }
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        if (b < 0x20 or b >= 0x7f or b == '"' or b == '\\') return false;
    }
    return true;
}

test "parse JSON-RPC request" {
    var req = try parseRequest(std.testing.allocator, "{\"id\":7,\"method\":\"daemon.ping\",\"params\":{}}\n");
    defer req.deinit();

    try std.testing.expectEqualStrings("7", req.id_json);
    try std.testing.expectEqualStrings("daemon.ping", req.method);
    try std.testing.expect(req.params() != null);
}

test "parse JSON-RPC request preserves string ids and defaults missing ids to null" {
    var string_id = try parseRequest(std.testing.allocator, "{\"id\":\"abc\",\"method\":\"session.list\"}\n");
    defer string_id.deinit();
    try std.testing.expectEqualStrings("\"abc\"", string_id.id_json);
    try std.testing.expectEqualStrings("session.list", string_id.method);
    try std.testing.expect(string_id.params() == null);

    var notification_like = try parseRequest(std.testing.allocator, "{\"method\":\"pane_output\",\"params\":{}}\n");
    defer notification_like.deinit();
    try std.testing.expectEqualStrings("null", notification_like.id_json);
    try std.testing.expectEqualStrings("pane_output", notification_like.method);
}

test "parse JSON-RPC request rejects missing or non-string methods" {
    try std.testing.expectError(
        error.InvalidRequest,
        parseRequest(std.testing.allocator, "{\"id\":1,\"params\":{}}\n"),
    );
    try std.testing.expectError(
        error.InvalidRequest,
        parseRequest(std.testing.allocator, "{\"id\":1,\"method\":7}\n"),
    );
}

test "format JSON-RPC result and raw result" {
    const json = try result(std.testing.allocator, "9", .{ .ok = true, .name = "work" });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"work\"") != null);

    const raw = try resultRaw(std.testing.allocator, "\"abc\"", "{\"items\":[1,2]}");
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"result\":{\"items\":[1,2]}}\n",
        raw,
    );
}

test "format JSON-RPC error" {
    const json = try @"error"(std.testing.allocator, "null", ErrorCode.method_not_found, "missing");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":-32601") != null);
}

test "format JSON-RPC notification" {
    const json = try notification(std.testing.allocator, foreground_changed_method, ForegroundChangedParams{
        .session_id = "sess-1",
        .pid = 42,
        .comm = "git",
        .argv = &.{ "git", "status" },
    });
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"foreground_changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"session_id\":\"sess-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"argv\":[\"git\",\"status\"]") != null);
}

test "paneOutputNotification matches generic notification wire format" {
    const raw = "hello\x00world\n\x1b[32mok\x1b[0m";
    const fast = try paneOutputNotification(std.testing.allocator, "pane-1", raw);
    defer std.testing.allocator.free(fast);

    const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
    const b64 = try std.testing.allocator.alloc(u8, enc_len);
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);

    const generic = try notification(std.testing.allocator, pane_output_method, PaneOutputParams{
        .pane_id = "pane-1",
        .data_base64 = b64,
    });
    defer std.testing.allocator.free(generic);
    try std.testing.expectEqualStrings(generic, fast);

    // Also verify pane_id with special JSON characters escapes properly.
    const escaped = try paneOutputNotification(std.testing.allocator, "pane\"\\\n1", "hi");
    defer std.testing.allocator.free(escaped);
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, escaped, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("pane\"\\\n1", params.get("pane_id").?.string);
    try std.testing.expectEqualStrings("aGk=", params.get("data_base64").?.string);
}

test "attachResult emits valid single-line JSON with inline base64 replay" {
    const frame = try attachResult(
        std.testing.allocator,
        "42",
        "client-1",
        "sess-1",
        "win-1",
        "pane-1",
        40,
        120,
        "replay data",
    );
    defer std.testing.allocator.free(frame);

    try std.testing.expect(frame[frame.len - 1] == '\n');
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, frame, .{});
    defer parsed.deinit();
    const res = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("client-1", res.get("clientId").?.string);
    try std.testing.expectEqualStrings("pane-1", res.get("paneId").?.string);
    try std.testing.expectEqual(@as(i64, 40), res.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 120), res.get("cols").?.integer);
    try std.testing.expectEqualStrings("cmVwbGF5IGRhdGE=", res.get("replayBase64").?.string);
}
