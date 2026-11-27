//! Agent-native JSON-RPC handlers: `pane.wait`, `pane.exec`, `pane.signal`, and `pane.record`.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");
const vt_mod = @import("../vt.zig");
const Value = std.json.Value;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const params_mod = @import("params.zig");
const rpc_session_mod = @import("rpc_session.zig");

const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const base64Encode = rpc_session_mod.base64Encode;
const optionalBool = params_mod.optionalBool;
const optionalInt = params_mod.optionalInt;
const optionalString = params_mod.optionalString;
const paneIdParam = params_mod.paneIdParam;

/// `pane.wait`: server-side condition-variable wait for pattern, exit, idle,
/// OSC 133 prompt state, OSC 7501 agent status, command done, or foreground return.
pub fn waitPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const opts = try parseWaitOptions(params, &connection.closed);

    const active = self.manager.find(target) orelse return error.PaneNotFound;
    defer active.release();
    assert(active.id.len > 0);

    var result = try active.waitCondition(self.allocator, opts);
    defer result.deinit(self.allocator);

    try self.reply(connection, req, .{
        .matched = result.matched,
        .reason = result.reason.label(),
        .matchText = result.match_text,
        .exitCode = result.exit_code,
        .signal = result.signal,
        .generation = result.generation,
        .offset = result.offset,
        .screenText = result.screen_text,
    });
}

fn parseWaitOptions(params: ?Value, stop_flag: *const std.atomic.Value(bool)) !native_mod.WaitOptions {
    const pattern = try optionalString(params, "pattern");
    const use_regex = try optionalBool(params, "regex") orelse false;
    const exit_flag = try optionalBool(params, "exit") orelse false;
    const idle_ms = try optionalInt(u64, params, "idleMs");
    if (idle_ms != null and idle_ms.? == 0) return error.InvalidParams;
    const prompt_str = try optionalString(params, "promptState");
    const prompt_state = if (prompt_str) |s| (parsePromptState(s) orelse return error.InvalidParams) else null;
    const status_str = try optionalString(params, "agentStatus");
    const agent_status = if (status_str) |s| (parseAgentStatus(s) orelse return error.InvalidParams) else null;
    const command_done = try optionalBool(params, "commandDone") orelse false;
    const fg_return = try optionalBool(params, "foregroundReturn") orelse false;
    const timeout_ms = try optionalInt(u64, params, "timeoutMs") orelse 30_000;
    if (timeout_ms == 0) return error.InvalidParams;

    const has_any = pattern != null or exit_flag or idle_ms != null or
        prompt_state != null or agent_status != null or command_done or fg_return;
    if (!has_any) return error.InvalidParams;

    return .{
        .pattern = pattern,
        .regex = use_regex,
        .exit = exit_flag,
        .idle_ms = idle_ms,
        .prompt_state = prompt_state,
        .agent_status = agent_status,
        .command_done = command_done,
        .foreground_return = fg_return,
        .timeout_ms = timeout_ms,
        .stop_flag = stop_flag,
    };
}

/// `pane.exec`: run a shell command inside a pane and return its exit code and output.
pub fn execPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const command = try optionalString(params, "command") orelse return error.InvalidParams;
    const trimmed = std.mem.trimEnd(u8, command, "\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidParams;
    const timeout_ms = try optionalInt(u64, params, "timeoutMs") orelse 30_000;
    if (timeout_ms == 0) return error.InvalidParams;
    const capture_output = try optionalBool(params, "captureOutput") orelse true;

    const active = self.manager.find(target) orelse return error.PaneNotFound;
    defer active.release();
    assert(active.id.len > 0 and timeout_ms >= 1);

    var res = try active.execInPane(self.allocator, command, timeout_ms, capture_output, &connection.closed);
    defer res.deinit(self.allocator);

    const out_b64 = try base64Encode(self.allocator, res.output);
    defer self.allocator.free(out_b64);

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"paneId\":");
    try std.json.Stringify.value(active.id, .{}, &out.writer);
    try out.writer.writeAll(",\"exitCode\":");
    if (res.exit_code) |c| try out.writer.print("{d}", .{c}) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"signal\":");
    if (res.signal) |s| try out.writer.print("{d}", .{s}) else try out.writer.writeAll("null");
    try out.writer.writeAll(",\"output\":");
    try protocol.writeJsonStringLossy(&out.writer, res.output);
    try out.writer.writeAll(",\"outputBase64\":");
    try std.json.Stringify.value(out_b64, .{}, &out.writer);
    try out.writer.print(",\"timedOut\":{},\"durationMs\":{d}}}", .{ res.timed_out, res.duration_ms });
    try self.replyRaw(connection, req, out.written());
}

/// `pane.signal`: deliver a POSIX signal to a pane's foreground group or child process.
pub fn signalPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const group = try optionalBool(params, "group") orelse true;
    var name_buf: [16]u8 = undefined;
    const parsed = try parseSignalParam(params, &name_buf);

    const active = self.manager.find(target) orelse return error.PaneNotFound;
    defer active.release();
    assert(active.id.len > 0);

    try active.sendSignal(parsed.sig, group);
    assert(parsed.name.len > 0);
    try self.reply(connection, req, .{
        .ok = true,
        .paneId = active.id,
        .signal = parsed.name,
    });
}

/// `pane.record`: start, stop, or inspect an asciicast v2 recording of a pane stream.
pub fn recordPane(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const action = try optionalString(params, "action") orelse return error.InvalidParams;
    if (try optionalString(params, "format")) |fmt| {
        if (!std.mem.eql(u8, fmt, "asciicast-v2")) return error.InvalidParams;
    }
    const path = try optionalString(params, "path");
    const max_bytes = try optionalInt(usize, params, "maxBytes");
    if (max_bytes != null and max_bytes.? == 0) return error.InvalidParams;

    const active = self.manager.find(target) orelse return error.PaneNotFound;
    defer active.release();
    assert(active.id.len > 0);

    var status = if (std.mem.eql(u8, action, "start"))
        try active.startRecording(.{
            .path = path,
            .max_bytes = max_bytes orelse 8 * 1024 * 1024,
        })
    else if (std.mem.eql(u8, action, "stop"))
        try active.stopRecording(self.allocator)
    else if (std.mem.eql(u8, action, "status"))
        try active.recordingStatus(self.allocator)
    else
        return error.InvalidParams;
    defer status.deinit(self.allocator);

    try self.reply(connection, req, .{
        .paneId = active.id,
        .recording = status.recording,
        .path = status.path,
        .format = "asciicast-v2",
        .bytesWritten = status.bytes_written,
        .startedAtMs = status.started_at_ms,
    });
}

const ParsedSignal = struct {
    sig: posix.SIG,
    name: []const u8,
};

fn parseSignalParam(params: ?Value, buf: *[16]u8) !ParsedSignal {
    const p = params orelse return error.InvalidParams;
    if (p != .object) return error.InvalidParams;
    const raw = p.object.get("signal") orelse return error.InvalidParams;
    return switch (raw) {
        .string => |text| parseSignalName(text) orelse error.InvalidSignal,
        .integer => |n| blk: {
            if (n < 1 or n > 64) return error.InvalidSignal;
            const sig: posix.SIG = @fromBackingInt(@intCast(@as(u8, @intCast(n))));
            const name = signalCanonicalName(sig) orelse
                (std.fmt.bufPrint(buf, "SIG{d}", .{n}) catch return error.InvalidSignal);
            break :blk .{ .sig = sig, .name = name };
        },
        else => error.InvalidParams,
    };
}

const SignalEntry = struct { short: []const u8, canonical: []const u8, sig: posix.SIG };

const named_signals = [_]SignalEntry{
    .{ .short = "HUP", .canonical = "SIGHUP", .sig = .HUP },
    .{ .short = "INT", .canonical = "SIGINT", .sig = .INT },
    .{ .short = "QUIT", .canonical = "SIGQUIT", .sig = .QUIT },
    .{ .short = "ABRT", .canonical = "SIGABRT", .sig = .ABRT },
    .{ .short = "KILL", .canonical = "SIGKILL", .sig = .KILL },
    .{ .short = "USR1", .canonical = "SIGUSR1", .sig = .USR1 },
    .{ .short = "USR2", .canonical = "SIGUSR2", .sig = .USR2 },
    .{ .short = "PIPE", .canonical = "SIGPIPE", .sig = .PIPE },
    .{ .short = "ALRM", .canonical = "SIGALRM", .sig = .ALRM },
    .{ .short = "TERM", .canonical = "SIGTERM", .sig = .TERM },
    .{ .short = "CONT", .canonical = "SIGCONT", .sig = .CONT },
    .{ .short = "STOP", .canonical = "SIGSTOP", .sig = .STOP },
    .{ .short = "TSTP", .canonical = "SIGTSTP", .sig = .TSTP },
    .{ .short = "WINCH", .canonical = "SIGWINCH", .sig = .WINCH },
    .{ .short = "TRAP", .canonical = "SIGTRAP", .sig = .TRAP },
    .{ .short = "CHLD", .canonical = "SIGCHLD", .sig = .CHLD },
};

fn parseSignalName(text: []const u8) ?ParsedSignal {
    if (text.len == 0) return null;
    const trimmed = if (text.len > 3 and std.ascii.eqlIgnoreCase(text[0..3], "SIG")) text[3..] else text;
    for (named_signals) |entry| {
        if (std.ascii.eqlIgnoreCase(trimmed, entry.short)) {
            return .{ .sig = entry.sig, .name = entry.canonical };
        }
    }
    return null;
}

fn signalCanonicalName(sig: posix.SIG) ?[]const u8 {
    for (named_signals) |entry| {
        if (entry.sig == sig) return entry.canonical;
    }
    return null;
}

fn parsePromptState(text: []const u8) ?vt_mod.PromptState {
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    if (std.mem.eql(u8, text, "prompt")) return .prompt;
    if (std.mem.eql(u8, text, "input")) return .input;
    if (std.mem.eql(u8, text, "running")) return .running;
    return null;
}

fn parseAgentStatus(text: []const u8) ?vt_mod.AgentStatus {
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    if (std.mem.eql(u8, text, "idle")) return .idle;
    if (std.mem.eql(u8, text, "working")) return .working;
    if (std.mem.eql(u8, text, "waiting_for_input")) return .waiting_for_input;
    if (std.mem.eql(u8, text, "done")) return .done;
    return null;
}

test "parseSignalName handles SIG prefixes, short names, and rejects invalid names" {
    const int_sig = parseSignalName("SIGINT").?;
    try std.testing.expectEqual(posix.SIG.INT, int_sig.sig);
    try std.testing.expectEqualStrings("SIGINT", int_sig.name);

    const term_sig = parseSignalName("term").?;
    try std.testing.expectEqual(posix.SIG.TERM, term_sig.sig);
    try std.testing.expectEqualStrings("SIGTERM", term_sig.name);

    try std.testing.expect(parseSignalName("BOGUS") == null);
    try std.testing.expect(parseSignalName("") == null);
}

test "RPC: pane.wait, pane.exec, pane.signal, and pane.record work end-to-end" {
    const builtin = @import("builtin");
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const fuzz_hooks = @import("fuzz_hooks.zig").fuzz_hooks;
    const ts = @import("test_support.zig");
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, ts.test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    var client = try ts.TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"session.create\",\"params\":{\"title\":\"agent-rpc\"," ++
        "\"shell\":\"/bin/sh\",\"env\":{\"HOME\":\"/nonexistent\",\"PS1\":\"$ \"}}}\n");
    var created = try client.response(1);
    defer created.deinit();
    const pane_id = try allocator.dupe(u8, (try ts.resultOf(&created)).get("paneId").?.string);
    defer allocator.free(pane_id);

    // pane.exec exit 0 + output capture.
    try client.sendFmt("{{\"id\":2,\"method\":\"pane.exec\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"command\":\"printf 'AGENT_OK'\",\"timeoutMs\":5000}}}}\n", .{pane_id});
    var ex0 = try client.response(2);
    defer ex0.deinit();
    const ex0_obj = try ts.resultOf(&ex0);
    try std.testing.expectEqual(@as(i64, 0), ex0_obj.get("exitCode").?.integer);
    try std.testing.expectEqualStrings("AGENT_OK", ex0_obj.get("output").?.string);
    try std.testing.expect(!ex0_obj.get("timedOut").?.bool);

    // pane.exec non-zero exit code with captureOutput=false.
    try client.sendFmt("{{\"id\":3,\"method\":\"pane.exec\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"command\":\"(exit 5)\",\"captureOutput\":false,\"timeoutMs\":5000}}}}\n", .{pane_id});
    var ex5 = try client.response(3);
    defer ex5.deinit();
    const ex5_obj = try ts.resultOf(&ex5);
    try std.testing.expectEqual(@as(i64, 5), ex5_obj.get("exitCode").?.integer);
    try std.testing.expectEqualStrings("", ex5_obj.get("output").?.string);

    // pane.record start, duplicate conflict, status, stop.
    var path_buf: [128]u8 = undefined;
    const rec_path = try std.fmt.bufPrint(&path_buf, "/tmp/zmux-rpc-rec-{s}.cast", .{pane_id});
    defer ts.deleteTestFile(rec_path);

    try client.sendFmt("{{\"id\":4,\"method\":\"pane.record\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"action\":\"start\",\"path\":\"{s}\"}}}}\n", .{ pane_id, rec_path });
    var r_start = try client.response(4);
    defer r_start.deinit();
    try std.testing.expect((try ts.resultOf(&r_start)).get("recording").?.bool);

    try client.sendFmt("{{\"id\":5,\"method\":\"pane.record\",\"params\":{{\"paneId\":\"{s}\",\"action\":\"start\"}}}}\n", .{pane_id});
    var r_dup = try client.response(5);
    defer r_dup.deinit();
    try ts.expectRpcError(&r_dup, -32000, "conflict", "RecordingActive");

    try client.sendFmt("{{\"id\":6,\"method\":\"pane.record\",\"params\":{{\"paneId\":\"{s}\",\"action\":\"stop\"}}}}\n", .{pane_id});
    var r_stop = try client.response(6);
    defer r_stop.deinit();
    try std.testing.expect(!(try ts.resultOf(&r_stop)).get("recording").?.bool);

    // pane.signal: deliver SIGUSR1 trapped by shell, verify output via pane.wait, reject invalid signal.
    try client.sendFmt("{{\"id\":7,\"method\":\"pane.signal\",\"params\":{{\"paneId\":\"{s}\",\"signal\":\"BOGUS\"}}}}\n", .{pane_id});
    var sig_bad = try client.response(7);
    defer sig_bad.deinit();
    try ts.expectRpcError(&sig_bad, -32602, "invalid_params", "InvalidSignal");

    try client.sendFmt("{{\"id\":8,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\"," ++
        "\"text\":\"trap 'echo TRAPPED_SIG' USR1; echo READY_SIG\",\"enter\":true}}}}\n", .{pane_id});
    var sent = try client.response(8);
    sent.deinit();
    try client.sendFmt("{{\"id\":9,\"method\":\"pane.wait\",\"params\":{{\"paneId\":\"{s}\",\"pattern\":\"READY_SIG\",\"timeoutMs\":5000}}}}\n", .{pane_id});
    var w1 = try client.response(9);
    w1.deinit();

    try client.sendFmt("{{\"id\":10,\"method\":\"pane.signal\",\"params\":{{\"paneId\":\"{s}\",\"signal\":\"SIGUSR1\"}}}}\n", .{pane_id});
    var sig_ok = try client.response(10);
    defer sig_ok.deinit();
    try std.testing.expectEqualStrings("SIGUSR1", (try ts.resultOf(&sig_ok)).get("signal").?.string);

    try client.sendFmt("{{\"id\":11,\"method\":\"pane.wait\",\"params\":{{\"paneId\":\"{s}\",\"pattern\":\"TRAPPED_SIG\",\"timeoutMs\":5000}}}}\n", .{pane_id});
    var w2 = try client.response(11);
    defer w2.deinit();
    try std.testing.expect((try ts.resultOf(&w2)).get("matched").?.bool);
}
