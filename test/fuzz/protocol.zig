const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const protocol = zmux.protocol;

fn fuzzParseRequestRaw(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var buf: [2048]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);

    var req = protocol.parseRequest(allocator, raw) catch {
        // Any parse / invalid request error must leave zero leaked memory.
        return;
    };
    defer req.deinit();

    // Every accepted request must produce a valid JSON `id_json` with no raw newlines.
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, req.id_json, '\n'));
    var id_parsed = try std.json.parseFromSlice(std.json.Value, allocator, req.id_json, .{});
    defer id_parsed.deinit();

    // Formatting any response using the parsed id_json must emit a single valid JSON line.
    const ok_frame = try protocol.result(allocator, req.id_json, .{
        .ok = true,
        .method = req.method,
    });
    defer allocator.free(ok_frame);
    var ok_parsed = try corpus.parseSingleLineJsonObject(allocator, ok_frame);
    defer ok_parsed.deinit();
    try std.testing.expectEqualStrings("2.0", ok_parsed.value.object.get("jsonrpc").?.string);
    try std.testing.expect(ok_parsed.value.object.get("id") != null);
    try std.testing.expect(ok_parsed.value.object.get("result") != null);

    const err_frame = try protocol.@"error"(allocator, req.id_json, protocol.ErrorCode.session_error, req.method);
    defer allocator.free(err_frame);
    var err_parsed = try corpus.parseSingleLineJsonObject(allocator, err_frame);
    defer err_parsed.deinit();
    try std.testing.expectEqualStrings("2.0", err_parsed.value.object.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, protocol.ErrorCode.session_error), err_parsed.value.object.get("error").?.object.get("code").?.integer);
    try std.testing.expectEqualStrings(req.method, err_parsed.value.object.get("error").?.object.get("message").?.string);
}

fn fuzzProtocolSerializationAndOom(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    var method_buf: [128]u8 = undefined;
    var msg_buf: [256]u8 = undefined;
    var id_buf: [64]u8 = undefined;
    var arg1_buf: [64]u8 = undefined;
    var arg2_buf: [64]u8 = undefined;

    const method = corpus.drawAsciiSlice(smith, &method_buf);
    const message = corpus.drawAsciiSlice(smith, &msg_buf);
    const id_str = corpus.drawAsciiSlice(smith, &id_buf);
    const arg1 = corpus.drawAsciiSlice(smith, &arg1_buf);
    const arg2 = corpus.drawAsciiSlice(smith, &arg2_buf);
    const err_code = smith.value(i32);
    const pid = smith.valueRangeAtMost(i32, -100, 1_000_000);
    const ts_ms = smith.value(i64);
    const exit_code: ?u32 = if (smith.value(bool)) smith.value(u32) else null;
    const signal: ?u32 = if (smith.value(bool)) smith.value(u32) else null;

    // JSON-encode `id_str` as a valid id_json (string or integer or null).
    const id_kind = smith.valueRangeAtMost(u8, 0, 2);
    const id_json = switch (id_kind) {
        0 => try allocator.dupe(u8, "null"),
        1 => try std.fmt.allocPrint(allocator, "{d}", .{smith.value(i64)}),
        else => try protocol.jsonValueAlloc(allocator, .{ .string = id_str }),
    };
    defer allocator.free(id_json);

    // 1. Result frame
    {
        const frame = try protocol.result(allocator, id_json, .{
            .method = method,
            .message = message,
            .ts = ts_ms,
        });
        defer allocator.free(frame);
        var parsed = try corpus.parseSingleLineJsonObject(allocator, frame);
        defer parsed.deinit();
        const res = parsed.value.object.get("result").?.object;
        try std.testing.expectEqualStrings(method, res.get("method").?.string);
        try std.testing.expectEqualStrings(message, res.get("message").?.string);
    }

    // 2. Error frame
    {
        const frame = try protocol.@"error"(allocator, id_json, err_code, message);
        defer allocator.free(frame);
        var parsed = try corpus.parseSingleLineJsonObject(allocator, frame);
        defer parsed.deinit();
        const err_obj = parsed.value.object.get("error").?.object;
        try std.testing.expectEqual(@as(i64, err_code), err_obj.get("code").?.integer);
        try std.testing.expectEqualStrings(message, err_obj.get("message").?.string);
    }

    // 3. All 5 notification types
    {
        const argv = [_][]const u8{ arg1, arg2 };
        const n1 = try protocol.notification(allocator, protocol.foreground_changed_method, protocol.ForegroundChangedParams{
            .session_id = id_str,
            .pid = pid,
            .comm = method,
            .argv = &argv,
        });
        defer allocator.free(n1);
        var p1 = try corpus.parseSingleLineJsonObject(allocator, n1);
        defer p1.deinit();
        try std.testing.expectEqualStrings(protocol.foreground_changed_method, p1.value.object.get("method").?.string);

        const n2 = try protocol.notification(allocator, protocol.session_exited_method, protocol.SessionExitedParams{
            .session_id = id_str,
            .pid = pid,
            .exit_code = exit_code,
            .signal = signal,
        });
        defer allocator.free(n2);
        var p2 = try corpus.parseSingleLineJsonObject(allocator, n2);
        defer p2.deinit();

        const n3 = try protocol.notification(allocator, protocol.pane_output_method, protocol.PaneOutputParams{
            .pane_id = id_str,
            .data_base64 = message,
        });
        defer allocator.free(n3);
        var p3 = try corpus.parseSingleLineJsonObject(allocator, n3);
        defer p3.deinit();

        const n4 = try protocol.notification(allocator, protocol.pane_activity_method, protocol.PaneActivityParams{
            .pane_id = id_str,
            .last_activity_ms = ts_ms,
        });
        defer allocator.free(n4);
        var p4 = try corpus.parseSingleLineJsonObject(allocator, n4);
        defer p4.deinit();

        const n5 = try protocol.notification(allocator, protocol.pane_bell_method, protocol.PaneBellParams{
            .pane_id = id_str,
            .last_bell_ms = ts_ms,
        });
        defer allocator.free(n5);
        var p5 = try corpus.parseSingleLineJsonObject(allocator, n5);
        defer p5.deinit();
    }

    // 4. OOM safety across parseRequest & formatters.
    const req_line = try protocol.notification(allocator, method, .{ .msg = message });
    defer allocator.free(req_line);

    const fail_idx = smith.valueRangeAtMost(u8, 0, 8);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (protocol.parseRequest(fa, req_line)) |*r| {
        var owned = r.*;
        owned.deinit();
    } else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "fuzz: protocol.parseRequest arbitrary byte streams" {
    try std.testing.fuzz({}, fuzzParseRequestRaw, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("{}\n"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\",\"params\":{}}\n"),
            corpus.sliceSeed("{\"id\":\"str-id\",\"method\":\"session.create\",\"params\":{\"id\":\"work\"}}\n"),
            corpus.sliceSeed("{\"id\":[1,{\"a\":\"b\"}],\"method\":\"x\"}\n"),
            corpus.sliceSeed("{\"method\":\"pane_output\",\"params\":null}\n"),
            corpus.sliceSeed("{\"id\":1,\"method\":123}\n"),
            corpus.sliceSeed("[[[[[[[[[[[[[[[["),
            corpus.sliceSeed("{\"id\":1e999,\"method\":\"m\"}"),
        },
    });
}

test "fuzz: protocol serialization round-trips and OOM safety" {
    try std.testing.fuzz({}, fuzzProtocolSerializationAndOom, .{});
}
