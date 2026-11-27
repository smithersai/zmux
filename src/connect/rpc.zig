//! Bootstrap JSON-RPC exchanges: deadlines, request and response matching,
//! attach or create, respawn, and the version handshake.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const LineReader = @import("../rpc_line_reader.zig").LineReader;
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
const wire = @import("wire.zig");

const Response = wire.Response;
const RpcError = wire.RpcError;
const jsonField = wire.jsonField;
const jsonObjectString = wire.jsonObjectString;
const requiredString = wire.requiredString;
const mayHaveKey = wire.mayHaveKey;
const buildFrame = wire.buildFrame;
const decodeReplay = wire.decodeReplay;
const rpc_line_max = wire.rpc_line_max;
const attach_rpc_id = wire.attach_rpc_id;
const ping_rpc_id = wire.ping_rpc_id;
const reportRpcError = cli.reportRpcError;
const diagnostic = cli.diagnostic;
const printDiagnostic = cli.printDiagnostic;
const escaped = cli.escaped;
const sendFrame = terminal.sendFrame;
const TerminalSize = terminal.TerminalSize;

const test_io = std.testing.io;

/// An absolute point on the monotonic clock for a bootstrap RPC exchange.
/// Carries the `Io` that reads the clock so call chains pass one value.
pub const Deadline = struct {
    io: std.Io,
    at: std.Io.Clock.Timestamp,
    notifications: ?*BootstrapNotifications = null,

    pub fn fromNow(io: std.Io, timeout_ms: i64) Deadline {
        return .{ .io = io, .at = .fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake }) };
    }

    pub fn remainingMs(self: Deadline) i64 {
        const remaining_ns = self.at.durationFromNow(self.io).raw.toNanoseconds();
        const remaining_ms: i64 = @intCast(@max(0, remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        assert(remaining_ms >= 0);
        return remaining_ms;
    }

    pub fn timeout(self: Deadline) std.Io.Timeout {
        return .{ .deadline = self.at };
    }
};

/// Attach to `target`, creating it first on daemons that ignore `createIfMissing`.
pub fn attachOrCreate(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    target: []const u8,
    size: TerminalSize,
    auto_create: bool,
    command: ?[]const u8,
    deadline: Deadline,
) !Response {
    // A new session starts in this client's working directory, not in the
    // daemon's.
    var cwd_buf: [posix.PATH_MAX]u8 = undefined;
    const create = if (auto_create) CreateParams{
        .id = target,
        .rows = size.rows,
        .cols = size.cols,
        .command = command,
        .cwd = currentDirectory(&cwd_buf),
    } else null;
    const response = try sendAttach(allocator, reader, fd, target, size, create, attach_rpc_id, deadline);
    if (create) |params| {
        if (response.rpcError()) |rpc_err| {
            if (rpc_err.is("not_found") or
                (rpc_err.kind == null and std.mem.eql(u8, rpc_err.message, "PaneNotFound")))
            {
                // Older daemons ignore createIfMissing.
                response.deinit(allocator);
                const created = try callRpc(allocator, reader, fd, 2, "session.create", params, deadline);
                defer created.deinit(allocator);
                if (created.rpcError()) |err| if (!err.is("conflict")) return reportRpcError(deadline.io, err);
                const retry = try sendAttach(allocator, reader, fd, target, size, null, 3, deadline);
                return validateAttach(allocator, deadline.io, retry);
            }
        }
    }
    return validateAttach(allocator, deadline.io, response);
}

const CreateParams = struct {
    id: []const u8,
    rows: u16,
    cols: u16,
    command: ?[]const u8,
    cwd: ?[]const u8 = null,
};

/// The working directory, or null when it is unavailable (removed, or
/// unreadable) or not valid UTF-8 for a JSON string.
fn currentDirectory(buf: *[posix.PATH_MAX]u8) ?[]const u8 {
    const ptr = std.c.getcwd(buf, buf.len) orelse return null;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(ptr)), 0);
    if (cwd.len == 0 or cwd[0] != '/' or !std.unicode.utf8ValidateSlice(cwd)) return null;
    return cwd;
}

fn sendAttach(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    target: []const u8,
    size: TerminalSize,
    create: ?CreateParams,
    id: u32,
    deadline: Deadline,
) !Response {
    return callRpc(allocator, reader, fd, id, "client.attach", .{
        .paneId = target,
        .rows = size.rows,
        .cols = size.cols,
        .createIfMissing = create,
    }, deadline);
}

fn validateAttach(allocator: std.mem.Allocator, io: std.Io, response: Response) !Response {
    errdefer response.deinit(allocator);
    if (response.rpcError()) |err| return reportRpcError(io, err);
    _ = try requiredString(response.result(), "paneId");
    _ = try requiredString(response.result(), "clientId");
    assert(response.rpcError() == null);
    return response;
}

/// Respawn an exited pane and attach to it again.
pub fn respawnAndReattach(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    result: std.json.Value,
    size: TerminalSize,
    deadline: Deadline,
) !Response {
    const pane_id = try requiredString(result, "paneId");
    const client_id = try requiredString(result, "clientId");
    assert(pane_id.len > 0 and client_id.len > 0);
    const respawn_params = .{ .paneId = pane_id, .kill = false };
    const respawned = try callRpc(allocator, reader, fd, 4, "pane.respawn", respawn_params, deadline);
    defer respawned.deinit(allocator);
    // Another client may have respawned the pane while we were printing replay.
    if (respawned.rpcError()) |err| if (!err.is("conflict")) return reportRpcError(deadline.io, err);
    const detached = try callRpc(allocator, reader, fd, 5, "client.detach", .{ .clientId = client_id }, deadline);
    defer detached.deinit(allocator);
    if (detached.rpcError()) |err| if (!err.is("not_found")) return reportRpcError(deadline.io, err);
    const attached = try sendAttach(allocator, reader, fd, pane_id, size, null, 6, deadline);
    return validateAttach(allocator, deadline.io, attached);
}

/// Send one request and wait for its response.
pub fn callRpc(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    id: u32,
    method: []const u8,
    params: anytype,
    deadline: Deadline,
) !Response {
    const frame = try buildFrame(allocator, id, method, params);
    defer allocator.free(frame);
    assert(frame[frame.len - 1] == '\n');
    return exchange(allocator, reader, fd, id, method, frame, deadline);
}

/// Send a prebuilt frame and wait for the response to `id`.
pub fn exchange(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    id: u32,
    operation: []const u8,
    frame: []const u8,
    deadline: Deadline,
) !Response {
    assert(frame.len > 0);
    assert(frame[frame.len - 1] == '\n');
    sendFrame(fd, frame, deadline.remainingMs()) catch |err| switch (err) {
        error.WriteTimeout => return diagnostic(deadline.io, "timed out sending {s}", .{operation}),
        // The daemon may close immediately after writing a null-id capacity
        // error. Read its pending response even when the write loses the race.
        error.BrokenPipe, error.ConnectionResetByPeer => {},
        else => return err,
    };
    return readRpcResponse(allocator, reader, fd, id, deadline) catch |err| switch (err) {
        error.ReadTimeout => return diagnostic(deadline.io, "timed out waiting for {s}", .{operation}),
        else => return err,
    };
}

/// Replay unmatched notifications through the normal pane, generation and
/// offset checks once the attach reply establishes the initial state.
pub const BootstrapNotifications = struct {
    lines: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,

    pub fn deinit(self: *BootstrapNotifications, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line);
        self.lines.deinit(allocator);
    }

    pub fn append(self: *BootstrapNotifications, allocator: std.mem.Allocator, line: []u8) !void {
        if (self.lines.items.len == 4096 or line.len > rpc_line_max - self.bytes)
            return error.TooManyBootstrapNotifications;
        try self.lines.append(allocator, line);
        self.bytes += line.len;
        assert(self.bytes <= rpc_line_max);
        assert(self.lines.items.len <= 4096);
    }
};

/// Read lines until the response to `expected_id` or a null-id error arrives.
pub fn readRpcResponse(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    expected_id: u32,
    deadline: Deadline,
) !Response {
    while (deadline.remainingMs() > 0) {
        const line = try reader.readLineAllocTimeout(allocator, deadline.io, fd, rpc_line_max, deadline.timeout());
        errdefer allocator.free(line);
        // Fast reject: a line without a backslash spells every key literally,
        // so it can only carry an `id` member if `"id"` appears verbatim.
        // Skips a DOM parse of every interleaved pane_output notification.
        if (!mayHaveKey(line, "\"id\"")) {
            if (deadline.notifications) |pending| {
                if (mayHaveKey(line, "\"method\"")) {
                    try pending.append(allocator, line);
                    continue;
                }
            }
            allocator.free(line);
            continue;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                allocator.free(line);
                continue;
            },
        };
        const response_id = if (parsed.value == .object) parsed.value.object.get("id") else null;
        if (response_id) |id| {
            if ((id == .integer and id.integer == expected_id) or
                (id == .null and RpcError.fromEnvelope(parsed.value) != null))
            {
                return .{ .line = line, .parsed = parsed };
            }
        }
        const notification = response_id == null and jsonObjectString(parsed.value, "method") != null;
        parsed.deinit();
        if (notification) {
            if (deadline.notifications) |pending| {
                try pending.append(allocator, line);
                continue;
            }
        }
        allocator.free(line);
    }
    return error.ReadTimeout;
}

/// Ping the daemon and warn when its protocol version differs.
pub fn warnOnVersionMismatch(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    deadline: Deadline,
) !void {
    const response = try callRpc(allocator, reader, fd, ping_rpc_id, "daemon.ping", .{}, deadline);
    defer response.deinit(allocator);
    if (response.rpcError()) |err| return reportRpcError(deadline.io, err);
    const daemon_ver = try requiredString(response.result(), "version");
    if (!std.mem.eql(u8, daemon_ver, protocol.version)) {
        printDiagnostic(
            deadline.io,
            "warning: daemon protocol {f} differs from client {s}; continuing",
            .{ escaped(daemon_ver), protocol.version },
        );
    }
}

test "RPC reads match numeric ids and accept null-id capacity errors" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"method\":\"pane_output\",\"params\":{}}\n" ++
        "{\"id\":1,\"result\":{\"stale\":true}}\n" ++
        "{\"id\":\"2\",\"result\":{\"stale\":true}}\n" ++
        "{\"id\":2,\"result\":{\"name\":\"error\"}}\n" ++
        "{\"id\":null,\"error\":{\"code\":-32000,\"message\":\"LimitExceeded\",\"data\":{\"kind\":\"limit\"}}}\n");
    var reader: LineReader = .{};
    defer reader.deinit();
    const deadline = Deadline.fromNow(test_io, 500);
    const success = try readRpcResponse(alloc, &reader, pair[0], 2, deadline);
    defer success.deinit(alloc);
    try std.testing.expect(success.rpcError() == null);
    try std.testing.expectEqualStrings("error", try requiredString(success.result(), "name"));
    const failure = try readRpcResponse(alloc, &reader, pair[0], 3, deadline);
    defer failure.deinit(alloc);
    try std.testing.expect(failure.rpcError().?.is("limit"));
    try std.testing.expectEqualStrings("LimitExceeded", failure.rpcError().?.message);
}

test "RPC read has an absolute timeout" {
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectError(error.ReadTimeout, readRpcResponse(std.testing.allocator, &reader, fds[0], 1, .fromNow(test_io, 20)));
}

test "attach sends createIfMissing in one frame and parses whitespace in replay" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"id\":1,\"result\":{\"paneId\":\"pane-1\",\"clientId\":\"client-1\",\"title\":\"error\",\"replayBase64\" : \"aGVsbG8=\"}}\n");
    var reader: LineReader = .{};
    defer reader.deinit();
    const deadline = Deadline.fromNow(test_io, 500);
    const response = try attachOrCreate(alloc, &reader, pair[0], "error", .{ .rows = 24, .cols = 80 }, true, "echo hi", deadline);
    defer response.deinit(alloc);
    const replay = (try decodeReplay(alloc, response.result())).?;
    defer alloc.free(replay);
    try std.testing.expectEqualStrings("hello", replay);
    var request_reader: LineReader = .{};
    defer request_reader.deinit();
    const request = try request_reader.readLineAllocTimeout(alloc, test_io, pair[1], rpc_line_max, deadline.timeout());
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    const create = jsonField(jsonField(parsed.value, "params"), "createIfMissing");
    try std.testing.expectEqualStrings("error", try requiredString(create, "id"));
    try std.testing.expectEqualStrings("echo hi", try requiredString(create, "command"));
}

test "attach requires both canonical IDs" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"id\":1,\"result\":{\"paneId\":\"pane-1\"}}\n");
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectError(error.InvalidResponse, attachOrCreate(alloc, &reader, pair[0], "work", .{ .rows = 24, .cols = 80 }, true, null, .fromNow(test_io, 500)));
}

test "legacy create fallback branches on kind, independent of the message" {
    const allocator = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"Missing target\",\"data\":{\"kind\":\"not_found\"}}}\n" ++
        "{\"id\":2,\"result\":{\"paneId\":\"p\"}}\n" ++
        "{\"id\":3,\"result\":{\"paneId\":\"p\",\"clientId\":\"c\"}}\n");
    var reader: LineReader = .{};
    defer reader.deinit();
    const response = try attachOrCreate(
        allocator,
        &reader,
        pair[0],
        "work",
        .{ .rows = 24, .cols = 80 },
        true,
        null,
        .fromNow(test_io, 500),
    );
    defer response.deinit(allocator);
    try std.testing.expectEqualStrings("p", try requiredString(response.result(), "paneId"));
}

test "legacy PaneNotFound retries attach through session.create" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\"}}\n" ++
        "{\"id\":2,\"result\":{}}\n" ++
        "{\"id\":3,\"result\":{\"paneId\":\"p\",\"clientId\":\"c\"}}\n");
    var reader: LineReader = .{};
    defer reader.deinit();
    const attached = try attachOrCreate(alloc, &reader, pair[0], "work", .{ .rows = 24, .cols = 80 }, true, null, .fromNow(test_io, 500));
    defer attached.deinit(alloc);
    try std.testing.expectEqualStrings("p", try requiredString(attached.result(), "paneId"));
}
