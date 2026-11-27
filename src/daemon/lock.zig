//! Start lock for one socket path: the pinned socket directory, the
//! persistent `<socket>.lock` file, and the sibling file names beside it.
const std = @import("std");

const log = @import("../log.zig");
const server_mod = @import("../server.zig");
const socket_path_mod = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const pidfile = @import("pidfile.zig");

const posix = std.posix;
const assert = std.debug.assert;
const test_io = std.testing.io;
const posix_ok = pidfile.posix_ok;
const TempDir = pidfile.TempDir;

/// Serializes daemon startup (and socket/PID cleanup) for one socket path.
///
/// A running daemon holds the lock for its whole lifetime and releases it
/// only after `Server.deinit`, so holding it is proof of a live (or starting)
/// daemon. A second starter never reaches the stale-socket probe, which on
/// macOS reports a live listener with a full accept queue as refused.
///
/// The lock is `flock(2)` on a persistent `<socket>.lock` file. The file is
/// never unlinked: `flock` locks an inode, so removing the name would let one
/// starter hold the old inode while another creates and locks a new one, and
/// both would believe they are alone. Releasing is closing the descriptor.
///
/// The file is opened relative to the pinned, already validated socket
/// directory with `O_NOFOLLOW` and must be a regular file this user owns, so
/// a symlink, FIFO, or foreign file planted at the name is refused instead of
/// followed or blocked on.
const StartLock = struct {
    fd: sys.fd_t,

    fn acquire(
        dir_fd: sys.fd_t,
        lock_name: []const u8,
        timeout_ms: i64,
        stop: ?*const std.atomic.Value(bool),
    ) !StartLock {
        assert(lock_name.len > 0);
        const fd = try sys.openOwnedRegularAt(dir_fd, lock_name, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
        errdefer sys.close(fd);
        assert(fd >= 0);
        // A restrictive umask must not leave a lock the next starter cannot
        // open. The file is ours (checked above), so this is safe.
        sys.fchmod(fd, 0o600) catch |err| log.debug("start_lock_fchmod_failed", .{ .err = err });
        try sys.flockExclusiveDeadline(fd, sys.monotonicMs() + timeout_ms, stop);
        return .{ .fd = fd };
    }

    pub fn release(self: *StartLock) void {
        if (self.fd < 0) return;
        sys.close(self.fd);
        self.fd = -1;
    }
};

/// Names of the files zmuxd keeps beside the socket, relative to the socket
/// directory.
pub const SiblingNames = struct {
    lock_buf: [server_mod.max_socket_path_len + ".lock".len]u8 = undefined,
    pid_buf: [server_mod.max_socket_path_len + ".pid".len]u8 = undefined,
    lock_len: usize = 0,
    pid_len: usize = 0,

    /// A base name too long for the buffers (only possible for a path that
    /// never passed `socket_path.validate`) leaves both lengths 0; check
    /// `fits` before using the names.
    pub fn init(socket_path: []const u8) SiblingNames {
        var names: SiblingNames = .{};
        const base = std.fs.path.basename(socket_path);
        const lock_name = std.fmt.bufPrint(&names.lock_buf, "{s}.lock", .{base}) catch return names;
        const pid_name = std.fmt.bufPrint(&names.pid_buf, "{s}.pid", .{base}) catch return names;
        names.lock_len = lock_name.len;
        names.pid_len = pid_name.len;
        assert(names.lock_len == base.len + ".lock".len);
        assert(names.pid_len == base.len + ".pid".len);
        return names;
    }

    /// True when both derived names were formatted.
    pub fn fits(self: *const SiblingNames) bool {
        return self.lock_len > 0 and self.pid_len > 0;
    }

    pub fn lock(self: *const SiblingNames) []const u8 {
        assert(self.lock_len <= self.lock_buf.len);
        return self.lock_buf[0..self.lock_len];
    }

    pub fn pid(self: *const SiblingNames) []const u8 {
        assert(self.pid_len <= self.pid_buf.len);
        return self.pid_buf[0..self.pid_len];
    }
};

/// The pinned socket directory plus the start lock inside it.
pub const StartContext = struct {
    dir_fd: sys.fd_t,
    lock: StartLock,

    pub fn deinit(self: *StartContext) void {
        self.lock.release();
        sys.close(self.dir_fd);
    }
};

/// Validate (or create private) the socket directory first, then take the
/// start lock inside it. The order matters: the lock, PID file, and socket
/// are only ever created in a directory that already passed the ownership
/// and permission checks, through the descriptor that was checked.
pub fn openStartContext(
    socket_path: []const u8,
    getenv: socket_path_mod.GetEnv,
    timeout_ms: i64,
    stop: ?*const std.atomic.Value(bool),
) !StartContext {
    const names = SiblingNames.init(socket_path);
    if (!names.fits()) return error.NameTooLong;
    const dir_fd = try server_mod.openSocketParent(socket_path, getenv);
    errdefer sys.close(dir_fd);
    assert(dir_fd >= 0);
    const lock = try StartLock.acquire(dir_fd, names.lock(), timeout_ms, stop);
    assert(lock.fd >= 0);
    return .{ .dir_fd = dir_fd, .lock = lock };
}

const LockContention = struct {
    dir_fd: sys.fd_t,
    inside: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_inside: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    entries: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    inodes_differ: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    first_ino: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const name = "sessions.sock.lock";

    fn starter(self: *LockContention) void {
        var round: usize = 0;
        while (round < 6) : (round += 1) {
            var lock = StartLock.acquire(self.dir_fd, name, 10_000, null) catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                return;
            };
            const now_inside = self.inside.fetchAdd(1, .seq_cst) + 1;
            _ = self.max_inside.fetchMax(now_inside, .seq_cst);
            _ = self.entries.fetchAdd(1, .seq_cst);

            // Every holder must be locking the one persistent inode.
            if (sys.fstat(lock.fd)) |stat| {
                const previous = self.first_ino.cmpxchgStrong(0, stat.ino, .seq_cst, .seq_cst);
                if (previous != null and previous.? != stat.ino) self.inodes_differ.store(true, .seq_cst);
            } else |_| {
                _ = self.failures.fetchAdd(1, .seq_cst);
            }

            test_io.sleep(.fromMilliseconds(3), .awake) catch |err| {
                log.debug("test_sleep_failed", .{ .err = err });
            };
            _ = self.inside.fetchSub(1, .seq_cst);
            lock.release();
        }
    }
};

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "start lock file is never unlinked and excludes a second holder" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock");
    defer dir.deinit();
    const name = "sessions.sock.lock";

    var first = try StartLock.acquire(dir.fd, name, 500, null);
    const created = try sys.statAt(dir.fd, name, false);
    try std.testing.expectEqual(@as(u32, posix.S.IFREG), created.kind());
    try std.testing.expectEqual(@as(u32, 0o600), created.permissions());
    try std.testing.expectEqual(sys.geteuid(), created.uid);

    // Held: a second starter times out instead of getting its own lock.
    const start = sys.monotonicMs();
    try std.testing.expectError(error.Timeout, StartLock.acquire(dir.fd, name, 150, null));
    try std.testing.expect(sys.monotonicMs() - start >= 100);
    try std.testing.expect(created.sameFile(try sys.statAt(dir.fd, name, false)));

    // Released: the file is still there, same inode, and can be taken again.
    first.release();
    first.release();
    try std.testing.expect(created.sameFile(try sys.statAt(dir.fd, name, false)));

    var second = try StartLock.acquire(dir.fd, name, 500, null);
    try std.testing.expect(created.sameFile(try sys.fstat(second.fd)));
    second.release();
    try std.testing.expect(created.sameFile(try sys.statAt(dir.fd, name, false)));
    try std.testing.expectEqual(@as(usize, 1), try dir.entryCount());
}

test "three concurrent starters never hold the start lock together" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock-race");
    defer dir.deinit();

    // Release-then-reacquire is exactly the window where an unlinking lock
    // lets two starters each lock a different inode.
    var contention: LockContention = .{ .dir_fd = dir.fd };
    var threads: [3]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, LockContention.starter, .{&contention});
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(u32, 0), contention.failures.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 18), contention.entries.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), contention.max_inside.load(.seq_cst));
    try std.testing.expect(!contention.inodes_differ.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), try dir.entryCount());
}

test "waiting for the start lock stops when shutdown is requested" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock-stop");
    defer dir.deinit();
    const name = "sessions.sock.lock";

    var held = try StartLock.acquire(dir.fd, name, 500, null);
    defer held.release();

    var stop = std.atomic.Value(bool).init(true);
    const start = sys.monotonicMs();
    try std.testing.expectError(error.Interrupted, StartLock.acquire(dir.fd, name, 30_000, &stop));
    try std.testing.expect(sys.monotonicMs() - start < 2000);
}

test "a symlink or FIFO in place of the lock file is refused without following or hanging" {
    if (!posix_ok) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var dir = try TempDir.init("zmx-lock-planted");
    defer dir.deinit();

    // A dangling symlink: following it would create a file wherever the
    // attacker pointed.
    const target = try dir.child("attacker-chosen-target");
    defer allocator.free(target);
    const link = try dir.child("link.sock.lock");
    defer allocator.free(link);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target.ptr, link.ptr));
    if (StartLock.acquire(dir.fd, "link.sock.lock", 200, null)) |acquired| {
        var lock = acquired;
        lock.release();
        return error.SymlinkedLockAccepted;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, target, false));

    // A symlink to an existing regular file is refused as well.
    {
        var file = try std.Io.Dir.createFileAbsolute(test_io, target, .{});
        file.close(test_io);
    }
    if (StartLock.acquire(dir.fd, "link.sock.lock", 200, null)) |acquired| {
        var lock = acquired;
        lock.release();
        return error.SymlinkedLockAccepted;
    } else |_| {}

    // A FIFO: a blocking open would hang the daemon forever.
    const fifo = try dir.child("fifo.sock.lock");
    defer allocator.free(fifo);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo.ptr, 0o600));
    const start = sys.monotonicMs();
    try std.testing.expectError(error.NotRegularFile, StartLock.acquire(dir.fd, "fifo.sock.lock", 200, null));
    try std.testing.expect(sys.monotonicMs() - start < 2000);
}

test "the start lock stays usable under a umask that clears every bit" {
    if (!posix_ok) return error.SkipZigTest;
    var dir = try TempDir.init("zmx-lock-umask");
    defer dir.deinit();
    const name = "sessions.sock.lock";

    const original_umask = std.c.umask(0o777);
    defer _ = std.c.umask(original_umask);

    var first = try StartLock.acquire(dir.fd, name, 500, null);
    first.release();
    try std.testing.expectEqual(@as(u32, 0o600), (try sys.statAt(dir.fd, name, false)).permissions());
    var second = try StartLock.acquire(dir.fd, name, 500, null);
    second.release();
}
