//! Streaming CLI helpers: aligned session tables, live `events`, `capture --follow`,
//! `send --stdin`, and client-side `wait` fallback for v0.4.0 daemons.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const connect_events = @import("../connect/events.zig");
const connect_terminal = @import("../connect/terminal.zig");
const connect_wire = @import("../connect/wire.zig");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const args_mod = @import("args.zig");
const help = @import("help.zig");
const rpc = @import("rpc.zig");

const test_io = std.testing.io;

/// Maximum bytes accepted from stdin in a single `zmux send --stdin` call (4 MiB).
pub const max_stdin_send_bytes: usize = 4 * 1024 * 1024;

/// Format a `session.list` JSON array as an aligned, control-escaped table.
pub fn formatSessionTable(allocator: std.mem.Allocator, result: std.json.Value) ![]u8 {
    if (result != .array) return error.InvalidResponse;
    if (result.array.items.len == 0) return allocator.dupe(u8, "no sessions\n");

    var w_session: usize = "SESSION".len;
    var w_pane: usize = "PANE".len;
    var w_state: usize = "STATE".len;
    for (result.array.items) |item| {
        if (item != .object) continue;
        const s = sessionLabel(item);
        const p = connect_wire.jsonObjectString(item, "paneId") orelse "";
        const st = connect_wire.jsonObjectString(item, "state") orelse "";
        w_session = @max(w_session, @min(s.len, 32));
        w_pane = @max(w_pane, @min(p.len, 24));
        w_state = @max(w_state, @min(st.len, 16));
    }
    assert(w_session >= 7 and w_pane >= 4 and w_state >= 5);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writePadded(&out.writer, "SESSION", w_session);
    try writePadded(&out.writer, "PANE", w_pane);
    try writePadded(&out.writer, "STATE", w_state);
    try out.writer.writeAll("PID     TITLE\n");

    for (result.array.items) |item| {
        if (item != .object) continue;
        try formatSessionRow(&out.writer, item, w_session, w_pane, w_state);
    }
    return out.toOwnedSlice();
}

fn sessionLabel(item: std.json.Value) []const u8 {
    return connect_wire.jsonObjectString(item, "sessionName") orelse
        connect_wire.jsonObjectString(item, "sessionId") orelse
        connect_wire.jsonObjectString(item, "id") orelse "";
}

fn formatSessionRow(
    writer: *std.Io.Writer,
    item: std.json.Value,
    w_session: usize,
    w_pane: usize,
    w_state: usize,
) !void {
    const sess = sessionLabel(item);
    const pane = connect_wire.jsonObjectString(item, "paneId") orelse "";
    const state = connect_wire.jsonObjectString(item, "state") orelse "";
    const pid = connect_wire.jsonUnsigned(item, "pid") orelse 0;
    const title = connect_wire.jsonObjectString(item, "paneTitle") orelse
        connect_wire.jsonObjectString(item, "title") orelse "";

    try writePaddedEscaped(writer, sess, w_session);
    try writePaddedEscaped(writer, pane, w_pane);
    try writePaddedEscaped(writer, state, w_state);
    var pid_buf: [24]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    try writePadded(writer, pid_str, 6);
    try writer.print("{f}\n", .{help.escaped(title)});
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    const pad = if (width > text.len) width - text.len else 0;
    for (0..pad + 2) |_| try writer.writeByte(' ');
}

fn writePaddedEscaped(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    const before = writer.end;
    try writer.print("{f}", .{help.escaped(text)});
    const written = writer.end - before;
    const pad = if (width > written) width - written else 0;
    for (0..pad + 2) |_| try writer.writeByte(' ');
}

/// Subscribe to daemon events (`--panes a,b` or `*`) and stream NDJSON lines to `out_fd`.
pub fn runEvents(client: *rpc.RpcClient, panes_csv: ?[]const u8, out_fd: posix.fd_t) !void {
    assert(out_fd >= 0);
    const params_json = try buildSubscribeParams(client.allocator, panes_csv);
    defer client.allocator.free(params_json);

    const resp = try client.callRawParams("events.subscribe", params_json, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);

    while (true) {
        const line = client.readLineTimeout(null) catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => return err,
        };
        defer client.allocator.free(line);
        try connect_terminal.writeAllFd(out_fd, line);
    }
}

/// Build the JSON params object for `events.subscribe` from an optional CSV string.
pub fn buildSubscribeParams(allocator: std.mem.Allocator, panes_csv: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"panes\":[");
    if (panes_csv) |csv| {
        var first = true;
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw_tok| {
            const tok = std.mem.trim(u8, raw_tok, " \t");
            if (tok.len == 0) continue;
            if (!first) try out.writer.writeByte(',');
            try std.json.Stringify.value(tok, .{}, &out.writer);
            first = false;
        }
        if (first) try out.writer.writeAll("\"*\"");
    } else {
        try out.writer.writeAll("\"*\"");
    }
    try out.writer.writeAll("]}");
    assert(out.written().len >= 12);
    return out.toOwnedSlice();
}

/// Stream scrollback replay followed by live `pane_output` frames for `capture --follow`.
pub fn runCaptureFollow(
    client: *rpc.RpcClient,
    target: []const u8,
    json: bool,
    out_fd: posix.fd_t,
) !void {
    assert(target.len > 0 and out_fd >= 0);
    const attach = try client.call("client.attach", .{
        .paneId = target,
        .readOnly = true,
        .resizePolicy = "none",
    }, rpc.default_timeout_ms);
    defer attach.deinit(client.allocator);
    if (attach.rpcError()) |err| return help.reportRpcError(client.io, err);

    const pane_id = try connect_wire.requiredString(attach.result(), "paneId");
    const client_id = try connect_wire.requiredString(attach.result(), "clientId");
    if (json) {
        try connect_terminal.writeAllFd(out_fd, attach.line);
    } else {
        try connect_terminal.replayScrollback(client.allocator, attach.result(), out_fd);
    }

    var state: connect_events.RunState = .{
        .pane_id = pane_id,
        .client_id = client_id,
        .generation = connect_wire.jsonUnsigned(attach.result(), "generation"),
        .next_offset = connect_wire.jsonUnsigned(attach.result(), "replayEndOffset"),
    };
    defer if (state.switched_pane) |p| client.allocator.free(p);
    defer state.pending_sends.deinit(client.allocator);

    try streamFollowLoop(client, &state, json, out_fd);
}

fn streamFollowLoop(
    client: *rpc.RpcClient,
    state: *connect_events.RunState,
    json: bool,
    out_fd: posix.fd_t,
) !void {
    while (true) {
        const line = client.readLineTimeout(null) catch |err| switch (err) {
            error.ConnectionClosed => return,
            else => return err,
        };
        defer client.allocator.free(line);
        var chunk: ?[]u8 = null;
        defer if (chunk) |bytes| client.allocator.free(bytes);
        const outcome = try connect_events.handleServerLine(client.allocator, line, state, &chunk, client.io);
        if (json) {
            try connect_terminal.writeAllFd(out_fd, line);
        } else if (chunk) |bytes| {
            try connect_terminal.writeAllFd(out_fd, bytes);
        }
        if (outcome != null) return;
    }
}

/// Read all bytes from `in_fd` (up to `max_stdin_send_bytes`) and forward via `session.send`.
pub fn sendFromFd(client: *rpc.RpcClient, target: []const u8, in_fd: posix.fd_t, enter: bool) !void {
    assert(target.len > 0 and in_fd >= 0);
    var total: usize = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (total < max_stdin_send_bytes) {
        const n = try posix.read(in_fd, &buf);
        if (n == 0) break;
        total += n;
        const b64 = try connect_wire.base64Encode(client.allocator, buf[0..n]);
        defer client.allocator.free(b64);
        const resp = try client.call("session.send", .{
            .sessionId = target,
            .dataBase64 = b64,
        }, rpc.default_timeout_ms);
        defer resp.deinit(client.allocator);
        if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    }
    if (enter) {
        const cr = try client.call("session.send", .{
            .sessionId = target,
            .text = "",
            .enter = true,
        }, rpc.default_timeout_ms);
        defer cr.deinit(client.allocator);
        if (cr.rpcError()) |err| return help.reportRpcError(client.io, err);
    }
}

/// Client-side wait fallback when talking to a v0.4.0 daemon without `pane.wait`.
pub fn waitFallback(client: *rpc.RpcClient, parsed: args_mod.ParsedArgs, out_fd: posix.fd_t) !void {
    if (parsed.command_done) {
        return help.diagnostic(client.io, "wait --command-done requires zmuxd >= 0.5.0", .{});
    }
    const target = parsed.target orelse return error.InvalidArguments;
    assert(target.len > 0 and parsed.timeout_ms > 0);
    const attach = try client.call("client.attach", .{
        .paneId = target,
        .readOnly = true,
        .resizePolicy = "none",
    }, rpc.default_timeout_ms);
    defer attach.deinit(client.allocator);
    if (attach.rpcError()) |err| return help.reportRpcError(client.io, err);

    const pane_id = try connect_wire.requiredString(attach.result(), "paneId");
    const client_id = try connect_wire.requiredString(attach.result(), "clientId");
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(client.allocator);
    if (try connect_wire.decodeReplay(client.allocator, attach.result())) |replay| {
        defer client.allocator.free(replay);
        try appendBoundedTail(client.allocator, &acc, replay);
    }

    const exited_now = connect_wire.jsonField(attach.result(), "exited");
    if (parsed.wait_exit and exited_now == .bool and exited_now.bool) {
        return emitWaitResult(client.allocator, parsed.json, true, "exit", out_fd);
    }
    if (parsed.pattern) |pat| {
        if (std.mem.indexOf(u8, acc.items, pat) != null) {
            return emitWaitResult(client.allocator, parsed.json, true, "pattern", out_fd);
        }
    }

    var state: connect_events.RunState = .{
        .pane_id = pane_id,
        .client_id = client_id,
        .generation = connect_wire.jsonUnsigned(attach.result(), "generation"),
        .next_offset = connect_wire.jsonUnsigned(attach.result(), "replayEndOffset"),
    };
    defer if (state.switched_pane) |p| client.allocator.free(p);
    defer state.pending_sends.deinit(client.allocator);

    try pollWaitLoop(client, parsed, &state, &acc, out_fd);
}

fn pollWaitLoop(
    client: *rpc.RpcClient,
    parsed: args_mod.ParsedArgs,
    state: *connect_events.RunState,
    acc: *std.ArrayList(u8),
    out_fd: posix.fd_t,
) !void {
    const end_ms = sys.monotonicMs() + @as(i64, @intCast(parsed.timeout_ms));
    var last_activity = sys.monotonicMs();
    while (true) {
        const now = sys.monotonicMs();
        if (now >= end_ms) {
            try emitWaitResult(client.allocator, parsed.json, false, "timeout", out_fd);
            return error.ReportedFailure;
        }
        var wait_ms = end_ms - now;
        if (parsed.idle_ms) |idle| {
            const idle_rem = (last_activity + @as(i64, @intCast(idle))) - now;
            if (idle_rem <= 0) return emitWaitResult(client.allocator, parsed.json, true, "idle", out_fd);
            wait_ms = @min(wait_ms, idle_rem);
        }
        const line = client.readLineTimeout(@max(wait_ms, 1)) catch |err| switch (err) {
            error.ReadTimeout => continue,
            error.ConnectionClosed => return help.diagnostic(client.io, "daemon closed while waiting", .{}),
            else => return err,
        };
        defer client.allocator.free(line);
        var chunk: ?[]u8 = null;
        defer if (chunk) |b| client.allocator.free(b);
        const outcome = try connect_events.handleServerLine(client.allocator, line, state, &chunk, client.io);
        if (chunk) |bytes| {
            last_activity = sys.monotonicMs();
            try appendBoundedTail(client.allocator, acc, bytes);
            if (parsed.pattern) |pat| {
                if (std.mem.indexOf(u8, acc.items, pat) != null) {
                    return emitWaitResult(client.allocator, parsed.json, true, "pattern", out_fd);
                }
            }
        }
        if (outcome == .session_ended and parsed.wait_exit) {
            return emitWaitResult(client.allocator, parsed.json, true, "exit", out_fd);
        }
    }
}

fn appendBoundedTail(allocator: std.mem.Allocator, acc: *std.ArrayList(u8), bytes: []const u8) !void {
    const cap: usize = 64 * 1024;
    if (bytes.len >= cap) {
        acc.clearRetainingCapacity();
        try acc.appendSlice(allocator, bytes[bytes.len - cap ..]);
        return;
    }
    if (acc.items.len + bytes.len > cap) {
        const drop = (acc.items.len + bytes.len) - cap;
        std.mem.copyForwards(u8, acc.items[0 .. acc.items.len - drop], acc.items[drop..]);
        acc.shrinkRetainingCapacity(acc.items.len - drop);
    }
    try acc.appendSlice(allocator, bytes);
    assert(acc.items.len <= cap);
}

fn emitWaitResult(
    allocator: std.mem.Allocator,
    json: bool,
    matched: bool,
    reason: []const u8,
    out_fd: posix.fd_t,
) !void {
    const line = if (json)
        try std.fmt.allocPrint(allocator, "{{\"matched\":{},\"reason\":\"{s}\"}}\n", .{ matched, reason })
    else
        try std.fmt.allocPrint(allocator, "{s}\n", .{reason});
    defer allocator.free(line);
    try connect_terminal.writeAllFd(out_fd, line);
}

test "formatSessionTable renders aligned columns and escapes controls" {
    const alloc = std.testing.allocator;
    const raw =
        "[{\"sessionName\":\"dev\",\"paneId\":\"p1\",\"state\":\"running\",\"pid\":42,\"paneTitle\":\"hi\\u001b[31m\"}]";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const table = try formatSessionTable(alloc, parsed.value);
    defer alloc.free(table);
    try std.testing.expect(std.mem.indexOf(u8, table, "SESSION") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "hi\\x1b[31m") != null);
}

test "buildSubscribeParams splits CSV panes and defaults to wildcard" {
    const alloc = std.testing.allocator;
    const wild = try buildSubscribeParams(alloc, null);
    defer alloc.free(wild);
    try std.testing.expectEqualStrings("{\"panes\":[\"*\"]}", wild);

    const list = try buildSubscribeParams(alloc, "p1, p2 ,");
    defer alloc.free(list);
    try std.testing.expectEqualStrings("{\"panes\":[\"p1\",\"p2\"]}", list);
}

test "runEvents subscribes and streams NDJSON notifications verbatim" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true,\"all\":true,\"panes\":[\"*\"]}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"pane_bell\",\"params\":{\"pane_id\":\"p1\"}}\n",
    );
    _ = std.c.shutdown(pair[1], 1);

    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();
    try runEvents(&client, null, out[1]);

    var buf: [256]u8 = undefined;
    const n = try posix.read(out[0], &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"pane_bell\"") != null);
}

test "waitFallback matches pattern from replay and handles exit" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"paneId\":\"p1\",\"clientId\":\"c1\"," ++
            "\"replayBase64\":\"cmVhZHkK\",\"exited\":false,\"generation\":1,\"replayEndOffset\":6}}\n",
    );
    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    var p: args_mod.ParsedArgs = .{ .command = .wait, .target = "p1", .pattern = "ready", .json = true };
    p.timeout_ms = 500;
    try waitFallback(&client, p, out[1]);

    var buf: [128]u8 = undefined;
    const n = try posix.read(out[0], &buf);
    try std.testing.expectEqualStrings("{\"matched\":true,\"reason\":\"pattern\"}\n", buf[0..n]);
}
