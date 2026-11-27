//! Daemon socket resolution, authenticated connect, and detached daemon
//! spawn for `--spawn-daemon`.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const assert = std.debug.assert;
const server = @import("../server.zig");
const socket_path = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
const wire = @import("wire.zig");

const write_timeout_ms = wire.write_timeout_ms;
const spawn_timeout_ms = wire.spawn_timeout_ms;
const fail = cli.fail;
const diagnostic = cli.diagnostic;
const escaped = cli.escaped;
const moveAboveStdio = terminal.moveAboveStdio;
const waitWritableOrReadable = terminal.waitWritableOrReadable;

const test_io = std.testing.io;

/// Look up an environment variable.
pub fn getEnv(name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const key = buf[0..name.len :0];
    return if (c.getenv(key.ptr)) |value| std.mem.span(value) else null;
}

/// Resolve and validate the daemon socket path.
pub fn resolveSocketPath(allocator: std.mem.Allocator, io: std.Io, override: ?[]const u8) ![]u8 {
    const path = socket_path.resolveUnvalidated(allocator, override, getEnv) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fail(io, "{s}", .{@errorName(err)}),
    };
    errdefer allocator.free(path);
    socket_path.validate(path) catch |err| switch (err) {
        error.SocketPathTooLong => return failSocketPathTooLong(io, path),
        else => return fail(io, "{s}", .{@errorName(err)}),
    };
    assert(path.len <= sys.max_unix_path_len);
    return path;
}

fn failSocketPathTooLong(io: std.Io, path: []const u8) error{InvalidArguments} {
    return fail(io, "socket path too long ({d} > {d})", .{ path.len, sys.max_unix_path_len });
}

/// Connect to the daemon, optionally spawning one first.
pub fn connectWithRetry(allocator: std.mem.Allocator, io: std.Io, path: []const u8, spawn_daemon: bool) !posix.fd_t {
    const first_deadline = sys.monotonicMs() + write_timeout_ms;
    if (tryConnect(io, path, first_deadline)) |fd| return fd else |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => {
            if (!spawn_daemon)
                return diagnostic(io, "no daemon at {f}; start zmuxd or pass --spawn-daemon", .{escaped(path)});
        },
        else => return err,
    }

    // A refused connect can also mean an existing regular file or symlink.
    if (sys.statAt(sys.cwd_fd, path, false)) |st| {
        if (!st.isSocket() or st.uid != sys.geteuid())
            return diagnostic(io, "refusing to replace socket path {f}", .{escaped(path)});
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const deadline = sys.monotonicMs() + spawn_timeout_ms;
    spawnDaemonDetached(allocator, io, path, deadline) catch |err| {
        if (err == error.ReportedFailure) return err;
        const args = .{ escaped(path), @errorName(err), escaped(path) };
        return diagnostic(io, "could not start daemon at {f}: {s}; see {f}.log", args);
    };
    while (sys.monotonicMs() < deadline) {
        if (tryConnect(io, path, deadline)) |fd| return fd else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => try io.sleep(.fromMilliseconds(50), .awake),
            error.ReportedFailure => return err,
            else => return err,
        }
    }
    const args = .{ escaped(path), escaped(path) };
    return diagnostic(io, "daemon at {f} did not become ready within 4s; see {f}.log", args);
}

fn tryConnect(io: std.Io, path: []const u8, deadline: i64) !posix.fd_t {
    const connected = sys.connectUnixDeadline(path, deadline) catch |err| switch (err) {
        error.NameTooLong => return failSocketPathTooLong(io, path),
        error.Timeout, error.ConnectionTimedOut => {
            return diagnostic(io, "timed out connecting to daemon at {f}", .{escaped(path)});
        },
        else => return err,
    };
    // Keep a socket out of stdin/stdout/stderr when the caller closed one.
    const fd = try moveAboveStdio(connected);
    errdefer sys.close(fd);
    assert(fd >= 3);
    sys.tuneUnixSocketBuffers(fd);
    const uid = sys.peerEuid(fd) catch
        return diagnostic(io, "could not authenticate daemon at {f}; refusing", .{escaped(path)});
    if (uid != sys.geteuid())
        return diagnostic(io, "socket at {f} is owned by uid {d}; refusing", .{ escaped(path), uid });

    if (socket_path.isDefaultManaged(path, getEnv)) {
        const parent = std.fs.path.dirname(path).?;
        // An existing connection must never cause us to create a directory.
        const dir = sys.openDirNoFollow(parent) catch |err|
            return diagnostic(io, "cannot verify socket directory {f}: {s}", .{ escaped(parent), @errorName(err) });
        defer sys.close(dir);
        const st = try sys.fstat(dir);
        if (!st.isDir() or st.uid != sys.geteuid() or st.permissions() & 0o077 != 0)
            return diagnostic(
                io,
                "socket directory {f} must be private and owned by the current user",
                .{escaped(parent)},
            );
    }
    try sys.setNonBlocking(fd);
    return fd;
}

/// Open and vet the directory that will hold a spawned socket.
pub fn openSpawnSocketParent(path: []const u8, getenv: socket_path.GetEnv) !posix.fd_t {
    if (socket_path.isDefaultManaged(path, getenv)) return server.openSocketParent(path, getenv);

    const parent = std.fs.path.dirname(path) orelse return error.NoSocketDirectory;
    // Follow the custom directory (including macOS /tmp), then check the
    // pinned descriptor before creating anything in it.
    const fd = try sys.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    errdefer sys.close(fd);
    const stat = try sys.fstat(fd);
    const self_owned = stat.uid == sys.geteuid();
    const trusted_sticky = (stat.uid == 0 or self_owned) and stat.mode & 0o1000 != 0;
    if (!trusted_sticky and !(self_owned and stat.mode & 0o022 == 0))
        return error.InsecureSocketDirectory;
    return fd;
}

fn spawnDaemonDetached(allocator: std.mem.Allocator, io: std.Io, path: []const u8, deadline: i64) !void {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse ".";
    const daemon_path = try findDaemonSibling(allocator, io, self_dir, std.fs.path.basename(self_path));
    defer allocator.free(daemon_path);
    const daemon_z = try allocator.dupeSentinel(u8, daemon_path, 0);
    defer allocator.free(daemon_z);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    const argv = [_:null]?[*:0]const u8{ daemon_z.ptr, "--socket", path_z.ptr };
    const envp = sys.currentEnviron();

    const dir_fd = try moveAboveStdio(try openSpawnSocketParent(path, getEnv));
    defer sys.close(dir_fd);
    assert(dir_fd >= 3);
    const log_name = try std.fmt.allocPrint(allocator, "{s}.log", .{std.fs.path.basename(path)});
    defer allocator.free(log_name);
    const log_flags: posix.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true };
    const log_fd = try moveAboveStdio(try sys.openOwnedRegularAt(dir_fd, log_name, log_flags, 0o600));
    defer sys.close(log_fd);
    assert(log_fd >= 3);
    try sys.fchmod(log_fd, 0o600);
    const devnull = try moveAboveStdio(try sys.openZ("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    defer sys.close(devnull);

    const status_pipe = try sys.pipe();
    const status_read = moveAboveStdio(status_pipe[0]) catch |err| {
        sys.close(status_pipe[1]);
        return err;
    };
    defer sys.close(status_read);
    const status_write = try moveAboveStdio(status_pipe[1]);
    assert(status_read >= 3 and status_write >= 3);

    const child = sys.fork() catch |err| {
        sys.close(status_write);
        return err;
    };
    if (child == 0) {
        sys.close(status_read);
        if (c.setsid() < 0) childSpawnFailed(status_write, "setsid");
        const daemon_child = sys.fork() catch childSpawnFailed(status_write, "fork");
        if (daemon_child != 0) c._exit(0);

        sys.dup2(devnull, 0) catch childSpawnFailed(status_write, "stdin");
        sys.dup2(devnull, 1) catch childSpawnFailed(status_write, "stdout");
        sys.dup2(log_fd, 2) catch childSpawnFailed(status_write, "stderr");
        // Reserve fd 3 for the exec receipt, and close all other inherited fds.
        if (status_write != 3) sys.dup2(status_write, 3) catch childSpawnFailed(status_write, "dup2");
        sys.setCloseOnExec(3) catch childSpawnFailed(3, "cloexec");
        sys.closeFrom(4);
        sys.resetChildSignals();
        _ = c.execve(daemon_z.ptr, &argv, envp);
        childSpawnFailed(3, "execve");
    }
    sys.close(status_write);

    var status: c_int = undefined;
    while (c.waitpid(child, &status, 0) < 0) {
        if (posix.errno(@as(c_int, -1)) != .INTR) return error.WaitFailed;
    }
    try waitWritableOrReadable(status_read, posix.POLL.IN, deadline);
    var buf: [32]u8 = undefined;
    const count = try posix.read(status_read, &buf);
    if (count != 0) return diagnostic(io, "daemon startup failed during {f}", .{escaped(buf[0..count])});
    if (status != 0) return error.DaemonSpawnFailed;
}

fn childSpawnFailed(fd: posix.fd_t, stage: []const u8) noreturn {
    _ = c.write(fd, stage.ptr, stage.len);
    c._exit(127);
}

/// The daemon binary next to this executable.
pub fn findDaemonSibling(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, self_name: []const u8) ![]u8 {
    const zmux_order = [_][]const u8{ "zmuxd", "smithers-session-daemon" };
    const smithers_order = [_][]const u8{ "smithers-session-daemon", "zmuxd" };
    const candidates: []const []const u8 = if (std.mem.eql(u8, self_name, "zmux-connect"))
        &zmux_order
    else
        &smithers_order;

    for (candidates) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    return std.fs.path.join(allocator, &.{ dir, candidates[0] });
}

test "spawn socket parent accepts /tmp and tightens an owned legacy managed directory" {
    const tmp = try openSpawnSocketParent("/tmp/zmux-test.sock", getEnv);
    sys.close(tmp);

    const home = struct {
        var path: []const u8 = undefined;
        fn env(name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "HOME")) path else null;
        }
    };
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const alloc = std.testing.allocator;
    const relative = try std.fs.path.join(alloc, &.{ ".zig-cache/tmp", &temp.sub_path });
    defer alloc.free(relative);
    const test_home = try std.Io.Dir.cwd().realPathFileAlloc(test_io, relative, alloc);
    defer alloc.free(test_home);
    home.path = test_home;
    const parent = try std.fs.path.join(alloc, &.{ test_home, ".smithers" });
    defer alloc.free(parent);
    const path = try std.fs.path.join(alloc, &.{ parent, "sessions.sock" });
    defer alloc.free(path);
    try sys.mkdir(parent, 0o755);
    const legacy = try sys.openDirNoFollow(parent);
    defer sys.close(legacy);
    try sys.fchmod(legacy, 0o755);

    const managed = try openSpawnSocketParent(path, home.env);
    defer sys.close(managed);
    try std.testing.expectEqual(@as(u32, 0o700), (try sys.fstat(managed)).permissions());
    try sys.fchmod(legacy, 0o775);
    try std.testing.expectError(error.InsecurePermissions, openSpawnSocketParent(path, home.env));
}
