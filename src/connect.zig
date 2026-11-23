const std = @import("std");
const builtin = @import("builtin");
const rpc_line_reader = @import("rpc_line_reader.zig");
const protocol = @import("protocol.zig");
const socket_path = @import("socket_path.zig");
const c = std.c;

const posix = std.posix;
const sys = @import("sys.zig");
const LineReader = rpc_line_reader.LineReader;

const buffer_size: usize = 32 * 1024;
const rpc_line_max: usize = 16 * 1024 * 1024;
const outbound_max: usize = 1024 * 1024;
const write_timeout_ms: i64 = 2_000;
const spawn_timeout_ms: i64 = 4_000;
const partial_frame_timeout_ms: i64 = 30_000;
const pipe_quiet_ms: i64 = 2_000;
const run_loop_poll_timeout_ms: i32 = 100;
const bootstrap_response_timeout_ms: i64 = 10_000;
const version_handshake_timeout_ms: i64 = 2_000;

// Default detach chord: Ctrl-\ (0x1C). Chosen because it maps to SIGQUIT,
// which raw mode disables anyway, so it is rarely wanted by the attached
// program and makes a safe single-byte escape hatch. Configurable via
// --detach-key (ctrl-<letter> | none).
const default_detach_key: u8 = 0x1C;

const ping_rpc_id: u32 = 100;
const verb_rpc_id: u32 = 1;
const attach_rpc_id: u32 = 1;
const first_interactive_id: u32 = 101;

var g_terminal_active = std.atomic.Value(bool).init(false);
var g_saved_termios: posix.termios = undefined;
var g_raw_termios: posix.termios = undefined;
var g_saved_termios_fd: posix.fd_t = 0;
var g_termios_saved = std.atomic.Value(bool).init(false);
var g_restore_output = std.atomic.Value(bool).init(false);
var g_output_fd: posix.fd_t = 1;
var g_output_flags: c_int = 0;
var g_winch_flag = std.atomic.Value(bool).init(false);

pub const panic = std.debug.FullPanic(connectPanic);

fn connectPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    leaveTerminal();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// An absolute point on the monotonic clock for a bootstrap RPC exchange.
/// Carries the `Io` that reads the clock so call chains pass one value.
const Deadline = struct {
    io: std.Io,
    at: std.Io.Clock.Timestamp,

    pub fn fromNow(io: std.Io, timeout_ms: i64) Deadline {
        return .{ .io = io, .at = .fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake }) };
    }

    fn remainingMs(self: Deadline) i64 {
        return @intCast(@max(0, self.at.durationFromNow(self.io).raw.toNanoseconds() + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
    }

    fn timeout(self: Deadline) std.Io.Timeout {
        return .{ .deadline = self.at };
    }
};

pub fn main(init: std.process.Init) void {
    runMain(init) catch |err| {
        switch (err) {
            error.InvalidArguments => std.process.exit(2),
            error.ReportedFailure, error.RpcError => {},
            else => printDiagnostic(init.io, "{s}", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

pub const ParsedAttachArgs = struct {
    session_id: ?[]const u8 = null,
    explicit_socket_path: ?[]const u8 = null,
    spawn_daemon: bool = false,
    auto_create: bool = true,
    create_command: ?[]const u8 = null,
    show_version: bool = false,
    show_help: bool = false,
    detach_key: ?u8 = default_detach_key,
};

pub const ParseAttachArgsError = error{
    MissingSocketValue,
    MissingCommandValue,
    MissingDetachKeyValue,
    InvalidDetachKeyValue,
    UnknownFlag,
    UnexpectedArgument,
};

pub const ParseAttachArgsFailure = struct {
    err: ParseAttachArgsError,
    arg: ?[]const u8 = null,
};

pub fn parseAttachArgs(argv: []const []const u8, failure: ?*ParseAttachArgsFailure) ParseAttachArgsError!ParsedAttachArgs {
    var parsed: ParsedAttachArgs = .{};
    var options = true;
    var explicit_attach = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (options and std.mem.eql(u8, a, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, a, "attach") and parsed.session_id == null and !explicit_attach) {
            explicit_attach = true;
        } else if (options and std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingSocketValue };
                return error.MissingSocketValue;
            }
            parsed.explicit_socket_path = argv[i];
        } else if (options and std.mem.eql(u8, a, "--spawn-daemon")) {
            parsed.spawn_daemon = true;
        } else if (options and std.mem.eql(u8, a, "--no-create")) {
            parsed.auto_create = false;
        } else if (options and std.mem.eql(u8, a, "--command")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingCommandValue };
                return error.MissingCommandValue;
            }
            parsed.create_command = argv[i];
        } else if (options and std.mem.eql(u8, a, "--detach-key")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingDetachKeyValue };
                return error.MissingDetachKeyValue;
            }
            parsed.detach_key = parseDetachKey(argv[i]) catch {
                if (failure) |f| f.* = .{ .err = error.InvalidDetachKeyValue, .arg = argv[i] };
                return error.InvalidDetachKeyValue;
            };
        } else if (options and (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V"))) {
            parsed.show_version = true;
        } else if (options and (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h"))) {
            parsed.show_help = true;
            return parsed;
        } else if (options and a.len > 0 and a[0] == '-') {
            if (failure) |f| f.* = .{ .err = error.UnknownFlag, .arg = a };
            return error.UnknownFlag;
        } else if (parsed.session_id == null) {
            parsed.session_id = a;
        } else {
            if (failure) |f| f.* = .{ .err = error.UnexpectedArgument, .arg = a };
            return error.UnexpectedArgument;
        }
    }
    return parsed;
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // Global socket options may precede the management verb.
    var verb_index: usize = 1;
    var global_socket: ?[]const u8 = null;
    while (verb_index + 1 < argv.len and std.mem.eql(u8, argv[verb_index], "--socket")) : (verb_index += 2) {
        global_socket = argv[verb_index + 1];
    }
    if (verb_index < argv.len) {
        if (parseVerb(argv[verb_index])) |verb| {
            return runVerb(allocator, io, verb, argv[verb_index + 1 ..], global_socket);
        }
    }

    var failure: ParseAttachArgsFailure = .{ .err = error.UnknownFlag };
    const parsed = parseAttachArgs(argv, &failure) catch |err| switch (err) {
        error.MissingSocketValue => return fail(io, "missing value for --socket", .{}),
        error.MissingCommandValue => return fail(io, "missing value for --command", .{}),
        error.MissingDetachKeyValue => return fail(io, "missing value for --detach-key", .{}),
        error.InvalidDetachKeyValue => return fail(io, "invalid --detach-key: {f}", .{escaped(failure.arg.?)}),
        error.UnknownFlag => return fail(io, "unknown flag: {f}", .{escaped(failure.arg.?)}),
        error.UnexpectedArgument => return fail(io, "unexpected argument: {f}", .{escaped(failure.arg.?)}),
    };

    if (parsed.show_help) {
        try printUsage(io);
        return;
    }
    if (parsed.show_version) {
        try printVersion(io);
        return;
    }

    const sid = parsed.session_id orelse return fail(io, "session_id is required", .{});
    const path = try resolveSocketPath(allocator, io, parsed.explicit_socket_path);
    defer allocator.free(path);

    const socket_fd = try connectWithRetry(allocator, io, path, parsed.spawn_daemon);
    defer sys.close(socket_fd);
    var reader: LineReader = .{};
    defer deinitReader(&reader);

    try warnOnVersionMismatch(allocator, &reader, socket_fd, .fromNow(io, version_handshake_timeout_ms));

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;
    const is_tty = sys.isatty(stdin_fd);
    const size = currentTerminalSize(stdout_fd, stdin_fd) orelse TerminalSize{ .rows = 24, .cols = 80 };
    const deadline = Deadline.fromNow(io, bootstrap_response_timeout_ms);
    var attach = try attachOrCreate(allocator, &reader, socket_fd, sid, size, parsed.auto_create, parsed.create_command, deadline);
    defer attach.deinit(allocator);

    var previous_mask: posix.sigset_t = undefined;
    const signals = terminalSignalSet();
    posix.sigprocmask(posix.SIG.BLOCK, &signals, &previous_mask);
    installTerminalHandlers();
    g_terminal_active.store(true, .seq_cst);
    const setup = enterTerminal(stdin_fd, stdout_fd, is_tty);
    posix.sigprocmask(posix.SIG.SETMASK, &previous_mask, null);
    defer leaveTerminal();
    try setup;

    try replayScrollback(allocator, attach.result(), stdout_fd);
    if (jsonField(attach.result(), "exited") == .bool and jsonField(attach.result(), "exited").bool) {
        try printExitStatus(io, attach.result());
        const next = try respawnAndReattach(allocator, &reader, socket_fd, attach.result(), size, .fromNow(io, bootstrap_response_timeout_ms));
        attach.deinit(allocator);
        attach = next;
        try replayScrollback(allocator, attach.result(), stdout_fd);
        if (jsonField(attach.result(), "exited") == .bool and jsonField(attach.result(), "exited").bool) {
            try printExitStatus(io, attach.result());
            try stderrWrite(io, "session ended\n");
            return;
        }
    }

    const outcome = try runLoop(stdin_fd, stdout_fd, socket_fd, &reader, allocator, .{
        .pane_id = try requiredString(attach.result(), "paneId"),
        .client_id = try requiredString(attach.result(), "clientId"),
        .generation = jsonUnsigned(attach.result(), "generation"),
        .replay_end = jsonUnsigned(attach.result(), "replayEndOffset"),
        .detach_key = if (is_tty) parsed.detach_key else null,
        .piped = !is_tty,
        .io = io,
    });

    leaveTerminal();
    switch (outcome) {
        .detached => try stderrWrite(io, "[detached]\n"),
        .detached_remotely => try stderrWrite(io, "[detached remotely]\n"),
        .session_ended => try stderrWrite(io, "session ended\n"),
        .connection_lost => return diagnostic(io, "daemon connection lost", .{}),
        .exited => {},
    }
}

fn printVersion(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "zmux-connect " ++ protocol.version ++ "\n");
}

const Response = struct {
    line: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: Response, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.line);
    }

    fn result(self: Response) std.json.Value {
        return jsonField(self.parsed.value, "result");
    }

    fn rpcError(self: Response) ?RpcError {
        return RpcError.fromEnvelope(self.parsed.value);
    }
};

const RpcError = struct {
    message: []const u8,
    kind: []const u8,

    fn fromEnvelope(envelope: std.json.Value) ?RpcError {
        const err = jsonField(envelope, "error");
        if (err != .object) return null;
        return .{
            .message = jsonObjectString(err, "message") orelse "unknown RPC error",
            .kind = jsonObjectString(jsonField(err, "data"), "kind") orelse "",
        };
    }

    fn is(self: RpcError, kind: []const u8) bool {
        return std.mem.eql(u8, self.kind, kind);
    }
};

fn attachOrCreate(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    target: []const u8,
    size: TerminalSize,
    auto_create: bool,
    command: ?[]const u8,
    deadline: Deadline,
) !Response {
    const create = if (auto_create) CreateParams{ .id = target, .rows = size.rows, .cols = size.cols, .command = command } else null;
    const response = try sendAttach(allocator, reader, fd, target, size, create, attach_rpc_id, deadline);
    if (create) |params| {
        if (response.rpcError()) |rpc_err| {
            if (rpc_err.is("not_found")) {
                // A daemon that implements structured errors but ignores createIfMissing.
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
};

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
    return response;
}

fn respawnAndReattach(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    result: std.json.Value,
    size: TerminalSize,
    deadline: Deadline,
) !Response {
    const pane_id = try requiredString(result, "paneId");
    const client_id = try requiredString(result, "clientId");
    const respawned = try callRpc(allocator, reader, fd, 4, "pane.respawn", .{ .paneId = pane_id, .kill = false }, deadline);
    defer respawned.deinit(allocator);
    // Another client may have respawned the pane while we were printing replay.
    if (respawned.rpcError()) |err| if (!err.is("conflict")) return reportRpcError(deadline.io, err);
    const detached = try callRpc(allocator, reader, fd, 5, "client.detach", .{ .clientId = client_id }, deadline);
    defer detached.deinit(allocator);
    if (detached.rpcError()) |err| if (!err.is("not_found")) return reportRpcError(deadline.io, err);
    const attached = try sendAttach(allocator, reader, fd, pane_id, size, null, 6, deadline);
    return validateAttach(allocator, deadline.io, attached);
}

fn printExitStatus(io: std.Io, result: std.json.Value) !void {
    var buf: [128]u8 = undefined;
    const message = if (jsonUnsigned(result, "exitCode")) |code|
        try std.fmt.bufPrint(&buf, "[session exited: code {d}]\n", .{code})
    else if (jsonUnsigned(result, "signal")) |signal|
        try std.fmt.bufPrint(&buf, "[session exited: signal {d}]\n", .{signal})
    else
        "[session exited]\n";
    try stderrWrite(io, message);
}

fn buildFrame(allocator: std.mem.Allocator, id: u32, method: []const u8, params: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(.{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params,
    }, .{ .emit_null_optional_fields = false })});
}

fn callRpc(
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
    return exchange(allocator, reader, fd, id, method, frame, deadline);
}

fn exchange(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    id: u32,
    operation: []const u8,
    frame: []const u8,
    deadline: Deadline,
) !Response {
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

fn deinitReader(reader: *LineReader) void {
    if (@hasDecl(LineReader, "deinit")) reader.deinit();
}

fn readRpcResponse(allocator: std.mem.Allocator, reader: *LineReader, fd: posix.fd_t, expected_id: u32, deadline: Deadline) !Response {
    while (deadline.remainingMs() > 0) {
        const line = try reader.readLineAllocTimeout(allocator, deadline.io, fd, rpc_line_max, deadline.timeout());
        errdefer allocator.free(line);
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
        parsed.deinit();
        allocator.free(line);
    }
    return error.ReadTimeout;
}

fn parseDetachKey(spec: []const u8) !?u8 {
    if (std.ascii.eqlIgnoreCase(spec, "none")) return null;
    if (spec.len == 6 and std.ascii.eqlIgnoreCase(spec[0..5], "ctrl-")) {
        return controlByte(spec[5]) orelse return error.InvalidDetachKey;
    }
    return error.InvalidDetachKey;
}

// Map a key name to its ASCII control byte: letters => C-a..C-z (0x01..0x1A),
// and backslash => 0x1C so the default Ctrl-\ chord is expressible.
fn controlByte(key: u8) ?u8 {
    if (std.ascii.isAlphabetic(key)) return std.ascii.toUpper(key) - 'A' + 1;
    if (key == '\\') return 0x1C;
    return null;
}

fn warnOnVersionMismatch(
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
        printDiagnostic(deadline.io, "warning: daemon protocol {f} differs from client {s}; continuing", .{ escaped(daemon_ver), protocol.version });
    }
}

// ---------------------------------------------------------------------------
// Management verbs: `zmux-connect ls|kill|rename|shutdown ...` map onto single
// JSON-RPC calls, print human-readable output (or --json for the raw frame),
// and exit non-zero with the daemon's error message on stderr.
// ---------------------------------------------------------------------------

const Verb = enum { list, kill, rename, shutdown };

fn parseVerb(token: []const u8) ?Verb {
    if (std.mem.eql(u8, token, "ls")) return .list;
    if (std.mem.eql(u8, token, "kill")) return .kill;
    if (std.mem.eql(u8, token, "rename")) return .rename;
    if (std.mem.eql(u8, token, "shutdown")) return .shutdown;
    return null;
}

fn verbName(verb: Verb) []const u8 {
    return switch (verb) {
        .list => "ls",
        .kill => "kill",
        .rename => "rename",
        .shutdown => "shutdown",
    };
}

pub const ParsedVerbArgs = struct {
    target: ?[]const u8 = null,
    new_name: ?[]const u8 = null,
    json: bool = false,
    explicit_socket: ?[]const u8 = null,
    show_help: bool = false,
};

pub const ParseVerbArgsError = error{
    MissingSocketValue,
    UnknownFlag,
    UnexpectedArgument,
    MissingTarget,
    MissingNewName,
};

pub const ParseVerbArgsFailure = struct {
    err: ParseVerbArgsError,
    arg: ?[]const u8 = null,
};

pub fn parseVerbArgs(verb: Verb, rest: []const []const u8, failure: ?*ParseVerbArgsFailure) ParseVerbArgsError!ParsedVerbArgs {
    var parsed: ParsedVerbArgs = .{};
    const needs_target = (verb == .kill or verb == .rename);
    const needs_new_name = (verb == .rename);

    var options = true;
    var positionals: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (options and std.mem.eql(u8, a, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= rest.len) {
                if (failure) |f| f.* = .{ .err = error.MissingSocketValue };
                return error.MissingSocketValue;
            }
            parsed.explicit_socket = rest[i];
        } else if (options and std.mem.eql(u8, a, "--json")) {
            parsed.json = true;
        } else if (options and (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h"))) {
            parsed.show_help = true;
            return parsed;
        } else if (options and a.len > 0 and a[0] == '-') {
            if (failure) |f| f.* = .{ .err = error.UnknownFlag, .arg = a };
            return error.UnknownFlag;
        } else if (positionals == 0 and needs_target) {
            parsed.target = a;
            positionals += 1;
        } else if (positionals == 1 and needs_new_name) {
            parsed.new_name = a;
            positionals += 1;
        } else {
            if (failure) |f| f.* = .{ .err = error.UnexpectedArgument, .arg = a };
            return error.UnexpectedArgument;
        }
    }

    if (needs_target and parsed.target == null) {
        if (failure) |f| f.* = .{ .err = error.MissingTarget };
        return error.MissingTarget;
    }
    if (needs_new_name and parsed.new_name == null) {
        if (failure) |f| f.* = .{ .err = error.MissingNewName };
        return error.MissingNewName;
    }
    return parsed;
}

fn runVerb(
    allocator: std.mem.Allocator,
    io: std.Io,
    verb: Verb,
    rest: []const []const u8,
    global_socket: ?[]const u8,
) !void {
    var failure: ParseVerbArgsFailure = .{ .err = error.UnknownFlag };
    const parsed = parseVerbArgs(verb, rest, &failure) catch |err| switch (err) {
        error.MissingSocketValue => return fail(io, "missing value for --socket", .{}),
        error.UnknownFlag => return fail(io, "unknown flag: {f}", .{escaped(failure.arg.?)}),
        error.UnexpectedArgument => return fail(io, "unexpected argument: {f}", .{escaped(failure.arg.?)}),
        error.MissingTarget => return fail(io, "{s} requires a session id", .{verbName(verb)}),
        error.MissingNewName => return fail(io, "rename requires a new name", .{}),
    };

    if (parsed.show_help) {
        try printUsage(io);
        return;
    }

    const target = parsed.target;
    const new_name = parsed.new_name;
    const json = parsed.json;
    const path = try resolveSocketPath(allocator, io, parsed.explicit_socket orelse global_socket);
    defer allocator.free(path);

    const socket_fd = try connectWithRetry(allocator, io, path, false);
    defer sys.close(socket_fd);

    var reader: LineReader = .{};
    defer deinitReader(&reader);
    try executeVerb(
        allocator,
        socket_fd,
        &reader,
        verb,
        target,
        new_name,
        json,
        1,
        .fromNow(io, bootstrap_response_timeout_ms),
    );
}

fn executeVerb(
    allocator: std.mem.Allocator,
    socket_fd: posix.fd_t,
    reader: *LineReader,
    verb: Verb,
    target: ?[]const u8,
    new_name: ?[]const u8,
    json: bool,
    out_fd: posix.fd_t,
    deadline: Deadline,
) !void {
    const request = try buildVerbRequest(allocator, verb, target, new_name);
    defer allocator.free(request);
    const operation = switch (verb) {
        .list => "session.list",
        .kill => "session.terminate",
        .rename => "session.rename",
        .shutdown => "daemon.shutdown",
    };
    const response = try exchange(allocator, reader, socket_fd, verb_rpc_id, operation, request, deadline);
    defer response.deinit(allocator);

    const rpc_err = response.rpcError();
    if (json) {
        try writeAllFd(out_fd, response.line);
        if (rpc_err != null) return error.RpcError;
        return;
    }
    if (rpc_err) |err| return reportRpcError(deadline.io, err);
    if (response.result() == .null) return error.InvalidResponse;

    const human = try formatVerbResult(allocator, verb, target, new_name, response.result());
    defer allocator.free(human);
    try writeAllFd(out_fd, human);
}

fn buildVerbRequest(
    allocator: std.mem.Allocator,
    verb: Verb,
    target: ?[]const u8,
    new_name: ?[]const u8,
) ![]u8 {
    return switch (verb) {
        .list => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.list\",\"params\":{{}}}}\n",
            .{verb_rpc_id},
        ),
        .shutdown => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"daemon.shutdown\",\"params\":{{}}}}\n",
            .{verb_rpc_id},
        ),
        .kill => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.terminate\",\"params\":{{\"sessionId\":{f}}}}}\n",
            .{ verb_rpc_id, std.json.fmt(target.?, .{}) },
        ),
        .rename => std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.rename\",\"params\":{{\"sessionId\":{f},\"name\":{f}}}}}\n",
            .{ verb_rpc_id, std.json.fmt(target.?, .{}), std.json.fmt(new_name.?, .{}) },
        ),
    };
}

fn formatVerbResult(
    allocator: std.mem.Allocator,
    verb: Verb,
    target: ?[]const u8,
    new_name: ?[]const u8,
    result: std.json.Value,
) ![]u8 {
    return switch (verb) {
        .list => formatSessionList(allocator, result),
        .kill => std.fmt.allocPrint(allocator, "killed session {f}\n", .{escaped(target.?)}),
        .rename => std.fmt.allocPrint(allocator, "renamed session {f} to {f}\n", .{ escaped(target.?), escaped(new_name.?) }),
        .shutdown => allocator.dupe(u8, "daemon shutdown\n"),
    };
}

fn formatSessionList(allocator: std.mem.Allocator, result: std.json.Value) ![]u8 {
    if (result != .array) return error.InvalidResponse;
    if (result.array.items.len == 0) return allocator.dupe(u8, "no sessions\n");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (result.array.items) |item| {
        if (item != .object) continue;
        try out.writer.print("{f}\t{f}\t{f}\tpid={d}\t{f}\n", .{
            escaped(jsonObjectString(item, "sessionId") orelse ""),
            escaped(jsonObjectString(item, "paneId") orelse ""),
            escaped(jsonObjectString(item, "state") orelse ""),
            jsonUnsigned(item, "pid") orelse 0,
            escaped(jsonObjectString(item, "title") orelse ""),
        });
    }
    return out.toOwnedSlice();
}

const Escaped = struct {
    bytes: []const u8,

    pub fn format(self: Escaped, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.bytes.len) {
            const byte = self.bytes[i];
            // Preserve printable UTF-8, including continuation bytes that
            // would otherwise look like standalone C1 controls.
            const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            const codepoint = if (len > 1 and i + len <= self.bytes.len)
                std.unicode.utf8Decode(self.bytes[i..][0..len]) catch null
            else
                null;
            if (codepoint) |cp| {
                if (cp >= 0x80 and cp <= 0x9f)
                    try writer.print("\\x{x:0>2}", .{cp})
                else
                    try writer.writeAll(self.bytes[i..][0..len]);
                i += len;
            } else {
                if (byte < 0x20 or (byte >= 0x7f and byte <= 0x9f))
                    try writer.print("\\x{x:0>2}", .{byte})
                else
                    try writer.writeByte(byte);
                i += 1;
            }
        }
    }
};

fn escaped(bytes: []const u8) Escaped {
    return .{ .bytes = bytes };
}

fn reportRpcError(io: std.Io, err: RpcError) error{RpcError} {
    printDiagnostic(io, "{f}", .{escaped(err.message)});
    return error.RpcError;
}

fn diagnostic(io: std.Io, comptime fmt: []const u8, args: anytype) error{ReportedFailure} {
    printDiagnostic(io, fmt, args);
    return error.ReportedFailure;
}

fn printDiagnostic(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("zmux-connect: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

const RunOutcome = enum { exited, session_ended, detached, detached_remotely, connection_lost };

const RunLoopOptions = struct {
    pane_id: []const u8,
    client_id: []const u8 = "",
    generation: ?u64 = null,
    replay_end: ?u64 = null,
    detach_key: ?u8 = null,
    piped: bool = false,
    io: std.Io,
};

const RunState = struct {
    pane_id: []const u8,
    switched_pane: ?[]u8 = null,
    generation: ?u64,
    next_offset: ?u64,
    client_id: []const u8,
    next_id: u32 = first_interactive_id,

    fn queue(self: *RunState, allocator: std.mem.Allocator, out: *WriteQueue, method: []const u8, params: anytype) !void {
        const frame = try buildFrame(allocator, self.next_id, method, params);
        defer allocator.free(frame);
        self.next_id += 1;
        try out.append(allocator, frame);
    }
};

const WriteQueue = struct {
    bytes: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    deadline: i64 = 0,

    fn pending(self: *const WriteQueue) []const u8 {
        return self.bytes.items[self.sent..];
    }

    fn append(self: *WriteQueue, allocator: std.mem.Allocator, frame: []const u8) !void {
        const pending_bytes = self.pending();
        if (frame.len > outbound_max - pending_bytes.len) return error.OutboundQueueFull;
        if (pending_bytes.len == 0) self.deadline = sys.monotonicMs() + write_timeout_ms;
        if (self.bytes.items.len + frame.len > outbound_max) {
            std.mem.copyForwards(u8, self.bytes.items, pending_bytes);
            self.bytes.shrinkRetainingCapacity(pending_bytes.len);
            self.sent = 0;
        }
        try self.bytes.appendSlice(allocator, frame);
    }

    fn flush(self: *WriteQueue, fd: posix.fd_t) !void {
        // Byte-level helper shared with the bootstrap writer.
        self.sent += try sendSome(fd, self.pending()) orelse return;
        self.deadline = sys.monotonicMs() + write_timeout_ms;
        if (self.pending().len == 0) {
            self.bytes.clearRetainingCapacity();
            self.sent = 0;
        }
    }
};

fn runLoop(
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    socket_fd: posix.fd_t,
    reader: *LineReader,
    allocator: std.mem.Allocator,
    options: RunLoopOptions,
) !RunOutcome {
    try sys.setNonBlocking(socket_fd);
    var state: RunState = .{
        .pane_id = options.pane_id,
        .client_id = options.client_id,
        .generation = options.generation,
        .next_offset = options.replay_end,
    };
    defer if (state.switched_pane) |pane| allocator.free(pane);
    var outbound: WriteQueue = .{};
    defer outbound.bytes.deinit(allocator);

    var partial: std.ArrayList(u8) = .empty;
    defer partial.deinit(allocator);
    var partial_since: ?i64 = null;
    var pending_output: ?[]u8 = null;
    defer if (pending_output) |bytes| allocator.free(bytes);
    var output_sent: usize = 0;

    var stdin_eof = false;
    var quiet_until: i64 = 0;
    var eof_outcome: ?RunOutcome = null;
    var resize_pending = true;
    var buf: [buffer_size]u8 = undefined;

    while (true) {
        if (pending_output == null and eof_outcome == null) {
            while (reader.hasBufferedLine()) {
                const line = (try reader.nextBufferedLineAlloc(allocator, rpc_line_max - partial.items.len)).?;
                defer allocator.free(line);
                const full_line = if (partial.items.len == 0) line else blk: {
                    try partial.appendSlice(allocator, line);
                    break :blk partial.items;
                };
                eof_outcome = try handleServerLine(allocator, full_line, &state, &pending_output, options.io);
                partial.clearRetainingCapacity();
                partial_since = null;
                if (pending_output != null or eof_outcome != null) break;
            }
            // The reader's staging buffer is fixed-size. Spill only when it
            // fills before a newline so large frames never block the loop.
            if (pending_output == null and eof_outcome == null and reader.end > reader.start) {
                if (partial_since == null) partial_since = sys.monotonicMs();
                if (@hasDecl(LineReader, "deinit")) {
                    // The final LineReader retains partial frames itself.
                    _ = try reader.nextBufferedLineAlloc(allocator, rpc_line_max);
                } else if (reader.end - reader.start == reader.buffer.len) {
                    if (partial.items.len + reader.buffer.len >= rpc_line_max) return error.MessageTooLarge;
                    try partial.appendSlice(allocator, reader.buffer[reader.start..reader.end]);
                    reader.start = 0;
                    reader.end = 0;
                }
            }
        }

        if (eof_outcome) |outcome| {
            if (pending_output == null and (outcome != .detached or outbound.pending().len == 0)) return outcome;
        }
        const now = sys.monotonicMs();
        if (partial_since) |started| {
            if (now - started >= partial_frame_timeout_ms) return .connection_lost;
        }
        if (outbound.pending().len != 0 and now >= outbound.deadline) {
            return diagnostic(options.io, "timed out sending interactive requests", .{});
        }
        if (stdin_eof and outbound.pending().len == 0 and pending_output == null and partial_since == null and now >= quiet_until)
            return .exited;

        resize_pending = g_winch_flag.swap(false, .seq_cst) or resize_pending;
        // Leave space for a worst-case input frame and a detach frame.
        const can_queue = outbound.pending().len <= outbound_max - (buffer_size * 2 + 4096);
        if (eof_outcome == null and resize_pending and can_queue) {
            resize_pending = false;
            if (currentTerminalSize(stdout_fd, stdin_fd)) |size| {
                try state.queue(allocator, &outbound, "session.resize", .{
                    .sessionId = state.pane_id,
                    .rows = size.rows,
                    .cols = size.cols,
                });
            }
        }

        const socket_events: i16 = (if (pending_output == null and eof_outcome == null) @as(i16, posix.POLL.IN) else 0) |
            (if (outbound.pending().len != 0) @as(i16, posix.POLL.OUT) else 0);
        var fds = [_]posix.pollfd{
            .{ .fd = if (!stdin_eof and eof_outcome == null and can_queue) stdin_fd else -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (socket_events != 0) socket_fd else -1, .events = socket_events, .revents = 0 },
            .{ .fd = if (pending_output != null) stdout_fd else -1, .events = posix.POLL.OUT, .revents = 0 },
        };
        _ = try posix.poll(&fds, run_loop_poll_timeout_ms);
        if ((fds[2].revents & (posix.POLL.ERR | posix.POLL.NVAL | posix.POLL.HUP)) != 0) return error.OutputClosed;
        if ((fds[2].revents & posix.POLL.OUT) != 0) {
            const bytes = pending_output.?;
            const n = sys.write(stdout_fd, bytes[output_sent..]) catch |err| switch (err) {
                error.WouldBlock => 0,
                else => return err,
            };
            output_sent += n;
            if (output_sent == bytes.len) {
                allocator.free(bytes);
                pending_output = null;
                output_sent = 0;
            }
        }
        if (socket_events & posix.POLL.IN != 0 and (fds[1].revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            const filled = reader.fillOnce(socket_fd) catch |err| switch (@as(anyerror, err)) {
                error.ConnectionClosed, error.ConnectionResetByPeer => return .connection_lost,
                else => return err,
            };
            switch (filled) {
                .data => quiet_until = sys.monotonicMs() + pipe_quiet_ms,
                .eof => return .connection_lost,
                .would_block => if ((fds[1].revents & posix.POLL.HUP) != 0) return .connection_lost,
            }
        } else if ((fds[1].revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0 or
            (socket_events & posix.POLL.OUT != 0 and fds[1].revents & posix.POLL.HUP != 0 and pending_output == null))
        {
            return .connection_lost;
        }
        if ((fds[1].revents & posix.POLL.HUP) != 0 and socket_events & posix.POLL.IN == 0) {
            // Finish pending terminal output before reading EOF from the socket.
            outbound.bytes.clearRetainingCapacity();
            outbound.sent = 0;
        } else if ((fds[1].revents & posix.POLL.OUT) != 0) {
            outbound.flush(socket_fd) catch |err| switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    // Read already queued final frames before handling EOF.
                    outbound.bytes.clearRetainingCapacity();
                    outbound.sent = 0;
                },
                else => return err,
            };
            if (stdin_eof) quiet_until = sys.monotonicMs() + pipe_quiet_ms;
        }

        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
            switch (try readStdinChunk(stdin_fd, &buf)) {
                .again => {},
                .eof => {
                    if (!options.piped) return .exited;
                    stdin_eof = true;
                    quiet_until = sys.monotonicMs() + pipe_quiet_ms;
                },
                .bytes => |bytes| {
                    const chord = if (options.detach_key) |key| std.mem.indexOfScalar(u8, bytes, key) else null;
                    const input = bytes[0 .. chord orelse bytes.len];
                    if (input.len != 0) {
                        const encoded = try base64Encode(allocator, input);
                        defer allocator.free(encoded);
                        try state.queue(allocator, &outbound, "session.send", .{ .sessionId = state.pane_id, .dataBase64 = encoded });
                    }
                    if (chord != null) {
                        try state.queue(allocator, &outbound, "client.detach", .{ .clientId = state.client_id });
                        eof_outcome = .detached;
                    }
                },
            }
        }
    }
}

const StdinReadResult = union(enum) {
    again,
    eof,
    bytes: []const u8,
};

fn readStdinChunk(fd: posix.fd_t, buf: []u8) !StdinReadResult {
    const n = posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return .again,
        else => return err,
    };
    if (n == 0) return .eof;
    return .{ .bytes = buf[0..n] };
}

fn getEnv(name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const key = buf[0..name.len :0];
    return if (c.getenv(key.ptr)) |value| std.mem.span(value) else null;
}

fn resolveSocketPath(allocator: std.mem.Allocator, io: std.Io, override: ?[]const u8) ![]u8 {
    return socket_path.resolve(allocator, override, getEnv) catch |err| switch (err) {
        error.SocketPathTooLong => {
            // The resolver discards an overlong result. Repeat its resolution
            // only on this error with a generalized path-length diagnostic.
            const raw = override orelse getEnv("ZMUX_SOCKET") orelse getEnv("SMITHERS_SESSION_SOCKET");
            if (raw) |value| {
                const path = try socket_path.absolutize(allocator, value);
                defer allocator.free(path);
                if (path.len > sys.max_unix_path_len)
                    return fail(io, "socket path too long ({d} > {d})", .{ path.len, sys.max_unix_path_len });
            }
            return fail(io, "socket path too long (maximum {d} bytes)", .{sys.max_unix_path_len});
        },
        error.EmptySocketPath, error.SocketPathContainsNul => return fail(io, "{s}", .{@errorName(err)}),
        else => return err,
    };
}

fn connectWithRetry(allocator: std.mem.Allocator, io: std.Io, path: []const u8, spawn_daemon: bool) !posix.fd_t {
    const first_deadline = sys.monotonicMs() + write_timeout_ms;
    if (tryConnect(io, path, first_deadline)) |fd| return fd else |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => {
            if (!spawn_daemon) return diagnostic(io, "no daemon at {f}; start zmuxd or pass --spawn-daemon", .{escaped(path)});
        },
        else => return err,
    }

    // A refused connect can also mean an existing regular file or symlink.
    if (sys.statAt(sys.cwd_fd, path, false)) |st| {
        if (!st.isSocket() or st.uid != sys.geteuid()) return diagnostic(io, "refusing to replace socket path {f}", .{escaped(path)});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const deadline = sys.monotonicMs() + spawn_timeout_ms;
    spawnDaemonDetached(allocator, io, path, deadline) catch |err| {
        if (err == error.ReportedFailure) return err;
        return diagnostic(io, "could not start daemon at {f}: {s}; see {f}.log", .{ escaped(path), @errorName(err), escaped(path) });
    };
    while (sys.monotonicMs() < deadline) {
        if (tryConnect(io, path, deadline)) |fd| return fd else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => try io.sleep(.fromMilliseconds(50), .awake),
            error.ReportedFailure => return err,
            else => return err,
        }
    }
    return diagnostic(io, "daemon at {f} did not become ready within 4s; see {f}.log", .{ escaped(path), escaped(path) });
}

fn tryConnect(io: std.Io, path: []const u8, deadline: i64) !posix.fd_t {
    const connected = sys.connectUnixDeadline(path, deadline) catch |err| switch (err) {
        error.NameTooLong => return fail(io, "socket path too long ({d} > {d})", .{ path.len, sys.max_unix_path_len }),
        error.Timeout, error.ConnectionTimedOut => return diagnostic(io, "timed out connecting to daemon at {f}", .{escaped(path)}),
        else => return err,
    };
    // Keep a socket out of stdin/stdout/stderr when the caller closed one.
    const fd = try moveAboveStdio(connected);
    errdefer sys.close(fd);
    const uid = sys.peerEuid(fd) catch
        return diagnostic(io, "could not authenticate daemon at {f}; refusing", .{escaped(path)});
    if (uid != sys.geteuid())
        return diagnostic(io, "socket at {f} is owned by uid {d}; refusing", .{ escaped(path), uid });

    if (socket_path.isDefaultManaged(path, getEnv)) {
        const parent = std.fs.path.dirname(path).?;
        // An existing connection must never cause us to create a directory.
        const dir = sys.openDirNoFollow(parent) catch |err|
            return diagnostic(io, "cannot verify socket directory {f}: {s}", .{ escaped(parent), @errorName(err) });
        defer sys.close(dir);
        const st = try sys.fstat(dir);
        if (!st.isDir() or st.uid != sys.geteuid() or st.permissions() & 0o077 != 0)
            return diagnostic(io, "socket directory {f} must be private and owned by the current user", .{escaped(parent)});
    }
    try sys.setNonBlocking(fd);
    return fd;
}

fn moveAboveStdio(fd: posix.fd_t) !posix.fd_t {
    if (fd >= 3) return fd;
    defer sys.close(fd);
    const moved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (moved < 0) return error.Unexpected;
    return moved;
}

fn spawnDaemonDetached(allocator: std.mem.Allocator, io: std.Io, path: []const u8, deadline: i64) !void {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    const daemon_path = try findDaemonSibling(allocator, io, std.fs.path.dirname(self_path) orelse ".", std.fs.path.basename(self_path));
    defer allocator.free(daemon_path);
    const daemon_z = try allocator.dupeSentinel(u8, daemon_path, 0);
    defer allocator.free(daemon_z);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const argv = [_:null]?[*:0]const u8{ daemon_z.ptr, "--socket", path_z.ptr };
    const envp = sys.currentEnviron();

    const parent = std.fs.path.dirname(path) orelse return error.NoSocketDirectory;
    if (!socket_path.isDefaultManaged(path, getEnv)) {
        const existing = try sys.openDirNoFollow(parent);
        sys.close(existing);
    }
    const dir_fd = try moveAboveStdio(try sys.ensurePrivateDir(parent));
    defer sys.close(dir_fd);
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{std.fs.path.basename(path)});
    defer allocator.free(log_name);
    const log_fd = try moveAboveStdio(try sys.openOwnedRegularAt(dir_fd, log_name, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, 0o600));
    defer sys.close(log_fd);
    const devnull = try moveAboveStdio(try sys.openZ("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    defer sys.close(devnull);

    const status_pipe = try sys.pipe();
    const status_read = moveAboveStdio(status_pipe[0]) catch |err| {
        sys.close(status_pipe[1]);
        return err;
    };
    defer sys.close(status_read);
    const status_write = try moveAboveStdio(status_pipe[1]);

    const child = sys.fork() catch |err| {
        sys.close(status_write);
        return err;
    };
    if (child == 0) {
        sys.close(status_read);
        if (c.setsid() < 0) childSpawnFailed(status_write, "setsid");
        const daemon_child = sys.fork() catch childSpawnFailed(status_write, "fork");
        if (daemon_child != 0) c._exit(0);

        sys.dup2(devnull, 0) catch childSpawnFailed(status_write, "stdin");
        sys.dup2(devnull, 1) catch childSpawnFailed(status_write, "stdout");
        sys.dup2(log_fd, 2) catch childSpawnFailed(status_write, "stderr");
        // Reserve fd 3 for the exec receipt, and close all other inherited fds.
        if (status_write != 3) sys.dup2(status_write, 3) catch childSpawnFailed(status_write, "dup2");
        sys.setCloseOnExec(3) catch childSpawnFailed(3, "cloexec");
        sys.closeFrom(4);
        sys.resetChildSignals();
        _ = c.execve(daemon_z.ptr, &argv, envp);
        childSpawnFailed(3, "execve");
    }
    sys.close(status_write);

    var status: c_int = undefined;
    while (c.waitpid(child, &status, 0) < 0) {
        if (posix.errno(@as(c_int, -1)) != .INTR) return error.WaitFailed;
    }
    try waitWritableOrReadable(status_read, posix.POLL.IN, deadline);
    var buf: [32]u8 = undefined;
    const count = try posix.read(status_read, &buf);
    if (count != 0) return diagnostic(io, "daemon startup failed during {f}", .{escaped(buf[0..count])});
    if (status != 0) return error.DaemonSpawnFailed;
}

fn childSpawnFailed(fd: posix.fd_t, stage: []const u8) noreturn {
    _ = c.write(fd, stage.ptr, stage.len);
    c._exit(127);
}

const terminal_signals = [_]posix.SIG{ .HUP, .INT, .TERM, .TSTP, .QUIT, .PIPE, .CONT, .TTOU };

fn terminalSignalSet() posix.sigset_t {
    var mask = posix.sigemptyset();
    for (terminal_signals) |sig| posix.sigaddset(&mask, sig);
    return mask;
}

fn enterTerminal(stdin_fd: posix.fd_t, stdout_fd: posix.fd_t, is_tty: bool) !void {
    if (is_tty) {
        const current = try posix.tcgetattr(stdin_fd);
        g_saved_termios = current;
        g_saved_termios_fd = stdin_fd;
        var raw = current;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        g_raw_termios = raw;
        try posix.tcsetattr(stdin_fd, .NOW, raw);
        g_termios_saved.store(true, .seq_cst);
    } else {
        g_saved_termios_fd = -1;
    }

    g_output_fd = stdout_fd;
    g_output_flags = c.fcntl(stdout_fd, c.F.GETFL);
    if (g_output_flags < 0) return error.Unexpected;
    try sys.setNonBlocking(stdout_fd);
    g_restore_output.store(true, .seq_cst);
}

fn leaveTerminal() void {
    g_terminal_active.store(false, .seq_cst);
    restoreTerminal();
}

fn restoreTerminal() void {
    var previous: posix.sigset_t = undefined;
    const signals = terminalSignalSet();
    posix.sigprocmask(posix.SIG.BLOCK, &signals, &previous);
    if (g_termios_saved.swap(false, .seq_cst)) posix.tcsetattr(g_saved_termios_fd, .NOW, g_saved_termios) catch {};
    if (g_restore_output.swap(false, .seq_cst)) _ = c.fcntl(g_output_fd, c.F.SETFL, g_output_flags);
    posix.sigprocmask(posix.SIG.SETMASK, &previous, null);
}

fn winchHandler(_: posix.SIG) callconv(.c) void {
    g_winch_flag.store(true, .seq_cst);
}

fn terminalAction(handler: *const fn (posix.SIG) callconv(.c) void) posix.Sigaction {
    return .{ .handler = .{ .handler = handler }, .mask = terminalSignalSet(), .flags = 0 };
}

fn exitRestoreHandler(sig: posix.SIG) callconv(.c) void {
    leaveTerminal();
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &dfl, null);
    _ = c.raise(sig);
}

fn suspendHandler(sig: posix.SIG) callconv(.c) void {
    restoreTerminal();
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &dfl, null);
    var unblock = posix.sigemptyset();
    posix.sigaddset(&unblock, sig);
    posix.sigprocmask(posix.SIG.UNBLOCK, &unblock, null);
    _ = c.raise(sig);
    // Also restore the active state when an orphaned process group ignores TSTP.
    resumeHandler(.CONT);
}

fn resumeHandler(_: posix.SIG) callconv(.c) void {
    if (!g_terminal_active.load(.seq_cst)) return;
    const suspend_action = terminalAction(suspendHandler);
    posix.sigaction(.TSTP, &suspend_action, null);
    if (g_saved_termios_fd >= 0 and !g_termios_saved.load(.seq_cst)) {
        if (posix.tcsetattr(g_saved_termios_fd, .NOW, g_raw_termios)) |_| {
            g_termios_saved.store(true, .seq_cst);
        } else |_| {}
    }
    if (!g_restore_output.load(.seq_cst)) {
        if (sys.setNonBlocking(g_output_fd)) |_| {
            g_restore_output.store(true, .seq_cst);
        } else |_| {}
    }
    g_winch_flag.store(true, .seq_cst);
}

fn installTerminalHandlers() void {
    const restore = terminalAction(exitRestoreHandler);
    for ([_]posix.SIG{ .HUP, .PIPE, .QUIT, .INT, .TERM }) |sig| posix.sigaction(sig, &restore, null);
    const suspend_action = terminalAction(suspendHandler);
    posix.sigaction(.TSTP, &suspend_action, null);
    const resume_action = terminalAction(resumeHandler);
    posix.sigaction(.CONT, &resume_action, null);
    const winch = terminalAction(winchHandler);
    posix.sigaction(.WINCH, &winch, null);
}

const TerminalSize = struct { rows: u16, cols: u16 };

fn currentTerminalSize(stdout_fd: posix.fd_t, stdin_fd: posix.fd_t) ?TerminalSize {
    return terminalSize(stdout_fd) orelse terminalSize(stdin_fd);
}

fn terminalSize(fd: posix.fd_t) ?TerminalSize {
    var size: posix.winsize = undefined;
    const rc = if (builtin.os.tag.isDarwin() or builtin.abi.isGnu()) blk: {
        const ioctl = @extern(*const fn (posix.fd_t, c_ulong, ...) callconv(.c) c_int, .{ .name = "ioctl", .library_name = "c" });
        break :blk ioctl(fd, tiocgwinsz(), &size);
    } else c.ioctl(fd, @intCast(tiocgwinsz()), &size);
    if (rc != 0 or size.col == 0 or size.row == 0) return null;
    return .{ .rows = size.row, .cols = size.col };
}

fn tiocgwinsz() c_ulong {
    return if (builtin.os.tag.isDarwin()) 0x40087468 else 0x5413;
}

fn waitWritableOrReadable(fd: posix.fd_t, event: i16, deadline: i64) !void {
    const remaining = deadline - sys.monotonicMs();
    if (remaining <= 0) return error.WriteTimeout;
    var pollfds = [_]posix.pollfd{.{ .fd = fd, .events = event, .revents = 0 }};
    if (try posix.poll(&pollfds, @intCast(remaining)) == 0) return error.WriteTimeout;
}

fn sendSome(fd: posix.fd_t, bytes: []const u8) !?usize {
    const n = sys.send(fd, bytes) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (n == 0) return error.WriteZero;
    return n;
}

fn sendFrame(fd: posix.fd_t, bytes: []const u8, timeout_ms: i64) !void {
    const deadline = sys.monotonicMs() + timeout_ms;
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (sys.monotonicMs() >= deadline) return error.WriteTimeout;
        if (try sendSome(fd, bytes[offset..])) |n| {
            offset += n;
        } else {
            try waitWritableOrReadable(fd, posix.POLL.OUT, deadline);
        }
    }
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    const deadline = sys.monotonicMs() + write_timeout_ms;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = sys.write(fd, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => {
                try waitWritableOrReadable(fd, posix.POLL.OUT, deadline);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

fn handleServerLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    state: *RunState,
    output: *?[]u8,
    io: std.Io,
) !?RunOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    const envelope = parsed.value;
    if (RpcError.fromEnvelope(envelope)) |err| {
        const id = jsonUnsigned(envelope, "id");
        if (id) |n| if (n < first_interactive_id or n >= state.next_id) return null;
        printDiagnostic(io, "{f}", .{escaped(err.message)});
        if (err.is("terminated") or err.is("not_found")) return .session_ended;
        if (id == null) return error.RpcError;
        return null;
    }

    const method = jsonObjectString(envelope, "method") orelse return null;
    const params = jsonField(envelope, "params");
    if (std.mem.eql(u8, method, protocol.client_detached_method) or std.mem.eql(u8, method, "client_switched")) {
        if (!jsonAnyStringEquals(params, &.{ "clientId", "client_id" }, state.client_id)) return null;
        if (std.mem.eql(u8, method, protocol.client_detached_method)) {
            const reason = jsonObjectString(params, "reason") orelse "";
            if (std.mem.eql(u8, reason, "remote_detach")) return .detached_remotely;
            return .session_ended;
        }
        const pane = jsonAnyObjectString(params, &.{ "paneId", "pane_id" }) orelse return error.InvalidResponse;
        if (pane.len == 0) return error.InvalidResponse;
        const new_pane = try allocator.dupe(u8, pane);
        if (state.switched_pane) |old_pane| allocator.free(old_pane);
        state.switched_pane = new_pane;
        state.pane_id = new_pane;
        state.generation = jsonUnsigned(params, "generation");
        state.next_offset = jsonUnsigned(params, "replayEndOffset");
        output.* = try decodeReplay(allocator, params);
        g_winch_flag.store(true, .seq_cst);
        return null;
    }

    const generation = jsonUnsigned(params, "generation");
    if (generation != null and state.generation != null and generation.? < state.generation.?) return null;

    if (std.mem.eql(u8, method, protocol.session_exited_method)) {
        if (jsonAnyStringEquals(params, &.{ "sessionId", "session_id" }, state.pane_id)) return .session_ended;
        return null;
    }
    if (!jsonAnyStringEquals(params, &.{ "paneId", "pane_id" }, state.pane_id)) return null;

    if (std.mem.eql(u8, method, protocol.pane_respawned_method)) {
        if (generation != state.generation) state.next_offset = null;
        state.generation = generation;
        return null;
    }
    if (std.mem.eql(u8, method, protocol.pane_output_dropped_method)) {
        if (jsonUnsigned(params, "resume_offset")) |offset|
            state.next_offset = @max(offset, state.next_offset orelse 0);
        return null;
    }
    if (!std.mem.eql(u8, method, protocol.pane_output_method)) return null;
    if (generation != null and generation != state.generation) {
        state.generation = generation;
        state.next_offset = null;
    }
    const encoded = jsonAnyObjectString(params, &.{ "dataBase64", "data_base64" }) orelse return null;
    const bytes = try base64Decode(allocator, encoded);
    errdefer allocator.free(bytes);
    const skip: usize = if (jsonUnsigned(params, "offset")) |offset| blk: {
        const previous = state.next_offset orelse offset;
        state.next_offset = @max(previous, offset +| bytes.len);
        break :blk @intCast(@min(previous -| offset, bytes.len));
    } else 0;
    if (skip == 0 and bytes.len != 0) {
        output.* = bytes;
    } else {
        if (skip < bytes.len) output.* = try allocator.dupe(u8, bytes[skip..]);
        allocator.free(bytes);
    }
    return null;
}

fn jsonField(value: std.json.Value, key: []const u8) std.json.Value {
    if (value != .object) return .null;
    return value.object.get(key) orelse .null;
}

fn jsonAnyStringEquals(value: std.json.Value, keys: []const []const u8, expected: []const u8) bool {
    const actual = jsonAnyObjectString(value, keys) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn jsonAnyObjectString(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (jsonObjectString(value, key)) |actual| return actual;
    }
    return null;
}

fn jsonObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = jsonField(value, key);
    return if (field == .string) field.string else null;
}

fn requiredString(value: std.json.Value, key: []const u8) ![]const u8 {
    const str = jsonObjectString(value, key) orelse return error.InvalidResponse;
    if (str.len == 0) return error.InvalidResponse;
    return str;
}

fn jsonUnsigned(value: std.json.Value, key: []const u8) ?u64 {
    const field = jsonField(value, key);
    return switch (field) {
        .integer => std.math.cast(u64, field.integer),
        .number_string => std.fmt.parseInt(u64, field.number_string, 10) catch null,
        else => null,
    };
}

fn base64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

fn base64Decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

fn decodeReplay(allocator: std.mem.Allocator, result: std.json.Value) !?[]u8 {
    const encoded = jsonObjectString(result, "replayBase64") orelse return null;
    if (encoded.len == 0) return null;
    return try base64Decode(allocator, encoded);
}

fn replayScrollback(allocator: std.mem.Allocator, result: std.json.Value, out_fd: posix.fd_t) !void {
    const bytes = (try decodeReplay(allocator, result)) orelse return;
    defer allocator.free(bytes);
    try writeAllFd(out_fd, bytes);
}

fn stderrWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("zmux-connect: " ++ fmt ++ "\n", args) catch {};
    w.interface.print("Try 'zmux-connect --help' for usage.\n", .{}) catch {};
    w.interface.flush() catch {};
    return error.InvalidArguments;
}

fn printUsage(io: std.Io) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(
        \\Usage: zmux-connect [--socket PATH] [attach] <session_id> [--socket PATH] [--spawn-daemon]
        \\                    [--no-create] [--command CMD] [--detach-key KEY]
        \\       zmux-connect <verb> [args] [--socket PATH] [--json]
        \\       smithers-session-connect ... (same interface)
        \\
        \\Attach (default): if <session_id> is not an existing pane id or session
        \\name, a new session with that name is created and then attached.
        \\  --socket PATH      path to the daemon's unix socket
        \\  --                 end options (e.g. zmux-connect -- ls to attach to ls)
        \\  --spawn-daemon     start a daemon if none is running
        \\  --no-create        require an existing session (do not create)
        \\  --command CMD       shell command to run in a newly created session
        \\  --detach-key KEY    detach chord: ctrl-<letter> or none to disable
        \\                     (default: ctrl-\, i.e. Ctrl-\ then detach)
        \\
        \\Management verbs (single JSON-RPC call, add --json for the raw frame):
        \\  ls                 list sessions/panes
        \\  kill <session>     terminate a session
        \\  rename <session> <name>   rename a session
        \\  shutdown           stop the daemon
        \\
    );
    try w.interface.flush();
}

fn findDaemonSibling(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, self_name: []const u8) ![]u8 {
    const zmux_order = [_][]const u8{ "zmuxd", "smithers-session-daemon" };
    const smithers_order = [_][]const u8{ "smithers-session-daemon", "zmuxd" };
    const candidates: []const []const u8 = if (std.mem.eql(u8, self_name, "zmux-connect"))
        &zmux_order
    else
        &smithers_order;

    for (candidates) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    return std.fs.path.join(allocator, &.{ dir, candidates[0] });
}

const test_io = std.testing.io;

/// Internal hooks for repository fuzz and benchmark code.
pub const fuzz_hooks = struct {
    pub const VerbKind = Verb;
    pub const RunOutcomeKind = RunOutcome;
    pub const RunLoopOpts = RunLoopOptions;
    pub const TermSize = TerminalSize;
    pub const RpcDeadline = Deadline;
    pub const default_detach = default_detach_key;
    pub const ping_id = ping_rpc_id;
    pub const verb_id = verb_rpc_id;
    pub const parseAttachArgsFn = parseAttachArgs;
    pub const parseVerbArgsFn = parseVerbArgs;
    pub const parseDetachKeyFn = parseDetachKey;
    pub const controlByteFn = controlByte;
    pub const parseVerbFn = parseVerb;
    pub const verbNameFn = verbName;
    pub const buildVerbRequestFn = buildVerbRequest;
    pub const formatVerbResultFn = formatVerbResult;
    pub const formatSessionListFn = formatSessionList;
    pub const handleServerLineFn = handleServerLine;
    pub const replayScrollbackFromAttachFn = replayScrollback;
    pub const attachOrCreateFn = attachOrCreate;
    pub const executeVerbFn = executeVerb;
    pub const readRpcResponseFn = readRpcResponse;
    pub const runLoopFn = runLoop;
    pub const b64EncodeFn = base64Encode;
    pub const b64DecodeFn = base64Decode;
    pub const findDaemonSiblingFn = findDaemonSibling;
    pub const writeAllFn = sendFrame;
};

test "explicit attach and the options terminator accept reserved session names" {
    const explicit = try parseAttachArgs(&.{ "zmux-connect", "--socket", "sock", "attach", "ls" }, null);
    try std.testing.expectEqualStrings("ls", explicit.session_id.?);
    try std.testing.expectEqualStrings("sock", explicit.explicit_socket_path.?);
    const literal = try parseAttachArgs(&.{ "zmux-connect", "--", "--help" }, null);
    try std.testing.expectEqualStrings("--help", literal.session_id.?);
    try std.testing.expect(!literal.show_help);
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
    defer deinitReader(&reader);
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
    defer deinitReader(&reader);
    try std.testing.expectError(error.ReadTimeout, readRpcResponse(std.testing.allocator, &reader, fds[0], 1, .fromNow(test_io, 20)));
}

test "attach sends createIfMissing in one frame and parses whitespace in replay" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"id\":1,\"result\":{\"paneId\":\"pane-1\",\"clientId\":\"client-1\",\"title\":\"error\",\"replayBase64\" : \"aGVsbG8=\"}}\n");
    var reader: LineReader = .{};
    defer deinitReader(&reader);
    const deadline = Deadline.fromNow(test_io, 500);
    const response = try attachOrCreate(alloc, &reader, pair[0], "error", .{ .rows = 24, .cols = 80 }, true, "echo hi", deadline);
    defer response.deinit(alloc);
    const replay = (try decodeReplay(alloc, response.result())).?;
    defer alloc.free(replay);
    try std.testing.expectEqualStrings("hello", replay);
    var request_reader: LineReader = .{};
    defer deinitReader(&request_reader);
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
    defer deinitReader(&reader);
    try std.testing.expectError(error.InvalidResponse, attachOrCreate(alloc, &reader, pair[0], "work", .{ .rows = 24, .cols = 80 }, true, null, .fromNow(test_io, 500)));
}

test "replay overlap, dropped bytes, switching and respawn follow the current pane" {
    const alloc = std.testing.allocator;
    var state: RunState = .{ .pane_id = "p", .client_id = "c", .generation = 1, .next_offset = 4 };
    defer if (state.switched_pane) |pane| alloc.free(pane);
    var output: ?[]u8 = null;
    const line = "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"generation\":1,\"offset\":2,\"data_base64\":\"YWJjZA==\"}}";
    try std.testing.expectEqual(null, try handleServerLine(alloc, line, &state, &output, test_io));
    try std.testing.expectEqualStrings("cd", output.?);
    alloc.free(output.?);
    output = null;
    _ = try handleServerLine(alloc, line, &state, &output, test_io);
    try std.testing.expect(output == null);
    _ = try handleServerLine(alloc, "{\"method\":\"pane_output_dropped\",\"params\":{\"pane_id\":\"p\",\"resume_offset\":20}}", &state, &output, test_io);
    try std.testing.expectEqual(@as(?u64, 20), state.next_offset);
    _ = try handleServerLine(alloc, "{\"method\":\"pane_respawned\",\"params\":{\"pane_id\":\"p\",\"generation\":2}}", &state, &output, test_io);
    try std.testing.expect(state.next_offset == null);
    const old = "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\",\"generation\":1}}";
    try std.testing.expectEqual(null, try handleServerLine(alloc, old, &state, &output, test_io));
    _ = try handleServerLine(alloc, "{\"method\":\"client_switched\",\"params\":{\"clientId\":\"c\",\"paneId\":\"q\",\"generation\":0}}", &state, &output, test_io);
    try std.testing.expectEqualStrings("q", state.pane_id);
    try std.testing.expectEqual(RunOutcome.detached_remotely, (try handleServerLine(alloc, "{\"method\":\"client_detached\",\"params\":{\"client_id\":\"c\",\"reason\":\"remote_detach\"}}", &state, &output, test_io)).?);
}

test "run loop drains frames already buffered behind the RPC response" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);
    const frames = "{\"id\":1,\"result\":{}}\n" ++
        "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\"}}\n" ++
        "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\"}}\n";
    try sys.sendAll(pair[1], frames);
    _ = c.shutdown(pair[1], 1);
    var reader: LineReader = .{};
    defer deinitReader(&reader);
    const response = try readRpcResponse(alloc, &reader, pair[0], 1, .fromNow(test_io, 500));
    defer response.deinit(alloc);
    try std.testing.expect(reader.hasBufferedLine());
    try std.testing.expectEqual(RunOutcome.session_ended, try runLoop(
        input[0],
        out[1],
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .io = test_io },
    ));
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try posix.read(out[0], &bytes));
    try std.testing.expectEqualStrings("ok", &bytes);
}

test "run loop completes a frame larger than the line reader staging buffer" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    const frame = try alloc.alloc(u8, 10_000);
    defer alloc.free(frame);
    @memset(frame, ' ');
    const exit_frame = "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\"}}\n";
    @memcpy(frame[frame.len - exit_frame.len ..], exit_frame);
    try sys.sendAll(pair[1], frame);
    _ = c.shutdown(pair[1], 1);
    var reader: LineReader = .{};
    defer deinitReader(&reader);
    try std.testing.expectEqual(RunOutcome.session_ended, try runLoop(
        input[0],
        1,
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .io = test_io },
    ));
}

test "run loop sends detach while a partial frame is pending" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    try sys.sendAll(pair[1], "{");
    try sys.writeAll(input[1], "a\x1c");
    var reader: LineReader = .{};
    defer deinitReader(&reader);
    try std.testing.expectEqual(RunOutcome.detached, try runLoop(
        input[0],
        1,
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .client_id = "c", .detach_key = default_detach_key, .io = test_io },
    ));
    var requests: LineReader = .{};
    defer deinitReader(&requests);
    const deadline = Deadline.fromNow(test_io, 500);
    const send = try requests.readLineAllocTimeout(alloc, test_io, pair[1], rpc_line_max, deadline.timeout());
    defer alloc.free(send);
    const detach = try requests.readLineAllocTimeout(alloc, test_io, pair[1], rpc_line_max, deadline.timeout());
    defer alloc.free(detach);
    try std.testing.expect(std.mem.indexOf(u8, send, "\"id\":101,\"method\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detach, "\"id\":102,\"method\":\"client.detach\"") != null);
}

test "session list escapes terminal controls and preserves printable UTF-8" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, "[{\"sessionId\":\"work\",\"paneId\":\"p\",\"state\":\"running\",\"pid\":7,\"title\":\"é\\u001b]0;pwn\\u0007\\u0085\\u007f\"}]", .{});
    defer parsed.deinit();
    const text = try formatSessionList(alloc, parsed.value);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("work\tp\trunning\tpid=7\té\\x1b]0;pwn\\x07\\x85\\x7f\n", text);
}

test "management JSON prints the complete null-id error envelope and fails" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);
    const response = "{\"id\":null,\"error\":{\"message\":\"LimitExceeded\",\"data\":{\"kind\":\"limit\"}}}\n";
    try sys.sendAll(pair[1], response);
    var reader: LineReader = .{};
    defer deinitReader(&reader);
    try std.testing.expectError(error.RpcError, executeVerb(alloc, pair[0], &reader, .list, null, null, true, out[1], .fromNow(test_io, 500)));
    var bytes: [response.len]u8 = undefined;
    try std.testing.expectEqual(response.len, try posix.read(out[0], &bytes));
    try std.testing.expectEqualStrings(response, &bytes);
}

test "detach key accepts ctrl chords and none" {
    try std.testing.expectEqual(@as(?u8, 1), try parseDetachKey("CTRL-A"));
    try std.testing.expectEqual(@as(?u8, default_detach_key), try parseDetachKey("ctrl-\\"));
    try std.testing.expectEqual(@as(?u8, null), try parseDetachKey("none"));
    try std.testing.expectError(error.InvalidDetachKey, parseDetachKey("ctrl-zebra"));
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
    defer deinitReader(&reader);
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
