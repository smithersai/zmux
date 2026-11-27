const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = @import("../log.zig");
const socket_path_mod = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const posix = std.posix;

const server_mod = @import("../server.zig");
const limits_mod = @import("limits.zig");
const startup_mod = @import("startup.zig");
const test_support_mod = @import("test_support.zig");
const Server = server_mod.Server;
const chmodAbsolute = test_support_mod.chmodAbsolute;
const countDirEntries = test_support_mod.countDirEntries;
const dirMode = test_support_mod.dirMode;
const noEnv = test_support_mod.noEnv;
const openSocketParent = startup_mod.openSocketParent;
const socketPathStat = test_support_mod.socketPathStat;
const stale_probe_timeout_ms = limits_mod.stale_probe_timeout_ms;
const tempPath = test_support_mod.tempPath;
const test_io = test_support_mod.test_io;

fn nameZ(buf: *[posix.PATH_MAX]u8, name: []const u8) error{NameTooLong}![*:0]const u8 {
    if (name.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0].ptr;
}

/// `mkdirat(2)` relative to `dir_fd`, mapping errno to Zig errors.
pub fn mkdirAt(dir_fd: posix.fd_t, name: []const u8, mode: std.c.mode_t) !void {
    assert(name.len > 0);
    var buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = try nameZ(&buf, name);
    switch (posix.errno(std.c.mkdirat(dir_fd, name_z, mode))) {
        .SUCCESS => {},
        .EXIST => return error.PathAlreadyExists,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOSPC => return error.NoSpaceLeft,
        else => return error.Unexpected,
    }
}

/// Best-effort `rmdir` of `name` relative to `dir_fd`.
pub fn rmdirAt(dir_fd: posix.fd_t, name: []const u8) void {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = nameZ(&buf, name) catch return;
    _ = std.c.unlinkat(dir_fd, name_z, std.c.AT.REMOVEDIR);
}

/// `linkat(2)` without following: fails with `error.AddressInUse` when
/// `new_name` exists, so publication never replaces a live entry.
pub fn linkAt(old_dir_fd: posix.fd_t, old_name: []const u8, new_dir_fd: posix.fd_t, new_name: []const u8) !void {
    assert(old_name.len > 0);
    assert(new_name.len > 0);
    var old_buf: [posix.PATH_MAX]u8 = undefined;
    var new_buf: [posix.PATH_MAX]u8 = undefined;
    const old_z = try nameZ(&old_buf, old_name);
    const new_z = try nameZ(&new_buf, new_name);
    while (true) switch (posix.errno(std.c.linkat(old_dir_fd, old_z, new_dir_fd, new_z, 0))) {
        .SUCCESS => return,
        .INTR => continue,
        .EXIST => return error.AddressInUse,
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM, .ROFS => return error.AccessDenied,
        .NOTDIR => return error.NotDir,
        .NOSPC => return error.NoSpaceLeft,
        else => return error.Unexpected,
    };
}

/// Remove `name` only while it still names the inode `expected`. The check
/// and the unlink are two calls; callers that need exclusion against another
/// publisher hold the daemon start lock.
pub fn unlinkIfSame(dir_fd: posix.fd_t, name: []const u8, expected: sys.Stat) void {
    const current = sys.statAt(dir_fd, name, false) catch return;
    if (!current.sameFile(expected)) return;
    sys.unlinkAt(dir_fd, name) catch |err| {
        log.debug("socket_unlink_failed", .{ .err = err });
    };
}

/// Duplicate `fd` with close-on-exec set, retrying on `EINTR`.
pub fn dupCloexec(fd: posix.fd_t) !posix.fd_t {
    while (true) {
        const rc = std.c.fcntl(fd, posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                assert(rc >= 0);
                return @intCast(rc);
            },
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .BADF => return error.NotOpenForReading,
            else => return error.Unexpected,
        }
    }
}

/// A directory with the sticky bit set lets its owner rename or remove any
/// entry, so a shared sticky parent is trusted only when root or this user
/// owns it.
pub fn stickyParentTrusted(stat: sys.Stat, euid: sys.uid_t) bool {
    return stat.uid == 0 or stat.uid == euid;
}

/// `openat(dir_fd, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`.
pub fn openDirAt(dir_fd: posix.fd_t, name: []const u8) !posix.fd_t {
    var buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = try nameZ(&buf, name);
    const flags: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };
    while (true) {
        const rc = std.c.openat(dir_fd, name_z, flags, @as(c_uint, 0));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                assert(rc >= 0);
                return @intCast(rc);
            },
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR, .LOOP => return error.NotDir,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => return error.Unexpected,
        }
    }
}

/// Open the private socket directory `parent`, repairing loose permissions on one we manage.
pub fn openManagedDir(parent: []const u8) !posix.fd_t {
    return sys.ensurePrivateDir(parent) catch |err| switch (err) {
        error.InsecurePermissions => repairManagedDir(parent),
        else => {
            log.err("socket_dir_refused", .{ .dir = parent, .err = err });
            return err;
        },
    };
}

/// A managed directory that already exists with group/other bits. Releases
/// before this one created it 0755, which nobody else can write to, so that
/// case is tightened in place. Group- or other-writable means another user
/// could already have planted entries: refuse.
fn repairManagedDir(parent: []const u8) !posix.fd_t {
    const dir_fd = try sys.openDirNoFollow(parent);
    errdefer sys.close(dir_fd);
    const stat = try sys.fstat(dir_fd);
    if (!stat.isDir()) return error.NotDirectory;
    if (stat.uid != sys.geteuid()) return error.ForeignOwner;
    if ((stat.mode & 0o022) != 0) {
        log.err("socket_dir_refused", .{ .dir = parent, .mode = stat.permissions(), .err = error.InsecurePermissions });
        return error.InsecurePermissions;
    }
    try sys.fchmod(dir_fd, 0o700);
    log.warn("socket_dir_permissions_tightened", .{ .dir = parent, .previous_mode = stat.permissions() });
    return dir_fd;
}

/// Decide what to do with an existing entry at the socket name. Only a stale
/// socket owned by this user is removed; everything else is preserved and
/// reported.
pub fn clearStaleSocket(dir_fd: posix.fd_t, socket_name: []const u8, socket_path: []const u8) !void {
    const existing = sys.statAt(dir_fd, socket_name, false) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // A regular file, directory, symlink, or FIFO here is someone's data.
    if (!existing.isSocket()) return error.SocketPathNotSocket;
    if (existing.uid != sys.geteuid()) return error.AccessDenied;

    const probe_deadline = sys.monotonicMs() + stale_probe_timeout_ms;
    const probe = sys.connectUnixDeadline(socket_path, probe_deadline) catch |err| switch (err) {
        error.ConnectionRefused => {
            // No listener: stale. Remove it only if it is still the entry
            // that was inspected.
            const current = sys.statAt(dir_fd, socket_name, false) catch |stat_err| switch (stat_err) {
                error.FileNotFound => return,
                else => return stat_err,
            };
            if (!current.sameFile(existing)) return error.ProbeInconclusive;
            sys.unlinkAt(dir_fd, socket_name) catch |unlink_err| switch (unlink_err) {
                error.FileNotFound => {},
                else => return unlink_err,
            };
            return;
        },
        error.FileNotFound => return,
        // Timeout, fd exhaustion, or anything else: keep the entry.
        else => return error.ProbeInconclusive,
    };
    defer sys.close(probe);

    const peer = sys.peerEuid(probe) catch return error.ProbeInconclusive;
    if (peer != sys.geteuid()) {
        log.err("socket_owned_by_other_user", .{
            .socket_path = socket_path,
            .peer_euid = peer,
            .euid = sys.geteuid(),
        });
        return error.AccessDenied;
    }
    return error.AddressInUse;
}

const ManagedHome = struct {
    threadlocal var home: ?[]const u8 = null;

    pub fn get(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "HOME")) return home;
        return null;
    }
};

test "H03: a sticky parent is trusted only when root or this user owns it" {
    const euid: sys.uid_t = 1000;
    const sticky = 0o41777;
    try std.testing.expect(stickyParentTrusted(.{ .dev = 0, .ino = 0, .mode = sticky, .uid = 0 }, euid));
    try std.testing.expect(stickyParentTrusted(.{ .dev = 0, .ino = 0, .mode = sticky, .uid = euid }, euid));
    try std.testing.expect(!stickyParentTrusted(.{ .dev = 0, .ino = 0, .mode = sticky, .uid = 1234 }, euid));
}

test "self-created socket parent is validated as private 0700" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-created-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    // The parent does not exist yet, so zmux owns its creation: Server.init
    // must bring it up as a private 0700 directory owned by the current uid.
    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    server.deinit();
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
}

test "existing socket parent permissions are left unchanged" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-existing-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    // A pre-existing self-owned parent of an explicit socket path is accepted
    // as-is and left at its original mode (here 0755), never chmod'd.
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);
    try chmodAbsolute(allocator, parent, 0o755);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    server.deinit();
    try std.testing.expectEqual(@as(u32, 0o755), try dirMode(parent));
}

test "a user-selected parent that others can write to is refused unless sticky" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-writable-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, parent, .default_dir);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    for ([_]std.c.mode_t{ 0o777, 0o775, 0o757 }) |mode| {
        try chmodAbsolute(allocator, parent, mode);
        try std.testing.expectError(error.InsecureSocketDirectory, Server.init(allocator, test_io, socket_path, 0));
        try std.testing.expectEqual(@as(usize, 0), try countDirEntries(parent));
    }

    // The sticky bit (as on /tmp) makes a world-writable parent acceptable.
    try chmodAbsolute(allocator, parent, 0o1777);
    var server = try Server.init(allocator, test_io, socket_path, 0);
    server.deinit();
    try std.testing.expectEqual(@as(u32, 0o1777), try dirMode(parent));
}

test "a daemon-managed parent must be private: created 0700, 0755 tightened, writable refused" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const home = try tempPath(allocator, "zmx-home");
    defer allocator.free(home);
    defer std.Io.Dir.cwd().deleteTree(test_io, home) catch {};
    try std.Io.Dir.createDirAbsolute(test_io, home, .default_dir);
    ManagedHome.home = home;
    defer ManagedHome.home = null;

    const managed = try std.fs.path.join(allocator, &.{ home, ".smithers" });
    defer allocator.free(managed);
    const socket_path = try std.fs.path.join(allocator, &.{ managed, "sessions.sock" });
    defer allocator.free(socket_path);
    try std.testing.expect(socket_path_mod.isDefaultManaged(socket_path, ManagedHome.get));

    // Missing: created private even under a permissive umask.
    {
        const original_umask = std.c.umask(0);
        defer _ = std.c.umask(original_umask);
        const dir_fd = try openSocketParent(socket_path, ManagedHome.get);
        sys.close(dir_fd);
        try std.testing.expectEqual(@as(u32, 0o700), try dirMode(managed));
    }

    // 0755 from an older release: nobody else could write, so it is tightened.
    try chmodAbsolute(allocator, managed, 0o755);
    {
        const dir_fd = try openSocketParent(socket_path, ManagedHome.get);
        sys.close(dir_fd);
        try std.testing.expectEqual(@as(u32, 0o700), try dirMode(managed));
    }

    // Group- or other-writable: refused and left exactly as found.
    for ([_]std.c.mode_t{ 0o777, 0o770, 0o707, 0o1777 }) |mode| {
        try chmodAbsolute(allocator, managed, mode);
        try std.testing.expectError(error.InsecurePermissions, openSocketParent(socket_path, ManagedHome.get));
        try std.testing.expectEqual(@as(u32, mode), try dirMode(managed));
    }

    // A symlink standing in for the managed directory is refused.
    try chmodAbsolute(allocator, managed, 0o700);
    const moved = try std.fs.path.join(allocator, &.{ home, "real-dir" });
    defer allocator.free(moved);
    try sys.rename(managed, moved);
    const moved_z = try allocator.dupeSentinel(u8, moved, 0);
    defer allocator.free(moved_z);
    const managed_z = try allocator.dupeSentinel(u8, managed, 0);
    defer allocator.free(managed_z);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(moved_z.ptr, managed_z.ptr));
    if (openSocketParent(socket_path, ManagedHome.get)) |dir_fd| {
        sys.close(dir_fd);
        return error.SymlinkedManagedDirAccepted;
    } else |_| {}
}

test "self-created socket parent is 0700 under umask 0022" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-created-umask022");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    const original_umask = std.c.umask(0o022);
    defer _ = std.c.umask(original_umask);

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    var server = Server.init(allocator, test_io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit();

    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
    const stat = try socketPathStat(socket_path);
    try std.testing.expect(stat.isSocket());
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions());
}

test "new socket parent is private" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const parent = try tempPath(allocator, "zmx-new-parent");
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(test_io, parent) catch {};

    const socket_path = try std.fs.path.join(allocator, &.{ parent, "sessions.sock" });
    defer allocator.free(socket_path);

    const dir_fd = try openSocketParent(socket_path, noEnv);
    defer sys.close(dir_fd);
    try std.testing.expectEqual(@as(u32, 0o700), try dirMode(parent));
    // The descriptor is the directory itself, not a path that can be swapped.
    try std.testing.expect((try sys.fstat(dir_fd)).sameFile(try sys.statAt(sys.cwd_fd, parent, false)));
}
