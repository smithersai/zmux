const std = @import("std");
const builtin = @import("builtin");
const bench = @import("bench");
const foreground = @import("foreground");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "foreground", argv);
    defer runner.deinit();

    // 1. Tracker steady-state pgid deduplication + transition.
    {
        var tracker = foreground.Tracker.init(100);
        tracker.commit(100);
        try runner.run("tracker_shouldEmitForPgid_steady", .{}, &tracker, struct {
            fn f(t: *foreground.Tracker) void {
                bench.doNotOptimize(t.observe(100));
                bench.doNotOptimize(t.observe(100));
            }
        }.f);

        try runner.run("tracker_shouldEmitForPgid_transition", .{}, &tracker, struct {
            fn f(t: *foreground.Tracker) void {
                if (t.observe(200)) t.commit(200);
                if (t.observe(300)) t.commit(300);
            }
        }.f);
    }

    // 2. parseLinuxProcComm.
    try runner.run("parseLinuxProcComm", .{}, {}, struct {
        fn f(_: void) void {
            bench.doNotOptimize(foreground.parseLinuxProcComm("kworker/0:1\r\n  \x00"));
        }
    }.f);

    // 3. parseLinuxProcCmdline (short and long argv).
    const AllocSliceCtx = struct { allocator: std.mem.Allocator, raw: []const u8 };
    const short_cmd = "git\x00status\x00--short\x00--branch\x00";
    try runner.run("parseLinuxProcCmdline_4_args", .{ .bytes_per_op = short_cmd.len }, AllocSliceCtx{ .allocator = allocator, .raw = short_cmd }, struct {
        fn f(ctx: AllocSliceCtx) !void {
            const args = try foreground.parseLinuxProcCmdline(ctx.allocator, ctx.raw);
            bench.doNotOptimize(args.ptr);
            foreground.freeArgv(ctx.allocator, args);
        }
    }.f);

    var long_cmd_list: std.ArrayList(u8) = .empty;
    defer long_cmd_list.deinit(allocator);
    for (0..64) |idx| {
        const arg = try std.fmt.allocPrint(allocator, "--flag-{d}=value-{d}", .{ idx, idx });
        defer allocator.free(arg);
        try long_cmd_list.appendSlice(allocator, arg);
        try long_cmd_list.append(allocator, 0);
    }
    try runner.run("parseLinuxProcCmdline_64_args", .{ .bytes_per_op = long_cmd_list.items.len }, AllocSliceCtx{ .allocator = allocator, .raw = long_cmd_list.items }, struct {
        fn f(ctx: AllocSliceCtx) !void {
            const args = try foreground.parseLinuxProcCmdline(ctx.allocator, ctx.raw);
            bench.doNotOptimize(args.ptr);
            foreground.freeArgv(ctx.allocator, args);
        }
    }.f);

    // 4. Darwin KERN_PROCARGS2 buffer parser.
    var procargs_buf: [512]u8 = @splat(0);
    std.mem.writeInt(u32, procargs_buf[0..4], 5, builtin.cpu.arch.endian());
    var off: usize = 4;
    const parts = [_][]const u8{ "/usr/bin/git", "", "git", "diff", "--stat", "--color=always", "HEAD~5" };
    for (parts) |p| {
        @memcpy(procargs_buf[off .. off + p.len], p);
        off += p.len + 1;
    }
    try runner.run("parseProcArgsBuffer_darwin", .{ .bytes_per_op = off }, AllocSliceCtx{ .allocator = allocator, .raw = procargs_buf[0..off] }, struct {
        fn f(ctx: AllocSliceCtx) !void {
            const args = try foreground.parseProcArgsBuffer(ctx.allocator, ctx.raw, "/usr/bin/git");
            bench.doNotOptimize(args.ptr);
            foreground.freeArgv(ctx.allocator, args);
        }
    }.f);

    // 5. Real OS resolveProcessInfo on current process (exercises proc_pidpath + sysctl on macOS, /proc on Linux).
    const ResolveCtx = struct { allocator: std.mem.Allocator, io: std.Io, pid: std.posix.pid_t };
    try runner.run("resolveProcessInfo_self_pid", .{ .min_sample_ns = 25 * std.time.ns_per_ms }, ResolveCtx{
        .allocator = allocator,
        .io = io,
        .pid = std.c.getpid(),
    }, struct {
        fn f(ctx: ResolveCtx) !void {
            var info = try foreground.resolveProcessInfo(ctx.allocator, ctx.io, ctx.pid);
            bench.doNotOptimize(info.comm.ptr);
            info.deinit();
        }
    }.f);

    try runner.finish();
}
