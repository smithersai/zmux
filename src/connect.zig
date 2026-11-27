//! `zmux-connect`: attaches a terminal to a daemon session, or runs one
//! management verb, over the daemon's JSON-RPC unix socket.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const sys = @import("sys.zig");
const LineReader = @import("rpc_line_reader.zig").LineReader;
const cli = @import("connect/cli.zig");
const events = @import("connect/events.zig");
const rpc = @import("connect/rpc.zig");
const run_loop = @import("connect/run_loop.zig");
const spawn = @import("connect/spawn.zig");
const terminal = @import("connect/terminal.zig");
const verbs = @import("connect/verbs.zig");
const wire = @import("connect/wire.zig");

/// Options accepted by `zmux-connect [attach] <session_id>`.
pub const ParsedAttachArgs = cli.ParsedAttachArgs;
/// Every way `parseAttachArgs` can reject a command line.
pub const ParseAttachArgsError = cli.ParseAttachArgsError;
/// Detail for a `parseAttachArgs` failure: the error and offending argument.
pub const ParseAttachArgsFailure = cli.ParseAttachArgsFailure;
/// Parse attach-mode `argv` (program name at index 0).
pub const parseAttachArgs = cli.parseAttachArgs;
/// Arguments of a management verb (`ls`, `kill`, `rename`, `shutdown`).
pub const ParsedVerbArgs = cli.ParsedVerbArgs;
/// Every way `parseVerbArgs` can reject a verb's arguments.
pub const ParseVerbArgsError = cli.ParseVerbArgsError;
/// Detail for a `parseVerbArgs` failure: the error and offending argument.
pub const ParseVerbArgsFailure = cli.ParseVerbArgsFailure;
/// Parse the arguments after a management verb.
pub const parseVerbArgs = cli.parseVerbArgs;

const Verb = cli.Verb;
const parseVerb = cli.parseVerb;
const escaped = cli.escaped;
const fail = cli.fail;
const diagnostic = cli.diagnostic;
const printDiagnostic = cli.printDiagnostic;
const printUsage = cli.printUsage;
const stderrWrite = cli.stderrWrite;
const runVerb = verbs.runVerb;
const RunOutcome = events.RunOutcome;
const BootstrapNotifications = rpc.BootstrapNotifications;
const Deadline = rpc.Deadline;
const attachOrCreate = rpc.attachOrCreate;
const respawnAndReattach = rpc.respawnAndReattach;
const warnOnVersionMismatch = rpc.warnOnVersionMismatch;
const runLoop = run_loop.runLoop;
const resolveSocketPath = spawn.resolveSocketPath;
const connectWithRetry = spawn.connectWithRetry;
const TerminalSize = terminal.TerminalSize;
const currentTerminalSize = terminal.currentTerminalSize;
const enterTerminalGuarded = terminal.enterTerminalGuarded;
const leaveTerminal = terminal.leaveTerminal;
const replayScrollback = terminal.replayScrollback;
const reportRestoreFailure = terminal.reportRestoreFailure;
const g_termios_saved = &terminal.g_termios_saved;
const Response = wire.Response;
const jsonField = wire.jsonField;
const jsonUnsigned = wire.jsonUnsigned;
const requiredString = wire.requiredString;
const bootstrap_response_timeout_ms = wire.bootstrap_response_timeout_ms;
const version_handshake_timeout_ms = wire.version_handshake_timeout_ms;

/// Panic handler that restores the terminal before the default report.
pub const panic = std.debug.FullPanic(connectPanic);

fn connectPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    leaveTerminal();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Entry point of `zmux-connect`: exits 2 on usage errors and 1 on any other
/// failure, after reporting it on stderr.
pub fn main(init: std.process.Init) void {
    defer reportRestoreFailure();
    runMain(init) catch |err| {
        reportRestoreFailure();
        switch (err) {
            error.InvalidArguments => std.process.exit(2),
            error.ReportedFailure, error.RpcError => {},
            else => printDiagnostic(init.io, "{s}", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (findVerb(argv)) |call| {
        assert(call.index + 1 <= argv.len);
        return runVerb(allocator, io, call.verb, argv[call.index + 1 ..], call.global_socket);
    }

    const parsed = try parseAttachArgsOrFail(io, argv);
    if (parsed.show_help) {
        try printUsage(io);
        return;
    }
    if (parsed.show_version) {
        try printVersion(io);
        return;
    }
    return runAttach(allocator, io, parsed);
}

/// A management verb found on the command line.
const VerbCall = struct {
    verb: Verb,
    /// Index of the verb in argv; its arguments follow it.
    index: usize,
    global_socket: ?[]const u8,
};

/// The management verb in `argv`, if any. Global socket options may precede
/// the verb.
fn findVerb(argv: []const []const u8) ?VerbCall {
    var verb_index: usize = 1;
    var global_socket: ?[]const u8 = null;
    while (verb_index + 1 < argv.len and std.mem.eql(u8, argv[verb_index], "--socket")) : (verb_index += 2) {
        global_socket = argv[verb_index + 1];
    }
    if (verb_index >= argv.len) return null;
    const verb = parseVerb(argv[verb_index]) orelse return null;
    assert(verb_index >= 1 and verb_index % 2 == 1);
    assert((global_socket != null) == (verb_index > 1));
    return .{ .verb = verb, .index = verb_index, .global_socket = global_socket };
}

/// `parseAttachArgs`, with every failure reported as a usage message.
fn parseAttachArgsOrFail(io: std.Io, argv: []const []const u8) error{InvalidArguments}!ParsedAttachArgs {
    var failure: ParseAttachArgsFailure = .{ .err = error.UnknownFlag };
    const parsed = parseAttachArgs(argv, &failure) catch |err| {
        const arg = escaped(failure.arg orelse "");
        return switch (err) {
            error.MissingSocketValue => fail(io, "missing value for --socket", .{}),
            error.MissingCommandValue => fail(io, "missing value for --command", .{}),
            error.MissingDetachKeyValue => fail(io, "missing value for --detach-key", .{}),
            error.InvalidDetachKeyValue => fail(io, "invalid --detach-key: {f}", .{arg}),
            error.UnknownFlag => fail(io, "unknown flag: {f}", .{arg}),
            error.UnexpectedArgument => fail(io, "unexpected argument: {f}", .{arg}),
        };
    };
    // Detach keys are C-a..C-z or the default C-\ chord.
    if (parsed.detach_key) |key| assert((key >= 0x01 and key <= 0x1A) or key == 0x1C);
    return parsed;
}

/// Attach to (or create) the session named on the command line and run the
/// interactive loop until it ends.
fn runAttach(allocator: std.mem.Allocator, io: std.Io, parsed: ParsedAttachArgs) !void {
    const sid = parsed.session_id orelse return fail(io, "session_id is required", .{});
    const path = try resolveSocketPath(allocator, io, parsed.explicit_socket_path);
    defer allocator.free(path);

    const socket_fd = try connectWithRetry(allocator, io, path, parsed.spawn_daemon);
    defer sys.close(socket_fd);
    assert(socket_fd >= 3);
    var reader: LineReader = .{};
    defer reader.deinit();

    try warnOnVersionMismatch(allocator, &reader, socket_fd, .fromNow(io, version_handshake_timeout_ms));

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;
    const is_tty = sys.isatty(stdin_fd);
    const size = currentTerminalSize(stdout_fd, stdin_fd) orelse TerminalSize{ .rows = 24, .cols = 80 };
    assert(size.rows > 0 and size.cols > 0);
    var notifications: BootstrapNotifications = .{};
    defer notifications.deinit(allocator);
    var deadline = Deadline.fromNow(io, bootstrap_response_timeout_ms);
    deadline.notifications = &notifications;
    const create_command = parsed.create_command;
    const auto_create = parsed.auto_create;
    var attach = try attachOrCreate(allocator, &reader, socket_fd, sid, size, auto_create, create_command, deadline);
    defer attach.deinit(allocator);

    const setup = enterTerminalGuarded(stdin_fd, stdout_fd, is_tty);
    defer leaveTerminal();
    try setup;

    try replayScrollback(allocator, attach.result(), stdout_fd);
    if (attachExited(attach)) {
        try printExitStatus(io, attach.result());
        deadline = .fromNow(io, bootstrap_response_timeout_ms);
        deadline.notifications = &notifications;
        const next = try respawnAndReattach(allocator, &reader, socket_fd, attach.result(), size, deadline);
        attach.deinit(allocator);
        attach = next;
        try replayScrollback(allocator, attach.result(), stdout_fd);
        if (attachExited(attach)) {
            try printExitStatus(io, attach.result());
            try stderrWrite(io, if (g_termios_saved.load(.seq_cst)) "session ended\r\n" else "session ended\n");
            return;
        }
    }

    const pane_id = try requiredString(attach.result(), "paneId");
    const client_id = try requiredString(attach.result(), "clientId");
    assert(pane_id.len > 0 and client_id.len > 0);
    const outcome = try runLoop(stdin_fd, stdout_fd, socket_fd, &reader, allocator, .{
        .pane_id = pane_id,
        .client_id = client_id,
        .generation = jsonUnsigned(attach.result(), "generation"),
        .replay_end = jsonUnsigned(attach.result(), "replayEndOffset"),
        .detach_key = if (is_tty) parsed.detach_key else null,
        .piped = !is_tty,
        .bootstrap_lines = notifications.lines.items,
        .io = io,
    });

    leaveTerminal();
    try reportOutcome(io, outcome);
}

/// True when an attach reply says the pane's process has already exited.
fn attachExited(attach: Response) bool {
    const exited = jsonField(attach.result(), "exited");
    return exited == .bool and exited.bool;
}

/// Tell the user how the interactive session ended.
fn reportOutcome(io: std.Io, outcome: RunOutcome) !void {
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

fn printExitStatus(io: std.Io, result: std.json.Value) !void {
    var buf: [128]u8 = undefined;
    const message = if (jsonUnsigned(result, "exitCode")) |code|
        try std.fmt.bufPrint(&buf, "[session exited: code {d}]", .{code})
    else if (jsonUnsigned(result, "signal")) |signal|
        try std.fmt.bufPrint(&buf, "[session exited: signal {d}]", .{signal})
    else
        "[session exited]";
    try stderrWrite(io, message);
    try stderrWrite(io, if (g_termios_saved.load(.seq_cst)) "\r\n" else "\n");
}

/// Internal hooks for repository fuzz and benchmark code.
pub const fuzz_hooks = struct {
    pub const VerbKind = cli.Verb;
    pub const RunOutcomeKind = events.RunOutcome;
    pub const RunLoopOpts = run_loop.RunLoopOptions;
    pub const TermSize = terminal.TerminalSize;
    pub const RpcDeadline = rpc.Deadline;
    pub const default_detach = wire.default_detach_key;
    pub const ping_id = wire.ping_rpc_id;
    pub const verb_id = wire.verb_rpc_id;
    pub const parseAttachArgsFn = cli.parseAttachArgs;
    pub const parseVerbArgsFn = cli.parseVerbArgs;
    pub const parseDetachKeyFn = cli.parseDetachKey;
    pub const controlByteFn = cli.controlByte;
    pub const parseVerbFn = cli.parseVerb;
    pub const verbNameFn = cli.verbName;
    pub const buildVerbRequestFn = verbs.buildVerbRequest;
    pub const formatVerbResultFn = verbs.formatVerbResult;
    pub const formatSessionListFn = verbs.formatSessionList;
    pub const RunStateKind = events.RunState;
    pub const handleServerLineFn = events.handleServerLine;
    pub const handleServerLineDomFn = events.handleServerLineDom;
    pub const replayScrollbackFromAttachFn = terminal.replayScrollback;
    pub const attachOrCreateFn = rpc.attachOrCreate;
    pub const executeVerbFn = verbs.executeVerb;
    pub const readRpcResponseFn = rpc.readRpcResponse;
    pub const runLoopFn = run_loop.runLoop;
    pub const b64EncodeFn = wire.base64Encode;
    pub const b64DecodeFn = wire.base64Decode;
    pub const findDaemonSiblingFn = spawn.findDaemonSibling;
    pub const sendFrameFn = terminal.sendFrame;
    pub const rpcErrorFromEnvelopeFn = wire.RpcError.fromEnvelope;
    pub const requiredStringFn = wire.requiredString;
    pub const mayHaveKeyFn = wire.mayHaveKey;
    pub const warnOnVersionMismatchFn = rpc.warnOnVersionMismatch;

    /// Free a response returned by `readRpcResponseFn` or `attachOrCreateFn`.
    pub fn deinitResponse(response: Response, allocator: std.mem.Allocator) void {
        response.deinit(allocator);
    }

    /// The `result` member of a response.
    pub fn responseResult(response: Response) std.json.Value {
        return response.result();
    }
};

test "management verbs follow global socket options and nothing else" {
    const call = findVerb(&.{ "zmux-connect", "--socket", "s", "kill", "work" }).?;
    try std.testing.expectEqual(Verb.kill, call.verb);
    try std.testing.expectEqual(@as(usize, 3), call.index);
    try std.testing.expectEqualStrings("s", call.global_socket.?);
    try std.testing.expect(findVerb(&.{ "zmux-connect", "work" }) == null);
    try std.testing.expect(findVerb(&.{ "zmux-connect", "--socket" }) == null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("connect/cli.zig");
    _ = @import("connect/events.zig");
    _ = @import("connect/rpc.zig");
    _ = @import("connect/run_loop.zig");
    _ = @import("connect/spawn.zig");
    _ = @import("connect/terminal.zig");
    _ = @import("connect/verbs.zig");
    _ = @import("connect/wire.zig");
}
