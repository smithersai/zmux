const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("test_build_options");
const server_mod = @import("zmux_server");

const posix = std.posix;

fn tempSocketPath(allocator: std.mem.Allocator) ![]u8 {
    // Use the system tmp dir for the UNIX domain socket. sun_path has a
    // ~104 byte limit on Darwin, so we keep the path short.
    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
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
    const address = try std.net.Address.initUnix(path);
    const listener = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer posix.close(listener);
    posix.bind(listener, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    std.fs.deleteFileAbsolute(path) catch {};
}

fn connectClient(path: []const u8) !posix.fd_t {
    const address = try std.net.Address.initUnix(path);
    const deadline_ms = std.time.milliTimestamp() + 2_000;
    while (true) {
        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        if (posix.connect(fd, &address.any, address.getOsSockLen())) |_| {
            return fd;
        } else |err| {
            posix.close(fd);
            // A saturated listen backlog surfaces as a transient ECONNREFUSED
            // on unix sockets (macOS clamps the accept queue to somaxconn):
            // the server drains and accepts moments later, so retry briefly
            // rather than treating a full backlog as a hard failure.
            if (err == error.ConnectionRefused and std.time.milliTimestamp() < deadline_ms) {
                std.Thread.sleep(2 * std.time.ns_per_ms);
                continue;
            }
            return err;
        }
    }
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try posix.write(fd, bytes[offset..]);
    }
}

fn readLineAlloc(allocator: std.mem.Allocator, fd: posix.fd_t, max_len: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &byte);
        if (n == 0) {
            if (out.items.len == 0) return error.EndOfStream;
            return try out.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try out.toOwnedSlice(allocator);
        try out.append(allocator, byte[0]);
        if (out.items.len > max_len) return error.ResponseTooLarge;
    }
}

fn readLineAllocTimeout(allocator: std.mem.Allocator, fd: posix.fd_t, max_len: usize, timeout_ms: i64) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var byte: [1]u8 = undefined;
    while (true) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return error.ReadTimeout;
        var fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const remaining: i32 = @intCast(@min(deadline - now, std.math.maxInt(i32)));
        const ready = try posix.poll(&fds, remaining);
        if (ready == 0) return error.ReadTimeout;
        if ((fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and (fds[0].revents & posix.POLL.IN) == 0) {
            return error.EndOfStream;
        }
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;

        const n = try posix.read(fd, &byte);
        if (n == 0) {
            if (out.items.len == 0) return error.EndOfStream;
            return try out.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try out.toOwnedSlice(allocator);
        try out.append(allocator, byte[0]);
        if (out.items.len > max_len) return error.ResponseTooLarge;
    }
}

fn rpcLine(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    request: []const u8,
    max_len: usize,
) ![]u8 {
    const client = try connectClient(socket_path);
    defer posix.close(client);
    try writeAll(client, request);
    return readRpcResponseWithAnyId(allocator, client, max_len);
}

fn readRpcResponseWithAnyId(allocator: std.mem.Allocator, fd: posix.fd_t, max_len: usize) ![]u8 {
    while (true) {
        const line = try readLineAlloc(allocator, fd, max_len);
        if (lineHasRpcId(allocator, line)) return line;
        allocator.free(line);
    }
}

fn readRpcResponseLine(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    expected_id: i64,
    max_len: usize,
) ![]u8 {
    while (true) {
        const line = try readLineAlloc(allocator, fd, max_len);
        if (lineMatchesRpcId(allocator, line, expected_id)) return line;
        allocator.free(line);
    }
}

fn readRpcResponseLineTimeout(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    expected_id: i64,
    max_len: usize,
    timeout_ms: i64,
) ![]u8 {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return error.ReadTimeout;
        const line = try readLineAllocTimeout(allocator, fd, max_len, deadline - now);
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
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(fd);
        const address = std.net.Address.initUnix(path) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        if (posix.connect(fd, &address.any, address.getOsSockLen())) |_| {
            return;
        } else |_| {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
    return error.SocketNotReady;
}

fn waitForClientCount(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    expected_count: usize,
    timeout_ms: i64,
) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const client = connectClient(socket_path) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer posix.close(client);

        try writeAll(client, "{\"id\":99,\"method\":\"client.list\",\"params\":{}}\n");

        const line = readRpcResponseLine(allocator, client, 99, 64 * 1024) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        if (result_val == .array and result_val.array.items.len == expected_count) {
            return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.ClientCountTimeout;
}

fn waitForProcessGone(pid: posix.pid_t, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (std.c.kill(pid, 0) != 0) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.ProcessStillExists;
}

fn waitForSessionExited(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    pane_id: []const u8,
    expected_exit_code: i64,
    timeout_ms: i64,
) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const line = try readLineAllocTimeout(allocator, fd, 1024 * 1024, deadline - std.time.milliTimestamp());
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

fn waitForPaneOutput(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    pane_id: []const u8,
    timeout_ms: i64,
) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    // Drain in bulk rather than one syscall per byte: a slow reader lets the
    // server's per-connection broadcast queue overflow while another pane is
    // flooding, which drops this client (EndOfStream) before the target line
    // ever arrives. Chunked reads keep the client draining fast enough to stay.
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return error.PaneOutputTimeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        const remaining: i32 = @intCast(@min(deadline - now, std.math.maxInt(i32)));
        const ready = try posix.poll(&fds, remaining);
        if (ready == 0) return error.PaneOutputTimeout;
        if ((fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and (fds[0].revents & posix.POLL.IN) == 0) {
            return error.EndOfStream;
        }
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;

        const n = try posix.read(fd, &chunk);
        if (n == 0) return error.EndOfStream;
        try pending.appendSlice(allocator, chunk[0..n]);

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pending.items, start, '\n')) |nl| {
            const line = pending.items[start..nl];
            start = nl + 1;
            if (paneOutputMatches(allocator, line, pane_id)) return;
        }
        if (start > 0) {
            const rest = pending.items.len - start;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[start..]);
            pending.shrinkRetainingCapacity(rest);
        }
    }
}

fn paneOutputMatches(allocator: std.mem.Allocator, line: []const u8, pane_id: []const u8) bool {
    if (line.len == 0) return false;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const method = parsed.value.object.get("method") orelse return false;
    if (method != .string or !std.mem.eql(u8, method.string, "pane_output")) return false;
    const params = parsed.value.object.get("params") orelse return false;
    if (params != .object) return false;
    const got = params.object.get("pane_id") orelse return false;
    return got == .string and std.mem.eql(u8, got.string, pane_id);
}

fn firstPaneMasterFd(server: *server_mod.Server) !posix.fd_t {
    server.manager.mutex.lock();
    defer server.manager.mutex.unlock();

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
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        const text = try captureSessionText(allocator, socket_path, session_id);
        if (std.mem.indexOf(u8, text, needle) != null) return text;
        allocator.free(text);
        std.Thread.sleep(50 * std.time.ns_per_ms);
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
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (std.time.milliTimestamp() < deadline) {
        if (ctx.done.load(.seq_cst)) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
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
    const client = try connectClient(socket_path);
    defer posix.close(client);
    const attach_req = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":{},\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
        .{ rpc_id, pane_id },
    );
    defer allocator.free(attach_req);
    try writeAll(client, attach_req);

    const line = try readRpcResponseLine(allocator, client, rpc_id, 1024 * 1024);
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
    fd: posix.fd_t,
    expected_method: []const u8,
    expected_pane_id: []const u8,
    timeout_ms: i64,
) ![]u8 {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        const now = std.time.milliTimestamp();
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
        const pane_id = params.object.get("pane_id") orelse params.object.get("session_id") orelse {
            allocator.free(line);
            continue;
        };
        if (pane_id == .string and std.mem.eql(u8, pane_id.string, expected_pane_id)) return line;
        allocator.free(line);
    }
}

fn readPaneOutputContaining(
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    pane_id: []const u8,
    needle: []const u8,
    timeout_ms: i64,
) ![]u8 {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return error.PaneOutputTimeout;
        const line = try readNotificationLine(allocator, fd, "pane_output", pane_id, deadline - now);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const params = parsed.value.object.get("params") orelse return error.MissingParams;
        const encoded = try expectStringField(params, "data_base64");
        const decoded = try decodeBase64(allocator, encoded);
        if (std.mem.indexOf(u8, decoded, needle) != null) return decoded;
        allocator.free(decoded);
    }
}

fn expectTermExited(term: std.process.Child.Term, expected_code: u8) !void {
    switch (term) {
        .Exited => |code| try std.testing.expectEqual(expected_code, code),
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
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ binary.path, "--version" },
                .max_output_bytes = 4096,
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try expectTermExited(result.term, 0);
            _ = binary.name;
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "zmux") != null);
        }
        {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ binary.path, "--help" },
                .max_output_bytes = 4096,
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            try expectTermExited(result.term, 0);
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Usage:") != null);
        }
        {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ binary.path, "--definitely-not-a-zmux-flag" },
                .max_output_bytes = 4096,
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            switch (result.term) {
                .Exited => |code| try std.testing.expect(code != 0),
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(pid_path) catch {};

    var child = std.process.Child.init(&.{ build_options.zmuxd_path, "--socket", socket_path, "--idle-seconds", "0" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    var child_running = true;
    errdefer if (child_running) {
        _ = std.c.kill(child.id, std.c.SIG.KILL);
        _ = child.wait() catch {};
    };

    try waitForSocket(socket_path, 2_000);
    if (std.c.kill(child.id, std.c.SIG.KILL) != 0) return error.KillFailed;
    _ = try child.wait();
    child_running = false;
    try std.fs.accessAbsolute(socket_path, .{});

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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

    const client = try connectClient(socket_path);
    defer posix.close(client);

    {
        try writeAll(client, "not-json\n");
        const line = try readRpcResponseWithAnyId(allocator, client, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32600);
    }

    {
        try writeAll(client, "{\"id\":2,\"method\":\"missing.method\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 2, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32601);
    }

    {
        try writeAll(client, "{\"id\":3,\"method\":\"session.info\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 3, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32602);
    }

    {
        try writeAll(client, "{\"id\":4,\"method\":\"client.detach\",\"params\":{\"clientId\":\"client-missing\"}}\n");
        const line = try readRpcResponseLine(allocator, client, 4, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32000);
    }

    {
        try writeAll(client, "{\"id\":{\"trace\":[1,2]},\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readRpcResponseWithAnyId(allocator, client, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const id_val = parsed.value.object.get("id") orelse return error.MissingId;
        try std.testing.expect(id_val == .object);
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    {
        const oversized = try allocator.alloc(u8, 1024 * 1024 + 2);
        defer allocator.free(oversized);
        @memset(oversized[0 .. oversized.len - 1], 'x');
        oversized[oversized.len - 1] = '\n';

        const overflow = try connectClient(socket_path);
        defer posix.close(overflow);
        try writeAll(overflow, oversized);
        const line = try readRpcResponseWithAnyId(allocator, overflow, 64 * 1024);
        defer allocator.free(line);
        try expectRpcErrorCode(allocator, line, -32700);
        try std.testing.expectError(error.EndOfStream, readLineAllocTimeout(allocator, overflow, 64 * 1024, 2_000));
    }

    {
        try writeAll(client, "{\"id\":5,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 5, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("error") == null);
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val.object.get("version") != null);
    }

    {
        try writeAll(client, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 6, 64 * 1024);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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

    const observer = try connectClient(socket_path);
    defer posix.close(observer);

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
        pane_id = try allocator.dupe(u8, (result_val.object.get("id") orelse return error.MissingSessionId).string);
        child_pid = @intCast((result_val.object.get("pid") orelse return error.MissingPid).integer);
    }

    try waitForSessionExited(allocator, observer, pane_id, 7, 4_000);
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
        for (padding.items) |fd| posix.close(fd);
        padding.deinit(allocator);
    }
    for (0..32) |_| {
        const fd = try posix.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        try padding.append(allocator, fd);
    }

    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        first_id = try allocator.dupe(u8, (result_val.object.get("id") orelse return error.MissingSessionId).string);
    }

    const master_fd = try firstPaneMasterFd(&server);
    for (padding.items) |fd| posix.close(fd);
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
        second_id = try allocator.dupe(u8, (result_val.object.get("id") orelse return error.MissingSessionId).string);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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

    const idle = try connectClient(socket_path);
    defer posix.close(idle);
    std.Thread.sleep(100 * std.time.ns_per_ms);

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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};
    test_shutdown_requested.store(false, .seq_cst);
    defer test_shutdown_requested.store(false, .seq_cst);

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        pane_id = try allocator.dupe(u8, try expectStringField(result_val, "id"));
        child_pid = @intCast(try expectIntegerField(result_val, "pid"));
    }
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readRpcResponseLine(allocator, client, 2, 1024 * 1024);
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
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(socket_path, .{}));
}

test "daemon.shutdown with live attached sessions terminates cleanly" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        pane_id = try allocator.dupe(u8, try expectStringField(result_val, "id"));
        child_pid = @intCast(try expectIntegerField(result_val, "pid"));
    }

    var attached = [_]posix.fd_t{ try connectClient(socket_path), try connectClient(socket_path) };
    defer {
        for (attached) |fd| posix.close(fd);
    }
    for (&attached, 0..) |*fd, index| {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{},\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{ index + 2, pane_id },
        );
        defer allocator.free(req);
        try writeAll(fd.*, req);
        const line = try readRpcResponseLine(allocator, fd.*, @intCast(index + 2), 1024 * 1024);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 1);
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
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(socket_path, .{}));
}

test "idle timeout waits for a live session then exits after it is terminated" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 1);
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
        pane_id = try allocator.dupe(u8, try expectStringField(result_val, "id"));
    }

    std.Thread.sleep(1_500 * std.time.ns_per_ms);
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

test "server rejects connections above max_client_connections" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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

    const max_connections = server_mod.max_client_connections;
    var clients = std.ArrayList(posix.fd_t).empty;
    try clients.ensureTotalCapacity(allocator, max_connections);
    defer {
        for (clients.items) |fd| posix.close(fd);
        clients.deinit(allocator);
    }

    for (0..max_connections) |_| {
        try clients.append(allocator, try connectClient(socket_path));
    }

    const overflow_client = try connectClient(socket_path);
    defer posix.close(overflow_client);
    var saw_limit_error = false;
    var overflow_msg: ?[]u8 = null;
    overflow_msg = readLineAllocTimeout(
        allocator,
        overflow_client,
        64 * 1024,
        1_000,
    ) catch |err| switch (err) {
        error.EndOfStream, error.ReadTimeout => null,
        else => return err,
    };
    if (overflow_msg) |msg| {
        defer allocator.free(msg);
        saw_limit_error = std.mem.indexOf(
            u8,
            msg,
            "server connection limit reached",
        ) != null;
    }
    try std.testing.expect(saw_limit_error);

    // Free one slot and confirm a new live connection is accepted. The control
    // connection is scoped so it releases its slot before the shutdown request.
    const released = clients.orderedRemove(0);
    posix.close(released);
    std.Thread.sleep(50 * std.time.ns_per_ms);

    {
        const control = try connectClient(socket_path);
        defer posix.close(control);
        try writeAll(control, "{\"id\":99,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const ping_response = try readLineAllocTimeout(allocator, control, 64 * 1024, 2_000);
        defer allocator.free(ping_response);
        try std.testing.expect(std.mem.indexOf(u8, ping_response, "\"result\"") != null);
    }

    // Release every remaining held client so the shutdown request is not turned
    // away by the connection cap, then let the accept loop drain the closures.
    // Clear the list so the outer defer does not double-close these fds.
    for (clients.items) |fd| posix.close(fd);
    clients.clearRetainingCapacity();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    {
        const shutdown = try connectClient(socket_path);
        defer posix.close(shutdown);
        try writeAll(shutdown, "{\"id\":100,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const shutdown_response = try readLineAllocTimeout(allocator, shutdown, 64 * 1024, 2_000);
        defer allocator.free(shutdown_response);
    }

    thread.join();
    server.deinit();
    server_stopped = true;
    try std.testing.expect(ctx.run_error == null);
}

test "stalled client does not block live pane output or active termination" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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

    const stalled = try connectClient(socket_path);
    defer posix.close(stalled);

    var flood_id: []u8 = &.{};
    defer if (flood_id.len > 0) allocator.free(flood_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"yes ZMUX_FLOOD\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        flood_id = try allocator.dupe(u8, (result_val.object.get("id") orelse return error.MissingSessionId).string);
    }

    std.Thread.sleep(2_000 * std.time.ns_per_ms);

    const live = try connectClient(socket_path);
    defer posix.close(live);

    var victim_id: []u8 = &.{};
    defer if (victim_id.len > 0) allocator.free(victim_id);
    {
        const line = try rpcLine(
            allocator,
            socket_path,
            "{\"id\":2,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"i=0; while [ $i -lt 20 ]; do echo VICTIM_$i; i=$((i+1)); sleep 0.05; done; sleep 2\",\"rows\":24,\"cols\":80}}\n",
            64 * 1024,
        );
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        victim_id = try allocator.dupe(u8, (result_val.object.get("id") orelse return error.MissingSessionId).string);
    }

    try waitForPaneOutput(allocator, live, victim_id, 4_000);

    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{flood_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readRpcResponseLineTimeout(allocator, client, 3, 64 * 1024, 4_000);
        defer allocator.free(line);
    }

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{victim_id},
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

test "attached clients receive pane output activity and bell notifications" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempSocketPath(allocator);
    defer allocator.free(socket_path);
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        pane_id = try allocator.dupe(u8, try expectStringField(result_val, "id"));
    }

    var client_a: ?posix.fd_t = try connectClient(socket_path);
    defer if (client_a) |fd| posix.close(fd);
    const client_b = try connectClient(socket_path);
    defer posix.close(client_b);

    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{pane_id},
        );
        defer allocator.free(req);
        try writeAll(client_a.?, req);
        const line = try readRpcResponseLine(allocator, client_a.?, 2, 1024 * 1024);
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
        try writeAll(client_b, req);
        const line = try readRpcResponseLine(allocator, client_b, 3, 1024 * 1024);
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

    const output_a = try readPaneOutputContaining(allocator, client_a.?, pane_id, "ZMUX_NOTIFY_ONE", 4_000);
    defer allocator.free(output_a);
    const output_b = try readPaneOutputContaining(allocator, client_b, pane_id, "ZMUX_NOTIFY_ONE", 4_000);
    defer allocator.free(output_b);
    try std.testing.expectEqualStrings(output_a, output_b);

    {
        const activity_a = try readNotificationLine(allocator, client_a.?, "pane_activity", pane_id, 4_000);
        defer allocator.free(activity_a);
        const activity_b = try readNotificationLine(allocator, client_b, "pane_activity", pane_id, 4_000);
        defer allocator.free(activity_b);
    }

    posix.close(client_a.?);
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
        const bell = try readNotificationLine(allocator, client_b, "pane_bell", pane_id, 4_000);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    // idle_timeout=0 means the server never self-exits due to idle; we drive
    // shutdown explicitly via daemon.shutdown.
    var server = try server_mod.Server.init(allocator, socket_path, 0);

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
        const client = try connectClient(socket_path);
        defer posix.close(client);

        try writeAll(client, "{\"id\":1,\"method\":\"daemon.ping\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 1, 64 * 1024);
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
        const client = try connectClient(socket_path);
        defer posix.close(client);

        // Pass a shell + command so pty.spawn builds a login-shell command
        // argv. This exercises RPC wiring plus PTY fd passing.
        try writeAll(
            client,
            "{\"id\":2,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"exec /bin/sh\",\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );

        const line = try readRpcResponseLine(allocator, client, 2, 64 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("error")) |_| {
            std.debug.print("session.create returned error: {s}\n", .{line});
            return error.SessionCreateFailed;
        }
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        try std.testing.expect(result_val == .object);
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        try std.testing.expect(id_val == .string);
        try std.testing.expect(id_val.string.len > 0);
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    // --- session.send "echo hi\n" ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"text\":\"echo hi\\n\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = try readRpcResponseLine(allocator, client, 3, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    // Give the shell a moment to echo.
    std.Thread.sleep(600 * std.time.ns_per_ms);

    // --- session.capture, expect "hi" to appear in the scrollback. ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":10}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = try readRpcResponseLine(allocator, client, 4, 1024 * 1024);
        defer allocator.free(line);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const text_val = result_val.object.get("text") orelse return error.MissingText;
        try std.testing.expect(text_val == .string);
        // The shell should have echoed "hi" (either in the echoed command or
        // in the command's output). We look for the substring "hi".
        try std.testing.expect(std.mem.indexOf(u8, text_val.string, "hi") != null);
    }

    // --- session.terminate ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);

        const line = try readRpcResponseLine(allocator, client, 5, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);
    }

    // --- daemon.shutdown: the server's run loop should exit. ---
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);

        try writeAll(client, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 6, 64 * 1024);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(
            client,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"echo REOPEN_SENTINEL_ONE; cat\"," ++
                "\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );
        const line = try readRpcResponseLine(allocator, client, 1, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    // Give the child a moment to emit the sentinel into the scrollback.
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // First logical attach: the replay should already contain the initial sentinel.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readRpcResponseLine(allocator, client, 2, 1024 * 1024);
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
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const send_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"session.send\",\"params\":" ++
                "{{\"sessionId\":\"{s}\",\"text\":\"REOPEN_SENTINEL_TWO\\n\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(send_req);
        try writeAll(client, send_req);
        const line = try readRpcResponseLine(allocator, client, 3, 64 * 1024);
        defer allocator.free(line);
    }

    // Let `cat` echo the input back to the PTY so the daemon captures it.
    std.Thread.sleep(500 * std.time.ns_per_ms);

    // Second attach: the replay must now carry BOTH sentinels.
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readRpcResponseLine(allocator, client, 4, 1024 * 1024);
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
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readRpcResponseLine(allocator, client, 5, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(client, "{\"id\":6,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 6, 64 * 1024);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        pane_id = try allocator.dupe(u8, try expectStringField(result_val, "id"));
    }

    const replay_cap = 256 * 1024;
    var decoded: []u8 = &.{};
    var saw_replay = false;
    const deadline = std.time.milliTimestamp() + 5_000;
    var rpc_id: i64 = 20;
    while (std.time.milliTimestamp() < deadline) : (rpc_id += 1) {
        const replay = try attachReplay(allocator, socket_path, pane_id, rpc_id);
        if (std.mem.endsWith(u8, replay, sentinel)) {
            decoded = replay;
            saw_replay = true;
            break;
        }
        allocator.free(replay);
        std.Thread.sleep(50 * std.time.ns_per_ms);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(
            client,
            "{\"id\":1,\"method\":\"session.create\",\"params\":" ++
                "{\"shell\":\"/bin/sh\",\"command\":\"echo AUTO_DETACH_SENTINEL; cat\"," ++
                "\"cwd\":\"/tmp\",\"rows\":24,\"cols\":80}}\n",
        );
        const line = try readRpcResponseLine(allocator, client, 1, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
        session_id_owned = try allocator.dupe(u8, id_val.string);
    }

    std.Thread.sleep(500 * std.time.ns_per_ms);

    {
        const client = try connectClient(socket_path);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":2,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readRpcResponseLine(allocator, client, 2, 1024 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.object.get("result") != null);

        // Simulate app/process death without an explicit client.detach RPC.
        posix.close(client);
    }

    try waitForClientCount(allocator, socket_path, 0, 2_000);

    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":3,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(attach_req);
        try writeAll(client, attach_req);

        const line = try readRpcResponseLine(allocator, client, 3, 1024 * 1024);
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
        const client = try connectClient(socket_path);
        defer posix.close(client);
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":4,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{session_id_owned},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readRpcResponseLine(allocator, client, 4, 64 * 1024);
        defer allocator.free(line);
    }
    {
        const client = try connectClient(socket_path);
        defer posix.close(client);
        try writeAll(client, "{\"id\":5,\"method\":\"daemon.shutdown\",\"params\":{}}\n");
        const line = try readRpcResponseLine(allocator, client, 5, 64 * 1024);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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

    std.Thread.sleep(600 * std.time.ns_per_ms);

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
        try expectNoRpcError(allocator, line);
    }
    {
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":50,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"work\",\"text\":\"stty size\\n\"}}}}\n",
            .{},
        );
        defer allocator.free(req);
        const line = try rpcLine(allocator, socket_path, req, 64 * 1024);
        defer allocator.free(line);
        try expectNoRpcError(allocator, line);
        const captured = try waitForCaptureContains(allocator, socket_path, returned_session_id, "24 80", 4_000);
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
        exited_pane_id = try allocator.dupe(u8, try expectStringField(result_val, "id"));
    }
    {
        const deadline = std.time.milliTimestamp() + 4_000;
        while (true) {
            if (std.time.milliTimestamp() >= deadline) return error.TerminatedPaneTimeout;
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
            std.Thread.sleep(20 * std.time.ns_per_ms);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        const id_val = result_val.object.get("id") orelse return error.MissingSessionId;
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
        const result_val = try responseResult(parsed.value);
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
        const result_val = try responseResult(parsed.value);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"split\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\"axis\":\"horizontal\"") != null);
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
        try std.testing.expectEqualStrings(first_pane_id, try expectStringField(result_val, "id"));
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
    var client_one_fd: ?posix.fd_t = null;
    defer if (client_one_fd) |fd| posix.close(fd);
    var client_two_fd: ?posix.fd_t = null;
    defer if (client_two_fd) |fd| posix.close(fd);
    {
        const client = try connectClient(socket_path);
        client_one_fd = client;
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":5,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":30,\"cols\":100}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readRpcResponseLine(allocator, client, 5, 64 * 1024);
        defer allocator.free(line);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const result_val = parsed.value.object.get("result") orelse return error.MissingResult;
        client_one = try allocator.dupe(u8, (result_val.object.get("clientId") orelse return error.MissingClientId).string);
    }

    {
        const client = try connectClient(socket_path);
        client_two_fd = client;
        const req = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":6,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":24,\"cols\":80}}}}\n",
            .{first_pane_id},
        );
        defer allocator.free(req);
        try writeAll(client, req);
        const line = try readRpcResponseLine(allocator, client, 6, 64 * 1024);
        defer allocator.free(line);
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
    try waitForSessionExited(allocator, client_two_fd.?, first_pane_id, 0, 4_000);
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
        if (client_one_fd) |fd| {
            posix.close(fd);
            client_one_fd = null;
        }
        if (client_two_fd) |fd| {
            posix.close(fd);
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
    std.fs.deleteFileAbsolute(socket_path) catch {};
    defer std.fs.deleteFileAbsolute(socket_path) catch {};

    var server = try server_mod.Server.init(allocator, socket_path, 0);
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
        const title_val = result_val.object.get("title") orelse return error.MissingTitle;
        try std.testing.expectEqualStrings("work", title_val.string);
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
