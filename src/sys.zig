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

fn unexpected(err: posix.E) UnexpectedError {
    return posix.unexpectedErrno(err);
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
pub fn dup2(old_fd: fd_t, new_fd: fd_t) UnexpectedError!void {
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

pub fn setCloseOnExec(fd: fd_t) SetCloexecError!void {
    const flags = c.fcntl(fd, c.F.GETFD);
    if (flags < 0) return unexpected(posix.errno(flags));
    if (c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0) return unexpected(posix.errno(@as(c_int, -1)));
}

pub fn setNonBlocking(fd: fd_t) UnexpectedError!void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return unexpected(posix.errno(flags));
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return unexpected(posix.errno(@as(c_int, -1)));
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

/// Raise `SO_SNDBUF` and `SO_RCVBUF` on local UNIX stream sockets (best effort).
/// macOS defaults `AF_UNIX` buffers to 8 KiB, forcing dozens of blocking thread
/// wakeups on 64–256 KiB scrollback replays and PTY output bursts; 256 KiB lets
/// typical frames complete in 1–2 syscalls.
pub fn tuneUnixSocketBuffers(fd: fd_t) void {
    const size: c_int = 256 * 1024;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDBUF, &size, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVBUF, &size, @sizeOf(c_int));
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
        const rc = if (builtin.os.tag == .linux)
            std.c.accept4(fd, null, null, c.SOCK.CLOEXEC)
        else
            c.accept(fd, null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                const client: fd_t = @intCast(rc);
                if (builtin.os.tag != .linux) setCloseOnExec(client) catch |err| {
                    close(client);
                    return err;
                };
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

pub fn connect(fd: fd_t, address: *const UnixAddress) ConnectError!void {
    while (true) {
        switch (posix.errno(c.connect(fd, address.any(), address.len))) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES, .PERM => return error.AccessDenied,
            .ADDRINUSE => return error.AddressInUse,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .NOENT => return error.FileNotFound,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOTDIR => return error.NotDir,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => |err| return unexpected(err),
        }
    }
}

/// Create a close-on-exec socket and connect it to the UNIX socket at `path`.
pub fn connectUnix(path: []const u8) (SocketError || ConnectError || error{NameTooLong})!fd_t {
    const address = try UnixAddress.init(path);
    const fd = try unixStreamSocket();
    errdefer close(fd);
    try connect(fd, &address);
    tuneUnixSocketBuffers(fd);
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

fn statAtZ(dir_fd: fd_t, path: [*:0]const u8, flags: u32) StatError!Stat {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
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
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NAMETOOLONG => return error.NameTooLong,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .NOMEM => return error.SystemResources,
            else => |err| return unexpected(err),
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

pub fn fork() ForkError!pid_t {
    const rc = c.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.ProcessLimitReached,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

pub const ExecError = error{
    AccessDenied,
    FileNotFound,
    NameTooLong,
    InvalidExe,
    SystemResources,
} || UnexpectedError;

/// `execvpe(3)` semantics without allocation, safe to call between `fork` and
/// `exec`: a `file` containing '/' is executed directly; otherwise each `PATH`
/// entry (from the calling process environment, defaulting to
/// `/usr/local/bin:/bin:/usr/bin`) is tried in order. Only returns on failure.
pub fn execvpeZ(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError {
    const file_slice = std.mem.sliceTo(file, 0);
    if (std.mem.indexOfScalar(u8, file_slice, '/') != null) {
        return execErr(posix.errno(c.execve(file, argv, envp)));
    }

    const path_env: []const u8 = if (c.getenv("PATH")) |value| std.mem.sliceTo(value, 0) else "/usr/local/bin:/bin:/usr/bin";
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    var last: ExecError = error.FileNotFound;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
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

test "unix address rejects paths longer than sun_path" {
    const too_long: [max_unix_path_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, UnixAddress.init(&too_long));
    const at_limit: [max_unix_path_len]u8 = @splat('x');
    _ = try UnixAddress.init(&at_limit);
}

test "stat reports directory kind, owner and permissions" {
    const st = try statAt(cwd_fd, ".", true);
    try std.testing.expect(st.isDir());
    try std.testing.expectEqual(geteuid(), st.uid);
}

test "unix stream sockets are close-on-exec" {
    const fd = try unixStreamSocket();
    defer close(fd);
    try std.testing.expect(try isCloseOnExec(fd));
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
