const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const log = @import("../log.zig");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const posix = std.posix;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const fuzz_hooks_mod = @import("fuzz_hooks.zig");
const ClientConnection = connection_mod.ClientConnection;
const Server = server_mod.Server;
const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;

/// I/O implementation shared by server tests.
pub const test_io = std.testing.io;

/// Environment lookup that finds nothing.
pub fn noEnv(_: []const u8) ?[]const u8 {
    return null;
}

/// Sleep `ms` milliseconds, logging instead of failing on error.
pub fn sleepMs(ms: i64) void {
    test_io.sleep(.fromMilliseconds(ms), .awake) catch |err| {
        log.debug("test_sleep_failed", .{ .err = err });
    };
}

/// Poll `flag` until true or `timeout_ms` passes. Returns its final value.
pub fn waitForFlag(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    assert(timeout_ms > 0);
    const deadline = sys.monotonicMs() + timeout_ms;
    while (sys.monotonicMs() < deadline) {
        if (flag.load(.seq_cst)) return true;
        sleepMs(5);
    }
    return flag.load(.seq_cst);
}

/// Read one newline-terminated line within `timeout_ms`. The caller frees it.
pub fn readLineTimeout(allocator: Allocator, fd: posix.fd_t, timeout_ms: i64) ![]u8 {
    assert(fd >= 0);
    assert(timeout_ms > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const deadline = sys.monotonicMs() + timeout_ms;
    var byte: [1]u8 = undefined;
    while (true) {
        const remaining = deadline - sys.monotonicMs();
        if (remaining <= 0) return error.ReadTimeout;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, @intCast(remaining)) == 0) return error.ReadTimeout;
        // A peer that closed with unread input reports a reset, not EOF.
        const n = posix.read(fd, &byte) catch |err| {
            const any_err: anyerror = err;
            if (any_err == error.ConnectionResetByPeer) return error.EndOfStream;
            return err;
        };
        if (n == 0) return error.EndOfStream;
        try out.append(allocator, byte[0]);
        if (byte[0] == '\n') return out.toOwnedSlice(allocator);
    }
}

/// Parse `text` into a JSON value owned by the testing allocator.
pub fn parseJson(text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, std.testing.allocator, text, .{ .allocate = .alloc_always });
}

/// A client on one end of a socketpair, served by `driveClient` on a thread.
pub const TestClient = struct {
    fd: posix.fd_t,
    thread: std.Thread,

    pub fn start(server: *Server) !TestClient {
        const fds = try sys.socketPair();
        errdefer sys.close(fds[1]);
        assert(fds[0] >= 0 and fds[1] >= 0);
        assert(fds[0] != fds[1]);
        // Pane children fork from this process: keep them from inheriting
        // either end.
        for (fds) |end| sys.setCloseOnExec(end) catch |err| {
            log.debug("test_cloexec_failed", .{ .err = err });
        };
        const thread = std.Thread.spawn(.{}, drive, .{ server, fds[0] }) catch |err| {
            sys.close(fds[0]);
            return err;
        };
        return .{ .fd = fds[1], .thread = thread };
    }

    pub fn drive(server: *Server, fd: posix.fd_t) void {
        fuzz_hooks.driveClient(server, fd) catch |err| {
            log.debug("test_drive_client_failed", .{ .err = err });
        };
    }

    pub fn stop(self: *TestClient) void {
        assert(self.fd >= 0);
        // Shut down first: a forked child that still holds a duplicate of
        // this descriptor must not keep the server side waiting for EOF.
        _ = std.c.shutdown(self.fd, @intCast(posix.SHUT.RDWR));
        sys.close(self.fd);
        self.thread.join();
    }

    pub fn send(self: *TestClient, bytes: []const u8) !void {
        try sys.writeAll(self.fd, bytes);
    }

    pub fn sendFmt(self: *TestClient, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
        defer std.testing.allocator.free(text);
        try self.send(text);
    }

    pub fn nextLine(self: *TestClient) !std.json.Parsed(Value) {
        const line = try readLineTimeout(std.testing.allocator, self.fd, 5000);
        defer std.testing.allocator.free(line);
        return parseJson(line);
    }

    /// The response to request `id`, skipping notifications.
    pub fn response(self: *TestClient, id: i64) !std.json.Parsed(Value) {
        while (true) {
            var parsed = try self.nextLine();
            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |got| {
                    if (got == .integer and got.integer == id) return parsed;
                }
            }
            parsed.deinit();
        }
    }

    /// The next notification named `method`, skipping everything else.
    pub fn notification(self: *TestClient, method: []const u8) !std.json.Parsed(Value) {
        while (true) {
            var parsed = try self.nextLine();
            if (parsed.value == .object) {
                if (parsed.value.object.get("method")) |got| {
                    if (got == .string and std.mem.eql(u8, got.string, method)) return parsed;
                }
            }
            parsed.deinit();
        }
    }
};

/// The `result` object of a parsed response; fails on an error or non-object result.
pub fn resultOf(parsed: *const std.json.Parsed(Value)) !std.json.ObjectMap {
    if (parsed.value.object.get("error")) |_| return error.UnexpectedRpcError;
    const result = parsed.value.object.get("result") orelse return error.MissingResult;
    if (result != .object) return error.ResultNotObject;
    return result.object;
}

/// Expect a parsed response to be an error with this code, kind, and message.
pub fn expectRpcError(parsed: *const std.json.Parsed(Value), code: i64, kind: []const u8, message: []const u8) !void {
    const err_val = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expectEqual(code, err_val.object.get("code").?.integer);
    try std.testing.expectEqualStrings(message, err_val.object.get("message").?.string);
    try std.testing.expectEqualStrings(kind, err_val.object.get("data").?.object.get("kind").?.string);
}

/// A registered connection with no reader or writer thread: tests drain its
/// queue with `tryTakeQueuedWrite`.
pub const QueueProbe = struct {
    server: *Server,
    connection: *ClientConnection,
    peer_fd: posix.fd_t,

    pub fn init(server: *Server) !QueueProbe {
        const fds = try sys.socketPair();
        errdefer sys.close(fds[1]);
        const connection = ClientConnection.create(std.testing.allocator, test_io, fds[0], null) catch |err| {
            sys.close(fds[0]);
            return err;
        };
        errdefer connection.release();
        assert(connection.fd == fds[0]);
        if (!server.registerConnection(connection)) return error.ServerStopping;
        return .{ .server = server, .connection = connection, .peer_fd = fds[1] };
    }

    pub fn deinit(self: *QueueProbe) void {
        self.server.unregisterConnection(self.connection);
        self.connection.release();
        sys.close(self.peer_fd);
    }

    /// Next queued frame, or null. The caller frees it.
    pub fn take(self: *QueueProbe) ?[]u8 {
        return fuzz_hooks.takeQueuedWrite(self.connection);
    }

    pub fn expectNext(self: *QueueProbe, needles: []const []const u8) !void {
        const frame = self.take() orelse return error.NothingQueued;
        defer std.testing.allocator.free(frame);
        for (needles) |needle| {
            if (std.mem.indexOf(u8, frame, needle) == null) {
                log.err("test_frame_mismatch", .{ .frame = frame[0..@min(frame.len, 300)], .needle = needle });
                return error.FrameMismatch;
            }
        }
    }

    pub fn expectEmpty(self: *QueueProbe) !void {
        if (self.take()) |frame| {
            defer std.testing.allocator.free(frame);
            log.err("test_unexpected_frame", .{ .frame = frame[0..@min(frame.len, 300)] });
            return error.UnexpectedFrame;
        }
    }
};

/// Inject a `pane_output` native event for `pane_id` into `server`.
pub fn emitOutput(server: *Server, pane_id: []const u8, data: []const u8, offset: u64) void {
    Server.handleNativeEvent(server, .{ .pane_output = .{
        .pane_id = pane_id,
        .data = data,
        .offset = offset,
        .generation = 3,
    } });
}

/// Unique socket path under the system temp directory. Caller frees it.
pub fn tempPath(allocator: Allocator, prefix: []const u8) ![]u8 {
    assert(prefix.len > 0);
    assert(std.mem.indexOfScalar(u8, prefix, '/') == null);
    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}-{x:0>16}", .{ root, prefix, nonce });
}

/// `<parent>/ssss…` padded to exactly `total_len` bytes.
pub fn paddedSocketPath(allocator: Allocator, parent: []const u8, total_len: usize) ![]u8 {
    assert(parent.len + 1 < total_len);
    const path = try allocator.alloc(u8, total_len);
    @memset(path, 's');
    @memcpy(path[0..parent.len], parent);
    path[parent.len] = '/';
    assert(path.len == total_len);
    return path;
}

/// Number of entries in the directory at `path`.
pub fn countDirEntries(path: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(test_io, path, .{ .iterate = true });
    defer dir.close(test_io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(test_io)) |_| count += 1;
    return count;
}

/// Entries in `dir_path` whose name starts with `prefix`: the socket itself
/// plus anything a failed bind left beside it.
pub fn countMatchingEntries(dir_path: []const u8, prefix: []const u8) !usize {
    var dir = try std.Io.Dir.openDirAbsolute(test_io, dir_path, .{ .iterate = true });
    defer dir.close(test_io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(test_io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) count += 1;
    }
    return count;
}

/// True when `entries` holds `expected` exactly.
pub fn envContains(entries: []const []const u8, expected: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, expected)) return true;
    }
    return false;
}

/// Bind and listen on a UNIX socket at `path` without the server's safety checks.
pub fn bindRawUnixListener(path: []const u8) !posix.fd_t {
    const address = try sys.UnixAddress.init(path);
    const listener = try sys.unixStreamSocket();
    errdefer sys.close(listener);
    try sys.bind(listener, &address);
    try sys.listen(listener, 1);
    return listener;
}

/// Skip the test when the sandbox forbids binding a UNIX socket at `path`.
pub fn requireUnixSocketBind(path: []const u8) !void {
    const listener = bindRawUnixListener(path) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    sys.close(listener);
    deleteTestFile(path);
}

/// Best-effort removal of a test socket or file; a failure is only logged.
pub fn deleteTestFile(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(test_io, path) catch |err| {
        log.debug("test_file_delete_failed", .{ .err = err });
    };
}

/// True when an entry exists at `path`.
pub fn socketExists(path: []const u8) bool {
    _ = socketPathStat(path) catch return false;
    return true;
}

/// Stat of `path` itself, without following a final symlink.
pub fn socketPathStat(path: []const u8) !sys.Stat {
    return sys.statAt(sys.cwd_fd, path, false);
}

/// `chmod(2)` on an absolute path.
pub fn chmodAbsolute(allocator: Allocator, path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

/// Permission bits of the directory at `path`.
pub fn dirMode(path: []const u8) !u32 {
    const stat = try sys.statAt(sys.cwd_fd, path, true);
    return stat.permissions();
}
