const std = @import("std");
const bench = @import("bench");
const buffer = @import("buffer");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "buffer", argv);
    defer runner.deinit();

    // Pre-allocated chunks for append benchmarks.
    var chunk_64: [64]u8 = undefined;
    @memset(&chunk_64, 'a');
    chunk_64[63] = '\n';

    const chunk_4k = try allocator.alloc(u8, 4 * 1024);
    defer allocator.free(chunk_4k);
    fillLines(chunk_4k, 80);

    const chunk_64k = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(chunk_64k);
    fillLines(chunk_64k, 80);

    // 1. Append throughput into default 10 MiB scrollback buffer (steady wrapped state).
    {
        var sb = try buffer.ScrollbackBuffer.init(allocator, buffer.default_capacity);
        defer sb.deinit();
        // Fill past capacity once so every append exercises the wrap path.
        for (0..200) |_| sb.append(chunk_64k);

        const AppendCtx = struct { sb: *buffer.ScrollbackBuffer, bytes: []const u8 };
        try runner.run("append_64B_wrapped_10MiB", .{ .bytes_per_op = chunk_64.len }, AppendCtx{ .sb = &sb, .bytes = &chunk_64 }, struct {
            fn f(ctx: AppendCtx) void {
                ctx.sb.append(ctx.bytes);
                bench.doNotOptimize(ctx.sb.start);
            }
        }.f);

        try runner.run("append_4KiB_wrapped_10MiB", .{ .bytes_per_op = chunk_4k.len }, AppendCtx{ .sb = &sb, .bytes = chunk_4k }, struct {
            fn f(ctx: AppendCtx) void {
                ctx.sb.append(ctx.bytes);
                bench.doNotOptimize(ctx.sb.start);
            }
        }.f);

        try runner.run("append_64KiB_wrapped_10MiB", .{ .bytes_per_op = chunk_64k.len }, AppendCtx{ .sb = &sb, .bytes = chunk_64k }, struct {
            fn f(ctx: AppendCtx) void {
                ctx.sb.append(ctx.bytes);
                bench.doNotOptimize(ctx.sb.start);
            }
        }.f);

        // 2. Full snapshot of a wrapped 10 MiB ring buffer.
        const SnapCtx = struct { sb: *const buffer.ScrollbackBuffer, allocator: std.mem.Allocator };
        try runner.run("snapshot_10MiB_wrapped", .{ .bytes_per_op = buffer.default_capacity, .min_sample_ns = 30 * std.time.ns_per_ms }, SnapCtx{ .sb = &sb, .allocator = allocator }, struct {
            fn f(ctx: SnapCtx) !void {
                const out = try ctx.sb.snapshot(ctx.allocator);
                bench.doNotOptimize(out.ptr);
                ctx.allocator.free(out);
            }
        }.f);

        // 3. captureLastLines on a full wrapped 10 MiB scrollback buffer.
        const CaptureCtx = struct { sb: *const buffer.ScrollbackBuffer, allocator: std.mem.Allocator, lines: usize };
        try runner.run("captureLastLines_50_from_10MiB", .{ .bytes_per_op = 50 * 80, .min_sample_ns = 30 * std.time.ns_per_ms }, CaptureCtx{ .sb = &sb, .allocator = allocator, .lines = 50 }, struct {
            fn f(ctx: CaptureCtx) !void {
                const out = try ctx.sb.captureLastLines(ctx.allocator, ctx.lines);
                bench.doNotOptimize(out.ptr);
                ctx.allocator.free(out);
            }
        }.f);

        try runner.run("captureLastLines_200_from_10MiB", .{ .bytes_per_op = 200 * 80, .min_sample_ns = 30 * std.time.ns_per_ms }, CaptureCtx{ .sb = &sb, .allocator = allocator, .lines = 200 }, struct {
            fn f(ctx: CaptureCtx) !void {
                const out = try ctx.sb.captureLastLines(ctx.allocator, ctx.lines);
                bench.doNotOptimize(out.ptr);
                ctx.allocator.free(out);
            }
        }.f);

        try runner.run("captureLastLines_2000_from_10MiB", .{ .bytes_per_op = 2000 * 80, .min_sample_ns = 30 * std.time.ns_per_ms }, CaptureCtx{ .sb = &sb, .allocator = allocator, .lines = 2000 }, struct {
            fn f(ctx: CaptureCtx) !void {
                const out = try ctx.sb.captureLastLines(ctx.allocator, ctx.lines);
                bench.doNotOptimize(out.ptr);
                ctx.allocator.free(out);
            }
        }.f);
    }

    // 4. Oversized append (>= buffer capacity).
    {
        var sb = try buffer.ScrollbackBuffer.init(allocator, 64 * 1024);
        defer sb.deinit();
        const big = try allocator.alloc(u8, 256 * 1024);
        defer allocator.free(big);
        fillLines(big, 80);

        const Ctx = struct { sb: *buffer.ScrollbackBuffer, bytes: []const u8 };
        try runner.run("append_oversize_256KiB_into_64KiB", .{ .bytes_per_op = 64 * 1024 }, Ctx{ .sb = &sb, .bytes = big }, struct {
            fn f(ctx: Ctx) void {
                ctx.sb.append(ctx.bytes);
                bench.doNotOptimize(ctx.sb.len);
            }
        }.f);
    }

    try runner.finish();
}

fn fillLines(buf: []u8, line_len: usize) void {
    for (buf, 0..) |*byte, i| {
        byte.* = if ((i + 1) % line_len == 0) '\n' else 'A' + @as(u8, @intCast(i % 26));
    }
}
