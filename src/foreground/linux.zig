//! Linux process lookup through `/proc/<pid>/{comm,cmdline}`.

const std = @import("std");
const builtin = @import("builtin");

const argv_mod = @import("argv.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const assert = std.debug.assert;
const ProcessInfo = argv_mod.ProcessInfo;
const freeArgv = argv_mod.freeArgv;

const linux_comm_max_bytes: usize = 4 * 1024;
const linux_cmdline_max_bytes: usize = 256 * 1024;

/// Resolves the process name and argv from /proc/<pid>/{comm,cmdline}.
/// Unreadable or empty /proc entries (kernel threads, processes that exited
/// between tcgetpgrp and this call, hidepid mounts) degrade to a
/// `pid-<pid>` name and an empty argv. Only allocation failure propagates,
/// so a foreground poll never fails because a process vanished. `degraded`
/// is set when neither file yielded a name, which is the transient case a
/// caller should retry instead of committing.
pub fn resolveLinuxProcessInfo(allocator: Allocator, io: std.Io, pid: posix.pid_t) Allocator.Error!ProcessInfo {
    var path_buffer: [linux_proc_path_max]u8 = undefined;

    var argv_truncated = false;
    const argv = argv: {
        const path = linuxProcPath(&path_buffer, pid, "cmdline");
        const raw = try readProcFileBounded(allocator, io, path, linux_cmdline_max_bytes) orelse
            break :argv try allocator.alloc([]u8, 0);
        defer allocator.free(raw.bytes);
        argv_truncated = raw.truncated;
        break :argv try parseLinuxProcCmdline(allocator, raw.bytes);
    };
    errdefer freeArgv(allocator, argv);

    var degraded = false;
    const comm = comm: {
        const path = linuxProcPath(&path_buffer, pid, "comm");
        if (try readProcFileBounded(allocator, io, path, linux_comm_max_bytes)) |raw| {
            defer allocator.free(raw.bytes);
            const name = parseLinuxProcComm(raw.bytes);
            if (name.len > 0) break :comm try allocator.dupe(u8, name);
        }
        if (argv.len > 0) {
            const base = std.fs.path.basename(argv[0]);
            if (base.len > 0) break :comm try allocator.dupe(u8, base);
        }
        degraded = true;
        break :comm try std.fmt.allocPrint(allocator, "pid-{d}", .{pid});
    };

    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
        .argv_truncated = argv_truncated,
        .degraded = degraded,
    };
}

/// Longest `/proc/<pid>/<leaf>` path `linuxProcPath` builds: the widest
/// `pid_t`, including its sign, plus the longest leaf.
const linux_proc_path_max = "/proc/".len + std.fmt.count("{d}", .{std.math.minInt(posix.pid_t)}) + "/cmdline".len;

/// Format `/proc/<pid>/<leaf>` into `buffer`. Cannot fail: `buffer` is sized
/// for the widest `pid_t` and the longest leaf this module reads.
fn linuxProcPath(buffer: *[linux_proc_path_max]u8, pid: posix.pid_t, comptime leaf: []const u8) []const u8 {
    const prefix = "/proc/";
    const tail = "/" ++ leaf;
    comptime assert(tail.len <= "/cmdline".len);
    @memcpy(buffer[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    pos += std.fmt.printInt(buffer[pos..], pid, 10, .lower, .{});
    @memcpy(buffer[pos..][0..tail.len], tail);
    pos += tail.len;
    assert(pos <= buffer.len);
    return buffer[0..pos];
}

const ProcFile = struct { bytes: []u8, truncated: bool };

/// Reads at most `max_bytes` from a /proc file. procfs reports a size of 0,
/// so this reads until EOF instead of trusting stat. Content past
/// `max_bytes` is dropped and reported through `truncated`. Returns null when
/// the file cannot be opened or read; returns error.OutOfMemory only on
/// allocation failure.
fn readProcFileBounded(allocator: Allocator, io: std.Io, path: []const u8, max_bytes: usize) Allocator.Error!?ProcFile {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    // Read one byte past the bound to learn whether anything was cut.
    while (buffer.items.len <= max_bytes) {
        const want = @min(chunk.len, max_bytes + 1 - buffer.items.len);
        assert(want > 0);
        const n = file.readStreaming(io, &.{chunk[0..want]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                buffer.deinit(allocator);
                return null;
            },
        };
        if (n == 0) break;
        try buffer.appendSlice(allocator, chunk[0..n]);
    }

    const truncated = buffer.items.len > max_bytes;
    if (truncated) buffer.shrinkRetainingCapacity(max_bytes);
    assert(buffer.items.len <= max_bytes);
    return .{ .bytes = try buffer.toOwnedSlice(allocator), .truncated = truncated };
}

/// Trims the trailing newline, carriage return, NUL, and blank padding from a
/// raw /proc/<pid>/comm read. Returns an empty slice when nothing remains.
pub fn parseLinuxProcComm(raw: []const u8) []const u8 {
    return std.mem.trimEnd(u8, raw, "\n\r\x00 \t");
}

/// Splits a raw /proc/<pid>/cmdline read into owned argv strings. Every
/// argument is NUL-terminated, so only the single final NUL is stripped:
/// `a\0\0` is `["a", ""]`. A missing final NUL (a truncated read or a
/// setproctitle rewrite) keeps the last argument.
pub fn parseLinuxProcCmdline(allocator: Allocator, raw: []const u8) ![][]u8 {
    if (raw.len == 0) return allocator.alloc([]u8, 0);
    const trimmed = if (raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;

    const count = std.mem.count(u8, trimmed, "\x00") + 1;
    const argv = try allocator.alloc([]u8, count);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    var it = std.mem.splitScalar(u8, trimmed, 0);
    while (it.next()) |arg| : (filled += 1) {
        argv[filled] = try allocator.dupe(u8, arg);
    }
    std.debug.assert(filled == count);
    return argv;
}

test "parseLinuxProcComm trims line endings, NULs, and blank padding" {
    try std.testing.expectEqualStrings("bash", parseLinuxProcComm("bash\n"));
    try std.testing.expectEqualStrings("bash", parseLinuxProcComm("bash\r\n"));
    try std.testing.expectEqualStrings("bash", parseLinuxProcComm("bash\x00"));
    try std.testing.expectEqualStrings("bash", parseLinuxProcComm("bash"));
    try std.testing.expectEqualStrings("kworker/0:1", parseLinuxProcComm("kworker/0:1\n"));
    try std.testing.expectEqualStrings("my prog", parseLinuxProcComm("my prog\n"));
    try std.testing.expectEqualStrings("", parseLinuxProcComm(""));
    try std.testing.expectEqualStrings("", parseLinuxProcComm("\n"));
    try std.testing.expectEqualStrings("", parseLinuxProcComm("  \t \r\n"));
}

fn expectCmdline(raw: []const u8, expected: []const []const u8) !void {
    const argv = try parseLinuxProcCmdline(std.testing.allocator, raw);
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "parseLinuxProcCmdline splits NUL-delimited argv" {
    try expectCmdline("git\x00status\x00--short\x00", &.{ "git", "status", "--short" });
}

test "parseLinuxProcCmdline keeps last arg without trailing NUL" {
    try expectCmdline("vim\x00README.md", &.{ "vim", "README.md" });
    try expectCmdline("top", &.{"top"});
}

test "parseLinuxProcCmdline strips only the final NUL and keeps trailing empty args" {
    try expectCmdline("a\x00\x00", &.{ "a", "" });
    try expectCmdline("nginx: worker\x00\x00\x00", &.{ "nginx: worker", "", "" });
}

test "parseLinuxProcCmdline preserves internal empty args" {
    try expectCmdline("echo\x00\x00x\x00", &.{ "echo", "", "x" });
}

test "parseLinuxProcCmdline returns empty argv for empty input" {
    try expectCmdline("", &.{});
    try expectCmdline("\x00", &.{""});
}

fn parseCmdlineForAllocTest(allocator: Allocator, raw: []const u8) !void {
    const argv = try parseLinuxProcCmdline(allocator, raw);
    freeArgv(allocator, argv);
}

test "parseLinuxProcCmdline frees partial results on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        parseCmdlineForAllocTest,
        .{"ssh\x00-p\x002222\x00\x00host\x00"},
    );
}

test "resolveLinuxProcessInfo reads the current process" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var info = try resolveLinuxProcessInfo(std.testing.allocator, std.testing.io, std.c.getpid());
    defer info.deinit();
    try std.testing.expect(info.comm.len > 0);
    try std.testing.expect(info.argv.len > 0);
    try std.testing.expect(info.argv[0].len > 0);
}

test "resolveLinuxProcessInfo falls back for a missing pid" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Above the kernel's PID_MAX_LIMIT (4194304), so /proc/<pid> never exists.
    const missing: posix.pid_t = 0x7fff_fff0;
    var info = try resolveLinuxProcessInfo(std.testing.allocator, std.testing.io, missing);
    defer info.deinit();
    try std.testing.expectEqualStrings("pid-2147483632", info.comm);
    try std.testing.expectEqual(@as(usize, 0), info.argv.len);
}

test "resolveLinuxProcessInfo is not degraded for the current process" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var info = try resolveLinuxProcessInfo(std.testing.allocator, std.testing.io, std.c.getpid());
    defer info.deinit();
    try std.testing.expect(!info.degraded);
    try std.testing.expect(!info.argv_truncated);
}

test "readProcFileBounded reports truncation past the bound" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const raw = (try readProcFileBounded(std.testing.allocator, std.testing.io, "/proc/self/cmdline", 2)).?;
    defer std.testing.allocator.free(raw.bytes);
    try std.testing.expectEqual(@as(usize, 2), raw.bytes.len);
    try std.testing.expect(raw.truncated);

    try std.testing.expect((try readProcFileBounded(std.testing.allocator, std.testing.io, "/proc/0/none", 16)) == null);
}
