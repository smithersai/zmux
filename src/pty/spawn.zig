//! The parent side of `Pty.spawn`: prepare every C string, fork, and wait
//! for the child's bounded startup receipt.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const pty = @import("../pty.zig");
const child_mod = @import("child.zig");
const env_mod = @import("env.zig");
const proc = @import("proc.zig");

const Pty = pty.Pty;
const SpawnOptions = pty.SpawnOptions;
const ChildSetupStage = pty.ChildSetupStage;
const supported_os = proc.supported_os;

/// Fork the child onto an already-open PTY pair. Takes ownership of both
/// descriptors on success and on failure.
pub fn spawnOnFds(
    allocator: Allocator,
    io: std.Io,
    opts: SpawnOptions,
    master_fd: posix.fd_t,
    slave_fd: posix.fd_t,
) !Pty {
    assert(master_fd >= 0);
    assert(slave_fd >= 0);
    assert(master_fd != slave_fd);
    var slave_open = true;
    defer if (slave_open) sys.close(slave_fd);
    errdefer sys.close(master_fd);

    // Everything the child needs is prepared here: after `fork` in a
    // multi-threaded process the child may not allocate or take locks.
    const shell_path = opts.shell orelse env_mod.defaultShell();
    const shell_z = try allocator.dupeSentinel(u8, shell_path, 0);
    defer allocator.free(shell_z);

    const command_z = if (opts.command) |command| try allocator.dupeSentinel(u8, command, 0) else null;
    defer if (command_z) |command| allocator.free(command);

    const cwd_z = if (opts.cwd) |cwd| try allocator.dupeSentinel(u8, cwd, 0) else null;
    defer if (cwd_z) |cwd| allocator.free(cwd);
    const cwd_ptr: ?[*:0]const u8 = if (cwd_z) |cwd| cwd.ptr else null;

    var env = try env_mod.buildEnv(allocator, sys.currentEnviron(), opts.env, opts.env_mode);
    defer env.deinit(allocator);

    var candidates = try env_mod.resolveExecCandidates(allocator, shell_path, env_mod.execPathEnv());
    defer candidates.deinit(allocator);

    const argv_shell = [_:null]?[*:0]const u8{ shell_z.ptr, "-l" };
    // Slot 4 is read only with a command, but is always initialized.
    const command_ptr: [*:0]const u8 = if (command_z) |command| command.ptr else "";
    const argv_command = [_:null]?[*:0]const u8{ shell_z.ptr, "-l", "-c", command_ptr };
    const argv: [*:null]const ?[*:0]const u8 = if (command_z != null) &argv_command else &argv_shell;

    const err_pipe = try sys.pipeCloexec();
    var err_read_open = true;
    defer if (err_read_open) sys.close(err_pipe[0]);
    var err_write_open = true;
    defer if (err_write_open) sys.close(err_pipe[1]);
    assert(err_pipe[0] >= 0);
    assert(err_pipe[1] >= 0);
    const pid = sys.fork() catch return error.ForkFailed;
    if (pid == 0) {
        child_mod.childExec(slave_fd, err_pipe[1], cwd_ptr, candidates.list(), argv, env.list());
    }

    sys.close(slave_fd);
    slave_open = false;
    sys.close(err_pipe[1]);
    err_write_open = false;

    assert(pid > 0);
    try awaitChildExec(pid, err_pipe[0]);
    sys.close(err_pipe[0]);
    err_read_open = false;

    return .{
        .io = io,
        .master_fd = master_fd,
        .child_pid = pid,
        .pid_fd = child_mod.openPidFd(pid),
    };
}

/// Wait for the forked child's startup receipt on `err_read_fd`.
/// EOF means `exec` succeeded (the pipe is close-on-exec); a report
/// means setup failed and the child has already called `_exit`. The
/// wait is bounded: callers hold locks across `spawn`. On failure the
/// child is reaped and `pty.last_child_setup_failure` is set.
pub fn awaitChildExec(pid: posix.pid_t, err_read_fd: posix.fd_t) error{ChildSetupFailed}!void {
    assert(pid > 0);
    assert(err_read_fd >= 0);
    switch (child_mod.readChildReport(err_read_fd, sys.monotonicMs() + pty.child_setup_timeout_ms)) {
        .exec_ok => return,
        .failed => |report| {
            child_mod.reapBlocking(pid);
            pty.last_child_setup_failure = .{ .stage = report.stage, .errno = report.errno, .pid = pid };
        },
        .timed_out => {
            child_mod.killAndReap(pid);
            pty.last_child_setup_failure = .{ .stage = .unknown, .errno = .TIMEDOUT, .pid = pid };
        },
        // Neither a confirmed exec nor a report: the child's state is
        // unknown, so it is not allowed to run on.
        .io_error => |errno_value| {
            child_mod.killAndReap(pid);
            pty.last_child_setup_failure = .{ .stage = .unknown, .errno = errno_value, .pid = pid };
        },
    }
    return error.ChildSetupFailed;
}

// ---------------------------------------------------------------------------
// Tests

test "spawn resolves a relative shell name through PATH" {
    if (!supported_os) return error.SkipZigTest;

    const output = try proc.runAndCollect(std.testing.allocator, .{ .shell = "sh", .command = "echo relative-shell-ok" });
    defer std.testing.allocator.free(output);
    try proc.expectContains(output, "relative-shell-ok");
}

test "spawned child sees the merged environment" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // /usr/bin/env is found through the inherited PATH, proving the daemon
    // environment survived the merge.
    const env = [_][]const u8{ "ZMUX_T2_MARK=merged", "TERM=vt220" };
    const output = try proc.runAndCollect(allocator, .{
        .shell = "/bin/sh",
        .command = "env | grep -E '^(ZMUX_T2_MARK|TERM|PATH)=' ; echo done-env",
        .env = &env,
    });
    defer allocator.free(output);
    try proc.expectContains(output, "ZMUX_T2_MARK=merged");
    try proc.expectContains(output, "TERM=vt220");
    try proc.expectContains(output, "PATH=");
    try proc.expectContains(output, "done-env");
}

test "spawned child with replace sees only the supplied entries and TERM" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // `export -p` is a shell builtin, so it works without any PATH. HOME is
    // not something /bin/sh sets on its own, so its absence proves the
    // daemon environment was dropped.
    const env = [_][]const u8{"ZMUX_T2_ONLY=1"};
    const output = try proc.runAndCollect(allocator, .{
        .shell = "/bin/sh",
        .command = "export -p; echo home=[${HOME-unset}] term=[$TERM]",
        .env = &env,
        .env_mode = .replace,
    });
    defer allocator.free(output);
    try proc.expectContains(output, "ZMUX_T2_ONLY");
    try proc.expectContains(output, "home=[unset]");
    try proc.expectContains(output, "term=[" ++ pty.default_term ++ "]");
}

test "spawn defaults TERM when the daemon environment has none" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const output = try proc.runAndCollect(allocator, .{
        .shell = "/bin/sh",
        .command = "echo term=[$TERM]",
        .env = &.{},
        .env_mode = .replace,
    });
    defer allocator.free(output);
    try proc.expectContains(output, "term=[" ++ pty.default_term ++ "]");
}

test "a failing chdir reports ChildSetupFailed and leaves no process" {
    if (!supported_os) return error.SkipZigTest;

    pty.last_child_setup_failure = null;
    try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "echo should-not-run",
        .cwd = "/zmux/no/such/directory",
    }));
    const failure = pty.last_child_setup_failure.?;
    try std.testing.expectEqual(ChildSetupStage.chdir, failure.stage);
    try std.testing.expectEqual(posix.E.NOENT, failure.errno);
    // Already reaped: waitpid has nothing left to collect.
    const rc = std.c.waitpid(failure.pid, null, @intCast(posix.W.NOHANG));
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(posix.E.CHILD, posix.errno(rc));
}

test "a child stuck before exec is killed at the handshake deadline" {
    if (!supported_os) return error.SkipZigTest;

    const saved_timeout = pty.child_setup_timeout_ms;
    pty.child_setup_timeout_ms = 200;
    child_mod.test_stall_child_setup = true;
    defer {
        pty.child_setup_timeout_ms = saved_timeout;
        child_mod.test_stall_child_setup = false;
    }

    pty.last_child_setup_failure = null;
    const started = sys.monotonicMs();
    try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "echo should-not-run",
    }));
    const elapsed = sys.monotonicMs() - started;
    try std.testing.expect(elapsed >= 200);
    try std.testing.expect(elapsed < 200 + child_mod.child_setup_reap_budget_ms);

    const failure = pty.last_child_setup_failure.?;
    try std.testing.expectEqual(ChildSetupStage.unknown, failure.stage);
    try std.testing.expectEqual(posix.E.TIMEDOUT, failure.errno);
    // Killed and reaped: waitpid has nothing left to collect.
    const rc = std.c.waitpid(failure.pid, null, @intCast(posix.W.NOHANG));
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(posix.E.CHILD, posix.errno(rc));
}

test "a missing shell reports ChildSetupFailed at the exec stage" {
    if (!supported_os) return error.SkipZigTest;

    for ([_][]const u8{ "/zmux/no/such/shell", "zmux-no-such-shell" }) |shell| {
        pty.last_child_setup_failure = null;
        try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
            .shell = shell,
            .command = "true",
        }));
        const failure = pty.last_child_setup_failure.?;
        try std.testing.expectEqual(ChildSetupStage.exec, failure.stage);
        try std.testing.expectEqual(posix.E.NOENT, failure.errno);
        const wait_rc = std.c.waitpid(failure.pid, null, @intCast(posix.W.NOHANG));
        try std.testing.expectEqual(posix.E.CHILD, posix.errno(wait_rc));
    }

    // A file that exists but is not executable surfaces EACCES, not ENOENT.
    pty.last_child_setup_failure = null;
    try std.testing.expectError(error.ChildSetupFailed, Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/etc/passwd",
        .command = "true",
    }));
    try std.testing.expectEqual(ChildSetupStage.exec, pty.last_child_setup_failure.?.stage);
    try std.testing.expectEqual(posix.E.ACCES, pty.last_child_setup_failure.?.errno);
}

test "a valid cwd is applied before exec" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const output = try proc.runAndCollect(allocator, .{ .shell = "/bin/sh", .command = "echo cwd=[$(pwd -P)]", .cwd = "/" });
    defer allocator.free(output);
    try proc.expectContains(output, "cwd=[/]");
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

    const output = try proc.runAndCollect(allocator, .{ .shell = "/bin/sh", .command = fd_listing_command });
    defer allocator.free(output);
    try proc.expectContains(output, "fd:0:");
    try proc.expectContains(output, "fd:1:");
    try proc.expectContains(output, "fd:2:");
    try proc.expectNotContains(output, "fd:50:");
    try proc.expectNotContains(output, "fd:51:");
    // The original pipe ends, the PTY master and the startup pipe are gone
    // too: nothing above the glob's own directory handle (3) is open.
    try proc.expectNotContains(output, "fd:4:");
    try proc.expectNotContains(output, "fd:5:");
    try proc.expectNotContains(output, "fd:6:");
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
            const output = try proc.runAndCollect(allocator, .{ .shell = "/bin/sh", .command = fd_listing_command });
            defer allocator.free(output);
            try proc.expectContains(output, "fd:0:");
            // Allowed: stdio, the glob's own directory handle (3), and the
            // shell's private high descriptors (10 for dash, 255 for bash).
            var it = std.mem.tokenizeAny(u8, output, "\r\n");
            while (it.next()) |line| {
                if (!std.mem.startsWith(u8, line, "fd:")) continue;
                const number = std.fmt.parseInt(u32, std.mem.trim(u8, line[3..], ":"), 10) catch continue;
                if (number > 3 and number != 10 and number != 255) {
                    log.err("pty_test_foreign_descriptor", .{ .fd = number, .output = output });
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
    const fds = try child_mod.openPty(.{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 });
    const saved_stdin = std.c.fcntl(0, std.c.F.DUPFD_CLOEXEC, @as(c_int, 10));
    try std.testing.expect(saved_stdin >= 10);
    defer sys.close(saved_stdin);

    try sys.dup2(fds.slave_fd, 0);
    sys.close(fds.slave_fd);
    try sys.setCloseOnExec(0);
    // spawnOnFds closes the slave (fd 0) in the parent; restore stdin after.
    const spawned = spawnOnFds(allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then echo stdio-is-tty; fi; read line; echo got=[$line]",
    }, fds.master_fd, 0);
    try sys.dup2(saved_stdin, 0);

    var child = try spawned;
    // The pidfd was allocated on the just-freed fd 0, which the dup2 above
    // has since replaced with the real stdin; forget it so `close` does not
    // close the runner's stdin.
    if (child.pid_fd == 0) child.pid_fd = -1;
    defer proc.cleanupPtyForTest(&child);
    try child.write("ping\n", sys.monotonicMs() + 2000, -1);
    const output = try proc.collectOutput(allocator, &child, 10_000);
    defer allocator.free(output);
    try proc.expectContains(output, "stdio-is-tty");
    try proc.expectContains(output, "got=[ping]");
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
    defer proc.cleanupPtyForTest(&child);
}

test "spawn allocation failures leak no memory, descriptors or children" {
    if (!supported_os) return error.SkipZigTest;

    try std.testing.checkAllAllocationFailures(std.testing.allocator, spawnWithEnvForFailureTest, .{});
}

test "spawn with bare shell (no command) exits cleanly" {
    if (!supported_os) return error.SkipZigTest;

    var bare = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = null,
        .rows = 24,
        .cols = 80,
    });

    // Kill, then close the master; the reap must succeed exactly once.
    bare.kill();
    bare.close();
    try std.testing.expect(bare.waitBlocking(2000));
    try std.testing.expect(bare.reapExited() != null);
    try std.testing.expect(bare.pid_fd == -1 and bare.master_fd == -1);
}
