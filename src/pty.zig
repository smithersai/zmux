//! PTY allocation and child process lifecycle for one pane.
//!
//! `Pty.spawn` does every allocation, `PATH` lookup, and environment merge
//! before `fork`. The forked child runs only async-signal-safe code
//! (`childExec`): it resets signal dispositions, wires the slave to stdio,
//! closes every other descriptor, and reports any setup or `exec` failure to
//! the parent over a close-on-exec pipe, so the caller gets
//! `error.ChildSetupFailed` instead of a pane running in the wrong directory.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const sys = @import("sys.zig");

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;

/// `TERM` applied when the spawn environment does not set one.
pub const default_term = "xterm-256color";
const default_term_entry: [:0]const u8 = "TERM=" ++ default_term;

/// How `SpawnOptions.env` combines with the daemon environment.
pub const EnvMode = enum {
    /// The daemon environment, with `env` entries overriding matching keys.
    merge,
    /// Only the `env` entries.
    replace,
};

pub const SpawnOptions = struct {
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// `KEY=VALUE` entries. See `env_mode`.
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    /// In both modes `TERM=xterm-256color` is added when no `TERM` is present.
    env_mode: EnvMode = .merge,
};

pub const ExitObserver = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, pid: posix.pid_t, status: ?u32) void,
};

/// The child setup step that failed. Sent over the startup pipe as one byte.
pub const ChildSetupStage = enum(u8) {
    setsid = 1,
    ctty = 2,
    dup2 = 3,
    chdir = 4,
    exec = 5,
    unknown = 255,
};

pub const ChildSetupFailure = struct {
    stage: ChildSetupStage,
    errno: posix.E,
    /// The already-reaped child. Kept so tests can prove no process remains.
    pid: posix.pid_t,
};

/// Detail for the most recent `error.ChildSetupFailed` returned by
/// `Pty.spawn` on this thread.
pub threadlocal var last_child_setup_failure: ?ChildSetupFailure = null;

pub const Pty = struct {
    /// Used only for `wait_mutex`; PTY reads and writes are non-blocking
    /// syscalls on `master_fd` driven by `poll(2)`, so callers can run them
    /// from plain `std.Thread`s.
    io: std.Io,
    /// Non-blocking. -1 once `close` ran. `read`, `pollReadable`, and `write`
    /// read this field without a lock: the owner must not call `close`
    /// concurrently with them. `resize`, `kill`, `terminate`, and
    /// `hangupForeground` are safe against a concurrent `close`.
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    /// Linux pidfd for `child_pid`, readable once the child exits; -1 when
    /// unavailable. Lets a poll loop learn of the exit without a timeout.
    pid_fd: posix.fd_t = -1,
    /// Serializes `waitpid` against every signal sent to the child, so a
    /// signal can never reach a PID the kernel has recycled after the reap.
    wait_mutex: std.Io.Mutex = .init,
    reaped: bool = false,
    exit_status: ?u32 = null,
    exit_observer: ?ExitObserver = null,

    pub fn spawn(allocator: Allocator, io: std.Io, opts: SpawnOptions) !Pty {
        try validateSpawnOptions(opts);

        const fds = try openPty(.{ .row = opts.rows, .col = opts.cols, .xpixel = 0, .ypixel = 0 });
        return spawnOnFds(allocator, io, opts, fds.master_fd, fds.slave_fd);
    }

    /// Fork the child onto an already-open PTY pair. Takes ownership of both
    /// descriptors on success and on failure.
    fn spawnOnFds(allocator: Allocator, io: std.Io, opts: SpawnOptions, master_fd: posix.fd_t, slave_fd: posix.fd_t) !Pty {
        var slave_open = true;
        defer if (slave_open) sys.close(slave_fd);
        errdefer sys.close(master_fd);

        // Everything the child needs is prepared here: after `fork` in a
        // multi-threaded process the child may not allocate or take locks.
        const shell_path = opts.shell orelse defaultShell();
        const shell_z = try allocator.dupeSentinel(u8, shell_path, 0);
        defer allocator.free(shell_z);

        const command_z = if (opts.command) |command| try allocator.dupeSentinel(u8, command, 0) else null;
        defer if (command_z) |command| allocator.free(command);

        const cwd_z = if (opts.cwd) |cwd| try allocator.dupeSentinel(u8, cwd, 0) else null;
        defer if (cwd_z) |cwd| allocator.free(cwd);

        var env = try buildEnv(allocator, sys.currentEnviron(), opts.env, opts.env_mode);
        defer env.deinit(allocator);

        const path_env: []const u8 = if (std.c.getenv("PATH")) |value| std.mem.sliceTo(value, 0) else sys.default_exec_path;
        var candidates = try resolveExecCandidates(allocator, shell_path, path_env);
        defer candidates.deinit(allocator);

        const argv_shell = [_:null]?[*:0]const u8{ shell_z.ptr, "-l" };
        // The 4th slot is only read when `command_z` is non-null, but the
        // initializer is always evaluated.
        const argv_command = [_:null]?[*:0]const u8{ shell_z.ptr, "-l", "-c", if (command_z) |command| command.ptr else "" };
        const argv: [*:null]const ?[*:0]const u8 = if (command_z != null) &argv_command else &argv_shell;

        const err_pipe = try sys.pipeCloexec();
        var err_read_open = true;
        defer if (err_read_open) sys.close(err_pipe[0]);
        var err_write_open = true;
        defer if (err_write_open) sys.close(err_pipe[1]);

        const pid = sys.fork() catch return error.ForkFailed;
        if (pid == 0) {
            childExec(slave_fd, err_pipe[1], if (cwd_z) |cwd| cwd.ptr else null, candidates.list(), argv, env.list());
        }

        sys.close(slave_fd);
        slave_open = false;
        sys.close(err_pipe[1]);
        err_write_open = false;

        // EOF means `exec` succeeded (the pipe is close-on-exec); a report
        // means setup failed and the child has already called `_exit`.
        if (readChildReport(err_pipe[0])) |report| {
            reapBlocking(pid);
            last_child_setup_failure = .{ .stage = report.stage, .errno = report.errno, .pid = pid };
            return error.ChildSetupFailed;
        }
        sys.close(err_pipe[0]);
        err_read_open = false;

        return .{
            .io = io,
            .master_fd = master_fd,
            .child_pid = pid,
            .pid_fd = openPidFd(pid),
        };
    }

    /// Close the master (hanging up the terminal) and the pidfd. Idempotent.
    pub fn close(self: *Pty) void {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.master_fd >= 0) sys.close(self.master_fd);
        self.master_fd = -1;
        if (self.pid_fd >= 0) sys.close(self.pid_fd);
        self.pid_fd = -1;
    }

    pub fn setExitObserver(self: *Pty, observer: ExitObserver) void {
        var should_emit = false;
        var emit_status: ?u32 = null;

        self.wait_mutex.lockUncancelable(self.io);
        self.exit_observer = observer;
        if (self.reaped) {
            should_emit = true;
            emit_status = self.exit_status;
        }
        self.wait_mutex.unlock(self.io);

        if (should_emit) {
            observer.callback(observer.context, self.child_pid, emit_status);
        }
    }

    /// SIGTERM to the child's process group. No-op once the child is reaped:
    /// its PID (and group id) may already name an unrelated process.
    pub fn terminate(self: *Pty) void {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.reaped) return;
        self.signalShellGroupLocked(.TERM);
    }

    /// SIGKILL to the terminal foreground group (when it is not the shell
    /// group) and to the shell group. No-op once the child is reaped.
    pub fn kill(self: *Pty) void {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.reaped) return;
        if (self.foregroundGroupLocked()) |fg| _ = sys.kill(-fg, .KILL);
        self.signalShellGroupLocked(.KILL);
    }

    /// SIGHUP+SIGCONT to the terminal foreground group when it is not the
    /// shell group, then to the shell group. SIGCONT lets stopped jobs act on
    /// the hangup. No-op once the child is reaped.
    pub fn hangupForeground(self: *Pty) void {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.reaped) return;
        if (self.foregroundGroupLocked()) |fg| {
            _ = sys.kill(-fg, .HUP);
            _ = sys.kill(-fg, .CONT);
        }
        self.signalShellGroupLocked(.HUP);
        self.signalShellGroupLocked(.CONT);
    }

    fn signalShellGroupLocked(self: *Pty, sig: posix.SIG) void {
        // The child calls `setsid`, so its PID is also its group id. Fall
        // back to the bare PID for the instant before `setsid` has run.
        if (!sys.kill(-self.child_pid, sig)) _ = sys.kill(self.child_pid, sig);
    }

    /// The terminal's foreground process group when it is a job other than
    /// the shell itself.
    fn foregroundGroupLocked(self: *Pty) ?posix.pid_t {
        if (self.master_fd < 0) return null;
        const fg = tcgetpgrp(self.master_fd);
        if (fg <= 1 or fg == self.child_pid) return null;
        return fg;
    }

    pub fn pollReadable(self: *const Pty, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{.{
            .fd = self.master_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        return (try posix.poll(&fds, timeout_ms)) > 0 and
            (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0;
    }

    /// Non-blocking: `error.WouldBlock` when no output is pending.
    pub fn read(self: *const Pty, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }

    pub const WriteError = error{ InputTimeout, InputClosed, WriteZero, BrokenPipe, InputOutput };

    /// Write every byte before the monotonic `deadline_ms` (`sys.monotonicMs`).
    /// The master is non-blocking: when the terminal's input queue is full
    /// (the child is not reading) this polls for `POLLOUT` together with
    /// `stop_fd`, returning `InputClosed` as soon as `stop_fd` is readable
    /// and `InputTimeout` at the deadline. Pass -1 for no stop descriptor.
    pub fn write(self: *Pty, bytes: []const u8, deadline_ms: i64, stop_fd: posix.fd_t) WriteError!void {
        var offset: usize = 0;
        var polled_writable = false;
        while (offset < bytes.len) {
            const fd = self.master_fd;
            if (fd < 0) return error.InputClosed;
            if (sys.write(fd, bytes[offset..])) |n| {
                if (n == 0) return error.WriteZero;
                offset += n;
                polled_writable = false;
                continue;
            } else |err| switch (err) {
                error.WouldBlock => {},
                error.BrokenPipe, error.ConnectionResetByPeer => return error.BrokenPipe,
                else => return error.InputOutput,
            }

            // poll said writable but the write still would block: back off
            // instead of spinning until the deadline.
            if (polled_writable) sys.sleepMs(1);
            const remaining = deadline_ms - sys.monotonicMs();
            if (remaining <= 0) return error.InputTimeout;
            var fds = [_]posix.pollfd{
                .{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 },
                .{ .fd = stop_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            const rc = std.c.poll(&fds, fds.len, @intCast(@min(remaining, std.math.maxInt(c_int))));
            if (rc < 0) {
                if (posix.errno(rc) == .INTR) continue;
                return error.InputOutput;
            }
            if (fds[1].revents != 0) return error.InputClosed;
            polled_writable = fds[0].revents != 0;
        }
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        var wsz: posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.master_fd < 0) return error.ResizeFailed;
        if (sys.ioctl(self.master_fd, tiocswinsz, @intFromPtr(&wsz)) != 0) return error.ResizeFailed;
    }

    /// Current window size, read back from the terminal.
    pub fn windowSize(self: *Pty) !posix.winsize {
        var wsz: posix.winsize = undefined;
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        if (self.master_fd < 0) return error.ResizeFailed;
        if (sys.ioctl(self.master_fd, tiocgwinsz, @intFromPtr(&wsz)) != 0) return error.ResizeFailed;
        return wsz;
    }

    pub fn reapExited(self: *Pty) ?u32 {
        var observer: ?ExitObserver = null;
        var should_emit = false;
        var status_to_emit: ?u32 = null;

        self.wait_mutex.lockUncancelable(self.io);
        if (self.reaped) {
            const status = self.exit_status;
            self.wait_mutex.unlock(self.io);
            return status;
        }

        switch (waitPidNoHang(self.child_pid)) {
            .running => {},
            .exited => |status| {
                self.reaped = true;
                self.exit_status = status;
                observer = self.exit_observer;
                should_emit = true;
                status_to_emit = status;
            },
        }
        self.wait_mutex.unlock(self.io);

        if (should_emit) {
            if (observer) |active| {
                active.callback(active.context, self.child_pid, status_to_emit);
            }
        }

        if (status_to_emit) |status| return status;
        return null;
    }

    pub fn isReaped(self: *Pty) bool {
        self.wait_mutex.lockUncancelable(self.io);
        defer self.wait_mutex.unlock(self.io);
        return self.reaped;
    }

    /// Reap until the child is collected or `timeout_ms` elapses. Returns
    /// whether the child was reaped.
    pub fn waitBlocking(self: *Pty, timeout_ms: i64) bool {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (true) {
            _ = self.reapExited();
            if (self.isReaped()) return true;
            if (sys.monotonicMs() >= deadline) return false;
            sys.sleepMs(2);
        }
    }
};

fn hasNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

/// Reject arguments that cannot be represented faithfully as C strings or
/// `KEY=VALUE` environment entries: an interior NUL would silently truncate
/// a path or command, and an entry with no key or no `=` is not a variable.
fn validateSpawnOptions(opts: SpawnOptions) error{InvalidSpawnArgument}!void {
    if (opts.shell) |v| if (v.len == 0 or hasNul(v)) return error.InvalidSpawnArgument;
    if (opts.command) |v| if (hasNul(v)) return error.InvalidSpawnArgument;
    if (opts.cwd) |v| if (v.len == 0 or hasNul(v)) return error.InvalidSpawnArgument;
    if (opts.env) |entries| for (entries) |entry| {
        if (hasNul(entry)) return error.InvalidSpawnArgument;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidSpawnArgument;
        if (eq == 0) return error.InvalidSpawnArgument;
    };
}

/// A NULL-terminated array of C strings, some owned and some borrowed.
const CStringList = struct {
    owned: std.ArrayList([:0]u8) = .empty,
    ptrs: std.ArrayList(?[*:0]const u8) = .empty,

    fn deinit(self: *CStringList, allocator: Allocator) void {
        for (self.owned.items) |entry| allocator.free(entry);
        self.owned.deinit(allocator);
        self.ptrs.deinit(allocator);
    }

    fn appendBorrowed(self: *CStringList, allocator: Allocator, entry: [*:0]const u8) !void {
        try self.ptrs.append(allocator, entry);
    }

    fn appendOwned(self: *CStringList, allocator: Allocator, entry: [:0]u8) !void {
        self.owned.append(allocator, entry) catch |err| {
            allocator.free(entry);
            return err;
        };
        try self.ptrs.append(allocator, entry.ptr);
    }

    fn finish(self: *CStringList, allocator: Allocator) !void {
        try self.ptrs.append(allocator, null);
    }

    /// Valid after `finish`.
    fn list(self: *const CStringList) [*:null]const ?[*:0]const u8 {
        return @ptrCast(self.ptrs.items.ptr);
    }

    /// Entries without the terminator.
    fn entries(self: *const CStringList) []const ?[*:0]const u8 {
        return self.ptrs.items[0 .. self.ptrs.items.len - 1];
    }
};

fn envKey(entry: []const u8) []const u8 {
    return entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
}

fn envSetsKey(entries: []const []const u8, key: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, envKey(entry), key)) return true;
    return false;
}

/// Build the child's `envp` before `fork`. `.merge` keeps every `base` entry
/// whose key `supplied` does not set, then appends `supplied`; `.replace`
/// uses `supplied` alone. A later duplicate key in `supplied` wins. In both
/// modes `TERM=xterm-256color` is appended when no `TERM` is present.
fn buildEnv(
    allocator: Allocator,
    base: [*:null]const ?[*:0]const u8,
    supplied_opt: ?[]const []const u8,
    mode: EnvMode,
) !CStringList {
    var env: CStringList = .{};
    errdefer env.deinit(allocator);
    const supplied: []const []const u8 = supplied_opt orelse &.{};
    var has_term = false;

    if (mode == .merge) {
        var index: usize = 0;
        while (base[index]) |entry_z| : (index += 1) {
            const key = envKey(std.mem.sliceTo(entry_z, 0));
            if (envSetsKey(supplied, key)) continue;
            if (std.mem.eql(u8, key, "TERM")) has_term = true;
            try env.appendBorrowed(allocator, entry_z);
        }
    }
    for (supplied, 0..) |entry, index| {
        const key = envKey(entry);
        if (envSetsKey(supplied[index + 1 ..], key)) continue;
        if (std.mem.eql(u8, key, "TERM")) has_term = true;
        try env.appendOwned(allocator, try allocator.dupeSentinel(u8, entry, 0));
    }
    if (!has_term) try env.appendBorrowed(allocator, default_term_entry.ptr);
    try env.finish(allocator);
    return env;
}

/// Resolve the paths `execvp(3)` would try for `file`, before `fork`: `file`
/// itself when it contains '/', otherwise one candidate per `PATH` component.
/// An empty component means the current directory (POSIX), which for the
/// child is the pane's `cwd`.
fn resolveExecCandidates(allocator: Allocator, file: []const u8, path_env: []const u8) !CStringList {
    var candidates: CStringList = .{};
    errdefer candidates.deinit(allocator);

    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        try candidates.appendOwned(allocator, try allocator.dupeSentinel(u8, file, 0));
    } else {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |component| {
            const dir = if (component.len == 0) "." else component;
            if (dir.len + 1 + file.len >= posix.PATH_MAX) continue;
            const candidate = try allocator.allocSentinel(u8, dir.len + 1 + file.len, 0);
            @memcpy(candidate[0..dir.len], dir);
            candidate[dir.len] = '/';
            @memcpy(candidate[dir.len + 1 ..], file);
            try candidates.appendOwned(allocator, candidate);
        }
    }
    try candidates.finish(allocator);
    return candidates;
}

const OpenPtyResult = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
};

/// Open a PTY pair. Both ends are close-on-exec; the master is non-blocking.
fn openPty(wsz: posix.winsize) !OpenPtyResult {
    var master_fd: posix.fd_t = undefined;
    var slave_fd: posix.fd_t = undefined;

    if (is_linux) {
        // Atomic close-on-exec on both ends: no window for a concurrent fork.
        const flags: std.c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        master_fd = posix_openpt(@bitCast(flags));
        if (master_fd < 0) return error.OpenPtyFailed;
        errdefer sys.close(master_fd);
        var name_buf: [128]u8 = undefined;
        if (grantpt(master_fd) != 0 or unlockpt(master_fd) != 0 or
            ptsname_r(master_fd, &name_buf, name_buf.len) != 0) return error.OpenPtyFailed;
        const name: [*:0]const u8 = @ptrCast(&name_buf);
        slave_fd = sys.openZ(name, flags, 0) catch return error.OpenPtyFailed;
        errdefer sys.close(slave_fd);
        var size = wsz;
        if (sys.ioctl(master_fd, tiocswinsz, @intFromPtr(&size)) != 0) return error.OpenPtyFailed;
    } else {
        // No atomic form: hold the fork lock until both ends are marked.
        if (is_darwin) sys.fork_lock.lockShared();
        defer if (is_darwin) sys.fork_lock.unlockShared();
        if (openpty(&master_fd, &slave_fd, null, null, &wsz) != 0) return error.OpenPtyFailed;
        errdefer sys.close(master_fd);
        errdefer sys.close(slave_fd);
        try sys.setCloseOnExec(master_fd);
        try sys.setCloseOnExec(slave_fd);
    }
    errdefer sys.close(master_fd);
    errdefer sys.close(slave_fd);

    try sys.setNonBlocking(master_fd);
    return .{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
    };
}

fn openPidFd(pid: posix.pid_t) posix.fd_t {
    if (!is_linux) return -1;
    // pidfds are close-on-exec by construction. ENOSYS on kernels < 5.3.
    const rc = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return -1;
    return @intCast(rc);
}

const WaitPidNoHangResult = union(enum) {
    running,
    exited: ?u32,
};

fn waitPidNoHang(pid: posix.pid_t) WaitPidNoHangResult {
    while (true) {
        var status: c_int = 0;
        const rc = std.c.waitpid(pid, &status, @intCast(posix.W.NOHANG));
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return .running;
                return .{ .exited = @bitCast(status) };
            },
            .INTR => continue,
            // Already collected elsewhere (for example SIGCHLD is ignored).
            .CHILD => return .{ .exited = null },
            // Nothing else is documented for waitpid; treat it as "gone with
            // an unknown status" instead of crashing the daemon.
            else => |err| {
                std.log.warn("zmux-pty: waitpid({d}) failed: {s}", .{ pid, @tagName(err) });
                return .{ .exited = null };
            },
        }
    }
}

/// Blocking reap for a child known to be exiting.
fn reapBlocking(pid: posix.pid_t) void {
    while (true) {
        const rc = std.c.waitpid(pid, null, 0);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return;
    }
}

const child_report_len = 1 + @sizeOf(i32);

/// Read the child's failure report. Null means EOF with no report: `exec`
/// succeeded.
fn readChildReport(fd: posix.fd_t) ?struct { stage: ChildSetupStage, errno: posix.E } {
    var report: [child_report_len]u8 = undefined;
    var got: usize = 0;
    while (got < report.len) {
        const rc = std.c.read(fd, report[got..].ptr, report.len - got);
        if (rc < 0) {
            if (posix.errno(rc) == .INTR) continue;
            break;
        }
        if (rc == 0) break;
        got += @intCast(rc);
    }
    if (got == 0) return null;
    if (got < report.len) return .{ .stage = .unknown, .errno = .SUCCESS };
    const raw_errno = std.mem.readInt(i32, report[1..5], .little);
    return .{
        .stage = std.enums.fromInt(ChildSetupStage, report[0]) orelse .unknown,
        .errno = if (raw_errno >= 0 and raw_errno <= std.math.maxInt(u16)) @fromBackingInt(@intCast(@as(u16, @intCast(raw_errno)))) else .SUCCESS,
    };
}

/// Async-signal-safe. Report `stage` and the current `errno` to the parent,
/// then exit.
fn childFail(err_fd: posix.fd_t, stage: ChildSetupStage, errno_value: c_int) noreturn {
    var report: [child_report_len]u8 = undefined;
    report[0] = @backingInt(stage);
    std.mem.writeInt(i32, report[1..5], @intCast(errno_value), .little);
    _ = std.c.write(err_fd, &report, report.len);
    std.c._exit(127);
}

/// Runs in the forked child. Async-signal-safe: no allocation, no locks, no
/// `getenv`, no formatted output. Never returns.
///
/// Descriptor plan: stdio (0-2) becomes the slave; the error pipe is parked
/// on fd 3 with `FD_CLOEXEC`, so `closeFrom(4)` plus `exec` leaves the
/// program with exactly 0, 1 and 2. This holds even when the parent had
/// stdio closed and the slave or the pipe was allocated at 0-2.
fn childExec(
    slave_fd_in: posix.fd_t,
    err_fd_in: posix.fd_t,
    cwd_z: ?[*:0]const u8,
    candidates: [*:null]const ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    sys.resetChildSignals();

    // Lift both descriptors out of the stdio range before it is rewritten.
    var err_fd = err_fd_in;
    if (err_fd < 3) {
        const moved = std.c.fcntl(err_fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) std.c._exit(127);
        err_fd = moved;
    }
    var slave_fd = slave_fd_in;
    if (slave_fd < 3) {
        const moved = std.c.fcntl(slave_fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) childFail(err_fd, .dup2, std.c._errno().*);
        slave_fd = moved;
    }

    if (std.c.setsid() < 0) childFail(err_fd, .setsid, std.c._errno().*);
    if (sys.ioctl(slave_fd, tiocsctty, 0) != 0) childFail(err_fd, .ctty, std.c._errno().*);

    var stdio: posix.fd_t = 0;
    while (stdio < 3) : (stdio += 1) {
        sys.dup2(slave_fd, stdio) catch childFail(err_fd, .dup2, std.c._errno().*);
    }
    if (err_fd != 3) {
        sys.dup2(err_fd, 3) catch childFail(err_fd, .dup2, std.c._errno().*);
        err_fd = 3;
        if (std.c.fcntl(err_fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) {
            childFail(err_fd, .dup2, std.c._errno().*);
        }
    }
    sys.closeFrom(4);

    if (cwd_z) |cwd| {
        if (std.c.chdir(cwd) != 0) childFail(err_fd, .chdir, std.c._errno().*);
    }

    // execvp(3) semantics over the pre-resolved candidates: keep searching on
    // "not here", but remember a permission failure so a later miss does not
    // hide it.
    var last_errno: c_int = @backingInt(posix.E.NOENT);
    var index: usize = 0;
    while (candidates[index]) |candidate| : (index += 1) {
        _ = std.c.execve(candidate, argv, envp);
        const errno_value = std.c._errno().*;
        switch (@as(posix.E, @fromBackingInt(@intCast(errno_value)))) {
            .NOENT, .NOTDIR => {},
            .ACCES, .PERM => last_errno = errno_value,
            else => childFail(err_fd, .exec, errno_value),
        }
    }
    childFail(err_fd, .exec, last_errno);
}

fn defaultShell() []const u8 {
    // The child inherits the libc environment block (see `buildEnv`), so
    // read SHELL from the same place.
    const env_shell: ?[]const u8 = if (std.c.getenv("SHELL")) |shell_z| std.mem.sliceTo(shell_z, 0) else null;
    return defaultShellFor(env_shell);
}

fn defaultShellFor(env_shell: ?[]const u8) []const u8 {
    if (env_shell) |shell| {
        if (shell.len > 0) return shell;
    }
    return if (is_darwin) "/bin/zsh" else "/bin/sh";
}

// ioctl request numbers at their native `unsigned long` width (see
// `sys.ioctl`). Darwin's are spelled out: its `_IOW` requests have the top
// bit set and must not be sign-extended.
const tiocswinsz: c_ulong = if (is_darwin) 0x80087467 else posix.T.IOCSWINSZ;
const tiocgwinsz: c_ulong = if (is_darwin) 0x40087468 else posix.T.IOCGWINSZ;
const tiocsctty: c_ulong = if (is_darwin) 0x20007461 else posix.T.IOCSCTTY;

// ---------------------------------------------------------------------------
// Tests

const supported_os = is_linux or is_darwin;

fn testSleepMs(ms: i64) void {
    sys.sleepMs(ms);
}

fn cleanupPtyForTest(child: *Pty) void {
    child.kill();
    _ = child.waitBlocking(2000);
    child.close();
}

/// Read PTY output until the child exits and the terminal drains.
fn collectOutput(allocator: Allocator, child: *Pty, timeout_ms: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const deadline = sys.monotonicMs() + timeout_ms;
    var buf: [4096]u8 = undefined;
    while (sys.monotonicMs() < deadline) {
        const readable = child.pollReadable(20) catch break;
        if (!readable) {
            _ = child.reapExited();
            if (child.isReaped() and !(child.pollReadable(0) catch true)) break;
            continue;
        }
        const n = child.read(&buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => break,
        };
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// Spawn `command` under /bin/sh and return everything it printed.
fn runAndCollect(allocator: Allocator, opts: SpawnOptions) ![]u8 {
    var child = try Pty.spawn(allocator, std.testing.io, opts);
    defer cleanupPtyForTest(&child);
    return collectOutput(allocator, &child, 10_000);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected output to contain \"{s}\"; got:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("expected output not to contain \"{s}\"; got:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedNotContains;
    }
}

fn processExists(pid: posix.pid_t) bool {
    return std.c.kill(pid, @fromBackingInt(@intCast(0))) == 0;
}

test "default shell honours SHELL and falls back to an absolute path" {
    try std.testing.expectEqualStrings("/opt/bin/fish", defaultShellFor("/opt/bin/fish"));
    try std.testing.expectEqualStrings("sh", defaultShellFor("sh"));
    try std.testing.expect(std.mem.startsWith(u8, defaultShellFor(null), "/"));
    try std.testing.expect(std.mem.startsWith(u8, defaultShellFor(""), "/"));
}

test "exec candidates follow PATH order and treat an empty component as cwd" {
    const allocator = std.testing.allocator;
    {
        var candidates = try resolveExecCandidates(allocator, "sh", ":/bin");
        defer candidates.deinit(allocator);
        const entries = candidates.entries();
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("./sh", std.mem.sliceTo(entries[0].?, 0));
        try std.testing.expectEqualStrings("/bin/sh", std.mem.sliceTo(entries[1].?, 0));
        try std.testing.expect(candidates.list()[2] == null);
    }
    {
        var candidates = try resolveExecCandidates(allocator, "sh", "/usr/bin::/bin:");
        defer candidates.deinit(allocator);
        const entries = candidates.entries();
        try std.testing.expectEqual(@as(usize, 4), entries.len);
        try std.testing.expectEqualStrings("/usr/bin/sh", std.mem.sliceTo(entries[0].?, 0));
        try std.testing.expectEqualStrings("./sh", std.mem.sliceTo(entries[1].?, 0));
        try std.testing.expectEqualStrings("/bin/sh", std.mem.sliceTo(entries[2].?, 0));
        try std.testing.expectEqualStrings("./sh", std.mem.sliceTo(entries[3].?, 0));
    }
    {
        // A name containing '/' is used as given, with no PATH search.
        var candidates = try resolveExecCandidates(allocator, "bin/tool", "/usr/bin");
        defer candidates.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), candidates.entries().len);
        try std.testing.expectEqualStrings("bin/tool", std.mem.sliceTo(candidates.entries()[0].?, 0));
    }
    try std.testing.checkAllAllocationFailures(allocator, resolveCandidatesForFailureTest, .{});
}

fn resolveCandidatesForFailureTest(allocator: Allocator) !void {
    var candidates = try resolveExecCandidates(allocator, "sh", "/a:/b::/c");
    candidates.deinit(allocator);
}

test "spawn resolves a relative shell name through PATH" {
    if (!supported_os) return error.SkipZigTest;

    const output = try runAndCollect(std.testing.allocator, .{ .shell = "sh", .command = "echo relative-shell-ok" });
    defer std.testing.allocator.free(output);
    try expectContains(output, "relative-shell-ok");
}

fn testEnvHas(env: *const CStringList, expected: []const u8) bool {
    for (env.entries()) |entry| {
        if (std.mem.eql(u8, std.mem.sliceTo(entry.?, 0), expected)) return true;
    }
    return false;
}

test "env merge overrides matching keys and keeps the rest of the base" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z", "FOO=old", "FOOBAR=keep" };

    var env = try buildEnv(allocator, &base, &.{ "FOO=new", "EXTRA=1", "EXTRA=2" }, .merge);
    defer env.deinit(allocator);
    try std.testing.expect(testEnvHas(&env, "PATH=/usr/bin"));
    try std.testing.expect(testEnvHas(&env, "HOME=/home/z"));
    try std.testing.expect(testEnvHas(&env, "FOO=new"));
    try std.testing.expect(!testEnvHas(&env, "FOO=old"));
    // Key matching is exact, not a prefix match.
    try std.testing.expect(testEnvHas(&env, "FOOBAR=keep"));
    // The last duplicate in the supplied entries wins.
    try std.testing.expect(testEnvHas(&env, "EXTRA=2"));
    try std.testing.expect(!testEnvHas(&env, "EXTRA=1"));
    // No TERM anywhere: the default is added exactly once.
    try std.testing.expect(testEnvHas(&env, "TERM=" ++ default_term));
    try std.testing.expectEqual(@as(usize, 6), env.entries().len);
    try std.testing.expect(env.list()[6] == null);
}

test "env merge with no supplied entries is the base plus a default TERM" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z" };
    var env = try buildEnv(allocator, &base, null, .merge);
    defer env.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), env.entries().len);
    try std.testing.expect(testEnvHas(&env, "TERM=" ++ default_term));
}

test "env keeps an existing TERM from the base or the supplied entries" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "TERM=screen", "PATH=/usr/bin" };
    {
        var env = try buildEnv(allocator, &base, null, .merge);
        defer env.deinit(allocator);
        try std.testing.expect(testEnvHas(&env, "TERM=screen"));
        try std.testing.expectEqual(@as(usize, 2), env.entries().len);
    }
    {
        var env = try buildEnv(allocator, &base, &.{"TERM=dumb"}, .merge);
        defer env.deinit(allocator);
        try std.testing.expect(testEnvHas(&env, "TERM=dumb"));
        try std.testing.expect(!testEnvHas(&env, "TERM=screen"));
        try std.testing.expectEqual(@as(usize, 2), env.entries().len);
    }
    {
        var env = try buildEnv(allocator, &base, &.{"TERM=vt100"}, .replace);
        defer env.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), env.entries().len);
        try std.testing.expect(testEnvHas(&env, "TERM=vt100"));
    }
}

test "env replace uses only the supplied entries plus a default TERM" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z", "TERM=screen" };
    {
        var env = try buildEnv(allocator, &base, &.{"ONLY=1"}, .replace);
        defer env.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), env.entries().len);
        try std.testing.expect(testEnvHas(&env, "ONLY=1"));
        try std.testing.expect(testEnvHas(&env, "TERM=" ++ default_term));
    }
    {
        var env = try buildEnv(allocator, &base, null, .replace);
        defer env.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), env.entries().len);
        try std.testing.expect(testEnvHas(&env, "TERM=" ++ default_term));
    }
}

fn buildEnvForFailureTest(allocator: Allocator) !void {
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z" };
    var env = try buildEnv(allocator, &base, &.{ "A=1", "B=2", "PATH=/x" }, .merge);
    env.deinit(allocator);
}

test "env construction cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildEnvForFailureTest, .{});
}

test "spawned child sees the merged environment" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // /usr/bin/env is found through the inherited PATH, proving the daemon
    // environment survived the merge.
    const env = [_][]const u8{ "ZMUX_T2_MARK=merged", "TERM=vt220" };
    const output = try runAndCollect(allocator, .{
        .shell = "/bin/sh",
        .command = "env | grep -E '^(ZMUX_T2_MARK|TERM|PATH)=' ; echo done-env",
        .env = &env,
    });
    defer allocator.free(output);
    try expectContains(output, "ZMUX_T2_MARK=merged");
    try expectContains(output, "TERM=vt220");
    try expectContains(output, "PATH=");
    try expectContains(output, "done-env");
}

test "spawned child with replace sees only the supplied entries and TERM" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // `export -p` is a shell builtin, so it works without any PATH. HOME is
    // not something /bin/sh sets on its own, so its absence proves the
    // daemon environment was dropped.
    const env = [_][]const u8{"ZMUX_T2_ONLY=1"};
    const output = try runAndCollect(allocator, .{
        .shell = "/bin/sh",
        .command = "export -p; echo home=[${HOME-unset}] term=[$TERM]",
        .env = &env,
        .env_mode = .replace,
    });
    defer allocator.free(output);
    try expectContains(output, "ZMUX_T2_ONLY");
    try expectContains(output, "home=[unset]");
    try expectContains(output, "term=[" ++ default_term ++ "]");
}

test "spawn defaults TERM when the daemon environment has none" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const output = try runAndCollect(allocator, .{
        .shell = "/bin/sh",
        .command = "echo term=[$TERM]",
        .env = &.{},
        .env_mode = .replace,
    });
    defer allocator.free(output);
    try expectContains(output, "term=[" ++ default_term ++ "]");
}

test "spawn rejects NUL bytes and malformed environment entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]SpawnOptions{
        .{ .shell = "/bin/s\x00h" },
        .{ .shell = "" },
        .{ .shell = "/bin/sh", .command = "echo a\x00b" },
        .{ .shell = "/bin/sh", .cwd = "/tm\x00p" },
        .{ .shell = "/bin/sh", .cwd = "" },
        .{ .shell = "/bin/sh", .env = &.{"KEY=va\x00lue"} },
        .{ .shell = "/bin/sh", .env = &.{"K\x00EY=value"} },
        .{ .shell = "/bin/sh", .env = &.{"=value"} },
        .{ .shell = "/bin/sh", .env = &.{""} },
        .{ .shell = "/bin/sh", .env = &.{"NOEQUALS"} },
        .{ .shell = "/bin/sh", .env = &.{ "GOOD=1", "=bad" } },
    };
    for (cases) |opts| {
        try std.testing.expectError(error.InvalidSpawnArgument, Pty.spawn(allocator, io, opts));
    }
    // An empty value and a value containing '=' are both legal.
    try validateSpawnOptions(.{ .env = &.{ "EMPTY=", "URL=a=b" } });
}

test "open pty marks both ends close-on-exec and the master non-blocking" {
    if (!supported_os) return error.SkipZigTest;

    const fds = try openPty(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    defer sys.close(fds.master_fd);
    defer sys.close(fds.slave_fd);

    try std.testing.expect(try sys.isCloseOnExec(fds.master_fd));
    try std.testing.expect(try sys.isCloseOnExec(fds.slave_fd));
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, posix.read(fds.master_fd, &buf));
}

test "a failing chdir reports ChildSetupFailed and leaves no process" {
    if (!supported_os) return error.SkipZigTest;

    last_child_setup_failure = null;
    try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "echo should-not-run",
        .cwd = "/zmux/no/such/directory",
    }));
    const failure = last_child_setup_failure.?;
    try std.testing.expectEqual(ChildSetupStage.chdir, failure.stage);
    try std.testing.expectEqual(posix.E.NOENT, failure.errno);
    // Already reaped: waitpid has nothing left to collect.
    const rc = std.c.waitpid(failure.pid, null, @intCast(posix.W.NOHANG));
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(posix.E.CHILD, posix.errno(rc));
}

test "a missing shell reports ChildSetupFailed at the exec stage" {
    if (!supported_os) return error.SkipZigTest;

    for ([_][]const u8{ "/zmux/no/such/shell", "zmux-no-such-shell" }) |shell| {
        last_child_setup_failure = null;
        try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
            .shell = shell,
            .command = "true",
        }));
        const failure = last_child_setup_failure.?;
        try std.testing.expectEqual(ChildSetupStage.exec, failure.stage);
        try std.testing.expectEqual(posix.E.NOENT, failure.errno);
        try std.testing.expectEqual(posix.E.CHILD, posix.errno(std.c.waitpid(failure.pid, null, @intCast(posix.W.NOHANG))));
    }

    // A file that exists but is not executable surfaces EACCES, not ENOENT.
    last_child_setup_failure = null;
    try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/etc/passwd",
        .command = "true",
    }));
    try std.testing.expectEqual(ChildSetupStage.exec, last_child_setup_failure.?.stage);
    try std.testing.expectEqual(posix.E.ACCES, last_child_setup_failure.?.errno);
}

test "a valid cwd is applied before exec" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const output = try runAndCollect(allocator, .{ .shell = "/bin/sh", .command = "echo cwd=[$(pwd -P)]", .cwd = "/" });
    defer allocator.free(output);
    try expectContains(output, "cwd=[/]");
}

const fd_listing_command = "for f in /dev/fd/*; do echo \"fd:${f##*/}:\"; done";

test "the child inherits only stdio, not unrelated descriptors" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // Plant inheritable descriptors at known numbers in the parent.
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try sys.dup2(fds[0], 50);
    defer sys.close(50);
    try sys.dup2(fds[1], 51);
    defer sys.close(51);
    try std.testing.expect(!(try sys.isCloseOnExec(50)));

    const output = try runAndCollect(allocator, .{ .shell = "/bin/sh", .command = fd_listing_command });
    defer allocator.free(output);
    try expectContains(output, "fd:0:");
    try expectContains(output, "fd:1:");
    try expectContains(output, "fd:2:");
    try expectNotContains(output, "fd:50:");
    try expectNotContains(output, "fd:51:");
    // The original pipe ends, the PTY master and the startup pipe are gone
    // too: nothing above the glob's own directory handle (3) is open.
    try expectNotContains(output, "fd:4:");
    try expectNotContains(output, "fd:5:");
    try expectNotContains(output, "fd:6:");
}

const ConcurrentSpawn = struct {
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *ConcurrentSpawn) void {
        self.check() catch self.failed.store(true, .seq_cst);
    }

    fn check(self: *ConcurrentSpawn) !void {
        _ = self;
        const allocator = std.testing.allocator;
        var round: usize = 0;
        while (round < 3) : (round += 1) {
            const output = try runAndCollect(allocator, .{ .shell = "/bin/sh", .command = fd_listing_command });
            defer allocator.free(output);
            try expectContains(output, "fd:0:");
            // Allowed: stdio, the glob's own directory handle (3), and the
            // shell's private high descriptors (10 for dash, 255 for bash).
            var it = std.mem.tokenizeAny(u8, output, "\r\n");
            while (it.next()) |line| {
                if (!std.mem.startsWith(u8, line, "fd:")) continue;
                const number = std.fmt.parseInt(u32, std.mem.trim(u8, line[3..], ":"), 10) catch continue;
                if (number > 3 and number != 10 and number != 255) {
                    std.debug.print("foreign descriptor {d} in child:\n{s}\n", .{ number, output });
                    return error.ForeignDescriptor;
                }
            }
        }
    }
};

test "concurrent spawns and descriptor churn leak no foreign descriptors" {
    if (!supported_os) return error.SkipZigTest;

    var state: ConcurrentSpawn = .{};
    var threads: [8]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    while (started < threads.len) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, ConcurrentSpawn.run, .{&state});
    }
    // Churn sockets and pipes on this thread while the others fork.
    var churn: usize = 0;
    while (churn < 400) : (churn += 1) {
        const sock = try sys.unixStreamSocket();
        const pipe_fds = try sys.pipeCloexec();
        sys.close(sock);
        sys.close(pipe_fds[0]);
        sys.close(pipe_fds[1]);
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    try std.testing.expect(!state.failed.load(.seq_cst));
}

test "a slave descriptor inside the stdio range is still wired to all of stdio" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // Reproduce a daemon started with stdin closed: the PTY slave lands on
    // fd 0. The test runner's own stdin is parked and restored around it.
    const fds = try openPty(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    const saved_stdin = std.c.fcntl(0, std.c.F.DUPFD_CLOEXEC, @as(c_int, 10));
    try std.testing.expect(saved_stdin >= 10);
    defer sys.close(saved_stdin);

    try sys.dup2(fds.slave_fd, 0);
    sys.close(fds.slave_fd);
    try sys.setCloseOnExec(0);
    // spawnOnFds closes the slave (fd 0) in the parent; restore stdin after.
    const spawned = Pty.spawnOnFds(allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then echo stdio-is-tty; fi; read line; echo got=[$line]",
    }, fds.master_fd, 0);
    try sys.dup2(saved_stdin, 0);

    var child = try spawned;
    // The pidfd was allocated on the just-freed fd 0, which the dup2 above
    // has since replaced with the real stdin; forget it so `close` does not
    // close the runner's stdin.
    if (child.pid_fd == 0) child.pid_fd = -1;
    defer cleanupPtyForTest(&child);
    try child.write("ping\n", sys.monotonicMs() + 2000, -1);
    const output = try collectOutput(allocator, &child, 10_000);
    defer allocator.free(output);
    try expectContains(output, "stdio-is-tty");
    try expectContains(output, "got=[ping]");
}

test "reapExited tolerates children auto-reaped by ignored SIGCHLD" {
    if (!supported_os) return error.SkipZigTest;

    var old_action: posix.Sigaction = undefined;
    posix.sigaction(std.c.SIG.CHLD, null, &old_action);
    defer posix.sigaction(std.c.SIG.CHLD, &old_action, null);

    var ignored: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&ignored), 0);
    ignored.handler = .{ .handler = posix.SIG.IGN };
    ignored.mask = std.mem.zeroes(posix.sigset_t);
    ignored.flags = 0;
    posix.sigaction(std.c.SIG.CHLD, &ignored, null);

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 24,
        .cols = 80,
    });
    defer child.close();

    try std.testing.expect(child.waitBlocking(2000));
    try std.testing.expect(child.isReaped());
    try std.testing.expect(child.exit_status == null);

    // The ECHILD path counts as reaped: nothing may be signalled afterwards.
    const kills_before = sys.kill_call_count.load(.seq_cst);
    child.terminate();
    child.kill();
    child.hangupForeground();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));
}

test "terminate, kill and hangupForeground never signal a reaped child" {
    if (!supported_os) return error.SkipZigTest;

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exit 3" });
    defer child.close();

    // While the child is alive a signal is delivered through sys.kill.
    try std.testing.expect(child.waitBlocking(5000));
    try std.testing.expectEqual(@as(u32, 3), posix.W.EXITSTATUS(child.exit_status.?));

    // The PID is free for reuse now. None of these may call kill(2).
    const kills_before = sys.kill_call_count.load(.seq_cst);
    child.terminate();
    child.kill();
    child.hangupForeground();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));

    // A live child, by contrast, is signalled and dies.
    var live = try Pty.spawn(std.testing.allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer live.close();
    const live_before = sys.kill_call_count.load(.seq_cst);
    live.kill();
    try std.testing.expect(sys.kill_call_count.load(.seq_cst) > live_before);
    try std.testing.expect(live.waitBlocking(5000));
    try std.testing.expectEqual(posix.SIG.KILL, posix.W.TERMSIG(live.exit_status.?));
}

test "children start with default signal dispositions and an empty mask" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // Spawn from a parent that ignores SIGHUP/SIGPIPE and blocks SIGTERM,
    // like a daemon. An ignored disposition survives exec unless reset.
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

    if (is_linux) {
        const output = try runAndCollect(allocator, .{
            .shell = "/bin/sh",
            .command = "grep -E '^Sig(Ign|Blk):' /proc/self/status",
        });
        defer allocator.free(output);
        try expectContains(output, "SigIgn:\t0000000000000000");
        try expectContains(output, "SigBlk:\t0000000000000000");
    }

    // Behavioural check on every platform: the child dies from SIGHUP
    // instead of ignoring it.
    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer cleanupPtyForTest(&child);
    testSleepMs(50);
    child.hangupForeground();
    try std.testing.expect(child.waitBlocking(5000));
    try std.testing.expectEqual(posix.SIG.HUP, posix.W.TERMSIG(child.exit_status.?));
}

test "hangupForeground reaches a foreground job in its own process group" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // An interactive shell with job control puts the foreground command in
    // its own process group, which a signal to the shell's group misses.
    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh" });
    defer cleanupPtyForTest(&child);
    try child.write("sleep 9998\n", sys.monotonicMs() + 2000, -1);

    var fg: posix.pid_t = 0;
    const deadline = sys.monotonicMs() + 5000;
    var sink: [4096]u8 = undefined;
    while (sys.monotonicMs() < deadline) {
        if (child.pollReadable(10) catch false) _ = child.read(&sink) catch 0;
        fg = tcgetpgrp(child.master_fd);
        if (fg > 1 and fg != child.child_pid) break;
    }
    try std.testing.expect(fg > 1 and fg != child.child_pid);
    try std.testing.expect(processExists(fg));

    child.hangupForeground();
    try std.testing.expect(child.waitBlocking(5000));
    var waited: usize = 0;
    while (processExists(fg) and waited < 500) : (waited += 1) testSleepMs(10);
    try std.testing.expect(!processExists(fg));
}

fn lineBlock(allocator: Allocator, total: usize) ![]u8 {
    // Newline-terminated lines: in canonical mode the kernel discards
    // overflow on an unterminated line instead of applying backpressure.
    const data = try allocator.alloc(u8, total);
    for (data, 0..) |*byte, index| byte.* = if (index % 64 == 63) '\n' else 'x';
    return data;
}

test "write times out when the child never reads" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer cleanupPtyForTest(&child);
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);

    const started = sys.monotonicMs();
    try std.testing.expectError(error.InputTimeout, child.write(data, started + 300, -1));
    const elapsed = sys.monotonicMs() - started;
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < 600);

    // An already-expired deadline fails without waiting once the queue is full.
    const again = sys.monotonicMs();
    try std.testing.expectError(error.InputTimeout, child.write(data, again - 1, -1));
    try std.testing.expect(sys.monotonicMs() - again < 100);
}

const StopWriter = struct {
    fd: posix.fd_t,
    delay_ms: i64,

    fn run(self: *StopWriter) void {
        sys.sleepMs(self.delay_ms);
        _ = sys.write(self.fd, "x") catch {};
    }
};

test "write is cancelled by the stop descriptor" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer cleanupPtyForTest(&child);
    const data = try lineBlock(allocator, 1024 * 1024);
    defer allocator.free(data);
    const stop = try sys.pipeCloexec();
    defer sys.close(stop[0]);
    defer sys.close(stop[1]);

    var stopper = StopWriter{ .fd = stop[1], .delay_ms = 100 };
    const thread = try std.Thread.spawn(.{}, StopWriter.run, .{&stopper});
    const started = sys.monotonicMs();
    const result = child.write(data, started + 30_000, stop[0]);
    const elapsed = sys.monotonicMs() - started;
    thread.join();
    try std.testing.expectError(error.InputClosed, result);
    try std.testing.expect(elapsed >= 90);
    try std.testing.expect(elapsed < 100 + 150);
}

test "write delivers input to a reading child and fails after close" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "read line; echo echoed=[$line]" });
    defer cleanupPtyForTest(&child);
    try child.write("", sys.monotonicMs() + 1000, -1);
    try child.write("hello\n", sys.monotonicMs() + 2000, -1);
    const output = try collectOutput(allocator, &child, 10_000);
    defer allocator.free(output);
    try expectContains(output, "echoed=[hello]");

    child.close();
    try std.testing.expectError(error.InputClosed, child.write("late", sys.monotonicMs() + 1000, -1));
    try std.testing.expectError(error.ResizeFailed, child.resize(80, 24));
    child.close();
}

test "resize round-trips the window size through the terminal" {
    if (!supported_os) return error.SkipZigTest;

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "exec sleep 100",
        .rows = 30,
        .cols = 100,
    });
    defer cleanupPtyForTest(&child);
    const initial = try child.windowSize();
    try std.testing.expectEqual(@as(u16, 30), initial.row);
    try std.testing.expectEqual(@as(u16, 100), initial.col);

    try child.resize(132, 43);
    const resized = try child.windowSize();
    try std.testing.expectEqual(@as(u16, 43), resized.row);
    try std.testing.expectEqual(@as(u16, 132), resized.col);
}

fn spawnWithEnvForFailureTest(allocator: Allocator) !void {
    const env = [_][]const u8{ "FOO=bar", "BAZ=qux" };
    var child = try Pty.spawn(allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .env = &env,
        .rows = 24,
        .cols = 80,
    });
    defer cleanupPtyForTest(&child);
}

test "spawn allocation failures leak no memory, descriptors or children" {
    if (!supported_os) return error.SkipZigTest;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, spawnWithEnvForFailureTest, .{});
}

test "spawn with bare shell (no command) exits cleanly" {
    if (!supported_os) return error.SkipZigTest;

    var pty = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = null,
        .rows = 24,
        .cols = 80,
    });

    // Kill, then close the master; the reap must succeed exactly once.
    pty.kill();
    pty.close();
    try std.testing.expect(pty.waitBlocking(2000));
    try std.testing.expect(pty.reapExited() != null);
    try std.testing.expect(pty.pid_fd == -1 and pty.master_fd == -1);
}
