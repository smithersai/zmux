//! Filesystem metadata that `std.Io.File.Stat` does not carry (owner,
//! device), and mutation on raw paths and directory descriptors. The socket
//! binding protocol needs fd-relative operations (`fchmodat`, `unlinkat`) and
//! `fchmod` on a socket, none of which `std.Io.Dir` exposes.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../sys.zig");
const fd = @import("fd.zig");
const log = @import("../log.zig");

const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const fd_t = sys.fd_t;
const uid_t = sys.uid_t;
const mode_t = sys.mode_t;
const UnexpectedError = sys.UnexpectedError;
const unexpected = fd.unexpected;

/// The file metadata zmux checks: device, inode, mode and owner.
pub const Stat = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    uid: uid_t,

    pub fn kind(self: Stat) u32 {
        return self.mode & posix.S.IFMT;
    }

    pub fn isDir(self: Stat) bool {
        return self.kind() == posix.S.IFDIR;
    }

    pub fn isSocket(self: Stat) bool {
        return self.kind() == posix.S.IFSOCK;
    }

    /// Permission bits including setuid/setgid/sticky.
    pub fn permissions(self: Stat) u32 {
        return self.mode & 0o7777;
    }

    pub fn sameFile(self: Stat, other: Stat) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

/// Errors from `statAt` and `fstat`.
pub const StatError = error{
    AccessDenied,
    FileNotFound,
    NameTooLong,
    NotDir,
    SymLinkLoop,
    SystemResources,
    StatFieldsUnavailable,
} || UnexpectedError;

/// `AT_FDCWD`: resolve relative paths against the current directory.
pub const cwd_fd: fd_t = c.AT.FDCWD;

/// `fstatat(2)`. `follow_symlinks = false` maps to `AT_SYMLINK_NOFOLLOW`.
pub fn statAt(dir_fd: fd_t, path: []const u8, follow_symlinks: bool) (StatError)!Stat {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    return statAtZ(dir_fd, path_z, if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW);
}

/// `fstat(2)`.
pub fn fstat(file: fd_t) StatError!Stat {
    if (builtin.os.tag == .linux) return statAtZ(file, "", std.os.linux.AT.EMPTY_PATH);
    var st: c.Stat = undefined;
    switch (posix.errno(c.fstat(file, &st))) {
        .SUCCESS => return fromCStat(&st),
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

/// Set once `statx(2)` reports `ENOSYS`/`EPERM` (old kernels, seccomp
/// sandboxes); later calls go straight to `newfstatat(2)`.
var statx_unavailable: std.atomic.Value(bool) = .init(false);

/// The kernel's `struct stat` for `newfstatat(2)`; `std.c.Stat` is not
/// available on Linux in this Zig version.
const KernelStat = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        times: [6]i64,
        __unused: [3]i64,
    },
    .aarch64, .riscv64 => extern struct {
        dev: u64,
        ino: u64,
        mode: u32,
        nlink: u32,
        uid: u32,
        gid: u32,
        rdev: u64,
        __pad1: u64,
        size: i64,
        blksize: i32,
        __pad2: i32,
        blocks: i64,
        times: [6]i64,
        __unused: [2]u32,
    },
    else => void,
};

/// True when Linux statx failures can fall back to `newfstatat(2)`.
const have_stat_fallback = builtin.os.tag == .linux and KernelStat != void and
    @hasField(std.os.linux.SYS, "newfstatat");

fn statErr(err: posix.E) StatError {
    assert(err != .SUCCESS);
    return switch (err) {
        .ACCES => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NAMETOOLONG => error.NameTooLong,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NOMEM => error.SystemResources,
        else => unexpected(err),
    };
}

fn statAtFallback(dir_fd: fd_t, path: [*:0]const u8, flags: u32) StatError!Stat {
    if (!have_stat_fallback) return error.StatFieldsUnavailable;
    const linux = std.os.linux;
    var st: KernelStat = undefined;
    const rc = linux.syscall4(
        .newfstatat,
        @as(usize, @bitCast(@as(isize, dir_fd))),
        @intFromPtr(path),
        @intFromPtr(&st),
        flags,
    );
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |err| return statErr(err),
    }
    // Decode the kernel's `new_encode_dev` layout into the same
    // (major << 32) | minor form the statx path produces.
    const major: u64 = (st.dev >> 8) & 0xfff;
    const minor: u64 = (st.dev & 0xff) | ((st.dev >> 12) & 0xfff00);
    assert(major <= 0xfff);
    assert(minor <= 0xfffff);
    return .{
        .dev = (major << 32) | minor,
        .ino = st.ino,
        .mode = st.mode,
        .uid = st.uid,
    };
}

fn statxAt(dir_fd: fd_t, path: [*:0]const u8, flags: u32) StatError!Stat {
    const linux = std.os.linux;
    if (sys.force_stat_fallback or statx_unavailable.load(.monotonic)) {
        return statAtFallback(dir_fd, path, flags);
    }
    var stx = std.mem.zeroes(linux.Statx);
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true, .INO = true };
    const rc = linux.statx(dir_fd, path, flags, mask, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {
            if (!stx.mask.TYPE or !stx.mask.MODE or !stx.mask.UID or !stx.mask.INO) {
                return error.StatFieldsUnavailable;
            }
            return .{
                .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor,
                .ino = stx.ino,
                .mode = stx.mode,
                .uid = stx.uid,
            };
        },
        .NOSYS, .PERM => {
            if (!have_stat_fallback) return error.StatFieldsUnavailable;
            statx_unavailable.store(true, .monotonic);
            return statAtFallback(dir_fd, path, flags);
        },
        else => |err| return statErr(err),
    }
}

fn statAtZ(dir_fd: fd_t, path: [*:0]const u8, flags: u32) StatError!Stat {
    if (builtin.os.tag == .linux) return statxAt(dir_fd, path, flags);
    var st: c.Stat = undefined;
    switch (posix.errno(c.fstatat(dir_fd, path, &st, flags))) {
        .SUCCESS => return fromCStat(&st),
        .ACCES => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .NAMETOOLONG => return error.NameTooLong,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

fn fromCStat(st: *const c.Stat) Stat {
    return .{
        .dev = @bitCast(@as(i64, st.dev)),
        .ino = @intCast(st.ino),
        .mode = @intCast(st.mode),
        .uid = st.uid,
    };
}

/// Copy `path` into `buf` with a NUL terminator.
pub fn toPathZ(buf: *[posix.PATH_MAX]u8, path: []const u8) error{NameTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    assert(path.len < buf.len);
    assert(buf[path.len] == 0);
    return buf[0..path.len :0].ptr;
}

/// Errors from `fchmod` and `fchmodat`.
pub const ChmodError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    NameTooLong,
    SymLinkLoop,
    /// Darwin rejects `fchmod` on sockets.
    OperationNotSupported,
} || UnexpectedError;

fn chmodErr(err: posix.E) ChmodError {
    assert(err != .SUCCESS and err != .INTR);
    return switch (err) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.SymLinkLoop,
        .INVAL, .OPNOTSUPP => error.OperationNotSupported,
        else => unexpected(err),
    };
}

/// `fchmod(2)`, retrying `EINTR`.
pub fn fchmod(file: fd_t, mode: mode_t) ChmodError!void {
    while (true) switch (posix.errno(c.fchmod(file, mode))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return chmodErr(err),
    };
}

/// `fchmodat(2)` relative to `dir_fd`, following symlinks; retries `EINTR`.
pub fn fchmodat(dir_fd: fd_t, path: []const u8, mode: mode_t) ChmodError!void {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    while (true) switch (posix.errno(c.fchmodat(dir_fd, path_z, mode, 0))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return chmodErr(err),
    };
}

/// Errors from `mkdir`.
pub const MkdirError = error{
    AccessDenied,
    PathAlreadyExists,
    FileNotFound,
    NotDir,
    NoSpaceLeft,
    ReadOnlyFileSystem,
    NameTooLong,
    SymLinkLoop,
} || UnexpectedError;

/// `mkdir(2)`. Unlike `std.Io.Dir.createDir`, this fails with
/// `PathAlreadyExists` for any existing name, which the socket staging
/// protocol depends on.
pub fn mkdir(path: []const u8, mode: mode_t) MkdirError!void {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    switch (posix.errno(c.mkdir(path_z, mode))) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .EXIST => return error.PathAlreadyExists,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .NOSPC => return error.NoSpaceLeft,
        .ROFS => return error.ReadOnlyFileSystem,
        .NAMETOOLONG => return error.NameTooLong,
        .LOOP => return error.SymLinkLoop,
        else => |err| return unexpected(err),
    }
}

/// `rmdir(2)`. `EEXIST` is reported as `DirNotEmpty`.
pub fn rmdir(path: []const u8) (error{ NameTooLong, DirNotEmpty, FileNotFound, AccessDenied } || UnexpectedError)!void {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    switch (posix.errno(c.rmdir(path_z))) {
        .SUCCESS => {},
        .NOTEMPTY, .EXIST => return error.DirNotEmpty,
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return unexpected(err),
    }
}

/// `unlinkat(2)` of a non-directory `path` relative to `dir_fd`.
pub fn unlinkAt(
    dir_fd: fd_t,
    path: []const u8,
) (error{ NameTooLong, FileNotFound, AccessDenied } || UnexpectedError)!void {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    switch (posix.errno(c.unlinkat(dir_fd, path_z, 0))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return unexpected(err),
    }
}

/// `rename(2)`: atomically replace `new_path` with `old_path`.
pub fn rename(
    old_path: []const u8,
    new_path: []const u8,
) (error{ NameTooLong, FileNotFound, AccessDenied, NotDir, IsDir } || UnexpectedError)!void {
    var old_buf: [posix.PATH_MAX]u8 = undefined;
    var new_buf: [posix.PATH_MAX]u8 = undefined;
    const old_z = try toPathZ(&old_buf, old_path);
    const new_z = try toPathZ(&new_buf, new_path);
    switch (posix.errno(c.rename(old_z, new_z))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .NOTDIR => return error.NotDir,
        .ISDIR => return error.IsDir,
        else => |err| return unexpected(err),
    }
}

/// Errors from `open`, `openZ` and the open helpers.
pub const OpenError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    SymLinkLoop,
    NameTooLong,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || UnexpectedError;

/// Open `path` with raw `O_*` flags. Used for the staging-directory descriptor
/// (`O_DIRECTORY|O_NOFOLLOW`) and for wiring `/dev/null` and log files into a
/// forked child, where `std.Io` cannot run.
pub fn open(path: []const u8, flags: c.O, mode: mode_t) OpenError!fd_t {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    return openZ(path_z, flags, mode);
}

/// Async-signal-safe `open(2)` on a NUL-terminated path, safe between `fork`
/// and `exec`.
pub fn openZ(path: [*:0]const u8, flags: c.O, mode: mode_t) OpenError!fd_t {
    while (true) {
        const rc = c.open(path, flags, @as(c_uint, mode));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const opened: fd_t = @intCast(rc);
                assert(opened >= 0);
                return opened;
            },
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| return unexpected(err),
        }
    }
}

/// Open a directory read-only, close-on-exec, refusing a symlink in the final
/// component. Uses `O_RDONLY` (never `O_PATH`) so `fchmod(2)` succeeds on the
/// returned descriptor on Linux.
pub fn openDirNoFollow(path: []const u8) OpenError!fd_t {
    return open(path, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0);
}

/// Test helper: a fresh private directory under `/tmp`, removed by `remove`.
pub const TestDir = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    var counter: std.atomic.Value(u32) = .init(0);

    /// Create a fresh 0700 directory under /tmp owned by the test process.
    pub fn create(tag: []const u8) !TestDir {
        var dir: TestDir = .{};
        const created = try std.fmt.bufPrint(&dir.buf, "/tmp/zmux-sys-{s}-{d}-{d}-{d}", .{
            tag, sys.getpid(), fd.monotonicMs(), counter.fetchAdd(1, .seq_cst),
        });
        dir.len = created.len;
        assert(dir.len <= dir.buf.len);
        try mkdir(created, 0o700);
        try fchmodat(cwd_fd, created, 0o700);
        return dir;
    }

    pub fn path(self: *const TestDir) []const u8 {
        return self.buf[0..self.len];
    }

    /// `<dir>/<name>` in `buf`. Test callers pass a buffer sized for the
    /// fixed-length test directory plus their short names.
    pub fn join(self: *const TestDir, buf: []u8, name: []const u8) []const u8 {
        const base = self.path();
        const len = base.len + 1 + name.len;
        assert(len <= buf.len);
        @memcpy(buf[0..base.len], base);
        buf[base.len] = '/';
        @memcpy(buf[base.len + 1 ..][0..name.len], name);
        return buf[0..len];
    }

    pub fn remove(self: *const TestDir, names: []const []const u8) void {
        var buf: [256]u8 = undefined;
        for (names) |name| {
            const child = self.join(&buf, name);
            // Each child is either a file or a directory, so one of these two
            // calls is expected to fail.
            unlinkAt(cwd_fd, child) catch |err| log.debug("test_dir_unlink_failed", .{ .err = err });
            rmdir(child) catch |err| log.debug("test_dir_rmdir_failed", .{ .err = err });
        }
        rmdir(self.path()) catch |err| log.debug("test_dir_rmdir_failed", .{ .err = err });
    }
};

/// Test helper: create a symlink at `link_path` pointing at `target`.
pub fn testSymlink(target: []const u8, link_path: []const u8) !void {
    var target_buf: [posix.PATH_MAX]u8 = undefined;
    var link_buf: [posix.PATH_MAX]u8 = undefined;
    const target_z = try toPathZ(&target_buf, target);
    const link_z = try toPathZ(&link_buf, link_path);
    if (c.symlink(target_z, link_z) != 0) return error.SymlinkFailed;
}

test "stat reports directory kind, owner and permissions" {
    // Assert against a directory this test created, not the cwd, which may be
    // owned by another user in CI checkouts.
    const dir = try TestDir.create("stat");
    defer dir.remove(&.{});
    const st = try statAt(cwd_fd, dir.path(), true);
    try std.testing.expect(st.isDir());
    try std.testing.expectEqual(sys.geteuid(), st.uid);
    try std.testing.expectEqual(@as(u32, 0o700), st.permissions());
}

test "stat fallback matches statx for file, dir, socket and symlink" {
    if (!have_stat_fallback) return error.SkipZigTest;
    const socket = @import("socket.zig");
    const close = fd.close;

    const dir = try TestDir.create("statfb");
    defer dir.remove(&.{ "file", "sub", "sock", "link" });
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;

    const file_fd = try open(dir.join(&buf, "file"), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
    defer close(file_fd);
    try mkdir(dir.join(&buf, "sub"), 0o700);
    const sock = try socket.unixStreamSocket();
    defer close(sock);
    const address = try socket.UnixAddress.init(dir.join(&buf, "sock"));
    try socket.bind(sock, &address);
    try testSymlink(dir.join(&buf, "file"), dir.join(&buf2, "link"));

    defer sys.force_stat_fallback = false;
    for ([_][]const u8{ "file", "sub", "sock", "link" }) |name| {
        const target = dir.join(&buf, name);
        for ([_]bool{ true, false }) |follow| {
            sys.force_stat_fallback = false;
            const via_statx = try statAt(cwd_fd, target, follow);
            sys.force_stat_fallback = true;
            const via_fallback = try statAt(cwd_fd, target, follow);
            try std.testing.expectEqual(via_statx, via_fallback);
        }
    }
    // The symlink itself is reported only when not following.
    sys.force_stat_fallback = true;
    const link_stat = try statAt(cwd_fd, dir.join(&buf, "link"), false);
    try std.testing.expectEqual(@as(u32, posix.S.IFLNK), link_stat.kind());

    // fstat goes through the same fallback (AT_EMPTY_PATH).
    const fd_fallback = try fstat(file_fd);
    sys.force_stat_fallback = false;
    try std.testing.expectEqual(try fstat(file_fd), fd_fallback);
}
