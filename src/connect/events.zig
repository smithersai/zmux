//! Daemon line handling for the interactive loop: replies, pane output,
//! client and session notifications, and the per-run request state.

const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
const wire = @import("wire.zig");

const first_interactive_id = wire.first_interactive_id;
const send_reply_timeout_ms = wire.send_reply_timeout_ms;
const buildFrame = wire.buildFrame;
const buildSendFrame = wire.buildSendFrame;
const isPlainJsonAscii = wire.isPlainJsonAscii;
const containsSubstrSimd = wire.containsSubstrSimd;
const jsonField = wire.jsonField;
const jsonUnsigned = wire.jsonUnsigned;
const jsonObjectString = wire.jsonObjectString;
const jsonAnyStringEquals = wire.jsonAnyStringEquals;
const jsonAnyObjectString = wire.jsonAnyObjectString;
const RpcError = wire.RpcError;
const base64Decode = wire.base64Decode;
const decodeReplay = wire.decodeReplay;
const reportRpcError = cli.reportRpcError;
const printDiagnostic = cli.printDiagnostic;
const escaped = cli.escaped;
const WriteQueue = terminal.WriteQueue;
const g_winch_flag = &terminal.g_winch_flag;

const test_io = std.testing.io;

/// How an interactive session ended.
pub const RunOutcome = enum { exited, session_ended, detached, detached_remotely, connection_lost };

/// Pane, generation and request state the server lines update.
pub const RunState = struct {
    pane_id: []const u8,
    switched_pane: ?[]u8 = null,
    generation: ?u64,
    next_offset: ?u64,
    client_id: []const u8,
    next_id: u32 = first_interactive_id,
    pending_sends: std.AutoHashMapUnmanaged(u32, void) = .empty,
    send_reply_deadline: i64 = 0,

    pub fn queue(
        self: *RunState,
        allocator: std.mem.Allocator,
        out: *WriteQueue,
        method: []const u8,
        params: anytype,
    ) !void {
        assert(self.next_id >= first_interactive_id);
        const frame = try buildFrame(allocator, self.next_id, method, params);
        defer allocator.free(frame);
        assert(frame[frame.len - 1] == '\n');
        self.next_id += 1;
        try out.append(allocator, frame);
    }

    /// Queue `session.send` for `input`. Byte-identical to
    /// `queue("session.send", .{ .sessionId, .dataBase64 })`, but encodes the
    /// base64 straight into the frame: one allocation and no JSON escape scan
    /// over the base64 alphabet.
    pub fn queueSend(self: *RunState, allocator: std.mem.Allocator, out: *WriteQueue, input: []const u8) !void {
        assert(self.next_id >= first_interactive_id);
        assert(input.len > 0);
        const frame = try buildSendFrame(allocator, self.next_id, self.pane_id, input);
        defer allocator.free(frame);
        assert(frame[frame.len - 1] == '\n');
        self.next_id += 1;
        try out.append(allocator, frame);
    }
};

/// Apply one daemon line to `state`, taking fast paths when safe.
pub fn handleServerLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    state: *RunState,
    output: *?[]u8,
    io: std.Io,
) !?RunOutcome {
    if (std.mem.indexOfScalar(u8, line, '\\') == null) {
        // Without a backslash every JSON string in `line` is spelled verbatim,
        // so a frame can only act on this client if the method names (or the
        // `"error"` key) and the current pane id appear literally.
        const is_error = containsSubstrSimd(line, "\"error\"");
        const is_result = state.pending_sends.count() != 0 and containsSubstrSimd(line, "\"result\"");
        const is_client = containsSubstrSimd(line, "client_");
        if (!is_error and !is_result and !is_client) {
            if (!containsSubstrSimd(line, "pane_") and
                !containsSubstrSimd(line, protocol.session_exited_method)) return null;
            if (!containsSubstrSimd(line, state.pane_id)) return null;
        }
        if (canonicalPaneOutput(line)) |frame| {
            if (frame.generation) |generation| {
                if (state.generation) |current| if (generation < current) return null;
            }
            if (!std.mem.eql(u8, frame.pane_id, state.pane_id)) return null;
            return applyPaneOutput(allocator, state, output, frame.generation, frame.offset, frame.data_base64);
        }
    }
    return handleServerLineDom(allocator, line, state, output, io);
}

/// Fields of a `pane_output` frame in the daemon's canonical wire layout.
const CanonicalPaneOutput = struct {
    pane_id: []const u8,
    data_base64: []const u8,
    offset: ?u64 = null,
    generation: ?u64 = null,
};

/// Match the exact layout `zmuxd` emits for `pane_output`, so the hot path
/// skips a JSON DOM parse over multi-kilobyte base64:
///   {"jsonrpc":"2.0","method":"pane_output","params":{"pane_id":"<id>",
///    "data_base64":"<b64>"[,"offset":<n>][,"generation":<n>]}}
/// The caller guarantees `line` has no backslash, so every string is
/// verbatim. Any other layout returns null and takes the DOM path; the result
/// is then identical because each accepted field is unique and well formed.
fn canonicalPaneOutput(line: []const u8) ?CanonicalPaneOutput {
    const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"";
    const mid = "\",\"data_base64\":\"";
    const trimmed = std.mem.trimEnd(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const id_end = std.mem.indexOfScalarPos(u8, trimmed, prefix.len, '"') orelse return null;
    assert(id_end >= prefix.len);
    const pane_id = trimmed[prefix.len..id_end];
    if (!isPlainJsonAscii(pane_id)) return null;
    if (!std.mem.startsWith(u8, trimmed[id_end..], mid)) return null;
    const b64_start = id_end + mid.len;
    const b64_end = std.mem.indexOfScalarPos(u8, trimmed, b64_start, '"') orelse return null;
    assert(b64_end >= b64_start);
    const data_base64 = trimmed[b64_start..b64_end];
    if (!isPlainJsonAscii(data_base64)) return null;

    var frame: CanonicalPaneOutput = .{ .pane_id = pane_id, .data_base64 = data_base64 };
    var rest = trimmed[b64_end + 1 ..];
    while (!std.mem.eql(u8, rest, "}}")) {
        const slot: *?u64 = if (std.mem.startsWith(u8, rest, ",\"offset\":"))
            &frame.offset
        else if (std.mem.startsWith(u8, rest, ",\"generation\":"))
            &frame.generation
        else
            return null;
        if (slot.* != null) return null;
        rest = rest[std.mem.indexOfScalar(u8, rest, ':').? + 1 ..];
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        // JSON forbids leading zeros; keep numbers well inside i64 so the DOM
        // would read the same `.integer`.
        if (digits == 0 or digits > 18 or (digits > 1 and rest[0] == '0')) return null;
        slot.* = std.fmt.parseInt(u64, rest[0..digits], 10) catch return null;
        rest = rest[digits..];
    }
    return frame;
}

/// Apply one daemon line to `state` through a JSON DOM parse.
pub fn handleServerLineDom(
    allocator: std.mem.Allocator,
    line: []const u8,
    state: *RunState,
    output: *?[]u8,
    io: std.Io,
) !?RunOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    const envelope = parsed.value;
    const id = jsonUnsigned(envelope, "id");
    const rpc_error = RpcError.fromEnvelope(envelope);
    if (id) |number| {
        if (std.math.cast(u32, number)) |request_id| {
            const is_reply = rpc_error != null or envelope.object.contains("result");
            if (is_reply and state.pending_sends.remove(request_id)) {
                if (rpc_error) |err| return reportRpcError(io, err);
                state.send_reply_deadline = sys.monotonicMs() + send_reply_timeout_ms;
                return null;
            }
        }
    }
    if (rpc_error) |err| {
        if (id) |n| if (n < first_interactive_id or n >= state.next_id) return null;
        printDiagnostic(io, "{f}", .{escaped(err.message)});
        if (err.is("terminated") or err.is("not_found")) return .session_ended;
        if (id == null) return error.RpcError;
        return null;
    }

    const method = jsonObjectString(envelope, "method") orelse return null;
    const params = jsonField(envelope, "params");
    if (std.mem.eql(u8, method, protocol.client_detached_method) or std.mem.eql(u8, method, "client_switched")) {
        return handleClientNotification(allocator, method, params, state, output);
    }
    return handlePaneNotification(allocator, method, params, state, output);
}

/// `client_detached` or `client_switched` addressed to this client.
fn handleClientNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: std.json.Value,
    state: *RunState,
    output: *?[]u8,
) !?RunOutcome {
    if (!jsonAnyStringEquals(params, &.{ "clientId", "client_id" }, state.client_id)) return null;
    if (std.mem.eql(u8, method, protocol.client_detached_method)) {
        const reason = jsonObjectString(params, "reason") orelse "";
        if (std.mem.eql(u8, reason, "remote_detach")) return .detached_remotely;
        return .session_ended;
    }
    const pane = jsonAnyObjectString(params, &.{ "paneId", "pane_id" }) orelse return error.InvalidResponse;
    if (pane.len == 0) return error.InvalidResponse;
    const new_pane = try allocator.dupe(u8, pane);
    if (state.switched_pane) |old_pane| allocator.free(old_pane);
    state.switched_pane = new_pane;
    state.pane_id = new_pane;
    assert(state.pane_id.len > 0);
    state.generation = jsonUnsigned(params, "generation");
    state.next_offset = jsonUnsigned(params, "replayEndOffset");
    output.* = try decodeReplay(allocator, params);
    g_winch_flag.store(true, .seq_cst);
    return null;
}

/// Session and pane notifications (`session_exited`, `pane_respawned`,
/// `pane_output_dropped`, `pane_output`) for the current pane.
fn handlePaneNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: std.json.Value,
    state: *RunState,
    output: *?[]u8,
) !?RunOutcome {
    const generation = jsonUnsigned(params, "generation");
    if (generation != null and state.generation != null and generation.? < state.generation.?) return null;

    if (std.mem.eql(u8, method, protocol.session_exited_method)) {
        if (jsonAnyStringEquals(params, &.{ "sessionId", "session_id" }, state.pane_id)) return .session_ended;
        return null;
    }
    if (!jsonAnyStringEquals(params, &.{ "paneId", "pane_id" }, state.pane_id)) return null;

    if (std.mem.eql(u8, method, protocol.pane_respawned_method)) {
        if (generation != state.generation) state.next_offset = null;
        state.generation = generation;
        return null;
    }
    if (std.mem.eql(u8, method, protocol.pane_output_dropped_method)) {
        if (generation != null and generation != state.generation) return null;
        if (jsonUnsigned(params, "resume_offset")) |offset|
            state.next_offset = @max(offset, state.next_offset orelse 0);
        return null;
    }
    if (!std.mem.eql(u8, method, protocol.pane_output_method)) return null;
    const encoded = jsonAnyObjectString(params, &.{ "dataBase64", "data_base64" });
    return applyPaneOutput(allocator, state, output, generation, jsonUnsigned(params, "offset"), encoded);
}

/// Apply a `pane_output` frame already matched to the current pane.
fn applyPaneOutput(
    allocator: std.mem.Allocator,
    state: *RunState,
    output: *?[]u8,
    generation: ?u64,
    offset_field: ?u64,
    encoded_field: ?[]const u8,
) !?RunOutcome {
    if (generation != null and generation != state.generation) {
        state.generation = generation;
        state.next_offset = null;
    }
    const encoded = encoded_field orelse return null;
    // A corrupt frame is dropped, never surfaced as a run-loop error.
    const bytes = base64Decode(allocator, encoded) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    errdefer allocator.free(bytes);
    const skip: usize = if (offset_field) |offset| blk: {
        const previous = state.next_offset orelse offset;
        state.next_offset = @max(previous, offset +| bytes.len);
        break :blk @intCast(@min(previous -| offset, bytes.len));
    } else 0;
    assert(skip <= bytes.len);
    if (skip == 0 and bytes.len != 0) {
        output.* = bytes;
    } else {
        if (skip < bytes.len) output.* = try allocator.dupe(u8, bytes[skip..]);
        allocator.free(bytes);
    }
    return null;
}

test "replay overlap, dropped bytes, switching and respawn follow the current pane" {
    const alloc = std.testing.allocator;
    var state: RunState = .{ .pane_id = "p", .client_id = "c", .generation = 1, .next_offset = 4 };
    defer if (state.switched_pane) |pane| alloc.free(pane);
    var output: ?[]u8 = null;
    const line = "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"generation\":1,\"offset\":2,\"data_base64\":\"YWJjZA==\"}}";
    try std.testing.expectEqual(null, try handleServerLine(alloc, line, &state, &output, test_io));
    try std.testing.expectEqualStrings("cd", output.?);
    alloc.free(output.?);
    output = null;
    _ = try handleServerLine(alloc, line, &state, &output, test_io);
    try std.testing.expect(output == null);
    _ = try handleServerLine(alloc, "{\"method\":\"pane_output_dropped\",\"params\":{\"pane_id\":\"p\",\"resume_offset\":20}}", &state, &output, test_io);
    try std.testing.expectEqual(@as(?u64, 20), state.next_offset);
    _ = try handleServerLine(alloc, "{\"method\":\"pane_respawned\",\"params\":{\"pane_id\":\"p\",\"generation\":2}}", &state, &output, test_io);
    try std.testing.expect(state.next_offset == null);
    const old = "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\",\"generation\":1}}";
    try std.testing.expectEqual(null, try handleServerLine(alloc, old, &state, &output, test_io));
    _ = try handleServerLine(alloc, "{\"method\":\"client_switched\",\"params\":{\"clientId\":\"c\",\"paneId\":\"q\",\"generation\":0}}", &state, &output, test_io);
    try std.testing.expectEqualStrings("q", state.pane_id);
    try std.testing.expectEqual(RunOutcome.detached_remotely, (try handleServerLine(alloc, "{\"method\":\"client_detached\",\"params\":{\"client_id\":\"c\",\"reason\":\"remote_detach\"}}", &state, &output, test_io)).?);
}

test "handleServerLine ignores corrupt base64 on every parse path without erroring" {
    // Canonical wire layout, reordered/camelCase keys, and an escaped key
    // (DOM path) must all drop the frame rather than fail the run loop.
    const alloc = std.testing.allocator;
    const frames = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"!!!not-valid-b64!!!\"}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"abc\",\"offset\":0,\"generation\":1}}\n",
        "{\"method\":\"pane_output\",\"jsonrpc\":\"2.0\",\"params\":{\"dataBase64\":\"=\",\"paneId\":\"pane-1\"}}\n",
        "{\"method\":\"pane_output\",\"params\":{\"pane_\\u0069d\":\"pane-1\",\"data_base64\":\"a\"}}\n",
    };
    for (frames) |frame| {
        var state: RunState = .{ .pane_id = "pane-1", .client_id = "c", .generation = 1, .next_offset = null };
        var output: ?[]u8 = null;
        try std.testing.expectEqual(null, try handleServerLine(alloc, frame, &state, &output, test_io));
        try std.testing.expect(output == null);
    }
}

test "handleServerLine fast paths match the DOM path" {
    const alloc = std.testing.allocator;
    const frames = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\"}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\",\"offset\":3,\"generation\":2}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\",\"generation\":1,\"offset\":12}}\r\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\",\"generation\":0}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\",\"offset\":1,\"offset\":2}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\",\"offset\":01}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"pane-2\",\"data_base64\":\"aGVsbG8=\"}}\n",
        "{\"method\":\"pane_output\",\"params\":{\"paneId\":\"pane-1\",\"dataBase64\":\"aGVsbG8=\"},\"jsonrpc\":\"2.0\"}\n",
        "{\"method\":\"pane_\\u006futput\",\"params\":{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\"}}\n",
        "{\"method\":\"pane_activity\",\"params\":{\"pane_id\":\"pane-1\"}}\n",
        "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"pane-1\"}}\n",
        "{\"method\":\"pane_respawned\",\"params\":{\"pane_id\":\"pane-1\",\"generation\":5}}\n",
    };
    for (frames) |frame| {
        var fast: RunState = .{ .pane_id = "pane-1", .client_id = "c", .generation = 1, .next_offset = 10 };
        var dom = fast;
        var fast_out: ?[]u8 = null;
        defer if (fast_out) |bytes| alloc.free(bytes);
        var dom_out: ?[]u8 = null;
        defer if (dom_out) |bytes| alloc.free(bytes);
        const fast_outcome = try handleServerLine(alloc, frame, &fast, &fast_out, test_io);
        const dom_outcome = try handleServerLineDom(alloc, frame, &dom, &dom_out, test_io);
        try std.testing.expectEqual(dom_outcome, fast_outcome);
        try std.testing.expectEqual(dom.generation, fast.generation);
        try std.testing.expectEqual(dom.next_offset, fast.next_offset);
        try std.testing.expectEqual(dom_out == null, fast_out == null);
        if (dom_out) |bytes| try std.testing.expectEqualStrings(bytes, fast_out.?);
    }
}

test "canonicalPaneOutput accepts only the exact daemon layout" {
    const ok = canonicalPaneOutput("{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\",\"offset\":7,\"generation\":2}}\n").?;
    try std.testing.expectEqualStrings("p", ok.pane_id);
    try std.testing.expectEqualStrings("b2s=", ok.data_base64);
    try std.testing.expectEqual(@as(?u64, 7), ok.offset);
    try std.testing.expectEqual(@as(?u64, 2), ok.generation);
    try std.testing.expect(canonicalPaneOutput("{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\",\"extra\":1}}") == null);
    try std.testing.expect(canonicalPaneOutput("{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\"}}}") == null);
    try std.testing.expect(canonicalPaneOutput("{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\",\"offset\":-1}}") == null);
}
