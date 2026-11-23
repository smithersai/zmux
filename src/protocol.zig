const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const version = "0.3.0";

pub const foreground_changed_method = "foreground_changed";
pub const session_exited_method = "session_exited";
pub const pane_output_method = "pane_output";
pub const pane_activity_method = "pane_activity";
pub const pane_bell_method = "pane_bell";
pub const pane_output_dropped_method = "pane_output_dropped";
pub const pane_respawned_method = "pane_respawned";
pub const client_detached_method = "client_detached";

/// Upper bounds enforced on incoming JSON-RPC requests before the value tree
/// is built.
pub const max_json_depth: usize = 64;
pub const max_json_nodes: usize = 100_000;

pub const ErrorCode = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const session_error = -32000;
};

pub const ParseRequestError = error{ ParseError, InvalidRequest, InvalidId, NestingTooDeep, BatchUnsupported, OutOfMemory };

pub const Request = struct {
    allocator: Allocator,
    parsed: std.json.Parsed(Value),
    /// `"null"` when `!has_id`.
    id_json: []u8,
    method: []u8,
    /// False for JSON-RPC notifications (no `"id"` member).
    has_id: bool,

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
    argv_truncated: bool = false,
};

pub const SessionExitedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    generation: u64 = 0,
};

pub const PaneOutputParams = struct {
    pane_id: []const u8,
    data_base64: []const u8,
    /// Stream offset of the first byte in `data_base64`.
    offset: u64 = 0,
    generation: u64 = 0,
};

pub const PaneActivityParams = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
    generation: u64 = 0,
};

pub const PaneBellParams = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
    generation: u64 = 0,
};

pub const PaneOutputDroppedParams = struct {
    pane_id: []const u8,
    dropped_bytes: u64,
    resume_offset: u64,
};

pub const PaneRespawnedParams = struct {
    pane_id: []const u8,
    generation: u64,
    pid: std.posix.pid_t,
};

pub const ClientDetachedParams = struct {
    client_id: []const u8,
    /// `"pane_removed"`, `"session_removed"`, or `"remote_detach"`.
    reason: []const u8,
};

/// Phase 0 stub (T1 owns): depth/node pre-scan, `jsonrpc` validation, batch
/// and id-type rejection are not enforced yet. std.json syntax failures map to
/// `error.ParseError`.
pub fn parseRequest(allocator: Allocator, line: []const u8) ParseRequestError!Request {
    var parsed = std.json.parseFromSlice(Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const method_value = parsed.value.object.get("method") orelse return error.InvalidRequest;
    if (method_value != .string) return error.InvalidRequest;

    const has_id = parsed.value.object.get("id") != null;
    const id_value = parsed.value.object.get("id") orelse Value.null;
    const id_json = jsonValueAlloc(allocator, id_value) catch return error.OutOfMemory;
    errdefer allocator.free(id_json);

    const method = try allocator.dupe(u8, method_value.string);
    errdefer allocator.free(method);

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .id_json = id_json,
        .method = method,
        .has_id = has_id,
    };
}

pub fn isNotification(req: *const Request) bool {
    return !req.has_id;
}

pub const ErrorKind = enum {
    parse,
    invalid_request,
    method_not_found,
    invalid_params,
    not_found,
    terminated,
    conflict,
    limit,
    spawn_failed,
    io,
    internal,
};

pub const ErrorMapping = struct { code: i32, kind: ErrorKind };

/// Global error-name to JSON-RPC code table (review K0).
pub fn errorCodeFor(err: anyerror) ErrorMapping {
    const Entry = struct { names: []const []const u8, mapping: ErrorMapping };
    const table = [_]Entry{
        .{ .names = &.{ "ParseError", "SyntaxError", "UnexpectedEndOfInput" }, .mapping = .{ .code = ErrorCode.parse_error, .kind = .parse } },
        .{ .names = &.{ "InvalidRequest", "InvalidId", "NestingTooDeep", "BatchUnsupported", "MessageTooLarge", "TruncatedFrame" }, .mapping = .{ .code = ErrorCode.invalid_request, .kind = .invalid_request } },
        .{ .names = &.{"MethodNotFound"}, .mapping = .{ .code = ErrorCode.method_not_found, .kind = .method_not_found } },
        .{ .names = &.{ "InvalidParams", "InvalidSpawnArgument", "UnknownKey", "ScrollbackBytesTooLarge", "InvalidName", "InvalidAxis", "InvalidDimensions" }, .mapping = .{ .code = ErrorCode.invalid_params, .kind = .invalid_params } },
        .{ .names = &.{ "SessionNotFound", "WindowNotFound", "PaneNotFound", "ClientNotFound" }, .mapping = .{ .code = ErrorCode.session_error, .kind = .not_found } },
        .{ .names = &.{"SessionTerminated"}, .mapping = .{ .code = ErrorCode.session_error, .kind = .terminated } },
        .{ .names = &.{ "DuplicateSessionName", "NameShadowsId", "PaneRunning" }, .mapping = .{ .code = ErrorCode.session_error, .kind = .conflict } },
        .{ .names = &.{"LimitExceeded"}, .mapping = .{ .code = ErrorCode.session_error, .kind = .limit } },
        .{ .names = &.{ "OpenPtyFailed", "ForkFailed", "ChildSetupFailed", "SpawnFailed" }, .mapping = .{ .code = ErrorCode.session_error, .kind = .spawn_failed } },
        .{ .names = &.{ "InputTimeout", "InputClosed", "BrokenPipe", "InputOutput", "WriteZero" }, .mapping = .{ .code = ErrorCode.session_error, .kind = .io } },
    };
    const name = @errorName(err);
    inline for (table) |entry| {
        for (entry.names) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return entry.mapping;
        }
    }
    return .{ .code = ErrorCode.internal_error, .kind = .internal };
}

/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":C,"message":"M","data":{"kind":"K"}}}`
pub fn errorWithKind(allocator: Allocator, id_json: []const u8, code: i32, message: []const u8, kind: ErrorKind) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":",
        .{ id_json, code },
    );
    try writeJsonStringLossy(&out.writer, message);
    try out.writer.print(",\"data\":{{\"kind\":\"{s}\"}}}}}}\n", .{@tagName(kind)});
    return out.toOwnedSlice();
}

/// Always emits a JSON string. Invalid UTF-8 sequences become U+FFFD.
pub fn writeJsonStringLossy(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try std.json.Stringify.value(bytes, .{}, writer);
        return;
    }
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len == 0 or i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try writer.writeAll("\u{FFFD}");
            i += 1;
            continue;
        }
        try writeJsonStringBody(writer, bytes[i .. i + len]);
        i += len;
    }
    try writer.writeByte('"');
}

fn writeJsonStringBody(writer: *std.Io.Writer, valid_utf8: []const u8) !void {
    for (valid_utf8) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

/// Copy `bytes`, replacing each invalid UTF-8 byte with U+FFFD.
pub fn sanitizeUtf8Alloc(allocator: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len == 0 or i + len > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(allocator, "\u{FFFD}");
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, bytes[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(allocator);
}

pub fn result(allocator: Allocator, id_json: []const u8, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_json});
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn resultRaw(allocator: Allocator, id_json: []const u8, raw_json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_json, raw_json });
    return out.toOwnedSlice();
}

pub fn notification(allocator: Allocator, method: []const u8, params: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"method\":", .{});
    try std.json.Stringify.value(method, .{}, &out.writer);
    try out.writer.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn @"error"(allocator: Allocator, id_json: []const u8, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
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
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
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
