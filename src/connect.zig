const std = @import("std");
const builtin = @import("builtin");
const rpc_line_reader = @import("rpc_line_reader.zig");
const protocol = @import("protocol.zig");

const posix = std.posix;
const LineReader = rpc_line_reader.LineReader;

const buffer_size: usize = 32 * 1024;
const rpc_line_max: usize = 1024 * 1024;
const run_loop_poll_timeout_ms: i32 = 100;
const bootstrap_response_timeout_ms: i64 = 10_000;
const version_handshake_timeout_ms: i64 = 2_000;

// Default detach chord: Ctrl-\ (0x1C). Chosen because it maps to SIGQUIT,
// which raw mode disables anyway, so it is rarely wanted by the attached
// program and makes a safe single-byte escape hatch. Configurable via
// --detach-key (ctrl-<letter> | none).
const default_detach_key: u8 = 0x1C;

// JSON-RPC ids reserved by the client. Attach/create use 1..3, resize uses 3,
// send uses 2; keep these distinct so their responses are unambiguous.
const ping_rpc_id: u32 = 100;
const detach_rpc_id: u32 = 5;
const verb_rpc_id: u32 = 1;

var g_saved_termios: ?posix.termios = null;
var g_saved_termios_fd: posix.fd_t = 0;
var g_winch_flag = std.atomic.Value(bool).init(false);

pub const panic = std.debug.FullPanic(connectPanic);

fn connectPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreTermios();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main() void {
    runMain() catch |err| {
        switch (err) {
            error.InvalidArguments, error.ReadTimeout, error.RpcError => {},
            else => {
                var buf: [1024]u8 = undefined;
                var w = std.fs.File.stderr().writer(&buf);
                w.interface.print("zmux-connect: {s}\n", .{@errorName(err)}) catch {};
                w.interface.flush() catch {};
            },
        }
        std.process.exit(1);
    };
}

fn runMain() !void {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    const allocator = dbg.allocator();
    defer _ = dbg.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Management verbs (`ls`, `kill`, `rename`, `shutdown`) are dispatched from
    // the first positional token. A bare `zmux-connect <name>` still attaches,
    // so anything that isn't a known verb falls through to the attach path.
    if (argv.len >= 2) {
        if (parseVerb(argv[1])) |verb| {
            return runVerb(allocator, verb, argv[2..]);
        }
    }

    var session_id: ?[]const u8 = null;
    var explicit_socket_path: ?[]const u8 = null;
    var spawn_daemon = false;
    var auto_create = true;
    var create_command: ?[]const u8 = null;
    var show_version = false;
    var detach_key: ?u8 = default_detach_key;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= argv.len) return fail("missing value for --socket", .{});
            explicit_socket_path = argv[i];
        } else if (std.mem.eql(u8, a, "--spawn-daemon")) {
            spawn_daemon = true;
        } else if (std.mem.eql(u8, a, "--no-create")) {
            auto_create = false;
        } else if (std.mem.eql(u8, a, "--command")) {
            i += 1;
            if (i >= argv.len) return fail("missing value for --command", .{});
            create_command = argv[i];
        } else if (std.mem.eql(u8, a, "--detach-key")) {
            i += 1;
            if (i >= argv.len) return fail("missing value for --detach-key", .{});
            detach_key = parseDetachKey(argv[i]) catch return fail("invalid --detach-key: {s}", .{argv[i]});
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            show_version = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printUsage();
            return;
        } else if (a.len > 0 and a[0] == '-') {
            return fail("unknown flag: {s}", .{a});
        } else if (session_id == null) {
            session_id = a;
        } else {
            return fail("unexpected argument: {s}", .{a});
        }
    }

    if (show_version) {
        try printVersion();
        return;
    }

    const sid = session_id orelse return fail("session_id is required", .{});

    const path = if (explicit_socket_path) |value|
        try allocator.dupe(u8, value)
    else
        try resolveSocketPath(allocator);
    defer allocator.free(path);

    const socket_fd = connectWithRetry(allocator, path, spawn_daemon) catch |err| {
        if (try connectFailureMessage(allocator, path, err)) |message| {
            defer allocator.free(message);
            return fail("{s}", .{message});
        }
        return err;
    };
    defer posix.close(socket_fd);
    var socket_reader: LineReader = .{};

    // Probe the daemon's protocol version before attaching. A version skew is
    // only a warning: the daemon persists across upgrades by design, so we
    // continue rather than abort. Uses its own short deadline so a hung daemon
    // here does not eat into the attach budget below.
    warnOnVersionMismatch(
        allocator,
        &socket_reader,
        socket_fd,
        std.time.milliTimestamp() + version_handshake_timeout_ms,
    );

    const initial_size = terminalSize(0) orelse @as(TerminalSize, .{ .rows = 24, .cols = 80 });
    const attach_response = try attachOrCreate(
        allocator,
        &socket_reader,
        socket_fd,
        sid,
        initial_size,
        auto_create,
        create_command,
        std.time.milliTimestamp() + bootstrap_response_timeout_ms,
    );
    defer allocator.free(attach_response);
    if (findJsonField(attach_response, "\"error\"")) |_| {
        try stderrWrite(attach_response);
        std.process.exit(1);
    }

    // The user may have launched us with a session NAME ("work"), but every
    // subsequent RPC (`session.send`, `session.resize`) is routed through
    // the daemon's pane lookup, which is keyed on the auto-generated pane
    // id. Pull the canonical paneId out of the attach response so we don't
    // try to resolve a name on every keystroke.
    const target_pane_id = paneIdFromAttach(allocator, attach_response) catch try allocator.dupe(u8, sid);
    defer allocator.free(target_pane_id);

    // The logical clientId identifies this attachment to the daemon; we need it
    // to send `client.detach` when the user hits the detach chord. If the
    // response somehow omits it we detach locally without notifying the daemon.
    const client_id: ?[]u8 = clientIdFromAttach(allocator, attach_response) catch null;
    defer if (client_id) |cid| allocator.free(cid);

    const stdin_fd: posix.fd_t = 0;
    const stdout_fd: posix.fd_t = 1;

    const stdin_is_tty = posix.isatty(stdin_fd);
    if (stdin_is_tty) try enterRawMode(stdin_fd);
    defer restoreTermios();

    installSigwinchHandler();
    installExitRestoreHandlers();

    replayScrollbackFromAttach(allocator, attach_response, stdout_fd) catch {};

    // Send an initial resize from our terminal's current size, if known.
    sendResize(allocator, socket_fd, target_pane_id, stdout_fd) catch {};

    // Detach interception is an interactive feature: only scan for the chord
    // when stdin is a real terminal so piped input can carry the byte verbatim.
    const active_detach_key: ?u8 = if (stdin_is_tty) detach_key else null;

    const outcome = runLoop(stdin_fd, stdout_fd, socket_fd, &socket_reader, allocator, target_pane_id, .{
        .detach_key = active_detach_key,
        .client_id = client_id,
    }) catch |err| {
        restoreTermios();
        if (err == error.ReadTimeout) {
            return fail("daemon at {s} is not responding; is zmuxd hung?", .{path});
        }
        return fail("{s}", .{@errorName(err)});
    };

    restoreTermios();
    switch (outcome) {
        .detached => stderrWrite("[detached]\n") catch {},
        .session_ended => stderrWrite("session ended\n") catch {},
        .connection_lost => {
            stderrWrite("zmux-connect: daemon connection lost\n") catch {};
            std.process.exit(1);
        },
        .exited => {},
    }
}

fn printVersion() !void {
    var buf: [64]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    try out.interface.print("zmux-connect {s}\n", .{protocol.version});
    try out.interface.flush();
}

// Send `client.attach` and, if the daemon reports `PaneNotFound` and
// `auto_create` is enabled, try `session.create` followed by a second attach.
// On success the returned slice is the final `client.attach` response and the
// caller owns it. Errors propagating from the underlying I/O bubble up
// unchanged. If both attempts return JSON-RPC errors, the latest error
// payload is returned (so the caller can print it).
fn attachOrCreate(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    socket_fd: posix.fd_t,
    sid: []const u8,
    size: TerminalSize,
    auto_create: bool,
    create_command: ?[]const u8,
    deadline_ms: i64,
) ![]u8 {
    var first = try sendAttach(allocator, reader, socket_fd, sid, size, 1, deadline_ms);
    // The errdefer is guarded so the manual `allocator.free(first)` below
    // doesn't double-free if a later step (`sendCreate`, the create
    // response read, the retry attach) returns an error.
    errdefer if (first.len != 0) allocator.free(first);

    if (!isPaneNotFound(first)) return first;
    if (!auto_create) return first;

    allocator.free(first);
    first = &.{};

    try sendCreate(allocator, socket_fd, sid, size, create_command, 2);

    // The daemon broadcasts pane_output / pane_activity / pane_bell
    // notifications to every connection as soon as the PTY child starts —
    // including this connection, which has not attached yet. Filter on the
    // JSON-RPC `id` so we don't consume a notification as the create
    // response.
    const create_response = try readRpcResponse(allocator, reader, socket_fd, 2, deadline_ms);
    defer allocator.free(create_response);
    if (findJsonField(create_response, "\"error\"")) |_| {
        return try allocator.dupe(u8, create_response);
    }

    return try sendAttach(allocator, reader, socket_fd, sid, size, 3, deadline_ms);
}

fn sendAttach(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    socket_fd: posix.fd_t,
    sid: []const u8,
    size: TerminalSize,
    rpc_id: u32,
    deadline_ms: i64,
) ![]u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"client.attach\",\"params\":{{\"paneId\":{f},\"rows\":{},\"cols\":{}}}}}\n",
        .{ rpc_id, std.json.fmt(sid, .{}), size.rows, size.cols },
    );
    defer allocator.free(req);
    try writeAll(socket_fd, req);
    return readRpcResponse(allocator, reader, socket_fd, rpc_id, deadline_ms);
}

// Read newline-delimited JSON-RPC frames until we find the response
// matching `expected_id`. Notifications (no `id` field) and any
// out-of-order responses are silently discarded. We keep this helper
// internal to the bootstrap (attach + create) sequence; once `runLoop`
// takes over it has its own classifier in `processServerLine`.
fn readRpcResponse(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    fd: posix.fd_t,
    expected_id: u32,
    deadline_ms: i64,
) ![]u8 {
    while (true) {
        const line = try reader.readLineAllocWithDeadline(allocator, fd, rpc_line_max, deadline_ms);
        if (matchesRpcId(allocator, line, expected_id)) return line;
        allocator.free(line);
    }
}

fn matchesRpcId(allocator: std.mem.Allocator, line: []const u8, expected_id: u32) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const id_value = parsed.value.object.get("id") orelse return false;
    if (id_value != .integer) return false;
    return id_value.integer == @as(i64, expected_id);
}

fn sendCreate(
    allocator: std.mem.Allocator,
    socket_fd: posix.fd_t,
    sid: []const u8,
    size: TerminalSize,
    command: ?[]const u8,
    rpc_id: u32,
) !void {
    const req = if (command) |cmd| try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.create\",\"params\":{{\"id\":{f},\"rows\":{},\"cols\":{},\"command\":{f}}}}}\n",
        .{ rpc_id, std.json.fmt(sid, .{}), size.rows, size.cols, std.json.fmt(cmd, .{}) },
    ) else try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"session.create\",\"params\":{{\"id\":{f},\"rows\":{},\"cols\":{}}}}}\n",
        .{ rpc_id, std.json.fmt(sid, .{}), size.rows, size.cols },
    );
    defer allocator.free(req);
    try writeAll(socket_fd, req);
}

fn isPaneNotFound(response: []const u8) bool {
    if (findJsonField(response, "\"error\"") == null) return false;
    return findJsonField(response, "PaneNotFound") != null;
}

// Extract `result.paneId` (the daemon's canonical pane id) from a
// `client.attach` response. The daemon answers every input RPC by looking
// up the pane via that id, so we use it instead of whatever the user
// passed on the command line (which may be a session name).
fn paneIdFromAttach(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MissingPaneId;
    const result = parsed.value.object.get("result") orelse return error.MissingPaneId;
    const pane_id = jsonObjectString(result, "paneId") orelse return error.MissingPaneId;
    return allocator.dupe(u8, pane_id);
}

// Extract `result.clientId` (the daemon's logical attachment id) from a
// `client.attach` response so the client can later send `client.detach`.
fn clientIdFromAttach(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MissingClientId;
    const result = parsed.value.object.get("result") orelse return error.MissingClientId;
    const client_id = jsonObjectString(result, "clientId") orelse return error.MissingClientId;
    return allocator.dupe(u8, client_id);
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
fn controlByte(c: u8) ?u8 {
    if (std.ascii.isAlphabetic(c)) return std.ascii.toUpper(c) - 'A' + 1;
    if (c == '\\') return 0x1C;
    return null;
}

// Best-effort protocol version probe: send daemon.ping and warn on stderr if
// the daemon reports a different protocol version than this client compiled
// against. Never aborts — a version skew is expected across daemon upgrades.
fn warnOnVersionMismatch(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    socket_fd: posix.fd_t,
    deadline_ms: i64,
) void {
    const daemon_ver = daemonVersion(allocator, reader, socket_fd, deadline_ms) catch return;
    defer allocator.free(daemon_ver);
    if (std.mem.eql(u8, daemon_ver, protocol.version)) return;

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print(
        "zmux-connect: warning: daemon protocol {s} differs from client {s}; continuing\n",
        .{ daemon_ver, protocol.version },
    ) catch {};
    w.interface.flush() catch {};
}

fn daemonVersion(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    socket_fd: posix.fd_t,
    deadline_ms: i64,
) ![]u8 {
    const req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"daemon.ping\",\"params\":{{}}}}\n",
        .{ping_rpc_id},
    );
    defer allocator.free(req);
    try writeAll(socket_fd, req);

    const response = try readRpcResponse(allocator, reader, socket_fd, ping_rpc_id, deadline_ms);
    defer allocator.free(response);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MissingVersion;
    const result = parsed.value.object.get("result") orelse return error.MissingVersion;
    const version = jsonObjectString(result, "version") orelse return error.MissingVersion;
    return allocator.dupe(u8, version);
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

fn runVerb(allocator: std.mem.Allocator, verb: Verb, rest: []const []const u8) !void {
    var target: ?[]const u8 = null;
    var new_name: ?[]const u8 = null;
    var json = false;
    var explicit_socket: ?[]const u8 = null;

    const needs_target = (verb == .kill or verb == .rename);
    const needs_new_name = (verb == .rename);

    var positionals: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= rest.len) return fail("missing value for --socket", .{});
            explicit_socket = rest[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try printUsage();
            return;
        } else if (a.len > 0 and a[0] == '-') {
            return fail("unknown flag: {s}", .{a});
        } else if (positionals == 0 and needs_target) {
            target = a;
            positionals += 1;
        } else if (positionals == 1 and needs_new_name) {
            new_name = a;
            positionals += 1;
        } else {
            return fail("unexpected argument: {s}", .{a});
        }
    }

    if (needs_target and target == null) return fail("{s} requires a session id", .{verbName(verb)});
    if (needs_new_name and new_name == null) return fail("rename requires a new name", .{});

    const path = if (explicit_socket) |value|
        try allocator.dupe(u8, value)
    else
        try resolveSocketPath(allocator);
    defer allocator.free(path);

    const socket_fd = tryConnect(path) catch {
        return verbError("no daemon reachable at {s}", .{path});
    };
    defer posix.close(socket_fd);

    var reader: LineReader = .{};
    try executeVerb(
        allocator,
        socket_fd,
        &reader,
        verb,
        target,
        new_name,
        json,
        1,
        std.time.milliTimestamp() + bootstrap_response_timeout_ms,
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
    deadline_ms: i64,
) !void {
    const request = try buildVerbRequest(allocator, verb, target, new_name);
    defer allocator.free(request);
    try writeAll(socket_fd, request);

    const response = try readRpcResponse(allocator, reader, socket_fd, verb_rpc_id, deadline_ms);
    defer allocator.free(response);

    if (rpcErrorMessage(allocator, response)) |msg| {
        defer allocator.free(msg);
        var buf: [1024]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("zmux-connect: {s}\n", .{msg}) catch {};
        w.interface.flush() catch {};
        return error.RpcError;
    }

    if (json) {
        try writeAllFd(out_fd, response);
        return;
    }

    const human = try formatVerbResult(allocator, verb, target, new_name, response);
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
    response: []const u8,
) ![]u8 {
    return switch (verb) {
        .list => formatSessionList(allocator, response),
        .kill => std.fmt.allocPrint(allocator, "killed session {s}\n", .{target.?}),
        .rename => std.fmt.allocPrint(allocator, "renamed session {s} to {s}\n", .{ target.?, new_name.? }),
        .shutdown => allocator.dupe(u8, "daemon shutdown\n"),
    };
}

// Render a `session.list` result array as one tab-separated line per pane:
//   <sessionId>\t<paneId>\t<state>\tpid=<pid>\t<title>
fn formatSessionList(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .array) return error.InvalidResponse;

    if (result.array.items.len == 0) {
        try out.appendSlice(allocator, "no sessions\n");
        return out.toOwnedSlice(allocator);
    }

    for (result.array.items) |item| {
        if (item != .object) continue;
        const session_id = jsonObjectString(item, "sessionId") orelse "";
        const pane_id = jsonObjectString(item, "paneId") orelse "";
        const state = jsonObjectString(item, "state") orelse "";
        const title = jsonObjectString(item, "title") orelse "";
        const pid = jsonObjectInt(item, "pid");
        const line = try std.fmt.allocPrint(
            allocator,
            "{s}\t{s}\t{s}\tpid={d}\t{s}\n",
            .{ session_id, pane_id, state, pid, title },
        );
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    return out.toOwnedSlice(allocator);
}

// Return the daemon's `error.message` text (caller owns) when `response` is a
// JSON-RPC error frame, or null for a success frame. Uses a real JSON parse so
// a result payload that merely contains the word "error" is not misread.
fn rpcErrorMessage(allocator: std.mem.Allocator, response: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err = parsed.value.object.get("error") orelse return null;
    if (err != .object) return allocator.dupe(u8, "unknown error") catch null;
    const message = err.object.get("message") orelse return allocator.dupe(u8, "unknown error") catch null;
    if (message != .string) return allocator.dupe(u8, "unknown error") catch null;
    return allocator.dupe(u8, message.string) catch null;
}

fn verbError(comptime fmt: []const u8, args: anytype) error{RpcError} {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("zmux-connect: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    return error.RpcError;
}

const RunOutcome = enum { exited, session_ended, detached, connection_lost };

const RunLoopOptions = struct {
    // Detach chord byte to intercept on stdin, or null to disable interception.
    detach_key: ?u8 = null,
    // Logical clientId to release via `client.detach` on detach, if known.
    client_id: ?[]const u8 = null,
};

fn runLoop(
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    socket_fd: posix.fd_t,
    reader: *LineReader,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    options: RunLoopOptions,
) !RunOutcome {
    var buf: [buffer_size]u8 = undefined;

    while (true) {
        if (g_winch_flag.swap(false, .seq_cst)) {
            sendResize(allocator, socket_fd, session_id, stdout_fd) catch {};
        }

        var fds = [_]posix.pollfd{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = socket_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = try posix.poll(&fds, run_loop_poll_timeout_ms);
        if (g_winch_flag.swap(false, .seq_cst)) {
            sendResize(allocator, socket_fd, session_id, stdout_fd) catch {};
        }
        if (ready == 0) continue;

        if ((fds[1].revents & posix.POLL.HUP) != 0) {
            const saw_exit = try drainReadableSocket(allocator, reader, socket_fd, session_id, stdout_fd);
            return if (saw_exit) .session_ended else .connection_lost;
        }

        if ((fds[1].revents & posix.POLL.IN) != 0) {
            if (try handleReadableSocket(allocator, reader, socket_fd, session_id, stdout_fd)) return .session_ended;
        }

        if ((fds[1].revents & posix.POLL.ERR) != 0) return .connection_lost;

        if ((fds[0].revents & posix.POLL.IN) != 0) {
            switch (try readStdinChunk(stdin_fd, &buf)) {
                .again => continue,
                .eof => return .exited,
                .bytes => |bytes| {
                    // Intercept the detach chord before forwarding: raw mode
                    // disables ISIG so we are scanning raw bytes. Forward any
                    // bytes that precede the chord, then detach.
                    if (options.detach_key) |chord| {
                        if (std.mem.indexOfScalar(u8, bytes, chord)) |pos| {
                            if (pos > 0) try sendInput(allocator, socket_fd, session_id, bytes[0..pos]);
                            if (options.client_id) |cid| sendDetach(allocator, socket_fd, cid) catch {};
                            return .detached;
                        }
                    }
                    try sendInput(allocator, socket_fd, session_id, bytes);
                },
            }
        }

        if ((fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return .exited;
    }
}

fn sendDetach(allocator: std.mem.Allocator, socket_fd: posix.fd_t, client_id: []const u8) !void {
    const msg = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"client.detach\",\"params\":{{\"clientId\":{f}}}}}\n",
        .{ detach_rpc_id, std.json.fmt(client_id, .{}) },
    );
    defer allocator.free(msg);
    try writeAll(socket_fd, msg);
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

fn handleReadableSocket(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    socket_fd: posix.fd_t,
    session_id: []const u8,
    stdout_fd: posix.fd_t,
) !bool {
    const first_line = try reader.readLineAlloc(allocator, socket_fd, rpc_line_max);
    defer allocator.free(first_line);
    if (try handleServerLine(allocator, first_line, session_id, stdout_fd)) return true;

    while (try reader.nextBufferedLineAlloc(allocator, rpc_line_max)) |line| {
        const should_exit = try handleServerLine(allocator, line, session_id, stdout_fd);
        allocator.free(line);
        if (should_exit) return true;
    }

    return false;
}

fn drainReadableSocket(
    allocator: std.mem.Allocator,
    reader: *LineReader,
    socket_fd: posix.fd_t,
    session_id: []const u8,
    stdout_fd: posix.fd_t,
) !bool {
    var saw_exit = false;
    while (try reader.readLineAllocMaybe(allocator, socket_fd, rpc_line_max)) |line| {
        const should_exit = try handleServerLine(allocator, line, session_id, stdout_fd);
        allocator.free(line);
        if (should_exit) saw_exit = true;
    }
    return saw_exit;
}

fn connectWithRetry(allocator: std.mem.Allocator, path: []const u8, spawn_daemon: bool) !posix.fd_t {
    if (tryConnect(path)) |fd| return fd else |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => {
            if (!spawn_daemon) return err;
        },
        else => return err,
    }

    try spawnDaemonDetached(allocator, path);

    const deadline_ms = std.time.milliTimestamp() + 2000;
    while (std.time.milliTimestamp() < deadline_ms) {
        if (tryConnect(path)) |fd| return fd else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            },
            else => return err,
        }
    }
    return error.DaemonUnavailable;
}

fn connectFailureMessage(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !?[]u8 {
    return switch (err) {
        error.ConnectionRefused, error.FileNotFound => try std.fmt.allocPrint(
            allocator,
            "no daemon at {s}; start zmuxd or pass --spawn-daemon",
            .{path},
        ),
        error.DaemonUnavailable => try std.fmt.allocPrint(
            allocator,
            "daemon at {s} did not become ready within 2s; see {s}.log",
            .{ path, path },
        ),
        else => null,
    };
}

fn tryConnect(path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    const address = std.net.Address.initUnix(path) catch return error.FileNotFound;
    try posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
}

fn spawnDaemonDetached(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    // Locate the daemon binary by looking next to our own executable.
    const self_path = std.fs.selfExePathAlloc(allocator) catch |err| return err;
    defer allocator.free(self_path);
    const dir = std.fs.path.dirname(self_path) orelse ".";
    const daemon_path = try findDaemonSibling(allocator, dir, std.fs.path.basename(self_path));
    defer allocator.free(daemon_path);

    const pid = try posix.fork();
    if (pid != 0) return;

    // Child: detach and exec.
    _ = std.c.setsid();
    // Redirect stdio to /dev/null, and stderr to the socket log for startup diagnostics.
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch std.c._exit(127);
    _ = std.c.dup2(devnull, 0);
    _ = std.c.dup2(devnull, 1);

    const log_path = std.fmt.allocPrint(allocator, "{s}.log", .{socket_path}) catch std.c._exit(127);
    defer allocator.free(log_path);
    const log_fd = posix.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600) catch devnull;
    _ = std.c.dup2(log_fd, 2);
    if (log_fd > 2) posix.close(log_fd);

    if (devnull > 2) posix.close(devnull);

    const daemon_z = allocator.dupeZ(u8, daemon_path) catch std.c._exit(127);
    const socket_flag_z = allocator.dupeZ(u8, "--socket") catch std.c._exit(127);
    const path_z = allocator.dupeZ(u8, socket_path) catch std.c._exit(127);
    const argv = [_:null]?[*:0]const u8{ daemon_z.ptr, socket_flag_z.ptr, path_z.ptr };
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    posix.execvpeZ(daemon_z.ptr, &argv, envp) catch {};
    std.c._exit(127);
}

fn enterRawMode(fd: posix.fd_t) !void {
    const current = posix.tcgetattr(fd) catch |err| switch (err) {
        error.NotATerminal => return,
        else => return err,
    };
    g_saved_termios = current;
    g_saved_termios_fd = fd;

    var raw = current;
    // Input: disable CR/NL translation, parity, strip, XON/XOFF.
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    // Output: disable post-processing (we forward bytes verbatim).
    raw.oflag.OPOST = false;
    // Local: disable echo, canonical mode, signal generation, extended input.
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    try posix.tcsetattr(fd, .FLUSH, raw);
}

fn restoreTermios() void {
    if (g_saved_termios) |saved| {
        posix.tcsetattr(g_saved_termios_fd, .FLUSH, saved) catch {};
        g_saved_termios = null;
    }
}

fn winchHandler(_: c_int) callconv(.c) void {
    g_winch_flag.store(true, .seq_cst);
}

fn exitRestoreHandler(sig: c_int) callconv(.c) void {
    restoreTermios();
    // Reset to default and re-raise so the default action takes effect.
    var dfl: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&dfl), 0);
    dfl.handler = .{ .handler = null };
    dfl.mask = std.mem.zeroes(posix.sigset_t);
    dfl.flags = 0;
    posix.sigaction(@intCast(sig), &dfl, null);
    _ = std.c.raise(sig);
}

fn installSigwinchHandler() void {
    var act: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = winchHandler };
    act.mask = std.mem.zeroes(posix.sigset_t);
    act.flags = 0;
    posix.sigaction(std.c.SIG.WINCH, &act, null);
}

fn installExitRestoreHandlers() void {
    // Raw mode disables ISIG, so interactive ^C is forwarded as input bytes.
    // Signal-delivered INT/TERM still need to restore the local terminal.
    var act: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = exitRestoreHandler };
    act.mask = std.mem.zeroes(posix.sigset_t);
    act.flags = 0;
    posix.sigaction(std.c.SIG.HUP, &act, null);
    posix.sigaction(std.c.SIG.PIPE, &act, null);
    posix.sigaction(std.c.SIG.QUIT, &act, null);
    posix.sigaction(std.c.SIG.INT, &act, null);
    posix.sigaction(std.c.SIG.TERM, &act, null);
}

fn sendResize(
    allocator: std.mem.Allocator,
    socket_fd: posix.fd_t,
    session_id: []const u8,
    tty_fd: posix.fd_t,
) !void {
    const size = terminalSize(tty_fd) orelse return;

    const msg = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session.resize\",\"params\":{{\"sessionId\":{f},\"cols\":{},\"rows\":{}}}}}\n",
        .{ std.json.fmt(session_id, .{}), size.cols, size.rows },
    );
    defer allocator.free(msg);
    writeAll(socket_fd, msg) catch {};
}

const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

fn terminalSize(tty_fd: posix.fd_t) ?TerminalSize {
    var wsz: posix.winsize = undefined;
    const req = tiocgwinsz();
    if (std.c.ioctl(tty_fd, @as(c_int, @bitCast(@as(u32, @truncate(req)))), &wsz) != 0) return null;
    if (wsz.col == 0 or wsz.row == 0) return null;
    return .{ .rows = wsz.row, .cols = wsz.col };
}

// Mirrors daemon.zig::socketPath. Keep in sync.
fn resolveSocketPath(allocator: std.mem.Allocator) ![]u8 {
    return resolveSocketPathFromEnv(
        allocator,
        std.posix.getenv("ZMUX_SOCKET"),
        std.posix.getenv("SMITHERS_SESSION_SOCKET"),
        std.posix.getenv("XDG_RUNTIME_DIR"),
        std.posix.getenv("HOME"),
    );
}

fn resolveSocketPathFromEnv(
    allocator: std.mem.Allocator,
    zmux_socket: ?[]const u8,
    smithers_socket: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    if (zmux_socket) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    if (smithers_socket) |value| {
        if (value.len > 0) return allocator.dupe(u8, value);
    }
    if (xdg_runtime_dir) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(allocator, &.{ xdg, "smithers-sessions.sock" });
    }
    if (home) |home_path| {
        if (home_path.len > 0) return std.fs.path.join(allocator, &.{ home_path, ".smithers", "sessions.sock" });
    }

    const fallback_dir = try std.fmt.allocPrint(allocator, "/tmp/zmux-{d}", .{posix.geteuid()});
    defer allocator.free(fallback_dir);
    return std.fs.path.join(allocator, &.{ fallback_dir, "sessions.sock" });
}

fn tiocgwinsz() usize {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x40087468,
        else => 0x5413, // TIOCGWINSZ on Linux
    };
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = posix.write(fd, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    return writeAll(fd, bytes);
}

fn handleServerLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    pane_id: []const u8,
    stdout_fd: posix.fd_t,
) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    const method = parsed.value.object.get("method") orelse return false;
    if (method != .string) return false;

    if (std.mem.eql(u8, method.string, "pane_output")) {
        const params = parsed.value.object.get("params") orelse return false;
        if (!jsonAnyStringEquals(params, &.{ "paneId", "pane_id" }, pane_id)) return false;
        const encoded = jsonAnyObjectString(params, &.{ "dataBase64", "data_base64" }) orelse return false;
        const decoded = try base64Decode(allocator, encoded);
        defer allocator.free(decoded);
        try writeAllFd(stdout_fd, decoded);
        return false;
    }

    if (std.mem.eql(u8, method.string, "session_exited")) {
        const params = parsed.value.object.get("params") orelse return false;
        return jsonAnyStringEquals(params, &.{ "sessionId", "session_id" }, pane_id);
    }

    return false;
}

fn sendInput(
    allocator: std.mem.Allocator,
    socket_fd: posix.fd_t,
    session_id: []const u8,
    bytes: []const u8,
) !void {
    const encoded = try base64Encode(allocator, bytes);
    defer allocator.free(encoded);
    const msg = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.send\",\"params\":{{\"sessionId\":{f},\"dataBase64\":{f}}}}}\n",
        .{ std.json.fmt(session_id, .{}), std.json.fmt(encoded, .{}) },
    );
    defer allocator.free(msg);
    try writeAll(socket_fd, msg);
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
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn jsonObjectInt(value: std.json.Value, key: []const u8) i64 {
    if (value != .object) return 0;
    const field = value.object.get(key) orelse return 0;
    return switch (field) {
        .integer => |n| n,
        else => 0,
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

fn findJsonField(haystack: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, haystack, needle);
}

/// Pull the `replayBase64` field out of the attach response JSON, decode
/// it, and write the raw bytes to `out_fd` so the terminal redraws the
/// prior session state.
fn replayScrollbackFromAttach(
    allocator: std.mem.Allocator,
    payload: []const u8,
    out_fd: posix.fd_t,
) !void {
    const marker = "\"replayBase64\":\"";
    const start = std.mem.indexOf(u8, payload, marker) orelse return;
    const value_start = start + marker.len;
    if (value_start >= payload.len) return;
    const value_end = std.mem.indexOfScalarPos(u8, payload, value_start, '"') orelse return;
    const encoded = payload[value_start..value_end];
    if (encoded.len == 0) return;

    const decoded = base64Decode(allocator, encoded) catch return;
    defer allocator.free(decoded);
    if (decoded.len == 0) return;
    try writeAllFd(out_fd, decoded);
}

fn stderrWrite(bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("zmux-connect: " ++ fmt ++ "\n", args) catch {};
    w.interface.print("Try 'zmux-connect --help' for usage.\n", .{}) catch {};
    w.interface.flush() catch {};
    return error.InvalidArguments;
}

fn printUsage() !void {
    var buf: [2048]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.writeAll(
        \\Usage: zmux-connect <session_id> [--socket PATH] [--spawn-daemon]
        \\                    [--no-create] [--command CMD] [--detach-key KEY]
        \\       zmux-connect <verb> [args] [--socket PATH] [--json]
        \\       smithers-session-connect ... (same interface)
        \\
        \\Attach (default): if <session_id> is not an existing pane id or session
        \\name, a new session with that name is created and then attached.
        \\  --socket PATH      path to the daemon's unix socket
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

fn findDaemonSibling(allocator: std.mem.Allocator, dir: []const u8, self_name: []const u8) ![]u8 {
    const zmux_order = [_][]const u8{ "zmuxd", "smithers-session-daemon" };
    const smithers_order = [_][]const u8{ "smithers-session-daemon", "zmuxd" };
    const candidates: []const []const u8 = if (std.mem.eql(u8, self_name, "zmux-connect"))
        &zmux_order
    else
        &smithers_order;

    for (candidates) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        if (std.fs.accessAbsolute(path, .{})) |_| {
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    return std.fs.path.join(allocator, &.{ dir, candidates[0] });
}

test "tiocgwinsz encodes the platform ioctl" {
    const req = tiocgwinsz();
    try std.testing.expect(req != 0);
}

test "resolveSocketPathFromEnv falls back to uid-scoped /tmp path" {
    const path = try resolveSocketPathFromEnv(std.testing.allocator, null, null, null, null);
    defer std.testing.allocator.free(path);
    const expected_prefix = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/zmux-{d}/sessions.sock",
        .{posix.geteuid()},
    );
    defer std.testing.allocator.free(expected_prefix);
    try std.testing.expectEqualStrings(expected_prefix, path);

    const from_home = try resolveSocketPathFromEnv(std.testing.allocator, null, null, null, "/home/me");
    defer std.testing.allocator.free(from_home);
    try std.testing.expect(std.mem.endsWith(u8, from_home, "/home/me/.smithers/sessions.sock"));
}

test "matchesRpcId accepts only the expected numeric response id" {
    try std.testing.expect(matchesRpcId(std.testing.allocator, "{\"id\":7,\"result\":{}}\n", 7));
    try std.testing.expect(!matchesRpcId(std.testing.allocator, "{\"id\":8,\"result\":{}}\n", 7));
    try std.testing.expect(!matchesRpcId(std.testing.allocator, "{\"id\":\"7\",\"result\":{}}\n", 7));
    try std.testing.expect(!matchesRpcId(std.testing.allocator, "{\"method\":\"pane_output\",\"params\":{}}\n", 7));
    try std.testing.expect(!matchesRpcId(std.testing.allocator, "not json\n", 7));
}

test "readRpcResponse skips notifications and out-of-order responses" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const fds = try std.posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try writeAll(
        fds[1],
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"stale\":true}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n",
    );

    var reader: LineReader = .{};
    const line = try readRpcResponse(std.testing.allocator, &reader, fds[0], 2, std.time.milliTimestamp() + 10_000);
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n", line);
}

test "readRpcResponse returns ReadTimeout" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const fds = try std.posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var reader: LineReader = .{};
    const deadline = std.time.milliTimestamp() + 20;
    try std.testing.expectError(
        error.ReadTimeout,
        readRpcResponse(std.testing.allocator, &reader, fds[0], 1, deadline),
    );
}

fn socketPairForTest() ![2]posix.fd_t {
    var pair: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    return pair;
}

fn readRequestLineForTest(allocator: std.mem.Allocator, reader: *LineReader, fd: posix.fd_t) ![]u8 {
    return reader.readLineAllocWithDeadline(allocator, fd, rpc_line_max, std.time.milliTimestamp() + 2_000);
}

test "attachOrCreate returns an attach success without creating" {
    const allocator = std.testing.allocator;
    const pair = try socketPairForTest();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    try writeAll(pair[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"clientId\":\"client-1\",\"paneId\":\"work\"}}\n");

    var reader: LineReader = .{};
    const response = try attachOrCreate(
        allocator,
        &reader,
        pair[0],
        "work",
        .{ .rows = 24, .cols = 80 },
        true,
        null,
        std.time.milliTimestamp() + 2_000,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"clientId\":\"client-1\"") != null);

    var request_reader: LineReader = .{};
    const attach_req = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(attach_req);
    try std.testing.expect(std.mem.indexOf(u8, attach_req, "\"method\":\"client.attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_req, "\"id\":1") != null);
}

test "attachOrCreate creates after PaneNotFound and skips interleaved notifications" {
    const allocator = std.testing.allocator;
    const pair = try socketPairForTest();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    try writeAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound: work\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"id\":\"work\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"clientId\":\"client-2\",\"paneId\":\"pane-2\"}}\n",
    );

    var reader: LineReader = .{};
    const response = try attachOrCreate(
        allocator,
        &reader,
        pair[0],
        "work",
        .{ .rows = 40, .cols = 120 },
        true,
        "printf ok",
        std.time.milliTimestamp() + 2_000,
    );
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"clientId\":\"client-2\"") != null);

    var request_reader: LineReader = .{};
    const first_attach = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(first_attach);
    const create_req = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(create_req);
    const second_attach = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(second_attach);

    try std.testing.expect(std.mem.indexOf(u8, first_attach, "\"method\":\"client.attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"method\":\"session.create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"command\":\"printf ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_attach, "\"id\":3") != null);
}

test "attachOrCreate returns PaneNotFound when auto create is disabled" {
    const allocator = std.testing.allocator;
    const pair = try socketPairForTest();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    const pane_error = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\"}}\n";
    try writeAll(pair[1], pane_error);

    var reader: LineReader = .{};
    const response = try attachOrCreate(
        allocator,
        &reader,
        pair[0],
        "missing",
        .{ .rows = 24, .cols = 80 },
        false,
        null,
        std.time.milliTimestamp() + 2_000,
    );
    defer allocator.free(response);
    try std.testing.expectEqualStrings(pane_error, response);

    var request_reader: LineReader = .{};
    const attach_req = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(attach_req);
    try std.testing.expect(std.mem.indexOf(u8, attach_req, "\"method\":\"client.attach\"") != null);
}

test "attachOrCreate returns create errors without retrying attach" {
    const allocator = std.testing.allocator;
    const pair = try socketPairForTest();
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    const create_error = "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"bad create\"}}\n";
    try writeAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\"}}\n" ++
            create_error,
    );

    var reader: LineReader = .{};
    const response = try attachOrCreate(
        allocator,
        &reader,
        pair[0],
        "bad",
        .{ .rows = 24, .cols = 80 },
        true,
        null,
        std.time.milliTimestamp() + 2_000,
    );
    defer allocator.free(response);
    try std.testing.expectEqualStrings(create_error, response);

    var request_reader: LineReader = .{};
    const attach_req = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(attach_req);
    const create_req = try readRequestLineForTest(allocator, &request_reader, pair[1]);
    defer allocator.free(create_req);
    try std.testing.expect(std.mem.indexOf(u8, attach_req, "\"method\":\"client.attach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_req, "\"method\":\"session.create\"") != null);
}

test "isPaneNotFound only matches error payloads containing PaneNotFound" {
    try std.testing.expect(isPaneNotFound("{\"error\":{\"message\":\"PaneNotFound\"}}\n"));
    try std.testing.expect(!isPaneNotFound("{\"result\":{\"message\":\"PaneNotFound\"}}\n"));
    try std.testing.expect(!isPaneNotFound("{\"error\":{\"message\":\"other\"}}\n"));
}

test "paneIdFromAttach extracts canonical pane id" {
    const pane_id = try paneIdFromAttach(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"clientId\":\"client-1\",\"paneId\":\"pane-7\"}}\n",
    );
    defer std.testing.allocator.free(pane_id);

    try std.testing.expectEqualStrings("pane-7", pane_id);
    try std.testing.expectError(
        error.MissingPaneId,
        paneIdFromAttach(std.testing.allocator, "{\"result\":{\"clientId\":\"client-1\"}}\n"),
    );
}

test "handleServerLine writes matching pane output and ignores other panes" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const ignored =
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":" ++
        "{\"pane_id\":\"pane-other\",\"data_base64\":\"aGVsbG8=\"}}\n";
    try std.testing.expect(!try handleServerLine(
        std.testing.allocator,
        ignored,
        "pane-1",
        @as(posix.fd_t, -1),
    ));

    const fds = try std.posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const matching =
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":" ++
        "{\"pane_id\":\"pane-1\",\"data_base64\":\"aGVsbG8=\"}}\n";
    try std.testing.expect(!try handleServerLine(std.testing.allocator, matching, "pane-1", fds[1]));

    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "handleServerLine exits only for matching session exit notification" {
    const matching =
        "{\"jsonrpc\":\"2.0\",\"method\":\"session_exited\",\"params\":" ++
        "{\"session_id\":\"pane-1\",\"pid\":123}}\n";
    const other =
        "{\"jsonrpc\":\"2.0\",\"method\":\"session_exited\",\"params\":" ++
        "{\"session_id\":\"pane-2\",\"pid\":123}}\n";

    try std.testing.expect(try handleServerLine(std.testing.allocator, matching, "pane-1", @as(posix.fd_t, -1)));
    try std.testing.expect(!try handleServerLine(std.testing.allocator, other, "pane-1", @as(posix.fd_t, -1)));
}

test "replayScrollbackFromAttach decodes replay bytes" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const fds = try std.posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try replayScrollbackFromAttach(
        std.testing.allocator,
        "{\"result\":{\"replayBase64\":\"cmVwbGF5IGJ5dGVz\"}}\n",
        fds[1],
    );

    var buf: [32]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings("replay bytes", buf[0..n]);
}

test "exit restore handlers include external INT and TERM signals" {
    var old_hup: posix.Sigaction = undefined;
    var old_pipe: posix.Sigaction = undefined;
    var old_quit: posix.Sigaction = undefined;
    var old_int: posix.Sigaction = undefined;
    var old_term: posix.Sigaction = undefined;
    posix.sigaction(std.c.SIG.HUP, null, &old_hup);
    posix.sigaction(std.c.SIG.PIPE, null, &old_pipe);
    posix.sigaction(std.c.SIG.QUIT, null, &old_quit);
    posix.sigaction(std.c.SIG.INT, null, &old_int);
    posix.sigaction(std.c.SIG.TERM, null, &old_term);
    defer posix.sigaction(std.c.SIG.HUP, &old_hup, null);
    defer posix.sigaction(std.c.SIG.PIPE, &old_pipe, null);
    defer posix.sigaction(std.c.SIG.QUIT, &old_quit, null);
    defer posix.sigaction(std.c.SIG.INT, &old_int, null);
    defer posix.sigaction(std.c.SIG.TERM, &old_term, null);

    installExitRestoreHandlers();

    var current_int: posix.Sigaction = undefined;
    var current_term: posix.Sigaction = undefined;
    posix.sigaction(std.c.SIG.INT, null, &current_int);
    posix.sigaction(std.c.SIG.TERM, null, &current_term);
    try std.testing.expect(current_int.handler.handler.? == exitRestoreHandler);
    try std.testing.expect(current_term.handler.handler.? == exitRestoreHandler);
}

test "stdin WouldBlock is not treated as EOF" {
    if (!@hasDecl(std.posix, "pipe2")) return error.SkipZigTest;

    const fds = try std.posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var buf: [16]u8 = undefined;
    switch (try readStdinChunk(fds[0], &buf)) {
        .again => {},
        .eof => return error.WouldBlockMappedToEof,
        .bytes => return error.UnexpectedStdinBytes,
    }
}

test "runLoop drains final socket output after HUP" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const stdin_fds = try std.posix.pipe();
    defer posix.close(stdin_fds[0]);
    defer posix.close(stdin_fds[1]);

    const socket_fds = try std.posix.pipe();
    defer posix.close(socket_fds[0]);
    var socket_write_open = true;
    defer if (socket_write_open) posix.close(socket_fds[1]);

    const stdout_fds = try std.posix.pipe();
    defer posix.close(stdout_fds[0]);
    var stdout_write_open = true;
    defer if (stdout_write_open) posix.close(stdout_fds[1]);

    const first_line = try paneOutputLineForTest(allocator, "pane-1", "FIRST\n");
    defer allocator.free(first_line);

    var tail = try allocator.alloc(u8, 5000);
    defer allocator.free(tail);
    @memset(tail, 'x');
    const marker = "TAIL_END";
    @memcpy(tail[tail.len - marker.len ..], marker);
    const tail_line = try paneOutputLineForTest(allocator, "pane-1", tail);
    defer allocator.free(tail_line);

    try writeAll(socket_fds[1], first_line);
    try writeAll(socket_fds[1], tail_line);
    posix.close(socket_fds[1]);
    socket_write_open = false;

    var reader: LineReader = .{};
    const outcome = try runLoop(stdin_fds[0], stdout_fds[1], socket_fds[0], &reader, allocator, "pane-1", .{});
    try std.testing.expectEqual(RunOutcome.connection_lost, outcome);

    posix.close(stdout_fds[1]);
    stdout_write_open = false;
    const output = try readAllFdForTest(allocator, stdout_fds[0]);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "FIRST\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, marker) != null);
}

test "runLoop reports session end when the daemon sends a matching exit notification" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const stdin_fds = try std.posix.pipe();
    defer posix.close(stdin_fds[0]);
    defer posix.close(stdin_fds[1]);

    const socket_fds = try std.posix.pipe();
    defer posix.close(socket_fds[0]);
    var socket_write_open = true;
    defer if (socket_write_open) posix.close(socket_fds[1]);

    const stdout_fds = try std.posix.pipe();
    defer posix.close(stdout_fds[0]);
    defer posix.close(stdout_fds[1]);

    try writeAll(
        socket_fds[1],
        "{\"jsonrpc\":\"2.0\",\"method\":\"session_exited\",\"params\":{\"session_id\":\"pane-1\",\"pid\":123,\"exit_code\":0,\"signal\":null}}\n",
    );
    posix.close(socket_fds[1]);
    socket_write_open = false;

    var reader: LineReader = .{};
    const outcome = try runLoop(stdin_fds[0], stdout_fds[1], socket_fds[0], &reader, allocator, "pane-1", .{});
    try std.testing.expectEqual(RunOutcome.session_ended, outcome);
}

test "run loop poll timeout bounds idle SIGWINCH latency" {
    try std.testing.expect(run_loop_poll_timeout_ms <= 100);
}

fn paneOutputLineForTest(allocator: std.mem.Allocator, pane_id: []const u8, data: []const u8) ![]u8 {
    const encoded = try base64Encode(allocator, data);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{{\"pane_id\":{f},\"data_base64\":{f}}}}}\n",
        .{ std.json.fmt(pane_id, .{}), std.json.fmt(encoded, .{}) },
    );
}

fn readAllFdForTest(allocator: std.mem.Allocator, fd: posix.fd_t) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &buf);
        if (n == 0) return out.toOwnedSlice(allocator);
        try out.appendSlice(allocator, buf[0..n]);
    }
}

// --- A2 detach key ---------------------------------------------------------

test "parseDetachKey handles ctrl chords, backslash default, and none" {
    try std.testing.expectEqual(@as(?u8, 0x01), try parseDetachKey("ctrl-a"));
    try std.testing.expectEqual(@as(?u8, 0x02), try parseDetachKey("Ctrl-B"));
    try std.testing.expectEqual(@as(?u8, 0x1a), try parseDetachKey("ctrl-z"));
    try std.testing.expectEqual(@as(?u8, default_detach_key), try parseDetachKey("ctrl-\\"));
    try std.testing.expectEqual(@as(?u8, null), try parseDetachKey("none"));
    try std.testing.expectEqual(@as(?u8, null), try parseDetachKey("NONE"));
    try std.testing.expectError(error.InvalidDetachKey, parseDetachKey("ctrl-1"));
    try std.testing.expectError(error.InvalidDetachKey, parseDetachKey("bogus"));
    try std.testing.expectError(error.InvalidDetachKey, parseDetachKey("ctrl-"));
}

test "clientIdFromAttach extracts the logical client id" {
    const alloc = std.testing.allocator;
    const cid = try clientIdFromAttach(alloc, "{\"result\":{\"clientId\":\"client-3\",\"paneId\":\"pane-1\"}}\n");
    defer alloc.free(cid);
    try std.testing.expectEqualStrings("client-3", cid);
    try std.testing.expectError(
        error.MissingClientId,
        clientIdFromAttach(alloc, "{\"result\":{\"paneId\":\"pane-1\"}}\n"),
    );
}

test "runLoop intercepts the detach chord and sends client.detach" {
    if (!@hasDecl(std.posix, "pipe")) return error.SkipZigTest;
    g_winch_flag.store(false, .seq_cst);

    const allocator = std.testing.allocator;

    const stdin_fds = try std.posix.pipe();
    defer posix.close(stdin_fds[0]);
    defer posix.close(stdin_fds[1]);

    const socket_fds = try std.posix.pipe();
    defer posix.close(socket_fds[0]);
    defer posix.close(socket_fds[1]);

    // Feed the default detach chord (Ctrl-\) as raw stdin.
    try writeAll(stdin_fds[1], &.{default_detach_key});

    var reader: LineReader = .{};
    const outcome = try runLoop(
        stdin_fds[0],
        @as(posix.fd_t, -1),
        socket_fds[1],
        &reader,
        allocator,
        "pane-1",
        .{ .detach_key = default_detach_key, .client_id = "client-9" },
    );
    try std.testing.expectEqual(RunOutcome.detached, outcome);

    // The client.detach request must be waiting on the socket write end.
    var buf: [256]u8 = undefined;
    const n = try posix.read(socket_fds[0], &buf);
    const written = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, written, "client.detach") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "client-9") != null);
}

// --- A9 management verbs ---------------------------------------------------

test "parseVerb recognizes management subcommands only" {
    try std.testing.expectEqual(Verb.list, parseVerb("ls").?);
    try std.testing.expectEqual(Verb.kill, parseVerb("kill").?);
    try std.testing.expectEqual(Verb.rename, parseVerb("rename").?);
    try std.testing.expectEqual(Verb.shutdown, parseVerb("shutdown").?);
    try std.testing.expect(parseVerb("work") == null);
    try std.testing.expect(parseVerb("--help") == null);
}

test "buildVerbRequest emits the expected JSON-RPC methods and params" {
    const alloc = std.testing.allocator;

    const list = try buildVerbRequest(alloc, .list, null, null);
    defer alloc.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"method\":\"session.list\"") != null);

    const kill = try buildVerbRequest(alloc, .kill, "work", null);
    defer alloc.free(kill);
    try std.testing.expect(std.mem.indexOf(u8, kill, "\"method\":\"session.terminate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kill, "\"sessionId\":\"work\"") != null);

    const rename = try buildVerbRequest(alloc, .rename, "work", "play");
    defer alloc.free(rename);
    try std.testing.expect(std.mem.indexOf(u8, rename, "\"method\":\"session.rename\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rename, "\"sessionId\":\"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rename, "\"name\":\"play\"") != null);

    const shutdown = try buildVerbRequest(alloc, .shutdown, null, null);
    defer alloc.free(shutdown);
    try std.testing.expect(std.mem.indexOf(u8, shutdown, "\"method\":\"daemon.shutdown\"") != null);
}

test "formatSessionList renders rows and the empty case" {
    const alloc = std.testing.allocator;

    const empty = try formatSessionList(alloc, "{\"id\":1,\"result\":[]}\n");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("no sessions\n", empty);

    const listed = try formatSessionList(
        alloc,
        "{\"id\":1,\"result\":[{\"pid\":7,\"state\":\"running\",\"title\":\"work\"," ++
            "\"sessionId\":\"work\",\"paneId\":\"pane-1\"}]}\n",
    );
    defer alloc.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "pane-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "work") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "pid=7") != null);
}

test "rpcErrorMessage extracts daemon error text and ignores success frames" {
    const alloc = std.testing.allocator;

    const msg = rpcErrorMessage(alloc, "{\"id\":1,\"error\":{\"code\":-32000,\"message\":\"nope\"}}\n") orelse
        return error.MissingMessage;
    defer alloc.free(msg);
    try std.testing.expectEqualStrings("nope", msg);

    try std.testing.expect(rpcErrorMessage(alloc, "{\"id\":1,\"result\":{\"ok\":true}}\n") == null);
}

test "executeVerb round-trips session.list over a socket and formats output" {
    const allocator = std.testing.allocator;

    var pair: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    const out = try std.posix.pipe();
    defer posix.close(out[0]);
    defer posix.close(out[1]);

    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[" ++
        "{\"id\":\"pane-1\",\"title\":\"work\",\"pid\":4242,\"state\":\"running\"," ++
        "\"sessionId\":\"work\",\"windowId\":\"win-1\",\"paneId\":\"pane-1\"}]}\n";
    try writeAll(pair[1], response);

    var reader: LineReader = .{};
    try executeVerb(
        allocator,
        pair[0],
        &reader,
        .list,
        null,
        null,
        false,
        out[1],
        std.time.milliTimestamp() + 2_000,
    );

    var buf: [512]u8 = undefined;
    const n = try posix.read(out[0], &buf);
    const written = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, written, "pane-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "pid=4242") != null);
}

test "executeVerb surfaces a daemon RPC error as error.RpcError" {
    const allocator = std.testing.allocator;

    var pair: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    const out = try std.posix.pipe();
    defer posix.close(out[0]);
    defer posix.close(out[1]);

    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32000,\"message\":\"session not found\"}}\n";
    try writeAll(pair[1], response);

    var reader: LineReader = .{};
    try std.testing.expectError(error.RpcError, executeVerb(
        allocator,
        pair[0],
        &reader,
        .kill,
        "ghost",
        null,
        false,
        out[1],
        std.time.milliTimestamp() + 2_000,
    ));
}

// --- A23 version handshake -------------------------------------------------

test "daemonVersion reads the daemon-reported protocol version" {
    const allocator = std.testing.allocator;

    // daemonVersion writes the ping and reads its reply on the same fd, so the
    // test needs a bidirectional socketpair rather than a one-way pipe.
    var pair: [2]posix.fd_t = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &pair) != 0) return error.SkipZigTest;
    defer posix.close(pair[0]);
    defer posix.close(pair[1]);

    // A notification the ping read must skip, then the ping response itself.
    try writeAll(
        pair[1],
        "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":100,\"result\":{\"version\":\"9.9.9\",\"pid\":1}}\n",
    );

    var reader: LineReader = .{};
    const version = try daemonVersion(allocator, &reader, pair[0], std.time.milliTimestamp() + 2_000);
    defer allocator.free(version);
    try std.testing.expectEqualStrings("9.9.9", version);
}

test "connectFailureMessage explains expected bootstrap failures" {
    const allocator = std.testing.allocator;

    const missing = (try connectFailureMessage(allocator, "/tmp/missing.sock", error.FileNotFound)) orelse
        return error.MissingMessage;
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "no daemon at /tmp/missing.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "--spawn-daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "FileNotFound") == null);

    const unavailable = (try connectFailureMessage(allocator, "/tmp/slow.sock", error.DaemonUnavailable)) orelse
        return error.MissingMessage;
    defer allocator.free(unavailable);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "did not become ready within 2s") != null);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "/tmp/slow.sock.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, unavailable, "DaemonUnavailable") == null);

    try std.testing.expect((try connectFailureMessage(allocator, "/tmp/x.sock", error.AccessDenied)) == null);
}
