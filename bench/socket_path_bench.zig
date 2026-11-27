const std = @import("std");
const bench = @import("bench");
const socket_path = @import("socket_path");

/// Thread-local fake environment, like `socket_path`'s own `TestEnv`, so each
/// benchmark selects one precedence branch of `resolve`.
const Env = struct {
    threadlocal var zmux_socket: ?[]const u8 = null;
    threadlocal var xdg_runtime_dir: ?[]const u8 = null;
    threadlocal var home: ?[]const u8 = null;

    fn set(zmux: ?[]const u8, xdg: ?[]const u8, home_dir: ?[]const u8) void {
        zmux_socket = zmux;
        xdg_runtime_dir = xdg;
        home = home_dir;
    }

    fn get(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "ZMUX_SOCKET")) return zmux_socket;
        if (std.mem.eql(u8, name, "XDG_RUNTIME_DIR")) return xdg_runtime_dir;
        if (std.mem.eql(u8, name, "HOME")) return home;
        return null;
    }
};

const ResolveCtx = struct { allocator: std.mem.Allocator, override: ?[]const u8 };

fn resolveOnce(ctx: ResolveCtx) !void {
    const path = try socket_path.resolve(ctx.allocator, ctx.override, Env.get);
    bench.doNotOptimize(path.ptr);
    ctx.allocator.free(path);
}

const PathCtx = struct { allocator: std.mem.Allocator, path: []const u8 };

fn absolutizeOnce(ctx: PathCtx) !void {
    const path = try socket_path.absolutize(ctx.allocator, ctx.path);
    bench.doNotOptimize(path.ptr);
    ctx.allocator.free(path);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "socket_path", argv);
    defer runner.deinit();

    Env.set(null, null, null);
    try runner.run("resolve_override", .{}, ResolveCtx{ .allocator = allocator, .override = "/tmp/zmux-bench.sock" }, resolveOnce);

    Env.set("/tmp/zmux-env.sock", null, null);
    try runner.run("resolve_env", .{}, ResolveCtx{ .allocator = allocator, .override = null }, resolveOnce);

    Env.set(null, "/run/user/1000", "/home/dev");
    try runner.run("resolve_xdg", .{}, ResolveCtx{ .allocator = allocator, .override = null }, resolveOnce);

    Env.set(null, null, "/home/dev");
    try runner.run("resolve_home", .{}, ResolveCtx{ .allocator = allocator, .override = null }, resolveOnce);

    Env.set(null, null, null);
    try runner.run("resolve_fallback_tmp", .{}, ResolveCtx{ .allocator = allocator, .override = null }, resolveOnce);

    try runner.run("absolutize_absolute", .{}, PathCtx{ .allocator = allocator, .path = "/tmp/zmux-501/sessions.sock" }, absolutizeOnce);
    try runner.run("absolutize_relative", .{}, PathCtx{ .allocator = allocator, .path = "././run/sessions.sock" }, absolutizeOnce);

    try runner.run("validate", .{}, PathCtx{ .allocator = allocator, .path = "/tmp/zmux-501/sessions.sock" }, struct {
        fn f(ctx: PathCtx) !void {
            // Hide the constant path so the checks are not folded away.
            var path = ctx.path;
            bench.doNotOptimize(&path);
            try socket_path.validate(path);
        }
    }.f);

    Env.set(null, null, "/home/dev");
    try runner.run("isDefaultManaged_home", .{}, {}, struct {
        fn f(_: void) !void {
            bench.doNotOptimize(socket_path.isDefaultManaged("/home/dev/.smithers/sessions.sock", Env.get));
        }
    }.f);
    try runner.run("isDefaultManaged_explicit", .{}, {}, struct {
        fn f(_: void) !void {
            bench.doNotOptimize(socket_path.isDefaultManaged("/var/run/explicit.sock", Env.get));
        }
    }.f);

    try runner.finish();
}
