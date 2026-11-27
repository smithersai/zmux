//! Wire helpers for `zmux-connect`: limits, request ids, JSON-RPC frames,
//! JSON field access and base64.

const std = @import("std");
const assert = std.debug.assert;

const test_io = std.testing.io;

/// Size of the stdin read buffer and line reader staging chunk.
pub const buffer_size: usize = 32 * 1024;
/// Largest JSON-RPC line accepted from the daemon.
pub const rpc_line_max: usize = 16 * 1024 * 1024;
/// Largest outbound byte queue toward the daemon.
pub const outbound_max: usize = 1024 * 1024;
/// Budget for one blocking write to the daemon or stdout.
pub const write_timeout_ms: i64 = 2_000;
/// Budget for a spawned daemon to accept connections.
pub const spawn_timeout_ms: i64 = 4_000;
/// Longest wait for a partial frame to complete.
pub const partial_frame_timeout_ms: i64 = 30_000;
/// Quiet period after piped stdin EOF before exiting.
pub const pipe_quiet_ms: i64 = 2_000;
/// Longest wait for piped `session.send` replies.
pub const send_reply_timeout_ms: i64 = 30_000;
/// Most unacknowledged piped `session.send` requests.
pub const max_pending_sends = 256;
/// Poll timeout of one run loop turn.
pub const run_loop_poll_timeout_ms: i32 = 100;
/// Budget for the attach bootstrap RPC exchange.
pub const bootstrap_response_timeout_ms: i64 = 10_000;
/// Budget for the `daemon.ping` version handshake.
pub const version_handshake_timeout_ms: i64 = 2_000;

/// Default detach chord: Ctrl-\ (0x1C). Chosen because it maps to SIGQUIT,
/// which raw mode disables anyway, so it is rarely wanted by the attached
/// program and makes a safe single-byte escape hatch. Configurable via
/// --detach-key (ctrl-<letter> | none).
pub const default_detach_key: u8 = 0x1C;

/// Request id of the `daemon.ping` handshake.
pub const ping_rpc_id: u32 = 100;
/// Request id of a management verb call.
pub const verb_rpc_id: u32 = 1;
/// Request id of the first `client.attach`.
pub const attach_rpc_id: u32 = 1;
/// First request id used by the interactive loop.
pub const first_interactive_id: u32 = 101;

/// A parsed JSON-RPC response that owns its line.
pub const Response = struct {
    line: []u8,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.line);
    }

    pub fn result(self: Response) std.json.Value {
        return jsonField(self.parsed.value, "result");
    }

    pub fn rpcError(self: Response) ?RpcError {
        return RpcError.fromEnvelope(self.parsed.value);
    }
};

/// The message and `data.kind` of a JSON-RPC error.
pub const RpcError = struct {
    message: []const u8,
    kind: ?[]const u8,

    pub fn fromEnvelope(envelope: std.json.Value) ?RpcError {
        const err = jsonField(envelope, "error");
        if (err != .object) return null;
        return .{
            .message = jsonObjectString(err, "message") orelse "unknown RPC error",
            .kind = jsonObjectString(jsonField(err, "data"), "kind"),
        };
    }

    pub fn is(self: RpcError, kind: []const u8) bool {
        return std.mem.eql(u8, self.kind orelse return false, kind);
    }
};

/// Serialize one newline-terminated JSON-RPC request.
pub fn buildFrame(allocator: std.mem.Allocator, id: u32, method: []const u8, params: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(.{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params,
    }, .{ .emit_null_optional_fields = false })});
}

/// Build a `session.send` frame for `input`.
pub fn buildSendFrame(allocator: std.mem.Allocator, id: u32, session_id: []const u8, input: []const u8) ![]u8 {
    if (!isPlainJsonAscii(session_id)) {
        const encoded = try base64Encode(allocator, input);
        defer allocator.free(encoded);
        return buildFrame(allocator, id, "session.send", .{ .sessionId = session_id, .dataBase64 = encoded });
    }
    const encoder = std.base64.standard.Encoder;
    var id_buf: [std.fmt.count("{d}", .{std.math.maxInt(u32)})]u8 = undefined;
    const id_text = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
    assert(id_text.len > 0);
    const parts = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":",
        id_text,
        ",\"method\":\"session.send\",\"params\":{\"sessionId\":\"",
        session_id,
        "\",\"dataBase64\":\"",
    };
    const suffix = "\"}}\n";
    var head_len: usize = 0;
    for (parts) |part| head_len += part.len;
    const b64_len = encoder.calcSize(input.len);
    const frame = try allocator.alloc(u8, head_len + b64_len + suffix.len);
    var pos: usize = 0;
    for (parts) |part| {
        @memcpy(frame[pos..][0..part.len], part);
        pos += part.len;
    }
    assert(pos == head_len);
    _ = encoder.encode(frame[pos..][0..b64_len], input);
    pos += b64_len;
    @memcpy(frame[pos..][0..suffix.len], suffix);
    assert(pos + suffix.len == frame.len);
    return frame;
}

/// True when `bytes` can sit inside a JSON string verbatim: printable ASCII
/// without `"` or `\`.
pub fn isPlainJsonAscii(bytes: []const u8) bool {
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
    assert(bytes.len - i < 16);
    for (bytes[i..]) |b| {
        if (b < 0x20 or b >= 0x7f or b == '"' or b == '\\') return false;
    }
    return true;
}

/// Substring search that skips to candidates with the SIMD
/// `indexOfScalarPos`; much faster than `std.mem.indexOf` over long base64.
pub fn containsSubstrSimd(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const last_start = haystack.len - needle.len;
    var pos: usize = 0;
    while (pos <= last_start) {
        const hit = std.mem.indexOfScalarPos(u8, haystack[0 .. last_start + 1], pos, needle[0]) orelse return false;
        assert(hit <= last_start);
        if (std.mem.eql(u8, haystack[hit..][0..needle.len], needle)) return true;
        pos = hit + 1;
    }
    return false;
}

/// False only when `line` provably has no `quoted_key` member: with no
/// backslash, every JSON key is spelled verbatim.
pub fn mayHaveKey(line: []const u8, quoted_key: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '\\') != null or containsSubstrSimd(line, quoted_key);
}

/// Member `key` of an object, or null.
pub fn jsonField(value: std.json.Value, key: []const u8) std.json.Value {
    if (value != .object) return .null;
    return value.object.get(key) orelse .null;
}

/// True when the first string member among `keys` equals `expected`.
pub fn jsonAnyStringEquals(value: std.json.Value, keys: []const []const u8, expected: []const u8) bool {
    const actual = jsonAnyObjectString(value, keys) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

/// The first string member among `keys`.
pub fn jsonAnyObjectString(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (jsonObjectString(value, key)) |actual| return actual;
    }
    return null;
}

/// String member `key`, or null.
pub fn jsonObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = jsonField(value, key);
    return if (field == .string) field.string else null;
}

/// Non-empty string member `key`, or `error.InvalidResponse`.
pub fn requiredString(value: std.json.Value, key: []const u8) ![]const u8 {
    const str = jsonObjectString(value, key) orelse return error.InvalidResponse;
    if (str.len == 0) return error.InvalidResponse;
    return str;
}

/// Unsigned integer member `key`, or null.
pub fn jsonUnsigned(value: std.json.Value, key: []const u8) ?u64 {
    const field = jsonField(value, key);
    return switch (field) {
        .integer => std.math.cast(u64, field.integer),
        .number_string => std.fmt.parseInt(u64, field.number_string, 10) catch null,
        else => null,
    };
}

/// Standard base64 encoding of `bytes`.
pub fn base64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    const written = encoder.encode(out, bytes);
    assert(written.len == out.len);
    return out;
}

/// Decode standard base64 into a new buffer.
pub fn base64Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

/// Decoded `replayBase64` of an attach result, if any.
pub fn decodeReplay(allocator: std.mem.Allocator, result: std.json.Value) !?[]u8 {
    const encoded = jsonObjectString(result, "replayBase64") orelse return null;
    if (encoded.len == 0) return null;
    return try base64Decode(allocator, encoded);
}

test "session.send fast framing is byte-identical to the generic frame" {
    const alloc = std.testing.allocator;
    const inputs = [_][]const u8{ "", "a", "hello world", "\x00\xff\x1b[A" };
    const ids = [_][]const u8{ "p", "pane-1/x", "pa\"ne", "p\xc3\xa9" };
    for (ids) |sid| for (inputs) |input| {
        const fast = try buildSendFrame(alloc, 4_000_000_000, sid, input);
        defer alloc.free(fast);
        const encoded = try base64Encode(alloc, input);
        defer alloc.free(encoded);
        const generic = try buildFrame(alloc, 4_000_000_000, "session.send", .{ .sessionId = sid, .dataBase64 = encoded });
        defer alloc.free(generic);
        try std.testing.expectEqualStrings(generic, fast);
    };
}

test "RPC reads skip id-less frames without parsing them" {
    try std.testing.expect(!mayHaveKey("{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\"}}", "\"id\""));
    try std.testing.expect(mayHaveKey("{\"\\u0069d\":1}", "\"id\""));
    try std.testing.expect(mayHaveKey("{\"id\":1}", "\"id\""));
}
