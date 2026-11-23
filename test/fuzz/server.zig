const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const server = zmux.server;
const hooks = server.fuzz_hooks;
const sys = zmux.sys;
const LineReader = zmux.internal.rpc_line_reader.LineReader;

fn fuzzServerParamsAndEnv(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var buf: [2048]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return;
    defer parsed.deinit();

    const params: ?std.json.Value = parsed.value;
    _ = hooks.sessionId(params);
    _ = hooks.paneId(params);
    _ = hooks.windowId(params);
    _ = hooks.clientId(params);
    _ = hooks.axis(params);
    _ = hooks.boolParamVal(params, "enter", false);
    _ = hooks.boolParamVal(params, "repeat", true);
    _ = hooks.intParamVal(u16, params, "rows", 24);
    _ = hooks.intParamVal(u16, params, "cols", 80);
    _ = hooks.intParamVal(usize, params, "lines", 200);

    const id_aliases_title = smith.value(bool);
    if (hooks.muxCreateArgs(allocator, params, .{ .id_aliases_title = id_aliases_title })) |*args_val| {
        var args = args_val.*;
        defer args.deinit();
        try std.testing.expect(args.opts.scrollback_bytes <= zmux.buffer.max_capacity);
        if (args.opts.env) |entries| {
            for (entries) |entry| {
                // Every env entry must contain '=' separating key and value.
                try std.testing.expect(std.mem.indexOfScalar(u8, entry, '=') != null);
            }
        }
    } else |err| {
        try std.testing.expect(err == error.ScrollbackBytesTooLarge or err == error.OutOfMemory);
    }

    // OOM safety on muxCreateArgs / envEntriesFromParams.
    const fail_idx = smith.valueRangeAtMost(u8, 0, 12);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (hooks.muxCreateArgs(fa, params, .{ .id_aliases_title = id_aliases_title })) |*args_val| {
        var args = args_val.*;
        args.deinit();
    } else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzServerBase64AndReplay(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);

    // 1. Round-trip encode -> decode must be exact identity for any bytes.
    const encoded = try hooks.b64Encode(allocator, raw);
    defer allocator.free(encoded);
    const decoded = try hooks.b64Decode(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, raw, decoded);

    // 2. Decoding arbitrary untrusted bytes must never panic or leak.
    if (hooks.b64Decode(allocator, raw)) |ok| {
        allocator.free(ok);
    } else |_| {}

    // 3. truncatedReplay invariants
    const cap: usize = switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => 0,
        1 => smith.valueRangeAtMost(u16, 1, 64),
        2 => raw.len,
        else => std.math.maxInt(usize),
    };
    const tail = hooks.replayTail(raw, cap);
    try std.testing.expectEqual(@min(raw.len, cap), tail.len);
    try std.testing.expect(std.mem.endsWith(u8, raw, tail));

    // 4. OOM safety on base64Encode / base64Decode
    const fail_idx = smith.valueRangeAtMost(u8, 0, 4);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (hooks.b64Encode(fa, raw)) |e| fa.free(e) else |_| {}
    if (hooks.b64Decode(fa, encoded)) |d| fa.free(d) else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzClientConnectionBackpressure(_: void, smith: *std.testing.Smith) !void {
    const saved_log_level = zmux.internal.log.getLevel();
    zmux.internal.log.setLevel(.err);
    defer zmux.internal.log.setLevel(saved_log_level);

    const allocator = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);

    const conn = try hooks.createConnection(allocator, std.testing.io, pair[0]);
    defer hooks.releaseConnection(conn);

    var ref_queue: std.ArrayList([]u8) = .empty;
    defer {
        for (ref_queue.items) |item| allocator.free(item);
        ref_queue.deinit(allocator);
    }
    var ref_queued_bytes: usize = 0;

    var tracked_clients = std.StringHashMap(void).init(allocator);
    defer {
        var it = tracked_clients.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        tracked_clients.deinit();
    }

    const Op = enum(u8) {
        enqueue_small,
        enqueue_large,
        drain_one,
        track_client,
        untrack_client,
        close_conn,
    };

    var msg_buf: [256]u8 = undefined;
    var cid_buf: [32]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 48) : (steps += 1) {
        switch (smith.value(Op)) {
            .enqueue_small => {
                const payload = corpus.drawBytes(smith, &msg_buf);
                if (hooks.enqueueBroadcast(conn, payload)) {
                    try ref_queue.append(allocator, try allocator.dupe(u8, payload));
                    ref_queued_bytes += payload.len;
                } else |err| {
                    try std.testing.expect(err == error.ConnectionClosed or err == error.ConnectionBacklogged);
                    try std.testing.expect(hooks.isConnectionClosed(conn));
                }
            },
            .enqueue_large => {
                // Stress exact broadcast_queue_max_bytes boundary.
                const size: usize = switch (smith.valueRangeAtMost(u8, 0, 2)) {
                    0 => hooks.broadcast_queue_cap / 2,
                    1 => hooks.broadcast_queue_cap,
                    else => hooks.broadcast_queue_cap + 1,
                };
                const big = try allocator.alloc(u8, size);
                defer allocator.free(big);
                @memset(big, 'A');
                if (hooks.enqueueBroadcast(conn, big)) {
                    try std.testing.expect(size <= hooks.broadcast_queue_cap);
                    try ref_queue.append(allocator, try allocator.dupe(u8, big));
                    ref_queued_bytes += size;
                } else |err| {
                    try std.testing.expect(err == error.ConnectionClosed or err == error.ConnectionBacklogged);
                    try std.testing.expect(hooks.isConnectionClosed(conn));
                }
            },
            .drain_one => {
                if (ref_queue.items.len == 0 and !hooks.isConnectionClosed(conn)) continue;
                const got = hooks.takeQueuedWrite(conn);
                if (ref_queue.items.len == 0) {
                    try std.testing.expect(got == null);
                } else {
                    const actual = got.?;
                    defer allocator.free(actual);
                    const expected = ref_queue.orderedRemove(0);
                    defer allocator.free(expected);
                    ref_queued_bytes -= expected.len;
                    try std.testing.expectEqualSlices(u8, expected, actual);
                }
            },
            .track_client => {
                const cid = corpus.drawAsciiSlice(smith, &cid_buf);
                try hooks.trackMuxClient(conn, cid);
                if (!tracked_clients.contains(cid)) {
                    try tracked_clients.put(try allocator.dupe(u8, cid), {});
                }
            },
            .untrack_client => {
                const cid = corpus.drawAsciiSlice(smith, &cid_buf);
                const removed = hooks.untrackMuxClient(conn, cid);
                if (tracked_clients.fetchRemove(cid)) |kv| {
                    allocator.free(kv.key);
                    try std.testing.expect(removed);
                } else {
                    try std.testing.expect(!removed);
                }
            },
            .close_conn => {
                hooks.closeConnection(conn);
                try std.testing.expect(hooks.isConnectionClosed(conn));
            },
        }
        try std.testing.expectEqual(ref_queued_bytes, conn.queued_bytes);
        try std.testing.expectEqual(ref_queue.items.len, conn.pending_writes.items.len);
    }

    // Take remaining mux clients and check exact match with reference set.
    var final_clients = hooks.takeMuxClients(conn);
    defer {
        for (final_clients.items) |cid| allocator.free(cid);
        final_clients.deinit(allocator);
    }
    try std.testing.expectEqual(tracked_clients.count(), final_clients.items.len);
    for (final_clients.items) |cid| {
        try std.testing.expect(tracked_clients.contains(cid));
    }
}

fn fuzzInMemoryServerWireProtocol(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var srv = try hooks.initInMemoryServer(allocator, io);
    defer hooks.deinitInMemoryServer(&srv);

    const pair = try sys.socketPair();
    // `driveClient` takes ownership of `pair[0]` (closes on connection.release()).
    defer sys.close(pair[1]);

    // Build a stream of JSON-RPC frames covering ALL non-spawning methods,
    // error paths, invalid params, unknown methods, raw malformed frames, and
    // whitespace lines. (Live PTY spawning methods are fuzzed in `live.zig`.)
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);

    const FrameKind = enum(u8) {
        raw_garbage,
        ping,
        list_sessions,
        snapshot,
        list_clients,
        list_keys,
        bind_key,
        dispatch_key,
        exec_command,
        missing_target_rpc,
        invalid_scrollback_create,
        bad_base64_send,
        unknown_method,
        whitespace_line,
        shutdown,
    };

    var tmp_buf: [256]u8 = undefined;
    var tmp_buf2: [128]u8 = undefined;
    var req_id: u32 = 1;
    var steps: usize = 0;
    while (!smith.eos() and steps < 24) : (steps += 1) {
        const kind = smith.value(FrameKind);
        switch (kind) {
            .raw_garbage => {
                const raw = corpus.drawBytes(smith, &tmp_buf);
                // Avoid sending an accidental `session.create` that spawns a real shell
                // in the fast wire fuzzer; replace "session.create" if ever synthesized.
                if (std.mem.indexOf(u8, raw, "session.create") == null) {
                    try stream.appendSlice(allocator, raw);
                    try stream.append(allocator, '\n');
                }
            },
            .ping => {
                const line = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"daemon.ping\"}}\n", .{req_id});
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .list_sessions => {
                const line = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.list\",\"params\":{{}}}}\n", .{req_id});
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .snapshot => {
                const line = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"mux.snapshot\"}}\n", .{req_id});
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .list_clients => {
                const line = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"client.list\"}}\n", .{req_id});
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .list_keys => {
                const line = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"key.list\"}}\n", .{req_id});
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .bind_key => {
                const key = corpus.drawAsciiSlice(smith, &tmp_buf2);
                const cmd = corpus.drawAsciiSlice(smith, &tmp_buf);
                const repeat = smith.value(bool);
                const line = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"key.bind\",\"params\":{{\"table\":\"prefix\",\"key\":{f},\"command\":{f},\"repeat\":{}}}}}\n",
                    .{ req_id, std.json.fmt(key, .{}), std.json.fmt(cmd, .{}), repeat },
                );
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .dispatch_key => {
                const key = corpus.drawAsciiSlice(smith, &tmp_buf2);
                const line = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"key.dispatch\",\"params\":{{\"paneId\":\"nonexistent\",\"key\":{f}}}}}\n",
                    .{ req_id, std.json.fmt(key, .{}) },
                );
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .exec_command => {
                const cmd = corpus.drawAsciiSlice(smith, &tmp_buf);
                const line = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"command.exec\",\"params\":{{\"paneId\":\"nonexistent\",\"command\":{f}}}}}\n",
                    .{ req_id, std.json.fmt(cmd, .{}) },
                );
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .missing_target_rpc => {
                const methods = [_][]const u8{
                    "session.terminate", "session.info",  "session.resize",
                    "session.capture",   "session.send",  "session.sendKey",
                    "session.rename",    "window.new",    "window.select",
                    "window.rename",     "pane.split",    "pane.select",
                    "pane.rename",       "pane.respawn",  "client.attach",
                    "client.detach",     "client.switch",
                };
                const method = methods[smith.index(methods.len)];
                const include_params = smith.value(bool);
                const target = corpus.drawAsciiSlice(smith, &tmp_buf2);
                const line = if (include_params)
                    try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{{\"id\":{f},\"name\":{f},\"title\":{f},\"key\":\"Enter\"}}}}\n",
                        .{ req_id, std.json.fmt(method, .{}), std.json.fmt(target, .{}), std.json.fmt(target, .{}), std.json.fmt(target, .{}) },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{{}}}}\n",
                        .{ req_id, std.json.fmt(method, .{}) },
                    );
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .invalid_scrollback_create => {
                const too_big = zmux.buffer.max_capacity + 1;
                const line = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.create\",\"params\":{{\"scrollbackBytes\":{d}}}}}\n",
                    .{ req_id, too_big },
                );
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .bad_base64_send => {
                const bad = corpus.drawAsciiSlice(smith, &tmp_buf2);
                const line = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.send\",\"params\":{{\"sessionId\":\"ghost\",\"dataBase64\":{f}}}}}\n",
                    .{ req_id, std.json.fmt(bad, .{}) },
                );
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
            },
            .unknown_method => {
                const method = corpus.drawAsciiSlice(smith, &tmp_buf2);
                if (!std.mem.eql(u8, method, "session.create")) {
                    const line = try std.fmt.allocPrint(
                        allocator,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f}}}\n",
                        .{ req_id, std.json.fmt(method, .{}) },
                    );
                    defer allocator.free(line);
                    try stream.appendSlice(allocator, line);
                    req_id += 1;
                }
            },
            .whitespace_line => {
                try stream.appendSlice(allocator, "   \t \r\n");
            },
            .shutdown => {
                const line = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"daemon.shutdown\"}}\n", .{req_id});
                defer allocator.free(line);
                try stream.appendSlice(allocator, line);
                req_id += 1;
                break;
            },
        }
    }

    // Write the entire request burst and half-close the client write side so
    // `driveClient` drains every request and returns on EOF.
    try sys.sendAll(pair[1], stream.items);
    _ = std.c.shutdown(pair[1], @intCast(std.posix.SHUT.WR));

    try hooks.driveClient(&srv, pair[0]);

    // Every response line emitted by the server MUST be a valid single-line JSON-RPC 2.0 frame!
    var reader: LineReader = .{};
    while (try reader.readLineAllocMaybe(allocator, pair[1], hooks.max_request_size)) |resp| {
        defer allocator.free(resp);
        var parsed = try corpus.parseSingleLineJsonObject(allocator, resp);
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
        try std.testing.expect(obj.get("id") != null);
        const has_result = obj.get("result") != null;
        const has_error = obj.get("error") != null;
        try std.testing.expect(has_result != has_error);
        if (has_error) {
            const err_obj = obj.get("error").?.object;
            try std.testing.expect(err_obj.get("code").? == .integer);
            try std.testing.expect(err_obj.get("message").? == .string);
        }
    }
}

test "fuzz: server JSON param extraction, env conversion, and OOM safety" {
    try std.testing.fuzz({}, fuzzServerParamsAndEnv, .{
        .corpus = &.{
            corpus.sliceSeed("{}"),
            corpus.sliceSeed("{\"id\":\"work\",\"rows\":40,\"cols\":120,\"scrollbackBytes\":4096}"),
            corpus.sliceSeed("{\"env\":{\"A\":\"1\",\"B\":2,\"C\":3.5,\"D\":true,\"E\":null,\"F\":[1,2]}}"),
            corpus.sliceSeed("{\"scrollbackBytes\":999999999999}"),
            corpus.sliceSeed("{\"scrollbackBytes\":-5,\"rows\":999999,\"cols\":-1}"),
            corpus.sliceSeed("{\"axis\":\"-h\",\"horizontal\":false}"),
            corpus.sliceSeed("null"),
            corpus.sliceSeed("[1,2,3]"),
        },
    });
}

test "fuzz: server base64 round-trip, untrusted decode, and truncatedReplay" {
    try std.testing.fuzz({}, fuzzServerBase64AndReplay, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("aGVsbG8="),
            corpus.sliceSeed("!!!!not-base64!!!!"),
            corpus.sliceSeed("==="),
        },
    });
}

test "fuzz: server ClientConnection broadcast queue backpressure and mux client tracking" {
    try std.testing.fuzz({}, fuzzClientConnectionBackpressure, .{});
}

test "fuzz: server in-memory JSON-RPC wire protocol and 27-method dispatcher" {
    try std.testing.fuzz({}, fuzzInMemoryServerWireProtocol, .{});
}
