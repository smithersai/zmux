//! Shared session-test harness: a recording event sink and process helpers.

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("../pty.zig");
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const root = @import("../native.zig");
const session = @import("session.zig");
const events = @import("events.zig");
const reader = @import("reader.zig");
const NativeSession = session.NativeSession;
const NativeSessionState = events.NativeSessionState;
const Event = events.Event;
const EventSink = events.EventSink;
const terminate_grace_ms = root.terminate_grace_ms;
const assert = std.debug.assert;

/// Whether session tests can spawn real PTY children here.
pub const supported_os = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

/// Foreground process group of a terminal.
pub extern "c" fn tcgetpgrp(fd: c_int) std.posix.pid_t;

/// Tag of an `Event`.
pub const EventKind = std.meta.Tag(Event);

/// Thread-safe event sink that records what the reader thread emits.
pub const Recorder = struct {
    mutex: std.Io.Mutex = .init,
    output: std.ArrayList(u8) = .empty,
    kinds: std.ArrayList(EventKind) = .empty,
    outputs: usize = 0,
    activity: usize = 0,
    bells: usize = 0,
    exits: usize = 0,
    exit_code: ?u32 = null,
    exit_signal: ?u32 = null,
    exit_at_ms: i64 = 0,
    expected_generation: u64 = 0,
    generation_mismatch: bool = false,
    next_offset: ?u64 = null,
    offsets_contiguous: bool = true,
    /// Sleep this long inside every pane_output callback.
    output_delay_ms: i64 = 0,
    entered: std.atomic.Value(usize) = .init(0),
    completed: std.atomic.Value(usize) = .init(0),

    pub const io = std.testing.io;
    pub const allocator = std.testing.allocator;

    pub fn sink(self: *Recorder) EventSink {
        assert(self.output_delay_ms >= 0);
        return .{ .context = self, .emit = Recorder.emit };
    }

    pub fn deinit(self: *Recorder) void {
        assert(self.entered.load(.seq_cst) >= self.completed.load(.seq_cst));
        self.output.deinit(allocator);
        self.kinds.deinit(allocator);
    }

    fn emit(context: *anyopaque, event: Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        const enter_count = self.entered.fetchAdd(1, .seq_cst);
        assert(enter_count < std.math.maxInt(usize));
        defer _ = self.completed.fetchAdd(1, .seq_cst);

        self.mutex.lockUncancelable(io);
        self.kinds.append(allocator, std.meta.activeTag(event)) catch |err| {
            log.err("native_test_recorder_append_failed", .{ .err = err });
        };
        var delay_ms: i64 = 0;
        switch (event) {
            .pane_output => |out| {
                self.outputs += 1;
                self.output.appendSlice(allocator, out.data) catch |err| {
                    log.err("native_test_recorder_append_failed", .{ .err = err });
                };
                if (out.generation != self.expected_generation) self.generation_mismatch = true;
                if (self.next_offset) |expected| {
                    if (out.offset != expected) self.offsets_contiguous = false;
                }
                self.next_offset = out.offset + out.data.len;
                delay_ms = self.output_delay_ms;
            },
            .pane_activity => |activity| {
                self.activity += 1;
                if (activity.generation != self.expected_generation) self.generation_mismatch = true;
            },
            .pane_bell => |bell| {
                self.bells += 1;
                if (bell.generation != self.expected_generation) self.generation_mismatch = true;
            },
            .session_exited => |exit| {
                self.exits += 1;
                self.exit_code = exit.exit_code;
                self.exit_signal = exit.signal;
                self.exit_at_ms = sys.monotonicMs();
                if (exit.generation != self.expected_generation) self.generation_mismatch = true;
            },
            .foreground_changed => {},
        }
        self.mutex.unlock(io);
        if (delay_ms > 0) sys.sleepMs(delay_ms);
    }

    pub fn exitCount(self: *Recorder) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.exits;
    }

    pub fn waitForExit(self: *Recorder, timeout_ms: i64) !void {
        assert(timeout_ms >= 0);
        const deadline = sys.monotonicMs() + timeout_ms;
        while (self.exitCount() == 0) {
            if (sys.monotonicMs() >= deadline) return error.TestTimedOutWaitingForExit;
            sys.sleepMs(2);
        }
    }

    pub fn outputContains(self: *Recorder, needle: []const u8) bool {
        assert(needle.len > 0);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return std.mem.indexOf(u8, self.output.items, needle) != null;
    }

    pub fn waitForOutput(self: *Recorder, needle: []const u8, timeout_ms: i64) !void {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (!self.outputContains(needle)) {
            if (sys.monotonicMs() >= deadline) return error.TestTimedOutWaitingForOutput;
            sys.sleepMs(2);
        }
    }

    pub fn countByte(self: *Recorder, byte: u8) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return std.mem.count(u8, self.output.items, &.{byte});
    }
};

/// Spawn a test session under `/bin/sh`, wiring `rec` as its sink.
pub fn testCreate(rec: ?*Recorder, command: ?[]const u8, extra: struct {
    id: []const u8 = "t2",
    generation: u64 = 0,
    shell: []const u8 = "/bin/sh",
    env: ?[]const []const u8 = null,
    scrollback_bytes: usize = 1024 * 1024,
}) !*NativeSession {
    if (rec) |r| r.expected_generation = extra.generation;
    return NativeSession.create(std.testing.allocator, std.testing.io, .{
        .id = extra.id,
        .shell = extra.shell,
        .command = command,
        .env = extra.env,
        .scrollback_bytes = extra.scrollback_bytes,
        .event_sink = if (rec) |r| r.sink() else null,
        .generation = extra.generation,
    });
}

/// Zombie-aware: an exited process that nothing reaped is not running.
pub fn processExists(pid: std.posix.pid_t) bool {
    return pty.processRunning(pid);
}

/// Poll until `pid` is gone or `timeout_ms` elapsed.
pub fn waitUntilGone(pid: std.posix.pid_t, timeout_ms: i64) bool {
    const deadline = sys.monotonicMs() + timeout_ms;
    while (processExists(pid)) {
        if (sys.monotonicMs() >= deadline) return false;
        sys.sleepMs(5);
    }
    return true;
}

/// Fail unless `json` contains `needle`.
pub fn expectJsonContains(json: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, json, needle) == null) {
        log.err("native_test_json_missing", .{ .needle = needle, .json = json });
        return error.TestExpectedContains;
    }
}

/// Thread that reaps a session until stopped.
pub const Reaper = struct {
    native: *NativeSession,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn run(self: *Reaper) void {
        while (!self.stop.load(.seq_cst)) _ = self.native.reapExited();
    }
};

test "PTY EOF with a live child keeps the session running and release reaps it" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    // The child closes its whole terminal and keeps running.
    const native = try testCreate(&rec, "exec sleep 100 <&- >&- 2>&-", .{});
    const pid = native.handle.child_pid;

    sys.sleepMs(400);
    try std.testing.expect(native.isRunning());
    try std.testing.expectEqual(NativeSessionState.running, native.state());
    try std.testing.expect(native.exitInfo() == null);
    try std.testing.expectEqual(@as(usize, 0), rec.exitCount());
    try std.testing.expect(processExists(pid));

    native.stopForOwnerRelease();
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    try std.testing.expect(native.exitInfo().?.signal != null);
    native.destroy();

    // Killed and reaped: no zombie is left to collect.
    const rc = std.c.waitpid(pid, null, @intCast(std.posix.W.NOHANG));
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(rc));
    try std.testing.expectEqual(@as(usize, 1), rec.exits);
}

test "terminate after a natural exit sends no signal" {
    if (!supported_os) return error.SkipZigTest;

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "exit 0", .{});
    defer native.destroy();
    try rec.waitForExit(10_000);

    // The PID may already belong to another process: nothing may be sent.
    const kills_before = sys.kill_call_count.load(.seq_cst);
    const started = sys.monotonicMs();
    native.terminate();
    native.beginTerminate();
    native.awaitTerminated(sys.monotonicMs() + 50);
    native.stopForOwnerRelease();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));
    // No SIGKILL escalation wait either.
    try std.testing.expect(sys.monotonicMs() - started < terminate_grace_ms);
}

test "a child auto-reaped under ignored SIGCHLD terminates without escalation" {
    if (!supported_os) return error.SkipZigTest;

    var old_action: std.posix.Sigaction = undefined;
    const ignored: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.CHLD, &ignored, &old_action);
    defer std.posix.sigaction(.CHLD, &old_action, null);

    var rec: Recorder = .{};
    defer rec.deinit();
    const native = try testCreate(&rec, "exit 0", .{});
    defer native.destroy();
    try rec.waitForExit(10_000);

    // waitpid reported ECHILD: terminated, with no status to decode.
    try std.testing.expectEqual(NativeSessionState.terminated, native.state());
    const info = native.exitInfo().?;
    try std.testing.expect(info.exit_code == null and info.signal == null);
    try std.testing.expect(rec.exit_code == null and rec.exit_signal == null);

    const kills_before = sys.kill_call_count.load(.seq_cst);
    const started = sys.monotonicMs();
    native.terminate();
    try std.testing.expectEqual(kills_before, sys.kill_call_count.load(.seq_cst));
    try std.testing.expect(sys.monotonicMs() - started < terminate_grace_ms);
}

const SpinReaper = struct {
    native: *NativeSession,
    go: *std.atomic.Value(bool),
    stop: *std.atomic.Value(bool),

    fn run(self: *SpinReaper) void {
        while (!self.go.load(.seq_cst)) std.atomic.spinLoopHint();
        while (!self.stop.load(.seq_cst)) _ = self.native.reapExited();
    }
};

test "concurrent reapers never replace a real exit status with an unknown one" {
    if (!supported_os) return error.SkipZigTest;

    var round: usize = 0;
    while (round < 12) : (round += 1) {
        var rec: Recorder = .{};
        defer rec.deinit();
        const native = try testCreate(&rec, "exit 9", .{});
        defer native.destroy();

        var go: std.atomic.Value(bool) = .init(false);
        var stop: std.atomic.Value(bool) = .init(false);
        var reapers: [4]SpinReaper = undefined;
        var threads: [4]std.Thread = undefined;
        for (&reapers, &threads) |*reaper, *thread| {
            reaper.* = .{ .native = native, .go = &go, .stop = &stop };
            thread.* = try std.Thread.spawn(.{}, SpinReaper.run, .{reaper});
        }
        go.store(true, .seq_cst);
        const waited = rec.waitForExit(15_000);
        stop.store(true, .seq_cst);
        for (threads) |thread| thread.join();
        try waited;

        // Whoever published the transition published the collected status.
        try std.testing.expectEqual(@as(?u32, 9), native.exitInfo().?.exit_code);
        try std.testing.expectEqual(@as(?u32, 9), rec.exit_code);
        const json = try native.infoJson(std.testing.allocator);
        defer std.testing.allocator.free(json);
        try expectJsonContains(json, "\"exitCode\":9");
    }
}
