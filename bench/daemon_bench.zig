const std = @import("std");
const bench = @import("bench");
const daemon = @import("daemon");

const hooks = daemon.fuzz_hooks;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "daemon", argv);
    defer runner.deinit();

    const sample_argv = [_][]const u8{
        "zmuxd",
        "--socket",
        "/tmp/zmux-bench.sock",
        "--idle-seconds",
        "3600",
        "--log-level",
        "info",
    };
    try runner.run("parseArgs_cli", .{}, &sample_argv, struct {
        fn f(a: []const []const u8) !void {
            const parsed = try hooks.parseArgsFn(a, null);
            bench.doNotOptimize(parsed.idle_timeout_seconds);
        }
    }.f);

    const AllocCtx = struct { allocator: std.mem.Allocator };
    try runner.run("socketPathFromEnv_xdg", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const path = try hooks.socketPathFromEnvFn(ctx.allocator, null, null, "/run/user/1000", "/home/dev");
            bench.doNotOptimize(path.ptr);
            ctx.allocator.free(path);
        }
    }.f);

    try runner.run("socketPathFromEnv_fallback_tmp", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const path = try hooks.socketPathFromEnvFn(ctx.allocator, null, null, null, null);
            bench.doNotOptimize(path.ptr);
            ctx.allocator.free(path);
        }
    }.f);

    try runner.run("validateSocketPath", .{}, {}, struct {
        fn f(_: void) !void {
            try hooks.validateSocketPathFn("/tmp/zmux-501/sessions.sock");
        }
    }.f);

    try runner.run("pidPath_alloc", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const path = try hooks.pidPathFn(ctx.allocator, "/tmp/zmux-501/sessions.sock");
            bench.doNotOptimize(path.ptr);
            ctx.allocator.free(path);
        }
    }.f);

    try runner.finish();
}
