//! Zero-allocation command-line parser types and top-level dispatcher for `zmux`.

const std = @import("std");
const assert = std.debug.assert;
const connect_wire = @import("../connect/wire.zig");
const args_sub = @import("args_sub.zig");

/// Maximum repeatable `--ssh-opt` flags accepted by `zmux ssh`.
pub const max_ssh_opts: usize = 16;

/// Default detach chord byte (`Ctrl-\`, `0x1C`).
pub const default_detach_key: u8 = connect_wire.default_detach_key;

/// Every top-level subcommand supported by `zmux`.
pub const Command = enum {
    help,
    version,
    attach,
    new,
    ls,
    run,
    send,
    screen,
    capture,
    wait,
    signal,
    split,
    close,
    kill,
    rename,
    shutdown,
    events,
    record,
    ssh,
    mcp,
    doctor,
    daemon,
};

/// Replay wire mode accepted by `zmux [attach] --replay`.
pub const ReplayMode = enum { raw, vt };

/// Output format accepted by `zmux screen --format`.
pub const ScreenFormat = enum { plain, ansi, cells, json };

/// Split direction accepted by `zmux split -h|-v`.
pub const SplitAxis = enum { vertical, horizontal };

/// Recording lifecycle action accepted by `zmux record <target> <action>`.
pub const RecordAction = enum { start, stop, @"export", status };

/// Complete parsed command line for `zmux`. All slices borrow from `argv`.
pub const ParsedArgs = struct {
    command: Command = .help,
    socket_path: ?[]const u8 = null,
    spawn_daemon: bool = true,
    json: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    target: ?[]const u8 = null,
    second_arg: ?[]const u8 = null,
    auto_create: bool = true,
    cmd_text: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
    detach_key: ?u8 = default_detach_key,
    read_only: bool = false,
    replay: ReplayMode = .raw,
    enter: bool = false,
    key: ?[]const u8 = null,
    use_stdin: bool = false,
    screen_format: ScreenFormat = .plain,
    scrollback: usize = 0,
    lines: usize = 200,
    follow: bool = false,
    pattern: ?[]const u8 = null,
    wait_exit: bool = false,
    idle_ms: ?u64 = null,
    command_done: bool = false,
    timeout_ms: u64 = 30_000,
    split_axis: SplitAxis = .vertical,
    panes_csv: ?[]const u8 = null,
    record_action: ?RecordAction = null,
    out_file: ?[]const u8 = null,
    remote_socket: ?[]const u8 = null,
    ssh_opts: [max_ssh_opts][]const u8 = undefined,
    ssh_opt_len: usize = 0,
    command_args: []const []const u8 = &.{},

    /// Active slice of `--ssh-opt` values.
    pub fn sshOptions(self: *const ParsedArgs) []const []const u8 {
        assert(self.ssh_opt_len <= max_ssh_opts);
        return self.ssh_opts[0..self.ssh_opt_len];
    }
};

/// Every error returned while parsing `zmux` command-line arguments.
pub const ParseError = error{
    MissingValue,
    InvalidValue,
    UnknownFlag,
    UnexpectedArgument,
    MissingArgument,
    TooManySshOptions,
};

/// Offending token context populated whenever `parse` returns an error.
pub const ParseFailure = struct {
    err: ParseError,
    arg: ?[]const u8 = null,
};

/// Parse `argv` (with program name at index 0) into a `ParsedArgs` struct.
pub fn parse(argv: []const []const u8, failure: ?*ParseFailure) ParseError!ParsedArgs {
    var out: ParsedArgs = .{};
    if (argv.len <= 1) {
        out.command = .help;
        return out;
    }

    var idx: usize = 1;
    var stop_opts = false;
    while (idx < argv.len) : (idx += 1) {
        const tok = argv[idx];
        if (!stop_opts and std.mem.eql(u8, tok, "--")) {
            stop_opts = true;
            continue;
        }
        if (!stop_opts and tok.len > 0 and tok[0] == '-') {
            const consumed = try parseGlobalFlag(&out, argv, idx, failure);
            if (out.show_help) {
                out.command = .help;
                return out;
            }
            if (out.show_version) {
                out.command = .version;
                return out;
            }
            idx += consumed;
            continue;
        }
        break;
    }

    if (idx >= argv.len) {
        out.command = .help;
        return out;
    }

    const head = argv[idx];
    if (!stop_opts) {
        if (matchCommand(head)) |cmd| {
            out.command = cmd;
            if (cmd == .daemon) {
                out.command_args = argv[idx + 1 ..];
                return out;
            }
            try args_sub.parseSubcommand(&out, argv[idx + 1 ..], failure);
            assert(out.ssh_opt_len <= max_ssh_opts);
            return out;
        }
    }

    out.command = .attach;
    out.target = head;
    if (stop_opts) {
        if (idx + 1 < argv.len) return failWith(failure, error.UnexpectedArgument, argv[idx + 1]);
        assert(out.target != null);
        return out;
    }
    try args_sub.parseAttach(&out, argv[idx + 1 ..], failure);
    assert(out.target != null);
    return out;
}

/// Normalize a POSIX signal name (e.g. `INT`, `sigterm`) to canonical `SIG...` form.
pub fn normalizeSignal(raw: []const u8) ?[]const u8 {
    if (raw.len == 0 or raw.len > 16) return null;
    const stripped = if (raw.len > 3 and std.ascii.eqlIgnoreCase(raw[0..3], "sig")) raw[3..] else raw;
    const table = [_]struct { short: []const u8, canonical: []const u8 }{
        .{ .short = "INT", .canonical = "SIGINT" },
        .{ .short = "TERM", .canonical = "SIGTERM" },
        .{ .short = "KILL", .canonical = "SIGKILL" },
        .{ .short = "HUP", .canonical = "SIGHUP" },
        .{ .short = "STOP", .canonical = "SIGSTOP" },
        .{ .short = "CONT", .canonical = "SIGCONT" },
        .{ .short = "WINCH", .canonical = "SIGWINCH" },
        .{ .short = "USR1", .canonical = "SIGUSR1" },
        .{ .short = "USR2", .canonical = "SIGUSR2" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(stripped, entry.short)) {
            assert(std.mem.startsWith(u8, entry.canonical, "SIG"));
            return entry.canonical;
        }
    }
    return null;
}

/// Map a subcommand token to its `Command` enum value, or null if not a verb.
pub fn matchCommand(token: []const u8) ?Command {
    const table = [_]struct { name: []const u8, cmd: Command }{
        .{ .name = "attach", .cmd = .attach },
        .{ .name = "new", .cmd = .new },
        .{ .name = "ls", .cmd = .ls },
        .{ .name = "run", .cmd = .run },
        .{ .name = "exec", .cmd = .run },
        .{ .name = "send", .cmd = .send },
        .{ .name = "screen", .cmd = .screen },
        .{ .name = "capture", .cmd = .capture },
        .{ .name = "tail", .cmd = .capture },
        .{ .name = "wait", .cmd = .wait },
        .{ .name = "signal", .cmd = .signal },
        .{ .name = "split", .cmd = .split },
        .{ .name = "close", .cmd = .close },
        .{ .name = "kill", .cmd = .kill },
        .{ .name = "rename", .cmd = .rename },
        .{ .name = "shutdown", .cmd = .shutdown },
        .{ .name = "events", .cmd = .events },
        .{ .name = "record", .cmd = .record },
        .{ .name = "ssh", .cmd = .ssh },
        .{ .name = "mcp", .cmd = .mcp },
        .{ .name = "doctor", .cmd = .doctor },
        .{ .name = "daemon", .cmd = .daemon },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, token, entry.name)) return entry.cmd;
    }
    return null;
}

/// Populate `failure` (when non-null) and return `err`.
pub fn failWith(failure: ?*ParseFailure, err: ParseError, arg: ?[]const u8) ParseError {
    if (failure) |f| f.* = .{ .err = err, .arg = arg };
    return err;
}

/// Consume the next positional value following a value-taking flag.
pub fn nextValue(
    rest: []const []const u8,
    idx: *usize,
    flag: []const u8,
    failure: ?*ParseFailure,
) ParseError![]const u8 {
    assert(idx.* < rest.len);
    idx.* += 1;
    if (idx.* >= rest.len) return failWith(failure, error.MissingValue, flag);
    return rest[idx.*];
}

/// Parse flags shared across all subcommands (`--socket`, `--no-spawn`, `--json`, `-h`/`--help`).
pub fn tryCommonFlag(
    out: *ParsedArgs,
    rest: []const []const u8,
    idx: *usize,
    failure: ?*ParseFailure,
) ParseError!bool {
    assert(idx.* < rest.len);
    const tok = rest[idx.*];
    if (std.mem.eql(u8, tok, "--socket")) {
        out.socket_path = try nextValue(rest, idx, tok, failure);
        return true;
    }
    if (std.mem.eql(u8, tok, "--no-spawn")) {
        out.spawn_daemon = false;
        return true;
    }
    if (std.mem.eql(u8, tok, "--json")) {
        out.json = true;
        return true;
    }
    if (std.mem.eql(u8, tok, "-h") or std.mem.eql(u8, tok, "--help")) {
        out.show_help = true;
        return true;
    }
    return false;
}

fn parseGlobalFlag(
    out: *ParsedArgs,
    argv: []const []const u8,
    idx: usize,
    failure: ?*ParseFailure,
) ParseError!usize {
    assert(idx < argv.len);
    const tok = argv[idx];
    if (std.mem.eql(u8, tok, "--socket")) {
        if (idx + 1 >= argv.len) return failWith(failure, error.MissingValue, tok);
        out.socket_path = argv[idx + 1];
        return 1;
    }
    if (std.mem.eql(u8, tok, "--no-spawn")) {
        out.spawn_daemon = false;
        return 0;
    }
    if (std.mem.eql(u8, tok, "--json")) {
        out.json = true;
        return 0;
    }
    if (std.mem.eql(u8, tok, "-V") or std.mem.eql(u8, tok, "--version")) {
        out.show_version = true;
        return 0;
    }
    if (std.mem.eql(u8, tok, "-h") or std.mem.eql(u8, tok, "--help")) {
        out.show_help = true;
        return 0;
    }
    return failWith(failure, error.UnknownFlag, tok);
}

test "bare zmux and global flags parse defaults cleanly" {
    const bare = try parse(&.{"zmux"}, null);
    try std.testing.expectEqual(Command.help, bare.command);
    try std.testing.expect(bare.spawn_daemon);

    const ver = try parse(&.{ "zmux", "-V" }, null);
    try std.testing.expectEqual(Command.version, ver.command);

    const implicit = try parse(&.{ "zmux", "--socket", "/tmp/a.sock", "--no-spawn", "dev", "--readonly" }, null);
    try std.testing.expectEqual(Command.attach, implicit.command);
    try std.testing.expectEqualStrings("/tmp/a.sock", implicit.socket_path.?);
    try std.testing.expect(!implicit.spawn_daemon);
    try std.testing.expectEqualStrings("dev", implicit.target.?);
    try std.testing.expect(implicit.read_only);
}

test "attach handles explicit verb, double dash, replay, and detach key" {
    const explicit = try parse(&.{ "zmux", "attach", "ls", "--replay", "vt", "--detach-key", "ctrl-a" }, null);
    try std.testing.expectEqual(Command.attach, explicit.command);
    try std.testing.expectEqualStrings("ls", explicit.target.?);
    try std.testing.expectEqual(ReplayMode.vt, explicit.replay);
    try std.testing.expectEqual(@as(?u8, 1), explicit.detach_key);

    const dashed = try parse(&.{ "zmux", "--", "ls" }, null);
    try std.testing.expectEqual(Command.attach, dashed.command);
    try std.testing.expectEqualStrings("ls", dashed.target.?);
}

test "normalizeSignal maps all supported POSIX signals case-insensitively" {
    try std.testing.expectEqualStrings("SIGINT", normalizeSignal("int").?);
    try std.testing.expectEqualStrings("SIGTERM", normalizeSignal("SIGTERM").?);
    try std.testing.expectEqualStrings("SIGWINCH", normalizeSignal("winch").?);
    try std.testing.expectEqualStrings("SIGUSR2", normalizeSignal("sigusr2").?);
    try std.testing.expect(normalizeSignal("UNKNOWN") == null);
    try std.testing.expect(normalizeSignal("") == null);
}
