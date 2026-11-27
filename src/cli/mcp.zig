//! Zero-dependency built-in Model Context Protocol (MCP) stdio server (`zmux mcp`).
//!
//! Speaks newline-delimited JSON-RPC 2.0 over stdin/stdout supporting MCP
//! protocol versions `2024-11-05` and `2025-03-26`, exposing 9 structured zmux
//! tools backed directly by the local `zmuxd` UNIX socket.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const connect_terminal = @import("../connect/terminal.zig");
const connect_wire = @import("../connect/wire.zig");
const protocol = @import("../protocol.zig");
const LineReader = @import("../rpc_line_reader.zig").LineReader;
const sys = @import("../sys.zig");
const help = @import("help.zig");
const mcp_tools = @import("mcp_tools.zig");
const rpc = @import("rpc.zig");

const test_io = std.testing.io;

/// Default MCP protocol version advertised when the client omits or asks for `2024-11-05`.
pub const default_protocol_version = "2024-11-05";

/// Newer MCP protocol version echoed when requested by the client.
pub const modern_protocol_version = "2025-03-26";

/// Maximum incoming MCP JSON-RPC line accepted over stdio (1 MiB).
pub const max_mcp_line_bytes: usize = 1024 * 1024;

/// Re-exported MCP tool catalog and tool kinds.
pub const tools = mcp_tools;

/// Parsed fields of an MCP `tools/call` request.
pub const ToolCall = struct {
    kind: mcp_tools.ToolKind,
    name: []const u8,
    arguments: std.json.Value,
};

/// Errors produced when parsing an MCP `tools/call` params object.
pub const ParseToolCallError = error{
    InvalidParams,
    UnknownTool,
};

/// Runtime options for `handleMcpLineWithOpts` and `runStdioServer`.
pub const ServerOptions = struct {
    socket_path: ?[]const u8 = null,
    spawn_daemon: bool = true,
};

/// Validate and extract the tool kind and arguments from a `tools/call` params object.
pub fn parseToolCall(params: std.json.Value) ParseToolCallError!ToolCall {
    if (params != .object) return error.InvalidParams;
    const name = connect_wire.jsonObjectString(params, "name") orelse return error.InvalidParams;
    if (name.len == 0) return error.InvalidParams;
    const kind = mcp_tools.findTool(name) orelse return error.UnknownTool;
    const arguments = connect_wire.jsonField(params, "arguments");
    if (arguments != .null and arguments != .object) return error.InvalidParams;
    assert(name.len > 0);
    return .{ .kind = kind, .name = name, .arguments = arguments };
}

/// Process one newline-delimited MCP JSON-RPC line and return an optional response line.
/// Returns `null` for notifications (such as `notifications/initialized`) or blank lines.
pub fn handleMcpLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    socket_path: ?[]const u8,
    line: []const u8,
) !?[]u8 {
    return handleMcpLineWithOpts(allocator, io, .{ .socket_path = socket_path, .spawn_daemon = true }, line);
}

/// Process one MCP line with explicit `ServerOptions` (socket override and auto-spawn toggle).
pub fn handleMcpLineWithOpts(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ServerOptions,
    line: []const u8,
) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    var req = protocol.parseRequest(allocator, trimmed) catch |err| {
        return switch (err) {
            error.OutOfMemory => err,
            error.ParseError => try protocol.@"error"(
                allocator,
                "null",
                protocol.ErrorCode.parse_error,
                "Parse error",
            ),
            else => try protocol.@"error"(
                allocator,
                "null",
                protocol.ErrorCode.invalid_request,
                "Invalid Request",
            ),
        };
    };
    defer req.deinit();

    if (protocol.isNotification(&req)) return null;
    assert(req.id_json.len > 0);

    if (std.mem.eql(u8, req.method, "initialize")) {
        return try buildInitializeResponse(allocator, req.id_json, req.params() orelse .null);
    }
    if (std.mem.eql(u8, req.method, "ping")) {
        return try protocol.resultRaw(allocator, req.id_json, "{}");
    }
    if (std.mem.eql(u8, req.method, "tools/list")) {
        const list_json = try mcp_tools.formatToolsListResult(allocator);
        defer allocator.free(list_json);
        return try protocol.resultRaw(allocator, req.id_json, list_json);
    }
    if (std.mem.eql(u8, req.method, "tools/call")) {
        return try dispatchToolCall(allocator, io, opts, req.id_json, req.params() orelse .null);
    }
    return try protocol.@"error"(allocator, req.id_json, protocol.ErrorCode.method_not_found, "Method not found");
}

/// Process one MCP `tools/call` against an existing `RpcClient` (ideal for unit tests).
pub fn dispatchToolCallOnClient(
    allocator: std.mem.Allocator,
    client: *rpc.RpcClient,
    id_json: []const u8,
    params: std.json.Value,
) ![]u8 {
    assert(id_json.len > 0);
    const call = parseToolCall(params) catch |err| switch (err) {
        error.UnknownTool => return protocol.@"error"(
            allocator,
            id_json,
            protocol.ErrorCode.invalid_params,
            "Unknown tool",
        ),
        error.InvalidParams => return protocol.@"error"(
            allocator,
            id_json,
            protocol.ErrorCode.invalid_params,
            "Invalid tool call parameters",
        ),
    };
    const outcome = mcp_tools.executeOnClient(allocator, client, call.kind, call.arguments) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidArguments, error.UnknownTool => return protocol.@"error"(
            allocator,
            id_json,
            protocol.ErrorCode.invalid_params,
            "Invalid tool arguments",
        ),
        else => {
            const msg = try std.fmt.allocPrint(allocator, "zmux daemon error: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            const raw = try mcp_tools.formatToolOutcomeJson(allocator, .{ .text = msg, .is_error = true });
            defer allocator.free(raw);
            return protocol.resultRaw(allocator, id_json, raw);
        },
    };
    defer outcome.deinit(allocator);
    const raw = try mcp_tools.formatToolOutcomeJson(allocator, outcome);
    defer allocator.free(raw);
    return protocol.resultRaw(allocator, id_json, raw);
}

fn dispatchToolCall(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ServerOptions,
    id_json: []const u8,
    params: std.json.Value,
) ![]u8 {
    // Validate tool name and parameter shape before touching the UNIX socket.
    _ = parseToolCall(params) catch |err| switch (err) {
        error.UnknownTool => return protocol.@"error"(
            allocator,
            id_json,
            protocol.ErrorCode.invalid_params,
            "Unknown tool",
        ),
        error.InvalidParams => return protocol.@"error"(
            allocator,
            id_json,
            protocol.ErrorCode.invalid_params,
            "Invalid tool call parameters",
        ),
    };
    var client = rpc.RpcClient.connect(allocator, io, opts.socket_path, opts.spawn_daemon) catch |err| {
        if (err == error.OutOfMemory) return err;
        const msg = try std.fmt.allocPrint(allocator, "failed to connect to zmuxd: {s}", .{@errorName(err)});
        defer allocator.free(msg);
        const raw = try mcp_tools.formatToolOutcomeJson(allocator, .{ .text = msg, .is_error = true });
        defer allocator.free(raw);
        return protocol.resultRaw(allocator, id_json, raw);
    };
    defer client.deinit();
    return dispatchToolCallOnClient(allocator, &client, id_json, params);
}

fn buildInitializeResponse(allocator: std.mem.Allocator, id_json: []const u8, params: std.json.Value) ![]u8 {
    const requested = connect_wire.jsonObjectString(params, "protocolVersion");
    const negotiated = if (requested) |ver|
        if (std.mem.eql(u8, ver, modern_protocol_version)) modern_protocol_version else default_protocol_version
    else
        default_protocol_version;
    assert(negotiated.len == 10);
    return protocol.result(allocator, id_json, .{
        .protocolVersion = negotiated,
        .capabilities = .{ .tools = .{} },
        .serverInfo = .{ .name = "zmux", .version = protocol.version },
    });
}

/// Run the blocking stdio MCP server reading from `in_fd` and writing to `out_fd`.
pub fn runStdioLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ServerOptions,
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
) !void {
    assert(in_fd >= 0 and out_fd >= 0);
    var reader: LineReader = .{};
    defer reader.deinit();

    while (true) {
        const maybe_line = reader.readLineAllocMaybe(allocator, in_fd, max_mcp_line_bytes) catch |err| switch (err) {
            error.MessageTooLarge => {
                const frame = try protocol.@"error"(
                    allocator,
                    "null",
                    protocol.ErrorCode.invalid_request,
                    "Request line too large",
                );
                defer allocator.free(frame);
                try connect_terminal.writeAllFd(out_fd, frame);
                continue;
            },
            else => return err,
        };
        const line = maybe_line orelse return;
        defer allocator.free(line);

        if (try handleMcpLineWithOpts(allocator, io, opts, line)) |reply| {
            defer allocator.free(reply);
            assert(reply.len > 0 and reply[reply.len - 1] == '\n');
            try connect_terminal.writeAllFd(out_fd, reply);
        }
    }
}

/// Start the `zmux mcp` server on process stdin (0) and stdout (1).
pub fn run(allocator: std.mem.Allocator, io: std.Io, socket_path: ?[]const u8, spawn_daemon: bool) !void {
    runStdioLoop(allocator, io, .{ .socket_path = socket_path, .spawn_daemon = spawn_daemon }, 0, 1) catch |err| {
        if (err == error.BrokenPipe) return;
        return help.diagnostic(io, "mcp server stopped: {s}", .{@errorName(err)});
    };
}

test "MCP initialize, notifications/initialized, ping, and tools/list round-trip" {
    const alloc = std.testing.allocator;

    const init_reply = (try handleMcpLine(
        alloc,
        test_io,
        null,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}",
    )).?;
    defer alloc.free(init_reply);
    try std.testing.expect(std.mem.indexOf(u8, init_reply, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_reply, "\"name\":\"zmux\"") != null);

    const notif_reply = try handleMcpLine(
        alloc,
        test_io,
        null,
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
    );
    try std.testing.expect(notif_reply == null);

    const ping_reply = (try handleMcpLine(
        alloc,
        test_io,
        null,
        "{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"method\":\"ping\"}",
    )).?;
    defer alloc.free(ping_reply);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"p1\",\"result\":{}}\n", ping_reply);

    const tools_reply = (try handleMcpLine(
        alloc,
        test_io,
        null,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
    )).?;
    defer alloc.free(tools_reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, tools_reply, .{});
    defer parsed.deinit();
    const list = parsed.value.object.get("result").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 9), list.len);
}

test "MCP handles malformed JSON, unknown methods, and unknown tools cleanly" {
    const alloc = std.testing.allocator;
    const parse_err = (try handleMcpLine(alloc, test_io, null, "{broken")).?;
    defer alloc.free(parse_err);
    try std.testing.expect(std.mem.indexOf(u8, parse_err, "-32700") != null);

    const unknown_method = (try handleMcpLine(
        alloc,
        test_io,
        null,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/nope\"}",
    )).?;
    defer alloc.free(unknown_method);
    try std.testing.expect(std.mem.indexOf(u8, unknown_method, "-32601") != null);

    const unknown_tool = (try handleMcpLine(
        alloc,
        test_io,
        null,
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"no_such_tool\",\"arguments\":{}}}",
    )).?;
    defer alloc.free(unknown_tool);
    try std.testing.expect(std.mem.indexOf(u8, unknown_tool, "-32602") != null);
}

test "MCP dispatchToolCallOnClient executes zmux_list_sessions over socketPair" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[{\"sessionId\":\"s1\",\"paneId\":\"p1\"}]}\n",
    );
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    var params = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"name\":\"zmux_list_sessions\",\"arguments\":{}}",
        .{},
    );
    defer params.deinit();

    const reply = try dispatchToolCallOnClient(alloc, &client, "99", params.value);
    defer alloc.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"id\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"isError\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "s1") != null);
}

test "MCP runStdioLoop processes pipelined stdin frames and exits on EOF" {
    const alloc = std.testing.allocator;
    const in_pipe = try sys.pipe();
    defer sys.close(in_pipe[0]);
    const out_pipe = try sys.pipe();
    defer sys.close(out_pipe[0]);
    defer sys.close(out_pipe[1]);

    try sys.writeAll(
        in_pipe[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n",
    );
    sys.close(in_pipe[1]);

    try runStdioLoop(alloc, test_io, .{ .spawn_daemon = false }, in_pipe[0], out_pipe[1]);
    var buf: [256]u8 = undefined;
    const n = try posix.read(out_pipe[0], &buf);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n", buf[0..n]);
}
