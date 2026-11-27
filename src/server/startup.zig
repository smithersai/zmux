const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const mux = @import("../mux.zig");
const socket_path_mod = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const server_mod = @import("../server.zig");
const socket_bind_mod = @import("socket_bind.zig");
const socket_dir_mod = @import("socket_dir.zig");
const socket_io_mod = @import("socket_io.zig");
const test_support_mod = @import("test_support.zig");
const Server = server_mod.Server;
const bindPrivateSocket = socket_bind_mod.bindPrivateSocket;
const bindRawUnixListener = test_support_mod.bindRawUnixListener;
const clearStaleSocket = socket_dir_mod.clearStaleSocket;
const countMatchingEntries = test_support_mod.countMatchingEntries;
const max_client_connections = server_mod.max_client_connections;
const max_socket_path_len = server_mod.max_socket_path_len;
const monotonicSeconds = socket_io_mod.monotonicSeconds;
const openManagedDir = socket_dir_mod.openManagedDir;
const paddedSocketPath = test_support_mod.paddedSocketPath;
const requireUnixSocketBind = test_support_mod.requireUnixSocketBind;
const socketPathStat = test_support_mod.socketPathStat;
const stickyParentTrusted = socket_dir_mod.stickyParentTrusted;
const tempPath = test_support_mod.tempPath;
const test_io = test_support_mod.test_io;
const unlinkIfSame = socket_dir_mod.unlinkIfSame;

/// Reject a socket path `bind(2)` can never accept: empty, NUL, relative, too long, or a directory.
pub fn validateSocketPath(socket_path: []const u8) !void {
    if (socket_path.len == 0) return error.EmptySocketPath;
    if (std.mem.indexOfScalar(u8, socket_path, 0) != null) return error.SocketPathContainsNul;
    if (!std.fs.path.isAbsolute(socket_path)) return error.SocketPathNotAbsolute;
    if (socket_path.len > max_socket_path_len) return error.SocketPathTooLong;
    if (socket_path[socket_path.len - 1] == '/') return error.SocketPathNotSocket;
    assert(socket_path.len > 0);
    assert(socket_path.len <= max_socket_path_len);
}

/// Takes ownership of `dir_fd` on success only.
pub fn initOwnedDir(
    allocator: Allocator,
    io: std.Io,
    dir_fd: posix.fd_t,
    socket_path: []const u8,
    idle_timeout_seconds: i64,
) !Server {
    assert(dir_fd >= 0);
    const socket_name = std.fs.path.basename(socket_path);
    assert(socket_name.len > 0);

    try clearStaleSocket(dir_fd, socket_name, socket_path);

    const listener = try sys.unixStreamSocket();
    errdefer sys.close(listener);

    // Bind owner-only (0600) without touching the process-wide umask,
    // start listening before the socket gets its public name, and never
    // replace an entry that appeared since the check above; see
    // bindPrivateSocket.
    const socket_stat = try bindPrivateSocket(io, listener, dir_fd, socket_name, socket_path);
    // Only the inode this server bound is ever removed.
    errdefer unlinkIfSame(dir_fd, socket_name, socket_stat);

    // A non-blocking listener keeps poll-then-accept from stalling the
    // loop when a client resets before accept.
    try sys.setNonBlocking(listener);
    const owned_socket_path = try allocator.dupe(u8, socket_path);
    assert(listener >= 0 and listener != dir_fd);

    log.info("server_listening", .{
        .socket_path = socket_path,
        .backlog = max_client_connections,
        .idle_timeout_seconds = idle_timeout_seconds,
    });

    return .{
        .allocator = allocator,
        .io = io,
        .socket_path = owned_socket_path,
        .socket_stat = socket_stat,
        .socket_dir_fd = dir_fd,
        .published = true,
        .listener_fd = listener,
        .manager = mux.Manager.init(allocator, io, null),
        .last_activity_seconds = std.atomic.Value(i64).init(monotonicSeconds(io)),
        .idle_timeout_seconds = idle_timeout_seconds,
    };
}

/// Open and validate the directory that holds `socket_path`, creating it
/// private (0700) when it is missing. Returns a pinned descriptor; the caller
/// closes it. Every later lock, PID, and socket operation goes through this
/// descriptor, so swapping the directory name afterwards changes nothing.
///
///   * A daemon-managed default (`$HOME/.smithers`, `/tmp/zmux-<euid>`) must
///     be a self-owned 0700 directory and never a symlink. A self-owned
///     directory left at 0755 by an older release is tightened to 0700; one
///     that is group- or other-writable, or owned by someone else, is refused.
///   * A missing parent is created by zmux and is therefore private too.
///   * An existing user-selected parent must be self-owned with no group or
///     other write permission, or have the sticky bit (such as `/tmp`) and
///     be owned by root or this user. Another user's sticky directory is
///     refused: its owner can rename entries inside it.
pub fn openSocketParent(socket_path: []const u8, getenv: socket_path_mod.GetEnv) !posix.fd_t {
    const parent = std.fs.path.dirname(socket_path) orelse return error.SocketPathNotAbsolute;

    if (socket_path_mod.isDefaultManaged(socket_path, getenv)) return openManagedDir(parent);

    _ = sys.statAt(sys.cwd_fd, parent, true) catch |err| switch (err) {
        error.FileNotFound => return openManagedDir(parent),
        else => return err,
    };

    // A user-selected parent may itself be reached through a symlink (macOS
    // `/tmp`), so the final component is followed; the checks below apply to
    // the directory actually opened.
    const dir_fd = try sys.open(parent, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    errdefer sys.close(dir_fd);
    const stat = try sys.fstat(dir_fd);
    if (!stat.isDir()) return error.NotDir;
    const sticky = (stat.mode & 0o1000) != 0 and stickyParentTrusted(stat, sys.geteuid());
    const owner_only_write = stat.uid == sys.geteuid() and (stat.mode & 0o022) == 0;
    if (!sticky and !owner_only_write) {
        log.err("socket_dir_insecure", .{
            .dir = parent,
            .mode = stat.permissions(),
            .owner_uid = stat.uid,
            .euid = sys.geteuid(),
        });
        return error.InsecureSocketDirectory;
    }
    assert(sticky or owner_only_write);
    return dir_fd;
}

test "server init rejects paths bind can never accept, with no side effects" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SocketPathNotAbsolute, Server.init(allocator, test_io, "zmx-relative.sock", 0));
    try std.testing.expectError(error.SocketPathNotAbsolute, Server.init(allocator, test_io, "./zmx-relative.sock", 0));
    try std.testing.expectError(error.SocketPathNotAbsolute, Server.init(allocator, test_io, "sub/zmx-relative.sock", 0));
    try std.testing.expectError(error.EmptySocketPath, Server.init(allocator, test_io, "", 0));
    try std.testing.expectError(error.SocketPathContainsNul, Server.init(allocator, test_io, "/tmp/zmx\x00.sock", 0));
    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, "/tmp/zmx-dir-like/", 0));

    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "zmx-relative.sock", false));
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "sub", false));
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, "/tmp/zmx-dir-like", false));
}

test "server init never unlinks a regular file at the socket path" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const path = try tempPath(allocator, "zmx-notes");
    defer allocator.free(path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, path) catch {};

    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, path, .{});
        defer file.close(test_io);
        try file.writeStreamingAll(test_io, "keep these notes\n");
    }

    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, path, 0));

    const text = try std.Io.Dir.cwd().readFileAlloc(test_io, path, allocator, .limited(64));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("keep these notes\n", text);
    try std.testing.expectEqual(@as(u32, posix.S.IFREG), (try socketPathStat(path)).kind());
}

test "server init never unlinks a directory or follows a symlink at the socket path" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const dir_path = try tempPath(allocator, "zmx-is-dir");
    defer allocator.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(test_io, dir_path) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, dir_path, .default_dir);
    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, dir_path, 0));
    try std.testing.expect((try socketPathStat(dir_path)).isDir());

    // A symlink whose target is a stale socket: the link is not a socket, so
    // neither the link nor its target is touched.
    const target = try tempPath(allocator, "zmx-link-target");
    defer allocator.free(target);
    defer std.Io.Dir.deleteFileAbsolute(test_io, target) catch {};
    const stale = bindRawUnixListener(target) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    sys.close(stale);

    const link = try tempPath(allocator, "zmx-link");
    defer allocator.free(link);
    defer std.Io.Dir.deleteFileAbsolute(test_io, link) catch {};
    const target_z = try allocator.dupeSentinel(u8, target, 0);
    defer allocator.free(target_z);
    const link_z = try allocator.dupeSentinel(u8, link, 0);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target_z.ptr, link_z.ptr));

    try std.testing.expectError(error.SocketPathNotSocket, Server.init(allocator, test_io, link, 0));
    try std.testing.expectEqual(@as(u32, posix.S.IFLNK), (try socketPathStat(link)).kind());
    try std.testing.expect((try socketPathStat(target)).isSocket());
}

test "a second server cannot displace a live one" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const socket_path = try tempPath(allocator, "zmx-live-server");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();
    const before = try socketPathStat(socket_path);

    try std.testing.expectError(error.AddressInUse, Server.init(allocator, test_io, socket_path, 0));

    const after = try socketPathStat(socket_path);
    try std.testing.expect(before.sameFile(after));
    try std.testing.expectEqual(@as(usize, 1), try countMatchingEntries(std.fs.path.dirname(socket_path).?, std.fs.path.basename(socket_path)));
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "server init rejects a socket path longer than sun_path before touching the filesystem" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-too-long");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    const socket_path = try paddedSocketPath(allocator, parent, max_socket_path_len + 1);
    defer allocator.free(socket_path);

    try std.testing.expectError(error.SocketPathTooLong, Server.init(allocator, test_io, socket_path, 0));
    // Rejected up front: not even the parent directory was created.
    try std.testing.expectError(error.FileNotFound, socketPathStat(parent));
}

test "server init replaces a stale socket with a private one" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-stale-replace");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};

    const stale = bindRawUnixListener(socket_path) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    sys.close(stale);
    // Confirm the stale socket file is genuinely unreachable before replacement.
    try std.testing.expectError(error.ConnectionRefused, sys.connectUnix(socket_path));

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();

    const stat = try socketPathStat(socket_path);
    try std.testing.expect(stat.isSocket());
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    // Linux filesystems can immediately recycle the freed inode number after
    // unlink(), so verify replacement by connecting to the newly bound server.
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}
