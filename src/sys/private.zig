//! Private directories, owned regular files, and deadline-bounded `flock`
//! (review round-1 contract §1.7).

const std = @import("std");
const sys = @import("../sys.zig");
const fd = @import("fd.zig");
const fs = @import("fs.zig");
const log = @import("../log.zig");

const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const fd_t = sys.fd_t;
const mode_t = sys.mode_t;
const close = fd.close;
const cwd_fd = fs.cwd_fd;

/// Errors from `ensurePrivateDir`.
pub const PrivateDirError = error{
    NotDirectory,
    ForeignOwner,
    InsecurePermissions,
    SymlinkParent,
    NameTooLong,
    AccessDenied,
    FileNotFound,
    Unexpected,
};

const MkdirOutcome = union(enum) { created, exists, failed: posix.E };

/// Best-effort `chmod(0700)` for a directory this call just created under a
/// restrictive umask (e.g. `0777`, where `mkdir` yields mode `0000` and
/// `open(O_RDONLY)` returns `EACCES`). Verifies `lstat` shows a directory
/// owned by euid before touching permissions; `ensurePrivateDir` still
/// validates ownership and final mode on the pinned `O_NOFOLLOW` fd.
fn chmodCreatedDir(path_z: [*:0]const u8, path: []const u8, mode: mode_t) void {
    assert(path.len > 0);
    const st = fs.statAt(cwd_fd, path, false) catch return;
    if (!st.isDir() or st.uid != sys.geteuid() or st.permissions() == mode) return;
    if (c.fchmodat(cwd_fd, path_z, mode, c.AT.SYMLINK_NOFOLLOW) == 0) return;
    switch (posix.errno(@as(c_int, -1))) {
        // Linux kernels/libcs reject AT_SYMLINK_NOFOLLOW on fchmodat.
        .OPNOTSUPP, .INVAL, .NOSYS => _ = c.fchmodat(cwd_fd, path_z, mode, 0),
        else => {},
    }
}

/// `mkdir(path, 0700)`. When this call created the directory and its mode is
/// missing owner rwx (e.g. under `umask 0777`), repair to `0700` via fd-pinned
/// `fchmod` when openable, falling back to `chmodCreatedDir` only when
/// `openDirNoFollow` fails with `AccessDenied`.
fn mkdirPrivateZ(path_z: [*:0]const u8, path: []const u8, repair_mode: bool) MkdirOutcome {
    assert(path.len > 0);
    switch (posix.errno(c.mkdir(path_z, 0o700))) {
        .SUCCESS => {
            if (repair_mode) {
                if (fs.openDirNoFollow(path)) |dir_fd| {
                    defer close(dir_fd);
                    if (fs.fstat(dir_fd)) |st| {
                        if (st.isDir() and st.uid == sys.geteuid() and st.permissions() != 0o700) {
                            fs.fchmod(dir_fd, 0o700) catch |err| {
                                log.debug("private_dir_fchmod_failed", .{ .err = err });
                            };
                        }
                    } else |_| {}
                } else |err| switch (err) {
                    error.AccessDenied => chmodCreatedDir(path_z, path, 0o700),
                    else => {},
                }
            }
            return .created;
        },
        .EXIST => return .exists,
        else => |err| return .{ .failed = err },
    }
}

fn privateDirErr(err: posix.E) PrivateDirError {
    assert(err != .SUCCESS);
    return switch (err) {
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDirectory,
        .LOOP => error.SymlinkParent,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

/// Open the directory `ensurePrivateDir` just made or found, repairing a
/// mode-0000 directory this call created under `umask 0777`.
fn openPrivateDir(path_z: [*:0]const u8, trimmed: []const u8, outcome: MkdirOutcome) PrivateDirError!fd_t {
    assert(outcome != .failed);
    const dir_fd = fs.openDirNoFollow(trimmed) catch |err| switch (err) {
        error.AccessDenied => if (outcome == .created) blk: {
            // Under `umask 0777` the directory we just created has mode 0000
            // and cannot be opened until owner rwx is restored.
            chmodCreatedDir(path_z, trimmed, 0o700);
            break :blk fs.openDirNoFollow(trimmed) catch return error.AccessDenied;
        } else return error.AccessDenied,
        error.NameTooLong => return error.NameTooLong,
        error.FileNotFound => return error.FileNotFound,
        // Linux reports ENOTDIR, Darwin ELOOP, for a symlink opened with
        // O_DIRECTORY|O_NOFOLLOW; lstat tells the two cases apart.
        error.NotDir, error.SymLinkLoop => {
            const st = fs.statAt(cwd_fd, trimmed, false) catch return error.NotDirectory;
            return if (st.kind() == posix.S.IFLNK) error.SymlinkParent else error.NotDirectory;
        },
        else => return error.Unexpected,
    };
    assert(dir_fd >= 0);
    return dir_fd;
}

/// mkdir 0700 if missing (after creating missing ancestors 0700), then open
/// `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` and require owner == euid and
/// `mode & 0o077 == 0`. Permissions are repaired with `fchmod` only on a
/// directory this call created; an existing loose directory is rejected with
/// `InsecurePermissions`. Works at umask 0777. Returns the pinned dir fd; the
/// caller closes it.
pub fn ensurePrivateDir(path: []const u8) PrivateDirError!fd_t {
    var trimmed = path;
    while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return error.FileNotFound;

    var buf: [posix.PATH_MAX]u8 = undefined;
    if (trimmed.len >= buf.len) return error.NameTooLong;
    assert(trimmed.len > 0);
    assert(trimmed.len < buf.len);
    @memcpy(buf[0..trimmed.len], trimmed);
    buf[trimmed.len] = 0;
    const path_z: [*:0]const u8 = buf[0..trimmed.len :0].ptr;

    var outcome = mkdirPrivateZ(path_z, trimmed, false);
    if (outcome == .failed and outcome.failed == .NOENT) {
        // Create missing ancestors front to back, like `mkdir -p`. Errors on
        // ancestors are ignored: the final mkdir reports what matters.
        var index: usize = 1;
        while (index < trimmed.len) : (index += 1) {
            if (buf[index] != '/') continue;
            buf[index] = 0;
            _ = mkdirPrivateZ(path_z, buf[0..index], true);
            buf[index] = '/';
        }
        outcome = mkdirPrivateZ(path_z, trimmed, false);
    }
    switch (outcome) {
        .failed => |err| return privateDirErr(err),
        .created, .exists => {},
    }

    const dir_fd = try openPrivateDir(path_z, trimmed, outcome);
    errdefer close(dir_fd);

    var st = fs.fstat(dir_fd) catch return error.Unexpected;
    if (!st.isDir()) return error.NotDirectory;
    if (st.uid != sys.geteuid()) return error.ForeignOwner;
    if (outcome == .created and st.permissions() != 0o700) {
        fs.fchmod(dir_fd, 0o700) catch return error.AccessDenied;
        st = fs.fstat(dir_fd) catch return error.Unexpected;
    }
    if (st.permissions() & 0o077 != 0) return error.InsecurePermissions;
    assert(st.isDir());
    assert(st.uid == sys.geteuid());
    return dir_fd;
}

/// `openat(dir_fd, name, flags|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC, mode)`, then
/// require a regular file owned by euid and clear `O_NONBLOCK`. `O_NONBLOCK`
/// keeps a planted FIFO from hanging the open; `O_NOFOLLOW` rejects a symlink
/// with `SymLinkLoop`.
pub fn openOwnedRegularAt(
    dir_fd: fd_t,
    name: []const u8,
    flags: c.O,
    mode: mode_t,
) (fs.OpenError || error{ NotRegularFile, ForeignOwner })!fd_t {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = try fs.toPathZ(&path_buf, name);
    var open_flags = flags;
    open_flags.NOFOLLOW = true;
    open_flags.NONBLOCK = true;
    open_flags.CLOEXEC = true;
    // Darwin can fail a creating open with ENOENT when another thread or
    // process creates the same name at the same moment (APFS race, especially
    // with O_NOFOLLOW). The directory is held open, so a bounded retry opens
    // or creates it while a genuinely removed directory still returns FileNotFound.
    var create_races_left: u8 = if (flags.CREAT and !flags.EXCL) 16 else 0;
    const file: fd_t = while (true) {
        const rc = c.openat(dir_fd, name_z, open_flags, @as(c_uint, mode));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => {
                if (create_races_left == 0) return error.FileNotFound;
                create_races_left -= 1;
                continue;
            },
            .NOTDIR => return error.NotDir,
            // Darwin reports EMLINK-free ELOOP; FreeBSD-style EMLINK is
            // treated the same way.
            .LOOP, .MLINK => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            // A write-only open of a FIFO with no reader, a socket, or a
            // directory opened for writing.
            .NXIO, .ISDIR, .OPNOTSUPP => return error.NotRegularFile,
            else => |err| return fd.unexpected(err),
        }
    };
    assert(file >= 0);
    errdefer close(file);
    const st = fs.fstat(file) catch return error.Unexpected;
    if (st.kind() != posix.S.IFREG) return error.NotRegularFile;
    if (st.uid != sys.geteuid()) return error.ForeignOwner;
    assert(st.kind() == posix.S.IFREG);
    try fd.clearNonBlocking(file);
    return file;
}

/// `flock(LOCK_EX)` polled with `LOCK_NB` until the monotonic `deadline_ms`
/// or until `stop` becomes true, so a contended lock never blocks shutdown.
pub fn flockExclusiveDeadline(
    file: fd_t,
    deadline_ms: i64,
    stop: ?*const std.atomic.Value(bool),
) error{ Timeout, Interrupted, Unexpected }!void {
    while (true) {
        if (stop) |flag| if (flag.load(.seq_cst)) return error.Interrupted;
        switch (posix.errno(c.flock(file, posix.LOCK.EX | posix.LOCK.NB))) {
            .SUCCESS => return,
            .INTR, .AGAIN => {},
            else => return error.Unexpected,
        }
        const remaining = deadline_ms - fd.monotonicMs();
        if (remaining <= 0) return error.Timeout;
        assert(remaining > 0);
        fd.sleepMs(@min(remaining, 10));
    }
}

const TestDir = fs.TestDir;
const testSymlink = fs.testSymlink;
const monotonicMs = fd.monotonicMs;
const statAt = fs.statAt;
const fstat = fs.fstat;
const mkdir = fs.mkdir;
const rmdir = fs.rmdir;
const geteuid = sys.geteuid;

extern "c" fn mkfifo(path: [*:0]const u8, mode: mode_t) c_int;

test "ensurePrivateDir creates a missing path with ancestors at 0700" {
    const dir = try TestDir.create("priv");
    var buf: [256]u8 = undefined;
    var buf_a: [256]u8 = undefined;
    var buf_ab: [256]u8 = undefined;
    const nested = dir.join(&buf, "a/b/c");
    defer {
        rmdir(nested) catch {};
        rmdir(dir.join(&buf_ab, "a/b")) catch {};
        dir.remove(&.{"a"});
    }

    const fd_ = try ensurePrivateDir(nested);
    defer close(fd_);
    const pinned = try fstat(fd_);
    try std.testing.expect(pinned.isDir());
    try std.testing.expectEqual(@as(u32, 0o700), pinned.permissions());
    try std.testing.expectEqual(geteuid(), pinned.uid);
    try std.testing.expect(try fd.isCloseOnExec(fd_));
    try std.testing.expect(pinned.sameFile(try statAt(cwd_fd, nested, false)));
    try std.testing.expectEqual(@as(u32, 0o700), (try statAt(cwd_fd, dir.join(&buf_a, "a"), false)).permissions());
    try std.testing.expectEqual(@as(u32, 0o700), (try statAt(cwd_fd, dir.join(&buf_ab, "a/b"), false)).permissions());

    // Idempotent on an existing private directory, with a trailing slash too.
    var slash_buf: [256]u8 = undefined;
    const with_slash = try std.fmt.bufPrint(&slash_buf, "{s}/", .{nested});
    const again = try ensurePrivateDir(with_slash);
    defer close(again);
    try std.testing.expect(pinned.sameFile(try fstat(again)));
}

test "ensurePrivateDir succeeds under umask 0777" {
    const dir = try TestDir.create("umask");
    var buf: [256]u8 = undefined;
    var buf_x: [256]u8 = undefined;
    const nested = dir.join(&buf, "x/y");
    defer {
        rmdir(nested) catch {};
        dir.remove(&.{"x"});
    }

    const previous = c.umask(0o777);
    const result = ensurePrivateDir(nested);
    _ = c.umask(previous);

    const fd_ = try result;
    defer close(fd_);
    try std.testing.expectEqual(@as(u32, 0o700), (try fstat(fd_)).permissions());
    try std.testing.expectEqual(@as(u32, 0o700), (try statAt(cwd_fd, dir.join(&buf_x, "x"), false)).permissions());
}

test "ensurePrivateDir rejects loose, symlinked, foreign and non-directory paths" {
    const dir = try TestDir.create("reject");
    defer dir.remove(&.{ "loose", "link", "target", "file" });
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;

    // An existing directory we own with group/other bits is rejected, not
    // silently repaired.
    const loose = dir.join(&buf, "loose");
    try mkdir(loose, 0o755);
    try fs.fchmodat(cwd_fd, loose, 0o755);
    try std.testing.expectError(error.InsecurePermissions, ensurePrivateDir(loose));
    try std.testing.expectEqual(@as(u32, 0o755), (try statAt(cwd_fd, loose, false)).permissions());

    // A symlink to a perfectly private directory is still refused.
    const target = dir.join(&buf, "target");
    try mkdir(target, 0o700);
    try fs.fchmodat(cwd_fd, target, 0o700);
    const link_path = dir.join(&buf2, "link");
    try testSymlink(target, link_path);
    try std.testing.expectError(error.SymlinkParent, ensurePrivateDir(link_path));

    // A regular file is not a directory, as a final or middle component.
    const file_path = dir.join(&buf, "file");
    close(try fs.open(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600));
    try std.testing.expectError(error.NotDirectory, ensurePrivateDir(file_path));
    try std.testing.expectError(error.NotDirectory, ensurePrivateDir(dir.join(&buf2, "file/child")));

    try std.testing.expectError(error.FileNotFound, ensurePrivateDir(""));
    const too_long: [posix.PATH_MAX + 8]u8 = @splat('p');
    try std.testing.expectError(error.NameTooLong, ensurePrivateDir(&too_long));

    // The filesystem root belongs to root.
    if (geteuid() != 0) try std.testing.expectError(error.ForeignOwner, ensurePrivateDir("/"));
}

test "openOwnedRegularAt opens owned regular files in blocking mode" {
    const dir = try TestDir.create("own");
    defer dir.remove(&.{"file"});
    const dir_fd = try fs.openDirNoFollow(dir.path());
    defer close(dir_fd);

    const fd_ = try openOwnedRegularAt(dir_fd, "file", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer close(fd_);
    try std.testing.expect(!fd.isNonBlocking(fd_));
    try std.testing.expect(try fd.isCloseOnExec(fd_));
    try fd.writeAll(fd_, "x");
    try std.testing.expectError(error.FileNotFound, openOwnedRegularAt(dir_fd, "missing", .{ .ACCMODE = .RDONLY }, 0));
}

test "openOwnedRegularAt creates under concurrent starters without spurious FileNotFound" {
    // Regression: concurrent daemon starters racing O_CREAT on the lock file
    // saw ENOENT on Darwin. Forked creators race on one name per round.
    var path_buf: [128]u8 = undefined;
    const dir_path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/zmx-ocreat-race-{d}", .{c.getpid()}, 0);
    mkdir(dir_path, 0o700) catch {};
    defer rmdir(dir_path) catch {};
    const dir_fd = try fs.openDirNoFollow(dir_path);
    defer close(dir_fd);
    for (0..1000) |_| {
        var children: [4]sys.pid_t = undefined;
        for (&children) |*child| {
            child.* = try sys.fork();
            if (child.* == 0) {
                const fd_ = openOwnedRegularAt(dir_fd, "race.lock", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch c._exit(1);
                close(fd_);
                c._exit(0);
            }
        }
        for (children) |child| {
            var status: c_int = 0;
            while (c.waitpid(child, &status, 0) < 0) {}
            try std.testing.expectEqual(@as(c_int, 0), status);
        }
        try fs.unlinkAt(dir_fd, "race.lock");
    }
}

test "openOwnedRegularAt rejects symlinks, FIFOs and directories without hanging" {
    const dir = try TestDir.create("ownrej");
    defer dir.remove(&.{ "file", "link", "fifo", "sub" });
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const dir_fd = try fs.openDirNoFollow(dir.path());
    defer close(dir_fd);

    close(try openOwnedRegularAt(dir_fd, "file", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600));
    try testSymlink(dir.join(&buf, "file"), dir.join(&buf2, "link"));
    try std.testing.expectError(error.SymLinkLoop, openOwnedRegularAt(dir_fd, "link", .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expectError(error.SymLinkLoop, openOwnedRegularAt(dir_fd, "link", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600));

    var fifo_buf: [posix.PATH_MAX]u8 = undefined;
    const fifo_z = try fs.toPathZ(&fifo_buf, dir.join(&buf, "fifo"));
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo_z, 0o600));
    // A blocking open of a reader-less FIFO would hang forever; both access
    // modes must return promptly.
    const started = monotonicMs();
    try std.testing.expectError(error.NotRegularFile, openOwnedRegularAt(dir_fd, "fifo", .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expectError(error.NotRegularFile, openOwnedRegularAt(dir_fd, "fifo", .{ .ACCMODE = .WRONLY }, 0));
    try std.testing.expect(monotonicMs() - started < 1000);

    try mkdir(dir.join(&buf, "sub"), 0o700);
    try std.testing.expectError(error.NotRegularFile, openOwnedRegularAt(dir_fd, "sub", .{ .ACCMODE = .RDONLY }, 0));
}

const FlockReleaser = struct {
    fd: fd_t,
    delay_ms: i64,
    stop: ?*std.atomic.Value(bool) = null,

    fn run(self: *FlockReleaser) void {
        fd.sleepMs(self.delay_ms);
        if (self.stop) |flag| {
            flag.store(true, .seq_cst);
        } else {
            _ = c.flock(self.fd, posix.LOCK.UN);
        }
    }
};

test "flockExclusiveDeadline times out, is interruptible, and acquires after release" {
    const dir = try TestDir.create("flock");
    defer dir.remove(&.{"lock"});
    var buf: [256]u8 = undefined;
    const path = dir.join(&buf, "lock");

    // flock locks belong to the open file description, so two opens contend
    // even inside one process.
    const holder = try fs.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    defer close(holder);
    const waiter = try fs.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    defer close(waiter);

    try flockExclusiveDeadline(holder, monotonicMs() + 100, null);

    const started = monotonicMs();
    try std.testing.expectError(error.Timeout, flockExclusiveDeadline(waiter, started + 120, null));
    const elapsed = monotonicMs() - started;
    try std.testing.expect(elapsed >= 120 and elapsed <= 200);

    // A stop flag raised from another thread interrupts the wait early.
    var stop = std.atomic.Value(bool).init(false);
    var stopper = FlockReleaser{ .fd = holder, .delay_ms = 30, .stop = &stop };
    const stop_thread = try std.Thread.spawn(.{}, FlockReleaser.run, .{&stopper});
    const stop_started = monotonicMs();
    try std.testing.expectError(error.Interrupted, flockExclusiveDeadline(waiter, stop_started + 5000, &stop));
    stop_thread.join();
    try std.testing.expect(monotonicMs() - stop_started < 1000);

    // Once the holder releases, the waiter acquires before its deadline.
    stop.store(false, .seq_cst);
    var releaser = FlockReleaser{ .fd = holder, .delay_ms = 30 };
    const release_thread = try std.Thread.spawn(.{}, FlockReleaser.run, .{&releaser});
    try flockExclusiveDeadline(waiter, monotonicMs() + 5000, &stop);
    release_thread.join();
    try std.testing.expectError(error.Timeout, flockExclusiveDeadline(holder, monotonicMs() + 30, null));
    try std.testing.expectError(error.Unexpected, flockExclusiveDeadline(-1, monotonicMs() + 30, null));
}
