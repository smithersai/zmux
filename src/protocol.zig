const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const assert = std.debug.assert;

/// zmux wire protocol version reported by `daemon.ping` and handshakes.
pub const version = "0.4.0";

/// Notification method sent when a session's foreground process changes.
pub const foreground_changed_method = "foreground_changed";
/// Notification method sent when a session's root process exits.
pub const session_exited_method = "session_exited";
/// Notification method carrying base64-encoded PTY output for a pane.
pub const pane_output_method = "pane_output";
/// Notification method sent when a pane records new output activity.
pub const pane_activity_method = "pane_activity";
/// Notification method sent when a pane rings the terminal bell.
pub const pane_bell_method = "pane_bell";
/// Notification method sent when a slow client missed pane output.
pub const pane_output_dropped_method = "pane_output_dropped";
/// Notification method sent when a pane's process is respawned.
pub const pane_respawned_method = "pane_respawned";
/// Notification method sent when the daemon detaches a client.
pub const client_detached_method = "client_detached";

/// Upper bounds enforced on incoming JSON-RPC requests before the value tree
/// is built.
pub const max_json_depth: usize = 64;
/// Maximum count of JSON values and object keys in one request.
pub const max_json_nodes: usize = 100_000;

/// JSON-RPC 2.0 error codes; `session_error` covers zmux domain failures.
pub const ErrorCode = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const session_error = -32000;
};

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

/// Params of a `foreground_changed` notification.
pub const ForegroundChangedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    comm: []const u8,
    argv: []const []const u8,
    argv_truncated: bool = false,
};

/// Params of a `session_exited` notification. `exit_code` and `signal` are
/// null when the process did not exit that way.
pub const SessionExitedParams = struct {
    session_id: []const u8,
    pid: std.posix.pid_t,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    generation: u64 = 0,
};

/// Params of a `pane_output` notification.
pub const PaneOutputParams = struct {
    pane_id: []const u8,
    data_base64: []const u8,
    /// Stream offset of the first byte in `data_base64`.
    offset: u64 = 0,
    generation: u64 = 0,
};

/// Params of a `pane_activity` notification.
pub const PaneActivityParams = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
    generation: u64 = 0,
};

/// Params of a `pane_bell` notification.
pub const PaneBellParams = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
    generation: u64 = 0,
};

/// Params of a `pane_output_dropped` notification. A client resumes reading
/// at `resume_offset`.
pub const PaneOutputDroppedParams = struct {
    pane_id: []const u8,
    dropped_bytes: u64,
    resume_offset: u64,
    /// Process generation of the pane whose output was dropped.
    generation: u64 = 0,
};

/// Params of a `pane_respawned` notification.
pub const PaneRespawnedParams = struct {
    pane_id: []const u8,
    generation: u64,
    pid: std.posix.pid_t,
};

/// Params of a `client_detached` notification.
pub const ClientDetachedParams = struct {
    client_id: []const u8,
    /// `"pane_removed"`, `"session_removed"`, or `"remote_detach"`.
    reason: []const u8,
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

/// Machine-readable error category sent in `error.data.kind`.
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

/// JSON-RPC error code and kind for one Zig error name.
pub const ErrorMapping = struct { code: i32, kind: ErrorKind };

/// Global error-name to JSON-RPC code table (review K0).
pub fn errorCodeFor(err: anyerror) ErrorMapping {
    const Entry = struct { names: []const []const u8, mapping: ErrorMapping };
    const C = ErrorCode;
    const e = struct {
        fn f(names: []const []const u8, code: i32, kind: ErrorKind) Entry {
            return .{ .names = names, .mapping = .{ .code = code, .kind = kind } };
        }
    }.f;
    const table = [_]Entry{
        e(&.{ "ParseError", "SyntaxError", "UnexpectedEndOfInput" }, C.parse_error, .parse),
        e(&.{
            "InvalidRequest", "InvalidId", "NestingTooDeep", "BatchUnsupported", "MessageTooLarge", "TruncatedFrame",
        }, C.invalid_request, .invalid_request),
        e(&.{"MethodNotFound"}, C.method_not_found, .method_not_found),
        e(&.{
            "InvalidParams",           "InvalidSpawnArgument", "UnknownKey",
            "ScrollbackBytesTooLarge", "InvalidName",          "InvalidAxis",
            "InvalidDimensions",
        }, C.invalid_params, .invalid_params),
        e(&.{ "SessionNotFound", "WindowNotFound", "PaneNotFound", "ClientNotFound" }, C.session_error, .not_found),
        e(&.{"SessionTerminated"}, C.session_error, .terminated),
        e(&.{ "DuplicateSessionName", "NameShadowsId", "PaneRunning" }, C.session_error, .conflict),
        e(&.{"LimitExceeded"}, C.session_error, .limit),
        e(&.{ "OpenPtyFailed", "ForkFailed", "ChildSetupFailed", "SpawnFailed" }, C.session_error, .spawn_failed),
        e(&.{ "InputTimeout", "InputClosed", "BrokenPipe", "InputOutput", "WriteZero" }, C.session_error, .io),
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
        assert(i + len <= bytes.len);
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
        assert(i + len <= bytes.len);
        try out.appendSlice(allocator, bytes[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(allocator);
}

/// Format `{"jsonrpc":"2.0","id":<id>,"result":<value>}\n` into a new
/// allocation. `id_json` must already be serialized JSON.
pub fn result(allocator: Allocator, id_json: []const u8, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    try writeResult(&out.writer, id_json, value);
    return out.toOwnedSlice();
}

/// `result` into a caller-owned writer, for a caller that reserved the
/// response buffer before doing the work it reports.
pub fn writeResult(writer: *std.Io.Writer, id_json: []const u8, value: anytype) !void {
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_json});
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeAll("}\n");
}

/// Like `result`, but `raw_json` is already-serialized JSON copied verbatim.
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
    assert(pos + suffix.len == total);
    @memcpy(out[pos..][0..suffix.len], suffix);
    return out;
}

const pane_output_suffix_offset = "\",\"offset\":";
const pane_output_suffix_generation = ",\"generation\":";
const pane_output_suffix_end = "}}\n";
const pane_output_suffix_fixed = pane_output_suffix_offset.len + pane_output_suffix_generation.len +
    pane_output_suffix_end.len;
const pane_output_suffix_max = pane_output_suffix_fixed + 2 * std.fmt.count("{d}", .{std.math.maxInt(u64)});

/// The bytes after `data_base64`'s value, in `PaneOutputParams` field order,
/// so the fast paths match `std.json.Stringify` byte for byte.
fn paneOutputSuffix(buf: *[pane_output_suffix_max]u8, offset: u64, generation: u64) []const u8 {
    // `buf` holds two maximal u64s plus the fixed bytes, so `printInt` and
    // the copies cannot overflow it.
    var pos: usize = 0;
    @memcpy(buf[pos..][0..pane_output_suffix_offset.len], pane_output_suffix_offset);
    pos += pane_output_suffix_offset.len;
    pos += std.fmt.printInt(buf[pos..], offset, 10, .lower, .{});
    @memcpy(buf[pos..][0..pane_output_suffix_generation.len], pane_output_suffix_generation);
    pos += pane_output_suffix_generation.len;
    pos += std.fmt.printInt(buf[pos..], generation, 10, .lower, .{});
    @memcpy(buf[pos..][0..pane_output_suffix_end.len], pane_output_suffix_end);
    pos += pane_output_suffix_end.len;
    assert(pos > pane_output_suffix_fixed);
    assert(pos <= buf.len);
    return buf[0..pos];
}

/// Format a `pane_output` notification directly from raw PTY bytes in a single
/// pre-sized allocation, avoiding intermediate base64 buffers and redundant
/// JSON escape scans over the base64 alphabet.
pub fn paneOutputNotification(
    allocator: Allocator,
    pane_id: []const u8,
    raw_bytes: []const u8,
    offset: u64,
    generation: u64,
) ![]u8 {
    const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":";
    const mid = ",\"data_base64\":\"";
    var suffix_buf: [pane_output_suffix_max]u8 = undefined;
    const suffix = paneOutputSuffix(&suffix_buf, offset, generation);
    assert(suffix.len <= suffix_buf.len);
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
        assert(pos + suffix.len == total);
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
    assert(pos + suffix.len == total);
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
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"clientId\":{f},\"sessionId\":{f}," ++
            "\"windowId\":{f},\"paneId\":{f},\"rows\":{},\"cols\":{},\"replayBase64\":\"",
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
    assert(head_slice.len > 0);
    const b64_len = std.base64.standard.Encoder.calcSize(replay_bytes.len);
    const suffix = "\"}}\n";
    const out = try allocator.alloc(u8, head_slice.len + b64_len + suffix.len);
    @memcpy(out[0..head_slice.len], head_slice);
    _ = std.base64.standard.Encoder.encode(out[head_slice.len..][0..b64_len], replay_bytes);
    @memcpy(out[head_slice.len + b64_len ..][0..suffix.len], suffix);
    return out;
}

/// Format a JSON-RPC notification line for `method` with `params`. Plain-ASCII
/// `PaneOutputParams` take a single-allocation fast path with identical bytes.
pub fn notification(allocator: Allocator, method: []const u8, params: anytype) ![]u8 {
    if (@TypeOf(params) == PaneOutputParams and
        std.mem.eql(u8, method, pane_output_method) and
        isPlainJsonAscii(params.pane_id) and
        isPlainJsonAscii(params.data_base64))
    {
        const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"";
        const mid = "\",\"data_base64\":\"";
        var suffix_buf: [pane_output_suffix_max]u8 = undefined;
        const suffix = paneOutputSuffix(&suffix_buf, params.offset, params.generation);
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
        assert(pos + suffix.len == total);
        @memcpy(out[pos..][0..suffix.len], suffix);
        return out;
    }

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
    try writeJsonStringLossy(&out.writer, method);
    try out.writer.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

/// Format a JSON-RPC error response without `data`. `id_json` must already be
/// serialized JSON; `message` is escaped and invalid UTF-8 becomes U+FFFD.
pub fn @"error"(allocator: Allocator, id_json: []const u8, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 160);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":",
        .{ id_json, code },
    );
    try writeJsonStringLossy(&out.writer, message);
    try out.writer.writeAll("}}\n");
    return out.toOwnedSlice();
}

/// Serialize `value` to compact JSON in a new allocation.
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
    assert(bytes.len - i < 16);
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
    const fast = try paneOutputNotification(std.testing.allocator, "pane-1", raw, 12345, std.math.maxInt(u64));
    defer std.testing.allocator.free(fast);

    const enc_len = std.base64.standard.Encoder.calcSize(raw.len);
    const b64 = try std.testing.allocator.alloc(u8, enc_len);
    defer std.testing.allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, raw);

    const params_in: PaneOutputParams = .{ .pane_id = "pane-1", .data_base64 = b64, .offset = 12345, .generation = std.math.maxInt(u64) };
    const generic = try notification(std.testing.allocator, pane_output_method, params_in);
    defer std.testing.allocator.free(generic);
    try std.testing.expectEqualStrings(generic, fast);
    // The notification fast path must match the generic serializer too,
    // including the stream offset and generation clients reassemble with.
    var stringified: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stringified.deinit();
    try stringified.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":");
    try std.json.Stringify.value(params_in, .{}, &stringified.writer);
    try stringified.writer.writeAll("}\n");
    try std.testing.expectEqualStrings(stringified.written(), generic);

    // Also verify pane_id with special JSON characters escapes properly.
    const escaped = try paneOutputNotification(std.testing.allocator, "pane\"\\\n1", "hi", 7, 2);
    defer std.testing.allocator.free(escaped);
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, escaped, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("pane\"\\\n1", params.get("pane_id").?.string);
    try std.testing.expectEqualStrings("aGk=", params.get("data_base64").?.string);
    try std.testing.expectEqual(@as(i64, 7), params.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 2), params.get("generation").?.integer);
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

test "errorCodeFor maps every K0 error name" {
    const Case = struct { err: anyerror, code: i32, kind: ErrorKind };
    const cases = [_]Case{
        .{ .err = error.ParseError, .code = -32700, .kind = .parse },
        .{ .err = error.SyntaxError, .code = -32700, .kind = .parse },
        .{ .err = error.UnexpectedEndOfInput, .code = -32700, .kind = .parse },
        .{ .err = error.InvalidRequest, .code = -32600, .kind = .invalid_request },
        .{ .err = error.InvalidId, .code = -32600, .kind = .invalid_request },
        .{ .err = error.NestingTooDeep, .code = -32600, .kind = .invalid_request },
        .{ .err = error.BatchUnsupported, .code = -32600, .kind = .invalid_request },
        .{ .err = error.MessageTooLarge, .code = -32600, .kind = .invalid_request },
        .{ .err = error.TruncatedFrame, .code = -32600, .kind = .invalid_request },
        .{ .err = error.MethodNotFound, .code = -32601, .kind = .method_not_found },
        .{ .err = error.InvalidParams, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidSpawnArgument, .code = -32602, .kind = .invalid_params },
        .{ .err = error.UnknownKey, .code = -32602, .kind = .invalid_params },
        .{ .err = error.ScrollbackBytesTooLarge, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidName, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidAxis, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidDimensions, .code = -32602, .kind = .invalid_params },
        .{ .err = error.SessionNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.WindowNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.PaneNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.ClientNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.SessionTerminated, .code = -32000, .kind = .terminated },
        .{ .err = error.DuplicateSessionName, .code = -32000, .kind = .conflict },
        .{ .err = error.NameShadowsId, .code = -32000, .kind = .conflict },
        .{ .err = error.PaneRunning, .code = -32000, .kind = .conflict },
        .{ .err = error.LimitExceeded, .code = -32000, .kind = .limit },
        .{ .err = error.OpenPtyFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.ForkFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.ChildSetupFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.SpawnFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.InputTimeout, .code = -32000, .kind = .io },
        .{ .err = error.InputClosed, .code = -32000, .kind = .io },
        .{ .err = error.BrokenPipe, .code = -32000, .kind = .io },
        .{ .err = error.InputOutput, .code = -32000, .kind = .io },
        .{ .err = error.WriteZero, .code = -32000, .kind = .io },
        .{ .err = error.OutOfMemory, .code = -32603, .kind = .internal },
        .{ .err = error.SomethingNobodyMapped, .code = -32603, .kind = .internal },
    };
    for (cases) |case| {
        const mapping = errorCodeFor(case.err);
        errdefer std.debug.print("error.{s}\n", .{@errorName(case.err)});
        try std.testing.expectEqual(case.code, mapping.code);
        try std.testing.expectEqual(case.kind, mapping.kind);
    }
}

test "errorWithKind emits the documented envelope" {
    const json = try errorWithKind(std.testing.allocator, "7", -32000, "PaneNotFound", .not_found);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\",\"data\":{\"kind\":\"not_found\"}}}\n",
        json,
    );
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
}

test "writeJsonStringLossy replaces invalid UTF-8 and stays a JSON string" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonStringLossy(&out.writer, "\xff\xfe");
    try std.testing.expectEqualStrings("\"\u{FFFD}\u{FFFD}\"", out.written());

    out.clearRetainingCapacity();
    try writeJsonStringLossy(&out.writer, "a\"\\\n\x01\xc3\xa9\xe2\x82");
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"\\\n\x01\u{e9}\u{FFFD}\u{FFFD}", parsed.value.string);

    out.clearRetainingCapacity();
    // Encoded surrogate and overlong NUL are invalid UTF-8.
    try writeJsonStringLossy(&out.writer, "\xed\xa0\x80\xc0\x80");
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.written()));
}

test "sanitizeUtf8Alloc keeps valid text and replaces invalid bytes" {
    const valid = try sanitizeUtf8Alloc(std.testing.allocator, "h\u{e9}llo");
    defer std.testing.allocator.free(valid);
    try std.testing.expectEqualStrings("h\u{e9}llo", valid);

    const fixed = try sanitizeUtf8Alloc(std.testing.allocator, "a\xffb\xc3");
    defer std.testing.allocator.free(fixed);
    try std.testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", fixed);
}

test "error and notification never emit integer arrays for invalid UTF-8" {
    const err_json = try @"error"(std.testing.allocator, "1", ErrorCode.internal_error, "bad\xff");
    defer std.testing.allocator.free(err_json);
    var parsed_err = try std.json.parseFromSlice(Value, std.testing.allocator, err_json, .{});
    defer parsed_err.deinit();
    try std.testing.expect(parsed_err.value.object.get("error").?.object.get("message").? == .string);

    const note = try notification(std.testing.allocator, "m\xff", .{});
    defer std.testing.allocator.free(note);
    var parsed_note = try std.json.parseFromSlice(Value, std.testing.allocator, note, .{});
    defer parsed_note.deinit();
    try std.testing.expect(parsed_note.value.object.get("method").? == .string);
}

test "empty positional params read as absent" {
    var empty = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\",\"params\":[]}");
    defer empty.deinit();
    try std.testing.expect(empty.params() == null);

    var positional = try parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\",\"params\":[1]}");
    defer positional.deinit();
    try std.testing.expect(positional.params().? == .array);
}
