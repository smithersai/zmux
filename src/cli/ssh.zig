//! Remote SSH attach (`zmux ssh <host> [session]`) with private UNIX socket
//! forwarding, SSH option-injection guards, automatic exponential-backoff
//! reconnection, and `resumeFromOffset` stream resumption.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const assert = std.debug.assert;
const connect_events = @import("../connect/events.zig");
const connect_terminal = @import("../connect/terminal.zig");
const sys = @import("../sys.zig");
const args_mod = @import("args.zig");
const attach = @import("attach.zig");
const help = @import("help.zig");
const rpc = @import("rpc.zig");

/// Validation errors returned when checking SSH host, session, option, or path inputs.
pub const ValidationError = error{
    EmptyValue,
    LeadingDashForbidden,
    InvalidCharacters,
    ValueTooLong,
    RelativeSocketPath,
};

/// Pure configuration passed to `buildSshArgs`.
pub const SshArgsConfig = struct {
    host: []const u8,
    local_socket: []const u8,
    remote_socket: []const u8,
    extra_opts: []const []const u8 = &.{},
    remote_command: ?[]const u8 = null,
};

/// Reconnect and stream-offset state machine across dropped SSH tunnels.
pub const ReconnectState = struct {
    target: []const u8,
    pane_id: ?[]u8 = null,
    last_generation: ?u64 = null,
    last_offset: ?u64 = null,
    attempt: u32 = 0,
    max_attempts: u32 = 8,
    base_backoff_ms: u64 = 250,
    max_backoff_ms: u64 = 8_000,

    /// Release owned `pane_id` memory.
    pub fn deinit(self: *ReconnectState, allocator: std.mem.Allocator) void {
        if (self.pane_id) |p| allocator.free(p);
        self.pane_id = null;
    }

    /// Return the resolved pane ID when previously attached, else the initial target name.
    pub fn activeTarget(self: *const ReconnectState) []const u8 {
        const res = self.pane_id orelse self.target;
        assert(res.len > 0);
        return res;
    }

    /// Record stream progress from an `AttachResult` and reset retry backoff on progress.
    pub fn recordAttachResult(
        self: *ReconnectState,
        allocator: std.mem.Allocator,
        res: *const attach.AttachResult,
    ) !void {
        if (res.pane_id) |pid| {
            const copy = try allocator.dupe(u8, pid);
            if (self.pane_id) |old| allocator.free(old);
            self.pane_id = copy;
        }
        const progressed = (res.last_offset != self.last_offset) or (res.last_generation != self.last_generation);
        if (res.last_generation) |g| self.last_generation = g;
        if (res.last_offset) |o| self.last_offset = o;
        if (progressed) self.attempt = 0;
    }

    /// True only when the tunnel dropped unexpectedly and retry budget remains.
    pub fn shouldRetry(self: *const ReconnectState, outcome: connect_events.RunOutcome) bool {
        return outcome == .connection_lost and self.attempt < self.max_attempts;
    }

    /// Compute and advance capped exponential backoff in milliseconds, or null if exhausted.
    pub fn nextBackoffMs(self: *ReconnectState) ?u64 {
        if (self.attempt >= self.max_attempts) return null;
        const shift: u6 = @intCast(@min(self.attempt, 10));
        const delay = @min(self.base_backoff_ms << shift, self.max_backoff_ms);
        self.attempt += 1;
        assert(delay >= self.base_backoff_ms and delay <= self.max_backoff_ms);
        return delay;
    }

    /// Build `AttachOptions` carrying `resumeFromOffset` and `resumeGeneration` for recovery.
    pub fn buildAttachOptions(
        self: *const ReconnectState,
        local_socket: []const u8,
        parsed: args_mod.ParsedArgs,
    ) attach.AttachOptions {
        assert(local_socket.len > 0);
        return .{
            .target = self.activeTarget(),
            .socket_path = local_socket,
            .spawn_daemon = false,
            .auto_create = self.pane_id == null and !parsed.read_only,
            .detach_key = parsed.detach_key,
            .read_only = parsed.read_only,
            .replay = parsed.replay,
            .resume_from_offset = self.last_offset,
            .resume_generation = self.last_generation,
            .report_outcome = false,
        };
    }
};

/// Reject empty, control-containing, whitespace-containing, or leading-`-` SSH host strings.
pub fn validateHost(host: []const u8) ValidationError!void {
    if (host.len == 0) return error.EmptyValue;
    if (host.len > 255) return error.ValueTooLong;
    if (host[0] == '-') return error.LeadingDashForbidden;
    for (host) |ch| {
        if (ch <= 0x20 or ch >= 0x7f) return error.InvalidCharacters;
    }
    assert(host.len > 0 and host[0] != '-');
}

/// Reject empty, overlong, or control-containing session target names.
pub fn validateSession(session: []const u8) ValidationError!void {
    if (session.len == 0) return error.EmptyValue;
    if (session.len > 255) return error.ValueTooLong;
    for (session) |ch| {
        if (ch < 0x20 or ch >= 0x7f) return error.InvalidCharacters;
    }
}

/// Validate a single `-o` SSH option value against NUL/control characters.
pub fn validateSshOpt(opt: []const u8) ValidationError!void {
    if (opt.len == 0) return error.EmptyValue;
    if (opt.len > 255) return error.ValueTooLong;
    for (opt) |ch| {
        if (ch < 0x20 or ch >= 0x7f) return error.InvalidCharacters;
    }
}

/// Validate an absolute UNIX socket path for local or remote SSH forwarding.
pub fn validateSocketPath(path: []const u8) ValidationError!void {
    if (path.len == 0) return error.EmptyValue;
    if (path.len > 255) return error.ValueTooLong;
    if (path[0] != '/') return error.RelativeSocketPath;
    for (path) |ch| {
        if (ch < 0x20 or ch >= 0x7f or ch == ':') return error.InvalidCharacters;
    }
}

/// Resolve the remote UNIX socket path from an explicit override or remote HOME.
pub fn resolveRemoteSocket(
    allocator: std.mem.Allocator,
    explicit: ?[]const u8,
    remote_home: ?[]const u8,
) ![]u8 {
    if (explicit) |p| {
        try validateSocketPath(p);
        return allocator.dupe(u8, p);
    }
    if (remote_home) |home| {
        if (home.len > 0 and home[0] == '/') {
            const trimmed = std.mem.trimEnd(u8, home, "/");
            const joined = try std.fmt.allocPrint(allocator, "{s}/.smithers/sessions.sock", .{trimmed});
            errdefer allocator.free(joined);
            try validateSocketPath(joined);
            return joined;
        }
    }
    return allocator.dupe(u8, "/tmp/zmux-remote.sock");
}

/// Build a shell-safe POSIX command to ensure `zmuxd` is listening on `remote_socket`.
pub fn buildRemoteBootstrapCmd(allocator: std.mem.Allocator, remote_socket: []const u8) ![]u8 {
    try validateSocketPath(remote_socket);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("sh -c 'SOCK=");
    try writeSingleQuoted(&out.writer, remote_socket);
    try out.writer.writeAll(
        "; if [ ! -S \"$SOCK\" ]; then (zmuxd --socket \"$SOCK\" >/dev/null 2>&1 &); fi; sleep 1'",
    );
    assert(out.written().len > remote_socket.len);
    return out.toOwnedSlice();
}

fn writeSingleQuoted(writer: *std.Io.Writer, raw: []const u8) !void {
    try writer.writeByte('\'');
    for (raw) |ch| {
        if (ch == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(ch);
        }
    }
    try writer.writeByte('\'');
}

/// Build the deterministic `ssh` argv slice with hardened forwarding and keepalive flags.
pub fn buildSshArgs(allocator: std.mem.Allocator, cfg: SshArgsConfig) ![][]u8 {
    try validateHost(cfg.host);
    try validateSocketPath(cfg.local_socket);
    try validateSocketPath(cfg.remote_socket);
    for (cfg.extra_opts) |opt| try validateSshOpt(opt);

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    try appendDup(allocator, &list, "ssh");
    try appendDup(allocator, &list, "-T");
    if (cfg.remote_command == null) try appendDup(allocator, &list, "-N");
    try appendDup(allocator, &list, "-o");
    try appendDup(allocator, &list, "ExitOnForwardFailure=yes");
    try appendDup(allocator, &list, "-o");
    try appendDup(allocator, &list, "ServerAliveInterval=15");
    try appendDup(allocator, &list, "-o");
    try appendDup(allocator, &list, "ServerAliveCountMax=3");

    for (cfg.extra_opts) |opt| {
        try appendDup(allocator, &list, "-o");
        try appendDup(allocator, &list, opt);
    }

    const forward = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ cfg.local_socket, cfg.remote_socket });
    errdefer allocator.free(forward);
    try appendDup(allocator, &list, "-L");
    try list.append(allocator, forward);

    try appendDup(allocator, &list, "--");
    try appendDup(allocator, &list, cfg.host);
    if (cfg.remote_command) |cmd| try appendDup(allocator, &list, cmd);

    assert(list.items.len >= 12);
    return list.toOwnedSlice(allocator);
}

/// Free an argv slice returned by `buildSshArgs`.
pub fn freeSshArgs(allocator: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn appendDup(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), text: []const u8) !void {
    const dup = try allocator.dupe(u8, text);
    errdefer allocator.free(dup);
    try list.append(allocator, dup);
}

/// Run `zmux ssh <host> [session]` with private `0700` socket forwarding and auto-reconnect.
pub fn run(allocator: std.mem.Allocator, io: std.Io, parsed: args_mod.ParsedArgs) !void {
    const host = parsed.target orelse return help.fail(io, "ssh requires a host", .{});
    const session = parsed.second_arg orelse "default";
    validateHost(host) catch |err| return help.fail(io, "invalid ssh host: {s}", .{@errorName(err)});
    validateSession(session) catch |err| return help.fail(io, "invalid session name: {s}", .{@errorName(err)});

    const remote_socket = resolveRemoteSocket(allocator, parsed.remote_socket, null) catch |err| {
        return help.fail(io, "invalid remote socket: {s}", .{@errorName(err)});
    };
    defer allocator.free(remote_socket);

    var nonce: u64 = 0;
    io.random(std.mem.asBytes(&nonce));
    const tag = nonce & 0xffff_ffff;
    const priv_dir = try std.fmt.allocPrint(allocator, "/tmp/zmux-ssh-{d}-{x}", .{ sys.getpid(), tag });
    defer allocator.free(priv_dir);
    const dir_fd = try sys.ensurePrivateDir(priv_dir);
    sys.close(dir_fd);
    defer _ = sys.rmdir(priv_dir) catch |err| help.printDiagnostic(io, "cleanup rmdir: {s}", .{@errorName(err)});

    const local_sock = try std.fmt.allocPrint(allocator, "{s}/f.sock", .{priv_dir});
    defer allocator.free(local_sock);
    assert(local_sock.len <= sys.max_unix_path_len);

    var state: ReconnectState = .{ .target = session };
    defer state.deinit(allocator);

    while (true) {
        _ = sys.unlinkAt(sys.cwd_fd, local_sock) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const tunnel_pid = try spawnSshTunnel(allocator, io, .{
            .host = host,
            .local_socket = local_sock,
            .remote_socket = remote_socket,
            .extra_opts = parsed.sshOptions(),
        });
        defer stopChild(tunnel_pid);

        const ready = waitForTunnelSocket(io, local_sock, tunnel_pid, 8_000) catch false;
        const outcome: connect_events.RunOutcome = if (ready) blk: {
            var res = attach.attachSession(allocator, io, state.buildAttachOptions(local_sock, parsed)) catch |err| {
                if (err == error.OutOfMemory) return err;
                break :blk .connection_lost;
            };
            defer res.deinit(allocator);
            try state.recordAttachResult(allocator, &res);
            break :blk res.outcome;
        } else .connection_lost;

        if (!state.shouldRetry(outcome)) {
            if (outcome == .detached) try help.stderrWrite(io, "[detached]\n");
            if (outcome == .connection_lost) return help.diagnostic(io, "ssh connection lost", .{});
            return;
        }
        const delay_ms = state.nextBackoffMs() orelse return help.diagnostic(io, "ssh reconnect exhausted", .{});
        help.printDiagnostic(
            io,
            "ssh tunnel disconnected, reconnecting in {d}ms (attempt {d}/{d})",
            .{ delay_ms, state.attempt, state.max_attempts },
        );
        try io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake);
    }
}

fn spawnSshTunnel(allocator: std.mem.Allocator, io: std.Io, cfg: SshArgsConfig) !posix.pid_t {
    const argv_owned = try buildSshArgs(allocator, cfg);
    defer freeSshArgs(allocator, argv_owned);

    const z_args = try allocator.alloc([:0]u8, argv_owned.len);
    var filled: usize = 0;
    defer {
        for (z_args[0..filled]) |s| allocator.free(s);
        allocator.free(z_args);
    }
    for (argv_owned, 0..) |arg, idx| {
        z_args[idx] = try allocator.dupeSentinel(u8, arg, 0);
        filled += 1;
    }

    const c_argv = try allocator.allocSentinel(?[*:0]const u8, z_args.len, null);
    defer allocator.free(c_argv);
    for (z_args, 0..) |s, idx| c_argv[idx] = s.ptr;

    const devnull = try connect_terminal.moveAboveStdio(
        try sys.openZ("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0),
    );
    defer sys.close(devnull);

    const pid = try sys.fork();
    if (pid == 0) {
        sys.dup2(devnull, 0) catch c._exit(127);
        sys.dup2(devnull, 1) catch c._exit(127);
        sys.closeFrom(3);
        sys.resetChildSignals();
        switch (sys.execvpeZ("ssh", c_argv.ptr, sys.currentEnviron())) {
            else => c._exit(127),
        }
    }
    _ = io;
    assert(pid > 0);
    return pid;
}

fn waitForTunnelSocket(io: std.Io, local_sock: []const u8, child_pid: posix.pid_t, timeout_ms: i64) !bool {
    const deadline = sys.monotonicMs() + timeout_ms;
    while (sys.monotonicMs() < deadline) {
        var status: c_int = 0;
        if (c.waitpid(child_pid, &status, posix.W.NOHANG) == child_pid) return false;
        if (sys.connectUnixDeadline(local_sock, sys.monotonicMs() + 300)) |fd| {
            sys.close(fd);
            return true;
        } else |_| {
            try io.sleep(.fromMilliseconds(50), .awake);
        }
    }
    return false;
}

fn stopChild(pid: posix.pid_t) void {
    assert(pid > 0);
    _ = sys.kill(pid, .TERM);
    var status: c_int = 0;
    var waited: usize = 0;
    while (waited < 20) : (waited += 1) {
        if (c.waitpid(pid, &status, posix.W.NOHANG) == pid) return;
        sys.sleepMs(25);
    }
    _ = sys.kill(pid, .KILL);
    _ = c.waitpid(pid, &status, 0);
}

test "validateHost rejects option injection, whitespace, control bytes, and empty input" {
    try validateHost("dev.example.com");
    try validateHost("alice@10.0.0.5");
    try std.testing.expectError(error.EmptyValue, validateHost(""));
    try std.testing.expectError(error.LeadingDashForbidden, validateHost("-oProxyCommand=evil"));
    try std.testing.expectError(error.InvalidCharacters, validateHost("host name"));
    try std.testing.expectError(error.InvalidCharacters, validateHost("host\nline"));
}

test "buildSshArgs produces hardened forwarding flags with double-dash host separator" {
    const alloc = std.testing.allocator;
    const argv = try buildSshArgs(alloc, .{
        .host = "ops@prod-01",
        .local_socket = "/tmp/zmux-ssh-1/f.sock",
        .remote_socket = "/home/ops/.smithers/sessions.sock",
        .extra_opts = &.{"Port=2222"},
    });
    defer freeSshArgs(alloc, argv);

    try std.testing.expectEqualStrings("ssh", argv[0]);
    try std.testing.expectEqualStrings("-T", argv[1]);
    try std.testing.expectEqualStrings("-N", argv[2]);
    try std.testing.expectEqualStrings("ExitOnForwardFailure=yes", argv[4]);
    try std.testing.expectEqualStrings("ServerAliveInterval=15", argv[6]);
    try std.testing.expectEqualStrings("ServerAliveCountMax=3", argv[8]);
    try std.testing.expectEqualStrings("Port=2222", argv[10]);
    try std.testing.expectEqualStrings("-L", argv[11]);
    try std.testing.expectEqualStrings("/tmp/zmux-ssh-1/f.sock:/home/ops/.smithers/sessions.sock", argv[12]);
    try std.testing.expectEqualStrings("--", argv[13]);
    try std.testing.expectEqualStrings("ops@prod-01", argv[14]);
}

test "resolveRemoteSocket and buildRemoteBootstrapCmd safely quote socket paths" {
    const alloc = std.testing.allocator;
    const def = try resolveRemoteSocket(alloc, null, "/home/will/");
    defer alloc.free(def);
    try std.testing.expectEqualStrings("/home/will/.smithers/sessions.sock", def);

    const cmd = try buildRemoteBootstrapCmd(alloc, "/tmp/a'b/z.sock");
    defer alloc.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "'/tmp/a'\\''b/z.sock'") != null);
}

test "ReconnectState tracks generation, offset resumption, and capped exponential backoff" {
    const alloc = std.testing.allocator;
    var st: ReconnectState = .{ .target = "work", .max_attempts = 3, .base_backoff_ms = 200, .max_backoff_ms = 500 };
    defer st.deinit(alloc);

    var res: attach.AttachResult = .{
        .outcome = .connection_lost,
        .pane_id = try alloc.dupe(u8, "pane-7"),
        .last_generation = 2,
        .last_offset = 4096,
    };
    defer res.deinit(alloc);
    try st.recordAttachResult(alloc, &res);

    try std.testing.expectEqualStrings("pane-7", st.activeTarget());
    try std.testing.expect(st.shouldRetry(.connection_lost));
    try std.testing.expect(!st.shouldRetry(.detached));
    try std.testing.expect(!st.shouldRetry(.session_ended));

    const parsed = try args_mod.parse(&.{ "zmux", "ssh", "box", "work", "--readonly" }, null);
    const opts = st.buildAttachOptions("/tmp/s.sock", parsed);
    try std.testing.expectEqual(@as(?u64, 4096), opts.resume_from_offset);
    try std.testing.expectEqual(@as(?u64, 2), opts.resume_generation);
    try std.testing.expect(!opts.auto_create);

    try std.testing.expectEqual(@as(?u64, 200), st.nextBackoffMs());
    try std.testing.expectEqual(@as(?u64, 400), st.nextBackoffMs());
    try std.testing.expectEqual(@as(?u64, 500), st.nextBackoffMs());
    try std.testing.expectEqual(@as(?u64, null), st.nextBackoffMs());
}
