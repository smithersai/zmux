const std = @import("std");
const bench = @import("bench");
const buffer = @import("buffer");
const native = @import("native");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "native", argv);
    defer runner.deinit();

    // 1. Key sequence resolution hot path (ctrl, navigation, function keys, misses).
    try runner.run("keySequence_ctrl_and_named", .{}, {}, struct {
        fn f(_: void) void {
            bench.doNotOptimize(native.keySequence("C-c"));
            bench.doNotOptimize(native.keySequence("Enter"));
            bench.doNotOptimize(native.keySequence("ArrowUp"));
            bench.doNotOptimize(native.keySequence("F12"));
            bench.doNotOptimize(native.keySequence("UnknownKey"));
        }
    }.f);

    // 2. NativeSession operations on a live session with a full 10 MiB scrollback buffer.
    {
        const session = try native.NativeSession.create(allocator, io, .{
            .id = "pane-bench-1",
            .title = "bench-pane",
            .shell = "/bin/sh",
            .command = "exec sleep 60",
            .rows = 40,
            .cols = 120,
            .scrollback_bytes = buffer.default_capacity,
        });
        defer session.release();

        // Pre-fill the session's scrollback buffer to 10 MiB (wrapped) so capture / snapshot measure realistic load.
        const chunk = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(chunk);
        for (chunk, 0..) |*b, i| {
            b.* = if ((i + 1) % 80 == 0) '\n' else 'a' + @as(u8, @intCast(i % 26));
        }
        session.mutex.lockUncancelable(io);
        for (0..180) |_| session.scrollback.append(chunk);
        session.mutex.unlock(io);

        const SessCtx = struct { session: *native.NativeSession, allocator: std.mem.Allocator };
        try runner.run("nativeSession_state_check", .{}, session, struct {
            fn f(s: *native.NativeSession) void {
                bench.doNotOptimize(s.state());
            }
        }.f);

        try runner.run("nativeSession_infoJson", .{}, SessCtx{ .session = session, .allocator = allocator }, struct {
            fn f(ctx: SessCtx) !void {
                const json = try ctx.session.infoJson(ctx.allocator);
                bench.doNotOptimize(json.ptr);
                ctx.allocator.free(json);
            }
        }.f);

        try runner.run("nativeSession_capture_50_from_10MiB", .{
            .bytes_per_op = 50 * 80,
            .min_sample_ns = 30 * std.time.ns_per_ms,
        }, SessCtx{ .session = session, .allocator = allocator }, struct {
            fn f(ctx: SessCtx) !void {
                const text = try ctx.session.capture(ctx.allocator, 50);
                bench.doNotOptimize(text.ptr);
                ctx.allocator.free(text);
            }
        }.f);

        try runner.run("nativeSession_capture_200_from_10MiB", .{
            .bytes_per_op = 200 * 80,
            .min_sample_ns = 30 * std.time.ns_per_ms,
        }, SessCtx{ .session = session, .allocator = allocator }, struct {
            fn f(ctx: SessCtx) !void {
                const text = try ctx.session.capture(ctx.allocator, 200);
                bench.doNotOptimize(text.ptr);
                ctx.allocator.free(text);
            }
        }.f);

        try runner.run("nativeSession_scrollbackSnapshot_10MiB", .{
            .bytes_per_op = buffer.default_capacity,
            .min_sample_ns = 30 * std.time.ns_per_ms,
        }, SessCtx{ .session = session, .allocator = allocator }, struct {
            fn f(ctx: SessCtx) !void {
                const snap = try ctx.session.scrollbackSnapshot(ctx.allocator);
                bench.doNotOptimize(snap.ptr);
                ctx.allocator.free(snap);
            }
        }.f);
    }

    // 3. End-to-end NativeSession readerLoop + EventSink streaming throughput (4 MiB).
    const StreamCtx = struct { allocator: std.mem.Allocator, io: std.Io };
    try runner.run("nativeSession_readerLoop_stream_4MiB", .{
        .bytes_per_op = 4 * 1024 * 1024,
        .samples = 5,
        .fixed_iters = 1,
    }, StreamCtx{ .allocator = allocator, .io = io }, struct {
        const Counter = struct {
            bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            fn onEvent(ctx_ptr: *anyopaque, event: native.Event) void {
                const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
                switch (event) {
                    .pane_output => |out| _ = self.bytes.fetchAdd(out.data.len, .monotonic),
                    .session_exited => self.exited.store(true, .release),
                    else => {},
                }
            }
        };

        fn f(ctx: StreamCtx) !void {
            var counter: Counter = .{};
            const session = try native.NativeSession.create(ctx.allocator, ctx.io, .{
                .id = "pane-stream",
                .shell = "/bin/sh",
                .command = "dd if=/dev/zero bs=65536 count=64 2>/dev/null",
                .rows = 24,
                .cols = 80,
                .scrollback_bytes = 256 * 1024,
                .event_sink = .{
                    .context = &counter,
                    .emit = Counter.onEvent,
                },
            });
            defer session.release();

            const deadline = std.Io.Clock.awake.now(ctx.io).addDuration(.fromSeconds(10));
            while (counter.bytes.load(.monotonic) < 4 * 1024 * 1024 and !counter.exited.load(.acquire)) {
                if (std.Io.Clock.awake.now(ctx.io).compare(.gte, deadline)) break;
                ctx.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            bench.doNotOptimize(counter.bytes.load(.monotonic));
        }
    }.f);

    try runner.finish();
}
