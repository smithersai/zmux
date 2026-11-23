const std = @import("std");
const bench = @import("bench");
const connect = @import("connect");
const sys = @import("sys");

const hooks = connect.fuzz_hooks;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "connect", argv);
    defer runner.deinit();

    // Open /dev/null as sink fd for output decoding benchmarks (avoids pipe buffer blocking).
    const devnull = try sys.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    defer sys.close(devnull);

    // Prepare 1 KiB, 8 KiB, 64 KiB pane_output JSON-RPC notifications.
    const notif_1k = try makePaneOutputNotif(allocator, "pane-1-deadbeef", 1024);
    defer allocator.free(notif_1k);
    const notif_8k = try makePaneOutputNotif(allocator, "pane-1-deadbeef", 8 * 1024);
    defer allocator.free(notif_8k);
    const notif_64k = try makePaneOutputNotif(allocator, "pane-1-deadbeef", 64 * 1024);
    defer allocator.free(notif_64k);

    const activity_notif = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_activity\",\"params\":{\"pane_id\":\"pane-1-deadbeef\",\"last_activity_ms\":1795397750743}}\n";

    // Prepare 256 KiB attach replay response.
    const replay_raw = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(replay_raw);
    @memset(replay_raw, 'R');
    const replay_b64 = try hooks.b64EncodeFn(allocator, replay_raw);
    defer allocator.free(replay_b64);
    const attach_resp = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"clientId\":\"client-1\",\"sessionId\":\"sess-1\",\"windowId\":\"win-1\",\"paneId\":\"pane-1-deadbeef\",\"rows\":40,\"cols\":120,\"replayBase64\":\"{s}\"}}}}\n",
        .{replay_b64},
    );
    defer allocator.free(attach_resp);

    // 1. handleServerLine (matching pane_output: 1 KiB, 8 KiB, 64 KiB).
    const HandleCtx = struct { allocator: std.mem.Allocator, line: []const u8, pane_id: []const u8, out_fd: sys.fd_t };
    try runner.run("handleServerLine_pane_output_1KiB", .{ .bytes_per_op = 1024 }, HandleCtx{
        .allocator = allocator,
        .line = notif_1k,
        .pane_id = "pane-1-deadbeef",
        .out_fd = devnull,
    }, struct {
        fn f(ctx: HandleCtx) !void {
            const exited = try hooks.handleServerLineFn(ctx.allocator, ctx.line, ctx.pane_id, ctx.out_fd);
            bench.doNotOptimize(exited);
        }
    }.f);

    try runner.run("handleServerLine_pane_output_8KiB", .{ .bytes_per_op = 8 * 1024 }, HandleCtx{
        .allocator = allocator,
        .line = notif_8k,
        .pane_id = "pane-1-deadbeef",
        .out_fd = devnull,
    }, struct {
        fn f(ctx: HandleCtx) !void {
            const exited = try hooks.handleServerLineFn(ctx.allocator, ctx.line, ctx.pane_id, ctx.out_fd);
            bench.doNotOptimize(exited);
        }
    }.f);

    try runner.run("handleServerLine_pane_output_64KiB", .{ .bytes_per_op = 64 * 1024 }, HandleCtx{
        .allocator = allocator,
        .line = notif_64k,
        .pane_id = "pane-1-deadbeef",
        .out_fd = devnull,
    }, struct {
        fn f(ctx: HandleCtx) !void {
            const exited = try hooks.handleServerLineFn(ctx.allocator, ctx.line, ctx.pane_id, ctx.out_fd);
            bench.doNotOptimize(exited);
        }
    }.f);

    try runner.run("handleServerLine_other_pane_8KiB_skip", .{ .bytes_per_op = notif_8k.len }, HandleCtx{
        .allocator = allocator,
        .line = notif_8k,
        .pane_id = "pane-99-other",
        .out_fd = devnull,
    }, struct {
        fn f(ctx: HandleCtx) !void {
            const exited = try hooks.handleServerLineFn(ctx.allocator, ctx.line, ctx.pane_id, ctx.out_fd);
            bench.doNotOptimize(exited);
        }
    }.f);

    try runner.run("handleServerLine_pane_activity_ignore", .{ .bytes_per_op = activity_notif.len }, HandleCtx{
        .allocator = allocator,
        .line = activity_notif,
        .pane_id = "pane-1-deadbeef",
        .out_fd = devnull,
    }, struct {
        fn f(ctx: HandleCtx) !void {
            const exited = try hooks.handleServerLineFn(ctx.allocator, ctx.line, ctx.pane_id, ctx.out_fd);
            bench.doNotOptimize(exited);
        }
    }.f);

    // 2. replayScrollbackFromAttach (256 KiB).
    const ReplayCtx = struct { allocator: std.mem.Allocator, payload: []const u8, out_fd: sys.fd_t };
    try runner.run("replayScrollbackFromAttach_256KiB", .{ .bytes_per_op = 256 * 1024 }, ReplayCtx{
        .allocator = allocator,
        .payload = attach_resp,
        .out_fd = devnull,
    }, struct {
        fn f(ctx: ReplayCtx) !void {
            try hooks.replayScrollbackFromAttachFn(ctx.allocator, ctx.payload, ctx.out_fd);
        }
    }.f);

    // 3. matchesRpcId on notification & matching response.
    const MatchCtx = struct { allocator: std.mem.Allocator, line: []const u8 };
    try runner.run("matchesRpcId_notification_skip_8KiB", .{ .bytes_per_op = notif_8k.len }, MatchCtx{
        .allocator = allocator,
        .line = notif_8k,
    }, struct {
        fn f(ctx: MatchCtx) void {
            bench.doNotOptimize(hooks.matchesRpcIdFn(ctx.allocator, ctx.line, 1));
        }
    }.f);

    // 4. formatSessionList with 32 sessions.
    var list_out: std.Io.Writer.Allocating = .init(allocator);
    defer list_out.deinit();
    try list_out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":[");
    for (0..32) |idx| {
        if (idx > 0) try list_out.writer.writeByte(',');
        try list_out.writer.print(
            "{{\"id\":\"pane-{d}\",\"title\":\"work-{d}\",\"pid\":{d},\"state\":\"running\",\"sessionId\":\"sess-{d}\",\"windowId\":\"win-{d}\",\"paneId\":\"pane-{d}\"}}",
            .{ idx, idx, 1000 + idx, idx, idx, idx },
        );
    }
    try list_out.writer.writeAll("]}\n");
    const session_list_resp = try list_out.toOwnedSlice();
    defer allocator.free(session_list_resp);

    try runner.run("formatSessionList_32_sessions", .{ .bytes_per_op = session_list_resp.len }, MatchCtx{
        .allocator = allocator,
        .line = session_list_resp,
    }, struct {
        fn f(ctx: MatchCtx) !void {
            const out = try hooks.formatSessionListFn(ctx.allocator, ctx.line);
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    // 5. CLI arg & detach-key parsing.
    const sample_argv = [_][]const u8{
        "zmux-connect",
        "work",
        "--socket",
        "/tmp/zmux.sock",
        "--spawn-daemon",
        "--detach-key",
        "ctrl-a",
    };
    try runner.run("parseAttachArgs_cli", .{}, &sample_argv, struct {
        fn f(a: []const []const u8) !void {
            const parsed = try hooks.parseAttachArgsFn(a, null);
            bench.doNotOptimize(parsed.detach_key);
        }
    }.f);

    try runner.finish();
}

fn makePaneOutputNotif(allocator: std.mem.Allocator, pane_id: []const u8, raw_len: usize) ![]u8 {
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    for (raw, 0..) |*b, i| b.* = 'A' + @as(u8, @intCast(i % 26));
    const b64 = try hooks.b64EncodeFn(allocator, raw);
    defer allocator.free(b64);
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{{\"pane_id\":\"{s}\",\"data_base64\":\"{s}\"}}}}\n",
        .{ pane_id, b64 },
    );
}
