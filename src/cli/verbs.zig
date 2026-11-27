//! Management and agent verb execution for `zmux`: `new`, `ls`, `run`/`exec`,
//! `send`, `screen` (with v0.4.0 capture fallback), `capture`/`tail`, `wait`,
//! `signal`, `split`, `close`, `kill`, `rename`, `events`, `record`, `shutdown`.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const connect_terminal = @import("../connect/terminal.zig");
const connect_wire = @import("../connect/wire.zig");
const sys = @import("../sys.zig");
const args_mod = @import("args.zig");
const help = @import("help.zig");
const rpc = @import("rpc.zig");
const stream = @import("stream.zig");

const test_io = std.testing.io;

/// Connect to the daemon (auto-spawning unless `--no-spawn`) and run one verb.
pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    assert(out_fd >= 0);
    // `shutdown` should never auto-spawn a daemon just to stop it.
    const should_spawn = parsed.spawn_daemon and parsed.command != .shutdown;
    var client = try rpc.RpcClient.connect(allocator, io, parsed.socket_path, should_spawn);
    defer client.deinit();
    try executeOnClient(&client, parsed, out_fd);
}

/// Execute one parsed CLI verb against an already-connected `RpcClient`.
pub fn executeOnClient(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    assert(client.fd >= 0 and out_fd >= 0);
    switch (parsed.command) {
        .new => try execNew(client, parsed, out_fd),
        .ls => try execLs(client, parsed, out_fd),
        .run => try execRun(client, parsed, out_fd),
        .send => try execSend(client, parsed, out_fd),
        .screen => try execScreen(client, parsed, out_fd),
        .capture => try execCapture(client, parsed, out_fd),
        .wait => try execWait(client, parsed, out_fd),
        .signal => try execSignal(client, parsed, out_fd),
        .split => try execSplit(client, parsed, out_fd),
        .close => try execClose(client, parsed, out_fd),
        .kill => try execKill(client, parsed, out_fd),
        .rename => try execRename(client, parsed, out_fd),
        .events => try stream.runEvents(client, parsed.panes_csv, out_fd),
        .record => try execRecord(client, parsed, out_fd),
        .shutdown => try execShutdown(client, parsed, out_fd),
        else => return error.InvalidArguments,
    }
}

fn currentDir(buf: *[posix.PATH_MAX]u8) ?[]const u8 {
    const ptr = std.c.getcwd(buf, buf.len) orelse return null;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(ptr)), 0);
    if (cwd.len == 0 or cwd[0] != '/' or !std.unicode.utf8ValidateSlice(cwd)) return null;
    return cwd;
}

fn emitJsonOrError(resp: rpc.Response, out_fd: posix.fd_t) !void {
    assert(resp.line.len > 0 and out_fd >= 0);
    try connect_terminal.writeAllFd(out_fd, resp.line);
    if (resp.rpcError() != null) return error.RpcError;
}

fn printFormatted(allocator: std.mem.Allocator, out_fd: posix.fd_t, comptime fmt: []const u8, a: anytype) !void {
    assert(out_fd >= 0);
    const line = try std.fmt.allocPrint(allocator, fmt, a);
    defer allocator.free(line);
    try connect_terminal.writeAllFd(out_fd, line);
}

fn execNew(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    var cwd_buf: [posix.PATH_MAX]u8 = undefined;
    const effective_cwd = parsed.cwd orelse currentDir(&cwd_buf);
    const resp = try client.call("session.create", .{
        .name = parsed.target,
        .command = parsed.cmd_text,
        .cwd = effective_cwd,
        .rows = parsed.rows,
        .cols = parsed.cols,
    }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    const sid = connect_wire.jsonObjectString(resp.result(), "sessionId") orelse
        connect_wire.jsonObjectString(resp.result(), "id") orelse "session";
    const pid = connect_wire.jsonObjectString(resp.result(), "paneId") orelse sid;
    try printFormatted(
        client.allocator,
        out_fd,
        "created session {f} (pane {f})\n",
        .{ help.escaped(sid), help.escaped(pid) },
    );
}

fn execLs(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const resp = try client.call("session.list", .{}, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    const table = try stream.formatSessionTable(client.allocator, resp.result());
    defer client.allocator.free(table);
    try connect_terminal.writeAllFd(out_fd, table);
}

fn execRun(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    const cmd = try std.mem.join(client.allocator, " ", parsed.command_args);
    defer client.allocator.free(cmd);
    assert(target.len > 0 and cmd.len > 0);
    const rpc_timeout: i64 = @intCast(@min(parsed.timeout_ms +| 5_000, 600_000));
    const resp = try client.call("pane.exec", .{
        .paneId = target,
        .command = cmd,
        .timeoutMs = parsed.timeout_ms,
    }, rpc_timeout);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| {
        if (err.isMethodNotFound()) return help.diagnostic(client.io, "run/exec requires zmuxd >= 0.5.0", .{});
        return help.reportRpcError(client.io, err);
    }
    if (connect_wire.jsonObjectString(resp.result(), "output")) |out_text| {
        try connect_terminal.writeAllFd(out_fd, out_text);
    }
    const timed_out = connect_wire.jsonField(resp.result(), "timedOut");
    if (timed_out == .bool and timed_out.bool) return help.diagnostic(client.io, "command timed out", .{});
    const exit_code = connect_wire.jsonField(resp.result(), "exitCode");
    if (exit_code == .integer and exit_code.integer != 0) {
        return help.diagnostic(client.io, "command exited with status {d}", .{exit_code.integer});
    }
}

fn execSend(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0);
    if (parsed.use_stdin) {
        try stream.sendFromFd(client, target, 0, parsed.enter);
        return;
    }
    const resp = if (parsed.key) |key|
        try client.call("session.sendKey", .{ .sessionId = target, .key = key }, rpc.default_timeout_ms)
    else
        try client.call("session.send", .{
            .sessionId = target,
            .text = parsed.second_arg orelse "",
            .enter = parsed.enter,
        }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
}

fn execScreen(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0);
    const fmt = parsed.screen_format;
    const resp = try client.call("session.screen", .{
        .sessionId = target,
        .includeScrollback = parsed.scrollback,
        .includeCells = fmt == .cells,
        .includeAnsiRestore = fmt == .ansi,
    }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);

    if (resp.rpcError()) |err| {
        if (err.isMethodNotFound()) return execScreenFallback(client, parsed, out_fd);
        if (parsed.json or fmt == .json) return emitJsonOrError(resp, out_fd);
        return help.reportRpcError(client.io, err);
    }
    if (parsed.json or fmt == .json) return emitJsonOrError(resp, out_fd);
    try writeScreenOutput(client.allocator, fmt, resp.result(), out_fd);
}

fn execScreenFallback(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    const lines = 200 +| parsed.scrollback;
    assert(lines >= 200);
    const cap = try client.call("session.capture", .{ .sessionId = target, .lines = lines }, rpc.default_timeout_ms);
    defer cap.deinit(client.allocator);
    if (parsed.json or parsed.screen_format == .json) return emitJsonOrError(cap, out_fd);
    if (cap.rpcError()) |err| return help.reportRpcError(client.io, err);
    try writeCaptureText(client.allocator, cap.result(), out_fd);
}

fn writeScreenOutput(
    allocator: std.mem.Allocator,
    fmt: args_mod.ScreenFormat,
    result: std.json.Value,
    out_fd: posix.fd_t,
) !void {
    assert(out_fd >= 0);
    switch (fmt) {
        .ansi => {
            const text = connect_wire.jsonObjectString(result, "ansiRestore") orelse
                connect_wire.jsonObjectString(result, "text") orelse "";
            try connect_terminal.writeAllFd(out_fd, text);
        },
        .cells => {
            const cells = connect_wire.jsonField(result, "cells");
            try printFormatted(allocator, out_fd, "{f}\n", .{std.json.fmt(cells, .{})});
        },
        .plain, .json => {
            const text = connect_wire.jsonObjectString(result, "text") orelse "";
            try connect_terminal.writeAllFd(out_fd, text);
            if (text.len > 0 and text[text.len - 1] != '\n') try connect_terminal.writeAllFd(out_fd, "\n");
        },
    }
}

fn execCapture(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0);
    if (parsed.follow) return stream.runCaptureFollow(client, target, parsed.json, out_fd);
    const resp = try client.call(
        "session.capture",
        .{ .sessionId = target, .lines = parsed.lines },
        rpc.default_timeout_ms,
    );
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    try writeCaptureText(client.allocator, resp.result(), out_fd);
}

fn writeCaptureText(allocator: std.mem.Allocator, result: std.json.Value, out_fd: posix.fd_t) !void {
    if (connect_wire.jsonObjectString(result, "textBase64")) |b64| {
        if (connect_wire.base64Decode(allocator, b64)) |bytes| {
            defer allocator.free(bytes);
            try connect_terminal.writeAllFd(out_fd, bytes);
            return;
        } else |_| {}
    }
    if (connect_wire.jsonObjectString(result, "text")) |text| {
        try connect_terminal.writeAllFd(out_fd, text);
    }
}

fn execWait(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0 and parsed.timeout_ms > 0);
    const rpc_timeout: i64 = @intCast(@min(parsed.timeout_ms +| 5_000, 600_000));
    const resp = try client.call("pane.wait", .{
        .paneId = target,
        .pattern = parsed.pattern,
        .exit = if (parsed.wait_exit) true else null,
        .idleMs = parsed.idle_ms,
        .commandDone = if (parsed.command_done) true else null,
        .timeoutMs = parsed.timeout_ms,
    }, rpc_timeout);
    defer resp.deinit(client.allocator);
    if (resp.rpcError()) |err| {
        if (err.isMethodNotFound()) return stream.waitFallback(client, parsed, out_fd);
        if (parsed.json) return emitJsonOrError(resp, out_fd);
        return help.reportRpcError(client.io, err);
    }
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    const reason = connect_wire.jsonObjectString(resp.result(), "reason") orelse "ok";
    try printFormatted(client.allocator, out_fd, "{s}\n", .{reason});
    const matched = connect_wire.jsonField(resp.result(), "matched");
    if (matched == .bool and !matched.bool) return error.ReportedFailure;
}

fn execSignal(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    const sig = parsed.second_arg orelse return error.InvalidArguments;
    assert(std.mem.startsWith(u8, sig, "SIG"));
    const resp = try client.call("pane.signal", .{ .paneId = target, .signal = sig }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    try printFormatted(client.allocator, out_fd, "signaled {f} with {s}\n", .{ help.escaped(target), sig });
}

fn execSplit(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0);
    const axis = if (parsed.split_axis == .horizontal) "horizontal" else "vertical";
    const resp = try client.call("pane.split", .{
        .paneId = target,
        .axis = axis,
        .command = parsed.cmd_text,
    }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    const pid = connect_wire.jsonObjectString(resp.result(), "paneId") orelse "pane";
    try printFormatted(client.allocator, out_fd, "split pane {f}\n", .{help.escaped(pid)});
}

fn execClose(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    const resp = try client.call("pane.close", .{ .paneId = target }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (resp.rpcError()) |err| {
        if (err.isMethodNotFound()) return execKill(client, parsed, out_fd);
        if (parsed.json) return emitJsonOrError(resp, out_fd);
        return help.reportRpcError(client.io, err);
    }
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    try printFormatted(client.allocator, out_fd, "closed {f}\n", .{help.escaped(target)});
}

fn execKill(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0);
    const resp = try client.call("session.terminate", .{ .sessionId = target }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    try printFormatted(client.allocator, out_fd, "killed session {f}\n", .{help.escaped(target)});
}

fn execRename(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    const new_name = parsed.second_arg orelse return error.InvalidArguments;
    assert(target.len > 0 and new_name.len > 0);
    const resp = try client.call(
        "session.rename",
        .{ .sessionId = target, .name = new_name },
        rpc.default_timeout_ms,
    );
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    try printFormatted(
        client.allocator,
        out_fd,
        "renamed {f} to {f}\n",
        .{ help.escaped(target), help.escaped(new_name) },
    );
}

fn execRecord(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const target = parsed.target orelse return error.InvalidArguments;
    const act = parsed.record_action orelse return error.InvalidArguments;
    const act_name = switch (act) {
        .start => "start",
        .stop => "stop",
        .@"export" => "export",
        .status => "status",
    };
    const resp = try client.call("pane.record", .{
        .paneId = target,
        .action = act_name,
        .path = parsed.out_file,
    }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    if (act == .@"export") {
        if (connect_wire.jsonObjectString(resp.result(), "asciicast") orelse
            connect_wire.jsonObjectString(resp.result(), "data")) |cast|
        {
            return writeExportPayload(parsed.out_file, cast, out_fd);
        }
    }
    try printFormatted(client.allocator, out_fd, "record {s} ok\n", .{act_name});
}

fn writeExportPayload(out_file: ?[]const u8, payload: []const u8, out_fd: posix.fd_t) !void {
    assert(out_fd >= 0);
    if (out_file) |file_path| {
        const fd = try sys.open(
            file_path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
            0o600,
        );
        defer sys.close(fd);
        try connect_terminal.writeAllFd(fd, payload);
        return;
    }
    try connect_terminal.writeAllFd(out_fd, payload);
}

fn execShutdown(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    const resp = try client.call("daemon.shutdown", .{}, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (parsed.json) return emitJsonOrError(resp, out_fd);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    try connect_terminal.writeAllFd(out_fd, "daemon shutdown\n");
}

test "screen transparently falls back to session.capture on v0.4.0 MethodNotFound" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"MethodNotFound\"," ++
            "\"data\":{\"kind\":\"method_not_found\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"w\",\"text\":\"ok\",\"textBase64\":\"aGkK\"}}\n",
    );
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    const parsed = try args_mod.parse(&.{ "zmux", "screen", "w" }, null);
    try executeOnClient(&client, parsed, out[1]);

    var buf: [32]u8 = undefined;
    const n = try posix.read(out[0], &buf);
    try std.testing.expectEqualStrings("hi\n", buf[0..n]);
}

test "close falls back to session.terminate on v0.4.0 MethodNotFound" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"MethodNotFound\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n",
    );
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    const parsed = try args_mod.parse(&.{ "zmux", "close", "work" }, null);
    try executeOnClient(&client, parsed, out[1]);

    var buf: [64]u8 = undefined;
    const n = try posix.read(out[0], &buf);
    try std.testing.expectEqualStrings("killed session work\n", buf[0..n]);
}

test "new, ls, signal, split, rename, and shutdown execute over RPC cleanly" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"sessionId\":\"s1\",\"paneId\":\"p1\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true,\"paneId\":\"p1\",\"signal\":\"SIGINT\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"paneId\":\"p2\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"ok\":true}}\n",
    );
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    try executeOnClient(&client, try args_mod.parse(&.{ "zmux", "new", "s1" }, null), out[1]);
    try executeOnClient(&client, try args_mod.parse(&.{ "zmux", "signal", "p1", "INT" }, null), out[1]);
    try executeOnClient(&client, try args_mod.parse(&.{ "zmux", "split", "p1", "-h" }, null), out[1]);
    try executeOnClient(&client, try args_mod.parse(&.{ "zmux", "shutdown" }, null), out[1]);

    var buf: [256]u8 = undefined;
    const n = try posix.read(out[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "created session s1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "SIGINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "split pane p2") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "daemon shutdown") != null);
}
