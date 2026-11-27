//! Terminal raw mode, signal handlers, window size, and descriptor I/O
//! helpers shared by the bootstrap exchange and the run loop.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const assert = std.debug.assert;
const log = @import("../log.zig");
const sys = @import("../sys.zig");
const wire = @import("wire.zig");

const outbound_max = wire.outbound_max;
const write_timeout_ms = wire.write_timeout_ms;
const decodeReplay = wire.decodeReplay;

var g_terminal_active = std.atomic.Value(bool).init(false);
var g_saved_termios: posix.termios = undefined;
var g_raw_termios: posix.termios = undefined;
var g_saved_termios_fd: posix.fd_t = 0;
/// True while the saved termios must be restored.
pub var g_termios_saved = std.atomic.Value(bool).init(false);
var g_restore_output = std.atomic.Value(bool).init(false);
var g_output_fd: posix.fd_t = 1;
var g_output_flags: c_int = 0;
/// Set by SIGWINCH and on resume; the run loop then resends the size.
pub var g_winch_flag = std.atomic.Value(bool).init(false);
/// Set when `restoreTerminal` could not reapply the saved termios.
var g_restore_failed = std.atomic.Value(bool).init(false);

/// Install the terminal signal handlers and enter raw mode with those signals
/// blocked. The caller must `leaveTerminal` even when this fails.
pub fn enterTerminalGuarded(stdin_fd: posix.fd_t, stdout_fd: posix.fd_t, is_tty: bool) !void {
    var previous_mask: posix.sigset_t = undefined;
    const signals = terminalSignalSet();
    posix.sigprocmask(posix.SIG.BLOCK, &signals, &previous_mask);
    installTerminalHandlers();
    g_terminal_active.store(true, .seq_cst);
    const setup = enterTerminal(stdin_fd, stdout_fd, is_tty);
    posix.sigprocmask(posix.SIG.SETMASK, &previous_mask, null);
    return setup;
}

/// Bounded outbound bytes toward the daemon with a write deadline.
pub const WriteQueue = struct {
    bytes: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    deadline: i64 = 0,

    pub fn pending(self: *const WriteQueue) []const u8 {
        assert(self.sent <= self.bytes.items.len);
        return self.bytes.items[self.sent..];
    }

    pub fn append(self: *WriteQueue, allocator: std.mem.Allocator, frame: []const u8) !void {
        const pending_bytes = self.pending();
        if (frame.len > outbound_max - pending_bytes.len) return error.OutboundQueueFull;
        if (pending_bytes.len == 0) self.deadline = sys.monotonicMs() + write_timeout_ms;
        if (self.bytes.items.len + frame.len > outbound_max) {
            std.mem.copyForwards(u8, self.bytes.items, pending_bytes);
            self.bytes.shrinkRetainingCapacity(pending_bytes.len);
            self.sent = 0;
        }
        try self.bytes.appendSlice(allocator, frame);
        assert(self.pending().len <= outbound_max);
    }

    pub fn flush(self: *WriteQueue, fd: posix.fd_t) !void {
        // Byte-level helper shared with the bootstrap writer.
        self.sent += try sendSome(fd, self.pending()) orelse return;
        self.deadline = sys.monotonicMs() + write_timeout_ms;
        if (self.pending().len == 0) {
            self.bytes.clearRetainingCapacity();
            self.sent = 0;
        }
    }
};

/// Whether `fd` is open but cannot be polled. Darwin's poll(2) "does not
/// support devices" (BUGS section): an open character device such as
/// /dev/null reports POLLNVAL, which otherwise reads as a closed descriptor.
/// Such a descriptor is left out of poll and treated as always ready; its
/// read or write then reports the real state.
pub fn pollUnsupported(fd: posix.fd_t) bool {
    if (fd < 0) return false;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN | posix.POLL.OUT, .revents = 0 }};
    _ = posix.poll(&fds, 0) catch return false;
    return (fds[0].revents & posix.POLL.NVAL) != 0 and c.fcntl(fd, c.F.GETFD) >= 0;
}

/// One nonblocking stdin read.
pub const StdinReadResult = union(enum) {
    again,
    eof,
    bytes: []const u8,
};

/// Read one chunk of stdin into `buf`.
pub fn readStdinChunk(fd: posix.fd_t, buf: []u8) !StdinReadResult {
    const n = posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => return .again,
        else => return err,
    };
    if (n == 0) return .eof;
    assert(n <= buf.len);
    return .{ .bytes = buf[0..n] };
}

/// Move `fd` to a descriptor >= 3, closing the original.
pub fn moveAboveStdio(fd: posix.fd_t) !posix.fd_t {
    if (fd >= 3) return fd;
    defer sys.close(fd);
    const moved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (moved < 0) return error.Unexpected;
    // F_DUPFD_CLOEXEC returns the lowest free descriptor >= 3.
    assert(moved >= 3);
    return moved;
}

const terminal_signals = [_]posix.SIG{ .HUP, .INT, .TERM, .TSTP, .QUIT, .PIPE, .CONT, .TTOU };

fn terminalSignalSet() posix.sigset_t {
    var mask = posix.sigemptyset();
    for (terminal_signals) |sig| posix.sigaddset(&mask, sig);
    return mask;
}

fn enterTerminal(stdin_fd: posix.fd_t, stdout_fd: posix.fd_t, is_tty: bool) !void {
    assert(stdout_fd >= 0);
    if (is_tty) {
        const current = try posix.tcgetattr(stdin_fd);
        g_saved_termios = current;
        g_saved_termios_fd = stdin_fd;
        var raw = current;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        g_raw_termios = raw;
        try posix.tcsetattr(stdin_fd, .NOW, raw);
        g_termios_saved.store(true, .seq_cst);
    } else {
        g_saved_termios_fd = -1;
    }

    g_output_fd = stdout_fd;
    g_output_flags = c.fcntl(stdout_fd, c.F.GETFL);
    if (g_output_flags < 0) return error.Unexpected;
    try sys.setNonBlocking(stdout_fd);
    g_restore_output.store(true, .seq_cst);
}

/// Mark the terminal inactive and restore it.
pub fn leaveTerminal() void {
    g_terminal_active.store(false, .seq_cst);
    restoreTerminal();
}

fn restoreTerminal() void {
    var previous: posix.sigset_t = undefined;
    const signals = terminalSignalSet();
    posix.sigprocmask(posix.SIG.BLOCK, &signals, &previous);
    if (g_termios_saved.swap(false, .seq_cst)) {
        // Signal context: logging takes the stderr lock, so only record the
        // failure here; `main` reports it.
        posix.tcsetattr(g_saved_termios_fd, .NOW, g_saved_termios) catch g_restore_failed.store(true, .seq_cst);
    }
    if (g_restore_output.swap(false, .seq_cst)) _ = c.fcntl(g_output_fd, c.F.SETFL, g_output_flags);
    posix.sigprocmask(posix.SIG.SETMASK, &previous, null);
}

/// Log a terminal restore that failed in `restoreTerminal`. Not for signal
/// context.
pub fn reportRestoreFailure() void {
    if (g_restore_failed.swap(false, .seq_cst)) log.warn("terminal_restore_failed", .{ .fd = g_saved_termios_fd });
}

fn winchHandler(_: posix.SIG) callconv(.c) void {
    g_winch_flag.store(true, .seq_cst);
}

fn terminalAction(handler: *const fn (posix.SIG) callconv(.c) void) posix.Sigaction {
    return .{ .handler = .{ .handler = handler }, .mask = terminalSignalSet(), .flags = 0 };
}

fn exitRestoreHandler(sig: posix.SIG) callconv(.c) void {
    leaveTerminal();
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &dfl, null);
    _ = c.raise(sig);
}

fn suspendHandler(sig: posix.SIG) callconv(.c) void {
    restoreTerminal();
    const dfl: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &dfl, null);
    var unblock = posix.sigemptyset();
    posix.sigaddset(&unblock, sig);
    posix.sigprocmask(posix.SIG.UNBLOCK, &unblock, null);
    _ = c.raise(sig);
    // Also restore the active state when an orphaned process group ignores TSTP.
    resumeHandler(.CONT);
}

fn resumeHandler(_: posix.SIG) callconv(.c) void {
    if (!g_terminal_active.load(.seq_cst)) return;
    const suspend_action = terminalAction(suspendHandler);
    posix.sigaction(.TSTP, &suspend_action, null);
    if (g_saved_termios_fd >= 0 and !g_termios_saved.load(.seq_cst)) {
        if (posix.tcsetattr(g_saved_termios_fd, .NOW, g_raw_termios)) |_| {
            g_termios_saved.store(true, .seq_cst);
        } else |_| {}
    }
    if (!g_restore_output.load(.seq_cst)) {
        if (sys.setNonBlocking(g_output_fd)) |_| {
            g_restore_output.store(true, .seq_cst);
        } else |_| {}
    }
    g_winch_flag.store(true, .seq_cst);
}

fn installTerminalHandlers() void {
    const restore = terminalAction(exitRestoreHandler);
    for ([_]posix.SIG{ .HUP, .PIPE, .QUIT, .INT, .TERM }) |sig| posix.sigaction(sig, &restore, null);
    const suspend_action = terminalAction(suspendHandler);
    posix.sigaction(.TSTP, &suspend_action, null);
    const resume_action = terminalAction(resumeHandler);
    posix.sigaction(.CONT, &resume_action, null);
    const winch = terminalAction(winchHandler);
    posix.sigaction(.WINCH, &winch, null);
}

/// Terminal rows and columns.
pub const TerminalSize = struct { rows: u16, cols: u16 };

/// The size of stdout, else stdin, when either is a terminal.
pub fn currentTerminalSize(stdout_fd: posix.fd_t, stdin_fd: posix.fd_t) ?TerminalSize {
    return terminalSize(stdout_fd) orelse terminalSize(stdin_fd);
}

fn terminalSize(fd: posix.fd_t) ?TerminalSize {
    var size: posix.winsize = undefined;
    const rc = if (builtin.os.tag.isDarwin() or builtin.abi.isGnu()) blk: {
        const IoctlFn = *const fn (posix.fd_t, c_ulong, ...) callconv(.c) c_int;
        const ioctl = @extern(IoctlFn, .{ .name = "ioctl", .library_name = "c" });
        break :blk ioctl(fd, tiocgwinsz(), &size);
    } else c.ioctl(fd, @intCast(tiocgwinsz()), &size);
    if (rc != 0 or size.col == 0 or size.row == 0) return null;
    return .{ .rows = size.row, .cols = size.col };
}

fn tiocgwinsz() c_ulong {
    return if (builtin.os.tag.isDarwin()) 0x40087468 else 0x5413;
}

/// Poll `fd` for `event` until `deadline` (monotonic ms).
pub fn waitWritableOrReadable(fd: posix.fd_t, event: i16, deadline: i64) !void {
    assert(event != 0);
    const remaining = deadline - sys.monotonicMs();
    if (remaining <= 0) return error.WriteTimeout;
    var pollfds = [_]posix.pollfd{.{ .fd = fd, .events = event, .revents = 0 }};
    if (try posix.poll(&pollfds, @intCast(remaining)) == 0) return error.WriteTimeout;
}

/// One nonblocking send; null when it would block.
pub fn sendSome(fd: posix.fd_t, bytes: []const u8) !?usize {
    const n = sys.send(fd, bytes) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (n == 0) return error.WriteZero;
    assert(n <= bytes.len);
    return n;
}

/// Send all of `bytes` within `timeout_ms`.
pub fn sendFrame(fd: posix.fd_t, bytes: []const u8, timeout_ms: i64) !void {
    const deadline = sys.monotonicMs() + timeout_ms;
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (sys.monotonicMs() >= deadline) return error.WriteTimeout;
        if (try sendSome(fd, bytes[offset..])) |n| {
            offset += n;
        } else {
            try waitWritableOrReadable(fd, posix.POLL.OUT, deadline);
        }
    }
    assert(offset == bytes.len);
}

/// Write all of `bytes` to `fd`, waiting while it would block.
pub fn writeAllFd(fd: posix.fd_t, bytes: []const u8) !void {
    const deadline = sys.monotonicMs() + write_timeout_ms;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = sys.write(fd, bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => {
                try waitWritableOrReadable(fd, posix.POLL.OUT, deadline);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.WriteZero;
        offset += n;
    }
    assert(offset == bytes.len);
}

/// Write the attach replay to `out_fd`.
pub fn replayScrollback(allocator: std.mem.Allocator, result: std.json.Value, out_fd: posix.fd_t) !void {
    const bytes = (try decodeReplay(allocator, result)) orelse return;
    defer allocator.free(bytes);
    try writeAllFd(out_fd, bytes);
}

test "write queue buffers frames until a flush drains them to the socket" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    var queue: WriteQueue = .{};
    defer queue.bytes.deinit(alloc);
    try queue.append(alloc, "ab");
    try queue.append(alloc, "cd\n");
    try std.testing.expectEqualStrings("abcd\n", queue.pending());
    try queue.flush(pair[0]);
    try std.testing.expectEqual(@as(usize, 0), queue.pending().len);
    var buf: [8]u8 = undefined;
    const got = try readStdinChunk(pair[1], &buf);
    try std.testing.expectEqualStrings("abcd\n", got.bytes);
    const oversized = try alloc.alloc(u8, outbound_max + 1);
    defer alloc.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.OutboundQueueFull, queue.append(alloc, oversized));
}
