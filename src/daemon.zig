const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");
const socket_path_mod = @import("socket_path.zig");
const sys = @import("sys.zig");

const posix = std.posix;

const default_idle_timeout_seconds: i64 = 60 * 60;
/// How long a starting daemon waits for another starter to finish.
const start_lock_timeout_ms: i64 = 2000;
/// How long startup keeps retrying a socket probe that could not decide
/// whether a daemon is already listening.
const startup_probe_timeout_ms: i64 = 2000;
var shutdown_requested = std.atomic.Value(bool).init(false);

/// The values socket path resolution reads from the environment.
/// `socket_path.GetEnv` is a plain function pointer, so the daemon parks them
/// here for `envGet`.
const EnvValues = struct {
    zmux_socket: ?[]const u8 = null,
    smithers_socket: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,
    home: ?[]const u8 = null,

    fn fromMap(environ: *const std.process.Environ.Map) EnvValues {
        return .{
            .zmux_socket = environ.get("ZMUX_SOCKET"),
            .smithers_socket = environ.get("SMITHERS_SESSION_SOCKET"),
            .xdg_runtime_dir = environ.get("XDG_RUNTIME_DIR"),
            .home = environ.get("HOME"),
        };
    }
};

threadlocal var env_values: EnvValues = .{};

fn envGet(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "ZMUX_SOCKET")) return env_values.zmux_socket;
    if (std.mem.eql(u8, name, "SMITHERS_SESSION_SOCKET")) return env_values.smithers_socket;
    if (std.mem.eql(u8, name, "XDG_RUNTIME_DIR")) return env_values.xdg_runtime_dir;
    if (std.mem.eql(u8, name, "HOME")) return env_values.home;
    return null;
}

/// Serializes daemon startup (and socket/PID cleanup) for one socket path.
///
/// The lock is `flock(2)` on a persistent `<socket>.lock` file. The file is
/// never unlinked: `flock` locks an inode, so removing the name would let one
/// starter hold the old inode while another creates and locks a new one, and
/// both would believe they are alone. Releasing is closing the descriptor.
///
/// The file is opened relative to the pinned, already validated socket
/// directory with `O_NOFOLLOW` and must be a regular file this user owns, so
/// a symlink, FIFO, or foreign file planted at the name is refused instead of
/// followed or blocked on.
const StartLock = struct {
    fd: sys.fd_t,

    fn acquire(dir_fd: sys.fd_t, lock_name: []const u8, timeout_ms: i64, stop: ?*const std.atomic.Value(bool)) !StartLock {
        const fd = try sys.openOwnedRegularAt(dir_fd, lock_name, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
        errdefer sys.close(fd);
        // A restrictive umask must not leave a lock the next starter cannot
        // open. The file is ours (checked above), so this is safe.
        sys.fchmod(fd, 0o600) catch {};
        try sys.flockExclusiveDeadline(fd, sys.monotonicMs() + timeout_ms, stop);
        return .{ .fd = fd };
    }

    fn release(self: *StartLock) void {
        if (self.fd < 0) return;
        sys.close(self.fd);
        self.fd = -1;
    }
};

/// Names of the files zmuxd keeps beside the socket, relative to the socket
/// directory.
const SiblingNames = struct {
    lock_buf: [server_mod.max_socket_path_len + ".lock".len]u8 = undefined,
    pid_buf: [server_mod.max_socket_path_len + ".pid".len]u8 = undefined,
    lock_len: usize = 0,
    pid_len: usize = 0,

    fn init(socket_path: []const u8) SiblingNames {
        var names: SiblingNames = .{};
        const base = std.fs.path.basename(socket_path);
        names.lock_len = (std.fmt.bufPrint(&names.lock_buf, "{s}.lock", .{base}) catch unreachable).len;
        names.pid_len = (std.fmt.bufPrint(&names.pid_buf, "{s}.pid", .{base}) catch unreachable).len;
        return names;
    }

    fn lock(self: *const SiblingNames) []const u8 {
        return self.lock_buf[0..self.lock_len];
    }

    fn pid(self: *const SiblingNames) []const u8 {
        return self.pid_buf[0..self.pid_len];
    }
};

/// The pinned socket directory plus the start lock inside it.
const StartContext = struct {
    dir_fd: sys.fd_t,
    lock: StartLock,

    fn deinit(self: *StartContext) void {
        self.lock.release();
        sys.close(self.dir_fd);
    }
};

/// Validate (or create private) the socket directory first, then take the
/// start lock inside it. The order matters: the lock, PID file, and socket
/// are only ever created in a directory that already passed the ownership
/// and permission checks, through the descriptor that was checked.
fn openStartContext(
    socket_path: []const u8,
    getenv: socket_path_mod.GetEnv,
    timeout_ms: i64,
    stop: ?*const std.atomic.Value(bool),
) !StartContext {
    const dir_fd = try server_mod.openSocketParent(socket_path, getenv);
    errdefer sys.close(dir_fd);
    const names = SiblingNames.init(socket_path);
    const lock = try StartLock.acquire(dir_fd, names.lock(), timeout_ms, stop);
    return .{ .dir_fd = dir_fd, .lock = lock };
}

pub fn main(init: std.process.Init) void {
    runMain(init) catch |err| {
        switch (err) {
            // Usage errors, already reported with a specific message.
            error.InvalidArguments => std.process.exit(2),
            // Already reported with a specific message.
            error.SocketPathTooLong, error.StartupFailed => {},
            else => {
                var buf: [1024]u8 = undefined;
                var w = std.Io.File.stderr().writerStreaming(init.io, &buf);
                w.interface.print("zmuxd: {s}\n", .{@errorName(err)}) catch {};
                w.interface.flush() catch {};
            },
        }
        std.process.exit(1);
    };
}

pub const ParsedArgs = struct {
    idle_timeout_seconds: i64 = default_idle_timeout_seconds,
    explicit_socket_path: ?[]const u8 = null,
    log_level: ?log.Level = null,
    show_version: bool = false,
    show_help: bool = false,
};

pub const ParseArgsError = error{
    MissingSocketValue,
    MissingIdleSecondsValue,
    InvalidIdleSecondsValue,
    NegativeIdleSecondsValue,
    MissingLogLevelValue,
    InvalidLogLevelValue,
    UnknownFlag,
};

pub const ParseArgsFailure = struct {
    err: ParseArgsError,
    arg: ?[]const u8 = null,
    parse_err: ?anyerror = null,
};

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
                if (failure) |f| f.* = .{ .err = error.InvalidIdleSecondsValue, .arg = argv[i], .parse_err = err };
                return error.InvalidIdleSecondsValue;
            };
            // A negative timeout used to disable idle cleanup silently; 0 is
            // the documented way to do that.
            if (parsed.idle_timeout_seconds < 0) {
                if (failure) |f| f.* = .{ .err = error.NegativeIdleSecondsValue, .arg = argv[i] };
                return error.NegativeIdleSecondsValue;
            }
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
    return parsed;
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // Environment first; an explicit --log-level below overrides it.
    log.initFromEnv(init.environ_map);

    var failure: ParseArgsFailure = .{ .err = error.UnknownFlag };
    const parsed = parseArgs(argv, &failure) catch |err| switch (err) {
        error.MissingSocketValue => return fail(io, "missing value for --socket", .{}),
        error.MissingIdleSecondsValue => return fail(io, "missing value for --idle-seconds", .{}),
        error.InvalidIdleSecondsValue => return fail(io, "invalid idle timeout value: {s}", .{@errorName(failure.parse_err.?)}),
        error.NegativeIdleSecondsValue => return fail(io, "--idle-seconds must be 0 or greater, got {s} (0 disables the idle timeout)", .{failure.arg.?}),
        error.MissingLogLevelValue => return fail(io, "missing value for --log-level", .{}),
        error.InvalidLogLevelValue => return fail(io, "invalid log level: {s} (expected error, warn, info, or debug)", .{failure.arg.?}),
        error.UnknownFlag => return fail(io, "unknown flag: {s}", .{failure.arg.?}),
    };

    if (parsed.log_level) |level| log.setLevel(level);
    if (parsed.show_help) {
        try printUsage(io);
        return;
    }
    if (parsed.show_version) {
        try printVersion(io);
        return;
    }

    const idle_timeout_seconds = parsed.idle_timeout_seconds;

    // One resolver for every binary. A relative --socket or $ZMUX_SOCKET is
    // resolved against the current directory here, before anything else
    // touches the path.
    env_values = EnvValues.fromMap(init.environ_map);
    const path = socket_path_mod.resolveUnvalidated(allocator, parsed.explicit_socket_path, envGet) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fail(io, "invalid socket path: {s}", .{socketPathProblem(err)}),
    };
    defer allocator.free(path);

    // Before the lock file or parent directory is created: a path bind(2) can
    // never accept must not leave anything behind.
    socket_path_mod.validate(path) catch |err| switch (err) {
        error.SocketPathTooLong => {
            reportSocketPathTooLong(io, path);
            return error.SocketPathTooLong;
        },
        else => return fail(io, "invalid socket path: {s}", .{socketPathProblem(err)}),
    };

    detachFromControllingTerminal();
    resetSigchldDisposition();
    installShutdownHandlers();

    // The socket directory is validated (or created 0700) before the lock,
    // PID file, or socket is touched, and everything below goes through the
    // pinned descriptor.
    var start = openStartContext(path, envGet, start_lock_timeout_ms, &shutdown_requested) catch |err| {
        return reportStartupFailure(io, path, err);
    };
    defer sys.close(start.dir_fd);
    defer start.lock.release();
    const names = SiblingNames.init(path);

    // Server.init decides what an existing socket means. A daemon that is
    // already listening is not an error: exiting successfully mirrors tmux's
    // start-server race behavior and never displaces the live socket.
    var server = initServer(allocator, io, path, idle_timeout_seconds) catch |err| switch (err) {
        error.AddressInUse => {
            log.info("daemon_already_running", .{ .socket_path = path });
            return;
        },
        else => return reportStartupFailure(io, path, err),
    };

    // Still under the start lock: no other starter can see the socket without
    // its PID file, or remove one while this daemon writes the other.
    const pid_stat: ?sys.Stat = writePidFile(start.dir_fd, names.pid()) catch |err| blk: {
        // The pid file is advisory; failing after the socket is bound would
        // leave a healthy daemon unavailable and a stale socket. Keep
        // serving, but say so: tools that read the pid file will not find
        // this daemon.
        log.warn("pid_file_write_failed", .{ .err = err, .socket_path = path });
        break :blk null;
    };
    start.lock.release();

    defer {
        // Remove the published names under the start lock, and only if they
        // are still the ones this daemon created. Teardown of the panes can
        // take a while and happens after the lock is released.
        var cleanup_lock: ?StartLock = StartLock.acquire(start.dir_fd, names.lock(), start_lock_timeout_ms, null) catch null;
        server.unpublish();
        if (pid_stat) |stat| removePidFile(start.dir_fd, names.pid(), stat);
        if (cleanup_lock) |*held| held.release();
        server.deinit();
    }

    log.info("daemon_start", .{
        .version = protocol.version,
        .socket_path = path,
        .idle_timeout_seconds = idle_timeout_seconds,
        .pid_file_written = pid_stat != null,
        .log_level = log.getLevel(),
    });

    server.shutdown_probe = shutdownRequested;
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
fn initServer(allocator: std.mem.Allocator, io: std.Io, path: []const u8, idle_timeout_seconds: i64) !server_mod.Server {
    const deadline = sys.monotonicMs() + startup_probe_timeout_ms;
    while (true) {
        return server_mod.Server.init(allocator, io, path, idle_timeout_seconds) catch |err| {
            if (err != error.ProbeInconclusive or sys.monotonicMs() >= deadline) return err;
            io.sleep(.fromMilliseconds(50), .awake) catch return err;
            continue;
        };
    }
}

fn socketPathProblem(err: socket_path_mod.Error) []const u8 {
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
fn startupFailureMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InsecurePermissions => "the socket directory is writable by other users; it must be owned by you with mode 0700",
        error.InsecureSocketDirectory => "the socket directory is writable by other users; use a directory you own with no group or other write permission, or a sticky directory such as /tmp",
        error.ForeignOwner => "the socket directory or a file in it is owned by another user",
        error.NotDirectory, error.SymlinkParent => "the socket directory is not a real directory (a symlink or a file is in its place)",
        error.NotRegularFile, error.SymLinkLoop => "the lock file beside the socket is not a regular file (a symlink, FIFO, or directory is in its place)",
        error.Timeout => "timed out waiting for another zmuxd that is starting on this socket",
        error.SocketPathNotSocket => "the socket path exists and is not a socket; zmuxd will not remove it",
        error.AccessDenied => "permission denied for the socket path (it may belong to another user)",
        error.ProbeInconclusive => "could not tell whether a daemon is already listening on the socket; nothing was removed",
        else => null,
    };
}

fn reportStartupFailure(io: std.Io, socket_path: []const u8, err: anyerror) anyerror {
    const message = startupFailureMessage(err) orelse return err;
    log.err("daemon_start_refused", .{ .err = err, .socket_path = socket_path });
    var buf: [std.fs.max_path_bytes + 512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("zmuxd: {s}\nzmuxd: socket: {s}\n", .{ message, socket_path }) catch {};
    w.interface.flush() catch {};
    return error.StartupFailed;
}

/// Longest suffix zmuxd appends to the socket path for a sibling file:
/// the pid file's temporary name, `<socket>.pid.tmp.<pid>`.
const longest_derived_suffix_len = ".pid.tmp.".len + std.fmt.count("{d}", .{std.math.maxInt(u64)});

comptime {
    // `<socket>.lock`, `<socket>.pid`, and the pid temp file are regular files,
    // so only PATH_MAX bounds them, not sun_path. A socket path that passes
    // validation therefore always yields usable derived names; this assertion
    // keeps that true if either limit ever changes.
    std.debug.assert(server_mod.max_socket_path_len + longest_derived_suffix_len < std.fs.max_path_bytes);
}

/// Reject a socket path `bind(2)` cannot accept. The `sun_path` cap applies to
/// the socket path itself; the derived `.lock`/`.pid` names are covered by the
/// comptime assertion above.
fn validateSocketPath(socket_path: []const u8) socket_path_mod.Error!void {
    return socket_path_mod.validate(socket_path);
}

fn socketPathTooLongMessage(buf: []u8, socket_path: []const u8) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "zmuxd: socket path is too long: {d} bytes, but this OS allows at most {d} bytes for a Unix socket path\n" ++
            "zmuxd: path: {s}\n" ++
            "zmuxd: choose a shorter path with --socket or $ZMUX_SOCKET\n",
        .{ socket_path.len, server_mod.max_socket_path_len, socket_path },
    ) catch "zmuxd: socket path is too long for a Unix socket\n";
}

fn reportSocketPathTooLong(io: std.Io, socket_path: []const u8) void {
    log.err("socket_path_too_long", .{
        .socket_path_len = socket_path.len,
        .max_socket_path_len = server_mod.max_socket_path_len,
    });
    var buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    std.Io.File.stderr().writeStreamingAll(io, socketPathTooLongMessage(&buf, socket_path)) catch {};
}

/// Default socket path: `$ZMUX_SOCKET`, `$SMITHERS_SESSION_SOCKET`,
/// `$XDG_RUNTIME_DIR/smithers-sessions.sock`, `$HOME/.smithers/sessions.sock`,
/// then `/tmp/zmux-<euid>/sessions.sock`. Pass `std.process.Init.environ_map`.
/// The result is absolute and validated; `socket_path.resolve` is the single
/// implementation.
pub fn socketPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    env_values = EnvValues.fromMap(environ);
    return socket_path_mod.resolve(allocator, null, envGet);
}

fn socketPathFromEnv(
    allocator: std.mem.Allocator,
    zmux_socket: ?[]const u8,
    smithers_socket: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    home: ?[]const u8,
) ![]u8 {
    env_values = .{
        .zmux_socket = zmux_socket,
        .smithers_socket = smithers_socket,
        .xdg_runtime_dir = xdg_runtime_dir,
        .home = home,
    };
    return socket_path_mod.resolve(allocator, null, envGet);
}

fn pidPath(allocator: std.mem.Allocator, active_socket_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.pid", .{active_socket_path});
}

fn nameZ(buf: *[posix.PATH_MAX]u8, name: []const u8) error{NameTooLong}![*:0]const u8 {
    if (name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0].ptr;
}

fn renameAt(dir_fd: sys.fd_t, old_name: []const u8, new_name: []const u8) !void {
    var old_buf: [posix.PATH_MAX]u8 = undefined;
    var new_buf: [posix.PATH_MAX]u8 = undefined;
    const old_z = try nameZ(&old_buf, old_name);
    const new_z = try nameZ(&new_buf, new_name);
    switch (posix.errno(std.c.renameat(dir_fd, old_z, dir_fd, new_z))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .ISDIR => return error.IsDir,
        .NOTDIR => return error.NotDir,
        else => return error.Unexpected,
    }
}

/// Write this process's pid to `pid_name` inside the pinned socket directory,
/// atomically, and return the identity of the file written so cleanup removes
/// only that file.
///
/// The temporary file is created with `O_EXCL|O_NOFOLLOW`; its cleanup is
/// armed only after that create succeeds, so a pre-existing entry with the
/// temporary name is never removed.
fn writePidFile(dir_fd: sys.fd_t, pid_name: []const u8) !sys.Stat {
    var tmp_buf: [posix.PATH_MAX]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}", .{ pid_name, sys.getpid() });

    // An entry already at the temporary name is not ours: leave it in place.
    if (sys.statAt(dir_fd, tmp_name, false)) |_| {
        return error.PathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const fd = try sys.openOwnedRegularAt(dir_fd, tmp_name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    var renamed = false;
    defer if (!renamed) sys.unlinkAt(dir_fd, tmp_name) catch {};
    defer sys.close(fd);

    // Readable by its owner whatever the umask was.
    try sys.fchmod(fd, 0o600);
    var text_buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{d}\n", .{sys.getpid()});
    try sys.writeAll(fd, text);
    if (std.c.fsync(fd) != 0) return error.InputOutput;
    const stat = try sys.fstat(fd);

    try renameAt(dir_fd, tmp_name, pid_name);
    renamed = true;
    return stat;
}

/// Remove the pid file only if it is still the file `writePidFile` created.
/// A successor daemon's pid file has another inode and is left alone.
fn removePidFile(dir_fd: sys.fd_t, pid_name: []const u8, written: sys.Stat) void {
    const current = sys.statAt(dir_fd, pid_name, false) catch return;
    if (!current.sameFile(written)) return;
    sys.unlinkAt(dir_fd, pid_name) catch {};
}

fn printUsage(io: std.Io) !void {
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

fn printVersion(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io, "zmuxd " ++ protocol.version ++ "\n");
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print("zmuxd: " ++ fmt ++ "\n", args) catch {};
    w.interface.print("Try 'zmuxd --help' for usage.\n", .{}) catch {};
    w.interface.flush() catch {};
    return error.InvalidArguments;
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
};

const posix_ok = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

fn tempPath(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    return std.fmt.allocPrint(allocator, "{s}/{s}-{x:0>16}", .{ root, prefix, nonce });
}

/// A fresh private directory and a pinned descriptor for it.
const TempDir = struct {
    path: []u8,
    fd: sys.fd_t,

    fn init(prefix: []const u8) !TempDir {
        const path = try tempPath(std.testing.allocator, prefix);
        errdefer std.testing.allocator.free(path);
        try sys.mkdir(path, 0o700);
        const fd = try sys.openDirNoFollow(path);
        return .{ .path = path, .fd = fd };
    }

    fn deinit(self: *TempDir) void {
        sys.close(self.fd);
        std.Io.Dir.cwd().deleteTree(test_io, self.path) catch {};
        std.testing.allocator.free(self.path);
    }

    fn child(self: *const TempDir, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ self.path, name }, 0);
    }

    fn entryCount(self: *const TempDir) !usize {
        var dir = try std.Io.Dir.openDirAbsolute(test_io, self.path, .{ .iterate = true });
        defer dir.close(test_io);
        var iterator = dir.iterate();
        var count: usize = 0;
        while (try iterator.next(test_io)) |_| count += 1;
        return count;
    }
};

fn chmodPath(path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

fn pathMode(path: []const u8) !u32 {
    return (try sys.statAt(sys.cwd_fd, path, false)).permissions();
}

test "socket path falls back to HOME/.smithers when HOME is provided" {
    const path = try socketPathFromEnv(std.testing.allocator, null, null, null, "/tmp/daemon-home-sim");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/daemon-home-sim/.smithers/sessions.sock", path);
}

test "socket path falls back to uid-scoped /tmp directory when HOME is unavailable" {
    const path = try socketPathFromEnv(std.testing.allocator, null, null, null, null);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "a relative --socket or environment path resolves against the current directory" {
    const allocator = std.testing.allocator;
    var cwd_buf: [posix.PATH_MAX]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.SkipZigTest;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_ptr)), 0);
    if (cwd.len + "/z.sock".len > server_mod.max_socket_path_len) return error.SkipZigTest;
    const expected = try std.fs.path.join(allocator, &.{ cwd, "z.sock" });
    defer allocator.free(expected);

    // What runMain does with `--socket ./z.sock`.
    env_values = .{};
    const explicit = try socket_path_mod.resolveUnvalidated(allocator, "./z.sock", envGet);
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings(expected, explicit);
    try socket_path_mod.validate(explicit);

    // The same for a relative $ZMUX_SOCKET, which outranks every default.
    const from_env = try socketPathFromEnv(allocator, "z.sock", "/ignored/smithers.sock", "/ignored/xdg", "/ignored/home");
    defer allocator.free(from_env);
    try std.testing.expectEqualStrings(expected, from_env);

    // Nothing was created by resolving.
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "z.sock", false));
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

test "start lock file is never unlinked and excludes a second holder" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock");
    defer dir.deinit();
    const name = "sessions.sock.lock";

    var first = try StartLock.acquire(dir.fd, name, 500, null);
    const created = try sys.statAt(dir.fd, name, false);
    try std.testing.expectEqual(@as(u32, posix.S.IFREG), created.kind());
    try std.testing.expectEqual(@as(u32, 0o600), created.permissions());
    try std.testing.expectEqual(sys.geteuid(), created.uid);

    // Held: a second starter times out instead of getting its own lock.
    const start = sys.monotonicMs();
    try std.testing.expectError(error.Timeout, StartLock.acquire(dir.fd, name, 150, null));
    try std.testing.expect(sys.monotonicMs() - start >= 100);
    try std.testing.expect(created.sameFile(try sys.statAt(dir.fd, name, false)));

    // Released: the file is still there, same inode, and can be taken again.
    first.release();
    first.release();
    try std.testing.expect(created.sameFile(try sys.statAt(dir.fd, name, false)));

    var second = try StartLock.acquire(dir.fd, name, 500, null);
    try std.testing.expect(created.sameFile(try sys.fstat(second.fd)));
    second.release();
    try std.testing.expect(created.sameFile(try sys.statAt(dir.fd, name, false)));
    try std.testing.expectEqual(@as(usize, 1), try dir.entryCount());
}

const LockContention = struct {
    dir_fd: sys.fd_t,
    inside: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_inside: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    entries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    inodes_differ: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    first_ino: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const name = "sessions.sock.lock";

    fn starter(self: *LockContention) void {
        var round: usize = 0;
        while (round < 6) : (round += 1) {
            var lock = StartLock.acquire(self.dir_fd, name, 10_000, null) catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                return;
            };
            const now_inside = self.inside.fetchAdd(1, .seq_cst) + 1;
            _ = self.max_inside.fetchMax(now_inside, .seq_cst);
            _ = self.entries.fetchAdd(1, .seq_cst);

            // Every holder must be locking the one persistent inode.
            if (sys.fstat(lock.fd)) |stat| {
                const previous = self.first_ino.cmpxchgStrong(0, stat.ino, .seq_cst, .seq_cst);
                if (previous != null and previous.? != stat.ino) self.inodes_differ.store(true, .seq_cst);
            } else |_| {
                _ = self.failures.fetchAdd(1, .seq_cst);
            }

            test_io.sleep(.fromMilliseconds(3), .awake) catch {};
            _ = self.inside.fetchSub(1, .seq_cst);
            lock.release();
        }
    }
};

test "three concurrent starters never hold the start lock together" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock-race");
    defer dir.deinit();

    // Release-then-reacquire is exactly the window where an unlinking lock
    // lets two starters each lock a different inode.
    var contention: LockContention = .{ .dir_fd = dir.fd };
    var threads: [3]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, LockContention.starter, .{&contention});
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), contention.failures.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 18), contention.entries.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), contention.max_inside.load(.seq_cst));
    try std.testing.expect(!contention.inodes_differ.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), try dir.entryCount());
}

test "waiting for the start lock stops when shutdown is requested" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock-stop");
    defer dir.deinit();
    const name = "sessions.sock.lock";

    var held = try StartLock.acquire(dir.fd, name, 500, null);
    defer held.release();

    var stop = std.atomic.Value(bool).init(true);
    const start = sys.monotonicMs();
    try std.testing.expectError(error.Interrupted, StartLock.acquire(dir.fd, name, 30_000, &stop));
    try std.testing.expect(sys.monotonicMs() - start < 2000);
}

test "a symlink or FIFO in place of the lock file is refused without following or hanging" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dir = try TempDir.init("zmx-lock-planted");
    defer dir.deinit();

    // A dangling symlink: following it would create a file wherever the
    // attacker pointed.
    const target = try dir.child("attacker-chosen-target");
    defer allocator.free(target);
    const link = try dir.child("link.sock.lock");
    defer allocator.free(link);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target.ptr, link.ptr));
    if (StartLock.acquire(dir.fd, "link.sock.lock", 200, null)) |acquired| {
        var lock = acquired;
        lock.release();
        return error.SymlinkedLockAccepted;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, target, false));

    // A symlink to an existing regular file is refused as well.
    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, target, .{});
        file.close(test_io);
    }
    if (StartLock.acquire(dir.fd, "link.sock.lock", 200, null)) |acquired| {
        var lock = acquired;
        lock.release();
        return error.SymlinkedLockAccepted;
    } else |_| {}

    // A FIFO: a blocking open would hang the daemon forever.
    const fifo = try dir.child("fifo.sock.lock");
    defer allocator.free(fifo);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo.ptr, 0o600));
    const start = sys.monotonicMs();
    try std.testing.expectError(error.NotRegularFile, StartLock.acquire(dir.fd, "fifo.sock.lock", 200, null));
    try std.testing.expect(sys.monotonicMs() - start < 2000);
}

test "the start lock stays usable under a umask that clears every bit" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock-umask");
    defer dir.deinit();
    const name = "sessions.sock.lock";

    const original_umask = std.c.umask(0o777);
    defer _ = std.c.umask(original_umask);

    var first = try StartLock.acquire(dir.fd, name, 500, null);
    first.release();
    try std.testing.expectEqual(@as(u32, 0o600), (try sys.statAt(dir.fd, name, false)).permissions());
    var second = try StartLock.acquire(dir.fd, name, 500, null);
    second.release();
}

test "the socket directory is made private before the lock exists" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var home = try TempDir.init("zmx-daemon-home");
    defer home.deinit();

    env_values = .{ .home = home.path };
    defer env_values = .{};
    const managed = try std.fs.path.join(allocator, &.{ home.path, ".smithers" });
    defer allocator.free(managed);
    const socket_path = try socketPathFromEnv(allocator, null, null, null, home.path);
    defer allocator.free(socket_path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{socket_path});
    defer allocator.free(lock_path);
    try std.testing.expect(socket_path_mod.isDefaultManaged(socket_path, envGet));

    // Missing: created 0700 even under a permissive umask, then locked.
    {
        const original_umask = std.c.umask(0);
        defer _ = std.c.umask(original_umask);
        var start = try openStartContext(socket_path, envGet, 500, null);
        defer start.deinit();
        try std.testing.expectEqual(@as(u32, 0o700), try pathMode(managed));
        try std.testing.expectEqual(@as(u32, 0o600), try pathMode(lock_path));
        // The lock lives in the directory that was validated.
        try std.testing.expect((try sys.fstat(start.dir_fd)).sameFile(try sys.statAt(sys.cwd_fd, managed, false)));
        try std.testing.expect((try sys.fstat(start.lock.fd)).sameFile(try sys.statAt(start.dir_fd, "sessions.sock.lock", false)));
    }
}

test "an insecure socket directory is refused before any lock file is created" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var home = try TempDir.init("zmx-daemon-home-open");
    defer home.deinit();

    env_values = .{ .home = home.path };
    defer env_values = .{};
    const managed = try std.fs.path.join(allocator, &.{ home.path, ".smithers" });
    defer allocator.free(managed);
    const socket_path = try socketPathFromEnv(allocator, null, null, null, home.path);
    defer allocator.free(socket_path);

    // A pre-existing world-writable managed directory (the /tmp/zmux-<uid>
    // hijack): the 0700 requirement is checked first, so no lock, PID file,
    // or socket is ever created in it.
    try sys.mkdir(managed, 0o700);
    for ([_]std.c.mode_t{ 0o777, 0o770, 0o1777 }) |mode| {
        try chmodPath(managed, mode);
        try std.testing.expectError(error.InsecurePermissions, openStartContext(socket_path, envGet, 500, null));
        try std.testing.expectEqual(@as(u32, mode), try pathMode(managed));
        var dir = try std.Io.Dir.openDirAbsolute(test_io, managed, .{ .iterate = true });
        defer dir.close(test_io);
        var iterator = dir.iterate();
        try std.testing.expect((try iterator.next(test_io)) == null);
    }

    // A 0755 directory from an older release is tightened, then locked.
    try chmodPath(managed, 0o755);
    {
        var start = try openStartContext(socket_path, envGet, 500, null);
        defer start.deinit();
        try std.testing.expectEqual(@as(u32, 0o700), try pathMode(managed));
    }

    // A user-selected directory that others can write to (and is not sticky)
    // is refused the same way.
    var shared = try TempDir.init("zmx-daemon-shared");
    defer shared.deinit();
    try chmodPath(shared.path, 0o777);
    const shared_socket = try std.fs.path.join(allocator, &.{ shared.path, "z.sock" });
    defer allocator.free(shared_socket);
    try std.testing.expectError(error.InsecureSocketDirectory, openStartContext(shared_socket, envGet, 500, null));
    try std.testing.expectEqual(@as(usize, 0), try shared.entryCount());
    try std.testing.expect(startupFailureMessage(error.InsecureSocketDirectory) != null);
    try std.testing.expect(startupFailureMessage(error.InsecurePermissions) != null);
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

/// Comptime `[n]u8` filled with `byte` (Zig 0.17 removed the `**` operator).
fn repeatedByte(comptime byte: u8, comptime n: usize) [n]u8 {
    return @splat(byte);
}

test "validateSocketPath accepts the sun_path limit and rejects one byte more" {
    const max = server_mod.max_socket_path_len;
    const at_limit = "/" ++ repeatedByte('s', max - 1);
    const too_long = "/" ++ repeatedByte('s', max);
    try std.testing.expectEqual(max, at_limit.len);
    try validateSocketPath(at_limit);
    try validateSocketPath("/tmp/zmux-test.sock");
    try std.testing.expectError(error.SocketPathTooLong, validateSocketPath(too_long));
}

test "socket path too long message states the actual and maximum byte lengths" {
    const max = server_mod.max_socket_path_len;
    const too_long = "/" ++ repeatedByte('s', max + 20);
    var buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const message = socketPathTooLongMessage(&buf, too_long);

    var expected_buf: [96]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{d} bytes, but this OS allows at most {d} bytes", .{ max + 21, max });
    try std.testing.expect(std.mem.indexOf(u8, message, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, too_long) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "--socket") != null);
}

test "derived lock and pid names fit for any valid socket path" {
    const max = server_mod.max_socket_path_len;
    const at_limit = "/" ++ repeatedByte('s', max - 1);
    const pid_path = try pidPath(std.testing.allocator, at_limit);
    defer std.testing.allocator.free(pid_path);
    try std.testing.expect(pid_path.len + ".tmp.".len + 20 < std.fs.max_path_bytes);
    try std.testing.expect(at_limit.len + ".lock".len < std.fs.max_path_bytes);

    const names = SiblingNames.init(at_limit);
    try std.testing.expectEqualStrings(at_limit[1..] ++ ".lock", names.lock());
    try std.testing.expectEqualStrings(at_limit[1..] ++ ".pid", names.pid());

    const short = SiblingNames.init("/tmp/zmux-1000/sessions.sock");
    try std.testing.expectEqualStrings("sessions.sock.lock", short.lock());
    try std.testing.expectEqualStrings("sessions.sock.pid", short.pid());
}

test "pid path is scoped to the socket path" {
    const path = try pidPath(std.testing.allocator, "/tmp/zmux-test.sock");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/zmux-test.sock.pid", path);
}

test "pid file write is atomic, private, and cleanly removable" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dir = try TempDir.init("zmx-pid");
    defer dir.deinit();
    const name = "sessions.sock.pid";

    // A permissive umask must not widen the file.
    const original_umask = std.c.umask(0);
    defer _ = std.c.umask(original_umask);

    const written = try writePidFile(dir.fd, name);
    const pid_path = try dir.child(name);
    defer allocator.free(pid_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, pid_path, allocator, .limited(64));
    defer allocator.free(text);

    const expected = try std.fmt.allocPrint(allocator, "{}\n", .{sys.getpid()});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, text);

    const on_disk = try sys.statAt(dir.fd, name, false);
    try std.testing.expect(written.sameFile(on_disk));
    try std.testing.expectEqual(@as(u32, 0o600), on_disk.permissions());
    // No temporary file is left beside it.
    try std.testing.expectEqual(@as(usize, 1), try dir.entryCount());

    removePidFile(dir.fd, name, written);
    try std.testing.expectError(error.FileNotFound, sys.statAt(dir.fd, name, false));
    // Removing again is harmless.
    removePidFile(dir.fd, name, written);
}

test "pid cleanup leaves a successor's pid file alone" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dir = try TempDir.init("zmx-pid-successor");
    defer dir.deinit();
    const name = "sessions.sock.pid";

    const written = try writePidFile(dir.fd, name);

    // A successor daemon replaced the file (new inode, other contents). The
    // old file is kept linked under another name so its inode number cannot
    // be recycled for the replacement.
    try renameAt(dir.fd, name, "old.pid");
    const pid_path = try dir.child(name);
    defer allocator.free(pid_path);
    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, pid_path, .{});
        defer file.close(test_io);
        try file.writeStreamingAll(test_io, "424242\n");
    }

    removePidFile(dir.fd, name, written);
    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, pid_path, allocator, .limited(64));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("424242\n", text);
}

test "a pre-existing pid temp file survives a failed pid write" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dir = try TempDir.init("zmx-pid-temp");
    defer dir.deinit();
    const name = "sessions.sock.pid";

    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ name, sys.getpid() });
    defer allocator.free(tmp_name);
    const tmp_path = try dir.child(tmp_name);
    defer allocator.free(tmp_path);
    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, tmp_path, .{});
        defer file.close(test_io);
        try file.writeStreamingAll(test_io, "someone else's\n");
    }

    try std.testing.expectError(error.PathAlreadyExists, writePidFile(dir.fd, name));
    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, tmp_path, allocator, .limited(64));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("someone else's\n", text);
    try std.testing.expectError(error.FileNotFound, sys.statAt(dir.fd, name, false));
}

test "pid file write failure is reported as an error instead of being swallowed" {
    if (!posix_ok) return error.SkipZigTest;
    // Root ignores directory permissions.
    if (sys.geteuid() == 0) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-pid-readonly");
    defer dir.deinit();

    try chmodPath(dir.path, 0o500);
    defer chmodPath(dir.path, 0o700) catch {};
    try std.testing.expectError(error.AccessDenied, writePidFile(dir.fd, "sessions.sock.pid"));
    try std.testing.expectEqual(@as(usize, 0), try dir.entryCount());
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
