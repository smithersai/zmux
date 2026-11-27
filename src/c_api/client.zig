//! UNIX-socket JSON-RPC client implementation backing `zmux_client_*`.

const std = @import("std");

const protocol = @import("../protocol.zig");
const rpc_line_reader = @import("../rpc_line_reader.zig");
const socket_path = @import("../socket_path.zig");
const sys = @import("../sys.zig");

const Allocator = std.mem.Allocator;
const LineReader = rpc_line_reader.LineReader;
const assert = std.debug.assert;
const posix = std.posix;

/// Default connection timeout applied when the C caller passes `timeout_ms == 0`.
pub const default_connect_timeout_ms: u32 = 5_000;
/// Maximum JSON-RPC frame size accepted from the daemon (matches `connect.zig`).
pub const max_frame_bytes: usize = 16 * 1024 * 1024;
/// Upper bound on server notifications skipped during a single `callRaw`.
pub const max_skipped_notifications: usize = 4_096;

/// Typed errors mapped onto `zmux_status_t` at the FFI boundary.
pub const Error = error{
    InvalidArg,
    OutOfMemory,
    Io,
    Timeout,
    Protocol,
    PathTooLong,
    Closed,
    NotFound,
    PeerAuth,
};

/// Result of a completed JSON-RPC request/response exchange.
pub const CallResult = struct {
    /// Raw JSON frame (trailing newline removed), owned by caller's allocator.
    json: []u8,
    /// True when the response envelope carries a non-null `"error"` member.
    is_rpc_error: bool,
};

/// Opaque C handle representing an authenticated UNIX-socket zmux client.
pub const Handle = struct {
    allocator: Allocator,
    fd: sys.fd_t,
    reader: LineReader = .{},
    next_id: u64 = 1,

    /// Connect to `override_path` (or resolve default socket path), verify same-UID
    /// peer credentials, and return an allocated handle.
    pub fn connect(
        allocator: Allocator,
        override_path: ?[]const u8,
        timeout_ms: u32,
        getenv: socket_path.GetEnv,
    ) Error!*Handle {
        const resolved = socket_path.resolve(allocator, override_path, getenv) catch |err| {
            return mapPathError(err);
        };
        defer allocator.free(resolved);

        const wait_ms: i64 = if (timeout_ms == 0) default_connect_timeout_ms else timeout_ms;
        const deadline_ms = sys.monotonicMs() + wait_ms;
        const fd = sys.connectUnixDeadline(resolved, deadline_ms) catch |err| {
            return mapConnectError(err);
        };
        assert(fd >= 0);
        errdefer sys.close(fd);

        try verifyPeerUid(fd);
        sys.tuneUnixSocketBuffers(fd);
        return fromFd(allocator, fd);
    }

    /// Wrap an already-connected descriptor in a client handle (used by `connect` and tests).
    pub fn fromFd(allocator: Allocator, fd: sys.fd_t) Error!*Handle {
        assert(fd >= 0);
        const handle = allocator.create(Handle) catch return error.OutOfMemory;
        handle.* = .{ .allocator = allocator, .fd = fd };
        return handle;
    }

    /// Close the descriptor and free all buffered state and the handle itself.
    pub fn destroy(self: *Handle) void {
        assert(self.fd >= 0);
        const allocator = self.allocator;
        self.reader.deinit();
        sys.close(self.fd);
        self.fd = -1;
        allocator.destroy(self);
    }

    /// Read one newline-delimited JSON frame, stripping the trailing newline.
    pub fn readFrame(self: *Handle, allocator: Allocator, timeout_ms: u32) Error![]u8 {
        assert(self.fd >= 0);
        const io_deadline: ?std.Io.Timestamp = if (timeout_ms == 0)
            null
        else
            std.Io.Clock.awake.now(std.Options.debug_io).addDuration(
                .fromMilliseconds(@as(i64, timeout_ms)),
            );
        return self.readFrameUntil(allocator, io_deadline);
    }

    /// Send a JSON-RPC 2.0 request and wait for the matching response frame.
    pub fn callRaw(
        self: *Handle,
        allocator: Allocator,
        method: []const u8,
        params_json: ?[]const u8,
        timeout_ms: u32,
    ) Error!CallResult {
        assert(self.fd >= 0);
        if (method.len == 0) return error.InvalidArg;

        const id = self.next_id;
        self.next_id += 1;
        assert(id >= 1);

        const frame = try buildRequestFrame(allocator, id, method, params_json);
        defer allocator.free(frame);

        const deadline_ms: ?i64 = if (timeout_ms == 0) null else sys.monotonicMs() + @as(i64, timeout_ms);
        const io_deadline: ?std.Io.Timestamp = if (timeout_ms == 0)
            null
        else
            std.Io.Clock.awake.now(std.Options.debug_io).addDuration(
                .fromMilliseconds(@as(i64, timeout_ms)),
            );

        try sendFrameDeadline(self.fd, frame, deadline_ms);
        return self.awaitResponse(allocator, id, io_deadline);
    }

    fn awaitResponse(
        self: *Handle,
        allocator: Allocator,
        expected_id: u64,
        io_deadline: ?std.Io.Timestamp,
    ) Error!CallResult {
        var skipped: usize = 0;
        while (skipped <= max_skipped_notifications) : (skipped += 1) {
            const line = try self.readFrameUntil(allocator, io_deadline);
            errdefer allocator.free(line);
            const verdict = try classifyResponse(allocator, line, expected_id);
            switch (verdict) {
                .notification => allocator.free(line),
                .result => return .{ .json = line, .is_rpc_error = false },
                .rpc_error => return .{ .json = line, .is_rpc_error = true },
            }
        }
        return error.Protocol;
    }

    fn readFrameUntil(self: *Handle, allocator: Allocator, io_deadline: ?std.Io.Timestamp) Error![]u8 {
        assert(self.fd >= 0);
        const maybe = if (io_deadline) |dl|
            self.reader.readFrameAllocMaybeDeadline(allocator, self.fd, max_frame_bytes, dl)
        else
            self.reader.readFrameAllocMaybe(allocator, self.fd, max_frame_bytes);

        const raw = maybe catch |err| return mapReadError(err);
        const line = raw orelse return error.Closed;
        errdefer allocator.free(line);
        if (line.len == 0 or line[line.len - 1] != '\n') return error.Protocol;
        const trimmed = allocator.dupe(u8, line[0 .. line.len - 1]) catch return error.OutOfMemory;
        allocator.free(line);
        return trimmed;
    }
};

const ResponseVerdict = enum { notification, result, rpc_error };

fn classifyResponse(allocator: Allocator, line: []const u8, expected_id: u64) Error!ResponseVerdict {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Protocol,
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.Protocol;
    const obj = parsed.value.object;
    const id_val = obj.get("id") orelse return .notification;
    if (id_val != .integer or id_val.integer < 0) return error.Protocol;
    if (@as(u64, @intCast(id_val.integer)) != expected_id) return error.Protocol;

    if (obj.get("error")) |err_val| {
        if (err_val != .null) return .rpc_error;
    }
    if (obj.get("result") != null) return .result;
    return error.Protocol;
}

/// Serialize a single-line JSON-RPC 2.0 request frame, validating `params_json`.
pub fn buildRequestFrame(
    allocator: Allocator,
    id: u64,
    method: []const u8,
    params_json: ?[]const u8,
) Error![]u8 {
    assert(method.len > 0);
    assert(id >= 1);
    const raw_params = params_json orelse "{}";
    if (raw_params.len == 0 or raw_params.len > max_frame_bytes) return error.InvalidArg;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_params, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArg,
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .object, .array, .null => {},
        else => return error.InvalidArg,
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
    protocol.writeJsonStringLossy(&out.writer, method) catch return error.OutOfMemory;
    out.writer.writeAll(",\"params\":") catch return error.OutOfMemory;
    std.json.Stringify.value(parsed.value, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll("}\n") catch return error.OutOfMemory;
    const slice = out.toOwnedSlice() catch return error.OutOfMemory;
    assert(slice.len > 0 and slice[slice.len - 1] == '\n');
    return slice;
}

fn verifyPeerUid(fd: sys.fd_t) Error!void {
    assert(fd >= 0);
    const peer_uid = sys.peerEuid(fd) catch return error.PeerAuth;
    if (peer_uid != sys.geteuid()) return error.PeerAuth;
}

fn sendFrameDeadline(fd: sys.fd_t, frame: []const u8, deadline_ms: ?i64) Error!void {
    assert(fd >= 0);
    assert(frame.len > 0);
    var offset: usize = 0;
    while (offset < frame.len) {
        if (deadline_ms) |dl| {
            try waitWritableUntil(fd, dl);
        }
        const n = sys.send(fd, frame[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            error.BrokenPipe, error.ConnectionResetByPeer => return error.Closed,
            else => return error.Io,
        };
        if (n == 0) return error.Closed;
        offset += n;
    }
    assert(offset == frame.len);
}

fn waitWritableUntil(fd: sys.fd_t, deadline_ms: i64) Error!void {
    assert(fd >= 0);
    while (true) {
        const rem = deadline_ms - sys.monotonicMs();
        if (rem <= 0) return error.Timeout;
        const step: i32 = @intCast(@min(rem, std.math.maxInt(i32)));
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
        const ready = posix.poll(&fds, step) catch return error.Io;
        if (ready == 0) continue;
        if ((fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL)) != 0 and
            (fds[0].revents & posix.POLL.OUT) == 0)
        {
            return error.Closed;
        }
        return;
    }
}

fn mapPathError(err: socket_path.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SocketPathTooLong => error.PathTooLong,
        error.EmptySocketPath, error.SocketPathContainsNul => error.InvalidArg,
        error.NoSocketDirectory, error.CurrentDirUnavailable => error.Io,
    };
}

fn mapConnectError(err: anyerror) Error {
    return switch (err) {
        error.Timeout, error.ConnectionTimedOut => error.Timeout,
        error.FileNotFound, error.NotDir => error.NotFound,
        error.NameTooLong => error.PathTooLong,
        else => error.Io,
    };
}

fn mapReadError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadTimeout => error.Timeout,
        error.ConnectionClosed, error.ConnectionResetByPeer, error.BrokenPipe => error.Closed,
        error.TruncatedFrame, error.MessageTooLarge => error.Protocol,
        else => error.Io,
    };
}

test "buildRequestFrame emits single-line valid JSON and rejects malformed params" {
    const frame = try buildRequestFrame(std.testing.allocator, 7, "daemon.ping", "{\"a\": 1,\n\"b\": \"x\\ny\"}");
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(u8, '\n'), frame[frame.len - 1]);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, frame[0 .. frame.len - 1], '\n'));

    try std.testing.expectError(error.InvalidArg, buildRequestFrame(std.testing.allocator, 1, "m", "{bad"));
    try std.testing.expectError(error.InvalidArg, buildRequestFrame(std.testing.allocator, 1, "m", "{\"b\":\"x\ny\"}"));
    try std.testing.expectError(error.InvalidArg, buildRequestFrame(std.testing.allocator, 1, "m", "123"));
    try std.testing.expectError(error.InvalidArg, buildRequestFrame(std.testing.allocator, 1, "m", ""));
}

test "client callRaw skips notifications and parses result or rpc_error" {
    const socks = try sys.socketPair();
    const client = try Handle.fromFd(std.testing.allocator, socks[0]);
    defer client.destroy();
    defer sys.close(socks[1]);

    try sys.sendAll(
        socks[1],
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"nope\"}}\n",
    );

    const ok_res = try client.callRaw(std.testing.allocator, "daemon.ping", null, 500);
    defer std.testing.allocator.free(ok_res.json);
    try std.testing.expect(!ok_res.is_rpc_error);
    try std.testing.expect(std.mem.indexOf(u8, ok_res.json, "\"ok\":true") != null);

    const err_res = try client.callRaw(std.testing.allocator, "unknown.method", "{}", 500);
    defer std.testing.allocator.free(err_res.json);
    try std.testing.expect(err_res.is_rpc_error);
    try std.testing.expect(std.mem.indexOf(u8, err_res.json, "-32601") != null);
}

test "client readFrame detects timeout, closed peer, and protocol errors" {
    const socks = try sys.socketPair();
    const client = try Handle.fromFd(std.testing.allocator, socks[0]);
    defer client.destroy();

    try std.testing.expectError(error.Timeout, client.readFrame(std.testing.allocator, 15));

    try sys.sendAll(socks[1], "{\"jsonrpc\":\"2.0\",\"method\":\"pane_bell\"}\n");
    const frame = try client.readFrame(std.testing.allocator, 200);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"pane_bell\"}", frame);

    sys.close(socks[1]);
    try std.testing.expectError(error.Closed, client.readFrame(std.testing.allocator, 200));
}

test "verifyPeerUid accepts same-uid socketPair" {
    const socks = try sys.socketPair();
    defer sys.close(socks[0]);
    defer sys.close(socks[1]);
    try verifyPeerUid(socks[0]);
}
