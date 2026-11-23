const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");
const sys = @import("sys.zig");

const default_idle_timeout_seconds: i64 = 60 * 60;
const startup_probe_timeout_ms: i64 = 2000;
var shutdown_requested = std.atomic.Value(bool).init(false);

const StartLock = struct {
    io: std.Io,
    file: std.Io.File,
    path: []u8,
    allocator: std.mem.Allocator,

    pub fn release(self: *StartLock) void {
        self.file.close(self.io);
        std.Io.Dir.deleteFileAbsolute(self.io, self.path) catch {};
        self.allocator.free(self.path);
    }
};

pub fn main(init: std.process.Init) void {
    runMain(init) catch |err| {
        switch (err) {
            // Already reported with a specific message.
            error.InvalidArguments, error.SocketPathTooLong => {},
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
    const explicit_socket_path = parsed.explicit_socket_path;

    const path = if (explicit_socket_path) |value|
        try allocator.dupe(u8, value)
    else
        try socketPath(allocator, init.environ_map);
    defer allocator.free(path);

    // Before the lock file or parent directory is created: a path bind(2) can
    // never accept must not leave anything behind.
    validateSocketPath(path) catch |err| {
        reportSocketPathTooLong(io, path);
        return err;
    };

    detachFromControllingTerminal();
    resetSigchldDisposition();
    installShutdownHandlers();

    var start_lock: ?StartLock = try acquireStartLock(allocator, io, path);
    defer if (start_lock) |*lock| lock.release();

    // If a server came up while we waited for the lock, this daemon instance
    // has nothing to do. Exiting successfully mirrors tmux's start-server
    // race behavior without unlinking another server's live socket.
    if (socketPathExists(io, path) and waitForSocketAcceptsConnection(io, path, startup_probe_timeout_ms)) {
        log.info("daemon_already_running", .{ .socket_path = path });
        return;
    }

    var server = try server_mod.Server.init(allocator, io, path, idle_timeout_seconds);
    defer server.deinit();
    if (start_lock) |*lock| {
        lock.release();
        start_lock = null;
    }

    const pid_file_path = pidPath(allocator, path) catch null;
    defer if (pid_file_path) |pid_path| allocator.free(pid_path);
    var pid_file_written = false;
    if (pid_file_path) |pid_path| {
        if (writePidFile(allocator, io, pid_path)) {
            pid_file_written = true;
        } else |err| {
            // The pid file is advisory; failing after the socket is bound
            // would leave a healthy daemon unavailable and a stale socket.
            // Keep serving, but say so: tools that read the pid file will not
            // find this daemon.
            log.warn("pid_file_write_failed", .{ .err = err, .pid_path = pid_path });
        }
    }
    defer if (pid_file_written) {
        if (pid_file_path) |pid_path| deletePidFile(io, pid_path);
    };

    log.info("daemon_start", .{
        .version = protocol.version,
        .socket_path = path,
        .idle_timeout_seconds = idle_timeout_seconds,
        .pid_file_written = pid_file_written,
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

/// Longest suffix zmuxd appends to the socket path for a sibling file:
/// the pid file's temporary name, `<socket>.pid.tmp.<pid>`.
const longest_derived_suffix_len = ".pid.tmp.".len + std.fmt.count("{d}", .{std.math.maxInt(u64)});

comptime {
    // `<socket>.lock`, `<socket>.pid`, and the pid temp file are regular files,
    // so only PATH_MAX bounds them, not sun_path. A socket path that passes
    // validateSocketPath therefore always yields usable derived paths; this
    // assertion keeps that true if either limit ever changes.
    std.debug.assert(server_mod.max_socket_path_len + longest_derived_suffix_len < std.fs.max_path_bytes);
}

/// Reject a socket path `bind(2)` cannot accept. The `sun_path` cap applies to
/// the socket path itself; the derived `.lock`/`.pid` paths are covered by the
/// comptime assertion above.
fn validateSocketPath(socket_path: []const u8) error{SocketPathTooLong}!void {
    if (socket_path.len > server_mod.max_socket_path_len) return error.SocketPathTooLong;
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
pub fn socketPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    return socketPathFromEnv(
        allocator,
        environ.get("ZMUX_SOCKET"),
        environ.get("SMITHERS_SESSION_SOCKET"),
        environ.get("XDG_RUNTIME_DIR"),
        environ.get("HOME"),
    );
}

fn socketPathFromEnv(
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

    const fallback_dir = try std.fmt.allocPrint(allocator, "/tmp/zmux-{d}", .{sys.geteuid()});
    defer allocator.free(fallback_dir);
    return std.fs.path.join(allocator, &.{ fallback_dir, "sessions.sock" });
}

fn pidPath(allocator: std.mem.Allocator, active_socket_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.pid", .{active_socket_path});
}

fn writePidFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    try ensureParent(io, path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, sys.getpid() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    var file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{
        .truncate = true,
        .exclusive = true,
        .permissions = .fromMode(0o600),
    });
    var file_open = true;
    defer if (file_open) file.close(io);

    const text = try std.fmt.allocPrint(allocator, "{}\n", .{sys.getpid()});
    defer allocator.free(text);
    try file.writeStreamingAll(io, text);
    try file.sync(io);
    file.close(io);
    file_open = false;
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

fn deletePidFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

fn acquireStartLock(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8) !StartLock {
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{socket_path});
    errdefer allocator.free(lock_path);

    try ensureParent(io, lock_path);
    const file = try std.Io.Dir.createFileAbsolute(io, lock_path, .{
        .truncate = false,
        .permissions = .fromMode(0o600),
        .lock = .exclusive,
    });
    errdefer file.close(io);

    return .{
        .io = io,
        .file = file,
        .path = lock_path,
        .allocator = allocator,
    };
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    // 0755 matches Zig 0.15 `std.fs.makeDirAbsolute`; Zig 0.17's `.default_dir`
    // is 0777 and would leave the directory world-writable under umask 0.
    std.Io.Dir.createDirAbsolute(io, parent, .fromMode(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

const SocketProbe = enum {
    /// A daemon is listening and accepted our probe connection.
    live,
    /// Definitive stale/dead socket: connect() was refused (no listener) or
    /// the path is gone. No amount of waiting turns this into a live daemon.
    dead,
    /// Transient/ambiguous failure (e.g. a daemon that has bound but is not yet
    /// accepting, or a temporary fd exhaustion): worth retrying to the deadline.
    retry,
};

fn probeSocketConnection(socket_path: []const u8) SocketProbe {
    const address = sys.UnixAddress.init(socket_path) catch return .dead;
    const fd = sys.unixStreamSocket() catch return .retry;
    defer sys.close(fd);

    sys.connect(fd, &address) catch |err| switch (err) {
        // ECONNREFUSED / ENOENT: the daemon that bound this socket is gone or
        // the file vanished. Both are definitive stale-socket signals.
        error.ConnectionRefused, error.FileNotFound => return .dead,
        else => return .retry,
    };
    return .live;
}

fn socketAcceptsConnection(socket_path: []const u8) bool {
    return probeSocketConnection(socket_path) == .live;
}

fn waitForSocketAcceptsConnection(io: std.Io, socket_path: []const u8, timeout_ms: i64) bool {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms));
    while (true) {
        switch (probeSocketConnection(socket_path)) {
            .live => return true,
            // Bail immediately on a definitive dead socket so main() can
            // proceed to Server.init (which unlinks the stale file) instead of
            // burning the whole startup budget on doomed retries.
            .dead => return false,
            .retry => {},
        }
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return false;
        io.sleep(.fromMilliseconds(50), .awake) catch return false;
    }
}

fn socketPathExists(io: std.Io, socket_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, socket_path, .{}) catch return false;
    return true;
}

fn printUsage(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\Usage: zmuxd [--socket PATH] [--idle-seconds SECONDS] [--log-level LEVEL]
        \\       smithers-session-daemon [--socket PATH] [--idle-seconds SECONDS] [--log-level LEVEL]
        \\
        \\Options:
        \\  --socket PATH           Unix socket to listen on (default: $ZMUX_SOCKET, then
        \\                          $XDG_RUNTIME_DIR/smithers-sessions.sock, then ~/.smithers/sessions.sock)
        \\  --idle-seconds SECONDS  Exit after this long with no sessions; 0 disables (default: 3600)
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
    pub const writePidFileFn = writePidFile;
    pub const deletePidFileFn = deletePidFile;
    pub const acquireStartLockFn = acquireStartLock;
    pub const socketAcceptsConnectionFn = socketAcceptsConnection;
    pub const waitForSocketAcceptsConnectionFn = waitForSocketAcceptsConnection;
};

test "socket path falls back to HOME/.smithers when HOME is provided" {
    const path = try socketPathFromEnv(std.testing.allocator, null, null, null, "/tmp/daemon-home-sim");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "smithers-sessions.sock") or
        std.mem.endsWith(u8, path, ".smithers/sessions.sock"));
}

test "socket path falls back to uid-scoped /tmp directory when HOME is unavailable" {
    const path = try socketPathFromEnv(std.testing.allocator, null, null, null, null);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "stale unix socket is rejected immediately during startup probe" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const seed = try std.testing.allocator.alloc(u8, 16);
    defer allocator.free(seed);
    test_io.random(seed);
    const nonce = std.mem.readInt(u64, seed[0..8], .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(allocator, "{s}/zmx-stale-{x:0>16}.sock", .{ root, nonce });
    defer allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};
    std.Io.Dir.deleteFileAbsolute(test_io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try sys.UnixAddress.init(path);
    const listener = try sys.unixStreamSocket();
    sys.bind(listener, &address) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try sys.listen(listener, 1);
    sys.close(listener);

    const start = std.Io.Clock.awake.now(test_io);
    try std.testing.expect(!waitForSocketAcceptsConnection(test_io, path, startup_probe_timeout_ms));
    const elapsed_ms = start.untilNow(test_io, .awake).toMilliseconds();
    try std.testing.expect(elapsed_ms < 500);
}

test "socketAcceptsConnection detects a listening unix socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/zmx-live-{x:0>16}.sock", .{ root, nonce });
    defer std.testing.allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};

    const address = try sys.UnixAddress.init(path);
    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    sys.bind(listener, &address) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try sys.listen(listener, 1);

    try std.testing.expect(socketAcceptsConnection(path));
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

test "derived lock and pid paths stay within PATH_MAX for any valid socket path" {
    const max = server_mod.max_socket_path_len;
    const at_limit = "/" ++ repeatedByte('s', max - 1);
    const pid_path = try pidPath(std.testing.allocator, at_limit);
    defer std.testing.allocator.free(pid_path);
    try std.testing.expect(pid_path.len + ".tmp.".len + 20 < std.fs.max_path_bytes);
    try std.testing.expect(at_limit.len + ".lock".len < std.fs.max_path_bytes);
}

test "pid file write failure is reported as an error instead of being swallowed" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    // The parent is a regular file, so neither mkdir nor create can succeed.
    const blocker = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zmx-pid-blocker-{x:0>16}", .{nonce});
    defer std.testing.allocator.free(blocker);
    defer std.Io.Dir.deleteFileAbsolute(test_io, blocker) catch {};
    (try std.Io.Dir.createFileAbsolute(test_io, blocker, .{})).close(test_io);

    const pid_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sessions.sock.pid", .{blocker});
    defer std.testing.allocator.free(pid_path);
    if (writePidFile(std.testing.allocator, test_io, pid_path)) {
        return error.TestExpectedError;
    } else |_| {}
}

test "pid path is scoped to the socket path" {
    const path = try pidPath(std.testing.allocator, "/tmp/zmux-test.sock");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/zmux-test.sock.pid", path);
}

test "pid file write is atomic and cleanly removable" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var seed: [8]u8 = undefined;
    test_io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/zmx-pid-{x:0>16}.sock.pid", .{ root, nonce });
    defer std.testing.allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};

    try writePidFile(std.testing.allocator, test_io, path);
    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(text);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{}\n", .{sys.getpid()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, text);

    deletePidFile(test_io, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(test_io, path, .{}));
}

test "resetSigchldDisposition restores default SIGCHLD handling" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

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
    std.testing.refAllDecls(@import("sys.zig"));
}
