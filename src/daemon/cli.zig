//! The `zmuxd` command line: argument parsing, usage and version output, and
//! the stderr messages for usage errors and refused startups.
const std = @import("std");

const log = @import("../log.zig");
const protocol = @import("../protocol.zig");
const server_mod = @import("../server.zig");
const socket_path_mod = @import("../socket_path.zig");

const assert = std.debug.assert;

const default_idle_timeout_seconds: i64 = 60 * 60;

/// Write one best-effort message to stderr. A failed write has nowhere better
/// to go, so it is logged at debug level and otherwise ignored.
pub fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [std.fs.max_path_bytes + 512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch |err| return log.debug("stderr_write_failed", .{ .err = err });
    w.interface.flush() catch |err| log.debug("stderr_write_failed", .{ .err = err });
}

/// Options accepted on the `zmuxd` command line.
pub const ParsedArgs = struct {
    idle_timeout_seconds: i64 = default_idle_timeout_seconds,
    explicit_socket_path: ?[]const u8 = null,
    log_level: ?log.Level = null,
    show_version: bool = false,
    show_help: bool = false,
};

/// Every way `parseArgs` can reject a command line.
pub const ParseArgsError = error{
    MissingSocketValue,
    MissingIdleSecondsValue,
    InvalidIdleSecondsValue,
    NegativeIdleSecondsValue,
    MissingLogLevelValue,
    InvalidLogLevelValue,
    UnknownFlag,
};

/// Detail for a `parseArgs` failure: the error plus the offending argument
/// and, for a bad number, the underlying parse error.
pub const ParseArgsFailure = struct {
    err: ParseArgsError,
    arg: ?[]const u8 = null,
    parse_err: ?anyerror = null,
};

/// Parse `argv` (including the program name at index 0). On error, `failure`
/// (when given) receives the details needed for a usage message.
pub fn parseArgs(argv: []const []const u8, failure: ?*ParseArgsFailure) ParseArgsError!ParsedArgs {
    var parsed: ParsedArgs = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--socket")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingSocketValue };
                return error.MissingSocketValue;
            }
            parsed.explicit_socket_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--idle-seconds")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingIdleSecondsValue };
                return error.MissingIdleSecondsValue;
            }
            parsed.idle_timeout_seconds = std.fmt.parseInt(i64, argv[i], 10) catch |err| {
                if (failure) |f| f.* = .{
                    .err = error.InvalidIdleSecondsValue,
                    .arg = argv[i],
                    .parse_err = err,
                };
                return error.InvalidIdleSecondsValue;
            };
            // A negative timeout used to disable idle cleanup silently; 0 is
            // the documented way to do that.
            if (parsed.idle_timeout_seconds < 0) {
                if (failure) |f| f.* = .{ .err = error.NegativeIdleSecondsValue, .arg = argv[i] };
                return error.NegativeIdleSecondsValue;
            }
            assert(parsed.idle_timeout_seconds >= 0);
        } else if (std.mem.eql(u8, argv[i], "--log-level")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingLogLevelValue };
                return error.MissingLogLevelValue;
            }
            parsed.log_level = log.parseLevel(argv[i]) catch {
                if (failure) |f| f.* = .{ .err = error.InvalidLogLevelValue, .arg = argv[i] };
                return error.InvalidLogLevelValue;
            };
        } else if (std.mem.eql(u8, argv[i], "--version") or std.mem.eql(u8, argv[i], "-V")) {
            parsed.show_version = true;
        } else if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) {
            parsed.show_help = true;
            return parsed;
        } else {
            if (failure) |f| f.* = .{ .err = error.UnknownFlag, .arg = argv[i] };
            return error.UnknownFlag;
        }
    }
    assert(parsed.idle_timeout_seconds >= 0);
    return parsed;
}

/// `parseArgs`, with every failure reported as a usage message on stderr.
pub fn parseArgsOrFail(io: std.Io, argv: []const []const u8) error{InvalidArguments}!ParsedArgs {
    var failure: ParseArgsFailure = .{ .err = error.UnknownFlag };
    return parseArgs(argv, &failure) catch |err| switch (err) {
        error.MissingSocketValue => return fail(io, "missing value for --socket", .{}),
        error.MissingIdleSecondsValue => return fail(io, "missing value for --idle-seconds", .{}),
        error.InvalidIdleSecondsValue => return fail(
            io,
            "invalid idle timeout value: {s}",
            .{@errorName(failure.parse_err orelse err)},
        ),
        error.NegativeIdleSecondsValue => return fail(
            io,
            "--idle-seconds must be 0 or greater, got {s} (0 disables the idle timeout)",
            .{failure.arg orelse ""},
        ),
        error.MissingLogLevelValue => return fail(io, "missing value for --log-level", .{}),
        error.InvalidLogLevelValue => return fail(
            io,
            "invalid log level: {s} (expected error, warn, info, or debug)",
            .{failure.arg orelse ""},
        ),
        error.UnknownFlag => return fail(io, "unknown flag: {s}", .{failure.arg orelse ""}),
    };
}

/// A short phrase saying why `socket_path` rejected a path.
pub fn socketPathProblem(err: socket_path_mod.Error) []const u8 {
    return switch (err) {
        error.EmptySocketPath => "the path is empty",
        error.SocketPathContainsNul => "the path contains a NUL byte",
        error.SocketPathTooLong => "the path is too long for a Unix socket",
        error.NoSocketDirectory => "the path does not name a file in a directory",
        error.CurrentDirUnavailable => "a relative path needs a readable current directory",
        error.OutOfMemory => "out of memory",
    };
}

/// One line saying why startup was refused, for the errors a user can act on.
pub fn startupFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InsecurePermissions => "the socket directory is writable by other users; " ++
            "it must be owned by you with mode 0700",
        error.InsecureSocketDirectory => "the socket directory is writable by other users; " ++
            "use a directory you own with no group or other write permission, or a sticky directory such as /tmp",
        error.ForeignOwner => "the socket directory or a file in it is owned by another user",
        error.NotDirectory, error.SymlinkParent => "the socket directory is not a real directory " ++
            "(a symlink or a file is in its place)",
        error.NotRegularFile, error.SymLinkLoop => "the lock file beside the socket is not a regular file " ++
            "(a symlink, FIFO, or directory is in its place)",
        error.Timeout => "timed out waiting for another zmuxd that is starting on this socket",
        error.SocketPathNotSocket => "the socket path exists and is not a socket; zmuxd will not remove it",
        error.AccessDenied => "permission denied for the socket path (it may belong to another user)",
        error.ProbeInconclusive => "could not tell whether a daemon is already listening on the socket; " ++
            "nothing was removed",
        else => null,
    };
}

/// Report an actionable startup error on stderr as `error.StartupFailed`;
/// any other error is returned unchanged.
pub fn reportStartupFailure(io: std.Io, socket_path: []const u8, err: anyerror) anyerror {
    assert(socket_path.len > 0);
    const message = startupFailureMessage(err) orelse return err;
    log.err("daemon_start_refused", .{ .err = err, .socket_path = socket_path });
    writeStderr(io, "zmuxd: {s}\nzmuxd: socket: {s}\n", .{ message, socket_path });
    return error.StartupFailed;
}

/// The stderr text for a socket path longer than `sun_path` allows, in `buf`.
pub fn socketPathTooLongMessage(buf: []u8, socket_path: []const u8) []const u8 {
    const message = std.fmt.bufPrint(
        buf,
        "zmuxd: socket path is too long: {d} bytes, but this OS allows at most {d} bytes for a Unix socket path\n" ++
            "zmuxd: path: {s}\n" ++
            "zmuxd: choose a shorter path with --socket or $ZMUX_SOCKET\n",
        .{ socket_path.len, server_mod.max_socket_path_len, socket_path },
    ) catch "zmuxd: socket path is too long for a Unix socket\n";
    assert(message.len > 0 and message[message.len - 1] == '\n');
    return message;
}

/// Log and print `socketPathTooLongMessage` for `socket_path`.
pub fn reportSocketPathTooLong(io: std.Io, socket_path: []const u8) void {
    assert(socket_path.len > server_mod.max_socket_path_len);
    log.err("socket_path_too_long", .{
        .socket_path_len = socket_path.len,
        .max_socket_path_len = server_mod.max_socket_path_len,
    });
    var buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const message = socketPathTooLongMessage(&buf, socket_path);
    std.Io.File.stderr().writeStreamingAll(io, message) catch |err| log.debug("stderr_write_failed", .{ .err = err });
}

/// Print the `--help` text to stdout.
pub fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Usage: zmuxd [--socket PATH] [--idle-seconds SECONDS] [--log-level LEVEL]
        \\       smithers-session-daemon [--socket PATH] [--idle-seconds SECONDS] [--log-level LEVEL]
        \\
        \\Options:
        \\  --socket PATH           Unix socket to listen on. A relative path is resolved
        \\                          against the current directory. Default, first match:
        \\                            $ZMUX_SOCKET
        \\                            $SMITHERS_SESSION_SOCKET
        \\                            $XDG_RUNTIME_DIR/smithers-sessions.sock
        \\                            $HOME/.smithers/sessions.sock
        \\                            /tmp/zmux-<uid>/sessions.sock
        \\                          zmuxd creates ~/.smithers and /tmp/zmux-<uid> with mode
        \\                          0700 and refuses them when other users can write there.
        \\  --idle-seconds SECONDS  Exit after this long with no live panes and no attached
        \\                          clients; 0 disables, negative is rejected (default: 3600)
        \\  --log-level LEVEL       error, warn, info, or debug (default: warn). Overrides
        \\                          $ZMUX_LOG_LEVEL. Diagnostics are one JSON object per stderr line.
        \\  -V, --version           Print the version and exit
        \\  -h, --help              Print this help and exit
        \\
    );
}

/// Print the `--version` line to stdout.
pub fn printVersion(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "zmuxd " ++ protocol.version ++ "\n");
}

/// Print a usage error and the `--help` hint, then return `InvalidArguments`.
pub fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    writeStderr(io, "zmuxd: " ++ fmt ++ "\nTry 'zmuxd --help' for usage.\n", args);
    return error.InvalidArguments;
}

test "parseArgs rejects a negative idle timeout and accepts zero" {
    var failure: ParseArgsFailure = .{ .err = error.UnknownFlag };
    try std.testing.expectError(
        error.NegativeIdleSecondsValue,
        parseArgs(&.{ "zmuxd", "--idle-seconds", "-5" }, &failure),
    );
    try std.testing.expectEqual(@as(ParseArgsError, error.NegativeIdleSecondsValue), failure.err);
    try std.testing.expectEqualStrings("-5", failure.arg.?);

    const disabled = try parseArgs(&.{ "zmuxd", "--idle-seconds", "0" }, null);
    try std.testing.expectEqual(@as(i64, 0), disabled.idle_timeout_seconds);
    const custom = try parseArgs(&.{ "zmuxd", "--idle-seconds", "90", "--socket", "rel.sock" }, null);
    try std.testing.expectEqual(@as(i64, 90), custom.idle_timeout_seconds);
    try std.testing.expectEqualStrings("rel.sock", custom.explicit_socket_path.?);

    try std.testing.expectError(error.InvalidIdleSecondsValue, parseArgs(&.{ "zmuxd", "--idle-seconds", "soon" }, &failure));
}
