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

const c = std.c;
const posix = std.posix;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const uid_t = c.uid_t;
pub const mode_t = c.mode_t;

const is_darwin = builtin.os.tag.isDarwin();

pub const UnexpectedError = error{Unexpected};

/// Async-signal-safe: unlike `std.posix.unexpectedErrno` this never prints or
/// captures a stack trace, so wrappers stay usable between `fork` and `exec`.
fn unexpected(err: posix.E) UnexpectedError {
    _ = err;
    return error.Unexpected;
}

/// Async-signal-safe sleep that needs no `std.Io`.
pub fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    var none: [1]c.pollfd = undefined;
    _ = c.poll(&none, 0, @intCast(@min(ms, std.math.maxInt(c_int))));
}

/// Guards the Darwin-only windows where a descriptor exists without
/// `FD_CLOEXEC` (`socket`, `accept`, `pipe`, `openpty` have no atomic
/// close-on-exec form there). Descriptor creators hold it shared; `fork`
/// holds it exclusive, so a forked child never observes a half-initialised
/// descriptor. The exclusive side waits a bounded time: `closeFrom` in the
/// child is the backstop, so `fork` must never deadlock behind a reader.
pub const ForkLock = struct {
    /// > 0: number of shared holders; -1: exclusive holder.
    state: std.atomic.Value(i32) = .init(0),

    pub fn lockShared(self: *ForkLock) void {
        while (true) {
            const current = self.state.load(.seq_cst);
            if (current >= 0 and self.state.cmpxchgWeak(current, current + 1, .seq_cst, .seq_cst) == null) return;
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlockShared(self: *ForkLock) void {
        _ = self.state.fetchSub(1, .seq_cst);
    }

    /// Returns false when shared holders did not drain within `budget_ms`.
    pub fn lockExclusiveBounded(self: *ForkLock, budget_ms: i64) bool {
        const deadline = monotonicMs() + budget_ms;
        while (true) {
            if (self.state.cmpxchgStrong(0, -1, .seq_cst, .seq_cst) == null) return true;
            if (monotonicMs() >= deadline) return false;
            sleepMs(1);
        }
    }

    pub fn unlockExclusive(self: *ForkLock) void {
        self.state.store(0, .seq_cst);
    }
};

pub var fork_lock: ForkLock = .{};
const fork_lock_budget_ms: i64 = 100;

inline fn forkLockShared() void {
    if (is_darwin) fork_lock.lockShared();
}

inline fn forkUnlockShared() void {
    if (is_darwin) fork_lock.unlockShared();
}

/// Close `fd`, ignoring errors. Matches the Zig 0.15 `std.posix.close` contract:
/// EINTR still releases the descriptor, so retrying would be a bug.
pub fn close(fd: fd_t) void {
    _ = c.close(fd);
}

pub const WriteError = error{
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
} || UnexpectedError;

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    const max_count: usize = if (is_darwin) std.math.maxInt(i32) else 0x7ffff000;
    while (true) {
        const rc = c.write(fd, bytes.ptr, @min(bytes.len, max_count));
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES, .PERM => return error.AccessDenied,
            else => |err| return unexpected(err),
        }
    }
}

/// Write every byte, retrying short writes. A zero-length write is reported as
/// `error.WriteZero` instead of spinning.
pub fn writeAll(fd: fd_t, bytes: []const u8) (WriteError || error{WriteZero})!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try write(fd, bytes[offset..]);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

/// Send bytes on a connected socket with `MSG_NOSIGNAL` so a closed peer
/// reports `error.BrokenPipe` instead of raising `SIGPIPE` in an embedding
/// process that leaves `SIGPIPE` at its default disposition.
pub fn send(fd: fd_t, bytes: []const u8) WriteError!usize {
    if (bytes.len == 0) return 0;
    const max_count: usize = if (is_darwin) std.math.maxInt(i32) else 0x7ffff000;
    while (true) {
        const rc = c.send(fd, bytes.ptr, @min(bytes.len, max_count), c.MSG.NOSIGNAL);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .ACCES, .PERM => return error.AccessDenied,
            else => |err| return unexpected(err),
        }
    }
}

/// Send every byte on a socket with `MSG_NOSIGNAL`, retrying short writes.
pub fn sendAll(fd: fd_t, bytes: []const u8) (WriteError || error{WriteZero})!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try send(fd, bytes[offset..]);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

/// `dup2(2)`: make `new_fd` refer to the same open file as `old_fd`.
/// Async-signal-safe; suitable for use between `fork` and `exec`.
/// When `old_fd == new_fd`, clears `FD_CLOEXEC` instead so the descriptor
/// survives `exec`.
pub fn dup2(old_fd: fd_t, new_fd: fd_t) UnexpectedError!void {
    if (old_fd == new_fd) return clearCloseOnExec(new_fd);
    while (true) {
        switch (posix.errno(c.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .INTR, .BUSY => continue,
            else => |err| return unexpected(err),
        }
    }
}

pub const read = posix.read;
pub const ReadError = posix.ReadError;
pub const poll = posix.poll;

pub const PipeError = error{ ProcessFdQuotaExceeded, SystemFdQuotaExceeded } || UnexpectedError;

/// Create a pipe. Both ends are blocking and inherited across exec, like the
/// Zig 0.15 `std.posix.pipe()`.
pub fn pipe() PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    switch (posix.errno(c.pipe(&fds))) {
        .SUCCESS => return fds,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return unexpected(err),
    }
}

pub const SetCloexecError = UnexpectedError;

/// Create a pipe whose ends are both close-on-exec, with no window in which a
/// concurrent `fork` could inherit them.
pub fn pipeCloexec() PipeError![2]fd_t {
    if (builtin.os.tag == .linux) {
        var fds: [2]fd_t = undefined;
        switch (posix.errno(c.pipe2(&fds, .{ .CLOEXEC = true }))) {
            .SUCCESS => return fds,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| return unexpected(err),
        }
    }
    forkLockShared();
    defer forkUnlockShared();
    const fds = try pipe();
    errdefer {
        close(fds[0]);
        close(fds[1]);
    }
    try setCloseOnExec(fds[0]);
    try setCloseOnExec(fds[1]);
    return fds;
}

pub fn setCloseOnExec(fd: fd_t) SetCloexecError!void {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

/// Async-signal-safe.
pub fn clearCloseOnExec(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFD, flags & ~@as(c_int, c.FD_CLOEXEC)) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

pub fn setNonBlocking(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return unexpected(posix.errno(flags));
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

pub fn clearNonBlocking(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return unexpected(posix.errno(flags));
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags & ~nonblock) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

fn isNonBlocking(fd: fd_t) bool {
    const flags = c.fcntl(fd, c.F.GETFL);
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    return flags >= 0 and (flags & nonblock) != 0;
}

pub fn isCloseOnExec(fd: fd_t) UnexpectedError!bool {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    return (flags & c.FD_CLOEXEC) != 0;
}

pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) == 1;
}

pub fn geteuid() uid_t {
    return c.geteuid();
}

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
};

/// `ioctl(2)` with the request passed at its native width. Async-signal-safe.
pub fn ioctl(fd: fd_t, request: c_ulong, arg: usize) c_int {
    return libc.ioctl(fd, request, arg);
}

// ---------------------------------------------------------------------------
// Sockets

/// Byte capacity of `sockaddr_un.sun_path`, excluding the NUL terminator.
pub const max_unix_path_len: usize = @field(@as(c.sockaddr.un, undefined), "path").len - 1;

pub const UnixAddress = struct {
    sockaddr: c.sockaddr.un,
    len: c.socklen_t,

    pub fn init(path: []const u8) error{NameTooLong}!UnixAddress {
        if (path.len > max_unix_path_len) return error.NameTooLong;
        var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        return .{ .sockaddr = addr, .len = @intCast(@sizeOf(c.sockaddr.un)) };
    }

    pub fn any(self: *const UnixAddress) *const c.sockaddr {
        return @ptrCast(&self.sockaddr);
    }
};

pub const SocketError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    AccessDenied,
    AddressFamilyNotSupported,
} || UnexpectedError;

/// Create a close-on-exec AF_UNIX stream socket.
pub fn unixStreamSocket() SocketError!fd_t {
    // Darwin has no SOCK_CLOEXEC; set FD_CLOEXEC right after creation.
    const flags: c_uint = if (is_darwin) c.SOCK.STREAM else c.SOCK.STREAM | c.SOCK.CLOEXEC;
    forkLockShared();
    defer forkUnlockShared();
    const rc = c.socket(c.AF.UNIX, flags, 0);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        else => |err| return unexpected(err),
    }
    const fd: fd_t = @intCast(rc);
    if (is_darwin) {
        setCloseOnExec(fd) catch |err| {
            close(fd);
            return err;
        };
        setNoSigPipe(fd);
    }
    return fd;
}

/// Suppress `SIGPIPE` on Darwin sockets via `SO_NOSIGPIPE` (best effort;
/// `send()` also passes `MSG_NOSIGNAL`).
fn setNoSigPipe(fd: fd_t) void {
    if (!is_darwin) return;
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
}

pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    SystemResources,
} || UnexpectedError;

pub fn bind(fd: fd_t, address: *const UnixAddress) BindError!void {
    switch (posix.errno(c.bind(fd, address.any(), address.len))) {
        .SUCCESS => {},
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

pub const ListenError = error{ AddressInUse, OperationNotSupported } || UnexpectedError;

pub fn listen(fd: fd_t, backlog: u31) ListenError!void {
    switch (posix.errno(c.listen(fd, backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => |err| return unexpected(err),
    }
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    ProtocolFailure,
    BlockedByFirewall,
} || UnexpectedError;

/// Accept one connection; the returned descriptor is close-on-exec.
pub fn accept(fd: fd_t) AcceptError!fd_t {
    while (true) {
        if (builtin.os.tag != .linux and !isNonBlocking(fd)) {
            // Wait for a connection outside the fork lock so a blocking
            // listener never holds it across an idle `accept`.
            var fds = [_]c.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
            _ = c.poll(&fds, 1, -1);
        }
        forkLockShared();
        const rc = if (builtin.os.tag == .linux)
            std.c.accept4(fd, null, null, c.SOCK.CLOEXEC)
        else
            c.accept(fd, null, null);
        const accept_errno = posix.errno(rc);
        const cloexec_ok = if (accept_errno == .SUCCESS and builtin.os.tag != .linux)
            (if (setCloseOnExec(@intCast(rc))) |_| true else |_| false)
        else
            true;
        forkUnlockShared();
        switch (accept_errno) {
            .SUCCESS => {
                const client: fd_t = @intCast(rc);
                if (!cloexec_ok) {
                    close(client);
                    return error.Unexpected;
                }
                if (is_darwin) setNoSigPipe(client);
                return client;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNABORTED => return error.ConnectionAborted,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .INVAL => return error.SocketNotListening,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return unexpected(err),
        }
    }
}

pub const ConnectError = error{
    AccessDenied,
    AddressInUse,
    ConnectionRefused,
    ConnectionResetByPeer,
    FileNotFound,
    WouldBlock,
    ConnectionTimedOut,
    NotDir,
    SystemResources,
} || UnexpectedError;

fn connectErr(err: posix.E) ConnectError {
    return switch (err) {
        .ACCES, .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .NOENT => error.FileNotFound,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NOTDIR => error.NotDir,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => unexpected(err),
    };
}

pub fn connect(fd: fd_t, address: *const UnixAddress) ConnectError!void {
    while (true) {
        switch (posix.errno(c.connect(fd, address.any(), address.len))) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return connectErr(err),
        }
    }
}

/// Create a close-on-exec socket and connect it to the UNIX socket at `path`.
pub fn connectUnix(path: []const u8) (SocketError || ConnectError || error{NameTooLong})!fd_t {
    const address = try UnixAddress.init(path);
    const fd = try unixStreamSocket();
    errdefer close(fd);
    try connect(fd, &address);
    return fd;
}

pub fn socketPair() (SocketError)![2]fd_t {
    var fds: [2]fd_t = undefined;
    switch (posix.errno(c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => return fds,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

// ---------------------------------------------------------------------------
// Filesystem metadata that `std.Io.File.Stat` does not carry (owner, device).

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

pub const StatError = error{
    AccessDenied,
    FileNotFound,
    NameTooLong,
    NotDir,
    SymLinkLoop,
    SystemResources,
    StatFieldsUnavailable,
} || UnexpectedError;

pub const cwd_fd: fd_t = c.AT.FDCWD;

/// `fstatat(2)`. `follow_symlinks = false` maps to `AT_SYMLINK_NOFOLLOW`.
pub fn statAt(dir_fd: fd_t, path: []const u8, follow_symlinks: bool) (StatError)!Stat {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    return statAtZ(dir_fd, path_z, if (follow_symlinks) 0 else c.AT.SYMLINK_NOFOLLOW);
}

/// `fstat(2)`.
pub fn fstat(fd: fd_t) StatError!Stat {
    if (builtin.os.tag == .linux) return statAtZ(fd, "", std.os.linux.AT.EMPTY_PATH);
    var st: c.Stat = undefined;
    switch (posix.errno(c.fstat(fd, &st))) {
        .SUCCESS => return fromCStat(&st),
        .ACCES => return error.AccessDenied,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

/// Set once `statx(2)` reports `ENOSYS`/`EPERM` (old kernels, seccomp
/// sandboxes); later calls go straight to `newfstatat(2)`.
var statx_unavailable: std.atomic.Value(bool) = .init(false);

/// Test seam: route every stat through the `newfstatat` fallback.
pub var force_stat_fallback: bool = false;

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

const have_stat_fallback = builtin.os.tag == .linux and KernelStat != void and
    @hasField(std.os.linux.SYS, "newfstatat");

fn statErr(err: posix.E) StatError {
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
    return .{
        .dev = (major << 32) | minor,
        .ino = st.ino,
        .mode = st.mode,
        .uid = st.uid,
    };
}

fn statAtZ(dir_fd: fd_t, path: [*:0]const u8, flags: u32) StatError!Stat {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        if (force_stat_fallback or statx_unavailable.load(.monotonic)) {
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

fn toPathZ(buf: *[posix.PATH_MAX]u8, path: []const u8) error{NameTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

// ---------------------------------------------------------------------------
// Filesystem mutation on raw paths and directory descriptors. The socket
// binding protocol needs fd-relative operations (`fchmodat`, `unlinkat`) and
// `fchmod` on a socket, none of which `std.Io.Dir` exposes.

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

pub fn fchmod(fd: fd_t, mode: mode_t) ChmodError!void {
    while (true) switch (posix.errno(c.fchmod(fd, mode))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return chmodErr(err),
    };
}

pub fn fchmodat(dir_fd: fd_t, path: []const u8, mode: mode_t) ChmodError!void {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    while (true) switch (posix.errno(c.fchmodat(dir_fd, path_z, mode, 0))) {
        .SUCCESS => return,
        .INTR => continue,
        else => |err| return chmodErr(err),
    };
}

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

pub fn unlinkAt(dir_fd: fd_t, path: []const u8) (error{ NameTooLong, FileNotFound, AccessDenied } || UnexpectedError)!void {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_z = try toPathZ(&path_buf, path);
    switch (posix.errno(c.unlinkat(dir_fd, path_z, 0))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        else => |err| return unexpected(err),
    }
}

pub fn rename(old_path: []const u8, new_path: []const u8) (error{ NameTooLong, FileNotFound, AccessDenied, NotDir, IsDir } || UnexpectedError)!void {
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
            .SUCCESS => return @intCast(rc),
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

// ---------------------------------------------------------------------------
// Processes

pub const ForkError = error{ SystemResources, ProcessLimitReached } || UnexpectedError;

/// `fork(2)`. On Darwin the fork lock is held exclusively across the call so
/// the child never inherits a descriptor that is about to become
/// close-on-exec.
pub fn fork() ForkError!pid_t {
    const locked = is_darwin and fork_lock.lockExclusiveBounded(fork_lock_budget_ms);
    const rc = c.fork();
    // Runs in both parent and child; each owns its own copy of the lock.
    if (locked) fork_lock.unlockExclusive();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.ProcessLimitReached,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

/// `PATH` used for bare program names when the environment has none.
pub const default_exec_path = "/usr/local/bin:/bin:/usr/bin";

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
// Private directories, owned files, peer credentials, deadlines, and the
// async-signal-safe child helpers (review round-1 contract §1.7).

pub const PrivateDirError = error{ NotDirectory, ForeignOwner, InsecurePermissions, SymlinkParent, NameTooLong, AccessDenied, FileNotFound, Unexpected };

const MkdirOutcome = union(enum) { created, exists, failed: posix.E };

/// `chmod` without following a final symlink where the platform supports it.
/// Best effort: `ensurePrivateDir` verifies the result on the pinned fd.
fn chmodNoFollow(path_z: [*:0]const u8, mode: mode_t) void {
    if (c.fchmodat(cwd_fd, path_z, mode, c.AT.SYMLINK_NOFOLLOW) == 0) return;
    switch (posix.errno(@as(c_int, -1))) {
        // Older libcs and kernels reject the flag outright.
        .OPNOTSUPP, .INVAL, .NOSYS => _ = c.fchmodat(cwd_fd, path_z, mode, 0),
        else => {},
    }
}

/// `mkdir(path, 0700)`. A directory we create is chmod-ed to exactly 0700 so
/// it is usable even when the process umask masks every bit.
fn mkdirPrivateZ(path_z: [*:0]const u8) MkdirOutcome {
    switch (posix.errno(c.mkdir(path_z, 0o700))) {
        .SUCCESS => {
            chmodNoFollow(path_z, 0o700);
            return .created;
        },
        .EXIST => return .exists,
        else => |err| return .{ .failed = err },
    }
}

fn privateDirErr(err: posix.E) PrivateDirError {
    return switch (err) {
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDirectory,
        .LOOP => error.SymlinkParent,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
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
    @memcpy(buf[0..trimmed.len], trimmed);
    buf[trimmed.len] = 0;
    const path_z: [*:0]const u8 = buf[0..trimmed.len :0].ptr;

    var outcome = mkdirPrivateZ(path_z);
    if (outcome == .failed and outcome.failed == .NOENT) {
        // Create missing ancestors front to back, like `mkdir -p`. Errors on
        // ancestors are ignored: the final mkdir reports what matters.
        var index: usize = 1;
        while (index < trimmed.len) : (index += 1) {
            if (buf[index] != '/') continue;
            buf[index] = 0;
            _ = mkdirPrivateZ(path_z);
            buf[index] = '/';
        }
        outcome = mkdirPrivateZ(path_z);
    }
    switch (outcome) {
        .failed => |err| return privateDirErr(err),
        .created, .exists => {},
    }

    const fd = openDirNoFollow(trimmed) catch |err| switch (err) {
        error.NameTooLong => return error.NameTooLong,
        error.AccessDenied => return error.AccessDenied,
        error.FileNotFound => return error.FileNotFound,
        // Linux reports ENOTDIR, Darwin ELOOP, for a symlink opened with
        // O_DIRECTORY|O_NOFOLLOW; lstat tells the two cases apart.
        error.NotDir, error.SymLinkLoop => {
            const st = statAt(cwd_fd, trimmed, false) catch return error.NotDirectory;
            return if (st.kind() == posix.S.IFLNK) error.SymlinkParent else error.NotDirectory;
        },
        else => return error.Unexpected,
    };
    errdefer close(fd);

    var st = fstat(fd) catch return error.Unexpected;
    if (!st.isDir()) return error.NotDirectory;
    if (st.uid != geteuid()) return error.ForeignOwner;
    if (outcome == .created and st.permissions() != 0o700) {
        fchmod(fd, 0o700) catch return error.AccessDenied;
        st = fstat(fd) catch return error.Unexpected;
    }
    if (st.permissions() & 0o077 != 0) return error.InsecurePermissions;
    return fd;
}

/// `openat(dir_fd, name, flags|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC, mode)`, then
/// require a regular file owned by euid and clear `O_NONBLOCK`. `O_NONBLOCK`
/// keeps a planted FIFO from hanging the open; `O_NOFOLLOW` rejects a symlink
/// with `SymLinkLoop`.
pub fn openOwnedRegularAt(dir_fd: fd_t, name: []const u8, flags: c.O, mode: mode_t) (OpenError || error{ NotRegularFile, ForeignOwner })!fd_t {
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const name_z = try toPathZ(&path_buf, name);
    var open_flags = flags;
    open_flags.NOFOLLOW = true;
    open_flags.NONBLOCK = true;
    open_flags.CLOEXEC = true;
    const fd: fd_t = while (true) {
        const rc = c.openat(dir_fd, name_z, open_flags, @as(c_uint, mode));
        switch (posix.errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
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
            else => |err| return unexpected(err),
        }
    };
    errdefer close(fd);
    const st = fstat(fd) catch return error.Unexpected;
    if (st.kind() != posix.S.IFREG) return error.NotRegularFile;
    if (st.uid != geteuid()) return error.ForeignOwner;
    try clearNonBlocking(fd);
    return fd;
}

extern "c" fn getpeereid(fd: fd_t, euid: *uid_t, egid: *c.gid_t) c_int;

/// Effective uid of the peer on a connected `AF_UNIX` socket.
pub fn peerEuid(fd: fd_t) error{ PeerCredentialsUnavailable, Unexpected }!uid_t {
    if (builtin.os.tag == .linux) {
        const Ucred = extern struct { pid: pid_t, uid: uid_t, gid: c.gid_t };
        var cred: Ucred = undefined;
        var len: c.socklen_t = @sizeOf(Ucred);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len) != 0) return error.PeerCredentialsUnavailable;
        if (len != @sizeOf(Ucred)) return error.PeerCredentialsUnavailable;
        return cred.uid;
    }
    if (is_darwin) {
        var uid: uid_t = undefined;
        var gid: c.gid_t = undefined;
        if (getpeereid(fd, &uid, &gid) != 0) return error.PeerCredentialsUnavailable;
        return uid;
    }
    return error.PeerCredentialsUnavailable;
}

/// Non-blocking connect + poll(POLLOUT) + SO_ERROR against the monotonic
/// `deadline_ms` (see `monotonicMs`). A listener with a full backlog makes a
/// non-blocking AF_UNIX connect fail with `EAGAIN` on Linux; that is retried
/// until the deadline. The returned socket is blocking.
pub fn connectUnixDeadline(path: []const u8, deadline_ms: i64) (SocketError || ConnectError || error{ NameTooLong, Timeout })!fd_t {
    const address = try UnixAddress.init(path);
    if (monotonicMs() >= deadline_ms) return error.Timeout;
    const fd = try unixStreamSocket();
    errdefer close(fd);
    try setNonBlocking(fd);

    attempt: while (true) {
        switch (posix.errno(c.connect(fd, address.any(), address.len))) {
            .SUCCESS, .ISCONN => break :attempt,
            // The connection continues asynchronously (EINTR included).
            .INTR, .INPROGRESS, .ALREADY => {
                while (true) {
                    const remaining = deadline_ms - monotonicMs();
                    if (remaining <= 0) return error.Timeout;
                    var fds = [_]c.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                    const ready = c.poll(&fds, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
                    if (ready > 0) break;
                    if (ready < 0 and posix.errno(ready) != .INTR) return error.Unexpected;
                }
                var so_error: c_int = 0;
                var len: c.socklen_t = @sizeOf(c_int);
                if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len) != 0) return error.Unexpected;
                if (so_error != 0) return connectErr(@fromBackingInt(@intCast(so_error)));
                break :attempt;
            },
            .AGAIN => {
                const remaining = deadline_ms - monotonicMs();
                if (remaining <= 0) return error.Timeout;
                sleepMs(@min(remaining, 5));
            },
            else => |err| return connectErr(err),
        }
    }

    try clearNonBlocking(fd);
    return fd;
}

/// `flock(LOCK_EX)` polled with `LOCK_NB` until the monotonic `deadline_ms`
/// or until `stop` becomes true, so a contended lock never blocks shutdown.
pub fn flockExclusiveDeadline(fd: fd_t, deadline_ms: i64, stop: ?*const std.atomic.Value(bool)) error{ Timeout, Interrupted, Unexpected }!void {
    while (true) {
        if (stop) |flag| if (flag.load(.seq_cst)) return error.Interrupted;
        switch (posix.errno(c.flock(fd, posix.LOCK.EX | posix.LOCK.NB))) {
            .SUCCESS => return,
            .INTR, .AGAIN => {},
            else => return error.Unexpected,
        }
        const remaining = deadline_ms - monotonicMs();
        if (remaining <= 0) return error.Timeout;
        sleepMs(@min(remaining, 10));
    }
}

/// Milliseconds on the monotonic (awake) clock.
pub fn monotonicMs() i64 {
    return std.Io.Clock.awake.now(std.Options.debug_io).toMilliseconds();
}

/// Async-signal-safe. Close every descriptor `>= low_fd`: `close_range(2)` on
/// Linux, otherwise (and on kernels without it) a loop bounded by
/// `RLIMIT_NOFILE`, capped so an unlimited rlimit cannot stall the child.
pub fn closeFrom(low_fd: fd_t) void {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.close_range(low_fd, std.math.maxInt(fd_t), .{ .UNSHARE = false, .CLOEXEC = false });
        if (std.os.linux.errno(rc) == .SUCCESS) return;
    }
    var limit: c.rlimit = undefined;
    const max_fd: fd_t = if (c.getrlimit(.NOFILE, &limit) == 0)
        @intCast(@min(limit.cur, 65536))
    else
        1024;
    var fd = low_fd;
    while (fd < max_fd) : (fd += 1) _ = c.close(fd);
}

/// Signals `resetChildSignals` restores to `SIG_DFL`.
pub const child_reset_signals = [_]posix.SIG{ .HUP, .INT, .QUIT, .TERM, .PIPE, .CHLD, .TSTP, .TTIN, .TTOU, .WINCH };

/// Async-signal-safe. Restore default dispositions for job-control and
/// termination signals and clear the signal mask, so a pane child does not
/// inherit the daemon's ignored `SIGHUP`/`SIGPIPE` or a blocked mask.
pub fn resetChildSignals() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (child_reset_signals) |sig| posix.sigaction(sig, &act, null);
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
}

// ---------------------------------------------------------------------------
// Tests

const TestDir = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    var counter: std.atomic.Value(u32) = .init(0);

    /// Create a fresh 0700 directory under /tmp owned by the test process.
    fn create(tag: []const u8) !TestDir {
        var dir: TestDir = .{};
        const created = try std.fmt.bufPrint(&dir.buf, "/tmp/zmux-sys-{s}-{d}-{d}-{d}", .{
            tag, getpid(), monotonicMs(), counter.fetchAdd(1, .seq_cst),
        });
        dir.len = created.len;
        try mkdir(created, 0o700);
        try fchmodat(cwd_fd, created, 0o700);
        return dir;
    }

    fn path(self: *const TestDir) []const u8 {
        return self.buf[0..self.len];
    }

    fn join(self: *const TestDir, buf: []u8, name: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.path(), name }) catch unreachable;
    }

    fn remove(self: *const TestDir, names: []const []const u8) void {
        var buf: [256]u8 = undefined;
        for (names) |name| {
            const child = self.join(&buf, name);
            unlinkAt(cwd_fd, child) catch {};
            rmdir(child) catch {};
        }
        rmdir(self.path()) catch {};
    }
};

fn testSymlink(target: []const u8, link_path: []const u8) !void {
    var target_buf: [posix.PATH_MAX]u8 = undefined;
    var link_buf: [posix.PATH_MAX]u8 = undefined;
    const target_z = try toPathZ(&target_buf, target);
    const link_z = try toPathZ(&link_buf, link_path);
    if (c.symlink(target_z, link_z) != 0) return error.SymlinkFailed;
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: mode_t) c_int;

test "unix address rejects paths longer than sun_path" {
    const too_long: [max_unix_path_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, UnixAddress.init(&too_long));
    const at_limit: [max_unix_path_len]u8 = @splat('x');
    _ = try UnixAddress.init(&at_limit);
}

test "stat reports directory kind, owner and permissions" {
    // Assert against a directory this test created, not the cwd, which may be
    // owned by another user in CI checkouts.
    const dir = try TestDir.create("stat");
    defer dir.remove(&.{});
    const st = try statAt(cwd_fd, dir.path(), true);
    try std.testing.expect(st.isDir());
    try std.testing.expectEqual(geteuid(), st.uid);
    try std.testing.expectEqual(@as(u32, 0o700), st.permissions());
}

test "stat fallback matches statx for file, dir, socket and symlink" {
    if (!have_stat_fallback) return error.SkipZigTest;

    const dir = try TestDir.create("statfb");
    defer dir.remove(&.{ "file", "sub", "sock", "link" });
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;

    const file_fd = try open(dir.join(&buf, "file"), .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600);
    defer close(file_fd);
    try mkdir(dir.join(&buf, "sub"), 0o700);
    const sock = try unixStreamSocket();
    defer close(sock);
    const address = try UnixAddress.init(dir.join(&buf, "sock"));
    try bind(sock, &address);
    try testSymlink(dir.join(&buf, "file"), dir.join(&buf2, "link"));

    defer force_stat_fallback = false;
    for ([_][]const u8{ "file", "sub", "sock", "link" }) |name| {
        const target = dir.join(&buf, name);
        for ([_]bool{ true, false }) |follow| {
            force_stat_fallback = false;
            const via_statx = try statAt(cwd_fd, target, follow);
            force_stat_fallback = true;
            const via_fallback = try statAt(cwd_fd, target, follow);
            try std.testing.expectEqual(via_statx, via_fallback);
        }
    }
    // The symlink itself is reported only when not following.
    force_stat_fallback = true;
    const link_stat = try statAt(cwd_fd, dir.join(&buf, "link"), false);
    try std.testing.expectEqual(@as(u32, posix.S.IFLNK), link_stat.kind());

    // fstat goes through the same fallback (AT_EMPTY_PATH).
    const fd_fallback = try fstat(file_fd);
    force_stat_fallback = false;
    try std.testing.expectEqual(try fstat(file_fd), fd_fallback);
}

test "unix stream sockets are close-on-exec" {
    const fd = try unixStreamSocket();
    defer close(fd);
    try std.testing.expect(try isCloseOnExec(fd));
}

test "pipeCloexec marks both ends close-on-exec" {
    const fds = try pipeCloexec();
    defer close(fds[0]);
    defer close(fds[1]);
    try std.testing.expect(try isCloseOnExec(fds[0]));
    try std.testing.expect(try isCloseOnExec(fds[1]));
}

test "pipe round-trips bytes and reports end of stream" {
    const fds = try pipe();
    defer close(fds[0]);
    try writeAll(fds[1], "ping");
    close(fds[1]);

    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try read(fds[0], &buffer));
    try std.testing.expectEqualStrings("ping", buffer[0..4]);
    try std.testing.expectEqual(@as(usize, 0), try read(fds[0], &buffer));
}

test "sendAll returns BrokenPipe without SIGPIPE on a closed socket" {
    const sockets = try socketPair();
    defer close(sockets[0]);
    close(sockets[1]);

    try std.testing.expectError(error.BrokenPipe, sendAll(sockets[0], "hello"));
}

test "execvpeZ reports a missing program without replacing the process" {
    const argv = [_:null]?[*:0]const u8{"zmux-no-such-program"};
    const envp = [_:null]?[*:0]const u8{};
    try std.testing.expectEqual(error.FileNotFound, execvpeZ("zmux-no-such-program", &argv, &envp));
    try std.testing.expectEqual(error.FileNotFound, execvpeZ("/zmux/no/such/program", &argv, &envp));
}

test "dup2 onto the same descriptor clears close-on-exec" {
    const fds = try pipeCloexec();
    defer close(fds[0]);
    defer close(fds[1]);
    try std.testing.expect(try isCloseOnExec(fds[0]));
    try dup2(fds[0], fds[0]);
    try std.testing.expect(!(try isCloseOnExec(fds[0])));

    // A distinct target is a plain dup2 and never inherits FD_CLOEXEC.
    try dup2(fds[1], fds[0]);
    try std.testing.expect(!(try isCloseOnExec(fds[0])));
    try std.testing.expectError(error.Unexpected, dup2(-1, fds[0]));
}

test "clearCloseOnExec and setCloseOnExec round-trip" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try setCloseOnExec(fds[0]);
    try std.testing.expect(try isCloseOnExec(fds[0]));
    try clearCloseOnExec(fds[0]);
    try std.testing.expect(!(try isCloseOnExec(fds[0])));
}

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

    const fd = try ensurePrivateDir(nested);
    defer close(fd);
    const pinned = try fstat(fd);
    try std.testing.expect(pinned.isDir());
    try std.testing.expectEqual(@as(u32, 0o700), pinned.permissions());
    try std.testing.expectEqual(geteuid(), pinned.uid);
    try std.testing.expect(try isCloseOnExec(fd));
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

    const fd = try result;
    defer close(fd);
    try std.testing.expectEqual(@as(u32, 0o700), (try fstat(fd)).permissions());
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
    try fchmodat(cwd_fd, loose, 0o755);
    try std.testing.expectError(error.InsecurePermissions, ensurePrivateDir(loose));
    try std.testing.expectEqual(@as(u32, 0o755), (try statAt(cwd_fd, loose, false)).permissions());

    // A symlink to a perfectly private directory is still refused.
    const target = dir.join(&buf, "target");
    try mkdir(target, 0o700);
    try fchmodat(cwd_fd, target, 0o700);
    const link_path = dir.join(&buf2, "link");
    try testSymlink(target, link_path);
    try std.testing.expectError(error.SymlinkParent, ensurePrivateDir(link_path));

    // A regular file is not a directory, as a final or middle component.
    const file_path = dir.join(&buf, "file");
    close(try open(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o600));
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
    const dir_fd = try openDirNoFollow(dir.path());
    defer close(dir_fd);

    const fd = try openOwnedRegularAt(dir_fd, "file", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
    defer close(fd);
    try std.testing.expect(!isNonBlocking(fd));
    try std.testing.expect(try isCloseOnExec(fd));
    try writeAll(fd, "x");
    try std.testing.expectError(error.FileNotFound, openOwnedRegularAt(dir_fd, "missing", .{ .ACCMODE = .RDONLY }, 0));
}

test "openOwnedRegularAt rejects symlinks, FIFOs and directories without hanging" {
    const dir = try TestDir.create("ownrej");
    defer dir.remove(&.{ "file", "link", "fifo", "sub" });
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    const dir_fd = try openDirNoFollow(dir.path());
    defer close(dir_fd);

    close(try openOwnedRegularAt(dir_fd, "file", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600));
    try testSymlink(dir.join(&buf, "file"), dir.join(&buf2, "link"));
    try std.testing.expectError(error.SymLinkLoop, openOwnedRegularAt(dir_fd, "link", .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expectError(error.SymLinkLoop, openOwnedRegularAt(dir_fd, "link", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600));

    var fifo_buf: [posix.PATH_MAX]u8 = undefined;
    const fifo_z = try toPathZ(&fifo_buf, dir.join(&buf, "fifo"));
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

test "peerEuid reports the euid of a socketpair peer" {
    const sockets = try socketPair();
    defer close(sockets[0]);
    defer close(sockets[1]);
    try std.testing.expectEqual(geteuid(), try peerEuid(sockets[0]));
    try std.testing.expectEqual(geteuid(), try peerEuid(sockets[1]));

    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try std.testing.expectError(error.PeerCredentialsUnavailable, peerEuid(fds[0]));
}

test "connectUnixDeadline connects, reports missing sockets, and honours an expired deadline" {
    const dir = try TestDir.create("conn");
    defer dir.remove(&.{"sock"});
    var buf: [256]u8 = undefined;
    const path = dir.join(&buf, "sock");

    try std.testing.expectError(error.FileNotFound, connectUnixDeadline(path, monotonicMs() + 500));

    const listener = try unixStreamSocket();
    defer close(listener);
    const address = try UnixAddress.init(path);
    try bind(listener, &address);
    try listen(listener, 8);

    const client = try connectUnixDeadline(path, monotonicMs() + 1000);
    defer close(client);
    try std.testing.expect(!isNonBlocking(client));
    try std.testing.expect(try isCloseOnExec(client));
    const accepted = try accept(listener);
    defer close(accepted);
    try sendAll(client, "hi");
    var byte: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try read(accepted, &byte));

    try std.testing.expectError(error.Timeout, connectUnixDeadline(path, monotonicMs() - 1));
    const too_long: [max_unix_path_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, connectUnixDeadline(&too_long, monotonicMs() + 1000));
}

test "connectUnixDeadline times out against a full backlog" {
    // Linux queues backlog+1 connections and then makes a non-blocking
    // connect report EAGAIN; Darwin refuses instead, so the timing assertion
    // is Linux-only.
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const dir = try TestDir.create("backlog");
    defer dir.remove(&.{"sock"});
    var buf: [256]u8 = undefined;
    const path = dir.join(&buf, "sock");

    const listener = try unixStreamSocket();
    defer close(listener);
    const address = try UnixAddress.init(path);
    try bind(listener, &address);
    try listen(listener, 0);

    var held: [8]fd_t = undefined;
    var held_count: usize = 0;
    defer for (held[0..held_count]) |fd| close(fd);

    var timed_out = false;
    while (held_count < held.len) {
        const started = monotonicMs();
        if (connectUnixDeadline(path, started + 150)) |fd| {
            held[held_count] = fd;
            held_count += 1;
        } else |err| {
            try std.testing.expectEqual(error.Timeout, err);
            const elapsed = monotonicMs() - started;
            try std.testing.expect(elapsed >= 150);
            try std.testing.expect(elapsed <= 200);
            timed_out = true;
            break;
        }
    }
    try std.testing.expect(timed_out);
}

const FlockReleaser = struct {
    fd: fd_t,
    delay_ms: i64,
    stop: ?*std.atomic.Value(bool) = null,

    fn run(self: *FlockReleaser) void {
        sleepMs(self.delay_ms);
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
    const holder = try open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    defer close(holder);
    const waiter = try open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
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

test "monotonicMs never goes backwards and sleepMs waits" {
    const before = monotonicMs();
    sleepMs(20);
    const after = monotonicMs();
    try std.testing.expect(after - before >= 19);
}

test "fork lock excludes exclusive holders while shared holders exist" {
    var lock: ForkLock = .{};
    lock.lockShared();
    lock.lockShared();
    try std.testing.expect(!lock.lockExclusiveBounded(20));
    lock.unlockShared();
    lock.unlockShared();
    try std.testing.expect(lock.lockExclusiveBounded(20));
    try std.testing.expect(!lock.lockExclusiveBounded(5));
    lock.unlockExclusive();
    lock.lockShared();
    lock.unlockShared();
}

test "kill wrapper counts calls and reports failures" {
    const before = kill_call_count.load(.seq_cst);
    // Signal 0 probes for existence without delivering anything.
    try std.testing.expect(kill(getpid(), @fromBackingInt(@intCast(0))));
    try std.testing.expectEqual(before + 1, kill_call_count.load(.seq_cst));
}

/// Fork a child that runs `body` and reports one status byte via `_exit`.
fn forkAndCollect(comptime body: fn () u8) !u8 {
    const pid = try fork();
    if (pid == 0) c._exit(body());
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, 0);
        if (rc == pid) break;
        if (posix.errno(rc) != .INTR) return error.WaitFailed;
    }
    const raw: u32 = @bitCast(status);
    if (!posix.W.IFEXITED(raw)) return error.ChildCrashed;
    return posix.W.EXITSTATUS(raw);
}

fn closeFromChildBody() u8 {
    // Fds 40 and 60 were opened by the parent; after closeFrom(41) only 40
    // may survive.
    closeFrom(41);
    if (c.fcntl(40, c.F.GETFD) < 0) return 1;
    if (c.fcntl(60, c.F.GETFD) >= 0) return 2;
    if (c.fcntl(41, c.F.GETFD) >= 0) return 3;
    closeFrom(3);
    if (c.fcntl(40, c.F.GETFD) >= 0) return 4;
    if (c.fcntl(2, c.F.GETFD) < 0) return 5;
    return 0;
}

test "closeFrom closes every descriptor at or above the floor" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try dup2(fds[0], 40);
    defer close(40);
    try dup2(fds[0], 41);
    defer close(41);
    try dup2(fds[1], 60);
    defer close(60);

    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(closeFromChildBody));
    // The parent's descriptors are untouched.
    try std.testing.expect(c.fcntl(60, c.F.GETFD) >= 0);
}

fn signalResetChildBody() u8 {
    resetChildSignals();
    for (child_reset_signals, 0..) |sig, index| {
        var current: posix.Sigaction = undefined;
        posix.sigaction(sig, null, &current);
        if (current.handler.handler != posix.SIG.DFL) return @intCast(10 + index);
    }
    var mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.SETMASK, null, &mask);
    if (!std.mem.eql(u8, std.mem.asBytes(&mask), std.mem.asBytes(&posix.sigemptyset()))) return 1;
    return 0;
}

test "resetChildSignals restores default dispositions and an empty mask" {
    // Give the forked child something to undo: ignored HUP/PIPE and a blocked
    // TERM, as a daemon would have.
    const ignore: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old_hup: posix.Sigaction = undefined;
    var old_pipe: posix.Sigaction = undefined;
    posix.sigaction(.HUP, &ignore, &old_hup);
    defer posix.sigaction(.HUP, &old_hup, null);
    posix.sigaction(.PIPE, &ignore, &old_pipe);
    defer posix.sigaction(.PIPE, &old_pipe, null);

    var blocked = posix.sigemptyset();
    posix.sigaddset(&blocked, .TERM);
    var old_mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &blocked, &old_mask);
    defer posix.sigprocmask(posix.SIG.SETMASK, &old_mask, null);

    try std.testing.expectEqual(@as(u8, 0), try forkAndCollect(signalResetChildBody));
}

test "ioctl wrapper reports ENOTTY for a non-terminal" {
    const fds = try pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    var wsz: posix.winsize = undefined;
    try std.testing.expect(ioctl(fds[0], posix.T.IOCGWINSZ, @intFromPtr(&wsz)) != 0);
}
