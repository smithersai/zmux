const std = @import("std");
const bench = @import("bench");
const pty = @import("pty");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "pty", argv);
    defer runner.deinit();

    // 1. Pty.spawn + exit + reap lifecycle latency.
    const SpawnCtx = struct { allocator: std.mem.Allocator, io: std.Io };
    try runner.run("pty_spawn_exit_reap", .{
        .samples = 5,
        .fixed_iters = 5,
    }, SpawnCtx{ .allocator = allocator, .io = io }, struct {
        fn f(ctx: SpawnCtx) !void {
            var child = try pty.Pty.spawn(ctx.allocator, ctx.io, .{
                .shell = "/bin/sh",
                .command = "exit 0",
                .rows = 24,
                .cols = 80,
            });
            defer child.close();
            var waited: usize = 0;
            while (waited < 500) : (waited += 1) {
                if (child.reapExited() != null or child.isReaped()) break;
                ctx.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            if (!child.isReaped()) {
                child.kill();
                _ = child.reapExited();
            }
        }
    }.f);

    // 2. Pty.resize (TIOCSWINSZ ioctl) latency on a live PTY.
    {
        var child = try pty.Pty.spawn(allocator, io, .{
            .shell = "/bin/sh",
            .command = "stty raw -echo; exec cat",
            .rows = 24,
            .cols = 80,
        });
        defer {
            child.kill();
            var w: usize = 0;
            while (w < 100 and !child.isReaped()) : (w += 1) {
                if (child.reapExited() != null) break;
                io.sleep(.fromMilliseconds(2), .awake) catch {};
            }
            child.close();
        }

        // Wait briefly for `stty raw -echo; exec cat` to come up.
        io.sleep(.fromMilliseconds(50), .awake) catch {};

        const ResizeCtx = struct { child: *pty.Pty, toggle: bool = false };
        var rctx: ResizeCtx = .{ .child = &child };
        try runner.run("pty_resize_ioctl", .{}, &rctx, struct {
            fn f(ctx: *ResizeCtx) !void {
                ctx.toggle = !ctx.toggle;
                if (ctx.toggle) {
                    try ctx.child.resize(120, 40);
                } else {
                    try ctx.child.resize(80, 24);
                }
            }
        }.f);

        // 3. Pty write + read round-trip latency (512B chunk echoed through raw PTY `cat`).
        var write_buf: [512]u8 = @splat('x');
        var read_buf: [4096]u8 = undefined;
        // Drain any shell banner first.
        while (try child.pollReadable(5)) {
            const n = child.read(&read_buf) catch break;
            if (n == 0) break;
        }

        const EchoCtx = struct { child: *pty.Pty, src: []const u8, dst: []u8 };
        try runner.run("pty_write_read_echo_512B", .{
            .bytes_per_op = write_buf.len,
            .min_sample_ns = 20 * std.time.ns_per_ms,
        }, EchoCtx{ .child = &child, .src = &write_buf, .dst = &read_buf }, struct {
            fn f(ctx: EchoCtx) !void {
                // No deadline and no stop descriptor: the echo `cat` always reads.
                try ctx.child.write(ctx.src, std.math.maxInt(i64), -1);
                var got: usize = 0;
                while (got < ctx.src.len) {
                    // The master is non-blocking: wait for the echo first.
                    if (!try ctx.child.pollReadable(5_000)) return error.EchoTimeout;
                    const n = try ctx.child.read(ctx.dst[0..@min(ctx.dst.len, ctx.src.len - got)]);
                    if (n == 0) return error.UnexpectedEof;
                    got += n;
                }
                bench.doNotOptimize(got);
            }
        }.f);
    }

    // 4. Bulk PTY output streaming throughput (4 MiB produced by dd -> Pty.read).
    try runner.run("pty_bulk_read_4MiB", .{
        .bytes_per_op = 4 * 1024 * 1024,
        .samples = 5,
        .fixed_iters = 1,
    }, SpawnCtx{ .allocator = allocator, .io = io }, struct {
        fn f(ctx: SpawnCtx) !void {
            var child = try pty.Pty.spawn(ctx.allocator, ctx.io, .{
                .shell = "/bin/sh",
                .command = "dd if=/dev/zero bs=65536 count=64 2>/dev/null",
                .rows = 24,
                .cols = 80,
            });
            defer {
                child.kill();
                var w: usize = 0;
                while (w < 100 and !child.isReaped()) : (w += 1) {
                    if (child.reapExited() != null) break;
                    ctx.io.sleep(.fromMilliseconds(2), .awake) catch {};
                }
                child.close();
            }

            var buf: [32 * 1024]u8 = undefined;
            var total: usize = 0;
            while (total < 4 * 1024 * 1024) {
                // The master is non-blocking: wait for output, stop on EOF/HUP.
                if (!(child.pollReadable(5_000) catch break)) break;
                const n = child.read(&buf) catch break;
                if (n == 0) break;
                total += n;
            }
            bench.doNotOptimize(total);
        }
    }.f);

    try runner.finish();
}
