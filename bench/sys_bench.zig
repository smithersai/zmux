const std = @import("std");
const bench = @import("bench");
const sys = @import("sys");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "sys", argv);
    defer runner.deinit();

    // 1. UnixAddress.init.
    try runner.run("unixAddress_init", .{}, {}, struct {
        fn f(_: void) !void {
            const addr = try sys.UnixAddress.init("/private/tmp/zmux-501/sessions.sock");
            bench.doNotOptimize(addr.len);
        }
    }.f);

    // 2. unixStreamSocket create + close.
    try runner.run("unixStreamSocket_open_close", .{}, {}, struct {
        fn f(_: void) !void {
            const fd = try sys.unixStreamSocket();
            sys.close(fd);
        }
    }.f);

    // 3. statAt on cwd.
    try runner.run("statAt_cwd", .{}, {}, struct {
        fn f(_: void) !void {
            const st = try sys.statAt(sys.cwd_fd, ".", true);
            bench.doNotOptimize(st.ino);
        }
    }.f);

    // 4. Pipe round-trip (4 KiB).
    {
        const fds = try sys.pipe();
        defer sys.close(fds[0]);
        defer sys.close(fds[1]);

        var write_buf: [4096]u8 = @splat('p');
        var read_buf: [4096]u8 = undefined;
        const PipeCtx = struct { rfd: sys.fd_t, wfd: sys.fd_t, src: []const u8, dst: []u8 };
        try runner.run("pipe_writeAll_read_4KiB", .{ .bytes_per_op = write_buf.len }, PipeCtx{
            .rfd = fds[0],
            .wfd = fds[1],
            .src = &write_buf,
            .dst = &read_buf,
        }, struct {
            fn f(ctx: PipeCtx) !void {
                try sys.writeAll(ctx.wfd, ctx.src);
                var got: usize = 0;
                while (got < ctx.src.len) {
                    got += try sys.read(ctx.rfd, ctx.dst[got..]);
                }
                bench.doNotOptimize(got);
            }
        }.f);
    }

    // 5. Socketpair sendAll + read (4 KiB & 32 KiB).
    {
        const socks = try sys.socketPair();
        defer sys.close(socks[0]);
        defer sys.close(socks[1]);

        const buf_4k = try allocator.alloc(u8, 4 * 1024);
        defer allocator.free(buf_4k);
        @memset(buf_4k, 's');
        const dst_4k = try allocator.alloc(u8, 4 * 1024);
        defer allocator.free(dst_4k);

        const SockCtx = struct { rfd: sys.fd_t, wfd: sys.fd_t, src: []const u8, dst: []u8 };
        try runner.run("socketPair_sendAll_read_4KiB", .{ .bytes_per_op = buf_4k.len }, SockCtx{
            .rfd = socks[0],
            .wfd = socks[1],
            .src = buf_4k,
            .dst = dst_4k,
        }, struct {
            fn f(ctx: SockCtx) !void {
                try sys.sendAll(ctx.wfd, ctx.src);
                var got: usize = 0;
                while (got < ctx.src.len) {
                    got += try sys.read(ctx.rfd, ctx.dst[got..]);
                }
                bench.doNotOptimize(got);
            }
        }.f);

        const buf_32k = try allocator.alloc(u8, 32 * 1024);
        defer allocator.free(buf_32k);
        @memset(buf_32k, 't');
        const dst_32k = try allocator.alloc(u8, 32 * 1024);
        defer allocator.free(dst_32k);

        try runner.run("socketPair_sendAll_read_32KiB", .{ .bytes_per_op = buf_32k.len }, SockCtx{
            .rfd = socks[0],
            .wfd = socks[1],
            .src = buf_32k,
            .dst = dst_32k,
        }, struct {
            fn f(ctx: SockCtx) !void {
                try sys.sendAll(ctx.wfd, ctx.src);
                var got: usize = 0;
                while (got < ctx.src.len) {
                    got += try sys.read(ctx.rfd, ctx.dst[got..]);
                }
                bench.doNotOptimize(got);
            }
        }.f);
    }

    try runner.finish();
}
