const std = @import("std");
const bench = @import("bench");
const cli = @import("cli");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "cli", argv);
    defer runner.deinit();

    // 1. CLI arg parsing: interactive attach with flags.
    const attach_argv = [_][]const u8{
        "zmux",
        "--socket",
        "/tmp/zmux.sock",
        "work",
        "--replay",
        "vt",
        "--detach-key",
        "ctrl-a",
        "--readonly",
    };
    try runner.run("parse_args_attach", .{}, &attach_argv, struct {
        fn f(a: []const []const u8) !void {
            const parsed = try cli.args.parse(a, null);
            bench.doNotOptimize(parsed.detach_key);
        }
    }.f);

    // 2. CLI arg parsing across a realistic mix of management/agent verbs.
    const verb_samples = [_][]const []const u8{
        &.{ "zmux", "new", "work", "--cwd", "/tmp", "--rows", "40", "--cols", "120", "--json" },
        &.{ "zmux", "ls", "--json" },
        &.{ "zmux", "run", "work", "--timeout-ms", "5000", "--", "zig", "build", "test" },
        &.{ "zmux", "send", "work", "echo ok", "--enter" },
        &.{ "zmux", "screen", "work", "--format", "plain", "--scrollback", "50" },
        &.{ "zmux", "wait", "work", "--pattern", "PASS", "--timeout-ms", "15000" },
        &.{ "zmux", "signal", "work", "INT" },
        &.{ "zmux", "ssh", "ops@box", "work", "--ssh-opt", "Port=2222", "--readonly" },
        &.{ "zmux", "mcp", "--no-spawn" },
        &.{ "zmux", "doctor", "--json" },
    };
    try runner.run("parse_args_verbs_mix", .{}, &verb_samples, struct {
        fn f(samples: []const []const []const u8) !void {
            for (samples) |s| {
                const parsed = try cli.args.parse(s, null);
                bench.doNotOptimize(parsed.command);
            }
        }
    }.f);

    // 3. MCP initialize JSON-RPC dispatch.
    const McpCtx = struct { allocator: std.mem.Allocator, io: std.Io, line: []const u8 };
    const init_line =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}";
    try runner.run("mcp_dispatch_initialize", .{ .bytes_per_op = init_line.len }, McpCtx{
        .allocator = allocator,
        .io = io,
        .line = init_line,
    }, struct {
        fn f(ctx: McpCtx) !void {
            const reply = (try cli.mcp.handleMcpLine(ctx.allocator, ctx.io, null, ctx.line)).?;
            bench.doNotOptimize(reply.ptr);
            ctx.allocator.free(reply);
        }
    }.f);

    // 4. MCP tools/list JSON-RPC dispatch (serializes all 9 tool JSON schemas).
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}";
    try runner.run("mcp_dispatch_tools_list", .{ .bytes_per_op = list_line.len }, McpCtx{
        .allocator = allocator,
        .io = io,
        .line = list_line,
    }, struct {
        fn f(ctx: McpCtx) !void {
            const reply = (try cli.mcp.handleMcpLine(ctx.allocator, ctx.io, null, ctx.line)).?;
            bench.doNotOptimize(reply.ptr);
            ctx.allocator.free(reply);
        }
    }.f);

    // 5. SSH hardened argv construction.
    const SshCtx = struct { allocator: std.mem.Allocator, cfg: cli.ssh.SshArgsConfig };
    try runner.run("ssh_build_args", .{}, SshCtx{
        .allocator = allocator,
        .cfg = .{
            .host = "ops@prod-01.internal",
            .local_socket = "/tmp/zmux-ssh-1234/f.sock",
            .remote_socket = "/home/ops/.smithers/sessions.sock",
            .extra_opts = &.{ "Port=2222", "BatchMode=yes" },
        },
    }, struct {
        fn f(ctx: SshCtx) !void {
            const out = try cli.ssh.buildSshArgs(ctx.allocator, ctx.cfg);
            bench.doNotOptimize(out.ptr);
            cli.ssh.freeSshArgs(ctx.allocator, out);
        }
    }.f);

    try runner.finish();
}
