const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const sys = @import("../sys.zig");
const posix = std.posix;

const server_mod = @import("../server.zig");
const limits_mod = @import("limits.zig");
const socket_dir_mod = @import("socket_dir.zig");
const test_support_mod = @import("test_support.zig");
const Server = server_mod.Server;
const chmodAbsolute = test_support_mod.chmodAbsolute;
const countDirEntries = test_support_mod.countDirEntries;
const linkAt = socket_dir_mod.linkAt;
const max_client_connections = server_mod.max_client_connections;
const max_socket_path_len = server_mod.max_socket_path_len;
const mkdirAt = socket_dir_mod.mkdirAt;
const openDirAt = socket_dir_mod.openDirAt;
const paddedSocketPath = test_support_mod.paddedSocketPath;
const requireUnixSocketBind = test_support_mod.requireUnixSocketBind;
const rmdirAt = socket_dir_mod.rmdirAt;
const socketPathStat = test_support_mod.socketPathStat;
const staged_socket_name = limits_mod.staged_socket_name;
const staging_dir_attempts = limits_mod.staging_dir_attempts;
const staging_dir_prefix = limits_mod.staging_dir_prefix;
const staging_dir_random_hex_max = limits_mod.staging_dir_random_hex_max;
const staging_dir_random_hex_min = limits_mod.staging_dir_random_hex_min;
const tempPath = test_support_mod.tempPath;
const test_io = test_support_mod.test_io;
const unlinkIfSame = socket_dir_mod.unlinkIfSame;

/// Bind `listener` at `socket_path` so the socket file is owner-only (0600)
/// from the instant it becomes reachable, without calling `umask(2)`, and
/// start listening before it gets its public name.
///
/// `umask` is process-wide: narrowing it around `bind` races every other
/// thread that creates a file, which is unacceptable for an embedded server.
/// POSIX has no `bindat`/mode argument for `bind`, so instead:
///
///   1. `mkdirat` a staging directory inside the pinned parent. Its mode is
///      at most 0700 (umask only clears bits) and `mkdirat` fails on any
///      existing name, so nobody else can enter it or have planted it.
///   2. `bind` the socket inside it. Whatever mode the umask yields, the file
///      is unreachable to other users behind the 0700 directory.
///   3. Check ownership, then `fchmodat` the socket to 0600 and verify it.
///   4. `listen`, then `linkat` it to the socket name and drop the staged
///      name. `linkat` is atomic, keeps the bound inode, and fails when the
///      name exists, so the public name only ever refers to a listening 0600
///      socket and a publisher that arrived after `clearStaleSocket` is never
///      replaced (`error.AddressInUse`).
///
/// Returns the identity of the bound inode, taken before publication, so a
/// later cleanup can never remove someone else's socket.
///
/// Every step except `bind` itself is relative to the pinned directory
/// descriptors. The staging path is longer than some valid socket paths. When
/// it cannot fit in `sun_path`, the socket is bound in place only if that is
/// provably private (see bindSocketInPlace); otherwise the bind is refused
/// rather than exposed.
pub fn bindPrivateSocket(
    io: std.Io,
    listener: posix.fd_t,
    dir_fd: posix.fd_t,
    socket_name: []const u8,
    socket_path: []const u8,
) !sys.Stat {
    assert(socket_name.len > 0);
    assert(socket_path.len >= socket_name.len);
    // Linux derives the socket file mode from the socket inode's mode, so this
    // makes bind create the file 0600 outright. macOS rejects fchmod on
    // sockets; staging covers both.
    const mode_preset = builtin.os.tag == .linux and blk: {
        sys.fchmod(listener, 0o600) catch break :blk false;
        break :blk true;
    };

    const dir_prefix = socket_path[0 .. socket_path.len - socket_name.len];

    // dir_prefix + staging dir name + "/" + staged_socket_name must fit.
    const fixed_len = dir_prefix.len + staging_dir_prefix.len + 1 + staged_socket_name.len;
    if (fixed_len + staging_dir_random_hex_min > max_socket_path_len) {
        return bindSocketInPlace(listener, dir_fd, socket_name, socket_path, mode_preset);
    }
    const hex_len = @min(staging_dir_random_hex_max, max_socket_path_len - fixed_len);
    assert(hex_len >= staging_dir_random_hex_min);
    assert(fixed_len + hex_len <= max_socket_path_len);

    var name_buf: [staging_dir_prefix.len + staging_dir_random_hex_max]u8 = undefined;
    const staging_name = try makeStagingDir(io, dir_fd, &name_buf, hex_len);
    defer rmdirAt(dir_fd, staging_name);

    // Hold the directory by fd and validate that fd, so later checks cannot be
    // redirected by someone swapping the name in a writable parent.
    const staging_fd = try openDirAt(dir_fd, staging_name);
    defer sys.close(staging_fd);
    try verifyStagingDir(staging_fd);

    var staged_buf: [max_socket_path_len]u8 = undefined;
    const staged_path = try std.fmt.bufPrint(
        &staged_buf,
        "{s}{s}/{s}",
        .{ dir_prefix, staging_name, staged_socket_name },
    );
    assert(staged_path.len <= max_socket_path_len);

    const address = try sys.UnixAddress.init(staged_path);
    try sys.bind(listener, &address);
    // The staged name always goes: after a successful link the public name
    // keeps the inode.
    defer sys.unlinkAt(staging_fd, staged_socket_name) catch |err| {
        log.debug("staged_socket_unlink_failed", .{ .err = err });
    };

    const socket_stat = try secureStagedSocket(staging_fd, staged_path);

    // Size the accept backlog to the connection cap so a burst of clients
    // (e.g. a leader spawning many attachers at once) is queued rather than
    // refused while the accept loop drains it. The kernel silently clamps to
    // somaxconn.
    try sys.listen(listener, @intCast(max_client_connections));
    // No-replace publish; the deferred unlink then drops the staged name.
    try linkAt(staging_fd, staged_socket_name, dir_fd, socket_name);
    return socket_stat;
}

/// Create a fresh 0700-or-narrower staging directory under `dir_fd` with a
/// random `hex_len`-character suffix, retrying name collisions. Returns the
/// directory name, which lives in `name_buf`.
fn makeStagingDir(
    io: std.Io,
    dir_fd: posix.fd_t,
    name_buf: *[staging_dir_prefix.len + staging_dir_random_hex_max]u8,
    hex_len: usize,
) ![]const u8 {
    assert(hex_len >= staging_dir_random_hex_min);
    assert(hex_len <= staging_dir_random_hex_max);
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var random: [staging_dir_random_hex_max / 2]u8 = undefined;
        io.random(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const staging_name = try std.fmt.bufPrint(name_buf, "{s}{s}", .{ staging_dir_prefix, hex[0..hex_len] });
        assert(staging_name.len == staging_dir_prefix.len + hex_len);
        mkdirAt(dir_fd, staging_name, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {
                if (attempt + 1 >= staging_dir_attempts) return err;
                continue;
            },
            else => return err,
        };
        // A restrictive umask (0777) leaves the new directory 000, which its
        // unprivileged owner cannot open. Restore 0700 by name first: in a
        // trusted parent (owner-only, or sticky and owned by root or us)
        // nobody else can replace the entry just created. The caller's fd
        // checks still verify type, owner, and mode.
        sys.fchmodat(dir_fd, staging_name, 0o700) catch |err| {
            log.debug("staging_dir_chmod_failed", .{ .err = err });
        };
        return staging_name;
    }
}

/// Check that the staging directory held by `staging_fd` is a directory we
/// own, then force and verify mode 0700.
fn verifyStagingDir(staging_fd: posix.fd_t) !void {
    // Ownership first: never chmod something that is not ours.
    const created = try sys.fstat(staging_fd);
    if (!created.isDir()) return error.PermissionDenied;
    if (created.uid != sys.geteuid()) return error.PermissionDenied;
    // A umask that clears owner bits would make the directory unusable.
    try sys.fchmod(staging_fd, 0o700);
    const dir_stat = try sys.fstat(staging_fd);
    if (dir_stat.permissions() != 0o700) return error.PermissionDenied;
}

/// Verify the freshly bound staged socket is ours and is the file at
/// `staged_path`, then chmod it to 0600. Returns its identity.
fn secureStagedSocket(staging_fd: posix.fd_t, staged_path: []const u8) !sys.Stat {
    assert(staged_path.len > 0);
    const bound = try sys.statAt(staging_fd, staged_socket_name, false);
    if (!bound.isSocket()) return error.PermissionDenied;
    if (bound.uid != sys.geteuid()) return error.PermissionDenied;
    // The path we bound must be the file inside the directory we validated.
    const path_stat = try sys.statAt(sys.cwd_fd, staged_path, false);
    if (!path_stat.sameFile(bound)) return error.PermissionDenied;
    try sys.fchmodat(staging_fd, staged_socket_name, 0o600);
    const socket_stat = try sys.statAt(staging_fd, staged_socket_name, false);
    if (!socket_stat.sameFile(bound)) return error.PermissionDenied;
    if (socket_stat.permissions() != 0o600) return error.PermissionDenied;
    return socket_stat;
}

/// Fallback for socket paths too close to the `sun_path` limit to stage.
/// Binding in place is race-free only when no other user can reach the file
/// between `bind` and `chmod`:
///   * Linux, when the pre-bind `fchmod` succeeded: the file is created with
///     at most 0600.
///   * Any OS, when the parent directory is self-owned with no group/other
///     access: nobody else can traverse to the socket.
/// Anything else would briefly expose a umask-mode socket, so it is refused.
fn bindSocketInPlace(
    listener: posix.fd_t,
    dir_fd: posix.fd_t,
    socket_name: []const u8,
    socket_path: []const u8,
    mode_preset: bool,
) !sys.Stat {
    assert(socket_name.len > 0);
    assert(socket_path.len >= socket_name.len);
    if (!mode_preset) {
        const parent_stat = try sys.fstat(dir_fd);
        const private = parent_stat.isDir() and
            parent_stat.uid == sys.geteuid() and
            (parent_stat.mode & 0o077) == 0;
        if (!private) return error.SocketStagingPathTooLong;
    }

    // `bind` itself fails with `AddressInUse` on an existing name, so this
    // path never replaces an entry either.
    const address = try sys.UnixAddress.init(socket_path);
    try sys.bind(listener, &address);

    var socket_stat = try sys.statAt(dir_fd, socket_name, false);
    // Only the inode just bound is removed on failure.
    const bound = socket_stat;
    errdefer unlinkIfSame(dir_fd, socket_name, bound);
    if (!socket_stat.isSocket() or socket_stat.uid != sys.geteuid()) return error.PermissionDenied;
    // With the preset the mode is already at most 0600; this only widens a
    // umask-narrowed socket back to 0600 so its owner can connect.
    if (socket_stat.permissions() != 0o600) {
        try sys.fchmodat(dir_fd, socket_name, 0o600);
        socket_stat = try sys.statAt(dir_fd, socket_name, false);
    }
    if (socket_stat.permissions() != 0o600) return error.PermissionDenied;
    if (!socket_stat.sameFile(bound)) return error.PermissionDenied;
    try sys.listen(listener, @intCast(max_client_connections));
    return socket_stat;
}

test "H02: publication never replaces a socket that appeared after the stale check" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const socket_path = try tempPath(allocator, "zmx-publish-race");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    // The first publisher wins; the second already passed `clearStaleSocket`
    // (simulated by calling the publication step directly).
    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();
    const before = try socketPathStat(socket_path);

    const listener = try sys.unixStreamSocket();
    defer sys.close(listener);
    const parent = std.fs.path.dirname(socket_path).?;
    const dir_fd = try sys.openDirNoFollow(parent);
    defer sys.close(dir_fd);
    try std.testing.expectError(
        error.AddressInUse,
        bindPrivateSocket(test_io, listener, dir_fd, std.fs.path.basename(socket_path), socket_path),
    );

    const after = try socketPathStat(socket_path);
    try std.testing.expect(before.sameFile(after));
    const client = try sys.connectUnix(socket_path);
    sys.close(client);

    // Cleanup removes only the inode this server bound.
    server.socket_stat.ino +%= 1;
    server.unpublish();
    try std.testing.expect((try socketPathStat(socket_path)).sameFile(before));
    server.socket_stat.ino -%= 1;
    server.published = true;
}

test "M13: startup and restart succeed under umask 0777" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    if (sys.geteuid() == 0) return error.SkipZigTest; // root ignores mode bits
    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-umask777");
    defer allocator.free(parent);
    sys.close(try sys.ensurePrivateDir(parent));
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    const socket_path = try std.fs.path.join(allocator, &.{ parent, "s.sock" });
    defer allocator.free(socket_path);

    const original_umask = std.c.umask(0o777);
    defer _ = std.c.umask(original_umask);

    for (0..2) |_| {
        var server = try Server.init(allocator, test_io, socket_path, 0);
        const stat = try socketPathStat(socket_path);
        try std.testing.expect(stat.isSocket());
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
        server.deinit();
    }
}

test "server socket is 0600 without mutating the process umask" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-umask");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);
    // A shared (0755) parent forces the staged bind rather than the
    // private-parent shortcut.
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);
    try requireUnixSocketBind(socket_path);

    // The most permissive umask: a plain bind would create a 0777 socket, so a
    // 0600 result proves the mode does not come from the umask. umask(2) can
    // only be read by setting it, so read it back the same way afterwards.
    const permissive_umask: std.c.mode_t = 0;
    const original_umask = std.c.umask(permissive_umask);
    defer _ = std.c.umask(original_umask);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    defer server.deinit();

    const umask_after_init = std.c.umask(permissive_umask);
    try std.testing.expectEqual(permissive_umask, umask_after_init);

    const stat = try socketPathStat(socket_path);
    try std.testing.expect(stat.isSocket());
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    try std.testing.expectEqual(sys.geteuid(), stat.uid);

    // The staging directory is gone: the socket is the parent's only entry.
    try std.testing.expectEqual(@as(usize, 1), try countDirEntries(parent));

    // The published socket is already listening: a client can connect.
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "socket path at the sun_path limit binds in place under a private parent" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-limit-private");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    // Parent does not exist, so Server.init creates it 0700. The path is
    // exactly the limit, which leaves no room for a staging directory.
    const socket_path = try paddedSocketPath(allocator, parent, max_socket_path_len);
    defer allocator.free(socket_path);

    const original_umask = std.c.umask(0);
    defer _ = std.c.umask(original_umask);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit();

    try std.testing.expectEqual(@as(std.c.mode_t, 0), std.c.umask(0));
    const stat = try socketPathStat(socket_path);
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    const client = try sys.connectUnix(socket_path);
    defer sys.close(client);
}

test "socket path at the sun_path limit is never exposed under a shared parent" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-limit-shared");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try paddedSocketPath(allocator, parent, max_socket_path_len);
    defer allocator.free(socket_path);

    const original_umask = std.c.umask(0);
    defer _ = std.c.umask(original_umask);

    if (Server.init(allocator, test_io, socket_path, 0)) |created| {
        // Linux creates the file 0600 at bind time via the pre-bind fchmod.
        var server = created;
        defer server.deinit();
        const stat = try socketPathStat(socket_path);
        try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
    } else |err| switch (err) {
        // Elsewhere there is no race-free way to bind here, so it is refused
        // and nothing is left behind.
        error.SocketStagingPathTooLong => {
            try std.testing.expect(builtin.os.tag != .linux);
            try std.testing.expectEqual(@as(usize, 0), try countDirEntries(parent));
        },
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    }
    try std.testing.expectEqual(@as(std.c.mode_t, 0), std.c.umask(0));
}
