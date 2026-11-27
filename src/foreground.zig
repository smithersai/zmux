//! Foreground process tracking for a pane's PTY: which process group owns
//! the terminal, and the name and argv of its leader.

const std = @import("std");
const builtin = @import("builtin");

const protocol = @import("protocol.zig");
const argv_mod = @import("foreground/argv.zig");
const darwin = @import("foreground/darwin.zig");
const linux = @import("foreground/linux.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const assert = std.debug.assert;

/// Interval between foreground process-group polls of a pane's PTY.
pub const poll_interval_ms: i64 = 500;
/// Bound on the serialized argv, measured after JSON escaping.
pub const max_serialized_argv_bytes: usize = 64 * 1024;

/// Name and argv of a foreground process. See `argv.ProcessInfo`.
pub const ProcessInfo = argv_mod.ProcessInfo;
/// Owned argv parsed from a process-arguments buffer.
pub const ParsedArgv = argv_mod.ParsedArgv;
/// Parse a Darwin `KERN_PROCARGS2` buffer.
pub const parseProcArgs = argv_mod.parseProcArgs;
/// Parse a `KERN_PROCARGS2` buffer and return only the argv slice.
pub const parseProcArgsBuffer = argv_mod.parseProcArgsBuffer;
/// Free every argument in `argv` and the slice itself.
pub const freeArgv = argv_mod.freeArgv;
/// Trim a raw `/proc/<pid>/comm` read.
pub const parseLinuxProcComm = linux.parseLinuxProcComm;
/// Split a raw `/proc/<pid>/cmdline` read into owned argv strings.
pub const parseLinuxProcCmdline = linux.parseLinuxProcCmdline;

/// Tracks the last reported foreground process group of one PTY, so only
/// changes are reported.
pub const Tracker = struct {
    shell_pid: posix.pid_t,
    last_pgid: ?posix.pid_t = null,

    pub fn init(shell_pid: posix.pid_t) Tracker {
        return .{ .shell_pid = shell_pid };
    }

    /// True when `pgid` differs from the last committed group, including a
    /// return to the shell group. Pure: nothing is recorded until `commit`,
    /// so a failed emit is retried on the next poll.
    pub fn observe(self: *Tracker, pgid: posix.pid_t) bool {
        if (pgid <= 0) return false;
        if (self.last_pgid) |last| return last != pgid;
        return true;
    }

    /// Record `pgid` as emitted. Call only after a successful emit.
    pub fn commit(self: *Tracker, pgid: posix.pid_t) void {
        self.last_pgid = pgid;
    }

    /// Report the PTY's foreground process group leader when it differs from
    /// the last committed group. Nothing is recorded: the caller calls
    /// `commit(info.pid)` after it delivered the result, and skips the commit
    /// for a `degraded` result so a later poll retries the lookup. `io` is
    /// used to read `/proc` on Linux.
    pub fn poll(self: *Tracker, allocator: Allocator, io: std.Io, master_fd: posix.fd_t) !?ProcessInfo {
        const pgid = terminalForegroundPgrp(master_fd) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => return err,
        };
        if (!self.observe(pgid)) return null;
        return try resolveProcessInfo(allocator, io, pgid);
    }
};

/// Resolve the name and argv of `pid`. Only `error.OutOfMemory` propagates:
/// every OS failure (the process exited, EPERM, hidepid, a short sysctl)
/// degrades to the `pid-<n>` form with `degraded = true`. `comm` and every
/// argv entry are valid UTF-8, and the JSON-escaped argv array is at most
/// `max_serialized_argv_bytes`.
pub fn resolveProcessInfo(allocator: Allocator, io: std.Io, pid: posix.pid_t) Allocator.Error!ProcessInfo {
    var info = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => try darwin.resolveDarwinProcessInfo(allocator, pid),
        .linux => try linux.resolveLinuxProcessInfo(allocator, io, pid),
        else => try resolveFallbackProcessInfo(allocator, pid),
    };
    errdefer info.deinit();
    try sanitizeProcessInfo(&info);
    return info;
}

/// Replace invalid UTF-8 in `comm` and `argv`, then bound the argv.
fn sanitizeProcessInfo(info: *ProcessInfo) Allocator.Error!void {
    const allocator = info.allocator;
    const comm = try protocol.sanitizeUtf8Alloc(allocator, info.comm);
    allocator.free(info.comm);
    info.comm = comm;
    for (info.argv) |*arg| {
        const clean = try protocol.sanitizeUtf8Alloc(allocator, arg.*);
        allocator.free(arg.*);
        arg.* = clean;
    }
    if (try boundSerializedArgv(allocator, &info.argv, max_serialized_argv_bytes)) info.argv_truncated = true;
}

/// Bytes that `c` occupies inside a JSON string, matching std.json.Stringify.
fn jsonEscapedLen(c: u8) usize {
    return switch (c) {
        '"', '\\', 0x08, 0x0c, '\n', '\r', '\t' => 2,
        0x00...0x07, 0x0b, 0x0e...0x1f => 6,
        else => 1,
    };
}

/// Shrink `argv` (valid UTF-8 entries) so the serialized JSON array fits in
/// `max_bytes`. Cuts at an argument boundary, or inside the first argument
/// that does not fit at a code point boundary. Returns true when anything was
/// dropped. On error `argv` is unchanged.
fn boundSerializedArgv(allocator: Allocator, argv: *[][]u8, max_bytes: usize) Allocator.Error!bool {
    const cut = argvCut(argv.*, max_bytes) orelse return false;
    assert(cut.index < argv.len);
    assert(cut.keep_bytes <= argv.*[cut.index].len);
    const kept_args = cut.index + @intFromBool(cut.keep_bytes > 0);

    const new_argv = try allocator.alloc([]u8, kept_args);
    errdefer allocator.free(new_argv);
    @memcpy(new_argv[0..cut.index], argv.*[0..cut.index]);
    if (cut.keep_bytes > 0) new_argv[cut.index] = try allocator.dupe(u8, argv.*[cut.index][0..cut.keep_bytes]);

    for (argv.*[cut.index..]) |dropped| allocator.free(dropped);
    allocator.free(argv.*);
    argv.* = new_argv;
    return true;
}

const ArgvCut = struct { index: usize, keep_bytes: usize };

/// First argument that overflows `max_bytes`, and how many of its bytes fit.
fn argvCut(argv: []const []const u8, max_bytes: usize) ?ArgvCut {
    // "[" and "]".
    var used: usize = 2;
    for (argv, 0..) |arg, index| {
        // Separator plus the two quotes.
        const overhead: usize = @as(usize, @intFromBool(index != 0)) + 2;
        var arg_len: usize = 0;
        for (arg) |c| arg_len += jsonEscapedLen(c);
        if (used + overhead + arg_len <= max_bytes) {
            used += overhead + arg_len;
            assert(used <= max_bytes);
            continue;
        }

        var keep: usize = 0;
        if (used + overhead < max_bytes) {
            var budget = max_bytes - used - overhead;
            while (keep < arg.len) {
                const seq = std.unicode.utf8ByteSequenceLength(arg[keep]) catch 1;
                const end = @min(keep + seq, arg.len);
                assert(end > keep);
                var cost: usize = 0;
                for (arg[keep..end]) |c| cost += jsonEscapedLen(c);
                if (cost > budget) break;
                budget -= cost;
                keep = end;
            }
        }
        assert(keep <= arg.len);
        return .{ .index = index, .keep_bytes = keep };
    }
    return null;
}

fn resolveFallbackProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    const comm = try std.fmt.allocPrint(allocator, "pid-{d}", .{pid});
    errdefer allocator.free(comm);

    const argv = try allocator.alloc([]u8, 0);
    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
    };
}

extern "c" fn tcgetpgrp(fd: c_int) c_int;

/// Errors from reading a PTY's foreground process group.
pub const ForegroundPgrpError = error{ NotATerminal, Unexpected };

fn terminalForegroundPgrp(fd: posix.fd_t) ForegroundPgrpError!posix.pid_t {
    while (true) {
        const rc = tcgetpgrp(fd);
        if (pgrpFromErrno(rc, posix.errno(rc))) |result| return result else |err| switch (err) {
            error.Interrupted => continue,
            else => |e| return e,
        }
    }
}

/// Map one `tcgetpgrp` result. EBADF and EINVAL mean the PTY is gone or
/// broken; they are reported, never `unreachable`, so a closing pane cannot
/// panic the daemon.
fn pgrpFromErrno(rc: c_int, e: posix.E) (ForegroundPgrpError || error{Interrupted})!posix.pid_t {
    return switch (e) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Interrupted,
        .NOTTY => error.NotATerminal,
        else => error.Unexpected,
    };
}

test "tracker observe reports every change including return to shell" {
    var tracker = Tracker.init(100);
    try std.testing.expect(tracker.observe(100));
    tracker.commit(100);
    try std.testing.expect(!tracker.observe(100));

    try std.testing.expect(tracker.observe(200));
    tracker.commit(200);
    try std.testing.expect(!tracker.observe(200));

    try std.testing.expect(tracker.observe(100));
    tracker.commit(100);
    try std.testing.expect(!tracker.observe(100));

    try std.testing.expect(!tracker.observe(0));
    try std.testing.expect(!tracker.observe(-1));
}

test "tracker observe without commit reports the same pgid again" {
    var tracker = Tracker.init(100);
    tracker.commit(100);
    try std.testing.expect(tracker.observe(300));
    try std.testing.expect(tracker.observe(300));
    tracker.commit(300);
    try std.testing.expect(!tracker.observe(300));
}

fn infoFromArgv(allocator: Allocator, argv: []const []const u8) !ProcessInfo {
    const owned = try allocator.alloc([]u8, argv.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |arg| allocator.free(arg);
        allocator.free(owned);
    }
    for (argv) |src| {
        owned[filled] = try allocator.dupe(u8, src);
        filled += 1;
    }
    return .{ .allocator = allocator, .pid = 1, .comm = try allocator.dupe(u8, "c\xff"), .argv = owned };
}

fn serializedArgvLen(argv: []const []u8) !usize {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(argv, .{}, &out.writer);
    return out.written().len;
}

test "argv of control bytes is bounded after JSON escaping" {
    const huge = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(huge);
    @memset(huge, 0x01);

    var info = try infoFromArgv(std.testing.allocator, &.{ "cmd", huge, "after" });
    defer info.deinit();
    try sanitizeProcessInfo(&info);

    try std.testing.expect(info.argv_truncated);
    try std.testing.expectEqual(@as(usize, 2), info.argv.len);
    const len = try serializedArgvLen(info.argv);
    try std.testing.expect(len <= max_serialized_argv_bytes);
    // Within one escape sequence of the bound.
    try std.testing.expect(len > max_serialized_argv_bytes - 6);
}

test "argv bound cuts at argument and code point boundaries" {
    const allocator = std.testing.allocator;
    // Exactly fills the bound: ["xxx..."] = 2 + 2 + n.
    const exact = try allocator.alloc(u8, max_serialized_argv_bytes - 4);
    defer allocator.free(exact);
    @memset(exact, 'x');
    var fits = try infoFromArgv(std.testing.allocator, &.{exact});
    defer fits.deinit();
    try sanitizeProcessInfo(&fits);
    try std.testing.expect(!fits.argv_truncated);
    try std.testing.expectEqual(max_serialized_argv_bytes, try serializedArgvLen(fits.argv));

    // A two-byte code point straddling the bound is dropped whole.
    const multi = try allocator.alloc(u8, max_serialized_argv_bytes - 3);
    defer allocator.free(multi);
    @memset(multi, 'x');
    @memcpy(multi[multi.len - 2 ..], "\xc3\xa9");
    var straddle = try infoFromArgv(allocator, &.{ multi, "next" });
    defer straddle.deinit();
    try sanitizeProcessInfo(&straddle);
    try std.testing.expect(straddle.argv_truncated);
    try std.testing.expectEqual(@as(usize, 1), straddle.argv.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(straddle.argv[0]));
    try std.testing.expectEqual(max_serialized_argv_bytes - 5, straddle.argv[0].len);
}

test "sanitized foreground metadata always serializes as JSON strings" {
    var info = try infoFromArgv(std.testing.allocator, &.{ "vim", "file\xff\xfe.txt", "\xc3" });
    defer info.deinit();
    try sanitizeProcessInfo(&info);
    try std.testing.expectEqualStrings("c\u{FFFD}", info.comm);

    const json = try protocol.notification(std.testing.allocator, protocol.foreground_changed_method, protocol.ForegroundChangedParams{
        .session_id = "s",
        .pid = info.pid,
        .comm = info.comm,
        .argv = info.argv,
        .argv_truncated = info.argv_truncated,
    });
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expect(params.get("comm").? == .string);
    for (params.get("argv").?.array.items) |item| try std.testing.expect(item == .string);
    try std.testing.expectEqualStrings("file\u{FFFD}\u{FFFD}.txt", params.get("argv").?.array.items[1].string);
}

fn sanitizeForAllocTest(allocator: Allocator) !void {
    const huge = try allocator.alloc(u8, max_serialized_argv_bytes);
    defer allocator.free(huge);
    @memset(huge, '"');
    var info = try infoFromArgv(allocator, &.{ "a\xff", huge, "z" });
    defer info.deinit();
    try sanitizeProcessInfo(&info);
}

test "sanitizeProcessInfo leaves a freeable ProcessInfo on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sanitizeForAllocTest, .{});
}

test "resolveProcessInfo never fails for a missing pid" {
    const missing: posix.pid_t = 0x7fff_fff0;
    var info = try resolveProcessInfo(std.testing.allocator, std.testing.io, missing);
    defer info.deinit();
    try std.testing.expect(info.comm.len > 0);
    if (builtin.os.tag == .linux) {
        try std.testing.expect(info.degraded);
        try std.testing.expectEqualStrings("pid-2147483632", info.comm);
    }
}

test "tcgetpgrp errno mapping never hits unreachable" {
    try std.testing.expectError(error.Unexpected, pgrpFromErrno(-1, .INVAL));
    try std.testing.expectError(error.Unexpected, pgrpFromErrno(-1, .BADF));
    try std.testing.expectError(error.NotATerminal, pgrpFromErrno(-1, .NOTTY));
    try std.testing.expectError(error.Interrupted, pgrpFromErrno(-1, .INTR));
    try std.testing.expectEqual(@as(posix.pid_t, 42), try pgrpFromErrno(42, .SUCCESS));
}

test "terminalForegroundPgrp reports errors for bad descriptors" {
    try std.testing.expectError(error.Unexpected, terminalForegroundPgrp(-1));
    const sys = @import("sys.zig");
    const fds = try sys.pipe();
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try std.testing.expectError(error.NotATerminal, terminalForegroundPgrp(fds[0]));
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("foreground/argv.zig");
    _ = @import("foreground/darwin.zig");
    _ = @import("foreground/linux.zig");
}
