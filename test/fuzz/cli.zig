const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const cli = zmux.cli;

fn fuzzCliArgsParser(_: void, smith: *std.testing.Smith) !void {
    const tokens = [_][]const u8{
        "zmux",
        "--socket",
        "/tmp/z.sock",
        "--no-spawn",
        "--json",
        "-V",
        "--version",
        "-h",
        "--help",
        "--",
        "attach",
        "new",
        "ls",
        "run",
        "exec",
        "send",
        "screen",
        "capture",
        "tail",
        "wait",
        "signal",
        "split",
        "close",
        "kill",
        "rename",
        "shutdown",
        "events",
        "record",
        "ssh",
        "mcp",
        "doctor",
        "daemon",
        "--no-create",
        "--command",
        "echo hi",
        "--cwd",
        "/tmp",
        "--rows",
        "40",
        "0",
        "--cols",
        "120",
        "--detach-key",
        "ctrl-a",
        "none",
        "bad",
        "--readonly",
        "--replay",
        "vt",
        "raw",
        "--enter",
        "--key",
        "C-c",
        "--stdin",
        "--format",
        "plain",
        "ansi",
        "cells",
        "json",
        "--scrollback",
        "100",
        "--lines",
        "50",
        "--follow",
        "--pattern",
        "ready",
        "--exit",
        "--idle-ms",
        "250",
        "--command-done",
        "--timeout-ms",
        "5000",
        "-h",
        "-v",
        "--panes",
        "a,b",
        "start",
        "stop",
        "export",
        "status",
        "--out",
        "/tmp/out.cast",
        "--remote-socket",
        "/tmp/r.sock",
        "--ssh-opt",
        "Port=2222",
        "INT",
        "SIGTERM",
        "work",
        "host.local",
        "--unknown",
        "",
    };

    var argv_buf: [14][]const u8 = undefined;
    argv_buf[0] = "zmux";
    var argc: usize = 1;
    while (!smith.eos() and argc < argv_buf.len) : (argc += 1) {
        argv_buf[argc] = tokens[smith.index(tokens.len)];
    }

    var failure: cli.args.ParseFailure = .{ .err = error.UnknownFlag };
    if (cli.args.parse(argv_buf[0..argc], &failure)) |parsed| {
        try std.testing.expect(parsed.ssh_opt_len <= cli.args.max_ssh_opts);
        if (parsed.detach_key) |k| {
            try std.testing.expect((k >= 0x01 and k <= 0x1A) or k == 0x1C);
        }
        if (parsed.rows) |r| try std.testing.expect(r >= 1);
        if (parsed.cols) |c| try std.testing.expect(c >= 1);
        if (parsed.command == .signal and !parsed.show_help) {
            const sig = parsed.second_arg.?;
            try std.testing.expect(std.mem.startsWith(u8, sig, "SIG"));
        }
    } else |err| {
        try std.testing.expectEqual(err, failure.err);
    }

    var raw_buf: [64]u8 = undefined;
    const raw = corpus.drawBytes(smith, &raw_buf);
    if (cli.args.normalizeSignal(raw)) |sig| {
        try std.testing.expect(std.mem.startsWith(u8, sig, "SIG"));
    }
    _ = cli.args.matchCommand(raw);
}

fn fuzzMcpDispatcherAndOom(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var buf: [512]u8 = undefined;
    const line = corpus.drawBytes(smith, &buf);

    // Nonexistent socket + spawn_daemon=false ensures fuzzing never launches zmuxd.
    const opts: cli.mcp.ServerOptions = .{
        .socket_path = "/tmp/zmux-fuzz-nonexistent-mcp.sock",
        .spawn_daemon = false,
    };

    if (try cli.mcp.handleMcpLineWithOpts(allocator, io, opts, line)) |reply| {
        defer allocator.free(reply);
        try std.testing.expect(reply.len > 0 and reply[reply.len - 1] == '\n');
        var obj = try corpus.parseSingleLineJsonObject(allocator, reply);
        defer obj.deinit();
        try std.testing.expectEqualStrings("2.0", obj.value.object.get("jsonrpc").?.string);
    }

    // Fuzz parseToolCall directly on arbitrary parsed JSON values.
    if (std.json.parseFromSlice(std.json.Value, allocator, line, .{})) |parsed| {
        defer parsed.deinit();
        if (cli.mcp.parseToolCall(parsed.value)) |tc| {
            try std.testing.expect(tc.name.len > 0);
            try std.testing.expect(tc.arguments == .null or tc.arguments == .object);
        } else |_| {}
    } else |_| {}

    // OOM safety on MCP dispatch (must free everything on every allocation failure).
    const fail_idx = smith.valueRangeAtMost(u8, 0, 12);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (cli.mcp.handleMcpLineWithOpts(fa, io, opts, line)) |maybe_reply| {
        if (maybe_reply) |r| fa.free(r);
    } else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzSshArgsAndReconnect(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var host_buf: [128]u8 = undefined;
    var local_buf: [128]u8 = undefined;
    var remote_buf: [128]u8 = undefined;
    var opt_buf: [128]u8 = undefined;

    const host = corpus.drawBytes(smith, &host_buf);
    const local_sock = corpus.drawBytes(smith, &local_buf);
    const remote_sock = corpus.drawBytes(smith, &remote_buf);
    const extra_opt = corpus.drawBytes(smith, &opt_buf);

    if (host.len > 0 and host[0] == '-') {
        try std.testing.expectError(error.LeadingDashForbidden, cli.ssh.validateHost(host));
    }

    const cfg: cli.ssh.SshArgsConfig = .{
        .host = host,
        .local_socket = local_sock,
        .remote_socket = remote_sock,
        .extra_opts = if (extra_opt.len > 0) &.{extra_opt} else &.{},
    };
    if (cli.ssh.buildSshArgs(allocator, cfg)) |argv| {
        defer cli.ssh.freeSshArgs(allocator, argv);
        try std.testing.expect(argv.len >= 12);
        try std.testing.expectEqualStrings("ssh", argv[0]);
        // Security invariant: `--` must immediately precede host, and host never starts with `-`.
        try std.testing.expectEqualStrings("--", argv[argv.len - 2]);
        try std.testing.expectEqualStrings(host, argv[argv.len - 1]);
        try std.testing.expect(argv[argv.len - 1][0] != '-');
    } else |_| {}

    if (cli.ssh.buildRemoteBootstrapCmd(allocator, remote_sock)) |cmd| {
        defer allocator.free(cmd);
        try std.testing.expect(std.mem.indexOf(u8, cmd, "zmuxd") != null);
    } else |_| {}

    // OOM safety on SSH argv builder.
    const fail_idx = smith.valueRangeAtMost(u8, 0, 16);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (cli.ssh.buildSshArgs(fa, .{
        .host = "dev@box.internal",
        .local_socket = "/tmp/zmux-ssh/f.sock",
        .remote_socket = "/tmp/zmux-remote.sock",
        .extra_opts = &.{"Port=2222"},
    })) |argv| {
        cli.ssh.freeSshArgs(fa, argv);
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "fuzz: cli argument parser across all verbs and flags" {
    try std.testing.fuzz({}, fuzzCliArgsParser, .{});
}

test "fuzz: cli MCP JSON-RPC dispatcher, tool parser, and OOM safety" {
    try std.testing.fuzz({}, fuzzMcpDispatcherAndOom, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"zmux_list_sessions\",\"arguments\":{}}}"),
            corpus.sliceSeed("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"unknown\",\"arguments\":{}}}"),
            corpus.sliceSeed("{malformed"),
        },
    });
}

test "fuzz: cli SSH argv builder, host injection guard, and OOM safety" {
    try std.testing.fuzz({}, fuzzSshArgsAndReconnect, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .slice = "ops@prod-01" },
                .{ .slice = "/tmp/local.sock" },
                .{ .slice = "/home/ops/.smithers/sessions.sock" },
                .{ .slice = "Port=2222" },
            }),
            corpus.seed(&.{
                .{ .slice = "-oProxyCommand=id" },
                .{ .slice = "/tmp/local.sock" },
                .{ .slice = "/tmp/remote.sock" },
                .{ .slice = "" },
            }),
        },
    });
}
