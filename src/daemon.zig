//! `zmuxd`, the zmux session daemon: parses its command line, takes the start
//! lock for one socket path, binds the server, publishes the pid file, and
//! serves until idle timeout or a shutdown signal.
const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");
const socket_path_mod = @import("socket_path.zig");
const sys = @import("sys.zig");
const cli = @import("daemon/cli.zig");
const lock_mod = @import("daemon/lock.zig");
const paths = @import("daemon/paths.zig");
const pidfile = @import("daemon/pidfile.zig");

const posix = std.posix;
const assert = std.debug.assert;

/// How long a starting daemon waits for another starter to finish.
const start_lock_timeout_ms: i64 = 2000;
/// How long startup keeps retrying a socket probe that could not decide
/// whether a daemon is already listening.
const startup_probe_timeout_ms: i64 = 2000;
var shutdown_requested = std.atomic.Value(bool).init(false);

const envGet = paths.envGet;
const SiblingNames = lock_mod.SiblingNames;
const openStartContext = lock_mod.openStartContext;
const writeStderr = cli.writeStderr;
const parseArgsOrFail = cli.parseArgsOrFail;
const printUsage = cli.printUsage;
const printVersion = cli.printVersion;
const startupFailureMessage = cli.startupFailureMessage;
const reportStartupFailure = cli.reportStartupFailure;
const resolveSocketPathOrFail = paths.resolveSocketPathOrFail;
const socketPathFromEnv = paths.socketPathFromEnv;
const validateSocketPath = paths.validateSocketPath;
const socketPathTooLongMessage = cli.socketPathTooLongMessage;
const pidPath = paths.pidPath;
const writePidFile = pidfile.writePidFile;
const removePidFile = pidfile.removePidFile;
const publishPidFile = pidfile.publishPidFile;
const tempPath = pidfile.tempPath;
const TempDir = pidfile.TempDir;
const posix_ok = pidfile.posix_ok;

/// Options accepted on the `zmuxd` command line.
pub const ParsedArgs = cli.ParsedArgs;

/// Every way `parseArgs` can reject a command line.
pub const ParseArgsError = cli.ParseArgsError;

/// Detail for a `parseArgs` failure: the error plus the offending argument
/// and, for a bad number, the underlying parse error.
pub const ParseArgsFailure = cli.ParseArgsFailure;

/// Parse `argv` (including the program name at index 0). On error, `failure`
/// (when given) receives the details needed for a usage message.
pub const parseArgs = cli.parseArgs;

/// Default socket path: `$ZMUX_SOCKET`, `$SMITHERS_SESSION_SOCKET`,
/// `$XDG_RUNTIME_DIR/smithers-sessions.sock`, `$HOME/.smithers/sessions.sock`,
/// then `/tmp/zmux-<euid>/sessions.sock`. Pass `std.process.Init.environ_map`.
pub const socketPath = paths.socketPath;

/// Entry point of `zmuxd`: runs the daemon and exits 2 on usage errors and 1
/// on any other failure, after reporting it on stderr.
pub fn main(init: std.process.Init) void {
    runMain(init) catch |err| {
        switch (err) {
            // Usage errors, already reported with a specific message.
            error.InvalidArguments, error.SocketPathTooLong => std.process.exit(2),
            // Already reported with a specific message.
            error.StartupFailed => {},
            else => writeStderr(init.io, "zmuxd: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // Environment first; an explicit --log-level below overrides it.
    log.initFromEnv(init.environ_map);

    const parsed = try parseArgsOrFail(io, argv);
    if (parsed.log_level) |level| log.setLevel(level);
    if (parsed.show_help) {
        try printUsage(io);
        return;
    }
    if (parsed.show_version) {
        try printVersion(io);
        return;
    }

    paths.loadEnv(init.environ_map);
    const path = try resolveSocketPathOrFail(allocator, io, parsed.explicit_socket_path);
    defer allocator.free(path);
    assert(std.fs.path.isAbsolute(path));

    prepareDaemonProcess();
    const default_cwd = defaultPaneCwd(envGet("HOME"));
    try serve(allocator, io, path, parsed.idle_timeout_seconds, default_cwd);
}

/// Detach from the launcher: new session, default SIGCHLD, shutdown handlers,
/// and `/` as the working directory.
fn prepareDaemonProcess() void {
    detachFromControllingTerminal();
    resetSigchldDisposition();
    installShutdownHandlers();

    // `path` is absolute from here on and everything else goes through the
    // pinned directory descriptor, so the daemon lets go of the launcher's
    // working directory: it must not keep a mount busy or hand an arbitrary
    // directory to every pane. Panes start in the client's cwd (sent by
    // zmux-connect) or, without one, in the user's home directory.
    //
    // The umask is deliberately left alone: pane shells inherit it, and every
    // file the daemon creates gets an explicit private mode.
    leaveLauncherDirectory();
}

/// Take the start lock, bind the server, publish the pid file, and run until
/// shutdown. Returns normally when another daemon already owns `path`.
fn serve(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    idle_timeout_seconds: i64,
    default_cwd: ?[]const u8,
) !void {
    // The socket directory is validated (or created 0700) before the lock,
    // PID file, or socket is touched, and everything below goes through the
    // pinned descriptor.
    var start = openStartContext(path, envGet, start_lock_timeout_ms, &shutdown_requested) catch |err| switch (err) {
        // The lock is held for a daemon's lifetime, so another holder is a
        // live or starting daemon. Exiting successfully mirrors tmux's
        // start-server race behavior and never displaces it.
        error.Timeout => {
            log.info("daemon_already_running", .{ .socket_path = path, .reason = "start_lock_held" });
            return;
        },
        else => return reportStartupFailure(io, path, err),
    };
    // Runs last: the lock is released only after the server is torn down
    // and its names removed.
    assert(start.dir_fd >= 0 and std.fs.path.isAbsolute(path));
    defer sys.close(start.dir_fd);
    defer start.lock.release();
    const names = SiblingNames.init(path);
    // openStartContext succeeded on the same path, so the names fit.
    assert(names.fits());

    // Server.init decides what an existing socket means. A daemon that is
    // already listening is not an error. The server binds in the directory
    // the lock lives in (`initAt`), never a second lookup of its name.
    var server = initServerAt(allocator, io, start.dir_fd, path, idle_timeout_seconds) catch |err| switch (err) {
        error.AddressInUse => {
            log.info("daemon_already_running", .{ .socket_path = path });
            return;
        },
        else => return reportStartupFailure(io, path, err),
    };

    // Under the start lock: no other starter can see the socket without its
    // PID file, or remove one while this daemon writes the other.
    const pid_stat = publishPidFile(start.dir_fd, names.pid(), path);

    defer {
        // Still under the lifetime start lock: remove the published names
        // only if they are still the ones this daemon created, then tear
        // down. The lock is released after this block.
        assert(start.lock.fd >= 0);
        server.unpublish();
        if (pid_stat) |stat| removePidFile(start.dir_fd, names.pid(), stat);
        server.deinit();
    }

    try runServer(&server, path, idle_timeout_seconds, default_cwd, pid_stat != null);
}

/// Log startup, serve until shutdown, and log why the server stopped.
fn runServer(
    server: *server_mod.Server,
    path: []const u8,
    idle_timeout_seconds: i64,
    default_cwd: ?[]const u8,
    pid_file_written: bool,
) !void {
    assert(idle_timeout_seconds >= 0);
    log.info("daemon_start", .{
        .version = protocol.version,
        .socket_path = path,
        .idle_timeout_seconds = idle_timeout_seconds,
        .pid_file_written = pid_file_written,
        .log_level = log.getLevel(),
    });

    server.shutdown_probe = shutdownRequested;
    server.default_cwd = default_cwd;
    assert(default_cwd == null or std.fs.path.isAbsolute(default_cwd.?));
    server.run() catch |err| {
        log.err("daemon_shutdown", .{ .reason = "error", .err = err, .socket_path = path });
        return err;
    };
    log.info("daemon_shutdown", .{
        .reason = if (shutdownRequested()) "signal" else "idle_or_stopped",
        .socket_path = path,
    });
}

/// `Server.init`, retried while the stale-socket probe cannot decide whether
/// a daemon is listening (for example during fd exhaustion).
fn initServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    idle_timeout_seconds: i64,
) !server_mod.Server {
    return initServerIn(allocator, io, null, path, idle_timeout_seconds);
}

/// `initServer` in the pinned directory `dir_fd` (borrowed).
fn initServerAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_fd: sys.fd_t,
    path: []const u8,
    idle_timeout_seconds: i64,
) !server_mod.Server {
    return initServerIn(allocator, io, dir_fd, path, idle_timeout_seconds);
}

fn initServerIn(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_fd: ?sys.fd_t,
    path: []const u8,
    idle_timeout_seconds: i64,
) !server_mod.Server {
    assert(idle_timeout_seconds >= 0);
    const deadline = sys.monotonicMs() + startup_probe_timeout_ms;
    while (true) {
        const attempt = if (dir_fd) |fd|
            server_mod.Server.initAt(allocator, io, fd, path, idle_timeout_seconds)
        else
            server_mod.Server.init(allocator, io, path, idle_timeout_seconds);
        return attempt catch |err| {
            if (err != error.ProbeInconclusive or sys.monotonicMs() >= deadline) return err;
            io.sleep(.fromMilliseconds(50), .awake) catch return err;
            continue;
        };
    }
}

fn shutdownRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

fn shutdownSignalHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn detachFromControllingTerminal() void {
    if (builtin.os.tag == .windows) return;
    _ = std.c.setsid();
}

fn leaveLauncherDirectory() void {
    if (std.c.chdir("/") != 0) log.warn("daemon_chdir_failed", .{ .errno = @backingInt(posix.errno(-1)) });
}

/// The directory a pane starts in when its creator names none: `$HOME` when
/// it is an absolute path to an existing directory, else null (the daemon's
/// own cwd, `/`).
fn defaultPaneCwd(home: ?[]const u8) ?[]const u8 {
    const dir = home orelse return null;
    if (!std.fs.path.isAbsolute(dir)) return null;
    if (std.mem.indexOfScalar(u8, dir, 0) != null) return null;
    const stat = sys.statAt(sys.cwd_fd, dir, true) catch return null;
    if (!stat.isDir()) return null;
    assert(std.fs.path.isAbsolute(dir));
    return dir;
}

fn resetSigchldDisposition() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &act, null);
}

fn installShutdownHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = shutdownSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);

    const ignore_hup: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.HUP, &ignore_hup, null);
}

const test_io = std.testing.io;

/// Internal hooks exposed for the repository's own fuzz suites.
pub const fuzz_hooks = struct {
    pub const socketPathFromEnvFn = socketPathFromEnv;
    pub const validateSocketPathFn = validateSocketPath;
    pub const socketPathTooLongMessageFn = socketPathTooLongMessage;
    pub const pidPathFn = pidPath;
    pub const parseArgsFn = parseArgs;
    pub const envGetFn = envGet;
    pub const openStartContextFn = openStartContext;
    pub const siblingNamesFn = SiblingNames.init;
    pub const writePidFileFn = writePidFile;
    pub const removePidFileFn = removePidFile;
};

test "H03: the server binds in the locked directory or not at all after its name is swapped" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var original = try TempDir.init("zmx-daemon-pinned");
    defer original.deinit();
    const socket_path = try std.fs.path.join(allocator, &.{ original.path, "z.sock" });
    defer allocator.free(socket_path);

    var start = try openStartContext(socket_path, envGet, 500, null);
    defer start.deinit();

    // Same directory: the socket lands beside the lock.
    {
        var server = try initServerAt(allocator, test_io, start.dir_fd, socket_path, 0);
        defer server.deinit();
        const stat = try sys.statAt(start.dir_fd, "z.sock", false);
        try std.testing.expect(stat.isSocket());
    }

    // The directory name now points elsewhere: the bind must fail rather
    // than publish a socket in a directory the lock does not cover.
    const moved = try std.fmt.allocPrint(allocator, "{s}-moved", .{original.path});
    defer allocator.free(moved);
    defer std.Io.Dir.cwd().deleteTree(test_io, moved) catch {};
    try std.Io.Dir.renameAbsolute(original.path, moved, test_io);
    try sys.mkdir(original.path, 0o700);
    if (initServerAt(allocator, test_io, start.dir_fd, socket_path, 0)) |server_value| {
        var server = server_value;
        server.deinit();
        return error.BoundOutsideLockedDirectory;
    } else |_| {}
    var replacement = try std.Io.Dir.openDirAbsolute(test_io, original.path, .{ .iterate = true });
    defer replacement.close(test_io);
    var iterator = replacement.iterate();
    try std.testing.expect((try iterator.next(test_io)) == null);
}

test "initServer replaces a stale socket promptly and reports a live one as in use" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const path = try tempPath(allocator, "zmx-daemon-probe");
    defer allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};

    // Stale: bound once, listener gone.
    {
        const address = try sys.UnixAddress.init(path);
        const listener = try sys.unixStreamSocket();
        errdefer sys.close(listener);
        sys.bind(listener, &address) catch |err| switch (err) {
            error.AccessDenied => {
                sys.close(listener);
                return error.SkipZigTest;
            },
            else => return err,
        };
        try sys.listen(listener, 1);
        sys.close(listener);
    }

    const start = sys.monotonicMs();
    var server = try initServer(allocator, test_io, path, 0);
    defer server.deinit();
    // A definitive stale socket must not burn the startup probe budget.
    try std.testing.expect(sys.monotonicMs() - start < 1000);

    // Live: a second daemon sees the first and must not displace it.
    const before = try sys.statAt(sys.cwd_fd, path, false);
    try std.testing.expectError(error.AddressInUse, initServer(allocator, test_io, path, 0));
    try std.testing.expect(before.sameFile(try sys.statAt(sys.cwd_fd, path, false)));
}

test "initServer refuses to remove a regular file at the socket path" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dir = try TempDir.init("zmx-daemon-notes");
    defer dir.deinit();

    const notes = try dir.child("notes.txt");
    defer allocator.free(notes);
    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, notes, .{});
        defer file.close(test_io);
        try file.writeStreamingAll(test_io, "do not delete\n");
    }

    try std.testing.expectError(error.SocketPathNotSocket, initServer(allocator, test_io, notes, 0));
    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, notes, allocator, .limited(64));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("do not delete\n", text);
    try std.testing.expect(startupFailureMessage(error.SocketPathNotSocket) != null);
}

test "defaultPaneCwd accepts only an absolute existing directory" {
    try std.testing.expectEqualStrings("/", defaultPaneCwd("/").?);
    try std.testing.expect(defaultPaneCwd(null) == null);
    try std.testing.expect(defaultPaneCwd("") == null);
    try std.testing.expect(defaultPaneCwd("relative/home") == null);
    try std.testing.expect(defaultPaneCwd("/zmux/no/such/home") == null);
    try std.testing.expect(defaultPaneCwd("/bin/sh") == null);
}

test "resetSigchldDisposition restores default SIGCHLD handling" {
    if (!posix_ok) return error.SkipZigTest;

    var old_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, null, &old_action);
    defer std.posix.sigaction(.CHLD, &old_action, null);

    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &ignored, null);

    resetSigchldDisposition();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(.CHLD, null, &current);
    try std.testing.expect(current.handler.handler == std.posix.SIG.DFL);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("daemon/cli.zig");
    _ = @import("daemon/lock.zig");
    _ = @import("daemon/paths.zig");
    _ = @import("daemon/pidfile.zig");
    std.testing.refAllDecls(@import("buffer.zig"));
    std.testing.refAllDecls(@import("foreground.zig"));
    std.testing.refAllDecls(@import("log.zig"));
    std.testing.refAllDecls(@import("native.zig"));
    std.testing.refAllDecls(@import("protocol.zig"));
    std.testing.refAllDecls(@import("pty.zig"));
    std.testing.refAllDecls(@import("server.zig"));
    std.testing.refAllDecls(@import("socket_path.zig"));
    std.testing.refAllDecls(@import("sys.zig"));
}
