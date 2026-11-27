const std = @import("std");
const builtin = @import("builtin");

const buffer = @import("buffer.zig");
const foreground = @import("foreground.zig");
const pty = @import("pty.zig");

/// How `NativeSessionOptions.env` combines with the daemon environment.
pub const EnvMode = pty.EnvMode;
const protocol = @import("protocol.zig");
const sys = @import("sys.zig");
const log = @import("log.zig");
const assert = std.debug.assert;

const events = @import("native/events.zig");
const session = @import("native/session.zig");
const control = @import("native/control.zig");
const reader = @import("native/reader.zig");
const keys = @import("native/keys.zig");
const harness = @import("native/harness.zig");

/// Decoded child exit: exactly one of the fields is set for a reaped child,
/// both null when the status was unavailable.
pub const ExitInfo = struct { exit_code: ?u32, signal: ?u32 };

/// Budget for one `send`/`sendKey`/`writeInput` call.
pub const default_input_deadline_ms: i64 = 2000;

/// How long the reader waits, idle, for more output or EOF after the child
/// exits while a descendant still holds the PTY slave open. Output that is
/// already readable when this expires is still drained (see
/// `exit_drain_max_bytes`), so `session_exited` follows the last buffered
/// byte, not a timer.
pub const exit_drain_grace_ms: i64 = 250;

/// Bound on the output drained after the idle wait ended (the grace expired
/// or the owner asked the reader to stop). It is far larger than any kernel
/// PTY buffer, so everything that was buffered when the child exited is
/// delivered; a descendant that keeps writing forever cannot postpone
/// `session_exited` indefinitely.
pub const exit_drain_max_bytes: usize = 1024 * 1024;

/// `pane_activity` fires on the idle-to-active edge: output after at least
/// this long without any.
pub const activity_idle_ms: i64 = 1000;

/// Budget `terminate` gives SIGHUP/SIGTERM before escalating to SIGKILL.
pub const terminate_grace_ms: i64 = 300;

/// How long SIGHUP gets to work alone before SIGTERM follows. A SIGTERM sent
/// together with the SIGHUP would kill a job before its HUP handler ran.
pub const hangup_grace_ms: i64 = 100;

/// Test seam: when false, reader threads skip foreground-process polling,
/// the only reader-side use of the session allocator. Allocation-failure
/// tests disable it so their failure indices do not depend on scheduling.
pub var foreground_check_enabled: std.atomic.Value(bool) = .init(true);

/// Test seam: called with the child PID right before the reader thread is
/// spawned; an error is reported as if `std.Thread.spawn` had failed.
pub var spawn_reader_hook: ?*const fn (child_pid: std.posix.pid_t) std.Thread.SpawnError!void = null;

/// Number of sessions fully torn down. Test seam for teardown that finishes
/// on a detached reader thread.
pub var teardown_count: std.atomic.Value(usize) = .init(0);

/// Session lifecycle states; see `events.NativeSessionState`.
pub const NativeSessionState = events.NativeSessionState;
/// What `NativeSession.create` spawns.
pub const NativeSessionOptions = events.NativeSessionOptions;
/// One notification delivered to an `EventSink`.
pub const Event = events.Event;
/// A chunk of PTY output.
pub const PaneOutputEvent = events.PaneOutputEvent;
/// Output resumed after silence.
pub const PaneActivityEvent = events.PaneActivityEvent;
/// The pane rang the bell.
pub const PaneBellEvent = events.PaneBellEvent;
/// Callback receiving every `Event`.
pub const EventSink = events.EventSink;
/// A single PTY-backed shell; see `native/session.zig`.
pub const NativeSession = session.NativeSession;
/// Terminal byte sequence for a tmux-style key name.
pub const keySequence = keys.keySequence;

/// Exit code of a `waitpid(2)` status word, or null if the child did not exit
/// normally. Masks explicitly (like C's `WEXITSTATUS`) rather than calling
/// `std.posix.W.EXITSTATUS`, whose Darwin implementation `@intCast`s
/// `status >> 8` to `u8` and panics on any status with bits above 16 set.
pub fn exitCodeOf(status: u32) ?u32 {
    if (!std.posix.W.IFEXITED(status)) return null;
    const code = (status >> 8) & 0xff;
    assert(code <= 0xff);
    return code;
}

/// Terminating signal number of a `waitpid(2)` status word, or null if the
/// child was not killed by a signal. Returns the raw number so unknown signal
/// values never trip an exhaustive-enum conversion.
pub fn termSignalOf(status: u32) ?u32 {
    if (!std.posix.W.IFSIGNALED(status)) return null;
    const sig = status & 0x7f;
    assert(sig <= 0x7f);
    return sig;
}

/// Exit code, else terminating signal, else the raw status word.
pub fn decodedExitStatus(status: u32) u32 {
    if (exitCodeOf(status)) |code| {
        assert(termSignalOf(status) == null);
        return code;
    }
    if (termSignalOf(status)) |signal| return signal;
    return status;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("native/events.zig");
    _ = @import("native/session.zig");
    _ = @import("native/control.zig");
    _ = @import("native/reader.zig");
    _ = @import("native/keys.zig");
    _ = @import("native/harness.zig");
}

test "decoded exit status unwraps waitpid status words" {
    try std.testing.expectEqual(@as(u32, 7), decodedExitStatus(7 << 8));
    try std.testing.expectEqual(@as(?u32, 7), exitCodeOf(7 << 8));
    try std.testing.expectEqual(@as(?u32, 9), termSignalOf(9));
    try std.testing.expectEqual(@as(u32, 9), decodedExitStatus(9));
    // Garbage high bits must never panic (Darwin std EXITSTATUS would).
    try std.testing.expectEqual(@as(u32, 0x12), decodedExitStatus(0xABCD_1200));
    try std.testing.expectEqual(@as(?u32, 0x12), exitCodeOf(0xABCD_1200));
    try std.testing.expect(termSignalOf(0xABCD_1200) == null);
}

const supported_os = harness.supported_os;
const tcgetpgrp = harness.tcgetpgrp;
const Recorder = harness.Recorder;
const testCreate = harness.testCreate;
const processExists = harness.processExists;
const waitUntilGone = harness.waitUntilGone;
const expectJsonContains = harness.expectJsonContains;

test "exit code and terminating signal are reported separately" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    {
        var rec: Recorder = .{};
        defer rec.deinit();
        const native = try testCreate(&rec, "exit 9", .{});
        defer native.destroy();
        try std.testing.expect(native.exitInfo() == null or native.exitInfo().?.exit_code == 9);
        try rec.waitForExit(10_000);

        const info = native.exitInfo().?;
        try std.testing.expectEqual(@as(?u32, 9), info.exit_code);
        try std.testing.expectEqual(@as(?u32, null), info.signal);
        try std.testing.expectEqual(@as(?u32, 9), rec.exit_code);
        try std.testing.expectEqual(@as(?u32, null), rec.exit_signal);
        const json = try native.infoJson(allocator);
        defer allocator.free(json);
        try expectJsonContains(json, "\"state\":\"terminated\"");
        try expectJsonContains(json, "\"exitStatus\":9,\"exitCode\":9,\"signal\":null");
    }
    {
        var rec: Recorder = .{};
        defer rec.deinit();
        const native = try testCreate(&rec, "kill -9 $$", .{});
        defer native.destroy();
        try rec.waitForExit(10_000);

        const info = native.exitInfo().?;
        try std.testing.expectEqual(@as(?u32, null), info.exit_code);
        try std.testing.expectEqual(@as(?u32, 9), info.signal);
        try std.testing.expectEqual(@as(?u32, null), rec.exit_code);
        try std.testing.expectEqual(@as(?u32, 9), rec.exit_signal);
        const json = try native.infoJson(allocator);
        defer allocator.free(json);
        try expectJsonContains(json, "\"exitStatus\":9,\"exitCode\":null,\"signal\":9");
    }
}

test "an exited session releases its descriptors and reader but keeps scrollback" {
    if (!supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "sleep 0.2; echo bye; exit 0", .{});
    defer native.destroy();
    const master_fd = native.handle.master_fd;
    try std.testing.expect(master_fd >= 0);
    try std.testing.expect(std.c.fcntl(master_fd, std.c.F.GETFD) >= 0);
    try rec.waitForExit(10_000);

    const deadline = sys.monotonicMs() + 5_000;
    while (!native.reader_finished.load(.seq_cst)) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        sys.sleepMs(2);
    }
    try std.testing.expectEqual(@as(sys.fd_t, -1), native.handle.master_fd);
    try std.testing.expectEqual(@as(sys.fd_t, -1), native.handle.pid_fd);
    try std.testing.expect(std.c.fcntl(master_fd, std.c.F.GETFD) < 0);
    try std.testing.expectEqual(@as(u64, 0), native.reader_tid.load(.seq_cst));

    const captured = try native.capture(allocator, 10);
    defer allocator.free(captured);
    try std.testing.expect(std.mem.indexOf(u8, captured, "bye") != null);
}

test "terminate hangs up foreground and background jobs of an interactive shell" {
    if (!supported_os) return error.SkipZigTest;
    // bash forwards SIGHUP to all of its jobs; a job-control shell is needed
    // to put the foreground command in its own process group.
    _ = sys.statAt(sys.cwd_fd, "/bin/bash", true) catch return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, null, .{
        .shell = "/bin/bash",
        // No rc files: a hermetic interactive login shell.
        .env = &.{ "HOME=/nonexistent", "PS1=zmux$ " },
    });
    defer native.destroy();
    const shell_pid = native.handle.child_pid;

    try native.send("sleep 9999 & echo BG=$!=", true);
    var bg_pid: std.posix.pid_t = 0;
    const bg_deadline = sys.monotonicMs() + 10_000;
    while (bg_pid == 0) {
        try std.testing.expect(sys.monotonicMs() < bg_deadline);
        sys.sleepMs(10);
        rec.mutex.lockUncancelable(Recorder.io);
        defer rec.mutex.unlock(Recorder.io);
        var search: usize = 0;
        // Skip the echoed command line, where "BG=" is followed by "$!".
        while (std.mem.indexOfPos(u8, rec.output.items, search, "BG=")) |at| {
            search = at + 3;
            const rest = rec.output.items[search..];
            const end = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
            bg_pid = std.fmt.parseInt(std.posix.pid_t, rest[0..end], 10) catch continue;
            break;
        }
    }
    try native.send("sleep 9998", true);

    var fg_pgid: std.posix.pid_t = 0;
    const fg_deadline = sys.monotonicMs() + 10_000;
    while (true) {
        try std.testing.expect(sys.monotonicMs() < fg_deadline);
        fg_pgid = tcgetpgrp(native.handle.master_fd);
        if (fg_pgid > 1 and fg_pgid != shell_pid) break;
        sys.sleepMs(10);
    }
    try std.testing.expect(processExists(bg_pid));
    try std.testing.expect(processExists(fg_pgid));

    native.terminate();
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(waitUntilGone(fg_pgid, 3_000));
    try std.testing.expect(waitUntilGone(bg_pid, 3_000));
    try std.testing.expect(!processExists(shell_pid));
}

test "terminate lets a HUP trap finish before SIGTERM follows" {
    if (!supported_os) return error.SkipZigTest;

    // Regression: SIGTERM used to be sent in the same instant as SIGHUP, so
    // a job with a HUP handler died of SIGTERM before the handler ran.
    // POSIX defers a trap until the running foreground command completes,
    // and a SIGHUP sent just after `ready` can land before the loop's next
    // `sleep` exists, so a foreground `sleep 1` would hold the trap for up to
    // a second. The `wait` builtin returns at once for a trapped signal.
    var rec: Recorder = .{};
    defer rec.deinit();
    // The shell waits with the `wait` builtin, which a trapped signal
    // interrupts at once. Waiting on a foreground `sleep` instead defers the
    // trap until that child exits, and a SIGHUP that lands between its fork
    // and exec misses it, so the trap would run up to a second late and lose
    // to the SIGTERM this test is about.
    const script = "trap 'echo TRAPPED; exit 3' HUP; echo ready; while :; do sleep 1 & wait $!; done";
    const native = try testCreate(&rec, script, .{});
    defer native.destroy();
    try rec.waitForOutput("ready", 10_000);
    // Let the shell get past the fork and park in `wait`.
    sys.sleepMs(50);

    native.terminate();
    try rec.waitForExit(10_000);
    try std.testing.expect(rec.outputContains("TRAPPED"));
    try std.testing.expectEqual(@as(?u32, 3), rec.exit_code);
    try std.testing.expectEqual(@as(?u32, null), rec.exit_signal);
}

test "terminate escalates to SIGTERM when SIGHUP is ignored" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "trap '' HUP; echo ready; exec sleep 100", .{});
    defer native.destroy();
    try rec.waitForOutput("ready", 10_000);
    // `exec` replaced the shell; give it a moment to be the sleep.
    sys.sleepMs(50);

    const started = sys.monotonicMs();
    native.terminate();
    try rec.waitForExit(10_000);
    // SIGTERM (15) arrived after the HUP grace and before the SIGKILL deadline.
    try std.testing.expectEqual(@as(?u32, 15), rec.exit_signal);
    try std.testing.expect(sys.monotonicMs() - started >= hangup_grace_ms);
}

test "destroy terminates a running child and joins the reader" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "echo up; exec sleep 100", .{});
    const pid = native.handle.child_pid;
    try rec.waitForOutput("up", 10_000);

    native.retain();
    native.release();
    try std.testing.expect(native.isRunning());
    native.destroy();

    const wait_rc = std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(wait_rc));
    // The exit was delivered before destroy returned, with the hangup signal.
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
    try std.testing.expectEqual(@as(?u32, @backingInt(std.posix.SIG.HUP)), rec.exit_signal);
}

/// Type a foreground job that ignores SIGHUP into an interactive shell and
/// return its process group once the inner shell has installed the trap and
/// taken ownership of the terminal.
fn startHupIgnoringJob(rec: *Recorder, native: *NativeSession, seconds: []const u8) !std.posix.pid_t {
    var line_buf: [144]u8 = undefined;
    var marker_buf: [32]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "HUPREADY-{s}", .{seconds});
    // An ignored disposition survives exec, so the `sleep` itself ignores
    // the hangup. Split the marker in printf so terminal echo of the typed
    // command never triggers waitForOutput before the trap is installed.
    const line = try std.fmt.bufPrint(
        &line_buf,
        "sh -c 'trap \"\" HUP; printf \"HUP%s\\n\" \"READY-{s}\"; exec sleep {s}'",
        .{ seconds, seconds },
    );
    try native.send(line, true);
    try rec.waitForOutput(marker, 10_000);

    const shell_pid = native.handle.child_pid;
    var fg_pgid: std.posix.pid_t = 0;
    const deadline = sys.monotonicMs() + 10_000;
    while (true) {
        try std.testing.expect(sys.monotonicMs() < deadline);
        fg_pgid = tcgetpgrp(native.handle.master_fd);
        if (fg_pgid > 1 and fg_pgid != shell_pid and processExists(fg_pgid)) break;
        sys.sleepMs(10);
    }
    try std.testing.expect(processExists(fg_pgid));
    return fg_pgid;
}

test "terminate finishes off a foreground job that ignores SIGHUP after its shell exits" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, null, .{ .env = &.{ "HOME=/nonexistent", "PS1=zmux$ " } });
    defer native.destroy();
    const fg_pgid = try startHupIgnoringJob(&rec, native, "9993");

    // SIGHUP kills the interactive shell at once; the job ignores it. The
    // ladder must keep going for the job: SIGTERM after the hangup grace.
    native.terminate();
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(waitUntilGone(fg_pgid, 3_000));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), native.handle.orphanedForegroundGroup());
}

test "releasing a pane whose shell died first still terminates its foreground job" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, null, .{ .env = &.{ "HOME=/nonexistent", "PS1=zmux$ " } });
    defer native.destroy();
    const fg_pgid = try startHupIgnoringJob(&rec, native, "9992");
    // The reader remembers the foreground group on its polling interval.
    sys.sleepMs(foreground.poll_interval_ms + 200);

    // The shell dies on its own (not through zmux) while the job runs. The
    // hangup the kernel sends to the foreground group is ignored.
    try std.testing.expectEqual(@as(c_int, 0), std.c.kill(native.handle.child_pid, .KILL));
    try rec.waitForExit(10_000);
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(processExists(fg_pgid));

    // The pane is already exited; closing it must not leave the job behind.
    native.stopForOwnerRelease();
    try std.testing.expect(waitUntilGone(fg_pgid, 3_000));
}
