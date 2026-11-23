const std = @import("std");
const builtin = @import("builtin");
const bench = @import("bench");
const buffer = @import("buffer");
const rpc_line_reader = @import("rpc_line_reader");
const server_mod = @import("server");
const sys = @import("sys");

const hooks = server_mod.fuzz_hooks;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "server", argv);
    defer runner.deinit();

    // 1. Broadcast queue microbenchmark: enqueue 512 x 1 KiB frames, then drain all 512 via takeQueuedWrite.
    // Directly exposes O(N^2) orderedRemove(0) vs O(1) ring queue behavior!
    {
        const socks = try sys.socketPair();
        defer sys.close(socks[1]);
        const conn = try hooks.createConnection(allocator, io, socks[0]);
        defer hooks.releaseConnection(conn);

        var frame: [1024]u8 = @splat('q');
        frame[1023] = '\n';

        const QueueCtx = struct {
            allocator: std.mem.Allocator,
            conn: @TypeOf(conn),
            frame: []const u8,
            count: usize,
        };
        try runner.run("clientConn_broadcast_queue_512x1KiB", .{
            .bytes_per_op = 512 * frame.len,
            .min_sample_ns = 20 * std.time.ns_per_ms,
        }, QueueCtx{
            .allocator = allocator,
            .conn = conn,
            .frame = &frame,
            .count = 512,
        }, struct {
            fn f(ctx: QueueCtx) !void {
                for (0..ctx.count) |_| {
                    try hooks.enqueueBroadcast(ctx.conn, ctx.frame);
                }
                for (0..ctx.count) |_| {
                    const owned = hooks.takeQueuedWrite(ctx.conn).?;
                    bench.doNotOptimize(owned.ptr);
                    ctx.allocator.free(owned);
                }
            }
        }.f);
    }

    // 2. Live UNIX-socket Server RPC & throughput benchmarks.
    {
        const socket_path = try tempSocketPath(allocator, io);
        defer allocator.free(socket_path);
        defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

        var srv = try server_mod.Server.init(allocator, io, socket_path, 0);
        const RunCtx = struct {
            server: *server_mod.Server,
            fn run(self: *@This()) void {
                self.server.run() catch {};
            }
        };
        var run_ctx: RunCtx = .{ .server = &srv };
        const server_thread = try std.Thread.spawn(.{}, RunCtx.run, .{&run_ctx});
        defer {
            srv.running.store(false, .seq_cst);
            server_thread.join();
            srv.deinit();
        }

        // Wait until listener accepts connections.
        const client_fd = try connectWithWait(io, socket_path);
        defer sys.close(client_fd);
        var reader: rpc_line_reader.LineReader = .{};

        // 2a. daemon.ping round-trip latency over persistent UNIX socket.
        const PingCtx = struct {
            allocator: std.mem.Allocator,
            fd: sys.fd_t,
            reader: *rpc_line_reader.LineReader,
        };
        try runner.run("rpc_daemon_ping_roundtrip", .{}, PingCtx{
            .allocator = allocator,
            .fd = client_fd,
            .reader = &reader,
        }, struct {
            fn f(ctx: PingCtx) !void {
                try sys.sendAll(ctx.fd, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\",\"params\":{}}\n");
                const line = try ctx.reader.readLineAlloc(ctx.allocator, ctx.fd, 1024 * 1024);
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);

        // Create a live session with a full 10 MiB scrollback buffer for capture, attach, send, snapshot benchmarks.
        const create_req =
            "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"session.create\",\"params\":{\"id\":\"bench\",\"shell\":\"/bin/sh\",\"command\":\"exec sleep 60\",\"rows\":40,\"cols\":120}}\n";
        try sys.sendAll(client_fd, create_req);
        const create_resp = try readResponseById(allocator, &reader, client_fd, 10);
        defer allocator.free(create_resp);
        const pane_id = try extractStringField(allocator, create_resp, "id");
        defer allocator.free(pane_id);

        // Fill pane scrollback to 10 MiB.
        const fill_chunk = try allocator.alloc(u8, 64 * 1024);
        defer allocator.free(fill_chunk);
        for (fill_chunk, 0..) |*b, i| {
            b.* = if ((i + 1) % 80 == 0) '\n' else 'A' + @as(u8, @intCast(i % 26));
        }
        if (srv.manager.find(pane_id)) |native_sess| {
            defer native_sess.release();
            native_sess.mutex.lockUncancelable(io);
            for (0..180) |_| native_sess.scrollback.append(fill_chunk);
            native_sess.mutex.unlock(io);
        }

        // 2b. mux.snapshot over UNIX socket.
        try runner.run("rpc_mux_snapshot_roundtrip", .{}, PingCtx{
            .allocator = allocator,
            .fd = client_fd,
            .reader = &reader,
        }, struct {
            fn f(ctx: PingCtx) !void {
                try sys.sendAll(ctx.fd, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"mux.snapshot\",\"params\":{}}\n");
                const line = try readResponseById(ctx.allocator, ctx.reader, ctx.fd, 11);
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);

        // 2c. session.capture (50 lines from 10 MiB scrollback) over UNIX socket.
        const cap_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"session.capture\",\"params\":{{\"sessionId\":\"{s}\",\"lines\":50}}}}\n",
            .{pane_id},
        );
        defer allocator.free(cap_req);

        const RpcReqCtx = struct {
            allocator: std.mem.Allocator,
            fd: sys.fd_t,
            reader: *rpc_line_reader.LineReader,
            req: []const u8,
            id: i64,
        };
        try runner.run("rpc_session_capture_50_from_10MiB", .{
            .bytes_per_op = 50 * 80,
            .min_sample_ns = 30 * std.time.ns_per_ms,
        }, RpcReqCtx{
            .allocator = allocator,
            .fd = client_fd,
            .reader = &reader,
            .req = cap_req,
            .id = 12,
        }, struct {
            fn f(ctx: RpcReqCtx) !void {
                try sys.sendAll(ctx.fd, ctx.req);
                const line = try readResponseById(ctx.allocator, ctx.reader, ctx.fd, ctx.id);
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);

        // 2d. client.attach + 256 KiB replay (from 10 MiB scrollback!) + client.detach over UNIX socket.
        const attach_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"client.attach\",\"params\":{{\"paneId\":\"{s}\",\"rows\":40,\"cols\":120}}}}\n",
            .{pane_id},
        );
        defer allocator.free(attach_req);

        try runner.run("rpc_client_attach_replay_256KiB_from_10MiB", .{
            .bytes_per_op = 256 * 1024,
            .min_sample_ns = 30 * std.time.ns_per_ms,
        }, RpcReqCtx{
            .allocator = allocator,
            .fd = client_fd,
            .reader = &reader,
            .req = attach_req,
            .id = 13,
        }, struct {
            fn f(ctx: RpcReqCtx) !void {
                try sys.sendAll(ctx.fd, ctx.req);
                const resp = try readResponseById(ctx.allocator, ctx.reader, ctx.fd, ctx.id);
                defer ctx.allocator.free(resp);
                const cid = try extractStringField(ctx.allocator, resp, "clientId");
                defer ctx.allocator.free(cid);
                const detach_req = try std.fmt.allocPrint(
                    ctx.allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"client.detach\",\"params\":{{\"clientId\":\"{s}\"}}}}\n",
                    .{cid},
                );
                defer ctx.allocator.free(detach_req);
                try sys.sendAll(ctx.fd, detach_req);
                const dresp = try readResponseById(ctx.allocator, ctx.reader, ctx.fd, 14);
                bench.doNotOptimize(dresp.ptr);
                ctx.allocator.free(dresp);
            }
        }.f);

        // 2e. session.send raw base64 input round-trip over UNIX socket.
        const send_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"{s}\",\"dataBase64\":\"aGVsbG8=\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(send_req);
        try runner.run("rpc_session_send_keystroke_roundtrip", .{}, RpcReqCtx{
            .allocator = allocator,
            .fd = client_fd,
            .reader = &reader,
            .req = send_req,
            .id = 15,
        }, struct {
            fn f(ctx: RpcReqCtx) !void {
                try sys.sendAll(ctx.fd, ctx.req);
                const line = try readResponseById(ctx.allocator, ctx.reader, ctx.fd, ctx.id);
                bench.doNotOptimize(line.ptr);
                ctx.allocator.free(line);
            }
        }.f);

        // Terminate the idle sleep session before running broadcast throughput test.
        const term_req = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"session.terminate\",\"params\":{{\"sessionId\":\"{s}\"}}}}\n",
            .{pane_id},
        );
        defer allocator.free(term_req);
        try sys.sendAll(client_fd, term_req);
        const term_resp = try readResponseById(allocator, &reader, client_fd, 16);
        allocator.free(term_resp);

        // 2f. End-to-end PTY output -> daemon -> JSON-RPC pane_output fanout to 4 concurrent clients (2 MiB raw PTY output).
        const FanoutCtx = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            socket_path: []const u8,
            clients: usize,
            raw_bytes: usize,
        };
        try runner.run("e2e_pty_fanout_4_clients_2MiB", .{
            .bytes_per_op = 4 * 2 * 1024 * 1024,
            .samples = 3,
            .fixed_iters = 1,
        }, FanoutCtx{
            .allocator = allocator,
            .io = io,
            .socket_path = socket_path,
            .clients = 4,
            .raw_bytes = 2 * 1024 * 1024,
        }, struct {
            const ClientDrainer = struct {
                allocator: std.mem.Allocator,
                fd: sys.fd_t,
                target_raw_bytes: usize,
                received_b64_bytes: usize = 0,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

                fn run(self: *@This()) void {
                    defer self.done.store(true, .release);
                    var rdr: rpc_line_reader.LineReader = .{};
                    // Base64 expands 3 -> 4 bytes.
                    const target_b64 = (self.target_raw_bytes * 4) / 3;
                    while (self.received_b64_bytes < target_b64) {
                        const line = rdr.readLineAlloc(self.allocator, self.fd, 1024 * 1024) catch return;
                        defer self.allocator.free(line);
                        if (std.mem.indexOf(u8, line, "\"pane_output\"") != null) {
                            if (std.mem.indexOf(u8, line, "\"data_base64\":\"")) |pos| {
                                const start = pos + "\"data_base64\":\"".len;
                                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| {
                                    self.received_b64_bytes += end - start;
                                }
                            }
                        } else if (std.mem.indexOf(u8, line, "\"session_exited\"") != null) {
                            return;
                        }
                    }
                }
            };

            fn f(ctx: FanoutCtx) !void {
                var fds: [4]sys.fd_t = undefined;
                var drainers: [4]ClientDrainer = undefined;
                var threads: [4]std.Thread = undefined;
                for (0..ctx.clients) |i| {
                    fds[i] = try connectWithWait(ctx.io, ctx.socket_path);
                    drainers[i] = .{
                        .allocator = ctx.allocator,
                        .fd = fds[i],
                        .target_raw_bytes = ctx.raw_bytes,
                    };
                    threads[i] = try std.Thread.spawn(.{}, ClientDrainer.run, .{&drainers[i]});
                }
                defer {
                    for (0..ctx.clients) |i| sys.close(fds[i]);
                }

                // Trigger a 2 MiB producer on the server.
                const ctrl = try connectWithWait(ctx.io, ctx.socket_path);
                defer sys.close(ctrl);
                var ctrl_reader: rpc_line_reader.LineReader = .{};
                try sys.sendAll(
                    ctrl,
                    "{\"jsonrpc\":\"2.0\",\"id\":200,\"method\":\"session.create\",\"params\":{\"id\":\"fanout\",\"shell\":\"/bin/sh\",\"command\":\"dd if=/dev/zero bs=65536 count=32 2>/dev/null\",\"scrollbackBytes\":65536}}\n",
                );
                const resp = try readResponseById(ctx.allocator, &ctrl_reader, ctrl, 200);
                defer ctx.allocator.free(resp);

                for (0..ctx.clients) |i| threads[i].join();
                var total: usize = 0;
                for (0..ctx.clients) |i| total += drainers[i].received_b64_bytes;
                bench.doNotOptimize(total);
            }
        }.f);
    }

    try runner.finish();
}

fn tempSocketPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var seed: [8]u8 = undefined;
    io.random(&seed);
    const nonce = std.mem.readInt(u64, &seed, .little);
    const root = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => "/private/tmp",
        else => "/tmp",
    };
    return std.fmt.allocPrint(allocator, "{s}/zmx-bench-{x:0>16}.sock", .{ root, nonce });
}

fn connectWithWait(io: std.Io, path: []const u8) !sys.fd_t {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (true) {
        if (sys.connectUnix(path)) |fd| return fd else |err| {
            if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return err;
            io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
    }
}

fn readResponseById(
    allocator: std.mem.Allocator,
    reader: *rpc_line_reader.LineReader,
    fd: sys.fd_t,
    expected_id: i64,
) ![]u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"id\":{d}", .{expected_id});
    while (true) {
        const line = try reader.readLineAlloc(allocator, fd, 1024 * 1024);
        if (std.mem.indexOf(u8, line, needle) != null) return line;
        allocator.free(line);
    }
}

fn extractStringField(allocator: std.mem.Allocator, json_line: []const u8, field: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_line, .{});
    defer parsed.deinit();
    const res = parsed.value.object.get("result") orelse return error.MissingResult;
    const val = res.object.get(field) orelse return error.MissingField;
    if (val != .string) return error.ExpectedString;
    return allocator.dupe(u8, val.string);
}
