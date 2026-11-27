//! zmux v0.4.0 JSON-RPC 2.0 wire protocol: method names, notification
//! params, request parsing, and response and notification framing.

const std = @import("std");
const request = @import("protocol/request.zig");
const errors = @import("protocol/errors.zig");
const json_text = @import("protocol/text.zig");
const frames = @import("protocol/frames.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const assert = std.debug.assert;
const isPlainJsonAscii = json_text.isPlainJsonAscii;
const paneOutputSuffix = frames.paneOutputSuffix;
const pane_output_suffix_max = frames.pane_output_suffix_max;

/// Upper bounds enforced on incoming JSON-RPC requests before the value tree
/// is built.
pub const max_json_depth = request.max_json_depth;
/// Maximum count of JSON values and object keys in one request.
pub const max_json_nodes = request.max_json_nodes;
/// Errors `parseRequest` returns for malformed or unsupported request lines.
pub const ParseRequestError = request.ParseRequestError;
/// A parsed JSON-RPC request; release it with `deinit`.
pub const Request = request.Request;
/// Parse one JSON-RPC 2.0 request line; see `request.parseRequest`.
pub const parseRequest = request.parseRequest;
/// True when `req` had no `"id"` member, so it must not receive a response.
pub const isNotification = request.isNotification;

/// JSON-RPC 2.0 error codes; `session_error` covers zmux domain failures.
pub const ErrorCode = errors.ErrorCode;
/// Machine-readable error category sent in `error.data.kind`.
pub const ErrorKind = errors.ErrorKind;
/// JSON-RPC error code and kind for one Zig error name.
pub const ErrorMapping = errors.ErrorMapping;
/// Global error-name to JSON-RPC code table (review K0).
pub const errorCodeFor = errors.errorCodeFor;
/// Format an error response carrying `data.kind`.
pub const errorWithKind = errors.errorWithKind;

/// Always emits a JSON string. Invalid UTF-8 sequences become U+FFFD.
pub const writeJsonStringLossy = json_text.writeJsonStringLossy;
/// Copy `bytes`, replacing each invalid UTF-8 byte with U+FFFD.
pub const sanitizeUtf8Alloc = json_text.sanitizeUtf8Alloc;

/// Format a `pane_output` notification directly from raw PTY bytes.
pub const paneOutputNotification = frames.paneOutputNotification;
/// Format a `client.attach` JSON-RPC result in a single pre-sized allocation.
pub const attachResult = frames.attachResult;

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
/// Notification method sent when OSC 0 or OSC 2 updates a pane's dynamic title.
pub const pane_title_changed_method = "pane_title_changed";
/// Notification method sent when OSC 7 reports a pane working directory change.
pub const pane_cwd_changed_method = "pane_cwd_changed";
/// Notification method sent when OSC 133 updates shell prompt state or command exit.
pub const pane_prompt_changed_method = "pane_prompt_changed";
/// Notification method sent when OSC 7501, OSC 9, or OSC 777 updates agent status.
pub const pane_status_changed_method = "pane_status_changed";

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

/// Params of a `pane_title_changed` notification (OSC 0 / OSC 2).
pub const PaneTitleChangedParams = struct {
    pane_id: []const u8,
    title: []const u8,
    generation: u64 = 0,
};

/// Params of a `pane_cwd_changed` notification (OSC 7).
pub const PaneCwdChangedParams = struct {
    pane_id: []const u8,
    cwd: []const u8,
    generation: u64 = 0,
};

/// Params of a `pane_prompt_changed` notification (OSC 133).
pub const PanePromptChangedParams = struct {
    pane_id: []const u8,
    prompt_state: []const u8,
    last_exit_code: ?i32 = null,
    command_seq: u64 = 0,
    generation: u64 = 0,
};

/// Params of a `pane_status_changed` notification (OSC 7501 / 9 / 777).
pub const PaneStatusChangedParams = struct {
    pane_id: []const u8,
    status: []const u8,
    message: ?[]const u8 = null,
    generation: u64 = 0,
};

/// Format `{"jsonrpc":"2.0","id":<id>,"result":<value>}\n` into a new
/// allocation. `id_json` must already be serialized JSON.
pub fn result(allocator: Allocator, id_json: []const u8, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    try writeResult(&out.writer, id_json, value);
    assert(out.written().len > id_json.len);
    return out.toOwnedSlice();
}

/// `result` into a caller-owned writer, for a caller that reserved the
/// response buffer before doing the work it reports.
pub fn writeResult(writer: *std.Io.Writer, id_json: []const u8, value: anytype) !void {
    assert(id_json.len > 0);
    try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id_json});
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeAll("}\n");
}

/// Like `result`, but `raw_json` is already-serialized JSON copied verbatim.
pub fn resultRaw(allocator: Allocator, id_json: []const u8, raw_json: []const u8) ![]u8 {
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":";
    const mid = ",\"result\":";
    const suffix = "}\n";
    assert(id_json.len > 0);
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
    assert(out.written().len > id_json.len);
    return out.toOwnedSlice();
}

/// Serialize `value` to compact JSON in a new allocation.
pub fn jsonValueAlloc(allocator: Allocator, value: Value) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    assert(out.written().len > 0);
    return out.toOwnedSlice();
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

test {
    std.testing.refAllDecls(@This());
    _ = @import("protocol/request.zig");
    _ = @import("protocol/errors.zig");
    _ = @import("protocol/text.zig");
    _ = @import("protocol/frames.zig");
}
