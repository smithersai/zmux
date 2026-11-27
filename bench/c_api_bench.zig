const std = @import("std");
const bench = @import("bench");
const zmux = @import("zmux");

const c_api = zmux.c_api;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "c_api", argv);
    defer runner.deinit();

    // 1. Static version + status lookup overhead across FFI symbols.
    try runner.run("version_and_status_lookup", .{}, {}, struct {
        fn f(_: void) void {
            bench.doNotOptimize(c_api.zmux_version());
            bench.doNotOptimize(c_api.zmux_status_string(.ok));
            bench.doNotOptimize(c_api.zmux_status_string(.err_peer_auth));
        }
    }.f);

    // 2. Scrollback append + capture across the C ABI.
    {
        const sb = c_api.zmux_scrollback_new(64 * 1024) orelse return error.OutOfMemory;
        defer c_api.zmux_scrollback_free(sb);
        const line = "zmux c_api benchmark output line 0123456789\n";
        for (0..256) |_| _ = c_api.zmux_scrollback_append(sb, line.ptr, line.len);

        const AppendCtx = struct { sb: *c_api.ZmuxScrollback, data: []const u8 };
        try runner.run("scrollback_append_44B", .{ .bytes_per_op = line.len }, AppendCtx{ .sb = sb, .data = line }, struct {
            fn f(ctx: AppendCtx) void {
                _ = c_api.zmux_scrollback_append(ctx.sb, ctx.data.ptr, ctx.data.len);
                bench.doNotOptimize(c_api.zmux_scrollback_end_offset(ctx.sb));
            }
        }.f);

        try runner.run("scrollback_capture_20_lines", .{ .bytes_per_op = 20 * line.len }, sb, struct {
            fn f(handle: *c_api.ZmuxScrollback) !void {
                var out: ?[*:0]u8 = null;
                var len: usize = 0;
                if (c_api.zmux_scrollback_capture_lines(handle, 20, 0, &out, &len) != .ok) return error.CaptureFailed;
                bench.doNotOptimize(len);
                c_api.zmux_string_free(out);
            }
        }.f);
    }

    // 3. VT feed + plain text render across the C ABI.
    {
        const handle = c_api.vt_impl.zmux_vt_new(24, 80, 128) orelse return error.OutOfMemory;
        defer c_api.vt_impl.zmux_vt_free(handle);
        const payload = "\x1b[2J\x1b[H\x1b[32mstatus:\x1b[0m ready\r\nline 2\r\n";

        const VtCtx = struct { h: *c_api.ZmuxVt, data: []const u8 };
        try runner.run("vt_feed_and_plain_text", .{ .bytes_per_op = payload.len }, VtCtx{ .h = handle, .data = payload }, struct {
            fn f(ctx: VtCtx) !void {
                _ = c_api.vt_impl.zmux_vt_feed(ctx.h, ctx.data.ptr, ctx.data.len);
                var out: ?[*:0]u8 = null;
                var len: usize = 0;
                if (c_api.vt_impl.zmux_vt_plain_text(ctx.h, 0, &out, &len) != .ok) return error.RenderFailed;
                bench.doNotOptimize(len);
                c_api.zmux_string_free(out);
            }
        }.f);
    }

    try runner.finish();
}
