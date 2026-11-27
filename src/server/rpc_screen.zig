//! Screen intelligence (`session.screen`), formatted `session.capture`, and
//! `client.attach` VT/delta-resumption replay builders.

const std = @import("std");
const assert = std.debug.assert;
const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const protocol = @import("../protocol.zig");
const Value = std.json.Value;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const limits_mod = @import("limits.zig");
const params_mod = @import("params.zig");
const rpc_session_mod = @import("rpc_session.zig");

const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const attach_replay_max_bytes = limits_mod.attach_replay_max_bytes;
const base64Encode = rpc_session_mod.base64Encode;
const captureTailStart = rpc_session_mod.captureTailStart;
const capture_envelope_reserve_bytes = limits_mod.capture_envelope_reserve_bytes;
const max_response_bytes = server_mod.max_response_bytes;
const optionalBool = params_mod.optionalBool;
const optionalInt = params_mod.optionalInt;
const optionalString = params_mod.optionalString;
const paneIdParam = params_mod.paneIdParam;

/// Replay mode selected by `client.attach` (`raw`, `ansi_restore`/`vt`, or `none`).
pub const ReplayMode = enum {
    raw,
    ansi_restore,
    none,

    /// Wire-format label matching OpenRPC `ReplayMode`.
    pub fn label(self: ReplayMode) []const u8 {
        return @tagName(self);
    }

    /// Parse a wire-format replay mode string (`"vt"` aliases `"ansi_restore"`).
    pub fn parse(text: []const u8) ?ReplayMode {
        if (std.mem.eql(u8, text, "raw")) return .raw;
        if (std.mem.eql(u8, text, "ansi_restore") or std.mem.eql(u8, text, "vt")) return .ansi_restore;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }
};

/// Parsed additive replay and resumption parameters for `client.attach`.
pub const AttachReplayOpts = struct {
    mode: ReplayMode = .raw,
    resume_from_offset: ?u64 = null,
    resume_generation: ?u64 = null,
    read_only: bool = false,
};

/// `session.screen`: read structured VT terminal state, OSC metadata, modes,
/// plain text, optional cell matrix, and optional ANSI restore sequence.
pub fn screenSession(self: *Server, connection: *ClientConnection, req: *const protocol.Request) !void {
    const params = req.params();
    const target = try paneIdParam(params) orelse return error.InvalidParams;
    const include_scrollback = try parseIncludeScrollback(params);
    const include_cells = try optionalBool(params, "includeCells") orelse false;
    const include_ansi = try optionalBool(params, "includeAnsiRestore") orelse false;

    const active = self.manager.find(target) orelse return error.SessionNotFound;
    defer active.release();
    assert(active.id.len > 0);

    const json = try active.screenJson(self.allocator, .{
        .include_scrollback = include_scrollback,
        .include_cells = include_cells,
        .include_ansi_restore = include_ansi,
    });
    defer self.allocator.free(json);
    try self.replyRaw(connection, req, json);
}

fn parseIncludeScrollback(params: ?Value) !usize {
    const p = params orelse return 0;
    if (p != .object) return 0;
    const val = p.object.get("includeScrollback") orelse return 0;
    return switch (val) {
        .null => 0,
        .bool => |flag| if (flag) (try optionalInt(usize, params, "lines") orelse 2000) else 0,
        .integer => |n| blk: {
            if (n < 0) return error.InvalidParams;
            break :blk std.math.cast(usize, n) orelse return error.InvalidParams;
        },
        else => error.InvalidParams,
    };
}

/// Handle `session.capture` when `format` is `"plain"`, `"ansi"`, or `"cells"`.
pub fn captureSessionFormatted(
    self: *Server,
    connection: *ClientConnection,
    req: *const protocol.Request,
    active: *native_mod.NativeSession,
    lines: usize,
    format: []const u8,
) !void {
    assert(active.id.len > 0);
    const is_plain = std.mem.eql(u8, format, "plain");
    const is_ansi = std.mem.eql(u8, format, "ansi");
    const is_cells = std.mem.eql(u8, format, "cells");
    if (!is_plain and !is_ansi and !is_cells) return error.InvalidParams;

    const payload = if (is_ansi)
        try active.ansiRestore(self.allocator)
    else
        try active.plainText(self.allocator, .{ .include_scrollback = lines });
    defer self.allocator.free(payload);

    const reserve = capture_envelope_reserve_bytes +| req.id_json.len +| active.id.len;
    const text = payload[captureTailStart(payload, max_response_bytes -| reserve)..];
    const text_b64 = try base64Encode(self.allocator, text);
    defer self.allocator.free(text_b64);

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"sessionId\":");
    try std.json.Stringify.value(active.id, .{}, &out.writer);
    try out.writer.writeAll(",\"text\":");
    try protocol.writeJsonStringLossy(&out.writer, text);
    try out.writer.writeAll(",\"textBase64\":");
    try std.json.Stringify.value(text_b64, .{}, &out.writer);
    if (is_cells) {
        const cells = try active.cellsJson(self.allocator, lines);
        defer self.allocator.free(cells);
        try out.writer.writeAll(",\"cells\":");
        try out.writer.writeAll(cells);
    }
    try out.writer.writeByte('}');
    try self.replyRaw(connection, req, out.written());
}

/// Build and send the `client.attach` JSON-RPC reply with support for `raw`,
/// `ansi_restore`/`vt`, `none`, and gap-free `resumeFromOffset` replay.
/// Caller holds `connection.write_mutex`.
pub fn writeAttachReply(
    self: *Server,
    connection: *ClientConnection,
    req: *const protocol.Request,
    client: *const mux.ClientSnapshot,
    created: bool,
    native: *native_mod.NativeSession,
    opts: AttachReplayOpts,
) !void {
    const exit = native.finalizedExitInfo();
    const generation = native.generation();
    const built = try buildAttachReplay(self.allocator, native, generation, opts);
    defer self.allocator.free(built.bytes);
    const replay_b64 = try base64Encode(self.allocator, built.bytes);
    defer self.allocator.free(replay_b64);
    assert(built.start_offset <= built.end_offset);

    if (protocol.isNotification(req)) return;
    const response = try encodeAttachResponse(
        self.allocator,
        req.id_json,
        client,
        created,
        exit,
        generation,
        replay_b64,
        &built,
        opts,
    );
    defer self.allocator.free(response);
    if (response.len > max_response_bytes) return error.LimitExceeded;
    assert(response.len > replay_b64.len);
    try connection.writeLocked(response);
}

fn encodeAttachResponse(
    allocator: std.mem.Allocator,
    id_json: []const u8,
    client: *const mux.ClientSnapshot,
    created: bool,
    exit: ?native_mod.ExitInfo,
    generation: u64,
    replay_b64: []const u8,
    built: *const BuiltReplay,
    opts: AttachReplayOpts,
) ![]u8 {
    const exit_code: ?u32 = if (exit) |info| info.exit_code else null;
    const signal: ?u32 = if (exit) |info| info.signal else null;
    assert(built.start_offset <= built.end_offset);
    if (opts.resume_from_offset != null) {
        return protocol.result(allocator, id_json, .{
            .clientId = client.id,
            .sessionId = client.session_id,
            .windowId = client.window_id,
            .paneId = client.pane_id,
            .rows = client.rows,
            .cols = client.cols,
            .created = created,
            .exited = exit != null,
            .exitCode = exit_code,
            .signal = signal,
            .generation = generation,
            .replayBase64 = replay_b64,
            .replayStartOffset = built.start_offset,
            .replayEndOffset = built.end_offset,
            .replayMode = opts.mode.label(),
            .readOnly = opts.read_only,
            .resumed = built.resumed,
            .truncated = built.truncated,
        });
    }
    return protocol.result(allocator, id_json, .{
        .clientId = client.id,
        .sessionId = client.session_id,
        .windowId = client.window_id,
        .paneId = client.pane_id,
        .rows = client.rows,
        .cols = client.cols,
        .created = created,
        .exited = exit != null,
        .exitCode = exit_code,
        .signal = signal,
        .generation = generation,
        .replayBase64 = replay_b64,
        .replayStartOffset = built.start_offset,
        .replayEndOffset = built.end_offset,
        .replayMode = opts.mode.label(),
        .readOnly = opts.read_only,
        .resumed = built.resumed,
    });
}

const BuiltReplay = struct {
    bytes: []u8,
    start_offset: u64,
    end_offset: u64,
    resumed: bool,
    truncated: bool,
};

fn buildAttachReplay(
    allocator: std.mem.Allocator,
    native: *native_mod.NativeSession,
    generation: u64,
    opts: AttachReplayOpts,
) !BuiltReplay {
    switch (opts.mode) {
        .none => {
            const end_off = native.scrollbackEndOffset();
            return .{
                .bytes = try allocator.alloc(u8, 0),
                .start_offset = end_off,
                .end_offset = end_off,
                .resumed = false,
                .truncated = false,
            };
        },
        .ansi_restore => {
            const end_off = native.scrollbackEndOffset();
            const restore = try native.ansiRestore(allocator);
            return .{
                .bytes = restore,
                .start_offset = end_off,
                .end_offset = end_off,
                .resumed = false,
                .truncated = false,
            };
        },
        .raw => {
            if (opts.resume_from_offset) |from_off| {
                const gen_ok = opts.resume_generation == null or opts.resume_generation.? == generation;
                if (gen_ok) {
                    const delta = try native.scrollbackSliceSince(allocator, from_off, attach_replay_max_bytes);
                    return .{
                        .bytes = delta.tail.bytes,
                        .start_offset = delta.tail.start_offset,
                        .end_offset = delta.tail.end_offset,
                        .resumed = delta.resumed,
                        .truncated = delta.truncated,
                    };
                }
                const tail = try native.scrollbackTail(allocator, attach_replay_max_bytes);
                return .{
                    .bytes = tail.bytes,
                    .start_offset = tail.start_offset,
                    .end_offset = tail.end_offset,
                    .resumed = false,
                    .truncated = true,
                };
            }
            const tail = try native.scrollbackTail(allocator, attach_replay_max_bytes);
            assert(tail.end_offset - tail.start_offset == tail.bytes.len);
            return .{
                .bytes = tail.bytes,
                .start_offset = tail.start_offset,
                .end_offset = tail.end_offset,
                .resumed = false,
                .truncated = false,
            };
        },
    }
}

test "ReplayMode parses raw, ansi_restore, vt alias, and none" {
    try std.testing.expectEqual(@as(?ReplayMode, .raw), ReplayMode.parse("raw"));
    try std.testing.expectEqual(@as(?ReplayMode, .ansi_restore), ReplayMode.parse("ansi_restore"));
    try std.testing.expectEqual(@as(?ReplayMode, .ansi_restore), ReplayMode.parse("vt"));
    try std.testing.expectEqual(@as(?ReplayMode, .none), ReplayMode.parse("none"));
    try std.testing.expectEqual(@as(?ReplayMode, null), ReplayMode.parse("unknown"));
}

test "RPC: session.screen, formatted session.capture, client.attach replay/resume, and OSC push notifications" {
    const builtin = @import("builtin");
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const fuzz_hooks = @import("fuzz_hooks.zig").fuzz_hooks;
    const ts = @import("test_support.zig");
    const allocator = std.testing.allocator;

    var server = try fuzz_hooks.initInMemoryServer(allocator, ts.test_io);
    defer fuzz_hooks.deinitInMemoryServer(&server);
    fuzz_hooks.enableEvents(&server);
    var client = try ts.TestClient.start(&server);
    defer client.stop();

    try client.send("{\"id\":1,\"method\":\"events.subscribe\",\"params\":{\"panes\":[\"*\"]}}\n");
    var sub = try client.response(1);
    sub.deinit();

    try client.send("{\"id\":2,\"method\":\"session.create\",\"params\":{\"title\":\"vt-rpc\",\"shell\":\"/bin/sh\"," ++
        "\"command\":\"printf '\\\\033]2;rpc-title\\\\007\\\\033]7;file://h/work\\\\007" ++
        "\\\\033]133;C\\\\007\\\\033]133;D;0\\\\007\\\\033]7501;working;running\\\\007" ++
        "\\\\033[1mSCREEN_OK\\\\033[0m\\\\n'; exec cat\",\"rows\":10,\"cols\":40}}\n");
    var created = try client.response(2);
    defer created.deinit();
    const pane_id = try allocator.dupe(u8, (try ts.resultOf(&created)).get("paneId").?.string);
    defer allocator.free(pane_id);

    // Wait for all 4 OSC notifications + output.
    try client.sendFmt("{{\"id\":3,\"method\":\"pane.wait\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"pattern\":\"SCREEN_OK\",\"timeoutMs\":5000}}}}\n", .{pane_id});
    var waited = try client.response(3);
    defer waited.deinit();
    try std.testing.expect((try ts.resultOf(&waited)).get("matched").?.bool);

    // session.screen with cells + ansiRestore.
    try client.sendFmt("{{\"id\":4,\"method\":\"session.screen\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"includeCells\":true,\"includeAnsiRestore\":true,\"includeScrollback\":5}}}}\n", .{pane_id});
    var scr = try client.response(4);
    defer scr.deinit();
    const sobj = try ts.resultOf(&scr);
    try std.testing.expectEqualStrings("rpc-title", sobj.get("title").?.string);
    try std.testing.expectEqualStrings("/work", sobj.get("cwd").?.string);
    try std.testing.expectEqualStrings("working", sobj.get("agentStatus").?.string);
    try std.testing.expect(std.mem.indexOf(u8, sobj.get("text").?.string, "SCREEN_OK") != null);
    try std.testing.expect(sobj.get("cells").?.array.items.len >= 10);
    try std.testing.expect(sobj.get("ansiRestore").?.string.len > 0);

    // session.capture format=plain, ansi, cells, and invalid format.
    try client.sendFmt("{{\"id\":5,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"format\":\"plain\"}}}}\n", .{pane_id});
    var cap_plain = try client.response(5);
    defer cap_plain.deinit();
    try std.testing.expect(std.mem.indexOf(u8, (try ts.resultOf(&cap_plain)).get("text").?.string, "SCREEN_OK") != null);

    try client.sendFmt("{{\"id\":6,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"format\":\"cells\"}}}}\n", .{pane_id});
    var cap_cells = try client.response(6);
    defer cap_cells.deinit();
    try std.testing.expect((try ts.resultOf(&cap_cells)).get("cells").? == .array);

    try client.sendFmt("{{\"id\":7,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"format\":\"bogus\"}}}}\n", .{pane_id});
    var cap_bad = try client.response(7);
    defer cap_bad.deinit();
    try ts.expectRpcError(&cap_bad, -32602, "invalid_params", "InvalidParams");

    // client.attach replayMode=vt + readOnly=true + resumeFromOffset exact vs mismatched generation.
    try client.sendFmt("{{\"id\":8,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"rows\":5,\"cols\":20,\"readOnly\":true,\"replayMode\":\"vt\"}}}}\n", .{pane_id});
    var att_vt = try client.response(8);
    defer att_vt.deinit();
    const av = try ts.resultOf(&att_vt);
    try std.testing.expectEqualStrings("ansi_restore", av.get("replayMode").?.string);
    try std.testing.expect(av.get("readOnly").?.bool);
    const end_off = av.get("replayEndOffset").?.integer;
    const gen = av.get("generation").?.integer;

    try client.sendFmt("{{\"id\":9,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"readOnly\":true,\"resumeFromOffset\":{d},\"resumeGeneration\":{d}}}}}\n", .{ pane_id, end_off, gen });
    var att_res = try client.response(9);
    defer att_res.deinit();
    const ar = try ts.resultOf(&att_res);
    try std.testing.expect(ar.get("resumed").?.bool);
    try std.testing.expect(!ar.get("truncated").?.bool);

    try client.sendFmt("{{\"id\":10,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\"," ++
        "\"readOnly\":true,\"resumeFromOffset\":{d},\"resumeGeneration\":{d}}}}}\n", .{ pane_id, end_off, gen + 1 });
    var att_mis = try client.response(10);
    defer att_mis.deinit();
    const am = try ts.resultOf(&att_mis);
    try std.testing.expect(!am.get("resumed").?.bool);
    try std.testing.expect(am.get("truncated").?.bool);

    // Emit another OSC sequence and verify live push notification arrives over JSON-RPC.
    try client.sendFmt("{{\"id\":11,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\"," ++
        "\"text\":\"\\u001b]2;pushed-title\\u0007\",\"enter\":true}}}}\n", .{pane_id});
    var notif = try client.notification(protocol.pane_title_changed_method);
    defer notif.deinit();
    try std.testing.expectEqualStrings("pushed-title", notif.value.object.get("params").?.object.get("title").?.string);
}
