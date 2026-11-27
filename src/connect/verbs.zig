//! Management verbs: `zmux-connect ls|kill|rename|shutdown ...` map onto single
//! JSON-RPC calls, print human-readable output (or --json for the raw frame),
//! and exit non-zero with the daemon's error message on stderr.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const sys = @import("../sys.zig");
const LineReader = @import("../rpc_line_reader.zig").LineReader;
const cli = @import("cli.zig");
const rpc = @import("rpc.zig");
const spawn = @import("spawn.zig");
const terminal = @import("terminal.zig");
const wire = @import("wire.zig");

const Verb = cli.Verb;
const ParseVerbArgsFailure = cli.ParseVerbArgsFailure;
const parseVerbArgs = cli.parseVerbArgs;
const fail = cli.fail;
const escaped = cli.escaped;
const printUsage = cli.printUsage;
const verbName = cli.verbName;
const reportRpcError = cli.reportRpcError;
const resolveSocketPath = spawn.resolveSocketPath;
const connectWithRetry = spawn.connectWithRetry;
const Deadline = rpc.Deadline;
const exchange = rpc.exchange;
const writeAllFd = terminal.writeAllFd;
const bootstrap_response_timeout_ms = wire.bootstrap_response_timeout_ms;
const verb_rpc_id = wire.verb_rpc_id;
const jsonObjectString = wire.jsonObjectString;
const jsonUnsigned = wire.jsonUnsigned;

const test_io = std.testing.io;

/// Parse and run one management verb.
pub fn runVerb(
    allocator: std.mem.Allocator,
    io: std.Io,
    verb: Verb,
    rest: []const []const u8,
    global_socket: ?[]const u8,
) !void {
    var failure: ParseVerbArgsFailure = .{ .err = error.UnknownFlag };
    const parsed = parseVerbArgs(verb, rest, &failure) catch |err| switch (err) {
        error.MissingSocketValue => return fail(io, "missing value for --socket", .{}),
        error.UnknownFlag => return fail(io, "unknown flag: {f}", .{escaped(failure.arg.?)}),
        error.UnexpectedArgument => return fail(io, "unexpected argument: {f}", .{escaped(failure.arg.?)}),
        error.MissingTarget => return fail(io, "{s} requires a session id", .{verbName(verb)}),
        error.MissingNewName => return fail(io, "rename requires a new name", .{}),
    };

    if (parsed.show_help) {
        try printUsage(io);
        return;
    }

    const target = parsed.target;
    const new_name = parsed.new_name;
    assert(target != null or !verbNeedsTarget(verb));
    assert(new_name != null or verb != .rename);
    const json = parsed.json;
    const path = try resolveSocketPath(allocator, io, parsed.explicit_socket orelse global_socket);
    defer allocator.free(path);

    const socket_fd = try connectWithRetry(allocator, io, path, false);
    defer sys.close(socket_fd);

    var reader: LineReader = .{};
    defer reader.deinit();
    try executeVerb(
        allocator,
        socket_fd,
        &reader,
        verb,
        target,
        new_name,
        json,
        1,
        .fromNow(io, bootstrap_response_timeout_ms),
    );
}

/// Send a verb request and print its result to `out_fd`.
pub fn executeVerb(
    allocator: std.mem.Allocator,
    socket_fd: posix.fd_t,
    reader: *LineReader,
    verb: Verb,
    target: ?[]const u8,
    new_name: ?[]const u8,
    json: bool,
    out_fd: posix.fd_t,
    deadline: Deadline,
) !void {
    assert(socket_fd >= 0 and out_fd >= 0);
    assert(target != null or !verbNeedsTarget(verb));
    const request = try buildVerbRequest(allocator, verb, target, new_name);
    defer allocator.free(request);
    assert(request.len > 0 and request[request.len - 1] == '\n');
    const operation = switch (verb) {
        .list => "session.list",
        .kill => "session.terminate",
        .rename => "session.rename",
        .shutdown => "daemon.shutdown",
    };
    const response = try exchange(allocator, reader, socket_fd, verb_rpc_id, operation, request, deadline);
    defer response.deinit(allocator);

    const rpc_err = response.rpcError();
    if (json) {
        try writeAllFd(out_fd, response.line);
        if (rpc_err != null) return error.RpcError;
        return;
    }
    if (rpc_err) |err| return reportRpcError(deadline.io, err);
    if (response.result() == .null) return error.InvalidResponse;

    const human = try formatVerbResult(allocator, verb, target, new_name, response.result());
    defer allocator.free(human);
    try writeAllFd(out_fd, human);
}

/// The JSON-RPC request frame for `verb`.
pub fn buildVerbRequest(
    allocator: std.mem.Allocator,
    verb: Verb,
    target: ?[]const u8,
    new_name: ?[]const u8,
) ![]u8 {
    return switch (verb) {
        .list => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.list\",\"params\":{{}}}}\n",
            .{verb_rpc_id},
        ),
        .shutdown => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"daemon.shutdown\",\"params\":{{}}}}\n",
            .{verb_rpc_id},
        ),
        .kill => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.terminate\",\"params\":{{\"sessionId\":{f}}}}}\n",
            .{ verb_rpc_id, std.json.fmt(target.?, .{}) },
        ),
        .rename => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.rename\"," ++
                "\"params\":{{\"sessionId\":{f},\"name\":{f}}}}}\n",
            .{ verb_rpc_id, std.json.fmt(target.?, .{}), std.json.fmt(new_name.?, .{}) },
        ),
    };
}

/// True when `verb` names a session (`kill`, `rename`).
fn verbNeedsTarget(verb: Verb) bool {
    return verb == .kill or verb == .rename;
}

/// Human-readable output for a successful verb.
pub fn formatVerbResult(
    allocator: std.mem.Allocator,
    verb: Verb,
    target: ?[]const u8,
    new_name: ?[]const u8,
    result: std.json.Value,
) ![]u8 {
    return switch (verb) {
        .list => formatSessionList(allocator, result),
        .kill => std.fmt.allocPrint(allocator, "killed session {f}\n", .{escaped(target.?)}),
        .rename => std.fmt.allocPrint(
            allocator,
            "renamed session {f} to {f}\n",
            .{ escaped(target.?), escaped(new_name.?) },
        ),
        .shutdown => allocator.dupe(u8, "daemon shutdown\n"),
    };
}

/// One line per session of a `session.list` result.
pub fn formatSessionList(allocator: std.mem.Allocator, result: std.json.Value) ![]u8 {
    if (result != .array) return error.InvalidResponse;
    if (result.array.items.len == 0) return allocator.dupe(u8, "no sessions\n");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (result.array.items) |item| {
        if (item != .object) continue;
        const before = out.writer.end;
        try out.writer.print("{f}\t{f}\t{f}\tpid={d}\t{f}\n", .{
            escaped(jsonObjectString(item, "sessionId") orelse ""),
            escaped(jsonObjectString(item, "paneId") orelse ""),
            escaped(jsonObjectString(item, "state") orelse ""),
            jsonUnsigned(item, "pid") orelse 0,
            escaped(jsonObjectString(item, "title") orelse ""),
        });
        assert(out.writer.end > before and out.writer.buffered()[out.writer.end - 1] == '\n');
    }
    return out.toOwnedSlice();
}

test "session list escapes terminal controls and preserves printable UTF-8" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "[{\"sessionId\":\"work\",\"paneId\":\"p\",\"state\":\"running\",\"pid\":7,\"title\":\"é\\u001b]0;pwn\\u0007\\u0085\\u007f\"}]", .{});
    defer parsed.deinit();
    const text = try formatSessionList(alloc, parsed.value);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("work\tp\trunning\tpid=7\té\\x1b]0;pwn\\x07\\x85\\x7f\n", text);
}

test "management JSON prints the complete null-id error envelope and fails" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);
    const response = "{\"id\":null,\"error\":{\"message\":\"LimitExceeded\",\"data\":{\"kind\":\"limit\"}}}\n";
    try sys.sendAll(pair[1], response);
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectError(error.RpcError, executeVerb(alloc, pair[0], &reader, .list, null, null, true, out[1], .fromNow(test_io, 500)));
    var bytes: [response.len]u8 = undefined;
    try std.testing.expectEqual(response.len, try posix.read(out[0], &bytes));
    try std.testing.expectEqualStrings(response, &bytes);
}
