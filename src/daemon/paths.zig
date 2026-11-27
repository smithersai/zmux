//! Socket path resolution for the daemon: the environment values the shared
//! resolver reads, validation, and the paths derived from the socket path.
const std = @import("std");

const server_mod = @import("../server.zig");
const socket_path_mod = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const cli = @import("cli.zig");
const lock_mod = @import("lock.zig");
const pidfile = @import("pidfile.zig");

const posix = std.posix;
const assert = std.debug.assert;
const test_io = std.testing.io;
const posix_ok = pidfile.posix_ok;
const TempDir = pidfile.TempDir;
const chmodPath = pidfile.chmodPath;
const pathMode = pidfile.pathMode;
const SiblingNames = lock_mod.SiblingNames;
const openStartContext = lock_mod.openStartContext;
const startupFailureMessage = cli.startupFailureMessage;
const socketPathTooLongMessage = cli.socketPathTooLongMessage;
const fail = cli.fail;
const socketPathProblem = cli.socketPathProblem;
const reportSocketPathTooLong = cli.reportSocketPathTooLong;

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

/// `socket_path.GetEnv` over the values parked in `env_values`.
pub fn envGet(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "ZMUX_SOCKET")) return env_values.zmux_socket;
    if (std.mem.eql(u8, name, "SMITHERS_SESSION_SOCKET")) return env_values.smithers_socket;
    if (std.mem.eql(u8, name, "XDG_RUNTIME_DIR")) return env_values.xdg_runtime_dir;
    if (std.mem.eql(u8, name, "HOME")) return env_values.home;
    return null;
}

/// Resolve and validate the socket path, reporting a bad path on stderr.
/// Caller owns the returned absolute path.
pub fn resolveSocketPathOrFail(allocator: std.mem.Allocator, io: std.Io, explicit: ?[]const u8) ![]u8 {
    // One resolver for every binary. A relative --socket or $ZMUX_SOCKET is
    // resolved against the current directory here, before anything else
    // touches the path.
    const path = socket_path_mod.resolveUnvalidated(allocator, explicit, envGet) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fail(io, "invalid socket path: {s}", .{socketPathProblem(err)}),
    };
    errdefer allocator.free(path);

    // Before the lock file or parent directory is created: a path bind(2) can
    // never accept must not leave anything behind.
    socket_path_mod.validate(path) catch |err| switch (err) {
        error.SocketPathTooLong => {
            reportSocketPathTooLong(io, path);
            return error.SocketPathTooLong;
        },
        else => return fail(io, "invalid socket path: {s}", .{socketPathProblem(err)}),
    };
    assert(path.len <= server_mod.max_socket_path_len);
    return path;
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
pub fn validateSocketPath(socket_path: []const u8) socket_path_mod.Error!void {
    return socket_path_mod.validate(socket_path);
}

/// Park the environment values socket path resolution reads.
pub fn loadEnv(environ: *const std.process.Environ.Map) void {
    env_values = EnvValues.fromMap(environ);
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

/// `socketPath` from explicit environment values instead of a map.
pub fn socketPathFromEnv(
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
    const path = try socket_path_mod.resolve(allocator, null, envGet);
    assert(std.fs.path.isAbsolute(path));
    return path;
}

/// The pid file path for `active_socket_path`: `<socket>.pid`.
pub fn pidPath(allocator: std.mem.Allocator, active_socket_path: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}.pid", .{active_socket_path});
    assert(path.len == active_socket_path.len + ".pid".len);
    return path;
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
