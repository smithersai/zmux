const std = @import("std");
const builtin = @import("builtin");

const protocol = @import("protocol.zig");

const server_mod = @import("server.zig");

const default_idle_timeout_seconds: i64 = 60 * 60;
const startup_probe_timeout_ms: i64 = 2000;
var shutdown_requested = std.atomic.Value(bool).init(false);

const StartLock = struct {
    file: std.fs.File,
    path: []u8,
    allocator: std.mem.Allocator,

    fn release(self: *StartLock) void {
        self.file.close();
        std.fs.deleteFileAbsolute(self.path) catch {};
        self.allocator.free(self.path);
    }
};

pub fn main() !void {
    runMain() catch |err| {
        switch (err) {
            error.InvalidArguments => {},
            else => {
                var buf: [1024]u8 = undefined;
                var w = std.fs.File.stderr().writer(&buf);
                w.interface.print("zmuxd: {s}\n", .{@errorName(err)}) catch {};
                w.interface.flush() catch {};
            },
        }
        std.process.exit(1);
    };
}

fn runMain() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var idle_timeout_seconds = default_idle_timeout_seconds;
    var explicit_socket_path: ?[]const u8 = null;

    var i: usize = 1;
    var show_version = false;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--socket")) {
            i += 1;
            if (i >= argv.len) return fail("missing value for --socket", .{});
            explicit_socket_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--idle-seconds")) {
            i += 1;
            if (i >= argv.len) return fail("missing value for --idle-seconds", .{});
            idle_timeout_seconds = std.fmt.parseInt(i64, argv[i], 10) catch |err| {
                return fail("invalid idle timeout value: {s}", .{@errorName(err)});
            };
        } else if (std.mem.eql(u8, argv[i], "--version") or std.mem.eql(u8, argv[i], "-V")) {
            show_version = true;
        } else if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) {
            try printUsage();
            return;
        } else {
            return fail("unknown flag: {s}", .{argv[i]});
        }
    }

    if (show_version) {
        try printVersion();
        return;
    }

    const path = if (explicit_socket_path) |value|
        try allocator.dupe(u8, value)
    else
        try socketPath(allocator);
    defer allocator.free(path);

    detachFromControllingTerminal();
    resetSigchldDisposition();
    installShutdownHandlers();

    var start_lock: ?StartLock = try acquireStartLock(allocator, path);
    defer if (start_lock) |*lock| lock.release();

    // If a server came up while we waited for the lock, this daemon instance
    // has nothing to do. Exiting successfully mirrors tmux's start-server
    // race behavior without unlinking another server's live socket.
    if (socketPathExists(path) and waitForSocketAcceptsConnection(path, startup_probe_timeout_ms)) return;

    var server = try server_mod.Server.init(allocator, path, idle_timeout_seconds);
    defer server.deinit();
    if (start_lock) |*lock| {
        lock.release();
        start_lock = null;
    }

    const pid_file_path = pidPath(allocator, path) catch null;
    defer if (pid_file_path) |pid_path| allocator.free(pid_path);
    var pid_file_written = false;
    if (pid_file_path) |pid_path| {
        if (writePidFile(allocator, pid_path)) {
            pid_file_written = true;
        } else |err| {
            _ = @errorName(err);
            // The pid file is advisory; failing after the socket is bound
            // would leave a healthy daemon unavailable and a stale socket.
        }
    }
    defer if (pid_file_written) {
        if (pid_file_path) |pid_path| deletePidFile(pid_path);
    };

    server.shutdown_probe = shutdownRequested;
    try server.run();
}

pub fn socketPath(allocator: std.mem.Allocator) ![]u8 {
    return socketPathFromEnv(
        allocator,
        std.posix.getenv("ZMUX_SOCKET"),
        std.posix.getenv("SMITHERS_SESSION_SOCKET"),
        std.posix.getenv("XDG_RUNTIME_DIR"),
        std.posix.getenv("HOME"),
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

    const fallback_dir = try std.fmt.allocPrint(allocator, "/tmp/zmux-{d}", .{std.posix.geteuid()});
    defer allocator.free(fallback_dir);
    return std.fs.path.join(allocator, &.{ fallback_dir, "sessions.sock" });
}

fn pidPath(allocator: std.mem.Allocator, active_socket_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.pid", .{active_socket_path});
}

fn writePidFile(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, std.c.getpid() });
    defer allocator.free(tmp_path);
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var file = try std.fs.createFileAbsolute(tmp_path, .{
        .truncate = true,
        .exclusive = true,
        .mode = 0o600,
    });
    var file_open = true;
    defer if (file_open) file.close();

    const text = try std.fmt.allocPrint(allocator, "{}\n", .{std.c.getpid()});
    defer allocator.free(text);
    try file.writeAll(text);
    try file.sync();
    file.close();
    file_open = false;
    try std.fs.renameAbsolute(tmp_path, path);
}

fn deletePidFile(path: []const u8) void {
    std.fs.deleteFileAbsolute(path) catch {};
}

fn acquireStartLock(allocator: std.mem.Allocator, socket_path: []const u8) !StartLock {
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{socket_path});
    errdefer allocator.free(lock_path);

    try ensureParent(lock_path);
    const file = try std.fs.createFileAbsolute(lock_path, .{
        .truncate = false,
        .mode = 0o600,
        .lock = .exclusive,
    });
    errdefer file.close();

    return .{
        .file = file,
        .path = lock_path,
        .allocator = allocator,
    };
}

fn ensureParent(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
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
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return .retry;
    defer std.posix.close(fd);

    const address = std.net.Address.initUnix(socket_path) catch return .dead;
    std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
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

fn waitForSocketAcceptsConnection(socket_path: []const u8, timeout_ms: i64) bool {
    const deadline_ms = std.time.milliTimestamp() + timeout_ms;
    while (true) {
        switch (probeSocketConnection(socket_path)) {
            .live => return true,
            // Bail immediately on a definitive dead socket so main() can
            // proceed to Server.init (which unlinks the stale file) instead of
            // burning the whole startup budget on doomed retries.
            .dead => return false,
            .retry => {},
        }
        if (std.time.milliTimestamp() >= deadline_ms) return false;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn socketPathExists(socket_path: []const u8) bool {
    std.fs.accessAbsolute(socket_path, .{}) catch return false;
    return true;
}

fn printUsage() !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try stdout.interface.writeAll(
        \\Usage: zmuxd [--socket PATH] [--idle-seconds SECONDS]
        \\       smithers-session-daemon [--socket PATH] [--idle-seconds SECONDS]
        \\
    );
    try stdout.interface.flush();
}

fn printVersion() !void {
    var buf: [64]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    try out.interface.print("zmuxd {s}\n", .{protocol.version});
    try out.interface.flush();
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("zmuxd: " ++ fmt ++ "\n", args) catch {};
    w.interface.print("Try 'zmuxd --help' for usage.\n", .{}) catch {};
    w.interface.flush() catch {};
    return error.InvalidArguments;
}

fn shutdownRequested() bool {
    return shutdown_requested.load(.seq_cst);
}

fn shutdownSignalHandler(_: c_int) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

fn detachFromControllingTerminal() void {
    if (builtin.os.tag == .windows) return;
    _ = std.c.setsid();
}

fn resetSigchldDisposition() void {
    var act: std.posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = null };
    act.mask = std.mem.zeroes(std.posix.sigset_t);
    act.flags = 0;
    std.posix.sigaction(std.c.SIG.CHLD, &act, null);
}

fn installShutdownHandlers() void {
    var act: std.posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&act), 0);
    act.handler = .{ .handler = shutdownSignalHandler };
    act.mask = std.mem.zeroes(std.posix.sigset_t);
    act.flags = 0;
    std.posix.sigaction(std.c.SIG.TERM, &act, null);
    std.posix.sigaction(std.c.SIG.INT, &act, null);

    var ignore_hup: std.posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&ignore_hup), 0);
    ignore_hup.handler = .{ .handler = std.posix.SIG.IGN };
    ignore_hup.mask = std.mem.zeroes(std.posix.sigset_t);
    ignore_hup.flags = 0;
    std.posix.sigaction(std.c.SIG.HUP, &ignore_hup, null);
}

test "socket path falls back to HOME/.smithers when HOME is provided" {
    const path = try socketPathFromEnv(std.testing.allocator, null, null, null, "/tmp/daemon-home-sim");
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "smithers-sessions.sock") or
        std.mem.endsWith(u8, path, ".smithers/sessions.sock"));
}

test "socket path falls back to uid-scoped /tmp directory when HOME is unavailable" {
    const path = try socketPathFromEnv(std.testing.allocator, null, null, null, null);
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zmux-{d}/sessions.sock", .{std.posix.geteuid()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "stale unix socket is rejected immediately during startup probe" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const seed = try std.testing.allocator.alloc(u8, 16);
    defer allocator.free(seed);
    std.crypto.random.bytes(seed);
    const nonce = std.mem.readInt(u64, seed[0..8], .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(allocator, "{s}/zmx-stale-{x:0>16}.sock", .{ root, nonce });
    defer allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const address = try std.net.Address.initUnix(path);
    const listener = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    std.posix.bind(listener, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try std.posix.listen(listener, 1);
    std.posix.close(listener);

    const start = std.time.milliTimestamp();
    try std.testing.expect(!waitForSocketAcceptsConnection(path, startup_probe_timeout_ms));
    const elapsed_ms = std.time.milliTimestamp() - start;
    try std.testing.expect(elapsed_ms < 500);
}

test "socketAcceptsConnection detects a listening unix socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/zmx-live-{x:0>16}.sock", .{ root, nonce });
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    const address = try std.net.Address.initUnix(path);
    const listener = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(listener);
    std.posix.bind(listener, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try std.posix.listen(listener, 1);

    try std.testing.expect(socketAcceptsConnection(path));
}

test "pid path is scoped to the socket path" {
    const path = try pidPath(std.testing.allocator, "/tmp/zmux-test.sock");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/zmux-test.sock.pid", path);
}

test "pid file write is atomic and cleanly removable" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var seed: [8]u8 = undefined;
    std.crypto.random.bytes(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/zmx-pid-{x:0>16}.sock.pid", .{ root, nonce });
    defer std.testing.allocator.free(path);
    defer std.fs.deleteFileAbsolute(path) catch {};

    try writePidFile(std.testing.allocator, path);
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const text = try file.readToEndAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(text);

    const expected = try std.fmt.allocPrint(std.testing.allocator, "{}\n", .{std.c.getpid()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, text);

    deletePidFile(path);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(path, .{}));
}

test "resetSigchldDisposition restores default SIGCHLD handling" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var old_action: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.c.SIG.CHLD, null, &old_action);
    defer std.posix.sigaction(std.c.SIG.CHLD, &old_action, null);

    var ignored: std.posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&ignored), 0);
    ignored.handler = .{ .handler = std.posix.SIG.IGN };
    ignored.mask = std.mem.zeroes(std.posix.sigset_t);
    ignored.flags = 0;
    std.posix.sigaction(std.c.SIG.CHLD, &ignored, null);

    resetSigchldDisposition();

    var current: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.c.SIG.CHLD, null, &current);
    try std.testing.expect(current.handler.handler == null);
}

test {
    std.testing.refAllDecls(@import("buffer.zig"));
    std.testing.refAllDecls(@import("foreground.zig"));
    std.testing.refAllDecls(@import("native.zig"));
    std.testing.refAllDecls(@import("protocol.zig"));
    std.testing.refAllDecls(@import("pty.zig"));
    std.testing.refAllDecls(@import("server.zig"));
}
