//! Process inspection (`/proc` parsing, liveness) and the PTY test harness
//! shared by every `pty` submodule and the native-session tests.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const pty = @import("../pty.zig");

const Pty = pty.Pty;
const SpawnOptions = pty.SpawnOptions;
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

/// Whether the PTY tests can run on this target.
pub const supported_os = is_linux or is_darwin;

/// Sleep in a test without reaching for `std.Thread`.
pub fn testSleepMs(ms: i64) void {
    assert(ms >= 0);
    sys.sleepMs(ms);
}

/// Kill, reap, and close a test child.
pub fn cleanupPtyForTest(child: *Pty) void {
    assert(child.child_pid > 0);
    child.kill();
    _ = child.waitBlocking(2000);
    child.close();
}

/// Read PTY output until the child exits and the terminal drains.
pub fn collectOutput(allocator: Allocator, child: *Pty, timeout_ms: i64) ![]u8 {
    assert(timeout_ms > 0);
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
        assert(n <= buf.len);
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// Spawn `command` under /bin/sh and return everything it printed.
pub fn runAndCollect(allocator: Allocator, opts: SpawnOptions) ![]u8 {
    var child = try Pty.spawn(allocator, std.testing.io, opts);
    defer cleanupPtyForTest(&child);
    return collectOutput(allocator, &child, 10_000);
}

/// Fail (and log the output) unless `haystack` contains `needle`.
pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    assert(needle.len > 0);
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        log.err("pty_test_output_missing", .{ .needle = needle, .output = haystack });
        return error.TestExpectedContains;
    }
}

/// Fail (and log the output) when `haystack` contains `needle`.
pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    assert(needle.len > 0);
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        log.err("pty_test_output_unexpected", .{ .needle = needle, .output = haystack });
        return error.TestExpectedNotContains;
    }
}

/// Test helper, shared with the native-session tests.
/// True while `pid` names a process that can still run. An exited process
/// that nobody reaped (a zombie, which `kill(pid, 0)` still finds, and which
/// persists in a container without a reaping init) does not count.
pub fn processRunning(pid: posix.pid_t) bool {
    if (std.c.kill(pid, @fromBackingInt(@intCast(0))) != 0) return false;
    if (!is_linux) return true;

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return true;
    const fd = sys.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return false;
    defer sys.close(fd);
    var buf: [512]u8 = undefined;
    const n = posix.read(fd, &buf) catch return false;
    return procStatState(buf[0..n]) != 'Z' and procStatState(buf[0..n]) != 'X';
}

/// The state field of a `/proc/<pid>/stat` line: the first non-blank byte
/// after the last ')', which closes the (arbitrary) command name. 0 when the
/// line has no such field.
pub fn procStatState(stat: []const u8) u8 {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return 0;
    for (stat[close + 1 ..]) |byte| if (byte != ' ') return byte;
    return 0;
}

/// Parse the hex mask of a `/proc/<pid>/status` line such as `SigIgn:`.
pub fn procStatusMask(status: []const u8, field: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, status, field) orelse return null;
    const rest = std.mem.trimStart(u8, status[at + field.len ..], " \t");
    var end: usize = 0;
    while (end < rest.len and std.ascii.isHex(rest[end])) end += 1;
    assert(end <= rest.len);
    return std.fmt.parseInt(u64, rest[0..end], 16) catch null;
}

/// The `/proc` signal-mask bit for `sig`.
pub fn signalBit(sig: posix.SIG) u64 {
    assert(@backingInt(sig) >= 1 and @backingInt(sig) <= 64);
    return @as(u64, 1) << @intCast(@as(u32, @backingInt(sig)) - 1);
}

// ---------------------------------------------------------------------------
// Tests

test "procStatState reads the state after the command name" {
    try std.testing.expectEqual(@as(u8, 'S'), procStatState("12 (sleep) S 1 12 12 0"));
    try std.testing.expectEqual(@as(u8, 'Z'), procStatState("12 (a) b) Z) Z 1 12"));
    try std.testing.expectEqual(@as(u8, 0), procStatState("garbage"));
    try std.testing.expectEqual(@as(u8, 0), procStatState("12 (x)"));
}

test "procStatusMask parses signal masks" {
    const status = "Name:\tsh\nSigBlk:\t0000000000000000\nSigIgn:\t0000000000000004\nSigCgt:\t0000000000010002\n";
    try std.testing.expectEqual(@as(?u64, 0), procStatusMask(status, "SigBlk:"));
    try std.testing.expectEqual(@as(?u64, 4), procStatusMask(status, "SigIgn:"));
    try std.testing.expectEqual(signalBit(.QUIT), procStatusMask(status, "SigIgn:").?);
    try std.testing.expectEqual(@as(?u64, null), procStatusMask(status, "SigNope:"));
}
