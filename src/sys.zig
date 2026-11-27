//! Thin, error-returning POSIX layer over libc for the syscalls `std.Io` does
//! not model.
//!
//! Zig 0.16 moved general-purpose I/O behind `std.Io` and reduced `std.posix`
//! to a handful of primitives. zmux still needs operations that no `Io`
//! implementation exposes: PTY fork/exec, `poll(2)` over raw descriptors,
//! binding a UNIX socket after `fchmod` (Linux) or inside a private staging
//! directory, peer credentials, owner/device/inode checks on socket paths, and
//! termios. Those calls live here so every other module either uses `std.Io`
//! or this one seam. zmux always links libc, so each wrapper is a direct
//! `std.c` call plus errno mapping. Error names match the Zig 0.15
//! `std.posix` vocabulary so callers' `switch` arms stay meaningful.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;

/// Platform file descriptor type.
pub const fd_t = posix.fd_t;
/// Platform process id type.
pub const pid_t = posix.pid_t;
/// Platform user id type.
pub const uid_t = c.uid_t;
/// Platform file mode type.
pub const mode_t = c.mode_t;

const fd_io = @import("sys/fd.zig");
const socket = @import("sys/socket.zig");
const fs = @import("sys/fs.zig");
const private = @import("sys/private.zig");
const child = @import("sys/child.zig");

const is_darwin = builtin.os.tag.isDarwin();
const unexpected = fd_io.unexpected;

/// An errno this layer does not map to a named error.
pub const UnexpectedError = error{Unexpected};

/// The process-wide Darwin fork lock. Test seam: defined here because a
/// mutable global cannot be re-exported through a `pub const` alias.
pub var fork_lock: ForkLock = .{};
const fork_lock_budget_ms: i64 = 100;

/// `read(2)` with the `std.posix` error vocabulary.
pub const read = posix.read;
/// Errors from `read`.
pub const ReadError = posix.ReadError;
/// `poll(2)` with the `std.posix` error vocabulary.
pub const poll = posix.poll;

/// Errors from `setCloseOnExec`.
pub const SetCloexecError = UnexpectedError;

/// Effective user id of the calling process.
pub fn geteuid() uid_t {
    return c.geteuid();
}

/// Process id of the calling process.
pub fn getpid() pid_t {
    return c.getpid();
}

/// Number of `kill(2)` calls made through `kill`. Test seam: lets callers
/// prove that a reaped child is never signalled.
pub var kill_call_count: std.atomic.Value(usize) = .init(0);

/// `kill(2)`. A negative `pid` addresses a process group. Returns false on
/// failure (for example `ESRCH`). Async-signal-safe.
pub fn kill(pid: pid_t, sig: posix.SIG) bool {
    _ = kill_call_count.fetchAdd(1, .seq_cst);
    return c.kill(pid, sig) == 0;
}

const libc = struct {
    // `request` is `unsigned long` in the kernel ABI on Darwin and Linux;
    // `std.c.ioctl` narrows it to `c_int`, which sign-extends requests with
    // the top bit set (every Darwin `_IOW` request).
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn getsid(pid: pid_t) pid_t;
    extern "c" fn getpgrp() pid_t;
    extern "c" fn pause() c_int;
};

/// `ioctl(2)` with the request passed at its native width. Async-signal-safe.
pub fn ioctl(fd: fd_t, request: c_ulong, arg: usize) c_int {
    return libc.ioctl(fd, request, arg);
}

// ---------------------------------------------------------------------------
// Test seams read by the submodules

/// Test seam: route every stat through the `newfstatat` fallback.
pub var force_stat_fallback: bool = false;

/// Test seam: skip `close_range(2)` so the enumeration fallback of
/// `closeFrom` runs on Linux too.
pub var force_close_from_fallback: bool = false;

// ---------------------------------------------------------------------------
// Processes

/// Errors from `fork`.
pub const ForkError = error{ SystemResources, ProcessLimitReached } || UnexpectedError;

/// `fork(2)`. On Darwin the fork lock is held exclusively across the call so
/// the child never inherits a descriptor that is about to become
/// close-on-exec.
pub fn fork() ForkError!pid_t {
    const locked = is_darwin and fork_lock.lockExclusiveBounded(fork_lock_budget_ms);
    assert(!locked or is_darwin);
    const rc = c.fork();
    // Runs in both parent and child; each owns its own copy of the lock.
    if (locked) fork_lock.unlockExclusive();
    switch (posix.errno(rc)) {
        .SUCCESS => {
            assert(rc >= 0);
            return @intCast(rc);
        },
        .AGAIN => return error.ProcessLimitReached,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

/// `PATH` used for bare program names when the environment has none.
pub const default_exec_path = "/usr/local/bin:/bin:/usr/bin";

/// Errors from `execvpeZ`.
pub const ExecError = error{
    AccessDenied,
    FileNotFound,
    NameTooLong,
    InvalidExe,
    SystemResources,
} || UnexpectedError;

/// `execvpe(3)` semantics without allocation: a `file` containing '/' is
/// executed directly; otherwise each `PATH` entry (from the calling process
/// environment, defaulting to `default_exec_path`) is tried in order; an empty
/// entry means the current directory. Only returns on failure. It reads `PATH`
/// with `getenv`, so strictly async-signal-safe callers (the PTY child)
/// resolve candidates before `fork` instead and call `execve` directly.
pub fn execvpeZ(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError {
    const file_slice = std.mem.sliceTo(file, 0);
    if (std.mem.indexOfScalar(u8, file_slice, '/') != null) {
        return execErr(posix.errno(c.execve(file, argv, envp)));
    }

    const path_env: []const u8 = if (c.getenv("PATH")) |value| std.mem.sliceTo(value, 0) else default_exec_path;
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    var last: ExecError = error.FileNotFound;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |component| {
        // POSIX: an empty PATH component names the current directory.
        const dir = if (component.len == 0) "." else component;
        if (dir.len + 1 + file_slice.len >= path_buf.len) {
            last = error.NameTooLong;
            continue;
        }
        assert(dir.len > 0);
        assert(dir.len + 1 + file_slice.len < path_buf.len);
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = '/';
        @memcpy(path_buf[dir.len + 1 ..][0..file_slice.len], file_slice);
        path_buf[dir.len + 1 + file_slice.len] = 0;
        const candidate: [*:0]const u8 = path_buf[0 .. dir.len + 1 + file_slice.len :0].ptr;
        const err = execErr(posix.errno(c.execve(candidate, argv, envp)));
        switch (err) {
            // Keep searching on "not here"; remember permission failures so a
            // later miss does not hide them, as execvp(3) does.
            error.FileNotFound => {},
            error.AccessDenied => last = err,
            else => return err,
        }
    }
    return last;
}

fn execErr(err: posix.E) ExecError {
    return switch (err) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .NOTDIR => error.FileNotFound,
        .NAMETOOLONG => error.NameTooLong,
        .NOEXEC => error.InvalidExe,
        .NOMEM, .@"2BIG" => error.SystemResources,
        else => unexpected(err),
    };
}

/// The process environment block as a NULL-terminated `envp` array.
pub fn currentEnviron() [*:null]const ?[*:0]const u8 {
    return @ptrCast(c.environ);
}

// ---------------------------------------------------------------------------
// Process groups and sessions

/// Linux `pidfd_send_signal(2)`: signal the exact process `pid_fd` refers
/// to. Unlike `kill(2)` it can never reach a process that reused the PID.
/// Returns false on failure, on other platforms, and for a negative
/// descriptor. Counted in `kill_call_count`. Async-signal-safe.
pub fn pidfdSendSignal(pid_fd: fd_t, sig: posix.SIG) bool {
    if (builtin.os.tag != .linux or pid_fd < 0) return false;
    assert(pid_fd >= 0);
    _ = kill_call_count.fetchAdd(1, .seq_cst);
    const rc = std.os.linux.pidfd_send_signal(pid_fd, sig, null, 0);
    return std.os.linux.errno(rc) == .SUCCESS;
}

/// True when the process group `pgid` still has a member (zombies included).
/// Never delivers a signal and is not counted in `kill_call_count`.
pub fn processGroupExists(pgid: pid_t) bool {
    if (pgid <= 1) return false;
    assert(pgid > 1);
    return c.kill(-pgid, @fromBackingInt(@intCast(0))) == 0;
}

/// `getsid(2)`: the session id of `pid`, or null when it cannot be read.
pub fn sessionOf(pid: pid_t) ?pid_t {
    const sid = libc.getsid(pid);
    assert(sid >= -1);
    return if (sid < 0) null else sid;
}

// ---------------------------------------------------------------------------
// Re-exports

/// Async-signal-safe sleep that needs no `std.Io`.
pub const sleepMs = fd_io.sleepMs;
/// Milliseconds on the monotonic (awake) clock.
pub const monotonicMs = fd_io.monotonicMs;
/// Guards the Darwin-only windows where a descriptor exists without `FD_CLOEXEC` (`socket`,
/// `accept`, `pipe`, `openpty` have no atomic close-on-exec form there).
pub const ForkLock = fd_io.ForkLock;
/// Close `fd`, ignoring errors.
pub const close = fd_io.close;
/// Errors from `write` and `send`.
pub const WriteError = fd_io.WriteError;
/// `write(2)`, retrying `EINTR`.
pub const write = fd_io.write;
/// Write every byte, retrying short writes.
pub const writeAll = fd_io.writeAll;
/// Send bytes on a connected socket with `MSG_NOSIGNAL` so a closed peer reports `error.BrokenPipe`
/// instead of raising `SIGPIPE` in an embedding process that leaves `SIGPIPE` at its default
/// disposition.
pub const send = fd_io.send;
/// Send every byte on a socket with `MSG_NOSIGNAL`, retrying short writes.
pub const sendAll = fd_io.sendAll;
/// `dup2(2)`: make `new_fd` refer to the same open file as `old_fd`.
pub const dup2 = fd_io.dup2;
/// Errors from `pipe` and `pipeCloexec`.
pub const PipeError = fd_io.PipeError;
/// Create a pipe.
pub const pipe = fd_io.pipe;
/// Create a pipe whose ends are both close-on-exec, with no window in which a concurrent `fork`
/// could inherit them.
pub const pipeCloexec = fd_io.pipeCloexec;
/// Set `FD_CLOEXEC` on `fd`.
pub const setCloseOnExec = fd_io.setCloseOnExec;
/// Clear `FD_CLOEXEC` on `fd`. Async-signal-safe.
pub const clearCloseOnExec = fd_io.clearCloseOnExec;
/// Set `O_NONBLOCK` on `fd`.
pub const setNonBlocking = fd_io.setNonBlocking;
/// Clear `O_NONBLOCK` on `fd`.
pub const clearNonBlocking = fd_io.clearNonBlocking;
/// True when `fd` has `O_NONBLOCK`; false also when `fcntl` fails.
pub const isNonBlocking = fd_io.isNonBlocking;
/// True when `fd` has `FD_CLOEXEC`.
pub const isCloseOnExec = fd_io.isCloseOnExec;
/// True when `fd` refers to a terminal.
pub const isatty = fd_io.isatty;
/// Byte capacity of `sockaddr_un.sun_path`, excluding the NUL terminator.
pub const max_unix_path_len = socket.max_unix_path_len;
/// A `sockaddr_un` for a filesystem `AF_UNIX` socket path.
pub const UnixAddress = socket.UnixAddress;
/// Errors from creating a socket or socket pair.
pub const SocketError = socket.SocketError;
/// Create a close-on-exec AF_UNIX stream socket.
pub const unixStreamSocket = socket.unixStreamSocket;
/// Raise `SO_SNDBUF` and `SO_RCVBUF` on local UNIX stream sockets (best effort).
pub const tuneUnixSocketBuffers = socket.tuneUnixSocketBuffers;
/// Errors from `bind`.
pub const BindError = socket.BindError;
/// `bind(2)` `fd` to the UNIX socket `address`.
pub const bind = socket.bind;
/// Errors from `listen`.
pub const ListenError = socket.ListenError;
/// `listen(2)` on `fd` with at most `backlog` pending connections.
pub const listen = socket.listen;
/// Errors from `accept`.
pub const AcceptError = socket.AcceptError;
/// Accept one connection; the returned descriptor is close-on-exec.
pub const accept = socket.accept;
/// Errors from `connect` and the `connectUnix*` helpers.
pub const ConnectError = socket.ConnectError;
/// `connect(2)` `fd` to the UNIX socket `address`, retrying `EINTR`.
pub const connect = socket.connect;
/// Create a close-on-exec socket and connect it to the UNIX socket at `path`.
pub const connectUnix = socket.connectUnix;
/// A connected pair of `AF_UNIX` stream sockets.
pub const socketPair = socket.socketPair;
/// Effective uid of the peer on a connected `AF_UNIX` socket.
pub const peerEuid = socket.peerEuid;
/// Non-blocking connect + poll(POLLOUT).
pub const connectUnixDeadline = socket.connectUnixDeadline;
/// The file metadata zmux checks: device, inode, mode and owner.
pub const Stat = fs.Stat;
/// Errors from `statAt` and `fstat`.
pub const StatError = fs.StatError;
/// `AT_FDCWD`: resolve relative paths against the current directory.
pub const cwd_fd = fs.cwd_fd;
/// `fstatat(2)`.
pub const statAt = fs.statAt;
/// `fstat(2)`.
pub const fstat = fs.fstat;
/// Errors from `fchmod` and `fchmodat`.
pub const ChmodError = fs.ChmodError;
/// `fchmod(2)`, retrying `EINTR`.
pub const fchmod = fs.fchmod;
/// `fchmodat(2)` relative to `dir_fd`, following symlinks; retries `EINTR`.
pub const fchmodat = fs.fchmodat;
/// Errors from `mkdir`.
pub const MkdirError = fs.MkdirError;
/// `mkdir(2)`.
pub const mkdir = fs.mkdir;
/// `rmdir(2)`.
pub const rmdir = fs.rmdir;
/// `unlinkat(2)` of a non-directory `path` relative to `dir_fd`.
pub const unlinkAt = fs.unlinkAt;
/// `rename(2)`: atomically replace `new_path` with `old_path`.
pub const rename = fs.rename;
/// Errors from `open`, `openZ` and the open helpers.
pub const OpenError = fs.OpenError;
/// Open `path` with raw `O_*` flags.
pub const open = fs.open;
/// Async-signal-safe `open(2)` on a NUL-terminated path, safe between `fork` and `exec`.
pub const openZ = fs.openZ;
/// Open a directory read-only, close-on-exec, refusing a symlink in the final component.
pub const openDirNoFollow = fs.openDirNoFollow;
/// Errors from `ensurePrivateDir`.
pub const PrivateDirError = private.PrivateDirError;
/// mkdir 0700 if missing (after creating missing ancestors 0700), then open
/// `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` and require owner == euid and `mode & 0o077 == 0`.
pub const ensurePrivateDir = private.ensurePrivateDir;
/// `openat(dir_fd, name, flags|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC, mode)`, then require a regular file
/// owned by euid and clear `O_NONBLOCK`.
pub const openOwnedRegularAt = private.openOwnedRegularAt;
/// `flock(LOCK_EX)` polled with `LOCK_NB` until the monotonic `deadline_ms` or until `stop` becomes
/// true, so a contended lock never blocks shutdown.
pub const flockExclusiveDeadline = private.flockExclusiveDeadline;
/// Close every descriptor `>= low_fd`. Async-signal-safe.
pub const closeFrom = child.closeFrom;
/// Signals `resetChildSignals` restores to `SIG_DFL`.
pub const child_reset_signals = child.child_reset_signals;
/// Restore default signal dispositions and clear the signal mask. Async-signal-safe.
pub const resetChildSignals = child.resetChildSignals;

// ---------------------------------------------------------------------------
// Tests

test {
    std.testing.refAllDecls(@This());
    _ = @import("sys/fd.zig");
    _ = @import("sys/socket.zig");
    _ = @import("sys/fs.zig");
    _ = @import("sys/private.zig");
    _ = @import("sys/child.zig");
}

test "execvpeZ reports a missing program without replacing the process" {
    const argv = [_:null]?[*:0]const u8{"zmux-no-such-program"};
    const envp = [_:null]?[*:0]const u8{};
    try std.testing.expectEqual(error.FileNotFound, execvpeZ("zmux-no-such-program", &argv, &envp));
    try std.testing.expectEqual(error.FileNotFound, execvpeZ("/zmux/no/such/program", &argv, &envp));
}

test "kill wrapper counts calls and reports failures" {
    const before = kill_call_count.load(.seq_cst);
    // Signal 0 probes for existence without delivering anything.
    try std.testing.expect(kill(getpid(), @fromBackingInt(@intCast(0))));
    try std.testing.expectEqual(before + 1, kill_call_count.load(.seq_cst));
}

test "pidfdSendSignal signals exactly the process behind the descriptor" {
    if (builtin.os.tag != .linux) {
        try std.testing.expect(!pidfdSendSignal(0, .TERM));
        return;
    }
    try std.testing.expect(!pidfdSendSignal(-1, .TERM));
    const pid = try fork();
    if (pid == 0) {
        while (true) _ = libc.pause();
    }
    const raw = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(raw) != .SUCCESS) {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
        return error.SkipZigTest;
    }
    const pid_fd: fd_t = @intCast(raw);
    defer close(pid_fd);
    const before = kill_call_count.load(.seq_cst);
    try std.testing.expect(pidfdSendSignal(pid_fd, .KILL));
    try std.testing.expectEqual(before + 1, kill_call_count.load(.seq_cst));
    var status: c_int = 0;
    try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    try std.testing.expectEqual(posix.SIG.KILL, posix.W.TERMSIG(@as(u32, @bitCast(status))));
    // The process is reaped: the descriptor no longer names anything.
    try std.testing.expect(!pidfdSendSignal(pid_fd, .KILL));
}

test "processGroupExists and sessionOf describe the current process" {
    // Inside a container the test can run in the group of PID 1, which
    // `processGroupExists` deliberately never reports.
    const own_group = libc.getpgrp();
    try std.testing.expectEqual(own_group > 1, processGroupExists(own_group));
    try std.testing.expect(!processGroupExists(1));
    try std.testing.expect(!processGroupExists(0));
    try std.testing.expect(!processGroupExists(0x7fff_fff0));
    try std.testing.expect(sessionOf(getpid()) != null);
    try std.testing.expectEqual(@as(?pid_t, null), sessionOf(0x7fff_fff0));
}

test "ioctl wrapper reports ENOTTY for a non-terminal" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    var wsz: posix.winsize = undefined;
    try std.testing.expect(ioctl(fds[0], posix.T.IOCGWINSZ, @intFromPtr(&wsz)) != 0);
}
