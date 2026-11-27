//! `AF_UNIX` stream sockets: addresses, create, bind, listen, accept,
//! connect (plain and deadline-bounded), socket pairs, and peer credentials.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../sys.zig");
const fd = @import("fd.zig");

const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const fd_t = sys.fd_t;
const pid_t = sys.pid_t;
const uid_t = sys.uid_t;
const UnexpectedError = sys.UnexpectedError;
const unexpected = fd.unexpected;
const close = fd.close;

const is_darwin = builtin.os.tag.isDarwin();

/// Byte capacity of `sockaddr_un.sun_path`, excluding the NUL terminator.
pub const max_unix_path_len: usize = @field(@as(c.sockaddr.un, undefined), "path").len - 1;

/// A `sockaddr_un` for a filesystem `AF_UNIX` socket path.
pub const UnixAddress = struct {
    sockaddr: c.sockaddr.un,
    len: c.socklen_t,

    pub fn init(path: []const u8) error{NameTooLong}!UnixAddress {
        if (path.len > max_unix_path_len) return error.NameTooLong;
        var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);
        assert(path.len < addr.path.len);
        assert(addr.path[path.len] == 0);
        return .{ .sockaddr = addr, .len = @intCast(@sizeOf(c.sockaddr.un)) };
    }

    pub fn any(self: *const UnixAddress) *const c.sockaddr {
        return @ptrCast(&self.sockaddr);
    }
};

/// Errors from creating a socket or socket pair.
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
    fd.forkLockShared();
    defer fd.forkUnlockShared();
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
    const socket: fd_t = @intCast(rc);
    assert(socket >= 0);
    if (is_darwin) {
        fd.setCloseOnExec(socket) catch |err| {
            close(socket);
            return err;
        };
        setNoSigPipe(socket);
    }
    return socket;
}

/// Suppress `SIGPIPE` on Darwin sockets via `SO_NOSIGPIPE` (best effort;
/// `send()` also passes `MSG_NOSIGNAL`).
fn setNoSigPipe(socket: fd_t) void {
    if (!is_darwin) return;
    assert(socket >= 0);
    const one: c_int = 1;
    _ = c.setsockopt(socket, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
}

/// Raise `SO_SNDBUF` and `SO_RCVBUF` on local UNIX stream sockets (best effort).
/// macOS defaults `AF_UNIX` buffers to 8 KiB, forcing dozens of blocking thread
/// wakeups on 64–256 KiB scrollback replays and PTY output bursts; 256 KiB lets
/// typical frames complete in 1–2 syscalls.
pub fn tuneUnixSocketBuffers(socket: fd_t) void {
    const size: c_int = 256 * 1024;
    _ = c.setsockopt(socket, c.SOL.SOCKET, c.SO.SNDBUF, &size, @sizeOf(c_int));
    _ = c.setsockopt(socket, c.SOL.SOCKET, c.SO.RCVBUF, &size, @sizeOf(c_int));
}

/// Errors from `bind`.
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

/// `bind(2)` `socket` to the UNIX socket `address`.
pub fn bind(socket: fd_t, address: *const UnixAddress) BindError!void {
    assert(address.sockaddr.family == c.AF.UNIX);
    switch (posix.errno(c.bind(socket, address.any(), address.len))) {
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

/// Errors from `listen`.
pub const ListenError = error{ AddressInUse, OperationNotSupported } || UnexpectedError;

/// `listen(2)` on `socket` with at most `backlog` pending connections.
pub fn listen(socket: fd_t, backlog: u31) ListenError!void {
    switch (posix.errno(c.listen(socket, backlog))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => |err| return unexpected(err),
    }
}

/// Errors from `accept`.
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
pub fn accept(listener: fd_t) AcceptError!fd_t {
    while (true) {
        if (builtin.os.tag != .linux and !fd.isNonBlocking(listener)) {
            // Wait for a connection outside the fork lock so a blocking
            // listener never holds it across an idle `accept`.
            var fds = [_]c.pollfd{.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 }};
            _ = c.poll(&fds, 1, -1);
        }
        fd.forkLockShared();
        const rc = if (builtin.os.tag == .linux)
            std.c.accept4(listener, null, null, c.SOCK.CLOEXEC)
        else
            c.accept(listener, null, null);
        const accept_errno = posix.errno(rc);
        const cloexec_ok = if (accept_errno == .SUCCESS and builtin.os.tag != .linux)
            (if (fd.setCloseOnExec(@intCast(rc))) |_| true else |_| false)
        else
            true;
        fd.forkUnlockShared();
        switch (accept_errno) {
            .SUCCESS => {
                const client: fd_t = @intCast(rc);
                assert(client >= 0);
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

/// Errors from `connect` and the `connectUnix*` helpers.
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
    assert(err != .SUCCESS);
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

/// `connect(2)` `socket` to the UNIX socket `address`, retrying `EINTR`.
pub fn connect(socket: fd_t, address: *const UnixAddress) ConnectError!void {
    assert(address.sockaddr.family == c.AF.UNIX);
    while (true) {
        switch (posix.errno(c.connect(socket, address.any(), address.len))) {
            .SUCCESS => return,
            .INTR => continue,
            else => |err| return connectErr(err),
        }
    }
}

/// Create a close-on-exec socket and connect it to the UNIX socket at `path`.
pub fn connectUnix(path: []const u8) (SocketError || ConnectError || error{NameTooLong})!fd_t {
    const address = try UnixAddress.init(path);
    const socket = try unixStreamSocket();
    errdefer close(socket);
    try connect(socket, &address);
    tuneUnixSocketBuffers(socket);
    return socket;
}

/// A connected pair of `AF_UNIX` stream sockets. Both ends are inherited
/// across exec.
pub fn socketPair() (SocketError)![2]fd_t {
    var fds: [2]fd_t = undefined;
    switch (posix.errno(c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds))) {
        .SUCCESS => {
            assert(fds[0] != fds[1]);
            return fds;
        },
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => |err| return unexpected(err),
    }
}

extern "c" fn getpeereid(sock_fd: fd_t, euid: *uid_t, egid: *c.gid_t) c_int;

/// Effective uid of the peer on a connected `AF_UNIX` socket.
pub fn peerEuid(socket: fd_t) error{ PeerCredentialsUnavailable, Unexpected }!uid_t {
    if (builtin.os.tag == .linux) {
        const Ucred = extern struct { pid: pid_t, uid: uid_t, gid: c.gid_t };
        var cred: Ucred = undefined;
        var len: c.socklen_t = @sizeOf(Ucred);
        const rc = c.getsockopt(socket, c.SOL.SOCKET, c.SO.PEERCRED, &cred, &len);
        if (rc != 0) return error.PeerCredentialsUnavailable;
        if (len != @sizeOf(Ucred)) return error.PeerCredentialsUnavailable;
        return cred.uid;
    }
    if (is_darwin) {
        var uid: uid_t = undefined;
        var gid: c.gid_t = undefined;
        if (getpeereid(socket, &uid, &gid) != 0) return error.PeerCredentialsUnavailable;
        return uid;
    }
    return error.PeerCredentialsUnavailable;
}

/// Wait for an in-progress connect on `socket` and report its `SO_ERROR`.
fn awaitConnect(socket: fd_t, deadline_ms: i64) (ConnectError || error{Timeout})!void {
    while (true) {
        const remaining = deadline_ms - fd.monotonicMs();
        if (remaining <= 0) return error.Timeout;
        var fds = [_]c.pollfd{.{ .fd = socket, .events = posix.POLL.OUT, .revents = 0 }};
        const ready = c.poll(&fds, 1, @intCast(@min(remaining, std.math.maxInt(c_int))));
        if (ready > 0) break;
        if (ready < 0 and posix.errno(ready) != .INTR) return error.Unexpected;
    }
    var so_error: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(socket, c.SOL.SOCKET, c.SO.ERROR, &so_error, &len) != 0) return error.Unexpected;
    if (so_error != 0) return connectErr(@fromBackingInt(@intCast(so_error)));
}

/// Non-blocking connect + poll(POLLOUT) + SO_ERROR against the monotonic
/// `deadline_ms` (see `monotonicMs`). A listener with a full backlog makes a
/// non-blocking AF_UNIX connect fail with `EAGAIN` on Linux; that is retried
/// until the deadline. The returned socket is blocking.
pub fn connectUnixDeadline(
    path: []const u8,
    deadline_ms: i64,
) (SocketError || ConnectError || error{ NameTooLong, Timeout })!fd_t {
    const address = try UnixAddress.init(path);
    if (fd.monotonicMs() >= deadline_ms) return error.Timeout;
    const socket = try unixStreamSocket();
    errdefer close(socket);
    try fd.setNonBlocking(socket);

    attempt: while (true) {
        switch (posix.errno(c.connect(socket, address.any(), address.len))) {
            .SUCCESS, .ISCONN => break :attempt,
            // The connection continues asynchronously (EINTR included).
            .INTR, .INPROGRESS, .ALREADY => {
                try awaitConnect(socket, deadline_ms);
                break :attempt;
            },
            .AGAIN => {
                const remaining = deadline_ms - fd.monotonicMs();
                if (remaining <= 0) return error.Timeout;
                fd.sleepMs(@min(remaining, 5));
            },
            else => |err| return connectErr(err),
        }
    }

    try fd.clearNonBlocking(socket);
    assert(socket >= 0);
    return socket;
}

const TestDir = @import("fs.zig").TestDir;

test "unix address rejects paths longer than sun_path" {
    const too_long: [max_unix_path_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, UnixAddress.init(&too_long));
    const at_limit: [max_unix_path_len]u8 = @splat('x');
    _ = try UnixAddress.init(&at_limit);
}

test "unix stream sockets are close-on-exec" {
    const socket = try unixStreamSocket();
    defer close(socket);
    try std.testing.expect(try fd.isCloseOnExec(socket));
}

test "sendAll returns BrokenPipe without SIGPIPE on a closed socket" {
    const sockets = try socketPair();
    defer close(sockets[0]);
    close(sockets[1]);

    try std.testing.expectError(error.BrokenPipe, fd.sendAll(sockets[0], "hello"));
}

test "peerEuid reports the euid of a socketpair peer" {
    const sockets = try socketPair();
    defer close(sockets[0]);
    defer close(sockets[1]);
    try std.testing.expectEqual(sys.geteuid(), try peerEuid(sockets[0]));
    try std.testing.expectEqual(sys.geteuid(), try peerEuid(sockets[1]));

    const fds = try fd.pipe();
    defer close(fds[0]);
    defer close(fds[1]);
    try std.testing.expectError(error.PeerCredentialsUnavailable, peerEuid(fds[0]));
}

test "connectUnixDeadline connects, reports missing sockets, and honours an expired deadline" {
    const monotonicMs = fd.monotonicMs;
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
    try std.testing.expect(!fd.isNonBlocking(client));
    try std.testing.expect(try fd.isCloseOnExec(client));
    const accepted = try accept(listener);
    defer close(accepted);
    try fd.sendAll(client, "hi");
    var byte: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try sys.read(accepted, &byte));

    try std.testing.expectError(error.Timeout, connectUnixDeadline(path, monotonicMs() - 1));
    const too_long: [max_unix_path_len + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, connectUnixDeadline(&too_long, monotonicMs() + 1000));
}

test "connectUnixDeadline times out against a full backlog" {
    // Linux queues backlog+1 connections and then makes a non-blocking
    // connect report EAGAIN; Darwin refuses instead, so the timing assertion
    // is Linux-only.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const monotonicMs = fd.monotonicMs;

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
    defer for (held[0..held_count]) |held_fd| close(held_fd);

    var timed_out = false;
    while (held_count < held.len) {
        const started = monotonicMs();
        if (connectUnixDeadline(path, started + 150)) |client| {
            held[held_count] = client;
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
