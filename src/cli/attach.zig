//! Interactive terminal attach for `zmux`: auto-spawns `zmuxd` by default,
//! supports `--readonly`, `--replay raw|vt`, `--detach-key`, `--no-create`,
//! `--command`, offset resumption for `zmux ssh`, and raw-mode restoration.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const connect_events = @import("../connect/events.zig");
const connect_terminal = @import("../connect/terminal.zig");
const connect_wire = @import("../connect/wire.zig");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const args_mod = @import("args.zig");
const help = @import("help.zig");
const rpc = @import("rpc.zig");

const test_io = std.testing.io;

/// Configuration for one interactive attach session (local or SSH-tunneled).
pub const AttachOptions = struct {
    target: []const u8,
    socket_path: ?[]const u8 = null,
    spawn_daemon: bool = true,
    auto_create: bool = true,
    command: ?[]const u8 = null,
    detach_key: ?u8 = args_mod.default_detach_key,
    read_only: bool = false,
    replay: args_mod.ReplayMode = .raw,
    resume_from_offset: ?u64 = null,
    resume_generation: ?u64 = null,
    report_outcome: bool = true,
};

/// Result of one attach session, including latest stream coordinates for resume.
pub const AttachResult = struct {
    outcome: connect_events.RunOutcome,
    pane_id: ?[]u8 = null,
    last_generation: ?u64 = null,
    last_offset: ?u64 = null,

    /// Free the owned `pane_id`, if any.
    pub fn deinit(self: *AttachResult, allocator: std.mem.Allocator) void {
        if (self.pane_id) |p| allocator.free(p);
        self.pane_id = null;
    }
};

/// Run `zmux [attach] <name>` from parsed CLI arguments.
pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.ParsedArgs) !void {
    const target = parsed.target orelse return help.fail(io, "session name is required", .{});
    assert(target.len > 0);
    var res = try attachSession(allocator, io, .{
        .target = target,
        .socket_path = parsed.socket_path,
        .spawn_daemon = parsed.spawn_daemon,
        .auto_create = parsed.auto_create,
        .command = parsed.cmd_text,
        .detach_key = parsed.detach_key,
        .read_only = parsed.read_only,
        .replay = parsed.replay,
        .report_outcome = true,
    });
    defer res.deinit(allocator);
}

/// Connect to the daemon and attach interactively, returning stream cursor state.
pub fn attachSession(allocator: std.mem.Allocator, io: std.Io, opts: AttachOptions) !AttachResult {
    assert(opts.target.len > 0);
    var client = try rpc.RpcClient.connect(allocator, io, opts.socket_path, opts.spawn_daemon);
    defer client.deinit();

    try warnVersionMismatch(&client);
    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;
    const is_tty = sys.isatty(stdin_fd);
    const size = connect_terminal.currentTerminalSize(stdout_fd, stdin_fd) orelse
        connect_terminal.TerminalSize{ .rows = 24, .cols = 80 };
    assert(size.rows > 0 and size.cols > 0);

    var attached = try attachOrCreate(&client, opts, size);
    defer attached.deinit(allocator);

    const setup = connect_terminal.enterTerminalGuarded(stdin_fd, stdout_fd, is_tty);
    defer connect_terminal.leaveTerminal();
    try setup;

    try connect_terminal.replayScrollback(allocator, attached.result(), stdout_fd);
    if (!opts.read_only and attachExited(attached)) {
        try respawnIfExited(&client, &attached, opts, size, stdout_fd);
        if (attachExited(attached)) {
            connect_terminal.leaveTerminal();
            if (opts.report_outcome) try help.stderrWrite(io, "session ended\n");
            return .{ .outcome = .session_ended };
        }
    }

    const pane_id = try connect_wire.requiredString(attached.result(), "paneId");
    const client_id = try connect_wire.requiredString(attached.result(), "clientId");
    var state: connect_events.RunState = .{
        .pane_id = pane_id,
        .client_id = client_id,
        .generation = connect_wire.jsonUnsigned(attached.result(), "generation"),
        .next_offset = connect_wire.jsonUnsigned(attached.result(), "replayEndOffset"),
    };
    defer if (state.switched_pane) |p| allocator.free(p);
    defer state.pending_sends.deinit(allocator);

    const outcome = try runTrackedLoop(
        allocator,
        &client,
        &state,
        stdin_fd,
        stdout_fd,
        if (is_tty) opts.detach_key else null,
        opts.read_only,
        !is_tty,
    );
    connect_terminal.leaveTerminal();
    if (opts.report_outcome) try reportOutcome(io, outcome);
    return .{
        .outcome = outcome,
        .pane_id = try allocator.dupe(u8, state.pane_id),
        .last_generation = state.generation,
        .last_offset = state.next_offset,
    };
}

fn warnVersionMismatch(client: *rpc.RpcClient) !void {
    const resp = try rpc.ping(client, rpc.connect_timeout_ms);
    defer resp.deinit(client.allocator);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    const ver = connect_wire.jsonObjectString(resp.result(), "version") orelse return;
    if (!std.mem.eql(u8, ver, protocol.version)) {
        help.printDiagnostic(
            client.io,
            "warning: daemon protocol {f} differs from client {s}",
            .{ help.escaped(ver), protocol.version },
        );
    }
}

fn attachOrCreate(
    client: *rpc.RpcClient,
    opts: AttachOptions,
    size: connect_terminal.TerminalSize,
) !rpc.Response {
    var cwd_buf: [posix.PATH_MAX]u8 = undefined;
    const cwd = currentDir(&cwd_buf);
    const create_if_missing = if (opts.auto_create and !opts.read_only) CreateSpec{
        .id = opts.target,
        .rows = size.rows,
        .cols = size.cols,
        .command = opts.command,
        .cwd = cwd,
    } else null;

    const resp = try sendAttachRpc(client, opts, size, create_if_missing);
    if (create_if_missing) |spec| {
        if (resp.rpcError()) |rpc_err| {
            if (rpc_err.isKind("not_found") or std.mem.eql(u8, rpc_err.message, "PaneNotFound")) {
                resp.deinit(client.allocator);
                const created = try client.call("session.create", spec, rpc.default_timeout_ms);
                defer created.deinit(client.allocator);
                if (created.rpcError()) |e| if (!e.isKind("conflict")) return help.reportRpcError(client.io, e);
                const retry = try sendAttachRpc(client, opts, size, null);
                return validateAttach(client, retry);
            }
        }
    }
    return validateAttach(client, resp);
}

const CreateSpec = struct {
    id: []const u8,
    rows: u16,
    cols: u16,
    command: ?[]const u8,
    cwd: ?[]const u8 = null,
};

fn sendAttachRpc(
    client: *rpc.RpcClient,
    opts: AttachOptions,
    size: connect_terminal.TerminalSize,
    create: ?CreateSpec,
) !rpc.Response {
    assert(opts.target.len > 0 and size.rows > 0 and size.cols > 0);
    const replay_str: ?[]const u8 = if (opts.replay == .vt) "vt" else null;
    return client.call("client.attach", .{
        .paneId = opts.target,
        .rows = size.rows,
        .cols = size.cols,
        .createIfMissing = create,
        .readOnly = if (opts.read_only) true else null,
        .resizePolicy = if (opts.read_only) "none" else null,
        .replayMode = replay_str,
        .resumeFromOffset = opts.resume_from_offset,
        .resumeGeneration = opts.resume_generation,
    }, rpc.default_timeout_ms);
}

fn validateAttach(client: *rpc.RpcClient, resp: rpc.Response) !rpc.Response {
    errdefer resp.deinit(client.allocator);
    if (resp.rpcError()) |err| return help.reportRpcError(client.io, err);
    const pid = try connect_wire.requiredString(resp.result(), "paneId");
    const cid = try connect_wire.requiredString(resp.result(), "clientId");
    assert(pid.len > 0 and cid.len > 0);
    return resp;
}

fn respawnIfExited(
    client: *rpc.RpcClient,
    attached: *rpc.Response,
    opts: AttachOptions,
    size: connect_terminal.TerminalSize,
    stdout_fd: posix.fd_t,
) !void {
    const pane_id = try connect_wire.requiredString(attached.result(), "paneId");
    const client_id = try connect_wire.requiredString(attached.result(), "clientId");
    assert(pane_id.len > 0 and client_id.len > 0);
    const resp = try client.call("pane.respawn", .{ .paneId = pane_id, .kill = false }, rpc.default_timeout_ms);
    defer resp.deinit(client.allocator);
    if (resp.rpcError()) |err| if (!err.isKind("conflict")) return help.reportRpcError(client.io, err);
    const det = try client.call("client.detach", .{ .clientId = client_id }, rpc.default_timeout_ms);
    defer det.deinit(client.allocator);
    const next = try validateAttach(client, try sendAttachRpc(client, opts, size, null));
    attached.deinit(client.allocator);
    attached.* = next;
    try connect_terminal.replayScrollback(client.allocator, attached.result(), stdout_fd);
}

fn attachExited(resp: rpc.Response) bool {
    const ex = connect_wire.jsonField(resp.result(), "exited");
    return ex == .bool and ex.bool;
}

fn currentDir(buf: *[posix.PATH_MAX]u8) ?[]const u8 {
    const ptr = std.c.getcwd(buf, buf.len) orelse return null;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(ptr)), 0);
    if (cwd.len == 0 or cwd[0] != '/' or !std.unicode.utf8ValidateSlice(cwd)) return null;
    return cwd;
}

fn reportOutcome(io: std.Io, outcome: connect_events.RunOutcome) !void {
    switch (outcome) {
        .detached => try help.stderrWrite(io, "[detached]\n"),
        .detached_remotely => try help.stderrWrite(io, "[detached remotely]\n"),
        .session_ended => try help.stderrWrite(io, "session ended\n"),
        .connection_lost => return help.diagnostic(io, "daemon connection lost", .{}),
        .exited => {},
    }
}

/// Interactive loop that tracks exact `generation` / `next_offset` and enforces `--readonly`.
pub fn runTrackedLoop(
    allocator: std.mem.Allocator,
    client: *rpc.RpcClient,
    state: *connect_events.RunState,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    detach_key: ?u8,
    read_only: bool,
    piped: bool,
) !connect_events.RunOutcome {
    assert(state.pane_id.len > 0 and client.fd >= 0);
    try sys.setNonBlocking(client.fd);
    var loop: TrackedLoop = .{
        .allocator = allocator,
        .client = client,
        .state = state,
        .stdin_fd = stdin_fd,
        .stdout_fd = stdout_fd,
        .detach_key = detach_key,
        .read_only = read_only,
        .piped = piped,
        .resize_pending = !read_only,
        .stdin_unpoll = connect_terminal.pollUnsupported(stdin_fd),
        .stdout_unpoll = connect_terminal.pollUnsupported(stdout_fd),
    };
    defer loop.deinit();
    while (true) {
        if (try loop.step()) |outcome| return outcome;
    }
}

const TrackedLoop = struct {
    allocator: std.mem.Allocator,
    client: *rpc.RpcClient,
    state: *connect_events.RunState,
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    detach_key: ?u8,
    read_only: bool,
    piped: bool,
    outbound: connect_terminal.WriteQueue = .{},
    pending_out: ?[]u8 = null,
    sent_out: usize = 0,
    eof_outcome: ?connect_events.RunOutcome = null,
    stdin_eof: bool = false,
    resize_pending: bool,
    stdin_unpoll: bool,
    stdout_unpoll: bool,

    fn deinit(self: *TrackedLoop) void {
        self.outbound.bytes.deinit(self.allocator);
        if (self.pending_out) |b| self.allocator.free(b);
    }

    fn step(self: *TrackedLoop) !?connect_events.RunOutcome {
        assert(self.sent_out == 0 or self.pending_out != null);
        if (self.pending_out == null) {
            try drainBuffered(self.allocator, self.client, self.state, &self.pending_out, &self.eof_outcome);
        }
        if (self.eof_outcome) |out| {
            if (self.pending_out == null and (out != .detached or self.outbound.pending().len == 0)) return out;
        }
        if (!self.read_only and self.resize_pending and self.eof_outcome == null) {
            self.resize_pending = false;
            try maybeQueueResize(self.allocator, self.state, &self.outbound, self.stdout_fd, self.stdin_fd);
        }
        if (!self.read_only and connect_terminal.g_winch_flag.swap(false, .seq_cst)) self.resize_pending = true;
        return self.pollAndService();
    }

    fn pollAndService(self: *TrackedLoop) !?connect_events.RunOutcome {
        const want_in = !self.stdin_eof and self.eof_outcome == null and
            self.outbound.pending().len < connect_wire.outbound_max / 2;
        const want_out = self.pending_out != null;
        const sock_ev: i16 = (if (self.pending_out == null and self.eof_outcome == null)
            @as(i16, posix.POLL.IN)
        else
            0) | (if (self.outbound.pending().len > 0) @as(i16, posix.POLL.OUT) else 0);
        const in_fd = if (want_in and !self.stdin_unpoll) self.stdin_fd else -1;
        const out_fd = if (want_out and !self.stdout_unpoll) self.stdout_fd else -1;
        var fds = [_]posix.pollfd{
            .{ .fd = in_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (sock_ev != 0) self.client.fd else -1, .events = sock_ev, .revents = 0 },
            .{ .fd = out_fd, .events = posix.POLL.OUT, .revents = 0 },
        };
        _ = try posix.poll(&fds, if (want_out and self.stdout_unpoll) 0 else 100);
        if (want_in and self.stdin_unpoll) fds[0].revents = posix.POLL.IN;
        if (want_out and self.stdout_unpoll) fds[2].revents = posix.POLL.OUT;
        if ((fds[2].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0) return error.OutputClosed;
        if ((fds[2].revents & (posix.POLL.OUT | posix.POLL.NVAL)) != 0) {
            try flushStdout(self.allocator, self.stdout_fd, &self.pending_out, &self.sent_out);
        }
        if (try stepSocket(self.client, &self.outbound, fds[1].revents, sock_ev)) |out| return out;
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
            return stepStdin(
                self.allocator,
                self.stdin_fd,
                self.state,
                &self.outbound,
                self.detach_key,
                self.read_only,
                self.piped,
                &self.stdin_eof,
                &self.eof_outcome,
            );
        }
        return null;
    }
};

fn drainBuffered(
    allocator: std.mem.Allocator,
    client: *rpc.RpcClient,
    state: *connect_events.RunState,
    pending_out: *?[]u8,
    eof_outcome: *?connect_events.RunOutcome,
) !void {
    while (client.reader.hasBufferedLine()) {
        const line = (try client.reader.nextBufferedLineAlloc(allocator, rpc.rpc_line_max)).?;
        defer allocator.free(line);
        if (try connect_events.handleServerLine(allocator, line, state, pending_out, client.io)) |out| {
            eof_outcome.* = out;
        }
        if (pending_out.* != null or eof_outcome.* != null) break;
    }
}

fn maybeQueueResize(
    allocator: std.mem.Allocator,
    state: *connect_events.RunState,
    outbound: *connect_terminal.WriteQueue,
    stdout_fd: posix.fd_t,
    stdin_fd: posix.fd_t,
) !void {
    const size = connect_terminal.currentTerminalSize(stdout_fd, stdin_fd) orelse return;
    assert(size.rows > 0 and size.cols > 0);
    try state.queue(allocator, outbound, "session.resize", .{
        .sessionId = state.pane_id,
        .rows = size.rows,
        .cols = size.cols,
    });
}

fn flushStdout(
    allocator: std.mem.Allocator,
    stdout_fd: posix.fd_t,
    pending_out: *?[]u8,
    sent_out: *usize,
) !void {
    const bytes = pending_out.* orelse return;
    const n = sys.write(stdout_fd, bytes[sent_out.*..]) catch |err| switch (err) {
        error.WouldBlock => 0,
        else => return err,
    };
    sent_out.* += n;
    assert(sent_out.* <= bytes.len);
    if (sent_out.* == bytes.len) {
        allocator.free(bytes);
        pending_out.* = null;
        sent_out.* = 0;
    }
}

fn stepSocket(
    client: *rpc.RpcClient,
    outbound: *connect_terminal.WriteQueue,
    revents: i16,
    sock_ev: i16,
) !?connect_events.RunOutcome {
    const hup = (revents & posix.POLL.HUP) != 0;
    if ((sock_ev & posix.POLL.IN) != 0 and (revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
        const filled = client.reader.fillOnce(client.fd) catch |err| switch (@as(anyerror, err)) {
            error.ConnectionClosed, error.ConnectionResetByPeer => return .connection_lost,
            else => return err,
        };
        switch (filled) {
            .data => {},
            .eof => return .connection_lost,
            .would_block => if (hup) return .connection_lost,
        }
    } else if ((revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
        return .connection_lost;
    }
    if ((revents & posix.POLL.OUT) != 0) {
        outbound.flush(client.fd) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => {
                outbound.bytes.clearRetainingCapacity();
                outbound.sent = 0;
            },
            else => return err,
        };
    }
    return null;
}

fn stepStdin(
    allocator: std.mem.Allocator,
    stdin_fd: posix.fd_t,
    state: *connect_events.RunState,
    outbound: *connect_terminal.WriteQueue,
    detach_key: ?u8,
    read_only: bool,
    piped: bool,
    stdin_eof: *bool,
    eof_outcome: *?connect_events.RunOutcome,
) !?connect_events.RunOutcome {
    var buf: [4096]u8 = undefined;
    switch (try connect_terminal.readStdinChunk(stdin_fd, &buf)) {
        .again => return null,
        .eof => {
            if (!piped) return .exited;
            stdin_eof.* = true;
            return null;
        },
        .bytes => |bytes| {
            assert(bytes.len > 0);
            const chord = if (detach_key) |k| std.mem.indexOfScalar(u8, bytes, k) else null;
            const input = bytes[0 .. chord orelse bytes.len];
            if (!read_only and input.len > 0) {
                try state.queueSend(allocator, outbound, input);
            }
            if (chord != null) {
                try state.queue(allocator, outbound, "client.detach", .{ .clientId = state.client_id });
                eof_outcome.* = .detached;
            }
            return null;
        },
    }
}

test "runTrackedLoop updates generation and next_offset and enforces read-only detach" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[1]);
    const in_pipe = try sys.pipe();
    defer sys.close(in_pipe[0]);
    defer sys.close(in_pipe[1]);
    const out_pipe = try sys.pipe();
    defer sys.close(out_pipe[0]);
    defer sys.close(out_pipe[1]);

    try sys.sendAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":" ++
            "{\"pane_id\":\"p1\",\"data_base64\":\"aGVsbG8=\",\"offset\":10,\"generation\":3}}\n",
    );
    try sys.writeAll(in_pipe[1], "ignored\x1c");

    var client = rpc.RpcClient.initFromFd(alloc, test_io, pair[0]);
    defer client.deinit();
    var state: connect_events.RunState = .{
        .pane_id = "p1",
        .client_id = "c1",
        .generation = 3,
        .next_offset = 10,
    };
    defer state.pending_sends.deinit(alloc);

    const outcome = try runTrackedLoop(
        alloc,
        &client,
        &state,
        in_pipe[0],
        out_pipe[1],
        args_mod.default_detach_key,
        true,
        false,
    );
    try std.testing.expectEqual(connect_events.RunOutcome.detached, outcome);
    try std.testing.expectEqual(@as(?u64, 15), state.next_offset);

    var req_reader = @import("../rpc_line_reader.zig").LineReader{};
    defer req_reader.deinit();
    const sent = try req_reader.readLineAlloc(alloc, pair[1], 4096);
    defer alloc.free(sent);
    // Read-only must NOT have sent session.send for "ignored", only client.detach!
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"client.detach\"") != null);
}
