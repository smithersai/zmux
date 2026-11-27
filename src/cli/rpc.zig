//! UNIX-socket JSON-RPC 2.0 client for `zmux`: socket path resolution,
//! same-UID peer authentication, detached sibling `zmuxd` auto-spawn, and
//! NDJSON request/response exchange via `rpc_line_reader`.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const assert = std.debug.assert;
const connect_terminal = @import("../connect/terminal.zig");
const connect_wire = @import("../connect/wire.zig");
const protocol = @import("../protocol.zig");
const LineReader = @import("../rpc_line_reader.zig").LineReader;
const socket_path_mod = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const help = @import("help.zig");

const test_io = std.testing.io;

/// Maximum JSON-RPC response line size accepted from `zmuxd` (16 MiB).
pub const rpc_line_max: usize = connect_wire.rpc_line_max;

/// Default RPC response timeout in milliseconds.
pub const default_timeout_ms: i64 = 10_000;

/// Connection handshake timeout in milliseconds.
pub const connect_timeout_ms: i64 = 2_000;

/// Budget for a freshly spawned `zmuxd` daemon to bind and accept connections.
pub const spawn_timeout_ms: i64 = 4_000;

/// Parsed JSON-RPC response owning both its raw NDJSON line and parsed DOM.
pub const Response = struct {
    line: []u8,
    parsed: std.json.Parsed(std.json.Value),

    /// Release both the JSON DOM and the underlying line buffer.
    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.line);
    }

    /// Return the `result` member of the JSON-RPC envelope, or `.null`.
    pub fn result(self: Response) std.json.Value {
        return connect_wire.jsonField(self.parsed.value, "result");
    }

    /// Extract structured JSON-RPC error metadata if the envelope has `error`.
    pub fn rpcError(self: Response) ?help.RpcErrorDetail {
        const err = connect_wire.jsonField(self.parsed.value, "error");
        if (err != .object) return null;
        const code_val = connect_wire.jsonField(err, "code");
        const code: ?i64 = if (code_val == .integer) code_val.integer else null;
        const msg = connect_wire.jsonObjectString(err, "message") orelse "unknown RPC error";
        const kind = connect_wire.jsonObjectString(connect_wire.jsonField(err, "data"), "kind");
        assert(msg.len > 0);
        return .{ .code = code, .message = msg, .kind = kind };
    }
};

/// Monotonic deadline for one RPC request/response exchange.
pub const Deadline = struct {
    io: std.Io,
    at: std.Io.Clock.Timestamp,

    /// Create a deadline `timeout_ms` milliseconds from now.
    pub fn fromNow(io: std.Io, timeout_ms: i64) Deadline {
        assert(timeout_ms > 0);
        return .{ .io = io, .at = .fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake }) };
    }

    /// Remaining milliseconds until the deadline, clamped at zero.
    pub fn remainingMs(self: Deadline) i64 {
        const remaining_ns = self.at.durationFromNow(self.io).raw.toNanoseconds();
        const ms: i64 = @intCast(@max(0, remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        assert(ms >= 0);
        return ms;
    }

    /// Convert to `std.Io.Timeout` for `LineReader`.
    pub fn timeout(self: Deadline) std.Io.Timeout {
        return .{ .deadline = self.at };
    }
};

/// Authenticated UNIX-socket JSON-RPC client connected to `zmuxd`.
pub const RpcClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fd: posix.fd_t,
    reader: LineReader = .{},
    next_id: u32 = 1,

    /// Wrap an already-connected socket descriptor (e.g. from `socketPair` in tests).
    pub fn initFromFd(allocator: std.mem.Allocator, io: std.Io, fd: posix.fd_t) RpcClient {
        assert(fd >= 0);
        return .{ .allocator = allocator, .io = io, .fd = fd };
    }

    /// Connect to the daemon socket, auto-spawning `zmuxd` when `spawn_daemon` is true.
    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        socket_override: ?[]const u8,
        spawn_daemon: bool,
    ) !RpcClient {
        const path = try resolveSocketPath(allocator, io, socket_override);
        defer allocator.free(path);
        const fd = try connectWithRetry(allocator, io, path, spawn_daemon);
        assert(fd >= 3);
        return .{ .allocator = allocator, .io = io, .fd = fd };
    }

    /// Close the socket descriptor and free any buffered partial frame.
    pub fn deinit(self: *RpcClient) void {
        self.reader.deinit();
        if (self.fd >= 0) {
            sys.close(self.fd);
            self.fd = -1;
        }
    }

    /// Send one typed JSON-RPC request and wait for its correlated response.
    pub fn call(self: *RpcClient, method: []const u8, params: anytype, timeout_ms: i64) !Response {
        assert(method.len > 0 and timeout_ms > 0);
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        const frame = try connect_wire.buildFrame(self.allocator, id, method, params);
        defer self.allocator.free(frame);
        return self.exchange(id, method, frame, Deadline.fromNow(self.io, timeout_ms));
    }

    /// Send a JSON-RPC request using a pre-serialized JSON object for `params`.
    pub fn callRawParams(
        self: *RpcClient,
        method: []const u8,
        params_json: []const u8,
        timeout_ms: i64,
    ) !Response {
        assert(method.len > 0 and params_json.len >= 2 and timeout_ms > 0);
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        const frame = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":{f},\"params\":{s}}}\n",
            .{ id, std.json.fmt(method, .{}), params_json },
        );
        defer self.allocator.free(frame);
        return self.exchange(id, method, frame, Deadline.fromNow(self.io, timeout_ms));
    }

    /// Read the next newline-delimited JSON line from the daemon socket.
    pub fn readLineTimeout(self: *RpcClient, timeout_ms: ?i64) ![]u8 {
        assert(self.fd >= 0);
        if (timeout_ms) |ms| {
            const dl = Deadline.fromNow(self.io, ms);
            return self.reader.readLineAllocTimeout(self.allocator, self.io, self.fd, rpc_line_max, dl.timeout());
        }
        return self.reader.readLineAlloc(self.allocator, self.fd, rpc_line_max);
    }

    fn exchange(self: *RpcClient, id: u32, operation: []const u8, frame: []const u8, dl: Deadline) !Response {
        assert(frame.len > 0 and frame[frame.len - 1] == '\n');
        connect_terminal.sendFrame(self.fd, frame, dl.remainingMs()) catch |err| switch (err) {
            error.WriteTimeout => return help.diagnostic(self.io, "timed out sending {s}", .{operation}),
            error.BrokenPipe, error.ConnectionResetByPeer => {},
            else => return err,
        };
        return readResponse(self.allocator, &self.reader, self.fd, id, dl) catch |err| switch (err) {
            error.ReadTimeout => return help.diagnostic(self.io, "timed out waiting for {s}", .{operation}),
            else => return err,
        };
    }
};

/// Resolve and validate the daemon socket path following zmux precedence rules.
pub fn resolveSocketPath(allocator: std.mem.Allocator, io: std.Io, override: ?[]const u8) ![]u8 {
    const path = socket_path_mod.resolveUnvalidated(allocator, override, socket_path_mod.processEnv) catch |err| {
        return switch (err) {
            error.OutOfMemory => err,
            else => help.fail(io, "{s}", .{@errorName(err)}),
        };
    };
    errdefer allocator.free(path);
    socket_path_mod.validate(path) catch |err| switch (err) {
        error.SocketPathTooLong => return help.fail(
            io,
            "socket path too long ({d} > {d})",
            .{ path.len, sys.max_unix_path_len },
        ),
        else => return help.fail(io, "{s}", .{@errorName(err)}),
    };
    assert(path.len <= sys.max_unix_path_len);
    return path;
}

/// Connect to an existing daemon socket with peer-UID verification, or return the raw error.
pub fn tryConnectPeerVerified(io: std.Io, path: []const u8, deadline_ms: i64) !posix.fd_t {
    assert(path.len > 0 and path.len <= sys.max_unix_path_len);
    const connected = sys.connectUnixDeadline(path, deadline_ms) catch |err| switch (err) {
        error.Timeout, error.ConnectionTimedOut => {
            return help.diagnostic(io, "timed out connecting to daemon at {f}", .{help.escaped(path)});
        },
        else => return err,
    };
    const fd = try connect_terminal.moveAboveStdio(connected);
    errdefer sys.close(fd);
    assert(fd >= 3);
    sys.tuneUnixSocketBuffers(fd);

    const uid = sys.peerEuid(fd) catch {
        return help.diagnostic(io, "could not authenticate daemon at {f}", .{help.escaped(path)});
    };
    if (uid != sys.geteuid()) {
        return help.diagnostic(io, "socket at {f} is owned by uid {d}", .{ help.escaped(path), uid });
    }
    try verifyManagedParentIfDefault(io, path);
    try sys.setNonBlocking(fd);
    return fd;
}

fn verifyManagedParentIfDefault(io: std.Io, path: []const u8) !void {
    if (!socket_path_mod.isDefaultManaged(path, socket_path_mod.processEnv)) return;
    const parent = std.fs.path.dirname(path) orelse return;
    const dir = sys.openDirNoFollow(parent) catch |err| {
        return help.diagnostic(io, "cannot verify socket dir {f}: {s}", .{ help.escaped(parent), @errorName(err) });
    };
    defer sys.close(dir);
    const st = try sys.fstat(dir);
    if (!st.isDir() or st.uid != sys.geteuid() or st.permissions() & 0o077 != 0) {
        return help.diagnostic(io, "socket dir {f} must be 0700 owned by current user", .{help.escaped(parent)});
    }
}

/// Connect to the daemon socket, optionally spawning sibling `zmuxd` if absent.
pub fn connectWithRetry(allocator: std.mem.Allocator, io: std.Io, path: []const u8, spawn_daemon: bool) !posix.fd_t {
    const first_deadline = sys.monotonicMs() + connect_timeout_ms;
    if (tryConnectPeerVerified(io, path, first_deadline)) |fd| return fd else |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => {
            if (!spawn_daemon) {
                return help.diagnostic(io, "no daemon at {f} (run zmuxd or omit --no-spawn)", .{help.escaped(path)});
            }
        },
        else => return err,
    }

    if (sys.statAt(sys.cwd_fd, path, false)) |st| {
        if (!st.isSocket() or st.uid != sys.geteuid()) {
            return help.diagnostic(io, "refusing to replace socket path {f}", .{help.escaped(path)});
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const deadline = sys.monotonicMs() + spawn_timeout_ms;
    spawnDaemonDetached(allocator, io, path, deadline) catch |err| {
        if (err == error.ReportedFailure) return err;
        return help.diagnostic(io, "could not start zmuxd at {f}: {s}", .{ help.escaped(path), @errorName(err) });
    };
    while (sys.monotonicMs() < deadline) {
        if (tryConnectPeerVerified(io, path, deadline)) |fd| return fd else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => try io.sleep(.fromMilliseconds(50), .awake),
            else => return err,
        }
    }
    return help.diagnostic(io, "daemon at {f} did not become ready within 4s", .{help.escaped(path)});
}

/// Locate the `zmuxd` (or `smithers-session-daemon`) binary next to `self_dir` or on `PATH`.
pub fn findDaemonBinary(allocator: std.mem.Allocator, io: std.Io, self_dir: []const u8) !?[]u8 {
    assert(self_dir.len > 0);
    const names = [_][]const u8{ "zmuxd", "smithers-session-daemon" };
    for (names) |name| {
        const candidate = try std.fs.path.join(allocator, &.{ self_dir, name });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    const path_env = socket_path_mod.processEnv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        for (names) |name| {
            const candidate = try std.fs.path.join(allocator, &.{ dir, name });
            if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
                return candidate;
            } else |_| {
                allocator.free(candidate);
            }
        }
    }
    return null;
}

/// Open and verify the parent directory of a socket path before spawning `zmuxd`.
pub fn openSpawnParentDir(path: []const u8) !posix.fd_t {
    const parent = std.fs.path.dirname(path) orelse return error.NoSocketDirectory;
    if (socket_path_mod.isDefaultManaged(path, socket_path_mod.processEnv)) {
        return sys.ensurePrivateDir(parent);
    }
    _ = sys.statAt(sys.cwd_fd, parent, true) catch |err| switch (err) {
        error.FileNotFound => return sys.ensurePrivateDir(parent),
        else => return err,
    };
    const fd = try sys.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    errdefer sys.close(fd);
    const st = try sys.fstat(fd);
    const self_owned = st.uid == sys.geteuid();
    const trusted_sticky = (st.uid == 0 or self_owned) and (st.mode & 0o1000 != 0);
    if (!trusted_sticky and !(self_owned and st.mode & 0o022 == 0)) return error.InsecureSocketDirectory;
    return fd;
}

fn spawnDaemonDetached(allocator: std.mem.Allocator, io: std.Io, path: []const u8, deadline: i64) !void {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse ".";
    const daemon_path = (try findDaemonBinary(allocator, io, self_dir)) orelse {
        return help.diagnostic(io, "could not find zmuxd next to {f} or on PATH", .{help.escaped(self_path)});
    };
    defer allocator.free(daemon_path);

    const daemon_z = try allocator.dupeSentinel(u8, daemon_path, 0);
    defer allocator.free(daemon_z);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    const dir_fd = try connect_terminal.moveAboveStdio(try openSpawnParentDir(path));
    defer sys.close(dir_fd);
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{std.fs.path.basename(path)});
    defer allocator.free(log_name);
    const log_flags: posix.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true };
    const raw_log_fd = try sys.openOwnedRegularAt(dir_fd, log_name, log_flags, 0o600);
    const log_fd = try connect_terminal.moveAboveStdio(raw_log_fd);
    defer sys.close(log_fd);
    try sys.fchmod(log_fd, 0o600);
    const devnull_fd = try sys.openZ("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    const devnull = try connect_terminal.moveAboveStdio(devnull_fd);
    defer sys.close(devnull);

    try forkDoubleDetached(io, daemon_z.ptr, path_z.ptr, devnull, log_fd, deadline);
}

fn forkDoubleDetached(
    io: std.Io,
    daemon_z: [*:0]const u8,
    path_z: [*:0]const u8,
    devnull: posix.fd_t,
    log_fd: posix.fd_t,
    deadline: i64,
) !void {
    const argv = [_:null]?[*:0]const u8{ daemon_z, "--socket", path_z };
    const envp = sys.currentEnviron();
    const pipe_fds = try sys.pipe();
    const rd = connect_terminal.moveAboveStdio(pipe_fds[0]) catch |err| {
        sys.close(pipe_fds[1]);
        return err;
    };
    defer sys.close(rd);
    const wr = try connect_terminal.moveAboveStdio(pipe_fds[1]);
    assert(rd >= 3 and wr >= 3);

    const child = sys.fork() catch |err| {
        sys.close(wr);
        return err;
    };
    if (child == 0) {
        sys.close(rd);
        if (c.setsid() < 0) childExecFail(wr, "setsid");
        const grand = sys.fork() catch childExecFail(wr, "fork");
        if (grand != 0) c._exit(0);
        sys.dup2(devnull, 0) catch childExecFail(wr, "stdin");
        sys.dup2(devnull, 1) catch childExecFail(wr, "stdout");
        sys.dup2(log_fd, 2) catch childExecFail(wr, "stderr");
        if (wr != 3) sys.dup2(wr, 3) catch childExecFail(wr, "dup2");
        sys.setCloseOnExec(3) catch childExecFail(3, "cloexec");
        sys.closeFrom(4);
        sys.resetChildSignals();
        _ = c.execve(daemon_z, &argv, envp);
        childExecFail(3, "execve");
    }
    sys.close(wr);

    var status: c_int = 0;
    while (c.waitpid(child, &status, 0) < 0) {
        if (posix.errno(@as(c_int, -1)) != .INTR) return error.WaitFailed;
    }
    try connect_terminal.waitWritableOrReadable(rd, posix.POLL.IN, deadline);
    var buf: [32]u8 = undefined;
    const count = try posix.read(rd, &buf);
    if (count != 0) return help.diagnostic(io, "zmuxd startup failed during {f}", .{help.escaped(buf[0..count])});
    if (status != 0) return error.DaemonSpawnFailed;
}

fn childExecFail(fd: posix.fd_t, stage: []const u8) noreturn {
    _ = c.write(fd, stage.ptr, stage.len);
    c._exit(127);
}

/// Read NDJSON lines from `fd` until the response for `expected_id` or a null-id error arrives.
pub fn readResponse(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    expected_id: u32,
    dl: Deadline,
) !Response {
    assert(fd >= 0);
    while (dl.remainingMs() > 0) {
        const line = try reader.readLineAllocTimeout(allocator, dl.io, fd, rpc_line_max, dl.timeout());
        errdefer allocator.free(line);
        if (!connect_wire.mayHaveKey(line, "\"id\"")) {
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
        const resp_id = if (parsed.value == .object) parsed.value.object.get("id") else null;
        if (resp_id) |id| {
            const matched_id = (id == .integer and id.integer == expected_id);
            const null_err = (id == .null and connect_wire.jsonField(parsed.value, "error") == .object);
            if (matched_id or null_err) return .{ .line = line, .parsed = parsed };
        }
        parsed.deinit();
        allocator.free(line);
    }
    return error.ReadTimeout;
}

/// Query `daemon.ping` over an open `RpcClient` and return the parsed response.
pub fn ping(client: *RpcClient, timeout_ms: i64) !Response {
    return client.call("daemon.ping", .{}, timeout_ms);
}

test "RpcClient correlates responses and skips interleaved notifications" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);

    var client = RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"version\":\"0.4.0\"}}\n",
    );
    const resp = try client.call("daemon.ping", .{}, 1000);
    defer resp.deinit(alloc);
    try std.testing.expect(resp.rpcError() == null);
    try std.testing.expectEqualStrings("0.4.0", connect_wire.jsonObjectString(resp.result(), "version").?);
}

test "RpcClient parses -32601 MethodNotFound errors for v0.4.0 fallback" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);

    var client = RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"MethodNotFound\"," ++
            "\"data\":{\"kind\":\"method_not_found\"}}}\n",
    );
    const resp = try client.callRawParams("session.screen", "{\"sessionId\":\"work\"}", 1000);
    defer resp.deinit(alloc);
    const rpc_err = resp.rpcError().?;
    try std.testing.expect(rpc_err.isMethodNotFound());
    try std.testing.expectEqualStrings("MethodNotFound", rpc_err.message);
}

test "openSpawnParentDir accepts /tmp and verifies directory safety" {
    const fd = try openSpawnParentDir("/tmp/zmux-cli-rpc-test.sock");
    sys.close(fd);
}
