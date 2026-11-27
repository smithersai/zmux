//! Signal delivery for a running `Pty`: termination, hangup, and tracking
//! of the terminal's foreground job so it can be signalled after the shell
//! exits first. Every signal is sent under `wait_mutex`.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;
const posix = std.posix;
const sys = @import("../sys.zig");
const session_mod = @import("session.zig");
const child_mod = @import("child.zig");
const proc = @import("proc.zig");

const Pty = session_mod.Pty;
const is_linux = builtin.os.tag == .linux;
const supported_os = proc.supported_os;
const tcgetpgrp = child_mod.tcgetpgrp;

/// SIGTERM to the terminal foreground group (when it is not the shell
/// group) and to the shell group. Once the child is reaped its PID and
/// group id may name an unrelated process, so the shell group is never
/// signalled again; a remembered foreground group that still belongs to
/// this session is.
pub fn terminate(self: *Pty) void {
    assert(self.child_pid > 0);
    self.wait_mutex.lockUncancelable(self.io);
    const notify = self.refreshReapLocked();
    if (foregroundTargetLocked(self)) |fg| _ = sys.kill(-fg, .TERM);
    if (!self.reaped) signalShellGroupLocked(self, .TERM);
    self.wait_mutex.unlock(self.io);
    self.notifyExit(notify);
}

/// SIGKILL to the terminal foreground group (when it is not the shell
/// group) and to the shell group. The shell group is skipped once the
/// child is reaped; see `terminate`.
pub fn kill(self: *Pty) void {
    assert(self.child_pid > 0);
    self.wait_mutex.lockUncancelable(self.io);
    const notify = self.refreshReapLocked();
    if (foregroundTargetLocked(self)) |fg| {
        _ = sys.kill(-fg, .KILL);
        // SIGKILL is final: nothing is left to escalate for this group.
        self.foreground_pgid = 0;
    }
    if (!self.reaped) signalShellGroupLocked(self, .KILL);
    self.wait_mutex.unlock(self.io);
    self.notifyExit(notify);
}

/// SIGHUP+SIGCONT to the terminal foreground group when it is not the
/// shell group, then to the shell group. SIGCONT lets stopped jobs act on
/// the hangup. The foreground group is remembered for later escalation.
/// The shell group is skipped once the child is reaped; see `terminate`.
pub fn hangupForeground(self: *Pty) void {
    assert(self.child_pid > 0);
    self.wait_mutex.lockUncancelable(self.io);
    const notify = self.refreshReapLocked();
    if (foregroundTargetLocked(self)) |fg| {
        _ = sys.kill(-fg, .HUP);
        _ = sys.kill(-fg, .CONT);
    }
    if (!self.reaped) {
        signalShellGroupLocked(self, .HUP);
        signalShellGroupLocked(self, .CONT);
    }
    self.wait_mutex.unlock(self.io);
    self.notifyExit(notify);
}

/// Remember the terminal's current foreground group while the shell is
/// alive, so it can still be signalled after the shell exits first.
/// Cheap (one `tcgetpgrp`); meant to be called periodically.
pub fn captureForeground(self: *Pty) void {
    assert(self.child_pid > 0);
    self.wait_mutex.lockUncancelable(self.io);
    defer self.wait_mutex.unlock(self.io);
    if (!self.reaped) _ = foregroundTargetLocked(self);
}

/// A remembered foreground group that still has members in this
/// session, or null. After the child is reaped this is the job that
/// `terminate` and `kill` still signal.
pub fn orphanedForegroundGroup(self: *Pty) ?posix.pid_t {
    self.wait_mutex.lockUncancelable(self.io);
    defer self.wait_mutex.unlock(self.io);
    return rememberedForegroundLocked(self);
}

/// Current foreground process group of the terminal, or 0 when unavailable or reaped.
pub fn foregroundPgid(self: *Pty) posix.pid_t {
    assert(self.child_pid > 0);
    self.wait_mutex.lockUncancelable(self.io);
    defer self.wait_mutex.unlock(self.io);
    if (self.reaped or self.master_fd < 0) return 0;
    const fg = tcgetpgrp(self.master_fd);
    return if (fg > 0) fg else 0;
}

/// Deliver `sig` to the terminal foreground process group (when `to_group` is
/// true, falling back to the shell process group) or directly to the child
/// process, without tearing down the pane. Fails with `SessionTerminated` once
/// the child has been reaped.
pub fn sendSignal(
    self: *Pty,
    sig: posix.SIG,
    to_group: bool,
) error{ SessionTerminated, InputOutput }!void {
    assert(self.child_pid > 0);
    self.wait_mutex.lockUncancelable(self.io);
    const notify = self.refreshReapLocked();
    if (self.reaped) {
        self.wait_mutex.unlock(self.io);
        self.notifyExit(notify);
        return error.SessionTerminated;
    }
    const delivered = if (to_group) blk: {
        if (foregroundTargetLocked(self)) |fg| {
            assert(fg > 1);
            break :blk sys.kill(-fg, sig);
        }
        break :blk signalShellGroupResultLocked(self, sig);
    } else blk: {
        if (is_linux and self.pid_fd >= 0) {
            break :blk sys.pidfdSendSignal(self.pid_fd, sig);
        }
        break :blk sys.kill(self.child_pid, sig);
    };
    self.wait_mutex.unlock(self.io);
    self.notifyExit(notify);
    if (!delivered) return error.InputOutput;
}

/// Signal the shell's process group (or the shell alone before `setsid`).
fn signalShellGroupLocked(self: *Pty, sig: posix.SIG) void {
    _ = signalShellGroupResultLocked(self, sig);
}

/// Signal the shell's process group (or child fallback) and return whether the syscall succeeded.
fn signalShellGroupResultLocked(self: *Pty, sig: posix.SIG) bool {
    assert(self.child_pid > 0);
    // The child calls `setsid`, so its PID is also its group id.
    if (sys.kill(-self.child_pid, sig)) return true;
    // The instant before `setsid` has run there is no such group yet.
    // With a pidfd the signal goes to exactly the process that was
    // forked, never to one that reused the PID after an external reap.
    if (is_linux and self.pid_fd >= 0) {
        return sys.pidfdSendSignal(self.pid_fd, sig);
    }
    return sys.kill(self.child_pid, sig);
}

/// The group to signal as "the foreground job": the terminal's live
/// foreground group while the shell runs (also remembered), otherwise
/// the remembered group if it still belongs to this session.
fn foregroundTargetLocked(self: *Pty) ?posix.pid_t {
    assert(self.child_pid > 0);
    if (!self.reaped and self.master_fd >= 0) {
        const fg = tcgetpgrp(self.master_fd);
        if (fg == self.child_pid) {
            // The shell owns the terminal again: no separate job.
            self.foreground_pgid = 0;
            return null;
        }
        if (fg > 1) {
            self.foreground_pgid = fg;
            return fg;
        }
        // No foreground group reported (the session leader is already a
        // zombie): fall through to the remembered one.
    }
    return rememberedForegroundLocked(self);
}

/// The remembered foreground group, verified. A process group id is
/// only meaningful while the group has members, so the group leader must
/// still exist and still be in the session the child created (whose id
/// is `child_pid`). Anything else, including a recycled PID, clears the
/// memory and returns null.
fn rememberedForegroundLocked(self: *Pty) ?posix.pid_t {
    const pgid = self.foreground_pgid;
    if (pgid <= 1 or pgid == self.child_pid) return null;
    const session = sys.sessionOf(pgid);
    if (session == null or session.? != self.child_pid or !sys.processGroupExists(pgid)) {
        self.foreground_pgid = 0;
        return null;
    }
    assert(pgid > 1);
    return pgid;
}

// ---------------------------------------------------------------------------
// Tests

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
    var live = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "exec sleep 100",
    });
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
        const output = try proc.runAndCollect(allocator, .{
            .shell = "/bin/sh",
            .command = "grep -E '^Sig(Ign|Blk):' /proc/self/status",
        });
        defer allocator.free(output);
        const ignored = proc.procStatusMask(output, "SigIgn:") orelse return error.TestExpectedContains;
        const blocked_mask = proc.procStatusMask(output, "SigBlk:") orelse return error.TestExpectedContains;
        try std.testing.expectEqual(@as(u64, 0), blocked_mask);
        // The mask is observed through the shell that runs `grep`, and a
        // shell may set dispositions of its own: BusyBox ash ignores SIGQUIT
        // for `-c` commands. A container runtime can also hand down ignored
        // real-time signals, which zmux does not touch. So the assertion is
        // exactly the contract: every signal the daemon ignores or that
        // `resetChildSignals` restores (bar the shell's SIGQUIT) is at its
        // default in the child.
        for ([_]posix.SIG{ .HUP, .INT, .TERM, .PIPE, .CHLD, .TSTP, .TTIN, .TTOU, .WINCH }) |sig| {
            if (ignored & proc.signalBit(sig) != 0) {
                std.debug.print("signal {d} is ignored in the child: SigIgn={x}\n", .{ @backingInt(sig), ignored });
                return error.TestUnexpectedResult;
            }
        }
    }

    // Behavioural check on every platform: the child dies from SIGHUP
    // instead of ignoring it.
    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exec sleep 100" });
    defer proc.cleanupPtyForTest(&child);
    proc.testSleepMs(50);
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
    defer proc.cleanupPtyForTest(&child);
    const fg = try startTrappedForegroundJob(&child, "");

    child.hangupForeground();
    try std.testing.expect(child.waitBlocking(5000));
    // The job must have stopped running. Its PID may linger as a zombie
    // where nothing adopts and reaps orphans (a container without an init).
    var waited: usize = 0;
    while (proc.processRunning(fg) and waited < 500) : (waited += 1) proc.testSleepMs(10);
    try std.testing.expect(!proc.processRunning(fg));
}

/// Start an interactive shell whose foreground job ignores `traps` (if any),
/// wait for the post-trap sentinel on the PTY, and return its foreground group.
fn startTrappedForegroundJob(child: *Pty, comptime traps: []const u8) !posix.pid_t {
    // Split the sentinel via printf %s so PTY input echo never triggers early.
    const trap_prefix = if (traps.len > 0) "trap \"\" " ++ traps ++ "; " else "";
    const cmd = "sh -c '" ++ trap_prefix ++
        "printf \"__ZMUX_%s__\\n\" \"FG_READY\"; exec sleep 9996'\n";
    try child.write(cmd, sys.monotonicMs() + 2000, -1);

    var fg: posix.pid_t = 0;
    var ready = false;
    var captured: [8192]u8 = undefined;
    var captured_len: usize = 0;
    const deadline = sys.monotonicMs() + 10_000;
    var sink: [1024]u8 = undefined;
    while (sys.monotonicMs() < deadline) {
        if (child.pollReadable(20) catch false) {
            const n = child.read(&sink) catch 0;
            if (n > 0) {
                const keep = @min(n, captured.len - captured_len);
                if (keep > 0) {
                    @memcpy(captured[captured_len..][0..keep], sink[0..keep]);
                    captured_len += keep;
                }
                if (std.mem.indexOf(u8, captured[0..captured_len], "__ZMUX_FG_READY__") != null) {
                    ready = true;
                }
            }
        }
        fg = tcgetpgrp(child.master_fd);
        if (ready and fg > 1 and fg != child.child_pid) break;
    }
    try std.testing.expect(ready);
    try std.testing.expect(fg > 1 and fg != child.child_pid);
    try std.testing.expect(proc.processRunning(fg));
    return fg;
}

fn expectStopsRunning(pid: posix.pid_t) !void {
    var waited: usize = 0;
    while (proc.processRunning(pid) and waited < 500) : (waited += 1) proc.testSleepMs(10);
    try std.testing.expect(!proc.processRunning(pid));
}

test "a foreground job that ignores SIGHUP is terminated after its shell exits first" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh" });
    defer proc.cleanupPtyForTest(&child);
    const fg = try startTrappedForegroundJob(&child, "HUP");

    // The hangup kills the shell; the job ignores it and keeps running.
    child.hangupForeground();
    try std.testing.expect(child.waitBlocking(5000));
    try std.testing.expect(child.isReaped());
    proc.testSleepMs(100);
    try std.testing.expect(proc.processRunning(fg));
    try std.testing.expectEqual(@as(?posix.pid_t, fg), child.orphanedForegroundGroup());

    // The shell is reaped, so its group is never signalled again, but the
    // remembered foreground group still gets the escalation.
    const kills_before = sys.kill_call_count.load(.seq_cst);
    child.terminate();
    try std.testing.expectEqual(kills_before + 1, sys.kill_call_count.load(.seq_cst));
    try expectStopsRunning(fg);

    // Once the group is gone nothing is signalled: its id may be reused.
    var gone_wait: usize = 0;
    while (child.orphanedForegroundGroup() != null and gone_wait < 500) : (gone_wait += 1) proc.testSleepMs(10);
    if (child.orphanedForegroundGroup() == null) {
        const kills_after = sys.kill_call_count.load(.seq_cst);
        child.terminate();
        child.kill();
        child.hangupForeground();
        try std.testing.expectEqual(kills_after, sys.kill_call_count.load(.seq_cst));
    }
}

test "kill reaches a remembered foreground job that also ignores SIGTERM" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var child = try Pty.spawn(allocator, std.testing.io, .{ .shell = "/bin/sh" });
    defer proc.cleanupPtyForTest(&child);
    const fg = try startTrappedForegroundJob(&child, "HUP TERM");

    child.hangupForeground();
    try std.testing.expect(child.waitBlocking(5000));
    child.terminate();
    proc.testSleepMs(100);
    try std.testing.expect(proc.processRunning(fg));

    child.kill();
    try expectStopsRunning(fg);
    // SIGKILL is final: the group is forgotten.
    try std.testing.expectEqual(@as(?posix.pid_t, null), child.orphanedForegroundGroup());
}

test "a remembered foreground group outside the session is never signalled" {
    if (!supported_os) return error.SkipZigTest;

    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{ .shell = "/bin/sh", .command = "exit 0" });
    defer child.close();
    try std.testing.expect(child.waitBlocking(5000));

    // A stale group id that now names a process in another session (here:
    // the test runner's own group) must be dropped, not signalled.
    child.foreground_pgid = sys.getpid();
    const kills_before = sys.kill_call_count.load(.seq_cst);
    try std.testing.expectEqual(@as(?posix.pid_t, null), child.orphanedForegroundGroup());
    child.foreground_pgid = sys.getpid();
    child.terminate();
    child.foreground_pgid = sys.getpid();
    child.kill();
    child.foreground_pgid = sys.getpid();
    child.hangupForeground();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));
    try std.testing.expectEqual(@as(posix.pid_t, 0), child.foreground_pgid);
}

test "sendSignal delivers SIGUSR1 without terminating the pane and rejects exited children" {
    if (!supported_os) return error.SkipZigTest;
    var child = try Pty.spawn(std.testing.allocator, std.testing.io, .{
        .shell = "/bin/sh",
        .command = "trap 'printf GOT_USR1; exit 0' USR1; printf READY; sleep 10 & wait",
    });
    defer proc.cleanupPtyForTest(&child);

    var buf: [256]u8 = undefined;
    var acc: [512]u8 = undefined;
    var len: usize = 0;
    const deadline = sys.monotonicMs() + 5_000;
    while (std.mem.indexOf(u8, acc[0..len], "READY") == null and sys.monotonicMs() < deadline) {
        var fds = [_]posix.pollfd{.{ .fd = child.master_fd, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&fds, 50) catch 0) > 0) {
            const n = posix.read(child.master_fd, &buf) catch break;
            if (n == 0) break;
            const take = @min(n, acc.len - len);
            @memcpy(acc[len .. len + take], buf[0..take]);
            len += take;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, acc[0..len], "READY") != null);
    try child.sendSignal(.USR1, true);
    // Drain master output so Darwin ttyclose does not block child exit on unread bytes.
    while (std.mem.indexOf(u8, acc[0..len], "GOT_USR1") == null and sys.monotonicMs() < deadline) {
        var fds = [_]posix.pollfd{.{ .fd = child.master_fd, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&fds, 50) catch 0) > 0) {
            const n = posix.read(child.master_fd, &buf) catch break;
            if (n == 0) break;
            const take = @min(n, acc.len - len);
            @memcpy(acc[len .. len + take], buf[0..take]);
            len += take;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, acc[0..len], "GOT_USR1") != null);
    try std.testing.expect(child.waitBlocking(5_000));
    try std.testing.expectError(error.SessionTerminated, child.sendSignal(.USR1, true));
}
