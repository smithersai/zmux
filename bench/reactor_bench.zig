const std = @import("std");
const bench = @import("bench");
const reactor = @import("reactor");

const Reactor = reactor.Reactor;
const Event = reactor.Event;
const c = std.c;
const posix = std.posix;

fn openPipe() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

fn writeByte(fd: posix.fd_t, byte: u8) !void {
    const buf = [1]u8{byte};
    while (true) {
        const rc = c.write(fd, &buf, 1);
        if (rc == 1) return;
        if (posix.errno(rc) == .INTR) continue;
        return error.WriteFailed;
    }
}

fn readByte(fd: posix.fd_t) !u8 {
    var buf: [1]u8 = undefined;
    while (true) {
        const rc = c.read(fd, &buf, 1);
        if (rc == 1) return buf[0];
        if (posix.errno(rc) == .INTR) continue;
        return error.ReadFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "reactor", argv);
    defer runner.deinit();

    // 1. Single-pipe wakeup roundtrip latency (write -> reactor.wait -> read).
    {
        var r = try Reactor.init(allocator);
        defer r.deinit();
        const fds = try openPipe();
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try r.watchFd(fds[0], 1, .{ .read = true });

        const PipeCtx = struct { r: *Reactor, rfd: posix.fd_t, wfd: posix.fd_t };
        try runner.run(
            "pipe_wakeup_roundtrip",
            .{ .bytes_per_op = 1, .min_sample_ns = 15 * std.time.ns_per_ms },
            PipeCtx{ .r = &r, .rfd = fds[0], .wfd = fds[1] },
            struct {
                fn f(ctx: PipeCtx) !void {
                    try writeByte(ctx.wfd, 'x');
                    var events: [4]Event = undefined;
                    const ready = try ctx.r.wait(&events, 1000);
                    bench.doNotOptimize(ready.len);
                    const b = try readByte(ctx.rfd);
                    bench.doNotOptimize(b);
                }
            }.f,
        );
    }

    // 2. Cross-thread wake() ping-pong latency (main <-> worker reactor).
    {
        var r_main = try Reactor.init(allocator);
        defer r_main.deinit();
        var r_worker = try Reactor.init(allocator);
        defer r_worker.deinit();
        var stop = std.atomic.Value(bool).init(false);

        const Worker = struct {
            main_r: *Reactor,
            worker_r: *Reactor,
            stop: *std.atomic.Value(bool),

            fn run(self: @This()) void {
                var events: [4]Event = undefined;
                while (true) {
                    const ready = self.worker_r.wait(&events, -1) catch return;
                    if (self.stop.load(.acquire)) return;
                    if (ready.len > 0) {
                        self.main_r.wake() catch return;
                    }
                }
            }
        };

        const thread = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .main_r = &r_main,
            .worker_r = &r_worker,
            .stop = &stop,
        }});
        defer {
            stop.store(true, .release);
            r_worker.wake() catch {};
            thread.join();
        }

        const WakeCtx = struct { main_r: *Reactor, worker_r: *Reactor };
        try runner.run(
            "cross_thread_wake_latency",
            .{ .min_sample_ns = 20 * std.time.ns_per_ms },
            WakeCtx{ .main_r = &r_main, .worker_r = &r_worker },
            struct {
                fn f(ctx: WakeCtx) !void {
                    try ctx.worker_r.wake();
                    var events: [4]Event = undefined;
                    const ready = try ctx.main_r.wait(&events, 2000);
                    bench.doNotOptimize(ready.len);
                }
            }.f,
        );
    }

    // 3. 64-fd batch dispatch (write 64 pipes -> batch wait -> read all 64).
    {
        const fd_count = 64;
        var r = try Reactor.init(allocator);
        defer r.deinit();

        var pipes: [fd_count][2]posix.fd_t = undefined;
        var opened: usize = 0;
        defer for (0..opened) |i| {
            _ = c.close(pipes[i][0]);
            _ = c.close(pipes[i][1]);
        };
        for (0..fd_count) |i| {
            pipes[i] = try openPipe();
            opened += 1;
            try r.watchFd(pipes[i][0], i, .{ .read = true });
        }

        const BatchCtx = struct { r: *Reactor, pipes: *[fd_count][2]posix.fd_t };
        try runner.run(
            "batch_dispatch_64_fds",
            .{ .bytes_per_op = fd_count, .min_sample_ns = 20 * std.time.ns_per_ms },
            BatchCtx{ .r = &r, .pipes = &pipes },
            struct {
                fn f(ctx: BatchCtx) !void {
                    for (ctx.pipes) |p| try writeByte(p[1], 'm');
                    var events: [fd_count]Event = undefined;
                    var drained: usize = 0;
                    while (drained < fd_count) {
                        const ready = try ctx.r.wait(&events, 1000);
                        for (ready) |ev| {
                            const b = try readByte(ev.fd);
                            bench.doNotOptimize(b);
                            drained += 1;
                        }
                    }
                    bench.doNotOptimize(drained);
                }
            }.f,
        );
    }

    try runner.finish();
}
