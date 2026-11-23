const std = @import("std");
const bench = @import("bench");
const protocol = @import("protocol");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "protocol", argv);
    defer runner.deinit();

    const ping_req = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"daemon.ping\",\"params\":{}}\n";
    const create_req =
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"session.create\",\"params\":{\"id\":\"work\",\"rows\":40,\"cols\":120,\"command\":\"bash\",\"cwd\":\"/tmp\",\"env\":{\"TERM\":\"xterm-256color\",\"COLORTERM\":\"truecolor\",\"LANG\":\"en_US.UTF-8\"}}}\n";

    // Build a realistic 4 KiB base64 session.send request.
    const raw_4k = try allocator.alloc(u8, 4 * 1024);
    defer allocator.free(raw_4k);
    @memset(raw_4k, 'x');
    const b64_4k = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_4k.len));
    defer allocator.free(b64_4k);
    _ = std.base64.standard.Encoder.encode(b64_4k, raw_4k);
    const send_req = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.send\",\"params\":{{\"sessionId\":\"pane-1-deadbeef\",\"dataBase64\":\"{s}\"}}}}\n",
        .{b64_4k},
    );
    defer allocator.free(send_req);

    // Build 8 KiB and 64 KiB base64 payloads for pane_output notification formatting.
    const raw_8k = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(raw_8k);
    @memset(raw_8k, 'y');
    const b64_8k = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_8k.len));
    defer allocator.free(b64_8k);
    _ = std.base64.standard.Encoder.encode(b64_8k, raw_8k);

    const raw_64k = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(raw_64k);
    @memset(raw_64k, 'z');
    const b64_64k = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw_64k.len));
    defer allocator.free(b64_64k);
    _ = std.base64.standard.Encoder.encode(b64_64k, raw_64k);

    const ParseCtx = struct { allocator: std.mem.Allocator, line: []const u8 };
    try runner.run("parseRequest_daemon_ping", .{ .bytes_per_op = ping_req.len }, ParseCtx{ .allocator = allocator, .line = ping_req }, struct {
        fn f(ctx: ParseCtx) !void {
            var req = try protocol.parseRequest(ctx.allocator, ctx.line);
            bench.doNotOptimize(req.method.ptr);
            req.deinit();
        }
    }.f);

    try runner.run("parseRequest_session_create_env", .{ .bytes_per_op = create_req.len }, ParseCtx{ .allocator = allocator, .line = create_req }, struct {
        fn f(ctx: ParseCtx) !void {
            var req = try protocol.parseRequest(ctx.allocator, ctx.line);
            bench.doNotOptimize(req.method.ptr);
            req.deinit();
        }
    }.f);

    try runner.run("parseRequest_session_send_4KiB_b64", .{ .bytes_per_op = send_req.len }, ParseCtx{ .allocator = allocator, .line = send_req }, struct {
        fn f(ctx: ParseCtx) !void {
            var req = try protocol.parseRequest(ctx.allocator, ctx.line);
            bench.doNotOptimize(req.method.ptr);
            req.deinit();
        }
    }.f);

    const AllocCtx = struct { allocator: std.mem.Allocator };
    try runner.run("format_result_daemon_ping", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const out = try protocol.result(ctx.allocator, "42", .{
                .version = protocol.version,
                .pid = @as(i32, 12345),
                .socketPath = "/tmp/zmux.sock",
                .sessions = @as(usize, 4),
                .panes = @as(usize, 12),
            });
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    const RawCtx = struct { allocator: std.mem.Allocator, raw: []const u8 };
    const sample_raw = "{\"sessions\":[{\"id\":\"sess-1\",\"name\":\"work\",\"windows\":[]}],\"clients\":[],\"keyBindings\":[]}";
    try runner.run("format_resultRaw", .{ .bytes_per_op = sample_raw.len }, RawCtx{ .allocator = allocator, .raw = sample_raw }, struct {
        fn f(ctx: RawCtx) !void {
            const out = try protocol.resultRaw(ctx.allocator, "99", ctx.raw);
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    const NotifCtx = struct { allocator: std.mem.Allocator, b64: []const u8 };
    try runner.run("format_notification_pane_output_8KiB", .{ .bytes_per_op = b64_8k.len }, NotifCtx{ .allocator = allocator, .b64 = b64_8k }, struct {
        fn f(ctx: NotifCtx) !void {
            const out = try protocol.notification(ctx.allocator, protocol.pane_output_method, protocol.PaneOutputParams{
                .pane_id = "pane-1-deadbeef",
                .data_base64 = ctx.b64,
            });
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    try runner.run("format_notification_pane_output_64KiB", .{ .bytes_per_op = b64_64k.len }, NotifCtx{ .allocator = allocator, .b64 = b64_64k }, struct {
        fn f(ctx: NotifCtx) !void {
            const out = try protocol.notification(ctx.allocator, protocol.pane_output_method, protocol.PaneOutputParams{
                .pane_id = "pane-1-deadbeef",
                .data_base64 = ctx.b64,
            });
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    try runner.run("format_notification_pane_activity", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const out = try protocol.notification(ctx.allocator, protocol.pane_activity_method, protocol.PaneActivityParams{
                .pane_id = "pane-1-deadbeef",
                .last_activity_ms = 1795397750743,
            });
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    try runner.run("format_notification_foreground_changed", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const out = try protocol.notification(ctx.allocator, protocol.foreground_changed_method, protocol.ForegroundChangedParams{
                .session_id = "pane-1-deadbeef",
                .pid = 4242,
                .comm = "git",
                .argv = &.{ "git", "status", "--short", "--branch" },
            });
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    try runner.run("format_error", .{}, AllocCtx{ .allocator = allocator }, struct {
        fn f(ctx: AllocCtx) !void {
            const out = try protocol.@"error"(ctx.allocator, "7", protocol.ErrorCode.session_error, "PaneNotFound");
            bench.doNotOptimize(out.ptr);
            ctx.allocator.free(out);
        }
    }.f);

    try runner.finish();
}
