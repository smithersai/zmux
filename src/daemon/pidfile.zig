//! The advisory pid file beside the socket, written atomically and removed
//! only while it is still the file this daemon created. Also owns the temp
//! directory helpers the daemon's inline tests share.
const std = @import("std");
const builtin = @import("builtin");

const log = @import("../log.zig");
const sys = @import("../sys.zig");

const posix = std.posix;
const assert = std.debug.assert;
const test_io = std.testing.io;

fn nameZ(buf: *[posix.PATH_MAX]u8, name: []const u8) error{NameTooLong}![*:0]const u8 {
    if (name.len >= buf.len) return error.NameTooLong;
    assert(name.len < buf.len);
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
pub fn writePidFile(dir_fd: sys.fd_t, pid_name: []const u8) !sys.Stat {
    var tmp_buf: [posix.PATH_MAX]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp.{d}", .{ pid_name, sys.getpid() });

    // An entry already at the temporary name is not ours: leave it in place.
    if (sys.statAt(dir_fd, tmp_name, false)) |_| {
        return error.PathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const create_flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true };
    const fd = try sys.openOwnedRegularAt(dir_fd, tmp_name, create_flags, 0o600);
    assert(fd >= 0);
    var renamed = false;
    defer if (!renamed) sys.unlinkAt(dir_fd, tmp_name) catch |err| {
        log.debug("pid_tmp_unlink_failed", .{ .err = err });
    };
    defer sys.close(fd);

    // Readable by its owner whatever the umask was.
    try sys.fchmod(fd, 0o600);
    var text_buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "{d}\n", .{sys.getpid()});
    assert(text.len >= 2 and text[text.len - 1] == '\n');
    try sys.writeAll(fd, text);
    if (std.c.fsync(fd) != 0) return error.InputOutput;
    const stat = try sys.fstat(fd);

    try renameAt(dir_fd, tmp_name, pid_name);
    renamed = true;
    return stat;
}

/// Remove the pid file only if it is still the file `writePidFile` created.
/// A successor daemon's pid file has another inode and is left alone.
pub fn removePidFile(dir_fd: sys.fd_t, pid_name: []const u8, written: sys.Stat) void {
    assert(pid_name.len > 0);
    const current = sys.statAt(dir_fd, pid_name, false) catch return;
    if (!current.sameFile(written)) return;
    sys.unlinkAt(dir_fd, pid_name) catch |err| log.debug("pid_file_unlink_failed", .{ .err = err });
}

/// `writePidFile`, downgraded to a warning: the pid file is advisory.
pub fn publishPidFile(dir_fd: sys.fd_t, pid_name: []const u8, path: []const u8) ?sys.Stat {
    return writePidFile(dir_fd, pid_name) catch |err| {
        // Failing after the socket is bound would leave a healthy daemon
        // unavailable and a stale socket. Keep serving, but say so: tools
        // that read the pid file will not find this daemon.
        log.warn("pid_file_write_failed", .{ .err = err, .socket_path = path });
        return null;
    };
}

/// True on the platforms whose POSIX file and signal behavior the tests exercise.
pub const posix_ok = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// A fresh, unique path under the system temp directory (test helper).
pub fn tempPath(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
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
pub const TempDir = struct {
    path: []u8,
    fd: sys.fd_t,

    pub fn init(prefix: []const u8) !TempDir {
        const path = try tempPath(std.testing.allocator, prefix);
        errdefer std.testing.allocator.free(path);
        try sys.mkdir(path, 0o700);
        const fd = try sys.openDirNoFollow(path);
        return .{ .path = path, .fd = fd };
    }

    pub fn deinit(self: *TempDir) void {
        sys.close(self.fd);
        std.Io.Dir.cwd().deleteTree(test_io, self.path) catch |err| {
            log.debug("test_tempdir_cleanup_failed", .{ .err = err });
        };
        std.testing.allocator.free(self.path);
    }

    pub fn child(self: *const TempDir, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ self.path, name }, 0);
    }

    pub fn entryCount(self: *const TempDir) !usize {
        var dir = try std.Io.Dir.openDirAbsolute(test_io, self.path, .{ .iterate = true });
        defer dir.close(test_io);
        var iterator = dir.iterate();
        var count: usize = 0;
        while (try iterator.next(test_io)) |_| count += 1;
        return count;
    }
};

/// `chmod(2)` on `path` (test helper).
pub fn chmodPath(path: []const u8, mode: std.c.mode_t) !void {
    const path_z = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, mode) != 0) return error.ChmodFailed;
}

/// The permission bits of `path`, not following a final symlink (test helper).
pub fn pathMode(path: []const u8) !u32 {
    return (try sys.statAt(sys.cwd_fd, path, false)).permissions();
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
