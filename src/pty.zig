const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const posix = std.posix;

extern "c" fn openpty(
    amaster: *posix.fd_t,
    aslave: *posix.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;

pub const SpawnOptions = struct {
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const ExitObserver = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, pid: posix.pid_t, status: ?u32) void,
};

pub const Pty = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    wait_mutex: std.Thread.Mutex = .{},
    reaped: bool = false,
    exit_status: ?u32 = null,
    exit_observer: ?ExitObserver = null,

    pub fn spawn(allocator: Allocator, opts: SpawnOptions) !Pty {
        const wsz: posix.winsize = .{
            .row = opts.rows,
            .col = opts.cols,
            .xpixel = 0,
            .ypixel = 0,
        };

        const fds = try openPty(wsz);
        const master_fd = fds.master_fd;
        const slave_fd = fds.slave_fd;
        errdefer posix.close(master_fd);
        errdefer posix.close(slave_fd);

        const shell_path = opts.shell orelse defaultShell();
        const shell_z = try allocator.dupeZ(u8, shell_path);
        defer allocator.free(shell_z);

        const command_z = if (opts.command) |command| try allocator.dupeZ(u8, command) else null;
        defer if (command_z) |command| allocator.free(command);

        const cwd_z = if (opts.cwd) |cwd| try allocator.dupeZ(u8, cwd) else null;
        defer if (cwd_z) |cwd| allocator.free(cwd);

        var env_storage = std.ArrayList([:0]u8).empty;
        defer {
            for (env_storage.items) |entry| allocator.free(entry);
            env_storage.deinit(allocator);
        }
        var env_ptrs = std.ArrayList(?[*:0]const u8).empty;
        defer env_ptrs.deinit(allocator);
        if (opts.env) |env_entries| {
            for (env_entries) |entry| {
                const entry_z = try allocator.dupeZ(u8, entry);
                var entry_owned = true;
                errdefer if (entry_owned) allocator.free(entry_z);
                try env_storage.append(allocator, entry_z);
                entry_owned = false;
                try env_ptrs.append(allocator, entry_z.ptr);
            }
            try env_ptrs.append(allocator, null);
        }

        const argv_shell = [_:null]?[*:0]const u8{ shell_z.ptr, "-l" };
        // Keep the sentinel-terminated literal valid in the command == null branch
        // by pointing the 4th slot at an empty string; we only take &argv_command
        // when command_z is non-null, but the initializer is always evaluated.
        const argv_command = [_:null]?[*:0]const u8{ shell_z.ptr, "-l", "-c", if (command_z) |command| command.ptr else "" };
        const argv = if (command_z != null) &argv_command else &argv_shell;
        const envp: [*:null]const ?[*:0]const u8 = if (opts.env != null)
            @ptrCast(env_ptrs.items.ptr)
        else
            @ptrCast(std.c.environ);

        const pid = try posix.fork();
        if (pid == 0) {
            childExec(master_fd, slave_fd, cwd_z, shell_z.ptr, argv, envp);
        }

        posix.close(slave_fd);
        return .{
            .master_fd = master_fd,
            .child_pid = pid,
        };
    }

    pub fn close(self: *Pty) void {
        posix.close(self.master_fd);
    }

    pub fn setExitObserver(self: *Pty, observer: ExitObserver) void {
        var should_emit = false;
        var emit_status: ?u32 = null;

        self.wait_mutex.lock();
        self.exit_observer = observer;
        if (self.reaped) {
            should_emit = true;
            emit_status = self.exit_status;
        }
        self.wait_mutex.unlock();

        if (should_emit) {
            observer.callback(observer.context, self.child_pid, emit_status);
        }
    }

    pub fn terminate(self: *const Pty) void {
        const pgid: posix.pid_t = -self.child_pid;
        if (std.c.kill(pgid, posix.SIG.TERM) != 0) {
            _ = std.c.kill(self.child_pid, posix.SIG.TERM);
        }
    }

    pub fn kill(self: *const Pty) void {
        const pgid: posix.pid_t = -self.child_pid;
        if (std.c.kill(pgid, posix.SIG.KILL) != 0) {
            _ = std.c.kill(self.child_pid, posix.SIG.KILL);
        }
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

    pub fn read(self: *const Pty, buffer: []u8) !usize {
        return posix.read(self.master_fd, buffer);
    }

    pub fn write(self: *const Pty, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            offset += try posix.write(self.master_fd, bytes[offset..]);
        }
    }

    pub fn resize(self: *const Pty, cols: u16, rows: u16) !void {
        var wsz: posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (std.c.ioctl(self.master_fd, ioctlRequest(tiocswinsz()), &wsz) != 0) return error.ResizeFailed;
    }

    pub fn reapExited(self: *Pty) ?u32 {
        var observer: ?ExitObserver = null;
        var should_emit = false;
        var status_to_emit: ?u32 = null;

        self.wait_mutex.lock();
        if (self.reaped) {
            const status = self.exit_status;
            self.wait_mutex.unlock();
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
        self.wait_mutex.unlock();

        if (should_emit) {
            if (observer) |active| {
                active.callback(active.context, self.child_pid, status_to_emit);
            }
        }

        if (status_to_emit) |status| return status;
        return null;
    }

    pub fn isReaped(self: *Pty) bool {
        self.wait_mutex.lock();
        defer self.wait_mutex.unlock();
        return self.reaped;
    }
};

const OpenPtyResult = struct {
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
};

fn openPty(wsz: posix.winsize) !OpenPtyResult {
    var master_fd: posix.fd_t = undefined;
    var slave_fd: posix.fd_t = undefined;
    if (openpty(&master_fd, &slave_fd, null, null, &wsz) != 0) return error.OpenPtyFailed;
    errdefer posix.close(master_fd);
    errdefer posix.close(slave_fd);

    try setCloseOnExec(master_fd);
    try setCloseOnExec(slave_fd);

    return .{
        .master_fd = master_fd,
        .slave_fd = slave_fd,
    };
}

fn setCloseOnExec(fd: posix.fd_t) !void {
    var flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    flags |= @as(usize, @intCast(posix.FD_CLOEXEC));
    _ = try posix.fcntl(fd, posix.F.SETFD, flags);
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
            .CHILD => return .{ .exited = null },
            .INVAL => unreachable,
            else => unreachable,
        }
    }
}

fn childExec(
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
    cwd_z: ?[:0]u8,
    shell_path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    _ = std.c.close(master_fd);
    _ = std.c.setsid();
    _ = std.c.ioctl(slave_fd, ioctlRequest(tiocsctty()), @as(c_int, 0));
    _ = std.c.dup2(slave_fd, 0);
    _ = std.c.dup2(slave_fd, 1);
    _ = std.c.dup2(slave_fd, 2);
    if (slave_fd > 2) _ = std.c.close(slave_fd);
    if (cwd_z) |cwd| {
        if (std.c.chdir(cwd.ptr) != 0) {
            const errno = std.c._errno().*;
            // stderr is wired to the slave PTY here, so this surfaces to the
            // terminal buffer and any log scraper capturing PTY output.
            const fd: i32 = 2;
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zmux-pty: chdir(\"{s}\") failed errno={d}\n", .{
                std.mem.sliceTo(cwd.ptr, 0), errno,
            }) catch "zmux-pty: chdir failed\n";
            _ = std.c.write(fd, msg.ptr, msg.len);
        }
    }
    const err = posix.execvpeZ(shell_path, argv, envp);
    const fd: i32 = 2;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zmux-pty: execvpe(\"{s}\") failed: {s}\n", .{
        std.mem.sliceTo(shell_path, 0), @errorName(err),
    }) catch "zmux-pty: execvpe failed\n";
    _ = std.c.write(fd, msg.ptr, msg.len);
    std.c._exit(127);
}

fn defaultShell() []const u8 {
    if (posix.getenv("SHELL")) |shell| {
        if (shell.len > 0) return shell;
    }
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/bin/zsh",
        else => "/bin/sh",
    };
}

fn tiocswinsz() usize {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x80087467,
        else => posix.T.IOCSWINSZ,
    };
}

fn tiocsctty() usize {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x20007461,
        else => posix.T.IOCSCTTY,
    };
}

fn ioctlRequest(value: usize) c_int {
    return @bitCast(@as(u32, @truncate(value)));
}

test "default shell is absolute" {
    try std.testing.expect(std.mem.startsWith(u8, defaultShell(), "/"));
}

test "open pty marks master and slave close-on-exec" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const fds = try openPty(.{
        .row = 24,
        .col = 80,
        .xpixel = 0,
        .ypixel = 0,
    });
    defer posix.close(fds.master_fd);
    defer posix.close(fds.slave_fd);

    const master_flags = try posix.fcntl(fds.master_fd, posix.F.GETFD, 0);
    const slave_flags = try posix.fcntl(fds.slave_fd, posix.F.GETFD, 0);
    const cloexec = @as(usize, @intCast(posix.FD_CLOEXEC));
    try std.testing.expect((master_flags & cloexec) != 0);
    try std.testing.expect((slave_flags & cloexec) != 0);
}

test "reapExited tolerates children auto-reaped by ignored SIGCHLD" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    var old_action: posix.Sigaction = undefined;
    posix.sigaction(std.c.SIG.CHLD, null, &old_action);
    defer posix.sigaction(std.c.SIG.CHLD, &old_action, null);

    var ignored: posix.Sigaction = undefined;
    @memset(std.mem.asBytes(&ignored), 0);
    ignored.handler = .{ .handler = posix.SIG.IGN };
    ignored.mask = std.mem.zeroes(posix.sigset_t);
    ignored.flags = 0;
    posix.sigaction(std.c.SIG.CHLD, &ignored, null);

    var child = try Pty.spawn(std.testing.allocator, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .rows = 24,
        .cols = 80,
    });
    defer child.close();
    defer if (!child.isReaped()) child.kill();

    var waited: u32 = 0;
    while (waited < 50 and !child.isReaped()) : (waited += 1) {
        _ = child.reapExited();
        if (child.isReaped()) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(child.isReaped());
    try std.testing.expect(child.exit_status == null);
}

fn cleanupPtyForTest(child: *Pty) void {
    child.kill();
    var waited: u32 = 0;
    while (waited < 50) : (waited += 1) {
        if (child.reapExited() != null) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    child.close();
}

fn spawnWithEnvForFailureTest(allocator: Allocator) !void {
    const env = [_][]const u8{ "FOO=bar", "BAZ=qux" };
    var child = try Pty.spawn(allocator, .{
        .shell = "/bin/sh",
        .command = "exit 0",
        .env = &env,
        .rows = 24,
        .cols = 80,
    });
    defer cleanupPtyForTest(&child);
}

test "spawn env allocation failures clean up env entry ownership" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, spawnWithEnvForFailureTest, .{});
}

test "spawn with bare shell (no command) exits cleanly" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    // /bin/sh -c ':' via command path is exercised elsewhere; this path
    // covers the bare-login case that used to trip `unreachable`.
    var pty = try Pty.spawn(std.testing.allocator, .{
        .shell = "/bin/sh",
        .command = null,
        .rows = 24,
        .cols = 80,
    });

    // Close the master immediately so the shell gets EOF on stdin and exits.
    pty.close();
    pty.kill();

    // Reap exactly once (waitpid with WNOHANG panics on ECHILD). Give the
    // kernel up to ~500ms to mark the child exited.
    var waited: u32 = 0;
    var reaped = false;
    while (waited < 50) : (waited += 1) {
        if (pty.reapExited() != null) {
            reaped = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(reaped);
}
