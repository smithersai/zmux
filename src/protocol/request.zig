//! JSON-RPC 2.0 request parsing. Raw bytes are pre-scanned for depth and
//! node bounds before std.json builds a value tree.

const std = @import("std");
const json_text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const assert = std.debug.assert;
const writeJsonStringLossy = json_text.writeJsonStringLossy;
const errorCodeFor = @import("errors.zig").errorCodeFor;

/// Upper bounds enforced on incoming JSON-RPC requests before the value tree
/// is built.
pub const max_json_depth: usize = 64;
/// Maximum count of JSON values and object keys in one request.
pub const max_json_nodes: usize = 100_000;

/// Errors `parseRequest` returns for malformed or unsupported request lines.
pub const ParseRequestError = error{
    ParseError,
    InvalidRequest,
    InvalidId,
    NestingTooDeep,
    BatchUnsupported,
    OutOfMemory,
};

/// A parsed JSON-RPC request. Owns its value tree, id text and method name;
/// release them with `deinit`.
pub const Request = struct {
    allocator: Allocator,
    parsed: std.json.Parsed(Value),
    /// `"null"` when `!has_id`.
    id_json: []u8,
    method: []u8,
    /// False for JSON-RPC notifications (no `"id"` member).
    has_id: bool,

    /// Free the id, method and parsed value tree.
    pub fn deinit(self: *Request) void {
        self.allocator.free(self.id_json);
        self.allocator.free(self.method);
        self.parsed.deinit();
    }

    /// The request's `params` member. An empty positional array carries no
    /// arguments, so it reads as absent: clients that serialize "no params"
    /// as `[]` are valid JSON-RPC 2.0 and get the same result as `{}`.
    pub fn params(self: *const Request) ?Value {
        if (self.parsed.value != .object) return null;
        const value = self.parsed.value.object.get("params") orelse return null;
        if (value == .array and value.array.items.len == 0) return null;
        return value;
    }
};

/// Parse one JSON-RPC 2.0 request line.
///
/// The raw bytes are pre-scanned for container depth (`max_json_depth`) and
/// value count (`max_json_nodes`) before any value tree is built, so a deeply
/// nested or node-heavy request inside the line-size limit cannot exhaust the
/// stack or the heap. Either bound returns `error.NestingTooDeep`.
///
/// Envelope rules:
///   * A top-level array is a batch and returns `error.BatchUnsupported`.
///   * `"jsonrpc"` may be absent (legacy clients); any value other than the
///     string `"2.0"` returns `error.InvalidRequest`.
///   * `"method"` must be a string.
///   * `"id"` may be a string, an integer, or null. Floats, bools, arrays and
///     objects return `error.InvalidId`. Integer ids are copied byte-exact
///     from the request, so ids beyond the i64 range round-trip unchanged.
///   * An absent `"id"` is a notification (`has_id == false`, `id_json ==
///     "null"`). `"id":null` is a request with `has_id == true`.
///
/// std.json syntax failures map to `error.ParseError`.
pub fn parseRequest(allocator: Allocator, line: []const u8) ParseRequestError!Request {
    try prescan(line);

    var parsed = std.json.parseFromSlice(Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    errdefer parsed.deinit();

    if (parsed.value == .array) return error.BatchUnsupported;
    if (parsed.value != .object) return error.InvalidRequest;
    const object = parsed.value.object;

    if (object.get("jsonrpc")) |version_value| {
        if (version_value != .string or !std.mem.eql(u8, version_value.string, "2.0")) return error.InvalidRequest;
    }

    const method_value = object.get("method") orelse return error.InvalidRequest;
    if (method_value != .string) return error.InvalidRequest;

    const id_value = object.get("id");
    const id_json = try idJsonAlloc(allocator, id_value orelse Value.null);
    errdefer allocator.free(id_json);

    const method = try allocator.dupe(u8, method_value.string);
    errdefer allocator.free(method);
    assert(parsed.value == .object);
    assert(id_json.len > 0);

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .id_json = id_json,
        .method = method,
        .has_id = id_value != null,
    };
}

/// Serialize a validated id. Only string, integer and null ids are accepted.
fn idJsonAlloc(allocator: Allocator, id: Value) error{ InvalidId, OutOfMemory }![]u8 {
    switch (id) {
        .null => return allocator.dupe(u8, "null"),
        .integer => |n| return std.fmt.allocPrint(allocator, "{d}", .{n}),
        // std.json keeps integers outside the i64 range as their source text.
        .number_string => |text| {
            if (!isIntegerToken(text)) return error.InvalidId;
            return allocator.dupe(u8, text);
        },
        .string => |text| {
            var out: std.Io.Writer.Allocating = .init(allocator);
            errdefer out.deinit();
            writeJsonStringLossy(&out.writer, text) catch return error.OutOfMemory;
            return out.toOwnedSlice() catch return error.OutOfMemory;
        },
        .float, .bool, .array, .object => return error.InvalidId,
    }
}

fn isIntegerToken(text: []const u8) bool {
    const digits = if (text.len > 0 and text[0] == '-') text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Enforce `max_json_depth` / `max_json_nodes` on the raw bytes. Malformed
/// input is left for std.json to report; the scanner only has to be exact
/// about string boundaries so brackets inside strings are not counted. A
/// top-level array is not rejected here: `parseRequest` reports a well-formed
/// batch as `BatchUnsupported` only after std.json accepted its syntax, so
/// `[not json` is a parse error (-32700), not an invalid request.
fn prescan(line: []const u8) error{NestingTooDeep}!void {
    const first = std.mem.indexOfNone(u8, line, " \t\r\n") orelse return;

    var depth: usize = 0;
    var nodes: usize = 0;
    var i: usize = first;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '{', '[' => {
                depth += 1;
                if (depth > max_json_depth) return error.NestingTooDeep;
                nodes += 1;
            },
            '}', ']' => depth -|= 1,
            '"' => {
                // Count string values and object keys alike: both cost a
                // node's worth of allocation in the parsed tree.
                nodes += 1;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
            },
            '-', '0'...'9', 't', 'f', 'n' => {
                nodes += 1;
                while (i + 1 < line.len and isScalarByte(line[i + 1])) i += 1;
            },
            else => {},
        }
        if (nodes > max_json_nodes) return error.NestingTooDeep;
    }
    assert(depth <= max_json_depth);
    assert(nodes <= max_json_nodes);
}

fn isScalarByte(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '-', '+', '.' => true,
        else => false,
    };
}

/// True when `req` had no `"id"` member, so it must not receive a response.
pub fn isNotification(req: *const Request) bool {
    return !req.has_id;
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

fn nestedRequestAlloc(allocator: Allocator, params_depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":1,\"method\":\"x\",\"params\":");
    try out.appendNTimes(allocator, '[', params_depth);
    try out.appendNTimes(allocator, ']', params_depth);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

test "parseRequest rejects a 100k-deep id without crashing" {
    const depth = 100_000;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, "{\"method\":\"x\",\"id\":");
    try out.appendNTimes(std.testing.allocator, '[', depth);
    try out.appendNTimes(std.testing.allocator, ']', depth);
    try out.appendSlice(std.testing.allocator, "}\n");
    try std.testing.expectError(error.NestingTooDeep, parseRequest(std.testing.allocator, out.items));
}

test "parseRequest accepts depth max_json_depth and rejects one more" {
    // The request object itself is one level.
    const ok_line = try nestedRequestAlloc(std.testing.allocator, max_json_depth - 1);
    defer std.testing.allocator.free(ok_line);
    var ok = try parseRequest(std.testing.allocator, ok_line);
    ok.deinit();

    const deep_line = try nestedRequestAlloc(std.testing.allocator, max_json_depth);
    defer std.testing.allocator.free(deep_line);
    try std.testing.expectError(error.NestingTooDeep, parseRequest(std.testing.allocator, deep_line));
}

test "parseRequest ignores brackets inside strings when measuring depth" {
    const brackets: [4 * max_json_depth]u8 = @splat('[');
    const line = "{\"id\":1,\"method\":\"session.send\",\"params\":{\"data\":\"" ++ brackets ++ "\\\"[{\"}}\n";
    var req = try parseRequest(std.testing.allocator, line);
    defer req.deinit();
    try std.testing.expectEqualStrings("session.send", req.method);
}

test "parseRequest enforces max_json_nodes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, "{\"id\":1,\"method\":\"x\",\"params\":[");
    for (0..max_json_nodes + 1) |i| {
        if (i != 0) try out.append(std.testing.allocator, ',');
        try out.append(std.testing.allocator, '0');
    }
    try out.appendSlice(std.testing.allocator, "]}\n");
    try std.testing.expectError(error.NestingTooDeep, parseRequest(std.testing.allocator, out.items));
}

test "parseRequest accepts only string, integer, and null ids" {
    const invalid = [_][]const u8{
        "{\"id\":{},\"method\":\"x\"}",
        "{\"id\":[1],\"method\":\"x\"}",
        "{\"id\":true,\"method\":\"x\"}",
        "{\"id\":false,\"method\":\"x\"}",
        "{\"id\":1.5,\"method\":\"x\"}",
        "{\"id\":1e3,\"method\":\"x\"}",
        "{\"id\":-0.0,\"method\":\"x\"}",
    };
    for (invalid) |line| {
        try std.testing.expectError(error.InvalidId, parseRequest(std.testing.allocator, line));
    }

    const valid = [_]struct { line: []const u8, id_json: []const u8 }{
        .{ .line = "{\"id\":-42,\"method\":\"x\"}", .id_json = "-42" },
        .{ .line = "{\"id\":123456789012345678901234567890,\"method\":\"x\"}", .id_json = "123456789012345678901234567890" },
        .{ .line = "{\"id\":\"a\\\"b\",\"method\":\"x\"}", .id_json = "\"a\\\"b\"" },
        .{ .line = "{\"id\":null,\"method\":\"x\"}", .id_json = "null" },
    };
    for (valid) |case| {
        var req = try parseRequest(std.testing.allocator, case.line);
        defer req.deinit();
        try std.testing.expectEqualStrings(case.id_json, req.id_json);
        try std.testing.expect(req.has_id);
    }
}

test "parseRequest distinguishes absent id from null id" {
    var absent = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"x\"}");
    defer absent.deinit();
    try std.testing.expect(!absent.has_id);
    try std.testing.expect(isNotification(&absent));
    try std.testing.expectEqualStrings("null", absent.id_json);

    var explicit_null = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"x\"}");
    defer explicit_null.deinit();
    try std.testing.expect(explicit_null.has_id);
    try std.testing.expect(!isNotification(&explicit_null));
}

test "parseRequest validates the jsonrpc member" {
    var legacy = try parseRequest(std.testing.allocator, "{\"id\":1,\"method\":\"x\"}");
    legacy.deinit();
    var current = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"x\"}");
    current.deinit();

    const bad = [_][]const u8{
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}",
        "{\"jsonrpc\":2.0,\"id\":1,\"method\":\"x\"}",
        "{\"jsonrpc\":null,\"id\":1,\"method\":\"x\"}",
        "{\"jsonrpc\":\"2.0 \",\"id\":1,\"method\":\"x\"}",
    };
    for (bad) |line| try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, line));
}

test "parseRequest rejects batches and non-object requests" {
    try std.testing.expectError(error.BatchUnsupported, parseRequest(std.testing.allocator, "[]"));
    // Malformed array-prefixed input is a syntax error, not a batch.
    try std.testing.expectError(error.ParseError, parseRequest(std.testing.allocator, "[not json"));
    try std.testing.expectError(error.ParseError, parseRequest(std.testing.allocator, " [{\"id\":1,"));
    try std.testing.expectEqual(@as(i32, -32700), errorCodeFor(error.ParseError).code);
    try std.testing.expectError(error.BatchUnsupported, parseRequest(std.testing.allocator, " \t[{\"id\":1,\"method\":\"x\"}]\n"));
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, "\"x\""));
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, "7"));
    try std.testing.expectError(error.ParseError, parseRequest(std.testing.allocator, "{\"id\":1,"));
    try std.testing.expectError(error.ParseError, parseRequest(std.testing.allocator, "not json"));
}

fn parseRequestForAllocTest(allocator: Allocator, line: []const u8) !void {
    var req = try parseRequest(allocator, line);
    req.deinit();
}

test "parseRequest frees partial results on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseRequestForAllocTest,
        .{"{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"session.create\",\"params\":{\"argv\":[\"sh\"]}}"},
    );
}

test "empty positional params read as absent" {
    var empty = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\",\"params\":[]}");
    defer empty.deinit();
    try std.testing.expect(empty.params() == null);

    var positional = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\",\"params\":[1]}");
    defer positional.deinit();
    try std.testing.expect(positional.params().? == .array);
}
