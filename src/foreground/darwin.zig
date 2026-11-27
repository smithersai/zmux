//! Darwin process lookup through `proc_pidpath` and `KERN_PROCARGS2`.

const std = @import("std");
const builtin = @import("builtin");

const argv_mod = @import("argv.zig");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const assert = std.debug.assert;
const ProcessInfo = argv_mod.ProcessInfo;
const ParsedArgv = argv_mod.ParsedArgv;
const parseProcArgs = argv_mod.parseProcArgs;
const fallbackArgv = argv_mod.fallbackArgv;
const freeArgv = argv_mod.freeArgv;

/// Resolve `pid` from its executable path and `KERN_PROCARGS2`. Every OS
/// failure degrades to the path or `pid-<n>` form; only OOM propagates.
pub fn resolveDarwinProcessInfo(allocator: Allocator, pid: posix.pid_t) Allocator.Error!ProcessInfo {
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
    assert(comm.len > 0);

    return .{
        .allocator = allocator,
        .pid = pid,
        .comm = comm,
        .argv = argv,
        .argv_truncated = parsed.truncated,
        .degraded = degraded,
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
    try sysctlRead(&.{ ctl_kern, kern_argmax }, &argmax, &argmax_len);
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
    if (sysctlRead(&.{ ctl_kern, kern_procargs2, @as(c_int, @intCast(pid)) }, &stack_buf, &procargs_len)) {
        assert(procargs_len <= stack_buf.len);
        return try parseProcArgs(allocator, stack_buf[0..procargs_len], fallback_path);
    } else |_| {}

    const argmax = try darwinArgMax();
    if (argmax == 0) return .{ .argv = try fallbackArgv(allocator, fallback_path) };

    const buffer = try allocator.alloc(u8, argmax);
    defer allocator.free(buffer);

    procargs_len = buffer.len;
    try sysctlRead(&.{ ctl_kern, kern_procargs2, @as(c_int, @intCast(pid)) }, buffer.ptr, &procargs_len);

    return try parseProcArgs(allocator, buffer[0..@min(procargs_len, buffer.len)], fallback_path);
}

const ctl_kern: c_int = 1;
const kern_argmax: c_int = 8;
const kern_procargs2: c_int = 49;

/// Errors from a `sysctl` read. XNU reports a pid that does not exist or
/// already exited as EINVAL or ESRCH; both map to `ProcessNotFound`.
const SysctlError = posix.SysCtlError || error{ProcessNotFound};

/// Read the `sysctl` MIB `name` into `oldp`. Calls libc directly so an
/// expected errno never reaches `posix.unexpectedErrno`, which dumps a stack
/// trace in debug builds.
fn sysctlRead(name: []const c_int, oldp: ?*anyopaque, oldlenp: *usize) SysctlError!void {
    assert(name.len >= 2);
    const name_len = std.math.cast(c_uint, name.len) orelse return error.NameTooLong;
    const rc = std.c.sysctl(name.ptr, name_len, oldp, oldlenp, null, 0);
    return sysctlFromErrno(posix.errno(rc));
}

/// Map one `sysctl` errno. Matches `posix.sysctl` for PERM, NOMEM, NOENT, and
/// every other errno, and reports EINVAL and ESRCH as `ProcessNotFound`.
fn sysctlFromErrno(e: posix.E) SysctlError!void {
    return switch (e) {
        .SUCCESS => {},
        .INVAL, .SRCH => error.ProcessNotFound,
        .PERM => error.PermissionDenied,
        .NOMEM => error.SystemResources,
        .NOENT => error.UnknownName,
        else => |err| posix.unexpectedErrno(err),
    };
}

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

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

test "sysctl errno mapping reports a vanished pid without unexpectedErrno" {
    try sysctlFromErrno(.SUCCESS);
    try std.testing.expectError(error.ProcessNotFound, sysctlFromErrno(.INVAL));
    try std.testing.expectError(error.ProcessNotFound, sysctlFromErrno(.SRCH));
    try std.testing.expectError(error.PermissionDenied, sysctlFromErrno(.PERM));
    try std.testing.expectError(error.SystemResources, sysctlFromErrno(.NOMEM));
    try std.testing.expectError(error.UnknownName, sysctlFromErrno(.NOENT));
}

test "procArgsDarwin reports a missing pid as ProcessNotFound" {
    if (!builtin.os.tag.isDarwin()) return error.SkipZigTest;
    // Above any pid XNU assigns (PID_MAX is 99999).
    const missing: posix.pid_t = 0x7fff_fff0;
    try std.testing.expectError(error.ProcessNotFound, procArgsDarwin(std.testing.allocator, missing, ""));
}
