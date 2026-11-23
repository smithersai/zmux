const std = @import("std");
const bench = @import("bench");
const rpc_line_reader = @import("rpc_line_reader");
const sys = @import("sys");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "rpc_line_reader", argv);
    defer runner.deinit();

    // 1. Small line (128 B) over a UNIX socketpair.
    {
        const socks = try sys.socketPair();
        defer sys.close(socks[0]);
        defer sys.close(socks[1]);

        var line_128: [128]u8 = @splat('a');
        line_128[127] = '\n';
        var reader: rpc_line_reader.LineReader = .{};

        const Ctx = struct {
            allocator: std.mem.Allocator,
            rfd: sys.fd_t,
            wfd: sys.fd_t,
            reader: *rpc_line_reader.LineReader,
            payload: []const u8,
        };
        try runner.run("readLineAlloc_128B_socketpair", .{ .bytes_per_op = line_128.len }, Ctx{
            .allocator = allocator,
            .rfd = socks[0],
            .wfd = socks[1],
            .reader = &reader,
            .payload = &line_128,
        }, struct {
            fn f(ctx: Ctx) !void {
                try sys.sendAll(ctx.wfd, ctx.payload);
                const line = try ctx.reader.readLineAlloc(ctx.allocator, ctx.rfd, 1024 * 1024);
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);

        // 2. Medium line (4 KiB) over socketpair.
        const line_4k = try allocator.alloc(u8, 4 * 1024);
        defer allocator.free(line_4k);
        @memset(line_4k, 'b');
        line_4k[line_4k.len - 1] = '\n';

        try runner.run("readLineAlloc_4KiB_socketpair", .{ .bytes_per_op = line_4k.len }, Ctx{
            .allocator = allocator,
            .rfd = socks[0],
            .wfd = socks[1],
            .reader = &reader,
            .payload = line_4k,
        }, struct {
            fn f(ctx: Ctx) !void {
                try sys.sendAll(ctx.wfd, ctx.payload);
                const line = try ctx.reader.readLineAlloc(ctx.allocator, ctx.rfd, 1024 * 1024);
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);

        // 3. Pipelined batch of 32 x 128B lines in one write -> drain via readLineAlloc + nextBufferedLineAlloc.
        const batch = try allocator.alloc(u8, 32 * 128);
        defer allocator.free(batch);
        for (0..32) |i| {
            @memcpy(batch[i * 128 .. (i + 1) * 128], &line_128);
        }
        try runner.run("readLineAlloc_batch_32x128B", .{ .bytes_per_op = batch.len }, Ctx{
            .allocator = allocator,
            .rfd = socks[0],
            .wfd = socks[1],
            .reader = &reader,
            .payload = batch,
        }, struct {
            fn f(ctx: Ctx) !void {
                try sys.sendAll(ctx.wfd, ctx.payload);
                for (0..32) |_| {
                    const line = try ctx.reader.readLineAlloc(ctx.allocator, ctx.rfd, 1024 * 1024);
                    bench.doNotOptimize(line.ptr);
                    ctx.allocator.free(line);
                }
            }
        }.f);

        // 4. Timeout-path read (with active deadline, data already ready).
        const TimeoutCtx = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            rfd: sys.fd_t,
            wfd: sys.fd_t,
            reader: *rpc_line_reader.LineReader,
            payload: []const u8,
        };
        try runner.run("readLineAllocTimeout_128B_ready", .{ .bytes_per_op = line_128.len }, TimeoutCtx{
            .allocator = allocator,
            .io = io,
            .rfd = socks[0],
            .wfd = socks[1],
            .reader = &reader,
            .payload = &line_128,
        }, struct {
            fn f(ctx: TimeoutCtx) !void {
                try sys.sendAll(ctx.wfd, ctx.payload);
                const line = try ctx.reader.readLineAllocTimeout(ctx.allocator, ctx.io, ctx.rfd, 1024 * 1024, .{
                    .duration = .{ .raw = .fromSeconds(5), .clock = .awake },
                });
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);
    }

    // 5. Large 64 KiB frame via concurrent writer thread + LineReader (exercises multi-read assembly).
    {
        const socks = try sys.socketPair();
        defer sys.close(socks[0]);
        defer sys.close(socks[1]);

        const frame_64k = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(frame_64k);
        @memset(frame_64k, 'c');
        frame_64k[frame_64k.len - 1] = '\n';

        const LargeCtx = struct {
            allocator: std.mem.Allocator,
            rfd: sys.fd_t,
            wfd: sys.fd_t,
            frame: []const u8,
        };

        const Writer = struct {
            fd: sys.fd_t,
            frame: []const u8,
            count: usize,
            fn run(self: @This()) void {
                for (0..self.count) |_| {
                    sys.sendAll(self.fd, self.frame) catch return;
                }
            }
        };

        // Measure 32 x 64KiB = 2 MiB streamed per benchmark op to amortize thread spawn cleanly.
        try runner.run("readLineAlloc_64KiB_x32_stream", .{
            .bytes_per_op = 32 * frame_64k.len,
            .min_sample_ns = 25 * std.time.ns_per_ms,
        }, LargeCtx{
            .allocator = allocator,
            .rfd = socks[0],
            .wfd = socks[1],
            .frame = frame_64k,
        }, struct {
            fn f(ctx: LargeCtx) !void {
                const t = try std.Thread.spawn(.{}, Writer.run, .{Writer{
                    .fd = ctx.wfd,
                    .frame = ctx.frame,
                    .count = 32,
                }});
                defer t.join();
                var reader: rpc_line_reader.LineReader = .{};
                for (0..32) |_| {
                    const line = try reader.readLineAlloc(ctx.allocator, ctx.rfd, 1024 * 1024);
                    bench.doNotOptimize(line.ptr);
                    ctx.allocator.free(line);
                }
            }
        }.f);
    }

    try runner.finish();
}
