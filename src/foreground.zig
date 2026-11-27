const std = @import("std");
const builtin = @import("builtin");

const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const assert = std.debug.assert;

/// Interval between foreground process-group polls of a pane's PTY.
pub const poll_interval_ms: i64 = 500;
/// Bound on the serialized argv, measured after JSON escaping.
pub const max_serialized_argv_bytes: usize = 64 * 1024;

/// Name and argv of a foreground process. Owns `comm` and every `argv` entry;
/// release them with `deinit`.
pub const ProcessInfo = struct {
    allocator: Allocator,
    pid: posix.pid_t,
    comm: []u8,
    argv: [][]u8,
    /// True when argv was cut: by the kernel buffer, the /proc read bound,
    /// or `max_serialized_argv_bytes`.
    argv_truncated: bool = false,
    /// True when the OS lookup failed and `comm`/`argv` are the `pid-<n>`
    /// fallback. Callers should not `Tracker.commit` such a result, so a later
    /// poll retries the lookup.
    degraded: bool = false,

    pub fn deinit(self: *ProcessInfo) void {
        self.allocator.free(self.comm);
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

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
        .macos, .ios, .tvos, .watchos, .visionos => try resolveDarwinProcessInfo(allocator, pid),
        .linux => try resolveLinuxProcessInfo(allocator, io, pid),
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

fn resolveDarwinProcessInfo(allocator: Allocator, pid: posix.pid_t) Allocator.Error!ProcessInfo {
    var path_buffer: [4 * std.posix.PATH_MAX]u8 = undefined;
    const path = procPath(pid, &path_buffer);
    var degraded = false;
    const parsed: ParsedArgv = procArgsDarwin(allocator, pid, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            degraded = true;
            break :blk .{ .argv = try fallbackArgv(allocator, path) };
        },
    };
    const argv = parsed.argv;
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
        .argv_truncated = parsed.truncated,
        .degraded = degraded,
    };
}

const linux_comm_max_bytes: usize = 4 * 1024;
const linux_cmdline_max_bytes: usize = 256 * 1024;

/// Resolves the process name and argv from /proc/<pid>/{comm,cmdline}.
/// Unreadable or empty /proc entries (kernel threads, processes that exited
/// between tcgetpgrp and this call, hidepid mounts) degrade to a
/// `pid-<pid>` name and an empty argv. Only allocation failure propagates,
/// so a foreground poll never fails because a process vanished. `degraded`
/// is set when neither file yielded a name, which is the transient case a
/// caller should retry instead of committing.
fn resolveLinuxProcessInfo(allocator: Allocator, io: std.Io, pid: posix.pid_t) Allocator.Error!ProcessInfo {
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

var cached_darwin_argmax = std.atomic.Value(usize).init(0);

fn darwinArgMax() !usize {
    const cached = cached_darwin_argmax.load(.acquire);
    if (cached != 0) return cached;

    var argmax: c_int = 0;
    var argmax_len: usize = @sizeOf(c_int);
    try posix.sysctl(&.{ ctl_kern, kern_argmax }, &argmax, &argmax_len, null, 0);
    if (argmax <= 0) return 0;
    const size: usize = @intCast(argmax);
    assert(size > 0);
    cached_darwin_argmax.store(size, .release);
    return size;
}

fn procArgsDarwin(allocator: Allocator, pid: posix.pid_t, fallback_path: []const u8) !ParsedArgv {
    // Most processes fit well within 64 KiB of procargs2 (exec path + argv + env).
    // Probing a stack buffer first avoids a 1 MiB (ARG_MAX) heap allocation on
    // every foreground transition; if the buffer is too small (macOS returns
    // EINVAL/ENOMEM), fall back to the full cached KERN_ARGMAX buffer.
    var stack_buf: [64 * 1024]u8 = undefined;
    var procargs_len: usize = stack_buf.len;
    if (posix.sysctl(
        &.{ ctl_kern, kern_procargs2, @as(c_int, @intCast(pid)) },
        &stack_buf,
        &procargs_len,
        null,
        0,
    )) {
        return try parseProcArgs(allocator, stack_buf[0..procargs_len], fallback_path);
    } else |_| {}

    const argmax = try darwinArgMax();
    if (argmax == 0) return .{ .argv = try fallbackArgv(allocator, fallback_path) };

    const buffer = try allocator.alloc(u8, argmax);
    defer allocator.free(buffer);

    procargs_len = buffer.len;
    try posix.sysctl(
        &.{ ctl_kern, kern_procargs2, @as(c_int, @intCast(pid)) },
        buffer.ptr,
        &procargs_len,
        null,
        0,
    );

    return try parseProcArgs(allocator, buffer[0..@min(procargs_len, buffer.len)], fallback_path);
}

/// Parse a `KERN_PROCARGS2` buffer and return only the argv slice.
/// See `parseProcArgs` for the format and the truncation flag.
pub fn parseProcArgsBuffer(allocator: Allocator, buffer: []const u8, fallback_path: []const u8) Allocator.Error![][]u8 {
    return (try parseProcArgs(allocator, buffer, fallback_path)).argv;
}

/// Owned argv parsed from a process-arguments buffer.
pub const ParsedArgv = struct {
    argv: [][]u8,
    /// The buffer ended before `argc` arguments were read.
    truncated: bool = false,
};

/// Pointer size of every process Darwin still runs. XNU pads the saved exec
/// path to this alignment (`exec_extract_strings`).
const procargs_pointer_size: usize = 8;

/// Parse a Darwin `KERN_PROCARGS2` buffer:
///
///     argc:u32 | exec_path NUL | NUL padding | argv[0] NUL ... argv[argc-1] NUL | envp ...
///
/// The environment follows argv with no separator and may hold secrets, so
/// the parser must consume exactly `argc` strings starting at the true argv
/// boundary. That boundary is established independently of the argv bytes:
/// XNU pads `exec_path NUL` with NULs to a pointer-size multiple, so the
/// length of the padding follows from the path length alone. NULs past the
/// padding are empty leading arguments (`argv[0] == ""`) and each consumes
/// one of the `argc` slots. Inside the argv area each NUL ends exactly one
/// argument, so an empty argument (`git commit -m ""`) also consumes a slot.
///
/// When the NUL run is shorter than the padding the layout is not the one
/// described here and the boundary is ambiguous: only `fallback_path` is
/// reported, with `truncated = true`, and nothing after the path is read. A
/// buffer that ends before `argc` arguments returns what was parsed with
/// `truncated = true`.
pub fn parseProcArgs(allocator: Allocator, buffer: []const u8, fallback_path: []const u8) Allocator.Error!ParsedArgv {
    if (buffer.len < @sizeOf(u32)) return .{ .argv = try fallbackArgv(allocator, fallback_path) };

    const argc_u32 = std.mem.readInt(u32, buffer[0..@sizeOf(u32)], builtin.cpu.arch.endian());
    const argc = @as(usize, @intCast(argc_u32));
    if (argc == 0) return .{ .argv = try fallbackArgv(allocator, fallback_path) };

    var offset: usize = @sizeOf(u32);
    while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
    const path_len = offset - @sizeOf(u32);
    const run_start = offset;
    while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}
    const nul_run = offset - run_start;

    // Terminator plus padding up to the pointer-size boundary.
    const pad = (procargs_pointer_size - (path_len + 1) % procargs_pointer_size) % procargs_pointer_size;
    const expected_run = 1 + pad;
    assert(expected_run <= procargs_pointer_size);
    // The buffer ends inside the NUL run (no argument is visible), or the
    // run is too short for the documented layout: the argv boundary cannot
    // be established, so report the executable alone.
    if (offset >= buffer.len or nul_run < expected_run) {
        return .{ .argv = try fallbackArgv(allocator, fallback_path), .truncated = true };
    }
    assert(nul_run >= expected_run);
    assert(offset < buffer.len);

    // The list is the single owner of every argument until `toOwnedSlice`.
    var argv = std.ArrayList([]u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.ensureTotalCapacity(allocator, @min(argc, 64));

    var remaining = argc;
    var leading_empty = @min(nul_run - expected_run, argc);
    while (leading_empty > 0) : (leading_empty -= 1) {
        const arg = try allocator.dupe(u8, "");
        errdefer allocator.free(arg);
        try argv.append(allocator, arg);
        remaining -= 1;
    }

    var cut = false;
    while (remaining > 0 and offset < buffer.len) {
        const start = offset;
        while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
        // An argument cut off by the end of the buffer is still reported,
        // but marks the result truncated below.
        const terminated = offset < buffer.len;

        const arg = try allocator.dupe(u8, buffer[start..offset]);
        errdefer allocator.free(arg);
        try argv.append(allocator, arg);
        remaining -= 1;

        if (!terminated) {
            cut = true;
            break;
        }
        offset += 1;
    }
    assert(argv.items.len + remaining == argc);
    assert(offset <= buffer.len);
    return .{ .argv = try argv.toOwnedSlice(allocator), .truncated = remaining > 0 or cut };
}

fn fallbackArgv(allocator: Allocator, fallback_path: []const u8) Allocator.Error![][]u8 {
    if (fallback_path.len == 0) return allocator.alloc([]u8, 0);

    var argv = try allocator.alloc([]u8, 1);
    errdefer allocator.free(argv);
    argv[0] = try allocator.dupe(u8, fallback_path);
    return argv;
}

/// Free every argument in `argv` and the slice itself.
pub fn freeArgv(allocator: Allocator, argv: [][]u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

const ctl_kern: c_int = 1;
const kern_argmax: c_int = 8;
const kern_procargs2: c_int = 49;

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
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

test "parse proc args buffer extracts argv after exec path" {
    // "/bin/zsh" is 8 bytes: its terminator plus 7 padding NULs reach the
    // next pointer boundary.
    const buffer = procArgsFixture(3, "/bin/zsh" ++ fixtureBytes(0, 8) ++ "git\x00status\x00--short\x00HOME=/\x00");
    const parsed = try parseProcArgs(std.testing.allocator, &buffer, "/bin/zsh");
    const argv = parsed.argv;
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expect(!parsed.truncated);

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

fn fixtureBytes(comptime byte: u8, comptime count: usize) [count]u8 {
    return @splat(byte);
}

fn procArgsFixture(comptime argc: u32, comptime body: []const u8) [4 + body.len]u8 {
    var out: [4 + body.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], argc, builtin.cpu.arch.endian());
    @memcpy(out[4..], body);
    return out;
}

fn expectProcArgs(buffer: []const u8, expected: []const []const u8, truncated: bool) !void {
    const parsed = try parseProcArgs(std.testing.allocator, buffer, "/bin/x");
    defer freeArgv(std.testing.allocator, parsed.argv);
    try std.testing.expectEqual(expected.len, parsed.argv.len);
    for (expected, parsed.argv) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(truncated, parsed.truncated);
    for (parsed.argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "SECRET") == null);
}

// Fixtures use the exec path "/bin/x" (6 bytes): its terminator plus one
// padding NUL reach the pointer boundary, so argv starts after two NULs.

test "KERN_PROCARGS2 empty argv element never exposes envp" {
    const buffer = procArgsFixture(3, "/bin/x\x00\x00x\x00\x00y\x00SECRET=1\x00");
    try expectProcArgs(&buffer, &.{ "x", "", "y" }, false);
}

test "KERN_PROCARGS2 trailing and repeated empty arguments" {
    const trailing = procArgsFixture(2, "/bin/x\x00\x00x\x00\x00SECRET=1\x00");
    try expectProcArgs(&trailing, &.{ "x", "" }, false);

    const repeated = procArgsFixture(4, "/bin/x\x00\x00git\x00\x00\x00z\x00SECRET=1\x00HOME=/\x00");
    try expectProcArgs(&repeated, &.{ "git", "", "", "z" }, false);
}

test "KERN_PROCARGS2 empty argv[0] consumes a slot and never exposes envp" {
    // One NUL beyond the padding: argv[0] is "".
    const one = procArgsFixture(2, "/bin/x\x00\x00\x00arg\x00SECRET=1\x00HOME=/\x00");
    try expectProcArgs(&one, &.{ "", "arg" }, false);

    // Two empty leading arguments, then one real one.
    const two = procArgsFixture(3, "/bin/x\x00\x00\x00\x00arg\x00SECRET=1\x00");
    try expectProcArgs(&two, &.{ "", "", "arg" }, false);

    // Every argument is empty: the first non-NUL byte is already envp.
    const all = procArgsFixture(2, "/bin/x\x00\x00\x00\x00SECRET=1\x00SECRET=2\x00");
    try expectProcArgs(&all, &.{ "", "" }, false);

    // More NULs than argc slots cannot be arguments; nothing past them is read.
    const excess = procArgsFixture(1, "/bin/x\x00\x00\x00\x00\x00SECRET=1\x00");
    try expectProcArgs(&excess, &.{""}, false);

    // Every exec path length, with an empty argv[0] and a real argv[1].
    inline for (1..18) |path_len| {
        const path = comptime "/" ++ fixtureBytes('p', path_len - 1);
        const pad = comptime (procargs_pointer_size - (path_len + 1) % procargs_pointer_size) % procargs_pointer_size;
        const body = comptime path ++ "\x00" ++ fixtureBytes(0, pad) ++ "\x00" ++ "arg\x00SECRET=1\x00SECRET=2\x00";
        const buffer = comptime procArgsFixture(2, body);
        try expectProcArgs(&buffer, &.{ "", "arg" }, false);
    }
}

test "KERN_PROCARGS2 ambiguous argv boundary reports only the exec path" {
    // "/bin/zsh" needs 8 NULs before argv. A shorter run does not match the
    // documented layout, so no string after the path is trusted.
    const short_run = procArgsFixture(2, "/bin/zsh\x00\x00SECRET=1\x00SECRET=2\x00");
    try expectProcArgs(&short_run, &.{"/bin/x"}, true);

    const no_padding = procArgsFixture(1, "/bin/zsh\x00SECRET=1\x00");
    try expectProcArgs(&no_padding, &.{"/bin/x"}, true);
}

test "KERN_PROCARGS2 truncated buffer reports truncation" {
    const short = procArgsFixture(3, "/bin/x\x00\x00a\x00b");
    try expectProcArgs(&short, &.{ "a", "b" }, true);

    const ends_after_nul = procArgsFixture(3, "/bin/x\x00\x00a\x00");
    try expectProcArgs(&ends_after_nul, &.{"a"}, true);
}

test "KERN_PROCARGS2 degenerate buffers fall back to the exec path" {
    try expectProcArgs("ab", &.{"/bin/x"}, false);
    const zero = procArgsFixture(0, "/bin/x\x00SECRET=1\x00");
    try expectProcArgs(&zero, &.{"/bin/x"}, false);
    const path_only = procArgsFixture(2, "/bin/x\x00\x00\x00");
    try expectProcArgs(&path_only, &.{"/bin/x"}, true);
    const unterminated_path = procArgsFixture(2, "/bin/x");
    try expectProcArgs(&unterminated_path, &.{"/bin/x"}, true);
}

fn parseProcArgsForAllocTest(allocator: Allocator, buffer: []const u8) !void {
    const parsed = try parseProcArgs(allocator, buffer, "/bin/x");
    freeArgv(allocator, parsed.argv);
}

test "parseProcArgs frees partial results on allocation failure" {
    const buffer = procArgsFixture(3, "/bin/x\x00\x00x\x00\x00y\x00SECRET=1\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &buffer)});
    const leading_empty = procArgsFixture(3, "/bin/x\x00\x00\x00\x00y\x00SECRET=1\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &leading_empty)});
}

test "parseProcArgs fallback branches survive every allocation failure" {
    // Positive argc with no parseable argument used to deinit the argv list
    // twice when the fallback allocation failed.
    const path_only = procArgsFixture(2, "/bin/x\x00\x00\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &path_only)});
    const ambiguous = procArgsFixture(2, "/bin/zsh\x00\x00SECRET=1\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &ambiguous)});
    const zero = procArgsFixture(0, "/bin/x\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &zero)});
}

test "a live Darwin process with an empty argv[0] never exposes its environment" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const pid = std.c.fork();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "", "30" };
        const envp = [_:null]?[*:0]const u8{ "SECRET=zmux-envp-marker", "SECRET2=zmux-envp-marker" };
        _ = std.c.execve("/bin/sleep", &argv, &envp);
        std.c._exit(127);
    }
    defer {
        _ = std.c.kill(pid, .KILL);
        _ = std.c.waitpid(pid, null, 0);
    }

    // Wait for the exec: until then the child still shows the test runner.
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        var path_buf: [posix.PATH_MAX]u8 = undefined;
        if (std.mem.endsWith(u8, procPath(pid, &path_buf), "/sleep")) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }

    const parsed = try procArgsDarwin(allocator, pid, "/bin/sleep");
    defer freeArgv(allocator, parsed.argv);
    for (parsed.argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "SECRET") == null);
    try std.testing.expect(!parsed.truncated);
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.len);
    try std.testing.expectEqualStrings("", parsed.argv[0]);
    try std.testing.expectEqualStrings("30", parsed.argv[1]);
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
