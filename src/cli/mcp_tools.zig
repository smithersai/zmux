//! MCP tool catalog (9 zmux tools with JSON Schema `inputSchema`) and
//! tool-to-RPC execution bridge for `zmux mcp`.

const std = @import("std");
const assert = std.debug.assert;
const connect_wire = @import("../connect/wire.zig");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const args_mod = @import("args.zig");
const rpc = @import("rpc.zig");

const test_io = std.testing.io;

/// Enumeration of the 9 built-in MCP tools exposed by `zmux mcp`.
pub const ToolKind = enum {
    list_sessions,
    create_session,
    send_input,
    send_key,
    read_screen,
    wait,
    exec,
    signal,
    terminate,
};

/// Static metadata and JSON Schema for one MCP tool entry.
pub const ToolSpec = struct {
    kind: ToolKind,
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

/// Canonical catalog of all 9 MCP tools exposed by `zmux mcp`.
pub const catalog = [_]ToolSpec{
    .{
        .kind = .list_sessions,
        .name = "zmux_list_sessions",
        .description = "List all zmux sessions and panes with PID, state, and title metadata.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}",
    },
    .{
        .kind = .create_session,
        .name = "zmux_create_session",
        .description = "Create a new zmux session and PTY pane with optional name, command, cwd, and size.",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{" ++
            "\"name\":{\"type\":\"string\",\"description\":\"Optional session name\"}," ++
            "\"command\":{\"type\":\"string\",\"description\":\"Optional command to run\"}," ++
            "\"cwd\":{\"type\":\"string\",\"description\":\"Initial working directory\"}," ++
            "\"rows\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65535}," ++
            "\"cols\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65535}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .send_input,
        .name = "zmux_send_input",
        .description = "Send UTF-8 text input to a running zmux session or pane, optionally pressing Enter.",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\",\"text\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Session or pane target\"}," ++
            "\"text\":{\"type\":\"string\",\"description\":\"UTF-8 text to write to the PTY\"}," ++
            "\"enter\":{\"type\":\"boolean\",\"default\":false,\"description\":\"Append carriage return\"}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .send_key,
        .name = "zmux_send_key",
        .description = "Send a named tmux-style key (Enter, C-c, Escape, ArrowUp, F1-F12) to a pane.",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\",\"key\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1}," ++
            "\"key\":{\"type\":\"string\",\"minLength\":1,\"description\":\"Key name such as Enter or C-c\"}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .read_screen,
        .name = "zmux_read_screen",
        .description = "Read rendered VT screen state, OSC metadata, and text (falls back to capture on v0.4.0).",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1}," ++
            "\"scrollback\":{\"type\":\"integer\",\"minimum\":0,\"default\":0}," ++
            "\"includeCells\":{\"type\":\"boolean\",\"default\":false}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .wait,
        .name = "zmux_wait",
        .description = "Wait until a pane matches text, exits, becomes idle, or finishes a shell command.",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1}," ++
            "\"pattern\":{\"type\":\"string\"}," ++
            "\"exit\":{\"type\":\"boolean\"}," ++
            "\"idleMs\":{\"type\":\"integer\",\"minimum\":1}," ++
            "\"commandDone\":{\"type\":\"boolean\"}," ++
            "\"timeoutMs\":{\"type\":\"integer\",\"minimum\":1,\"default\":30000}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .exec,
        .name = "zmux_exec",
        .description = "Execute a shell command inside a pane and collect its exit code and output.",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\",\"command\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1}," ++
            "\"command\":{\"type\":\"string\",\"minLength\":1}," ++
            "\"timeoutMs\":{\"type\":\"integer\",\"minimum\":1,\"default\":30000}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .signal,
        .name = "zmux_signal",
        .description = "Send a POSIX signal (INT, TERM, KILL, HUP, STOP, CONT, WINCH, USR1, USR2) to a pane.",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\",\"signal\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1}," ++
            "\"signal\":{\"type\":\"string\",\"minLength\":1}" ++
            "},\"additionalProperties\":false}",
    },
    .{
        .kind = .terminate,
        .name = "zmux_terminate",
        .description = "Terminate a zmux session or pane and clean up its PTY process.",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"target\"],\"properties\":{" ++
            "\"target\":{\"type\":\"string\",\"minLength\":1}" ++
            "},\"additionalProperties\":false}",
    },
};

/// Outcome of executing one MCP tool call, serialized into MCP `content[]`.
pub const ToolOutcome = struct {
    text: []u8,
    is_error: bool,

    /// Release the owned response text.
    pub fn deinit(self: ToolOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Errors produced when validating MCP `tools/call` arguments before RPC dispatch.
pub const ToolArgError = error{
    UnknownTool,
    InvalidArguments,
    OutOfMemory,
};

/// Look up a tool by MCP tool name.
pub fn findTool(name: []const u8) ?ToolKind {
    assert(catalog.len == 9);
    for (catalog) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec.kind;
    }
    return null;
}

/// Serialize the `tools/list` result object `{"tools":[...]}` into an owned slice.
pub fn formatToolsListResult(allocator: std.mem.Allocator) ![]u8 {
    assert(catalog.len == 9);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 2048);
    errdefer out.deinit();
    try out.writer.writeAll("{\"tools\":[");
    for (catalog, 0..) |spec, idx| {
        if (idx > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(spec.name, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(spec.description, .{}, &out.writer);
        try out.writer.writeAll(",\"inputSchema\":");
        try out.writer.writeAll(spec.input_schema_json);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    assert(out.written().len > 100);
    return out.toOwnedSlice();
}

/// Format a `ToolOutcome` as an MCP `tools/call` result JSON object.
pub fn formatToolOutcomeJson(allocator: std.mem.Allocator, outcome: ToolOutcome) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, outcome.text.len + 96);
    errdefer out.deinit();
    try out.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try protocol.writeJsonStringLossy(&out.writer, outcome.text);
    try out.writer.print("}}],\"isError\":{}}}", .{outcome.is_error});
    assert(out.written().len > 20);
    return out.toOwnedSlice();
}

/// Validate `arguments` and execute `kind` against an open `RpcClient`.
pub fn executeOnClient(
    allocator: std.mem.Allocator,
    client: *rpc.RpcClient,
    kind: ToolKind,
    arguments: std.json.Value,
) !ToolOutcome {
    assert(client.fd >= 0);
    if (arguments != .object and arguments != .null) return error.InvalidArguments;
    return switch (kind) {
        .list_sessions => callAndPack(allocator, client, "session.list", .{}, rpc.default_timeout_ms),
        .create_session => execCreate(allocator, client, arguments),
        .send_input => execSendInput(allocator, client, arguments),
        .send_key => execSendKey(allocator, client, arguments),
        .read_screen => execReadScreen(allocator, client, arguments),
        .wait => execWait(allocator, client, arguments),
        .exec => execPaneCommand(allocator, client, arguments),
        .signal => execSignal(allocator, client, arguments),
        .terminate => execTerminate(allocator, client, arguments),
    };
}

fn requiredTarget(arguments: std.json.Value) ToolArgError![]const u8 {
    const val = connect_wire.jsonObjectString(arguments, "target") orelse
        connect_wire.jsonObjectString(arguments, "sessionId") orelse
        connect_wire.jsonObjectString(arguments, "paneId") orelse return error.InvalidArguments;
    if (val.len == 0) return error.InvalidArguments;
    assert(val.len > 0);
    return val;
}

fn optionalBool(arguments: std.json.Value, key: []const u8) ToolArgError!?bool {
    assert(key.len > 0);
    const field = connect_wire.jsonField(arguments, key);
    return switch (field) {
        .null => null,
        .bool => field.bool,
        else => error.InvalidArguments,
    };
}

fn optionalDimension(arguments: std.json.Value, key: []const u8) ToolArgError!?u16 {
    assert(key.len > 0);
    const field = connect_wire.jsonField(arguments, key);
    if (field == .null) return null;
    if (field != .integer or field.integer < 1 or field.integer > 65535) return error.InvalidArguments;
    return @intCast(field.integer);
}

fn optionalU64(arguments: std.json.Value, key: []const u8, min_val: u64) ToolArgError!?u64 {
    assert(key.len > 0);
    const field = connect_wire.jsonField(arguments, key);
    if (field == .null) return null;
    if (field != .integer or field.integer < 0) return error.InvalidArguments;
    const val: u64 = @intCast(field.integer);
    if (val < min_val) return error.InvalidArguments;
    return val;
}

fn packResponse(allocator: std.mem.Allocator, resp: rpc.Response) !ToolOutcome {
    if (resp.rpcError()) |err| {
        const msg = try std.fmt.allocPrint(allocator, "RPC error: {s}", .{err.message});
        assert(msg.len > 0);
        return .{ .text = msg, .is_error = true };
    }
    const text = try protocol.jsonValueAlloc(allocator, resp.result());
    assert(text.len > 0);
    return .{ .text = text, .is_error = false };
}

fn callAndPack(
    allocator: std.mem.Allocator,
    client: *rpc.RpcClient,
    method: []const u8,
    params: anytype,
    timeout_ms: i64,
) !ToolOutcome {
    const resp = try client.call(method, params, timeout_ms);
    defer resp.deinit(client.allocator);
    return packResponse(allocator, resp);
}

fn execCreate(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const rows = try optionalDimension(args, "rows");
    const cols = try optionalDimension(args, "cols");
    return callAndPack(allocator, client, "session.create", .{
        .name = connect_wire.jsonObjectString(args, "name"),
        .command = connect_wire.jsonObjectString(args, "command"),
        .cwd = connect_wire.jsonObjectString(args, "cwd"),
        .rows = rows,
        .cols = cols,
    }, rpc.default_timeout_ms);
}

fn execSendInput(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    const text = connect_wire.jsonObjectString(args, "text") orelse return error.InvalidArguments;
    const enter = (try optionalBool(args, "enter")) orelse false;
    return callAndPack(allocator, client, "session.send", .{
        .sessionId = target,
        .text = text,
        .enter = enter,
    }, rpc.default_timeout_ms);
}

fn execSendKey(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    const key = connect_wire.jsonObjectString(args, "key") orelse return error.InvalidArguments;
    if (key.len == 0) return error.InvalidArguments;
    return callAndPack(allocator, client, "session.sendKey", .{
        .sessionId = target,
        .key = key,
    }, rpc.default_timeout_ms);
}

fn execReadScreen(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    const sb = (try optionalU64(args, "scrollback", 0)) orelse 0;
    const cells = (try optionalBool(args, "includeCells")) orelse false;
    const resp = try client.call("session.screen", .{
        .sessionId = target,
        .includeScrollback = sb,
        .includeCells = cells,
    }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);

    if (resp.rpcError()) |err| {
        if (err.isMethodNotFound()) {
            const lines = 200 +| sb;
            return callAndPack(
                allocator,
                client,
                "session.capture",
                .{ .sessionId = target, .lines = lines },
                rpc.default_timeout_ms,
            );
        }
    }
    return packResponse(allocator, resp);
}

fn execWait(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    const timeout_ms = (try optionalU64(args, "timeoutMs", 1)) orelse 30_000;
    const rpc_timeout: i64 = @intCast(@min(timeout_ms +| 5_000, 600_000));
    return callAndPack(allocator, client, "pane.wait", .{
        .paneId = target,
        .pattern = connect_wire.jsonObjectString(args, "pattern"),
        .exit = try optionalBool(args, "exit"),
        .idleMs = try optionalU64(args, "idleMs", 1),
        .commandDone = try optionalBool(args, "commandDone"),
        .timeoutMs = timeout_ms,
    }, rpc_timeout);
}

fn execPaneCommand(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    const cmd = connect_wire.jsonObjectString(args, "command") orelse return error.InvalidArguments;
    if (cmd.len == 0) return error.InvalidArguments;
    const timeout_ms = (try optionalU64(args, "timeoutMs", 1)) orelse 30_000;
    const rpc_timeout: i64 = @intCast(@min(timeout_ms +| 5_000, 600_000));
    return callAndPack(allocator, client, "pane.exec", .{
        .paneId = target,
        .command = cmd,
        .timeoutMs = timeout_ms,
    }, rpc_timeout);
}

fn execSignal(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    const raw_sig = connect_wire.jsonObjectString(args, "signal") orelse return error.InvalidArguments;
    const sig = args_mod.normalizeSignal(raw_sig) orelse return error.InvalidArguments;
    return callAndPack(allocator, client, "pane.signal", .{
        .paneId = target,
        .signal = sig,
    }, rpc.default_timeout_ms);
}

fn execTerminate(allocator: std.mem.Allocator, client: *rpc.RpcClient, args: std.json.Value) !ToolOutcome {
    const target = try requiredTarget(args);
    return callAndPack(allocator, client, "session.terminate", .{
        .sessionId = target,
    }, rpc.default_timeout_ms);
}

test "catalog defines all 9 tools with valid JSON schemas" {
    const alloc = std.testing.allocator;
    const list_json = try formatToolsListResult(alloc);
    defer alloc.free(list_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, list_json, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 9), tools.len);
    for (tools) |tool| {
        const name = tool.object.get("name").?.string;
        try std.testing.expect(findTool(name) != null);
        try std.testing.expect(tool.object.get("inputSchema").? == .object);
    }
}

test "zmux_read_screen falls back to session.capture on v0.4.0 daemons" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"MethodNotFound\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"w\",\"text\":\"hello\",\"textBase64\":\"aGVsbG8=\"}}\n",
    );
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    var args_parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"target\":\"w\"}", .{});
    defer args_parsed.deinit();
    const outcome = try executeOnClient(alloc, &client, .read_screen, args_parsed.value);
    defer outcome.deinit(alloc);
    try std.testing.expect(!outcome.is_error);
    try std.testing.expect(std.mem.indexOf(u8, outcome.text, "hello") != null);
}

test "tool validation rejects missing required fields and invalid signal names" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    var empty = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer empty.deinit();
    try std.testing.expectError(error.InvalidArguments, executeOnClient(alloc, &client, .send_input, empty.value));
    try std.testing.expectError(error.InvalidArguments, executeOnClient(alloc, &client, .terminate, empty.value));

    var bad_sig = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"target\":\"p1\",\"signal\":\"INVALID\"}",
        .{},
    );
    defer bad_sig.deinit();
    try std.testing.expectError(error.InvalidArguments, executeOnClient(alloc, &client, .signal, bad_sig.value));
}
