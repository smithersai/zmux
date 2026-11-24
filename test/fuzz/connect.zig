const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const connect = zmux.connect;
const hooks = connect.fuzz_hooks;
const protocol = zmux.protocol;
const sys = zmux.sys;
const LineReader = zmux.internal.rpc_line_reader.LineReader;

fn referenceParseDetachKey(spec: []const u8) ?(?u8) {
    if (std.ascii.eqlIgnoreCase(spec, "none")) return @as(?u8, null);
    if (spec.len == 6 and std.ascii.eqlIgnoreCase(spec[0..5], "ctrl-")) {
        const c = spec[5];
        if (std.ascii.isAlphabetic(c)) return @as(?u8, std.ascii.toUpper(c) - 'A' + 1);
        if (c == '\\') return @as(?u8, 0x1C);
    }
    return null;
}

fn fuzzConnectParsersAndFormatters(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var buf1: [512]u8 = undefined;
    var buf2: [128]u8 = undefined;
    var buf3: [128]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf1);
    const s1 = corpus.drawAsciiSlice(smith, &buf2);
    const s2 = corpus.drawAsciiSlice(smith, &buf3);

    // 1. parseDetachKey differential check
    if (referenceParseDetachKey(raw)) |expected| {
        const got = try hooks.parseDetachKeyFn(raw);
        try std.testing.expectEqual(expected, got);
    } else {
        try std.testing.expectError(error.InvalidDetachKey, hooks.parseDetachKeyFn(raw));
    }

    // 2. controlByte check on all byte values
    const byte = smith.value(u8);
    const cb = hooks.controlByteFn(byte);
    if (std.ascii.isAlphabetic(byte)) {
        try std.testing.expectEqual(@as(?u8, std.ascii.toUpper(byte) - 'A' + 1), cb);
    } else if (byte == '\\') {
        try std.testing.expectEqual(@as(?u8, 0x1C), cb);
    } else {
        try std.testing.expect(cb == null);
    }

    // 3. parseVerb & buildVerbRequest JSON-RPC round-trip
    if (hooks.parseVerbFn(raw)) |v| {
        try std.testing.expectEqualStrings(raw, hooks.verbNameFn(v));
    }
    const verb = smith.value(hooks.VerbKind);
    const req_frame = try hooks.buildVerbRequestFn(allocator, verb, s1, s2);
    defer allocator.free(req_frame);
    var parsed_req = try protocol.parseRequest(allocator, req_frame);
    defer parsed_req.deinit();
    var req_obj = try corpus.parseSingleLineJsonObject(allocator, req_frame);
    defer req_obj.deinit();

    // 4. Response parsers on arbitrary untrusted server lines. The old string
    //    helpers (rpcErrorMessage, isPaneNotFound, paneId/clientIdFromAttach)
    //    became `RpcError.fromEnvelope` and `requiredString` over one DOM.
    const verb_target: ?[]const u8 = if (verb == .kill or verb == .rename) s1 else null;
    const verb_name: ?[]const u8 = if (verb == .rename) s2 else null;
    var raw_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch null;
    defer if (raw_parsed) |*p| p.deinit();
    if (raw_parsed) |p| {
        const envelope = p.value;
        if (hooks.rpcErrorFromEnvelopeFn(envelope)) |rpc_err| {
            try std.testing.expect(rpc_err.message.len > 0);
        }
        const result = if (envelope == .object) envelope.object.get("result") orelse .null else .null;
        if (hooks.requiredStringFn(result, "paneId")) |pid| try std.testing.expect(pid.len > 0) else |_| {}
        if (hooks.requiredStringFn(result, "clientId")) |cid| try std.testing.expect(cid.len > 0) else |_| {}
        if (hooks.formatSessionListFn(allocator, result)) |out| allocator.free(out) else |_| {}
        if (hooks.formatVerbResultFn(allocator, verb, verb_target, verb_name, result)) |out| allocator.free(out) else |_| {}
    }

    //    matchesRpcId became `readRpcResponse`: it returns only the response
    //    carrying `expected_id`, or a null-id error envelope.
    {
        const expected_id = smith.value(u32);
        const pair = try sys.socketPair();
        defer sys.close(pair[0]);
        sys.sendAll(pair[1], raw) catch {};
        sys.sendAll(pair[1], "\n") catch {};
        sys.close(pair[1]);
        var reader: LineReader = .{};
        defer reader.deinit();
        if (hooks.readRpcResponseFn(allocator, &reader, pair[0], expected_id, hooks.RpcDeadline.fromNow(std.testing.io, 200))) |resp| {
            defer hooks.deinitResponse(resp, allocator);
            const id = resp.parsed.value.object.get("id").?;
            try std.testing.expect((id == .integer and id.integer == expected_id) or
                (id == .null and hooks.rpcErrorFromEnvelopeFn(resp.parsed.value) != null));
        } else |_| {}
    }

    // 5. replayScrollbackFromAttach + handleServerLine on arbitrary untrusted lines
    // Use a non-blocking pipe or drain pipe after each call so pipes never block.
    const pipe_fds = try sys.pipe();
    defer sys.close(pipe_fds[0]);
    defer sys.close(pipe_fds[1]);
    try sys.setNonBlocking(pipe_fds[0]);
    try sys.setNonBlocking(pipe_fds[1]);

    if (raw_parsed) |p| {
        if (p.value == .object) {
            const result = p.value.object.get("result") orelse .null;
            hooks.replayScrollbackFromAttachFn(allocator, result, pipe_fds[1]) catch {};
        }
    }
    // Differential: the backslash-free fast path must agree with the DOM path.
    try expectFastPathMatchesDom(allocator, raw, s1);

    // Also test valid pane_output round-trip through handleServerLine!
    const b64 = try hooks.b64EncodeFn(allocator, raw);
    defer allocator.free(b64);
    const valid_output = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{{\"pane_id\":{f},\"data_base64\":{f}}}}}\n",
        .{ std.json.fmt(s1, .{}), std.json.fmt(b64, .{}) },
    );
    defer allocator.free(valid_output);

    {
        var state = newRunState(s1);
        defer freeRunState(allocator, &state);
        var output: ?[]u8 = null;
        defer if (output) |o| allocator.free(o);
        const outcome = try hooks.handleServerLineFn(allocator, valid_output, &state, &output, std.testing.io);
        try std.testing.expect(outcome == null);
        try std.testing.expectEqualSlices(u8, raw, output orelse "");
    }
    try expectFastPathMatchesDom(allocator, valid_output, s1);

    // 6. Semantic differential invariants:
    //    (a) replayScrollback must handle standard JSON whitespace too.
    const pretty_attach = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\": \"2.0\", \"id\": 1, \"result\": {{\"clientId\": \"c1\", \"paneId\": \"p1\", \"replayBase64\": {f}}}}}\n",
        .{std.json.fmt(b64, .{})},
    );
    defer allocator.free(pretty_attach);
    var pretty_parsed = try std.json.parseFromSlice(std.json.Value, allocator, pretty_attach, .{});
    defer pretty_parsed.deinit();
    const pretty_result = pretty_parsed.value.object.get("result").?;
    try std.testing.expectEqualStrings("p1", try hooks.requiredStringFn(pretty_result, "paneId"));
    try std.testing.expectEqualStrings("c1", try hooks.requiredStringFn(pretty_result, "clientId"));
    const replay_pipe = try sys.pipe();
    defer sys.close(replay_pipe[0]);
    try hooks.replayScrollbackFromAttachFn(allocator, pretty_result, replay_pipe[1]);
    sys.close(replay_pipe[1]);
    var rbuf: [512]u8 = undefined;
    var replay_got: std.ArrayList(u8) = .empty;
    defer replay_got.deinit(allocator);
    while (true) {
        const n = try sys.read(replay_pipe[0], &rbuf);
        if (n == 0) break;
        try replay_got.appendSlice(allocator, rbuf[0..n]);
    }
    try std.testing.expectEqualSlices(u8, raw, replay_got.items);

    //    (b) Corrupt base64 in a pane_output notification must NOT crash
    //        handleServerLine, surface an error, or emit output.
    const bad_b64_line = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{{\"pane_id\":{f},\"data_base64\":\"!!!not-valid-b64!!!\"}}}}\n",
        .{std.json.fmt(s1, .{})},
    );
    defer allocator.free(bad_b64_line);
    {
        var state = newRunState(s1);
        defer freeRunState(allocator, &state);
        var output: ?[]u8 = null;
        defer if (output) |o| allocator.free(o);
        const bad_outcome = try hooks.handleServerLineFn(allocator, bad_b64_line, &state, &output, std.testing.io);
        try std.testing.expect(bad_outcome == null);
        try std.testing.expect(output == null);
    }

    //    (c) OOM safety on connect request builders and response formatters.
    const fail_idx = smith.valueRangeAtMost(u8, 0, 8);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (hooks.buildVerbRequestFn(fa, verb, s1, s2)) |r| fa.free(r) else |_| {}
    if (raw_parsed) |p| {
        const result = if (p.value == .object) p.value.object.get("result") orelse .null else .null;
        if (hooks.formatSessionListFn(fa, result)) |r| fa.free(r) else |_| {}
    }
    {
        var state = newRunState(s1);
        defer freeRunState(fa, &state);
        var output: ?[]u8 = null;
        defer if (output) |o| fa.free(o);
        _ = hooks.handleServerLineFn(fa, valid_output, &state, &output, std.testing.io) catch {};
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn newRunState(pane_id: []const u8) hooks.RunStateKind {
    return .{ .pane_id = pane_id, .client_id = "client-1", .generation = null, .next_offset = null };
}

fn freeRunState(allocator: std.mem.Allocator, state: *hooks.RunStateKind) void {
    if (state.switched_pane) |pane| allocator.free(pane);
    state.switched_pane = null;
}

/// `handleServerLine` skips the DOM parse for backslash-free lines; its
/// outcome, output, and state change must equal `handleServerLineDom`'s.
fn expectFastPathMatchesDom(allocator: std.mem.Allocator, line: []const u8, pane_id: []const u8) !void {
    const io = std.testing.io;
    var fast_state = newRunState(pane_id);
    defer freeRunState(allocator, &fast_state);
    var dom_state = newRunState(pane_id);
    defer freeRunState(allocator, &dom_state);
    var fast_out: ?[]u8 = null;
    defer if (fast_out) |o| allocator.free(o);
    var dom_out: ?[]u8 = null;
    defer if (dom_out) |o| allocator.free(o);

    const fast = hooks.handleServerLineFn(allocator, line, &fast_state, &fast_out, io);
    const dom = hooks.handleServerLineDomFn(allocator, line, &dom_state, &dom_out, io);
    if (dom) |dom_outcome| {
        try std.testing.expectEqual(dom_outcome, try fast);
    } else |dom_err| {
        try std.testing.expectError(dom_err, fast);
    }
    try std.testing.expectEqualSlices(u8, dom_out orelse "", fast_out orelse "");
    try std.testing.expectEqual(dom_out == null, fast_out == null);
    try std.testing.expectEqualStrings(dom_state.pane_id, fast_state.pane_id);
    try std.testing.expectEqual(dom_state.generation, fast_state.generation);
    try std.testing.expectEqual(dom_state.next_offset, fast_state.next_offset);
}

fn fuzzConnectCliParsers(_: void, smith: *std.testing.Smith) !void {
    const tokens = [_][]const u8{
        "zmux-connect",
        "--socket",
        "/tmp/z.sock",
        "--spawn-daemon",
        "--no-create",
        "--command",
        "sh -c true",
        "--detach-key",
        "ctrl-a",
        "ctrl-\\",
        "none",
        "bad-key",
        "--json",
        "--version",
        "-V",
        "--help",
        "-h",
        "--unknown",
        "-x",
        "work",
        "extra",
        "",
    };

    var argv_buf: [12][]const u8 = undefined;
    argv_buf[0] = "zmux-connect";
    var argc: usize = 1;
    while (!smith.eos() and argc < argv_buf.len) : (argc += 1) {
        argv_buf[argc] = tokens[smith.index(tokens.len)];
    }

    var attach_fail: connect.ParseAttachArgsFailure = .{ .err = error.UnknownFlag };
    if (hooks.parseAttachArgsFn(argv_buf[0..argc], &attach_fail)) |parsed| {
        if (parsed.detach_key) |k| {
            try std.testing.expect((k >= 1 and k <= 26) or k == 0x1C);
        }
    } else |err| {
        try std.testing.expectEqual(err, attach_fail.err);
    }

    const verb = smith.value(hooks.VerbKind);
    var verb_fail: connect.ParseVerbArgsFailure = .{ .err = error.UnknownFlag };
    if (hooks.parseVerbArgsFn(verb, argv_buf[1..argc], &verb_fail)) |parsed| {
        if (!parsed.show_help) {
            if (verb == .kill or verb == .rename) try std.testing.expect(parsed.target != null);
            if (verb == .rename) try std.testing.expect(parsed.new_name != null);
        }
    } else |err| {
        try std.testing.expectEqual(err, verb_fail.err);
    }
}

fn fuzzConnectProtocolFlows(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Flow = enum(u8) {
        attach_or_create,
        execute_verb,
        daemon_version,
        run_loop,
    };

    switch (smith.value(Flow)) {
        .attach_or_create => {
            const pair = try sys.socketPair();
            defer sys.close(pair[0]);
            defer sys.close(pair[1]);

            var sid_buf: [32]u8 = undefined;
            const sid = corpus.drawAsciiSlice(smith, &sid_buf);
            const auto_create = smith.value(bool);

            // Feed arbitrary interleaved notifications + responses for ids 1, 2, 3, then close write half.
            const scenario = smith.valueRangeAtMost(u8, 0, 4);
            switch (scenario) {
                0 => try sys.sendAll(pair[1], "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{}}\n{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"clientId\":\"c1\",\"paneId\":\"p1\"}}\n"),
                1 => try sys.sendAll(pair[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\"}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"id\":\"p1\"}}\n{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"clientId\":\"c2\",\"paneId\":\"p2\"}}\n"),
                2 => try sys.sendAll(pair[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\"}}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"bad\"}}\n"),
                3 => {
                    var raw_buf: [256]u8 = undefined;
                    const raw = corpus.drawBytes(smith, &raw_buf);
                    try sys.sendAll(pair[1], raw);
                },
                else => try sys.sendAll(pair[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"other\"}}\n"),
            }
            _ = std.c.shutdown(pair[1], @intCast(std.posix.SHUT.WR));

            var reader: LineReader = .{};

            defer reader.deinit();
            if (hooks.attachOrCreateFn(
                allocator,
                &reader,
                pair[0],
                sid,
                .{ .rows = 24, .cols = 80 },
                auto_create,
                null,
                hooks.RpcDeadline.fromNow(io, 500),
            )) |resp| {
                hooks.deinitResponse(resp, allocator);
            } else |_| {}
        },
        .execute_verb => {
            const pair = try sys.socketPair();
            defer sys.close(pair[0]);
            defer sys.close(pair[1]);

            const out = try sys.pipe();
            defer sys.close(out[0]);
            defer sys.close(out[1]);
            try sys.setNonBlocking(out[0]);
            try sys.setNonBlocking(out[1]);

            const verb = smith.value(hooks.VerbKind);
            const json_mode = smith.value(bool);
            var raw_buf: [256]u8 = undefined;
            if (smith.value(bool)) {
                try sys.sendAll(pair[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[]}\n");
            } else {
                const raw = corpus.drawBytes(smith, &raw_buf);
                try sys.sendAll(pair[1], raw);
            }
            _ = std.c.shutdown(pair[1], @intCast(std.posix.SHUT.WR));

            var reader: LineReader = .{};

            defer reader.deinit();
            hooks.executeVerbFn(
                allocator,
                pair[0],
                &reader,
                verb,
                "sess-1",
                "renamed",
                json_mode,
                out[1],
                hooks.RpcDeadline.fromNow(io, 500),
            ) catch {};
        },
        .daemon_version => {
            const pair = try sys.socketPair();
            defer sys.close(pair[0]);
            defer sys.close(pair[1]);

            var raw_buf: [256]u8 = undefined;
            const raw = corpus.drawBytes(smith, &raw_buf);
            try sys.sendAll(pair[1], raw);
            _ = std.c.shutdown(pair[1], @intCast(std.posix.SHUT.WR));

            // daemonVersion became warnOnVersionMismatch: the same daemon.ping
            // round trip, which warns instead of returning the version.
            var reader: LineReader = .{};
            defer reader.deinit();
            hooks.warnOnVersionMismatchFn(allocator, &reader, pair[0], hooks.RpcDeadline.fromNow(io, 500)) catch {};
        },
        .run_loop => {
            const stdin_fds = try sys.pipe();
            defer sys.close(stdin_fds[0]);
            var stdin_w_open = true;
            defer if (stdin_w_open) sys.close(stdin_fds[1]);

            const sock_pair = try sys.socketPair();
            defer sys.close(sock_pair[0]);
            var sock_peer_open = true;
            defer if (sock_peer_open) sys.close(sock_pair[1]);

            const stdout_fds = try sys.pipe();
            defer sys.close(stdout_fds[0]);
            defer sys.close(stdout_fds[1]);
            try sys.setNonBlocking(stdout_fds[0]);
            try sys.setNonBlocking(stdout_fds[1]);

            var in_buf: [128]u8 = undefined;
            const stdin_bytes = corpus.drawBytes(smith, &in_buf);
            if (stdin_bytes.len > 0) try sys.writeAll(stdin_fds[1], stdin_bytes);
            if (smith.value(bool)) {
                sys.close(stdin_fds[1]);
                stdin_w_open = false;
            }

            if (smith.value(bool)) {
                var srv_buf: [256]u8 = undefined;
                const srv_bytes = corpus.drawBytes(smith, &srv_buf);
                if (srv_bytes.len > 0) try sys.sendAll(sock_pair[1], srv_bytes);
            } else {
                try sys.sendAll(
                    sock_pair[1],
                    "{\"jsonrpc\":\"2.0\",\"method\":\"session_exited\",\"params\":{\"session_id\":\"pane-1\",\"pid\":1}}\n",
                );
            }
            // Always close peer write end so runLoop terminates deterministically without hanging.
            sys.close(sock_pair[1]);
            sock_peer_open = false;

            const detach_key: ?u8 = if (smith.value(bool)) hooks.default_detach else null;
            var reader: LineReader = .{};
            defer reader.deinit();
            _ = hooks.runLoopFn(
                stdin_fds[0],
                stdout_fds[1],
                sock_pair[0],
                &reader,
                allocator,
                .{ .pane_id = "pane-1", .detach_key = detach_key, .client_id = "client-1", .io = io },
            ) catch {};
        },
    }
}

test "fuzz: connect parsers, formatters, replay, and server notification handler" {
    try std.testing.fuzz({}, fuzzConnectParsersAndFormatters, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("ctrl-\\"),
            corpus.sliceSeed("none"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"clientId\":\"c1\",\"paneId\":\"p1\",\"replayBase64\":\"aGVsbG8=\"}}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\"}}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p1\",\"data_base64\":\"!!!\"}}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"result\":[{\"sessionId\":\"s\",\"paneId\":\"p\",\"state\":\"running\",\"pid\":42,\"title\":\"t\"}]}"),
        },
    });
}

test "fuzz: connect CLI attach and verb argument parsers" {
    try std.testing.fuzz({}, fuzzConnectCliParsers, .{});
}

test "fuzz: connect protocol flows (attachOrCreate, executeVerb, daemonVersion, runLoop)" {
    try std.testing.fuzz({}, fuzzConnectProtocolFlows, .{});
}
