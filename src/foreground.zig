const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const posix = std.posix;

pub const poll_interval_ms: i64 = 500;

pub const ProcessInfo = struct {
    allocator: Allocator,
    pid: posix.pid_t,
    comm: []u8,
    argv: [][]u8,

    pub fn deinit(self: *ProcessInfo) void {
        self.allocator.free(self.comm);
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

pub const Tracker = struct {
    shell_pid: posix.pid_t,
    last_pgid: ?posix.pid_t = null,

    pub fn init(shell_pid: posix.pid_t) Tracker {
        return .{ .shell_pid = shell_pid };
    }

    pub fn shouldEmitForPgid(self: *Tracker, pgid: posix.pid_t) bool {
        if (pgid <= 0) return false;
        if (self.last_pgid) |last| {
            if (last == pgid) return false;
        }
        self.last_pgid = pgid;
        return pgid != self.shell_pid;
    }

    pub fn poll(self: *Tracker, allocator: Allocator, master_fd: posix.fd_t) !?ProcessInfo {
        const pgid = terminalForegroundPgrp(master_fd) catch |err| switch (err) {
            error.NotATerminal => return null,
            else => return err,
        };
        if (!self.shouldEmitForPgid(pgid)) return null;
        return try resolveProcessInfo(allocator, pgid);
    }
};

pub fn resolveProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => try resolveDarwinProcessInfo(allocator, pid),
        .linux => try resolveLinuxProcessInfo(allocator, pid),
        else => try resolveFallbackProcessInfo(allocator, pid),
    };
}

fn resolveDarwinProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    var path_buffer: [4 * std.posix.PATH_MAX]u8 = undefined;
    const path = procPath(pid, &path_buffer);
    const argv = try procArgsDarwin(allocator, pid, path);
    errdefer freeArgv(allocator, argv);

    const comm_source = if (path.len > 0)
        path
    else if (argv.len > 0)
        argv[0]
    else
        "";
    const comm = if (comm_source.len > 0)
        try allocator.dupe(u8, std.fs.path.basename(comm_source))
    else
        try std.fmt.allocPrint(allocator, "pid-{d}", .{pid});
    errdefer allocator.free(comm);

    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
    };
}

const linux_comm_max_bytes: usize = 4 * 1024;
const linux_cmdline_max_bytes: usize = 256 * 1024;

/// Resolves the process name and argv from /proc/<pid>/{comm,cmdline}.
/// Unreadable or empty /proc entries (kernel threads, processes that exited
/// between tcgetpgrp and this call, hidepid mounts) degrade to a
/// `pid-<pid>` name and an empty argv. Only allocation failure propagates,
/// so a foreground poll never fails because a process vanished.
fn resolveLinuxProcessInfo(allocator: Allocator, pid: posix.pid_t) !ProcessInfo {
    var path_buffer: [64]u8 = undefined;

    const argv = argv: {
        const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch unreachable;
        const raw = try readProcFileBounded(allocator, path, linux_cmdline_max_bytes) orelse
            break :argv try allocator.alloc([]u8, 0);
        defer allocator.free(raw);
        break :argv try parseLinuxProcCmdline(allocator, raw);
    };
    errdefer freeArgv(allocator, argv);

    const comm = comm: {
        const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/comm", .{pid}) catch unreachable;
        if (try readProcFileBounded(allocator, path, linux_comm_max_bytes)) |raw| {
            defer allocator.free(raw);
            const name = parseLinuxProcComm(raw);
            if (name.len > 0) break :comm try allocator.dupe(u8, name);
        }
        if (argv.len > 0) {
            const base = std.fs.path.basename(argv[0]);
            if (base.len > 0) break :comm try allocator.dupe(u8, base);
        }
        break :comm try std.fmt.allocPrint(allocator, "pid-{d}", .{pid});
    };

    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
    };
}

/// Reads at most `max_bytes` from a /proc file. procfs reports a size of 0,
/// so this reads until EOF instead of trusting stat. Content past
/// `max_bytes` is truncated. Returns null when the file cannot be opened or
/// read; returns error.OutOfMemory only on allocation failure.
fn readProcFileBounded(allocator: Allocator, path: []const u8, max_bytes: usize) Allocator.Error!?[]u8 {
    var file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var chunk: [4096]u8 = undefined;
    while (buffer.items.len < max_bytes) {
        const want = @min(chunk.len, max_bytes - buffer.items.len);
        const n = file.read(chunk[0..want]) catch {
            buffer.deinit(allocator);
            return null;
        };
        if (n == 0) break;
        try buffer.appendSlice(allocator, chunk[0..n]);
    }

    return try buffer.toOwnedSlice(allocator);
}

/// Trims the trailing newline, carriage return, NUL, and blank padding from a
/// raw /proc/<pid>/comm read. Returns an empty slice when nothing remains.
pub fn parseLinuxProcComm(raw: []const u8) []const u8 {
    return std.mem.trimRight(u8, raw, "\n\r\x00 \t");
}

/// Splits a raw /proc/<pid>/cmdline read into owned argv strings. Arguments
/// are NUL-terminated; a missing final NUL keeps the last argument. Trailing
/// NUL padding (left behind by setproctitle-style rewrites) is dropped, while
/// empty arguments between non-empty ones are preserved.
pub fn parseLinuxProcCmdline(allocator: Allocator, raw: []const u8) ![][]u8 {
    const trimmed = std.mem.trimRight(u8, raw, "\x00");
    if (trimmed.len == 0) return allocator.alloc([]u8, 0);

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

fn procPath(pid: posix.pid_t, buffer: []u8) []const u8 {
    if (!builtin.os.tag.isDarwin()) return "";

    const rc = proc_pidpath(@intCast(pid), buffer.ptr, @intCast(buffer.len));
    if (rc <= 0) return "";

    const used: usize = @intCast(rc);
    const path_slice = buffer[0..used];
    const nul_index = std.mem.indexOfScalar(u8, path_slice, 0) orelse path_slice.len;
    return path_slice[0..nul_index];
}

fn procArgsDarwin(allocator: Allocator, pid: posix.pid_t, fallback_path: []const u8) ![][]u8 {
    var argmax: c_int = 0;
    var argmax_len: usize = @sizeOf(c_int);
    try posix.sysctl(&.{ ctl_kern, kern_argmax }, &argmax, &argmax_len, null, 0);
    if (argmax <= 0) return fallbackArgv(allocator, fallback_path);

    const buffer = try allocator.alloc(u8, @intCast(argmax));
    defer allocator.free(buffer);

    var procargs_len: usize = buffer.len;
    try posix.sysctl(
        &.{ ctl_kern, kern_procargs2, @as(c_int, @intCast(pid)) },
        buffer.ptr,
        &procargs_len,
        null,
        0,
    );

    return try parseProcArgsBuffer(allocator, buffer[0..procargs_len], fallback_path);
}

fn parseProcArgsBuffer(allocator: Allocator, buffer: []const u8, fallback_path: []const u8) ![][]u8 {
    if (buffer.len < @sizeOf(u32)) return fallbackArgv(allocator, fallback_path);

    const argc_u32 = std.mem.readInt(u32, buffer[0..@sizeOf(u32)], builtin.cpu.arch.endian());
    const argc = @as(usize, @intCast(argc_u32));
    if (argc == 0) return fallbackArgv(allocator, fallback_path);

    var offset: usize = @sizeOf(u32);
    while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
    while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}

    var argv = std.ArrayList([]u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    var remaining = argc;
    while (offset < buffer.len and remaining > 0) {
        const start = offset;
        while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
        if (offset == start) {
            while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}
            continue;
        }

        try argv.append(allocator, try allocator.dupe(u8, buffer[start..offset]));
        remaining -= 1;

        while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}
    }

    if (argv.items.len == 0) {
        argv.deinit(allocator);
        return fallbackArgv(allocator, fallback_path);
    }

    return try argv.toOwnedSlice(allocator);
}

fn fallbackArgv(allocator: Allocator, fallback_path: []const u8) ![][]u8 {
    if (fallback_path.len == 0) return allocator.alloc([]u8, 0);

    var argv = try allocator.alloc([]u8, 1);
    errdefer allocator.free(argv);
    argv[0] = try allocator.dupe(u8, fallback_path);
    return argv;
}

fn freeArgv(allocator: Allocator, argv: [][]u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

const ctl_kern: c_int = 1;
const kern_argmax: c_int = 8;
const kern_procargs2: c_int = 49;

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
extern "c" fn tcgetpgrp(fd: c_int) c_int;

fn terminalForegroundPgrp(fd: posix.fd_t) posix.TermioGetPgrpError!posix.pid_t {
    while (true) {
        const rc = tcgetpgrp(fd);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => unreachable,
            .INVAL => unreachable,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

test "tracker deduplicates shell foreground and repeated pgids" {
    var tracker = Tracker.init(100);
    try std.testing.expect(!tracker.shouldEmitForPgid(100));
    try std.testing.expect(!tracker.shouldEmitForPgid(100));
    try std.testing.expect(tracker.shouldEmitForPgid(200));
    try std.testing.expect(!tracker.shouldEmitForPgid(200));
    try std.testing.expect(!tracker.shouldEmitForPgid(100));
    try std.testing.expect(tracker.shouldEmitForPgid(300));
}

test "parse proc args buffer extracts argv after exec path" {
    var buffer: [128]u8 = [_]u8{0} ** 128;
    std.mem.writeInt(u32, buffer[0..4], 3, builtin.cpu.arch.endian());

    var offset: usize = 4;
    @memcpy(buffer[offset .. offset + "/bin/zsh".len], "/bin/zsh");
    offset += "/bin/zsh".len + 1;
    buffer[offset] = 0;
    offset += 1;
    @memcpy(buffer[offset .. offset + "git".len], "git");
    offset += "git".len + 1;
    @memcpy(buffer[offset .. offset + "status".len], "status");
    offset += "status".len + 1;
    @memcpy(buffer[offset .. offset + "--short".len], "--short");
    offset += "--short".len + 1;

    const argv = try parseProcArgsBuffer(std.testing.allocator, buffer[0..offset], "/bin/zsh");
    defer freeArgv(std.testing.allocator, argv);

    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("status", argv[1]);
    try std.testing.expectEqualStrings("--short", argv[2]);
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

test "parseLinuxProcCmdline drops trailing NUL padding" {
    try expectCmdline("nginx: worker\x00\x00\x00\x00", &.{"nginx: worker"});
}

test "parseLinuxProcCmdline preserves internal empty args" {
    try expectCmdline("echo\x00\x00x\x00", &.{ "echo", "", "x" });
}

test "parseLinuxProcCmdline returns empty argv for empty input" {
    try expectCmdline("", &.{});
    try expectCmdline("\x00\x00", &.{});
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

    var info = try resolveLinuxProcessInfo(std.testing.allocator, std.c.getpid());
    defer info.deinit();
    try std.testing.expect(info.comm.len > 0);
    try std.testing.expect(info.argv.len > 0);
    try std.testing.expect(info.argv[0].len > 0);
}

test "resolveLinuxProcessInfo falls back for a missing pid" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Above the kernel's PID_MAX_LIMIT (4194304), so /proc/<pid> never exists.
    const missing: posix.pid_t = 0x7fff_fff0;
    var info = try resolveLinuxProcessInfo(std.testing.allocator, missing);
    defer info.deinit();
    try std.testing.expectEqualStrings("pid-2147483632", info.comm);
    try std.testing.expectEqual(@as(usize, 0), info.argv.len);
}
