const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("test_build_options");
const zmux = @import("zmux");

const posix = std.posix;
const server_mod = zmux.server;
const sys = zmux.sys;
const io = std.testing.io;

/// Milliseconds on the monotonic clock; only compared with other `nowMs` values.
fn nowMs() i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

fn sleepMs(ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn tempSocketPath(allocator: std.mem.Allocator) ![]u8 {
    // Use the system tmp dir for the UNIX domain socket. sun_path has a
    // ~104 byte limit on Darwin, so we keep the path short.
    var seed: [8]u8 = undefined;
    io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(allocator, "{s}/zmx-test-{x:0>16}.sock", .{ root, nonce });
    errdefer allocator.free(path);
    try requireUnixSocketBind(path);
    return path;
}

fn requireUnixSocketBind(path: []const u8) !void {
    const address = try sys.UnixAddress.init(path);
    const listener = sys.unixStreamSocket() catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer sys.close(listener);
    sys.bind(listener, &address) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

const LineReader = zmux.internal.rpc_line_reader.LineReader;

const Connection = struct {
    fd: posix.fd_t,
    reader: LineReader = .{},

    fn close(self: *Connection) void {
        if (@hasDecl(LineReader, "deinit")) self.reader.deinit();
        sys.close(self.fd);
    }

    fn read(self: *Connection, allocator: std.mem.Allocator, max_len: usize, deadline_ms: i64) ![]u8 {
        if (nowMs() >= deadline_ms) return error.ReadTimeout;
        const timestamp = std.Io.Timestamp.fromNanoseconds(@as(i96, deadline_ms) * std.time.ns_per_ms);
        return self.reader.readLineAllocTimeout(allocator, io, self.fd, max_len, .{ .deadline = timestamp.withClock(.awake) }) catch |err| switch (err) {
            error.ConnectionClosed => error.EndOfStream,
            else => err,
        };
    }
};

fn connectClient(path: []const u8) !Connection {
    return connectClientUntil(path, nowMs() + 2_000);
}

fn connectClientUntil(path: []const u8, deadline: i64) !Connection {
    while (true) {
        const fd = sys.connectUnixDeadline(path, deadline) catch |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound, error.WouldBlock => {
                if (nowMs() >= deadline) return err;
                sleepMs(2);
                continue;
            },
            else => return err,
        };
        return .{ .fd = fd };
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    const deadline = nowMs() + 4_000;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return error.WriteTimeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(remaining)) == 0) return error.WriteTimeout;
        const n = sys.send(fd, bytes[offset..@min(bytes.len, offset + 4096)]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

fn readLineAllocTimeout(allocator: std.mem.Allocator, client: *Connection, max_len: usize, timeout_ms: i64) ![]u8 {
    return client.read(allocator, max_len, nowMs() + timeout_ms);
}

fn rpcLine(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request: []const u8,
    max_len: usize,
) ![]u8 {
    var client = try connectClient(socket_path);
    defer client.close();
    try writeAll(client.fd, request);
    return readRpcResponseWithAnyId(allocator, &client, max_len);
}

fn readRpcResponseWithAnyId(allocator: std.mem.Allocator, client: *Connection, max_len: usize) ![]u8 {
    const deadline = nowMs() + 4_000;
    while (true) {
        const line = try client.read(allocator, max_len, deadline);
        if (lineHasRpcId(allocator, line)) return line;
        allocator.free(line);
    }
}

fn readRpcResponseLine(allocator: std.mem.Allocator, client: *Connection, expected_id: i64, max_len: usize) ![]u8 {
    return readRpcResponseLineTimeout(allocator, client, expected_id, max_len, 4_000);
}

fn readRpcResponseLineTimeout(
    allocator: std.mem.Allocator,
    client: *Connection,
    expected_id: i64,
    max_len: usize,
    timeout_ms: i64,
) ![]u8 {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        const line = try client.read(allocator, max_len, deadline);
        if (lineMatchesRpcId(allocator, line, expected_id)) return line;
        allocator.free(line);
    }
}

fn lineHasRpcId(allocator: std.mem.Allocator, line: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    _ = parsed.value.object.get("id") orelse return false;
    return true;
}

fn lineMatchesRpcId(allocator: std.mem.Allocator, line: []const u8, expected_id: i64) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const id_value = parsed.value.object.get("id") orelse return false;
    if (id_value != .integer) return false;
    return id_value.integer == expected_id;
}

fn waitForSocket(path: []const u8, timeout_ms: i64) !void {
    const allocator = std.testing.allocator;
    const deadline = nowMs() + timeout_ms;
    var client = try connectClientUntil(path, deadline);
    defer client.close();
    try writeAll(client.fd, "{\"id\":1,\"method\":\"daemon.ping\"}\n");
    const reply = try client.read(allocator, 64 * 1024, deadline);
    defer allocator.free(reply);
    try expectNoRpcError(allocator, reply);
}

fn waitForClientCount(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    expected_count: usize,
    timeout_ms: i64,
) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        var client = connectClientUntil(socket_path, deadline) catch {
            sleepMs(10);
            continue;
        };
        defer client.close();

        try writeAll(client.fd, "{\"id\":99,\"method\":\"client.list\",\"params\":{}}\n");

        const line = readRpcResponseLineTimeout(allocator, &client, 99, 64 * 1024, deadline - nowMs()) catch {
            sleepMs(10);
            continue;
        };
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse {
            sleepMs(10);
            continue;
        };
        if (result_val == .array and result_val.array.items.len == expected_count) {
            return;
        }
        sleepMs(10);
    }
    return error.ClientCountTimeout;
}

fn waitForProcessGone(pid: posix.pid_t, timeout_ms: i64) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (std.c.kill(pid, @fromBackingInt(0)) != 0) return;
        sleepMs(10);
    }
    return error.ProcessStillExists;
}

fn waitForSessionExited(
    allocator: std.mem.Allocator,
    fd: *Connection,
    pane_id: []const u8,
    expected_exit_code: i64,
    timeout_ms: i64,
) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const line = try readLineAllocTimeout(allocator, fd, 1024 * 1024, deadline - nowMs());
        defer allocator.free(line);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const method = parsed.value.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "session_exited")) continue;
        const params = parsed.value.object.get("params") orelse continue;
        if (params != .object) continue;
        const session_id = params.object.get("session_id") orelse continue;
        if (session_id != .string or !std.mem.eql(u8, session_id.string, pane_id)) continue;
        const exit_code = params.object.get("exit_code") orelse return error.MissingExitCode;
        try std.testing.expect(exit_code == .integer);
        try std.testing.expectEqual(expected_exit_code, exit_code.integer);
        return;
    }
    return error.SessionExitedTimeout;
}

fn firstPaneMasterFd(server: *server_mod.Server) !posix.fd_t {
    server.manager.mutex.lockUncancelable(server.io);
    defer server.manager.mutex.unlock(server.io);

    if (server.manager.sessions.items.len == 0) return error.MissingSession;
    const session = server.manager.sessions.items[0];
    if (session.windows.items.len == 0) return error.MissingWindow;
    const window = session.windows.items[0];
    if (window.panes.items.len == 0) return error.MissingPane;
    return window.panes.items[0].native.handle.master_fd;
}

fn captureSessionText(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_id: []const u8,
) ![]u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":77,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":50}}}}\n",
        .{session_id},
    );
    defer allocator.free(req);
    const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
    defer allocator.free(line);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
    const text_val = result_val.object.get("text") orelse return error.MissingText;
    if (text_val != .string) return error.MissingText;
    return allocator.dupe(u8, text_val.string);
}

fn waitForCaptureContains(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_id: []const u8,
    needle: []const u8,
    timeout_ms: i64,
) ![]u8 {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        const text = try captureSessionText(allocator, socket_path, session_id);
        if (std.mem.indexOf(u8, text, needle) != null) return text;
        allocator.free(text);
        sleepMs(50);
    }
    return error.CaptureTimeout;
}

const RunServerCtx = struct {
    server: *server_mod.Server,
    run_error: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *RunServerCtx) void {
        defer self.done.store(true, .seq_cst);
        self.server.run() catch |err| {
            self.run_error = err;
        };
    }
};

var test_shutdown_requested = std.atomic.Value(bool).init(false);

fn testShutdownProbe() bool {
    return test_shutdown_requested.load(.seq_cst);
}

fn waitForRunDone(ctx: *RunServerCtx, timeout_ms: i64) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (ctx.done.load(.seq_cst)) return;
        sleepMs(10);
    }
    return error.ServerRunTimeout;
}

fn expectRpcErrorCode(allocator: std.mem.Allocator, line: []const u8, expected_code: i64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expect(err_val == .object);
    const code_val = err_val.object.get("code") orelse return error.MissingErrorCode;
    try std.testing.expect(code_val == .integer);
    try std.testing.expectEqual(expected_code, code_val.integer);
}

fn expectNoRpcError(allocator: std.mem.Allocator, line: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    if (parsed.value.object.get("error")) |_| return error.UnexpectedRpcError;
    _ = parsed.value.object.get("result") orelse return error.MissingResult;
}

fn expectStringField(value: std.json.Value, field: []const u8) ![]const u8 {
    if (value != .object) return error.ExpectedObject;
    const field_value = value.object.get(field) orelse return error.MissingField;
    if (field_value != .string) return error.ExpectedString;
    return field_value.string;
}

fn expectIntegerField(value: std.json.Value, field: []const u8) !i64 {
    if (value != .object) return error.ExpectedObject;
    const field_value = value.object.get(field) orelse return error.MissingField;
    if (field_value != .integer) return error.ExpectedInteger;
    return field_value.integer;
}

fn expectBoolField(value: std.json.Value, field: []const u8) !bool {
    if (value != .object) return error.ExpectedObject;
    const field_value = value.object.get(field) orelse return error.MissingField;
    if (field_value != .bool) return error.ExpectedBool;
    return field_value.bool;
}

fn responseResult(value: std.json.Value) !std.json.Value {
    if (value != .object) return error.ExpectedObject;
    if (value.object.get("error")) |_| return error.UnexpectedRpcError;
    return value.object.get("result") orelse return error.MissingResult;
}

fn findPaneInSnapshot(snapshot: std.json.Value, pane_id: []const u8) ?std.json.Value {
    if (snapshot != .object) return null;
    const sessions = snapshot.object.get("sessions") orelse return null;
    if (sessions != .array) return null;
    for (sessions.array.items) |session| {
        const windows = session.object.get("windows") orelse continue;
        if (windows != .array) continue;
        for (windows.array.items) |window| {
            const panes = window.object.get("panes") orelse continue;
            if (panes != .array) continue;
            for (panes.array.items) |pane| {
                const id = pane.object.get("id") orelse continue;
                if (id == .string and std.mem.eql(u8, id.string, pane_id)) return pane;
            }
        }
    }
    return null;
}

fn panePidFromSnapshot(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) !i64 {
    const line = try rpcLine(allocator, socket_path, "{\"id\":81,\"method\":\"mux.snapshot\",\"params\":{}}\n", 1024 * 1024);
    defer allocator.free(line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const result_val = try responseResult(parsed.value);
    const pane = findPaneInSnapshot(result_val, pane_id) orelse return error.MissingPane;
    return try expectIntegerField(pane, "pid");
}

fn expectPaneAlert(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    field: []const u8,
    expected: bool,
) !void {
    const line = try rpcLine(allocator, socket_path, "{\"id\":82,\"method\":\"mux.snapshot\",\"params\":{}}\n", 1024 * 1024);
    defer allocator.free(line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const result_val = try responseResult(parsed.value);
    const pane = findPaneInSnapshot(result_val, pane_id) orelse return error.MissingPane;
    const alerts = pane.object.get("alerts") orelse return error.MissingAlerts;
    try std.testing.expectEqual(expected, try expectBoolField(alerts, field));
}

fn expectPaneAlertTimestampNonZero(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    field: []const u8,
) !void {
    const line = try rpcLine(allocator, socket_path, "{\"id\":83,\"method\":\"mux.snapshot\",\"params\":{}}\n", 1024 * 1024);
    defer allocator.free(line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const result_val = try responseResult(parsed.value);
    const pane = findPaneInSnapshot(result_val, pane_id) orelse return error.MissingPane;
    const alerts = pane.object.get("alerts") orelse return error.MissingAlerts;
    const ts = try expectIntegerField(alerts, field);
    try std.testing.expect(ts > 0);
}

fn attachReplay(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    rpc_id: i64,
) ![]u8 {
    var client = try connectClient(socket_path);
    defer client.close();
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":{},\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
        .{ rpc_id, pane_id },
    );
    defer allocator.free(attach_req);
    try writeAll(client.fd, attach_req);

    const line = try readRpcResponseLine(allocator, &client, rpc_id, 1024 * 1024);
    defer allocator.free(line);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    const result_val = try responseResult(parsed.value);
    const replay_val = result_val.object.get("replayBase64") orelse return error.MissingReplayField;
    if (replay_val != .string) return error.MissingReplayField;
    return decodeBase64(allocator, replay_val.string);
}

fn readNotificationLine(
    allocator: std.mem.Allocator,
    fd: *Connection,
    expected_method: []const u8,
    expected_pane_id: []const u8,
    timeout_ms: i64,
) ![]u8 {
    const deadline = nowMs() + timeout_ms;
    while (true) {
        const now = nowMs();
        if (now >= deadline) return error.NotificationTimeout;
        const line = try readLineAllocTimeout(allocator, fd, 1024 * 1024, deadline - now);
        errdefer allocator.free(line);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            allocator.free(line);
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            allocator.free(line);
            continue;
        }
        const method = parsed.value.object.get("method") orelse {
            allocator.free(line);
            continue;
        };
        if (method != .string or !std.mem.eql(u8, method.string, expected_method)) {
            allocator.free(line);
            continue;
        }
        const params = parsed.value.object.get("params") orelse {
            allocator.free(line);
            continue;
        };
        if (params != .object) {
            allocator.free(line);
            continue;
        }
        const pane_id = params.object.get("pane_id") orelse params.object.get("session_id") orelse params.object.get("client_id") orelse {
            allocator.free(line);
            continue;
        };
        if (pane_id == .string and std.mem.eql(u8, pane_id.string, expected_pane_id)) return line;
        allocator.free(line);
    }
}

fn readPaneOutputContaining(
    allocator: std.mem.Allocator,
    fd: *Connection,
    pane_id: []const u8,
    needle: []const u8,
    timeout_ms: i64,
) ![]u8 {
    const deadline = nowMs() + timeout_ms;
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(allocator);
    while (true) {
        const now = nowMs();
        if (now >= deadline) return error.PaneOutputTimeout;
        const line = try readNotificationLine(allocator, fd, "pane_output", pane_id, deadline - now);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse return error.MissingParams;
        const encoded = try expectStringField(params, "data_base64");
        const decoded = try decodeBase64(allocator, encoded);
        defer allocator.free(decoded);
        try tail.appendSlice(allocator, decoded);
        if (std.mem.indexOf(u8, tail.items, needle) != null) return tail.toOwnedSlice(allocator);
        const keep = @min(tail.items.len, needle.len -| 1);
        std.mem.copyForwards(u8, tail.items[0..keep], tail.items[tail.items.len - keep ..]);
        tail.shrinkRetainingCapacity(keep);
    }
}

fn expectTermExited(term: std.process.Child.Term, expected_code: u8) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(expected_code, code),
        else => return error.UnexpectedChildTerm,
    }
}

test "built CLI binaries handle version help and unknown flags" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const binaries = [_]struct {
        path: []const u8,
        name: []const u8,
    }{
        .{ .path = build_options.zmuxd_path, .name = "zmuxd" },
        .{ .path = build_options.smithers_session_daemon_path, .name = "smithers-session-daemon" },
        .{ .path = build_options.zmux_connect_path, .name = "zmux-connect" },
        .{ .path = build_options.smithers_session_connect_path, .name = "smithers-session-connect" },
    };

    for (binaries) |binary| {
        {
            const result = try std.process.run(allocator, io, .{
                .argv = &.{ binary.path, "--version" },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try expectTermExited(result.term, 0);
            _ = binary.name;
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "zmux") != null);
        }
        {
            const result = try std.process.run(allocator, io, .{
                .argv = &.{ binary.path, "--help" },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try expectTermExited(result.term, 0);
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
        }
        {
            const result = try std.process.run(allocator, io, .{
                .argv = &.{ binary.path, "--definitely-not-a-zmux-flag" },
                .stdout_limit = .limited(4096),
                .stderr_limit = .limited(4096),
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            switch (result.term) {
                .exited => |code| try std.testing.expect(code != 0),
                else => return error.UnexpectedChildTerm,
            }
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Usage") != null or
                std.mem.indexOf(u8, result.stderr, "Try") != null);
        }
    }
}

test "daemon restart over a stale socket file binds and serves" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    const pid_path = try std.fmt.allocPrint(allocator, "{s}.pid", .{socket_path});
    defer allocator.free(pid_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, pid_path) catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmuxd_path, "--socket", socket_path, "--idle-seconds", "0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var child_running = true;
    errdefer if (child_running) child.kill(io);

    try waitForSocket(socket_path, 2_000);
    if (std.c.kill(child.id.?, .KILL) != 0) return error.KillFailed;
    _ = try child.wait(io);
    child_running = false;
    try std.Io.Dir.accessAbsolute(io, socket_path, .{});

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":1,\"method\":\"daemon.ping\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":2,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "daemon JSON-RPC errors are framed and the connection remains usable" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});

    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var client = try connectClient(socket_path);
    defer client.close();

    {
        try writeAll(client.fd, "not-json\n");
        const line = try readRpcResponseWithAnyId(allocator, &client, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32700);
    }

    {
        try writeAll(client.fd, "{\"id\":2,\"method\":\"missing.method\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 2, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32601);
    }

    {
        try writeAll(client.fd, "{\"id\":3,\"method\":\"session.info\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 3, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32602);
    }

    {
        try writeAll(client.fd, "{\"id\":4,\"method\":\"client.detach\",\"params\":{\"clientId\":\"client-missing\"}}\n");
        const line = try readRpcResponseLine(allocator, &client, 4, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32000);
    }

    {
        try writeAll(client.fd, "{\"id\":{\"trace\":[1,2]},\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readRpcResponseWithAnyId(allocator, &client, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32600);
    }

    {
        const oversized = try allocator.alloc(u8, 1024 * 1024 + 2);
        defer allocator.free(oversized);
        @memset(oversized[0 .. oversized.len - 1], 'x');
        oversized[oversized.len - 1] = '\n';

        var overflow = try connectClient(socket_path);
        defer overflow.close();
        writeAll(overflow.fd, oversized) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => {},
            else => return err,
        };
        const line = try readRpcResponseWithAnyId(allocator, &overflow, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32600);
        try std.testing.expectError(error.EndOfStream, readLineAllocTimeout(allocator, &overflow, 64 * 1024, 2_000));
    }

    {
        try writeAll(client.fd, "{\"id\":5,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 5, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val.object.get("version") != null);
    }

    {
        try writeAll(client.fd, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 6, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    thread.join();
    server.deinit();
    server_stopped = true;

    try std.testing.expect(ctx.run_error == null);
}

test "natural child exit is reaped and broadcasts session_exited" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var observer = try connectClient(socket_path);
    defer observer.close();

    var pane_id: []u8 = &.{};
    defer if (pane_id.len > 0) allocator.free(pane_id);
    var child_pid: posix.pid_t = 0;
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"exit 7\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
        child_pid = @intCast(expectIntegerField(result_val, "pid") catch try panePidFromSnapshot(allocator, socket_path, pane_id));
    }

    try waitForSessionExited(allocator, &observer, pane_id, 7, 4_000);
    try waitForProcessGone(child_pid, 1_000);

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"session.info\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const exit_status = result_val.object.get("exitStatus") orelse return error.MissingExitStatus;
        try std.testing.expect(exit_status == .integer);
        try std.testing.expectEqual(@as(i64, 7), exit_status.integer);
    }
    try expectPaneAlert(allocator, socket_path, pane_id, "exited", true);

    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":3,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "PTY master fd does not leak into subsequently spawned pane child" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var padding = std.ArrayList(posix.fd_t).empty;
    defer {
        for (padding.items) |fd| sys.close(fd);
        padding.deinit(allocator);
    }
    for (0..32) |_| {
        const fd = try sys.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        errdefer sys.close(fd);
        try padding.append(allocator, fd);
    }

    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var first_id: []u8 = &.{};
    defer if (first_id.len > 0) allocator.free(first_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        first_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
    }

    const master_fd = try firstPaneMasterFd(&server);
    for (padding.items) |fd| sys.close(fd);
    padding.clearRetainingCapacity();
    try std.testing.expect(master_fd > 16);

    var second_id: []u8 = &.{};
    defer if (second_id.len > 0) allocator.free(second_id);
    {
        const command = try std.fmt.allocPrint(
            allocator,
            "if [ -e /dev/fd/{} ]; then echo ZMUX_FD_LEAK_{}; else echo ZMUX_FD_ABSENT; fi",
            .{ master_fd, master_fd },
        );
        defer allocator.free(command);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"session.create\",\"params\":{{\"shell\":\"/bin/sh\",\"command\":{f},\"rows\":24,\"cols\":80}}}}\n",
            .{std.json.fmt(command, .{})},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        second_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
    }

    const captured = try waitForCaptureContains(allocator, socket_path, second_id, "ZMUX_FD_", 4_000);
    defer allocator.free(captured);
    try std.testing.expect(std.mem.indexOf(u8, captured, "ZMUX_FD_ABSENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "ZMUX_FD_LEAK") == null);

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{first_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":4,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "server shutdown waits for an idle client handler to exit" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var idle = try connectClient(socket_path);
    defer idle.close();
    try waitForActiveConnections(&server, 1);

    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":1,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    try std.testing.expectEqual(@as(usize, 0), server.active_connections.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), server.active_writer_threads.load(.seq_cst));
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "shutdown probe stops the server and deinit terminates live sessions" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    test_shutdown_requested.store(false, .seq_cst);
    defer test_shutdown_requested.store(false, .seq_cst);

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    server.shutdown_probe = testShutdownProbe;
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_deinited = false;
    errdefer {
        if (!server_deinited) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var pane_id: []u8 = &.{};
    defer if (pane_id.len > 0) allocator.free(pane_id);
    var child_pid: posix.pid_t = 0;
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
        child_pid = @intCast(expectIntegerField(result_val, "pid") catch try panePidFromSnapshot(allocator, socket_path, pane_id));
    }
    {
        var client = try connectClient(socket_path);
        defer client.close();
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);
        const line = try readRpcResponseLine(allocator, &client, 2, 1024 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);

        test_shutdown_requested.store(true, .seq_cst);
        try waitForRunDone(&ctx, 2_000);
    }

    thread.join();
    server.deinit();
    server_deinited = true;
    try waitForProcessGone(child_pid, 1_000);
    try std.testing.expect(ctx.run_error == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, socket_path, .{}));
}

test "daemon.shutdown with live attached sessions terminates cleanly" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var pane_id: []u8 = &.{};
    defer if (pane_id.len > 0) allocator.free(pane_id);
    var child_pid: posix.pid_t = 0;
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
        child_pid = @intCast(expectIntegerField(result_val, "pid") catch try panePidFromSnapshot(allocator, socket_path, pane_id));
    }

    var attached = [_]Connection{ try connectClient(socket_path), try connectClient(socket_path) };
    defer {
        for (&attached) |*fd| fd.close();
    }
    for (&attached, 0..) |*fd, index| {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{},\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{ index + 2, pane_id },
        );
        defer allocator.free(req);
        try writeAll(fd.fd, req);
        const line = try readRpcResponseLine(allocator, fd, @intCast(index + 2), 1024 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":10,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    thread.join();
    try waitForProcessGone(child_pid, 1_000);
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "idle timeout exits with no sessions and unlinks its socket after deinit" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 1);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_deinited = false;
    errdefer {
        if (!server_deinited) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);
    try waitForRunDone(&ctx, 3_000);
    thread.join();
    server.deinit();
    server_deinited = true;
    try std.testing.expect(ctx.run_error == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, socket_path, .{}));
}

test "idle timeout waits for a live session then exits after it is terminated" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 1);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var pane_id: []u8 = &.{};
    defer if (pane_id.len > 0) allocator.free(pane_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
    }

    sleepMs(1_500);
    try std.testing.expect(!ctx.done.load(.seq_cst));
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":2,\"method\":\"daemon.ping\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    try waitForRunDone(&ctx, 3_000);
    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

fn waitForActiveConnections(server: *const server_mod.Server, expected: usize) !void {
    const deadline = nowMs() + 2_000;
    while (server.active_connections.load(.seq_cst) != expected) {
        if (nowMs() >= deadline) return error.ActiveConnectionCountTimeout;
        sleepMs(10);
    }
}

test "server rejects connections above max_client_connections" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    if (std.c.getenv("ZMUX_TEST_FULL_CONNECTION_CAP") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);
    try waitForActiveConnections(&server, 0);

    const max_connections = server_mod.max_client_connections;
    var clients = std.ArrayList(posix.fd_t).empty;
    try clients.ensureTotalCapacity(allocator, max_connections);
    defer {
        for (clients.items) |fd| sys.close(fd);
        clients.deinit(allocator);
    }

    for (0..max_connections) |_| {
        try clients.append(allocator, (try connectClient(socket_path)).fd);
    }
    try waitForActiveConnections(&server, max_connections);

    var overflow_client = try connectClient(socket_path);
    defer overflow_client.close();
    var saw_limit_error = false;
    var overflow_msg: ?[]u8 = null;
    overflow_msg = readLineAllocTimeout(
        allocator,
        &overflow_client,
        64 * 1024,
        1_000,
    ) catch |err| switch (err) {
        error.EndOfStream, error.ReadTimeout => null,
        else => return err,
    };
    if (overflow_msg) |msg| {
        defer allocator.free(msg);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
        defer parsed.deinit();
        try expectErrorKind(parsed.value, "limit");
        saw_limit_error = true;
    }
    try std.testing.expect(saw_limit_error);

    // Free one slot and confirm a new live connection is accepted. The control
    // connection is scoped so it releases its slot before the shutdown request.
    const released = clients.orderedRemove(0);
    sys.close(released);
    try waitForActiveConnections(&server, max_connections - 1);

    {
        var control = try connectClient(socket_path);
        defer control.close();
        try writeAll(control.fd, "{\"id\":99,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const ping_response = try readLineAllocTimeout(allocator, &control, 64 * 1024, 2_000);
        defer allocator.free(ping_response);
        try std.testing.expect(std.mem.indexOf(u8, ping_response, "\"result\"") != null);
    }

    // Release every remaining held client so the shutdown request is not turned
    // away by the connection cap, then let the accept loop drain the closures.
    // Clear the list so the outer defer does not double-close these fds.
    for (clients.items) |fd| sys.close(fd);
    clients.clearRetainingCapacity();
    try waitForActiveConnections(&server, 0);

    {
        var shutdown = try connectClient(socket_path);
        defer shutdown.close();
        try writeAll(shutdown.fd, "{\"id\":100,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const shutdown_response = try readLineAllocTimeout(allocator, &shutdown, 64 * 1024, 2_000);
        defer allocator.free(shutdown_response);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "attached clients receive pane output activity and bell notifications" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var pane_id: []u8 = &.{};
    defer if (pane_id.len > 0) allocator.free(pane_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
    }

    var client_a: ?Connection = try connectClient(socket_path);
    defer if (client_a) |*fd| fd.close();
    var client_b = try connectClient(socket_path);
    defer client_b.close();

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        try writeAll(client_a.?.fd, req);
        const line = try readRpcResponseLine(allocator, &client_a.?, 2, 1024 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        try writeAll(client_b.fd, req);
        const line = try readRpcResponseLine(allocator, &client_b, 3, 1024 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"ZMUX_NOTIFY_ONE\\n\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    const output_a = try readPaneOutputContaining(allocator, &client_a.?, pane_id, "ZMUX_NOTIFY_ONE", 4_000);
    defer allocator.free(output_a);
    const output_b = try readPaneOutputContaining(allocator, &client_b, pane_id, "ZMUX_NOTIFY_ONE", 4_000);
    defer allocator.free(output_b);

    {
        const activity_a = try readNotificationLine(allocator, &client_a.?, "pane_activity", pane_id, 4_000);
        defer allocator.free(activity_a);
        const activity_b = try readNotificationLine(allocator, &client_b, "pane_activity", pane_id, 4_000);
        defer allocator.free(activity_b);
    }

    client_a.?.close();
    client_a = null;

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"dataBase64\":\"Bwo=\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const bell = try readNotificationLine(allocator, &client_b, "pane_bell", pane_id, 4_000);
        defer allocator.free(bell);
    }

    try expectPaneAlert(allocator, socket_path, pane_id, "activity", true);
    try expectPaneAlertTimestampNonZero(allocator, socket_path, pane_id, "lastActivityMs");
    try expectPaneAlert(allocator, socket_path, pane_id, "bell", true);
    try expectPaneAlertTimestampNonZero(allocator, socket_path, pane_id, "lastBellMs");

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":6,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":7,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "native session daemon end-to-end: ping, create, send, capture, terminate, shutdown" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    // idle_timeout=0 means the server never self-exits due to idle; we drive
    // shutdown explicitly via daemon.shutdown.
    var server = try server_mod.Server.init(allocator, io, socket_path, 0);

    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});

    // If anything below fails, make sure we still stop the server so the
    // thread joins before we deinit it.
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    // --- daemon.ping ---
    {
        var client = try connectClient(socket_path);
        defer client.close();

        try writeAll(client.fd, "{\"id\":1,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 1, 64 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        try std.testing.expect(parsed.value == .object);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val == .object);

        const version = result_val.object.get("version") orelse return error.MissingVersion;
        try std.testing.expect(version == .string);
        try std.testing.expect(result_val.object.get("pid") != null);
        try std.testing.expect(result_val.object.get("socketPath") != null);

        const sessions_val = result_val.object.get("sessions") orelse return error.MissingSessions;
        try std.testing.expect(sessions_val == .integer);
        try std.testing.expectEqual(@as(i64, 0), sessions_val.integer);
        const panes_val = result_val.object.get("panes") orelse return error.MissingPanes;
        try std.testing.expect(panes_val == .integer);
        try std.testing.expectEqual(@as(i64, 0), panes_val.integer);
    }

    // --- session.create ---
    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    {
        var client = try connectClient(socket_path);
        defer client.close();

        // Pass a shell + command so pty.spawn builds a login-shell command
        // argv. This exercises RPC wiring plus PTY fd passing.
        try writeAll(
            client.fd,
            "{\"id\":2,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"exec /bin/sh\",\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );

        const line = try readRpcResponseLine(allocator, &client, 2, 64 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |_| {
            std.debug.print("session.create returned error: {s}\n", .{line});
            return error.SessionCreateFailed;
        }
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val == .object);
        const id_val = result_val.object.get("paneId") orelse result_val.object.get("id") orelse return error.MissingSessionId;
        try std.testing.expect(id_val == .string);
        try std.testing.expect(id_val.string.len > 0);
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    // --- session.send "printf 'ZMUX_EXEC_%s\\n' MARK\n" ---
    {
        var client = try connectClient(socket_path);
        defer client.close();

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"printf 'ZMUX_EXEC_%s\\n' MARK\\n\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);

        const line = try readRpcResponseLine(allocator, &client, 3, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    allocator.free(try waitForCaptureContains(allocator, socket_path, session_id_owned, "ZMUX_EXEC_MARK", 4_000));

    // Verify the child-produced marker in captured scrollback.
    {
        var client = try connectClient(socket_path);
        defer client.close();

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":10}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);

        const line = try readRpcResponseLine(allocator, &client, 4, 1024 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const text_val = result_val.object.get("text") orelse return error.MissingText;
        try std.testing.expect(text_val == .string);
        try std.testing.expect(std.mem.indexOf(u8, text_val.string, "ZMUX_EXEC_MARK") != null);
    }

    // --- session.terminate ---
    {
        var client = try connectClient(socket_path);
        defer client.close();

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);

        const line = try readRpcResponseLine(allocator, &client, 5, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    // --- daemon.shutdown: the server's run loop should exit. ---
    {
        var client = try connectClient(socket_path);
        defer client.close();

        try writeAll(client.fd, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 6, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    thread.join();
    server.deinit();
    server_stopped = true;

    try std.testing.expect(ctx.run_error == null);
}

// Regression: reopening an app terminal used to drop the prior terminal state;
// Claude Code could appear as a fresh chat instead of showing the previous
// conversation. The daemon owns scrollback, and logical client attachment must
// replay it so thin app clients can redraw prior state.
test "client.attach replays scrollback on reattach so reopened sessions keep their state" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    // Create a long-lived session that emits a known sentinel and then
    // stays alive so the PTY doesn't close before we reattach. `cat`
    // (with no args) blocks on stdin forever after the echo, giving us a
    // stable target for reattach.
    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    {
        var client = try connectClient(socket_path);
        defer client.close();
        try writeAll(
            client.fd,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"echo REOPEN_SENTINEL_ONE; cat\"," ++
                "\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );
        const line = try readRpcResponseLine(allocator, &client, 1, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("paneId") orelse result_val.object.get("id") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    // Give the child a moment to emit the sentinel into the scrollback.
    allocator.free(try waitForCaptureContains(allocator, socket_path, session_id_owned, "REOPEN_SENTINEL_ONE", 4_000));

    // First logical attach: the replay should already contain the initial sentinel.
    {
        var client = try connectClient(socket_path);
        defer client.close();
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client.fd, attach_req);

        const line = try readRpcResponseLine(allocator, &client, 2, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse
            return error.MissingReplayField;
        try std.testing.expect(replay_val == .string);
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_ONE") != null);
    }

    // With the logical client connection closed, write more output to the PTY
    // so scrollback keeps growing while the UI is gone.
    {
        var client = try connectClient(socket_path);
        defer client.close();
        const send_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":" ++
                "{{\"sessionId\":\"{s}\",\"text\":\"REOPEN_SENTINEL_TWO\\n\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(send_req);
        try writeAll(client.fd, send_req);
        const line = try readRpcResponseLine(allocator, &client, 3, 64 * 1024);
        defer allocator.free(line);
    }

    // Let `cat` echo the input back to the PTY so the daemon captures it.
    allocator.free(try waitForCaptureContains(allocator, socket_path, session_id_owned, "REOPEN_SENTINEL_TWO", 4_000));

    // Second attach: the replay must now carry BOTH sentinels.
    {
        var client = try connectClient(socket_path);
        defer client.close();
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client.fd, attach_req);

        const line = try readRpcResponseLine(allocator, &client, 4, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse
            return error.MissingReplayField;
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_ONE") != null);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "REOPEN_SENTINEL_TWO") != null);
    }

    // Clean up: terminate the session and shut the server down.
    {
        var client = try connectClient(socket_path);
        defer client.close();
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);
        const line = try readRpcResponseLine(allocator, &client, 5, 64 * 1024);
        defer allocator.free(line);
    }
    {
        var client = try connectClient(socket_path);
        defer client.close();
        try writeAll(client.fd, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 6, 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "client.attach replay is capped to the newest 256 KiB tail" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    const sentinel = "ZMUX_REPLAY_TAIL";
    var pane_id: []u8 = &.{};
    defer if (pane_id.len > 0) allocator.free(pane_id);
    {
        const command =
            "head -c 330000 /dev/zero | tr '\\000' A; " ++
            "printf ZMUX_REPLAY_TAIL; cat";
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":1,\"method\":\"session.create\",\"params\":{{\"shell\":\"/bin/sh\",\"command\":{f},\"rows\":24,\"cols\":80}}}}\n",
            .{std.json.fmt(command, .{})},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
    }

    const replay_cap = 256 * 1024;
    var decoded: []u8 = &.{};
    var saw_replay = false;
    const deadline = nowMs() + 5_000;
    var rpc_id: i64 = 20;
    while (nowMs() < deadline) : (rpc_id += 1) {
        const replay = try attachReplay(allocator, socket_path, pane_id, rpc_id);
        if (std.mem.endsWith(u8, replay, sentinel)) {
            decoded = replay;
            saw_replay = true;
            break;
        }
        allocator.free(replay);
        sleepMs(50);
    }
    if (!saw_replay) return error.ReplayTailTimeout;
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, replay_cap), decoded.len);
    try std.testing.expect(std.mem.endsWith(u8, decoded, sentinel));
    for (decoded[0 .. decoded.len - sentinel.len]) |byte| {
        try std.testing.expectEqual(@as(u8, 'A'), byte);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":3,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "logical client auto-detaches when connection closes so a reopened tab can reattach" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    {
        var client = try connectClient(socket_path);
        defer client.close();
        try writeAll(
            client.fd,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"echo AUTO_DETACH_SENTINEL; cat\"," ++
                "\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );
        const line = try readRpcResponseLine(allocator, &client, 1, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("paneId") orelse result_val.object.get("id") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    allocator.free(try waitForCaptureContains(allocator, socket_path, session_id_owned, "AUTO_DETACH_SENTINEL", 4_000));

    {
        var client = try connectClient(socket_path);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client.fd, attach_req);

        const line = try readRpcResponseLine(allocator, &client, 2, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);

        // Simulate app/process death without an explicit client.detach RPC.
        client.close();
    }

    try waitForClientCount(allocator, socket_path, 0, 2_000);

    {
        var client = try connectClient(socket_path);
        defer client.close();
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client.fd, attach_req);

        const line = try readRpcResponseLine(allocator, &client, 3, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const replay_val = result_val.object.get("replayBase64") orelse return error.MissingReplayField;
        const decoded = try decodeBase64(allocator, replay_val.string);
        defer allocator.free(decoded);
        try std.testing.expect(std.mem.indexOf(u8, decoded, "AUTO_DETACH_SENTINEL") != null);
    }

    {
        var client = try connectClient(socket_path);
        defer client.close();
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);
        const line = try readRpcResponseLine(allocator, &client, 4, 64 * 1024);
        defer allocator.free(line);
    }
    {
        var client = try connectClient(socket_path);
        defer client.close();
        try writeAll(client.fd, "{\"id\":5,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, &client, 5, 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "session RPCs resolve session names and returned session ids, and attach resizes the PTY" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"id\":\"work\",\"shell\":\"/bin/sh\",\"command\":\"exec /bin/sh\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
    }

    var returned_session_id: []u8 = &.{};
    defer if (returned_session_id.len > 0) allocator.free(returned_session_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":2,\"method\":\"client.attach\",\"params\":{\"paneId\":\"work\",\"rows\":40,\"cols\":120}}\n",
            1024 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const session_id_val = result_val.object.get("sessionId") orelse return error.MissingSessionId;
        returned_session_id = try allocator.dupe(u8, session_id_val.string);
        const rows_val = result_val.object.get("rows") orelse return error.MissingRows;
        const cols_val = result_val.object.get("cols") orelse return error.MissingCols;
        try std.testing.expectEqual(@as(i64, 40), rows_val.integer);
        try std.testing.expectEqual(@as(i64, 120), cols_val.integer);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"work\",\"text\":\"printf 'NAME_SEND_OK\\\\n'; stty size\\n\"}}}}\n",
            .{},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
    }

    allocator.free(try waitForCaptureContains(allocator, socket_path, returned_session_id, "40 120", 4_000));

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":20}}}}\n",
            .{returned_session_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const text_val = result_val.object.get("text") orelse return error.MissingText;
        try std.testing.expect(std.mem.indexOf(u8, text_val.string, "NAME_SEND_OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, text_val.string, "40 120") != null);
    }

    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":45,\"method\":\"session.send\",\"params\":{\"sessionId\":\"work\",\"dataBase64\":\"!!!\"}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32602);
    }

    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":46,\"method\":\"daemon.ping\",\"params\":{}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":47,\"method\":\"session.resize\",\"params\":{\"sessionId\":\"work\",\"rows\":50,\"cols\":120}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":48,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"work\",\"text\":\"stty size\\n\"}}}}\n",
            .{},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
        const captured = try waitForCaptureContains(allocator, socket_path, returned_session_id, "50 120", 4_000);
        defer allocator.free(captured);
    }

    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":49,\"method\":\"session.resize\",\"params\":{\"sessionId\":\"work\",\"rows\":\"tall\",\"cols\":-1}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32602);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":50,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"work\",\"text\":\"stty size | sed 's/^/LAST /'\\n\"}}}}\n",
            .{},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
        const captured = try waitForCaptureContains(allocator, socket_path, returned_session_id, "LAST 50 120", 4_000);
        defer allocator.free(captured);
    }

    var exited_pane_id: []u8 = &.{};
    defer if (exited_pane_id.len > 0) allocator.free(exited_pane_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":51,\"method\":\"session.create\",\"params\":{\"shell\":\"/bin/sh\",\"command\":\"true\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        exited_pane_id = try allocator.dupe(u8, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
    }
    {
        const deadline = nowMs() + 4_000;
        while (true) {
            if (nowMs() >= deadline) return error.TerminatedPaneTimeout;
            const req = try std.fmt.allocPrint(
                allocator,
                "{{\"id\":52,\"method\":\"session.info\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
                .{exited_pane_id},
            );
            defer allocator.free(req);
            const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
            defer allocator.free(line);
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
            defer parsed.deinit();
            const result_val = try responseResult(parsed.value);
            const state = try expectStringField(result_val, "state");
            if (std.mem.eql(u8, state, "terminated")) break;
            sleepMs(20);
        }
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":53,\"method\":\"session.resize\",\"params\":{{\"sessionId\":\"{s}\",\"rows\":60,\"cols\":140}}}}\n",
            .{exited_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32000);
    }

    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":5,\"method\":\"session.terminate\",\"params\":{\"sessionId\":\"work\"}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        try std.testing.expect(parsed.value.object.get("result") != null);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "mux model API owns windows panes clients key bindings and respawn state" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});
    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    var first_pane_id: []u8 = &.{};
    defer if (first_pane_id.len > 0) allocator.free(first_pane_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"cat\",\"title\":\"root\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("paneId") orelse result_val.object.get("id") orelse return error.MissingSessionId;
        first_pane_id = try allocator.dupe(u8, id_val.string);
    }

    var session_id: []u8 = &.{};
    defer if (session_id.len > 0) allocator.free(session_id);
    var window_id: []u8 = &.{};
    defer if (window_id.len > 0) allocator.free(window_id);
    var second_window_id: []u8 = &.{};
    defer if (second_window_id.len > 0) allocator.free(second_window_id);
    var split_pane_id: []u8 = &.{};
    defer if (split_pane_id.len > 0) allocator.free(split_pane_id);
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":2,\"method\":\"mux.snapshot\",\"params\":{}}\n", 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        try std.testing.expectEqual(@as(usize, 1), sessions.array.items.len);
        const session = sessions.array.items[0];
        session_id = try allocator.dupe(u8, (session.object.get("id") orelse return error.MissingSessionId).string);
        const windows = session.object.get("windows") orelse return error.MissingWindows;
        try std.testing.expectEqual(@as(usize, 1), windows.array.items.len);
        const window = windows.array.items[0];
        window_id = try allocator.dupe(u8, (window.object.get("id") orelse return error.MissingWindowId).string);
        const panes = window.object.get("panes") orelse return error.MissingPanes;
        try std.testing.expectEqual(@as(usize, 1), panes.array.items.len);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"window.new\",\"params\":{{\"sessionId\":\"{s}\",\"title\":\"second\",\"shell\":\"/bin/sh\",\"command\":\"cat\"}}}}\n",
            .{session_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        _ = try responseResult(parsed.value);
        const snapshot = try rpcLine(allocator, socket_path, "{\"id\":33,\"method\":\"mux.snapshot\"}\n", max_reply);
        defer allocator.free(snapshot);
        const snapshot_parsed = try std.json.parseFromSlice(std.json.Value, allocator, snapshot, .{});
        defer snapshot_parsed.deinit();
        const result_val = try responseResult(snapshot_parsed.value);
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        const windows = sessions.array.items[0].object.get("windows") orelse return error.MissingWindows;
        for (windows.array.items) |window| {
            const name = window.object.get("name") orelse continue;
            if (name == .string and std.mem.eql(u8, name.string, "second")) {
                second_window_id = try allocator.dupe(u8, try expectStringField(window, "id"));
                break;
            }
        }
        if (second_window_id.len == 0) return error.MissingWindowId;
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"pane.split\",\"params\":{{\"paneId\":\"{s}\",\"axis\":\"horizontal\",\"shell\":\"/bin/sh\",\"command\":\"cat\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        _ = try responseResult(parsed.value);
        const snapshot = try rpcLine(allocator, socket_path, "{\"id\":33,\"method\":\"mux.snapshot\"}\n", max_reply);
        defer allocator.free(snapshot);
        const snapshot_parsed = try std.json.parseFromSlice(std.json.Value, allocator, snapshot, .{});
        defer snapshot_parsed.deinit();
        const result_val = try responseResult(snapshot_parsed.value);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"axis\":\"horizontal\"") != null);
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        const windows = sessions.array.items[0].object.get("windows") orelse return error.MissingWindows;
        for (windows.array.items) |window| {
            const panes = window.object.get("panes") orelse continue;
            if (panes != .array) continue;
            for (panes.array.items) |pane| {
                const id = try expectStringField(pane, "id");
                if (!std.mem.eql(u8, id, first_pane_id)) {
                    split_pane_id = try allocator.dupe(u8, id);
                    break;
                }
            }
            if (split_pane_id.len > 0) break;
        }
        if (split_pane_id.len == 0) return error.MissingPaneId;
    }

    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":41,\"method\":\"daemon.ping\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const sessions_val = result_val.object.get("sessions") orelse return error.MissingSessions;
        const panes_val = result_val.object.get("panes") orelse return error.MissingPanes;
        try std.testing.expectEqual(@as(i64, 1), sessions_val.integer);
        try std.testing.expectEqual(@as(i64, 3), panes_val.integer);
    }

    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":42,\"method\":\"session.list\",\"params\":{}}\n", 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        try std.testing.expect(result_val == .array);
        try std.testing.expect(result_val.array.items.len >= 3);
        const first = result_val.array.items[0];
        _ = try expectStringField(first, "sessionId");
        _ = try expectStringField(first, "windowId");
        _ = try expectStringField(first, "paneId");
        _ = try expectStringField(first, "state");
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":43,\"method\":\"session.info\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        try std.testing.expectEqualStrings(first_pane_id, expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id"));
        try std.testing.expectEqualStrings("running", try expectStringField(result_val, "state"));
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":44,\"method\":\"window.select\",\"params\":{{\"windowId\":\"{s}\"}}}}\n",
            .{second_window_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        try std.testing.expectEqualStrings(second_window_id, try expectStringField(sessions.array.items[0], "activeWindowId"));
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":45,\"method\":\"pane.select\",\"params\":{{\"paneId\":\"{s}\"}}}}\n",
            .{split_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        const session = sessions.array.items[0];
        try std.testing.expectEqualStrings(window_id, try expectStringField(session, "activeWindowId"));
        const windows = session.object.get("windows") orelse return error.MissingWindows;
        var saw_active_pane = false;
        for (windows.array.items) |window| {
            const id = try expectStringField(window, "id");
            if (std.mem.eql(u8, id, window_id)) {
                try std.testing.expectEqualStrings(split_pane_id, try expectStringField(window, "activePaneId"));
                saw_active_pane = true;
            }
        }
        try std.testing.expect(saw_active_pane);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":46,\"method\":\"pane.select\",\"params\":{{\"paneId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }

    var client_one: []u8 = &.{};
    defer if (client_one.len > 0) allocator.free(client_one);
    var client_one_fd: ?Connection = null;
    defer if (client_one_fd) |*fd| fd.close();
    var client_two_fd: ?Connection = null;
    defer if (client_two_fd) |*fd| fd.close();
    {
        var client = try connectClient(socket_path);
        errdefer client.close();
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":30,\"cols\":100}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);
        const line = try readRpcResponseLine(allocator, &client, 5, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        client_one = try allocator.dupe(u8, (result_val.object.get("clientId") orelse return error.MissingClientId).string);
        client_one_fd = client;
    }

    {
        var client = try connectClient(socket_path);
        errdefer client.close();
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":6,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        try writeAll(client.fd, req);
        const line = try readRpcResponseLine(allocator, &client, 6, 64 * 1024);
        defer allocator.free(line);
        client_two_fd = client;
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":7,\"method\":\"client.list\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expectEqual(@as(usize, 2), result_val.array.items.len);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":71,\"method\":\"client.switch\",\"params\":{{\"clientId\":\"{s}\",\"paneId\":\"{s}\"}}}}\n",
            .{ client_one, split_pane_id },
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":72,\"method\":\"client.list\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        var saw_switched = false;
        for (result_val.array.items) |client| {
            const id = try expectStringField(client, "id");
            if (std.mem.eql(u8, id, client_one)) {
                try std.testing.expectEqualStrings(split_pane_id, try expectStringField(client, "paneId"));
                saw_switched = true;
            }
        }
        try std.testing.expect(saw_switched);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":73,\"method\":\"session.sendKey\",\"params\":{{\"sessionId\":\"{s}\",\"key\":\"Enter\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":74,\"method\":\"session.sendKey\",\"params\":{{\"sessionId\":\"{s}\",\"key\":\"Bogus\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32602);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":8,\"method\":\"key.bind\",\"params\":{{\"table\":\"prefix\",\"key\":\"%\",\"command\":\"split-window -h\"}}}}\n",
            .{},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "split-window -h") != null);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":75,\"method\":\"key.list\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        try std.testing.expect(result_val == .array);
        try std.testing.expect(result_val.array.items.len >= 1);
        try std.testing.expectEqualStrings("%", try expectStringField(result_val.array.items[0], "key"));
        try std.testing.expectEqualStrings("split-window -h", try expectStringField(result_val.array.items[0], "command"));
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":9,\"method\":\"key.dispatch\",\"params\":{{\"table\":\"prefix\",\"key\":\"%\",\"paneId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"keyBindings\"") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":10,\"method\":\"pane.rename\",\"params\":{{\"paneId\":\"{s}\",\"title\":\"renamed-pane\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "renamed-pane") != null);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":11,\"method\":\"window.rename\",\"params\":{{\"windowId\":\"{s}\",\"name\":\"renamed-window\"}}}}\n",
            .{window_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "renamed-window") != null);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":12,\"method\":\"session.rename\",\"params\":{{\"sessionId\":\"{s}\",\"name\":\"renamed-session\"}}}}\n",
            .{session_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "renamed-session") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":76,\"method\":\"command.exec\",\"params\":{{\"paneId\":\"{s}\",\"command\":\"new-window -n exec-window cat\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        const sessions = result_val.object.get("sessions") orelse return error.MissingSessions;
        const windows = sessions.array.items[0].object.get("windows") orelse return error.MissingWindows;
        var saw_exec_window = false;
        for (windows.array.items) |window| {
            const name = try expectStringField(window, "name");
            if (std.mem.eql(u8, name, "exec-window")) saw_exec_window = true;
        }
        try std.testing.expect(saw_exec_window);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":77,\"method\":\"command.exec\",\"params\":{{\"paneId\":\"{s}\",\"command\":\"frobnicate\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32602);
    }

    const old_respawn_pid = try panePidFromSnapshot(allocator, socket_path, first_pane_id);
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":78,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"dataBase64\":\"BA==\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
    }
    try waitForSessionExited(allocator, &client_two_fd.?, first_pane_id, 0, 4_000);
    try expectPaneAlert(allocator, socket_path, first_pane_id, "exited", true);

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":13,\"method\":\"pane.respawn\",\"params\":{{\"paneId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = try responseResult(parsed.value);
        const pane = findPaneInSnapshot(result_val, first_pane_id) orelse return error.MissingPane;
        try std.testing.expectEqualStrings(first_pane_id, try expectStringField(pane, "id"));
        try std.testing.expectEqualStrings("running", try expectStringField(pane, "state"));
        const new_pid = try expectIntegerField(pane, "pid");
        try std.testing.expect(new_pid != old_respawn_pid);
        const alerts = pane.object.get("alerts") orelse return error.MissingAlerts;
        try std.testing.expect(!try expectBoolField(alerts, "exited"));
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":79,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"RESPAWN_OK\\n\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
        const captured = try waitForCaptureContains(allocator, socket_path, first_pane_id, "RESPAWN_OK", 4_000);
        defer allocator.free(captured);
    }
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":80,\"method\":\"pane.respawn\",\"params\":{\"paneId\":\"pane-missing\"}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") != null);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":14,\"method\":\"client.detach\",\"params\":{{\"clientId\":\"{s}\"}}}}\n",
            .{client_one},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"ok\":true") != null);
        if (client_one_fd) |*fd| {
            fd.close();
            client_one_fd = null;
        }
        if (client_two_fd) |*fd| {
            fd.close();
            client_two_fd = null;
        }
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":15,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":16,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

// Regression: the README quickstart promises `zmux-connect work` "open or
// create a session named 'work'", but the underlying RPC could not honor it
// — `session.create` ignored the user-supplied `id`, and `client.attach`
// only looked up panes by their auto-generated id. This test pins the
// fix: `session.create { id: "work" }` names the session "work", and
// `client.attach { paneId: "work" }` resolves through the session name to
// its active pane.
test "session.create honors id and client.attach resolves session names" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var server = try server_mod.Server.init(allocator, io, socket_path, 0);
    var ctx = RunServerCtx{ .server = &server };
    const thread = try std.Thread.spawn(.{}, RunServerCtx.run, .{&ctx});

    var server_stopped = false;
    errdefer {
        if (!server_stopped) {
            server.running.store(false, .seq_cst);
            thread.join();
            server.deinit();
        }
    }

    try waitForSocket(socket_path, 2_000);

    // session.create with id="work" — the session's title (and therefore
    // its lookup name) must be set from `id` when no explicit title is
    // given.
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"id\":\"work\",\"shell\":\"/bin/sh\",\"command\":\"exec /bin/sh\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        _ = expectStringField(result_val, "paneId") catch try expectStringField(result_val, "id");
    }

    // client.attach with paneId="work" — the daemon must resolve the
    // session name to the session's active pane and return a client.
    var session_id_owned: []u8 = &.{};
    defer if (session_id_owned.len > 0) allocator.free(session_id_owned);
    var pane_id_owned: []u8 = &.{};
    defer if (pane_id_owned.len > 0) allocator.free(pane_id_owned);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":2,\"method\":\"client.attach\",\"params\":" ++
                "{\"paneId\":\"work\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val.object.get("clientId") != null);
        const session_id_val = result_val.object.get("sessionId") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, session_id_val.string);
        // The attach response carries the canonical pane id back to the
        // client so it can route subsequent input through it. Without this
        // round-trip, a client that only knows the human-readable name
        // would have to guess at the pane id for every keystroke.
        const pane_id_val = result_val.object.get("paneId") orelse return error.MissingPaneId;
        pane_id_owned = try allocator.dupe(u8, pane_id_val.string);
    }

    // Regression: keystrokes from `zmux-connect` flow through `session.send`,
    // which the daemon resolves via `Manager.find` (pane-id only). After
    // `client.attach` the client must use the returned `paneId`, not the
    // user-supplied session name, or every keystroke gets rejected with
    // `session not found` — the symptom that broke typing in the first
    // version of the create-or-attach flow.
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"PROBE\"}}}}\n",
            .{pane_id_owned},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const ok = result_val.object.get("ok") orelse return error.MissingOk;
        try std.testing.expect(ok == .bool and ok.bool);
    }

    // Cleanup: terminate the session and shut down the daemon.
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const line = try rpcLine(allocator, socket_path, "{\"id\":5,\"method\":\"daemon.shutdown\",\"params\":{}}\n", 64 * 1024);
        defer allocator.free(line);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

const max_reply = 16 * 1024 * 1024;
const test_allocator = std.testing.allocator;

const TestDir = struct {
    path: []u8,
    socket: []u8,

    fn init() !TestDir {
        const path = try tempSocketPath(test_allocator);
        errdefer test_allocator.free(path);
        try sys.mkdir(path, 0o700);
        errdefer sys.rmdir(path) catch {};
        const socket = try std.fs.path.join(test_allocator, &.{ path, "zmux.sock" });
        return .{ .path = path, .socket = socket };
    }

    fn deinit(self: TestDir) void {
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        test_allocator.free(self.socket);
        test_allocator.free(self.path);
    }
};

fn spawnDaemon(path: []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ build_options.zmuxd_path, "--socket", path, "--idle-seconds", "0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn cleanChild(child: *std.process.Child) void {
    child.id = null;
    inline for (.{ &child.stdin, &child.stdout, &child.stderr }) |file| {
        if (file.*) |handle| handle.close(io);
        file.* = null;
    }
}

fn killChild(child: *std.process.Child) void {
    const pid = child.id orelse return;
    _ = std.c.kill(pid, .KILL);
    while (std.c.waitpid(pid, null, 0) < 0 and posix.errno(@as(c_int, -1)) == .INTR) {}
    cleanChild(child);
}

fn waitChild(child: *std.process.Child, timeout_ms: i64) !std.process.Child.Term {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        var status: c_int = 0;
        const rc = std.c.waitpid(child.id.?, &status, 1); // WNOHANG
        if (rc > 0) {
            cleanChild(child);
            const bits: u32 = @bitCast(status);
            if (posix.W.IFEXITED(bits)) return .{ .exited = posix.W.EXITSTATUS(bits) };
            if (posix.W.IFSIGNALED(bits)) return .{ .signal = posix.W.TERMSIG(bits) };
            return .{ .unknown = bits };
        }
        if (rc < 0 and posix.errno(rc) != .INTR) return error.WaitFailed;
        sleepMs(5);
    }
    killChild(child);
    return error.ChildTimeout;
}

fn rpc(client: *Connection, id: i64, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
    const args = try std.fmt.allocPrint(test_allocator, "{f}\n", .{std.json.fmt(.{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params,
    }, .{})});
    defer test_allocator.free(args);
    try writeAll(client.fd, args);
    const line = try readRpcResponseLine(test_allocator, client, id, max_reply);
    defer test_allocator.free(line);
    return std.json.parseFromSlice(std.json.Value, test_allocator, line, .{ .allocate = .alloc_always });
}

fn rpcOk(client: *Connection, id: i64, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
    const parsed = try rpc(client, id, method, params);
    errdefer parsed.deinit();
    _ = try responseResult(parsed.value);
    return parsed;
}

fn expectErrorKind(value: std.json.Value, kind: []const u8) !void {
    const err = value.object.get("error") orelse return error.MissingError;
    const data = err.object.get("data") orelse return error.MissingErrorData;
    try std.testing.expectEqualStrings(kind, try expectStringField(data, "kind"));
}

fn endDaemon(child: *std.process.Child, path: []const u8) !void {
    var client = try connectClient(path);
    defer client.close();
    (try rpcOk(&client, 99, "daemon.shutdown", .{})).deinit();
    try expectTermExited(try waitChild(child, 4_000), 0);
}

test "real_zmuxd_creates_private_dir_0700" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var env = std.process.Environ.Map.init(test_allocator);
    defer env.deinit();
    try env.put("HOME", dir.path);

    var daemon = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmuxd_path, "--idle-seconds", "0" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killChild(&daemon);
    const parent = try std.fs.path.join(test_allocator, &.{ dir.path, ".smithers" });
    defer test_allocator.free(parent);
    const path = try std.fs.path.join(test_allocator, &.{ parent, "sessions.sock" });
    defer test_allocator.free(path);
    try waitForSocket(path, 4_000);
    const st = try sys.statAt(sys.cwd_fd, parent, false);
    try std.testing.expectEqual(@as(u32, 0o700), st.permissions());
    try std.testing.expectEqual(sys.geteuid(), st.uid);
    try endDaemon(&daemon, path);
}

test "foreign_tmp_fallback_refused" {
    if (builtin.os.tag != .linux or sys.geteuid() != 0) return error.SkipZigTest;
    // Copy `zmuxd` into a world-traversable `/tmp` directory so UID 65534 can
    // exec it even when the build cache lives under a private `$HOME`/`$RUNNER_TEMP`.
    const bin_dir = try TestDir.init();
    defer bin_dir.deinit();
    const bin_dir_z = try test_allocator.dupeSentinel(u8, bin_dir.path, 0);
    defer test_allocator.free(bin_dir_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(bin_dir_z.ptr, 0o755));
    const zmuxd_copy = try std.fs.path.join(test_allocator, &.{ bin_dir.path, "zmuxd" });
    defer test_allocator.free(zmuxd_copy);
    const zmuxd_copy_z = try test_allocator.dupeSentinel(u8, zmuxd_copy, 0);
    defer test_allocator.free(zmuxd_copy_z);
    const cwd = std.Io.Dir.cwd();
    try cwd.copyFile(build_options.zmuxd_path, cwd, zmuxd_copy, io, .{});
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(zmuxd_copy_z.ptr, 0o755));

    const fallback = "/tmp/zmux-65534";
    sys.mkdir(fallback, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SkipZigTest,
        else => return err,
    };
    defer cwd.deleteTree(io, fallback) catch {};
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(fallback, 0o777));
    var env = std.process.Environ.Map.init(test_allocator);
    defer env.deinit();
    var daemon = try std.process.spawn(io, .{
        .argv = &.{zmuxd_copy},
        .cwd = .{ .path = "/tmp" },
        .environ_map = &env,
        .uid = 65534,
        .gid = 65534,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killChild(&daemon);
    try expectTermExited(try waitChild(&daemon, 4_000), 1);
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, fallback ++ "/sessions.sock", false));
}

test "foreign_owned listener never receives an RPC" {
    if (builtin.os.tag != .linux or sys.geteuid() != 0) return error.SkipZigTest;
    const dir = try TestDir.init();
    defer dir.deinit();
    const dir_z = try test_allocator.dupeSentinel(u8, dir.path, 0);
    defer test_allocator.free(dir_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(dir_z.ptr, 0o777));
    const address = try sys.UnixAddress.init(dir.socket);
    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    const ready = try sys.pipe();
    defer sys.close(ready[0]);
    const pid = try sys.fork();
    if (pid == 0) {
        sys.close(ready[0]);
        if (std.c.setuid(65534) != 0) std.c._exit(10);
        sys.bind(listener, &address) catch std.c._exit(11);
        sys.listen(listener, 1) catch std.c._exit(12);
        sys.writeAll(ready[1], "r") catch std.c._exit(13);
        const fd = sys.accept(listener) catch std.c._exit(14);
        var bytes: [1]u8 = undefined;
        const got = posix.read(fd, &bytes) catch std.c._exit(15);
        std.c._exit(if (got == 0) 0 else 16);
    }
    sys.close(ready[1]);
    var fixture: std.process.Child = .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    defer killChild(&fixture);
    var pollfds = [_]posix.pollfd{.{ .fd = ready[0], .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try posix.poll(&pollfds, 2_000) != 0);
    var ready_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try posix.read(ready[0], &ready_byte));

    var client = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "ls" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killChild(&client);
    try expectTermExited(try waitChild(&client, 3_000), 1);
    try expectTermExited(try waitChild(&fixture, 2_000), 0);
}

test "client resolves relative socket against its working directory" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.zmux_connect_path, test_allocator);
    defer test_allocator.free(binary);
    var client = try std.process.spawn(io, .{
        .argv = &.{ binary, "--socket", "zmux.sock", "ls" },
        .cwd = .{ .path = dir.path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer killChild(&client);
    try expectTermExited(try waitChild(&client, 4_000), 0);
    try endDaemon(&daemon, dir.socket);
}

fn spawnDaemonIn(dir: TestDir, home: ?[]const u8, env: *std.process.Environ.Map) !std.process.Child {
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.zmuxd_path, test_allocator);
    defer test_allocator.free(binary);
    try env.put("PATH", "/usr/bin:/bin");
    if (home) |value| try env.put("HOME", value);
    return std.process.spawn(io, .{
        .argv = &.{ binary, "--socket", dir.socket, "--idle-seconds", "0" },
        .cwd = .{ .path = dir.path },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn expectPaneStartsIn(dir: TestDir, admin: *Connection, id: i64, name: []const u8, expected: []const u8) !void {
    const command = try std.fmt.allocPrint(test_allocator, "pwd -P > '{s}/{s}'", .{ dir.path, name });
    defer test_allocator.free(command);
    (try rpcOk(admin, id, "session.create", .{ .id = name, .shell = "/bin/sh", .command = command })).deinit();
    const line = try std.fmt.allocPrint(test_allocator, "{s}\n", .{expected});
    defer test_allocator.free(line);
    try waitForFile(dir, name, line, 4_000);
    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    const bytes = try directory.readFileAlloc(io, name, test_allocator, .limited(4096));
    defer test_allocator.free(bytes);
    try std.testing.expectEqualStrings(line, bytes);
}

test "daemon_leaves_launcher_cwd: panes start in HOME, else in /" {
    const dir = try TestDir.init();
    defer dir.deinit();

    // No HOME: a pane without `cwd` inherits the daemon's directory, which is
    // `/` and not the directory the daemon was launched from.
    {
        var env = std.process.Environ.Map.init(test_allocator);
        defer env.deinit();
        var daemon = try spawnDaemonIn(dir, null, &env);
        defer killChild(&daemon);
        try waitForSocket(dir.socket, 4_000);
        var admin = try connectClient(dir.socket);
        defer admin.close();
        try expectPaneStartsIn(dir, &admin, 1, "where-root", "/");
        try endDaemon(&daemon, dir.socket);
    }

    // HOME set: that is the default; an explicit `cwd` still wins.
    {
        const home = try std.fs.path.join(test_allocator, &.{ dir.path, "home" });
        defer test_allocator.free(home);
        try sys.mkdir(home, 0o700);
        var env = std.process.Environ.Map.init(test_allocator);
        defer env.deinit();
        var daemon = try spawnDaemonIn(dir, home, &env);
        defer killChild(&daemon);
        try waitForSocket(dir.socket, 4_000);
        var admin = try connectClient(dir.socket);
        defer admin.close();
        try expectPaneStartsIn(dir, &admin, 1, "where-home", home);

        const command = try std.fmt.allocPrint(test_allocator, "pwd -P > '{s}/where-explicit'", .{dir.path});
        defer test_allocator.free(command);
        (try rpcOk(&admin, 2, "session.create", .{ .id = "explicit", .shell = "/bin/sh", .command = command, .cwd = dir.path })).deinit();
        const expected = try std.fmt.allocPrint(test_allocator, "{s}\n", .{dir.path});
        defer test_allocator.free(expected);
        try waitForFile(dir, "where-explicit", expected, 4_000);
        try endDaemon(&daemon, dir.socket);
    }
}

test "connect_created_session_starts_in_client_cwd" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);

    const work = try std.fs.path.join(test_allocator, &.{ dir.path, "work" });
    defer test_allocator.free(work);
    try sys.mkdir(work, 0o700);
    const input = try std.fmt.allocPrint(test_allocator, "pwd -P > '{s}/where-client'; exit 0\n", .{dir.path});
    defer test_allocator.free(input);
    try runClientWithInputIn(dir, "here", input, work);

    const expected = try std.fmt.allocPrint(test_allocator, "{s}\n", .{work});
    defer test_allocator.free(expected);
    try waitForFile(dir, "where-client", expected, 4_000);
    try endDaemon(&daemon, dir.socket);
}

test "relative_socket_no_panic" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.zmuxd_path, test_allocator);
    defer test_allocator.free(binary);
    var daemon = try std.process.spawn(io, .{
        .argv = &.{ binary, "--socket", "zmux.sock", "--idle-seconds", "0" },
        .cwd = .{ .path = dir.path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    try endDaemon(&daemon, dir.socket);
    try std.testing.expectError(error.SocketPathNotAbsolute, server_mod.Server.init(test_allocator, io, "zmux.sock", 0));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: sys.mode_t) c_int;

test "symlinked_log_not_followed, FIFO and non-socket rejected" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const log = try std.fmt.allocPrintSentinel(test_allocator, "{s}.log", .{dir.socket}, 0);
    defer test_allocator.free(log);
    var directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "victim", .data = "keep" });
    try directory.symLink(io, "victim", "zmux.sock.log", .{});

    for (0..3) |fixture| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "work", "--spawn-daemon" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer killChild(&child);
        try expectTermExited(try waitChild(&child, 2_000), 1);
        const bytes = try directory.readFileAlloc(io, "victim", test_allocator, .limited(32));
        defer test_allocator.free(bytes);
        try std.testing.expectEqualStrings("keep", bytes);
        if (fixture < 2) {
            try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, dir.socket, false));
            try directory.deleteFile(io, "zmux.sock.log");
        }
        if (fixture == 0) try std.testing.expectEqual(@as(c_int, 0), mkfifo(log.ptr, 0o600));
        if (fixture == 1) try directory.writeFile(io, .{ .sub_path = "zmux.sock", .data = "ordinary" });
    }
    const bytes = try directory.readFileAlloc(io, "zmux.sock", test_allocator, .limited(32));
    defer test_allocator.free(bytes);
    try std.testing.expectEqualStrings("ordinary", bytes);
}

test "overlong socket path fails before spawning" {
    var path: [201]u8 = @splat('x');
    path[0] = '/';
    var env = std.process.Environ.Map.init(test_allocator);
    defer env.deinit();
    try env.put("ZMUX_SOCKET", "");
    try env.put("SMITHERS_SESSION_SOCKET", &path);
    const expected = try std.fmt.allocPrint(test_allocator, "socket path too long ({d} > {d})", .{ path.len, sys.max_unix_path_len });
    defer test_allocator.free(expected);

    const cases = [_][]const []const u8{
        &.{ build_options.zmux_connect_path, "--socket", &path, "--spawn-daemon", "work" },
        &.{ build_options.zmux_connect_path, "--spawn-daemon", "work" },
    };
    for (cases) |argv| {
        const result = try std.process.run(test_allocator, io, .{
            .argv = argv,
            .environ_map = &env,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer test_allocator.free(result.stdout);
        defer test_allocator.free(result.stderr);
        try expectTermExited(result.term, 2);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected) != null);
    }
}

test "three_concurrent_starters_one_daemon and concurrent_open_or_create_single_session" {
    const dir = try TestDir.init();
    defer dir.deinit();

    var clients: [3]std.process.Child = undefined;
    var started: usize = 0;
    defer for (clients[0..started]) |*client| killChild(client);
    defer {
        const reply = rpcLine(test_allocator, dir.socket, "{\"id\":99,\"method\":\"daemon.shutdown\"}\n", max_reply) catch null;
        if (reply) |line| test_allocator.free(line);
    }
    for (&clients) |*client| {
        client.* = try std.process.spawn(io, .{
            .argv = &.{ build_options.zmux_connect_path, "work", "--socket", dir.socket, "--spawn-daemon", "--command", "cat" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        started += 1;
    }
    for (&clients) |*client| try expectTermExited(try waitChild(client, 8_000), 0);

    var admin = try connectClient(dir.socket);
    defer admin.close();
    const ping = try rpcOk(&admin, 1, "daemon.ping", .{});
    defer ping.deinit();
    try std.testing.expectEqual(@as(i64, 1), try expectIntegerField(try responseResult(ping.value), "sessions"));
    const list = try rpcOk(&admin, 2, "session.list", .{});
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try responseResult(list.value)).array.items.len);
}

test "notification_gets_no_reply, nested_id_rejected_daemon_survives, unterminated_request_not_executed" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var client = try connectClient(dir.socket);
    defer client.close();

    try writeAll(client.fd, "{\"method\":\"daemon.ping\"}\n{\"id\":{\"nested\":[1]},\"method\":\"daemon.ping\"}\n");
    const invalid_line = try client.read(test_allocator, max_reply, nowMs() + 2_000);
    defer test_allocator.free(invalid_line);
    try expectRpcErrorCode(test_allocator, invalid_line, -32600);
    const invalid = try std.json.parseFromSlice(std.json.Value, test_allocator, invalid_line, .{});
    defer invalid.deinit();
    try expectErrorKind(invalid.value, "invalid_request");
    try std.testing.expect(invalid.value.object.get("id").? == .null);

    var partial = try connectClient(dir.socket);
    defer partial.close();
    try writeAll(partial.fd, "{\"id\":3,\"method\":\"daemon.shutdown\"}");
    _ = std.c.shutdown(partial.fd, 1);
    try std.testing.expectError(error.EndOfStream, partial.read(test_allocator, max_reply, nowMs() + 2_000));
    (try rpcOk(&client, 4, "daemon.ping", .{})).deinit();
    try endDaemon(&daemon, dir.socket);
}

fn runClientWithInput(dir: TestDir, name: []const u8, input: []const u8) !void {
    return runClientWithInputIn(dir, name, input, null);
}

/// `cwd`: the client's working directory; null keeps the test runner's.
fn runClientWithInputIn(dir: TestDir, name: []const u8, input: []const u8, cwd: ?[]const u8) !void {
    const binary = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.zmux_connect_path, test_allocator);
    defer test_allocator.free(binary);
    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "stdin", .data = input });
    const input_path = try std.fs.path.join(test_allocator, &.{ dir.path, "stdin" });
    defer test_allocator.free(input_path);
    const stdout = try directory.createFile(io, "stdout", .{});
    defer stdout.close(io);
    const stderr = try directory.createFile(io, "stderr", .{});
    defer stderr.close(io);
    var client = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "cat \"$1\" | \"$2\" --socket \"$3\" -- \"$4\"", "zmux-test", input_path, binary, dir.socket, name },
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .pgid = 0,
        .stdin = .ignore,
        .stdout = .{ .file = stdout },
        .stderr = .{ .file = stderr },
    });
    const group = client.id.?;
    errdefer _ = std.c.kill(-group, .KILL);
    defer killChild(&client);
    try expectTermExited(try waitChild(&client, 8_000), 0);
}

fn fileContains(dir: TestDir, name: []const u8, needle: []const u8) !bool {
    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    const bytes = try directory.readFileAlloc(io, name, test_allocator, .limited(max_reply));
    defer test_allocator.free(bytes);
    return std.mem.indexOf(u8, bytes, needle) != null;
}

test "exit_then_reattach_by_name and session_named_error_attaches" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    const created = try rpcOk(&admin, 1, "session.create", .{ .id = "error", .shell = "/bin/sh", .command = "exec /bin/sh" });
    defer created.deinit();
    const pane = try expectStringField(try responseResult(created.value), "paneId");

    try runClientWithInput(dir, "error", "printf 'FIRST_%s\\n' RUN; exit 0\n");
    try std.testing.expect(try fileContains(dir, "stdout", "FIRST_RUN"));
    try std.testing.expect(try fileContains(dir, "stderr", "session ended"));
    try runClientWithInput(dir, "error", "printf 'SECOND_%s\\n' RUN; exit 0\n");
    try std.testing.expect(try fileContains(dir, "stdout", "FIRST_RUN"));
    try std.testing.expect(try fileContains(dir, "stdout", "SECOND_RUN"));
    try std.testing.expect(try fileContains(dir, "stderr", "[session exited: code 0]"));
    const info = try rpcOk(&admin, 2, "session.info", .{ .sessionId = pane });
    defer info.deinit();
    try std.testing.expectEqual(@as(i64, 1), try expectIntegerField(try responseResult(info.value), "generation"));
    try endDaemon(&daemon, dir.socket);
}

test "piped input reaches the pane through POLLHUP" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    const command = try std.fmt.allocPrint(test_allocator, "stty raw -echo; printf 'ready\\n'; head -c 204800 > '{s}/received'", .{dir.path});
    defer test_allocator.free(command);
    (try rpcOk(&admin, 1, "session.create", .{ .id = "ls", .shell = "/bin/sh", .command = command })).deinit();
    test_allocator.free(try waitForCaptureContains(test_allocator, dir.socket, "ls", "ready", 4_000));

    const bytes = try test_allocator.alloc(u8, 200 * 1024);
    defer test_allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try runClientWithInput(dir, "ls", bytes);

    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    const received = try directory.readFileAlloc(io, "received", test_allocator, .limited(bytes.len + 1));
    defer test_allocator.free(received);
    try std.testing.expectEqualSlices(u8, bytes, received);
    try endDaemon(&daemon, dir.socket);
}

fn acceptAttachHandshake(conn: *Connection) !void {
    const ping = try conn.read(test_allocator, max_reply, nowMs() + 2_000);
    defer test_allocator.free(ping);
    try std.testing.expect(lineMatchesRpcId(test_allocator, ping, 100));
    const ping_reply = try std.fmt.allocPrint(test_allocator, "{{\"id\":100,\"result\":{{\"version\":\"{s}\"}}}}\n", .{zmux.protocol.version});
    defer test_allocator.free(ping_reply);
    try writeAll(conn.fd, ping_reply);
    const attach = try conn.read(test_allocator, max_reply, nowMs() + 2_000);
    defer test_allocator.free(attach);
    try std.testing.expect(lineMatchesRpcId(test_allocator, attach, 1));
}

test "prebuffered exit before the attach reply is handled" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    const address = try sys.UnixAddress.init(dir.socket);
    try sys.bind(listener, &address);
    try sys.listen(listener, 1);

    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    const stdout = try directory.createFile(io, "stdout", .{});
    defer stdout.close(io);
    const stderr = try directory.createFile(io, "stderr", .{});
    defer stderr.close(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "attach", "error" },
        .stdin = .ignore,
        .stdout = .{ .file = stdout },
        .stderr = .{ .file = stderr },
    });
    defer killChild(&child);
    var pollfds = [_]posix.pollfd{.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try posix.poll(&pollfds, 2_000) != 0);
    var conn: Connection = .{ .fd = try sys.accept(listener) };
    defer conn.close();
    try acceptAttachHandshake(&conn);

    // Replay ends two bytes into the first live frame. A drop from the
    // previous generation must not suppress the non-overlapping bytes.
    try writeAll(conn.fd, "{\"method\":\"pane_output_dropped\",\"params\":{\"pane_id\":\"p\",\"resume_offset\":100,\"generation\":0}}\n" ++
        "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"YWJjZA==\",\"offset\":0,\"generation\":1}}\n" ++
        "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\",\"generation\":1}}\n" ++
        "{\"id\":1,\"result\":{\"paneId\":\"p\",\"clientId\":\"c\",\"replayBase64\":\"YWI=\",\"replayEndOffset\":2,\"generation\":1}}\n");
    try expectTermExited(try waitChild(&child, 1_500), 0);
    const bytes = try directory.readFileAlloc(io, "stdout", test_allocator, .limited(128));
    defer test_allocator.free(bytes);
    try std.testing.expectEqualStrings("abcd", bytes);
    try std.testing.expect(try fileContains(dir, "stderr", "session ended"));
}

test "exit_tail_output_not_lost and attach_replay_no_gap_no_dup" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var observer = try connectClient(dir.socket);
    defer observer.close();
    (try rpcOk(&observer, 1, "events.subscribe", .{ .panes = &.{"*"} })).deinit();
    var admin = try connectClient(dir.socket);
    defer admin.close();
    const created = try rpcOk(&admin, 2, "session.create", .{ .id = "tail", .shell = "/bin/sh", .command = "printf 'LEAD'; read line; printf 'TAIL'; exit 7" });
    defer created.deinit();
    const pane_id = try expectStringField(try responseResult(created.value), "paneId");
    test_allocator.free(try waitForCaptureContains(test_allocator, dir.socket, pane_id, "LEAD", 4_000));
    const attached = try rpcOk(&admin, 3, "client.attach", .{ .paneId = pane_id });
    defer attached.deinit();
    const attach = try responseResult(attached.value);
    const offset = try expectIntegerField(attach, "replayEndOffset");
    const replay = try decodeBase64(test_allocator, try expectStringField(attach, "replayBase64"));
    defer test_allocator.free(replay);
    try std.testing.expectEqualStrings("LEAD", replay);
    try std.testing.expectEqual(@as(i64, 4), offset);
    (try rpcOk(&admin, 4, "session.send", .{ .sessionId = pane_id, .text = "\n" })).deinit();

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(test_allocator);
    try stream.appendSlice(test_allocator, replay);
    const deadline = nowMs() + 4_000;
    while (true) {
        const line = try observer.read(test_allocator, max_reply, deadline);
        defer test_allocator.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, test_allocator, line, .{});
        defer parsed.deinit();
        const method = try expectStringField(parsed.value, "method");
        const params = parsed.value.object.get("params").?;
        if (std.mem.eql(u8, method, "session_exited")) {
            try std.testing.expectEqual(@as(i64, 7), try expectIntegerField(params, "exit_code"));
            break;
        }
        if (!std.mem.eql(u8, method, "pane_output")) continue;
        const chunk = try decodeBase64(test_allocator, try expectStringField(params, "data_base64"));
        defer test_allocator.free(chunk);
        const start: usize = @intCast(try expectIntegerField(params, "offset"));
        try std.testing.expect(start <= stream.items.len);
        const overlap = @min(chunk.len, stream.items.len - start);
        try std.testing.expectEqualSlices(u8, stream.items[start..][0..overlap], chunk[0..overlap]);
        try stream.appendSlice(test_allocator, chunk[overlap..]);
    }
    try std.testing.expect(std.mem.endsWith(u8, stream.items, "TAIL"));
    try endDaemon(&daemon, dir.socket);
}

/// Read `conn` at about 20 KiB/s until one line contains both needles, then
/// consume the rest of the line in progress so the connection's own reader
/// resumes on a frame boundary.
fn slowReadUntilLine(conn: *Connection, needle_a: []const u8, needle_b: []const u8, timeout_ms: i64) !void {
    try std.testing.expectEqual(conn.reader.start, conn.reader.end);
    const deadline = nowMs() + timeout_ms;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(test_allocator);
    var found = false;
    var chunk: [1024]u8 = undefined;
    while (true) {
        if (found and pending.items.len == 0) return;
        if (nowMs() >= deadline) return error.NotificationTimeout;
        var fds = [_]posix.pollfd{.{ .fd = conn.fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 50) == 0) continue;
        const n = try posix.read(conn.fd, chunk[0..if (found) 1 else chunk.len]);
        if (n == 0) return error.EndOfStream;
        try pending.appendSlice(test_allocator, chunk[0..n]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |end| {
            const line = pending.items[0..end];
            if (std.mem.indexOf(u8, line, needle_a) != null and std.mem.indexOf(u8, line, needle_b) != null) found = true;
            try pending.replaceRange(test_allocator, 0, end + 1, &.{});
        }
        if (!found) sleepMs(50);
    }
}

/// Read and discard lines from `conn` for `ms` milliseconds.
fn drainLinesFor(conn: *Connection, ms: i64) !void {
    const deadline = nowMs() + ms;
    while (true) {
        const line = conn.read(test_allocator, 1024 * 1024, deadline) catch |err| switch (err) {
            error.ReadTimeout => return,
            else => return err,
        };
        test_allocator.free(line);
    }
}

test "flood_does_not_disconnect_slow_client or an attached quiet pane client" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    var slow = try connectClient(dir.socket);
    defer slow.close();
    // Subscribe before flooding and stop reading to force the queue to cross
    // its high-water mark. The quiet pane is attached on another connection.
    (try rpcOk(&slow, 1, "events.subscribe", .{ .panes = &.{"*"} })).deinit();

    const quiet = try rpcOk(&admin, 2, "session.create", .{ .id = "quiet", .shell = "/bin/sh", .command = "read line; printf 'QUIET_%s' OK; sleep 10" });
    defer quiet.deinit();
    const quiet_id = try expectStringField(try responseResult(quiet.value), "paneId");
    var live = try connectClient(dir.socket);
    defer live.close();
    (try rpcOk(&live, 3, "client.attach", .{ .paneId = quiet_id })).deinit();

    const flood = try rpcOk(&admin, 4, "session.create", .{
        .id = "flood",
        .shell = "/bin/sh",
        // 4 MiB of output is several times the 1 MiB per-connection queue.
        .command = "yes flood | head -c 4194304; printf 'FLOOD_DONE'; sleep 10",
    });
    defer flood.deinit();
    const flood_id = try expectStringField(try responseResult(flood.value), "paneId");

    // The slow client reads a trickle (about 20 KiB/s) until its queue has
    // crossed the high-water mark and the drop notice reaches it. A trickle
    // rather than no reads at all: a client that leaves one frame unread past
    // the server's send deadline is disconnected by design, and how long the
    // flood needs to overflow the queue depends on PTY throughput (a busy
    // Darwin PTY delivers tens of bytes a read).
    try slowReadUntilLine(&slow, "\"pane_output_dropped\"", flood_id, 60_000);

    // From here the client keeps up while the rest of the flood arrives. The
    // bound is for liveness only; a loaded machine needs tens of seconds.
    const flood_deadline = nowMs() + 120_000;
    while (true) {
        const text = try captureSessionText(test_allocator, dir.socket, flood_id);
        defer test_allocator.free(text);
        if (std.mem.indexOf(u8, text, "FLOOD_DONE") != null) break;
        if (nowMs() >= flood_deadline) return error.CaptureTimeout;
        try drainLinesFor(&slow, 50);
    }
    (try rpcOk(&admin, 5, "session.send", .{ .sessionId = quiet_id, .text = "\n" })).deinit();

    const deadline = nowMs() + 4_000;
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(test_allocator);
    while (std.mem.indexOf(u8, tail.items, "QUIET_OK") == null) {
        const line = try live.read(test_allocator, max_reply, deadline);
        defer test_allocator.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, test_allocator, line, .{});
        defer parsed.deinit();
        const method = try expectStringField(parsed.value, "method");
        if (!std.mem.eql(u8, method, "pane_output")) continue;
        const params = parsed.value.object.get("params").?;
        try std.testing.expectEqualStrings(quiet_id, try expectStringField(params, "pane_id"));
        const chunk = try decodeBase64(test_allocator, try expectStringField(params, "data_base64"));
        defer test_allocator.free(chunk);
        try tail.appendSlice(test_allocator, chunk);
    }
    (try rpcOk(&slow, 6, "daemon.ping", .{})).deinit();
    (try rpcOk(&live, 7, "daemon.ping", .{})).deinit();
    try endDaemon(&daemon, dir.socket);
}

test "background_job_dies_on_terminate and client_list_pruned_after_terminate" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    // The job inherits the PTY process group. Its HUP trap leaves a receipt,
    // so a later zombie reparented to the runner cannot make the test flaky.
    const command = try std.fmt.allocPrint(test_allocator, "(trap 'echo gone > {s}/gone; exit 0' HUP; echo ready > {s}/ready; while :; do sleep 1; done) & wait", .{ dir.path, dir.path });
    defer test_allocator.free(command);
    const created = try rpcOk(&admin, 1, "session.create", .{ .id = "job", .shell = "/bin/sh", .command = command });
    defer created.deinit();
    const pane = try expectStringField(try responseResult(created.value), "paneId");
    var attached = try connectClient(dir.socket);
    defer attached.close();
    const reply = try rpcOk(&attached, 2, "client.attach", .{ .paneId = pane });
    defer reply.deinit();
    const id = try expectStringField(try responseResult(reply.value), "clientId");
    try waitForFile(dir, "ready", "ready", 3_000);
    (try rpcOk(&admin, 3, "session.terminate", .{ .sessionId = pane })).deinit();
    try waitForFile(dir, "gone", "gone", 3_000);
    const detached = try readNotificationLine(test_allocator, &attached, "client_detached", id, 3_000);
    defer test_allocator.free(detached);
    try waitForClientCount(test_allocator, dir.socket, 0, 3_000);
    try endDaemon(&daemon, dir.socket);
}

fn waitForFile(dir: TestDir, file: []const u8, needle: []const u8, timeout_ms: i64) !void {
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (fileContains(dir, file, needle) catch |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        }) return;
        sleepMs(10);
    }
    return error.FileTimeout;
}

test "respawn_does_not_end_attached_client" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    (try rpcOk(&admin, 1, "session.create", .{ .id = "work", .shell = "/bin/sh", .command = "exec /bin/sh" })).deinit();

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "work", "--no-create" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer killChild(&child);
    try waitForClientCount(test_allocator, dir.socket, 1, 4_000);
    const failed = try rpc(&admin, 2, "pane.respawn", .{ .paneId = "work", .kill = false });
    defer failed.deinit();
    try expectErrorKind(failed.value, "conflict");
    (try rpcOk(&admin, 3, "pane.respawn", .{ .paneId = "work", .kill = true })).deinit();
    try child.stdin.?.writeStreamingAll(io, "printf 'NEW_%s\\n' LIFE\n");
    test_allocator.free(try waitForCaptureContains(test_allocator, dir.socket, "work", "NEW_LIFE", 4_000));
    try child.stdin.?.writeStreamingAll(io, "exit 0\n");
    try expectTermExited(try waitChild(&child, 4_000), 0);
    try endDaemon(&daemon, dir.socket);
}

test "sigterm_during_connect_burst_exits" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var clients: [32]posix.fd_t = undefined;
    var count: usize = 0;
    defer for (clients[0..count]) |fd| sys.close(fd);
    for (&clients, 0..) |*fd, i| {
        const conn = connectClientUntil(dir.socket, nowMs() + 200) catch |err| {
            if (i > clients.len / 2) break;
            return err;
        };
        fd.* = conn.fd;
        count += 1;
        if (i == clients.len / 2) {
            try std.testing.expectEqual(@as(c_int, 0), std.c.kill(daemon.id.?, .TERM));
        }
    }
    try expectTermExited(try waitChild(&daemon, 3_000), 0);
}

test "sigterm_with_blocked_pty_write_exits" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    (try rpcOk(&admin, 1, "session.create", .{ .id = "blocked", .shell = "/bin/sh", .command = "stty raw -echo; printf 'BLOCKED_READY'; sleep 60" })).deinit();
    test_allocator.free(try waitForCaptureContains(test_allocator, dir.socket, "blocked", "BLOCKED_READY", 4_000));
    var writer = try connectClient(dir.socket);
    defer writer.close();
    const raw = try test_allocator.alloc(u8, 400 * 1024);
    defer test_allocator.free(raw);
    @memset(raw, 'x');
    const encoder = std.base64.standard.Encoder;
    const encoded = try test_allocator.alloc(u8, encoder.calcSize(raw.len));
    defer test_allocator.free(encoded);
    _ = encoder.encode(encoded, raw);
    const frame = try std.fmt.allocPrint(test_allocator, "{{\"id\":2,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"blocked\",\"dataBase64\":\"{s}\"}}}}\n", .{encoded});
    defer test_allocator.free(frame);
    try writeAll(writer.fd, frame);
    try std.testing.expectError(error.ReadTimeout, writer.read(test_allocator, max_reply, nowMs() + 100));
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(daemon.id.?, .TERM));
    try expectTermExited(try waitChild(&daemon, 3_000), 0);
}

test "environment merge, replacement, default TERM and duplicate names" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var env = std.process.Environ.Map.init(test_allocator);
    defer env.deinit();
    try env.put("ZMUX_INHERITED", "inherited");
    var daemon = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmuxd_path, "--socket", dir.socket, "--idle-seconds", "0" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killChild(&daemon);
    try waitForSocket(dir.socket, 4_000);
    var admin = try connectClient(dir.socket);
    defer admin.close();
    const command = "printf '%s/%s/%s\\n' \"${ZMUX_INHERITED-unset}\" \"$ROUND_ONE\" \"$TERM\"; /bin/cat";
    const merged = try rpcOk(&admin, 1, "session.create", .{ .id = "merged", .shell = "/bin/sh", .command = command, .env = .{ .ROUND_ONE = "set" } });
    defer merged.deinit();
    (try rpcOk(&admin, 2, "session.create", .{ .id = "clear", .shell = "/bin/sh", .command = command, .env = .{ .ROUND_ONE = "set" }, .clearEnv = true })).deinit();
    test_allocator.free(try waitForCaptureContains(test_allocator, dir.socket, "merged", "inherited/set/xterm-256color", 4_000));
    test_allocator.free(try waitForCaptureContains(test_allocator, dir.socket, "clear", "unset/set/xterm-256color", 4_000));

    const duplicate = try rpc(&admin, 3, "session.create", .{ .id = "merged", .shell = "/bin/sh", .command = command });
    defer duplicate.deinit();
    try expectErrorKind(duplicate.value, "conflict");
    try std.testing.expectEqualStrings("DuplicateSessionName", try expectStringField(duplicate.value.object.get("error").?, "message"));
    const session_id = try expectStringField(try responseResult(merged.value), "sessionId");
    const shadow = try rpc(&admin, 4, "session.rename", .{ .sessionId = "clear", .name = session_id });
    defer shadow.deinit();
    try expectErrorKind(shadow.value, "conflict");
    try std.testing.expectEqualStrings("NameShadowsId", try expectStringField(shadow.value.object.get("error").?, "message"));
    const exact = try rpcOk(&admin, 5, "client.attach", .{ .paneId = session_id });
    defer exact.deinit();
    try std.testing.expectEqualStrings(try expectStringField(try responseResult(merged.value), "paneId"), try expectStringField(try responseResult(exact.value), "paneId"));
    try endDaemon(&daemon, dir.socket);
}

extern "c" fn openpty(master: *posix.fd_t, slave: *posix.fd_t, name: ?[*]u8, termios: ?*const posix.termios, size: ?*const posix.winsize) c_int;

fn waitForRawMode(fd: posix.fd_t) !posix.termios {
    const deadline = nowMs() + 2_000;
    while (nowMs() < deadline) {
        const mode = try posix.tcgetattr(fd);
        if (!mode.lflag.ICANON and !mode.iflag.IGNCR and mode.cc[@backingInt(posix.V.MIN)] == 1 and
            mode.cc[@backingInt(posix.V.TIME)] == 0) return mode;
        sleepMs(5);
    }
    return error.RawModeTimeout;
}

/// Compare terminal settings, ignoring `PENDIN`. That bit is kernel state,
/// not a setting: Darwin sets it itself whenever a `tcsetattr` switches the
/// line discipline back to canonical mode (to reprocess pending input) and
/// clears it on the next read, so a faithful restore still reads it back set.
fn expectTermiosRestored(expected: posix.termios, actual: posix.termios) !void {
    var want = expected;
    var got = actual;
    want.lflag.PENDIN = false;
    got.lflag.PENDIN = false;
    try std.testing.expectEqualDeep(want, got);
}

test "client restores inherited terminal on TSTP and TERM, and re-enters raw on CONT" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    const address = try sys.UnixAddress.init(dir.socket);
    try sys.bind(listener, &address);
    try sys.listen(listener, 1);

    var master: posix.fd_t = undefined;
    var slave: posix.fd_t = undefined;
    const size: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    if (openpty(&master, &slave, null, null, &size) != 0) return error.OpenTestPtyFailed;
    defer sys.close(master);
    defer sys.close(slave);
    try sys.setCloseOnExec(master);
    try sys.setCloseOnExec(slave);
    var inherited = try posix.tcgetattr(slave);
    inherited.iflag.IGNCR = true;
    inherited.lflag.ICANON = true;
    inherited.cc[@backingInt(posix.V.MIN)] = 0;
    inherited.cc[@backingInt(posix.V.TIME)] = 5;
    try posix.tcsetattr(slave, .NOW, inherited);
    const original = try posix.tcgetattr(slave);

    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "tty" },
        .pgid = 0,
        .stdin = .{ .file = .{ .handle = slave, .flags = .{ .nonblocking = false } } },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer killChild(&child);
    var pollfds = [_]posix.pollfd{.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try posix.poll(&pollfds, 2_000) != 0);
    var conn: Connection = .{ .fd = try sys.accept(listener) };
    defer conn.close();
    test_allocator.free(try conn.read(test_allocator, max_reply, nowMs() + 2_000));
    const ping = try std.fmt.allocPrint(test_allocator, "{{\"id\":100,\"result\":{{\"version\":\"{s}\"}}}}\n", .{zmux.protocol.version});
    defer test_allocator.free(ping);
    try writeAll(conn.fd, ping);
    test_allocator.free(try conn.read(test_allocator, max_reply, nowMs() + 2_000));
    try writeAll(conn.fd, "{\"id\":1,\"result\":{\"paneId\":\"p\",\"clientId\":\"c\"}}\n{");

    _ = try waitForRawMode(slave);
    const initial_resize = try conn.read(test_allocator, max_reply, nowMs() + 2_000);
    defer test_allocator.free(initial_resize);
    try std.testing.expect(std.mem.indexOf(u8, initial_resize, "\"method\":\"session.resize\"") != null);
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(child.id.?, .WINCH));
    const winch_resize = try conn.read(test_allocator, max_reply, nowMs() + 2_000);
    defer test_allocator.free(winch_resize);
    try std.testing.expect(std.mem.indexOf(u8, winch_resize, "\"method\":\"session.resize\"") != null);
    try sys.writeAll(master, "\r");
    const input = try conn.read(test_allocator, max_reply, nowMs() + 2_000);
    defer test_allocator.free(input);
    try std.testing.expect(std.mem.indexOf(u8, input, "\"dataBase64\":\"DQ==\"") != null);

    const pid = child.id.?;
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(pid, .TSTP));
    const deadline = nowMs() + 2_000;
    while (true) {
        var status: c_int = 0;
        const got = std.c.waitpid(pid, &status, 3); // WNOHANG | WUNTRACED
        if (got > 0) {
            if (!posix.W.IFSTOPPED(@bitCast(status))) {
                cleanChild(&child);
                return error.UnexpectedChildTerm;
            }
            break;
        }
        if (nowMs() >= deadline) return error.StopTimeout;
        sleepMs(5);
    }
    try expectTermiosRestored(original, try posix.tcgetattr(slave));
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(pid, .CONT));
    _ = try waitForRawMode(slave);
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(pid, .TERM));
    const term = try waitChild(&child, 2_000);
    try std.testing.expect(term == .signal and term.signal == .TERM);
    try expectTermiosRestored(original, try posix.tcgetattr(slave));
}

test "auto-spawn keeps daemon startup logs when stderr is closed" {
    const dir = try TestDir.init();
    defer dir.deinit();
    var env = std.process.Environ.Map.init(test_allocator);
    defer env.deinit();
    try env.put("ZMUX_LOG_LEVEL", "info");
    defer {
        const reply = rpcLine(test_allocator, dir.socket, "{\"id\":1,\"method\":\"daemon.shutdown\"}\n", max_reply) catch null;
        if (reply) |line| test_allocator.free(line);
    }
    var client = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "missing", "--spawn-daemon", "--no-create" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .close,
    });
    defer killChild(&client);
    try expectTermExited(try waitChild(&client, 6_000), 1);
    try waitForSocket(dir.socket, 2_000);
    try std.testing.expect(try fileContains(dir, "zmux.sock.log", "daemon_start"));
}

test "daemon preserves a regular file at the socket path" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    try directory.writeFile(io, .{ .sub_path = "zmux.sock", .data = "keep" });
    var daemon = try spawnDaemon(dir.socket);
    defer killChild(&daemon);
    try expectTermExited(try waitChild(&daemon, 3_000), 1);
    try std.testing.expect(try fileContains(dir, "zmux.sock", "keep"));
}

fn shutdownAutoSpawned(path: []const u8) void {
    const reply = rpcLine(test_allocator, path, "{\"id\":1,\"method\":\"daemon.shutdown\"}\n", max_reply) catch return;
    test_allocator.free(reply);
}

test "auto-spawn accepts an explicit socket directly under /tmp" {
    const generated = try tempSocketPath(test_allocator);
    defer test_allocator.free(generated);
    const path = try std.fs.path.join(test_allocator, &.{ "/tmp", std.fs.path.basename(generated) });
    defer test_allocator.free(path);
    const log = try std.fmt.allocPrint(test_allocator, "{s}.log", .{path});
    defer test_allocator.free(log);
    const lock = try std.fmt.allocPrint(test_allocator, "{s}.lock", .{path});
    defer test_allocator.free(lock);
    defer std.Io.Dir.deleteFileAbsolute(io, log) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, lock) catch {};
    defer shutdownAutoSpawned(path);

    // Existing logs may have been created with a looser mode.
    const log_fd = try sys.open(log, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    defer sys.close(log_fd);
    try sys.fchmod(log_fd, 0o644);

    var client = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", path, "--spawn-daemon", "work", "--command", "cat" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer killChild(&client);
    try expectTermExited(try waitChild(&client, 8_000), 0);
    try std.testing.expectEqual(@as(u32, 0o600), (try sys.statAt(sys.cwd_fd, log, false)).permissions());
}

test "auto-spawn upgrades a legacy 0755 managed directory" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const parent = try std.fs.path.join(test_allocator, &.{ dir.path, ".smithers" });
    defer test_allocator.free(parent);
    const path = try std.fs.path.join(test_allocator, &.{ parent, "sessions.sock" });
    defer test_allocator.free(path);
    try sys.mkdir(parent, 0o755);
    const fd = try sys.openDirNoFollow(parent);
    defer sys.close(fd);
    try sys.fchmod(fd, 0o755);
    defer shutdownAutoSpawned(path);
    var env = std.process.Environ.Map.init(test_allocator);
    defer env.deinit();
    try env.put("HOME", dir.path);
    var client = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--spawn-daemon", "work", "--command", "cat" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    defer killChild(&client);
    try expectTermExited(try waitChild(&client, 8_000), 0);
    try std.testing.expectEqual(@as(u32, 0o700), (try sys.fstat(fd)).permissions());
}

test "piped send waits for a delayed daemon error even after session exit" {
    const dir = try TestDir.init();
    defer dir.deinit();
    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    const address = try sys.UnixAddress.init(dir.socket);
    try sys.bind(listener, &address);
    try sys.listen(listener, 1);
    const directory = try std.Io.Dir.openDirAbsolute(io, dir.path, .{});
    defer directory.close(io);
    const stderr = try directory.createFile(io, "stderr", .{});
    defer stderr.close(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ build_options.zmux_connect_path, "--socket", dir.socket, "attach", "work" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .{ .file = stderr },
    });
    defer killChild(&child);
    try child.stdin.?.writeStreamingAll(io, "input");
    child.stdin.?.close(io);
    child.stdin = null;

    var pollfds = [_]posix.pollfd{.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try posix.poll(&pollfds, 2_000) != 0);
    var conn: Connection = .{ .fd = try sys.accept(listener) };
    defer conn.close();
    try acceptAttachHandshake(&conn);
    try writeAll(conn.fd, "{\"id\":1,\"result\":{\"paneId\":\"p\",\"clientId\":\"c\",\"generation\":1}}\n");

    const send_id = while (true) {
        const line = try conn.read(test_allocator, max_reply, nowMs() + 2_000);
        defer test_allocator.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, test_allocator, line, .{});
        defer parsed.deinit();
        const method = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, method, "session.send")) break try expectIntegerField(parsed.value, "id");
    };
    sleepMs(2_200);
    try writeAll(conn.fd, "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\",\"generation\":1}}\n");
    const failure = try std.fmt.allocPrint(test_allocator, "{{\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"InputClosed\",\"data\":{{\"kind\":\"io\"}}}}}}\n", .{send_id});
    defer test_allocator.free(failure);
    try writeAll(conn.fd, failure);
    try expectTermExited(try waitChild(&child, 2_000), 1);
    try std.testing.expect(try fileContains(dir, "stderr", "InputClosed"));
}
