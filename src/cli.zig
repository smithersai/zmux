//! `zmux`: unified ergonomic CLI binary for session/pane management, interactive
//! attach (auto-spawning `zmuxd` by default), built-in zero-dependency MCP stdio
//! server (`zmux mcp`), resilient `zmux ssh` remote attach, and `zmux doctor`.

const std = @import("std");
const assert = std.debug.assert;
const connect_terminal = @import("connect/terminal.zig");
const sys = @import("sys.zig");

/// Zero-allocation CLI argument parser for all `zmux` subcommands and flags.
pub const args = @import("cli/args.zig");
/// Usage text, version reporting, and terminal-safe diagnostics.
pub const help = @import("cli/help.zig");
/// Authenticated UNIX-socket JSON-RPC 2.0 client and detached `zmuxd` spawner.
pub const rpc = @import("cli/rpc.zig");
/// Management and agent verbs (`new`, `ls`, `run`, `send`, `screen`, `wait`, ...).
pub const verbs = @import("cli/verbs.zig");
/// Streaming helpers (`events`, `capture --follow`, `send --stdin`, aligned tables).
pub const stream = @import("cli/stream.zig");
/// Interactive attach loop with raw-mode restoration, `--readonly`, and `--replay`.
pub const attach = @import("cli/attach.zig");
/// Built-in zero-dependency Model Context Protocol (MCP) stdio server.
pub const mcp = @import("cli/mcp.zig");
/// Remote SSH tunnel attach with auto-reconnect and `resumeFromOffset` recovery.
pub const ssh = @import("cli/ssh.zig");
/// Actionable environment and live-daemon diagnostics (`zmux doctor`).
pub const doctor = @import("cli/doctor.zig");

/// Re-exported top-level CLI subcommand enum.
pub const Command = args.Command;
/// Re-exported parsed CLI argument structure.
pub const ParsedArgs = args.ParsedArgs;
/// Re-exported CLI argument parser function.
pub const parseArgs = args.parse;
/// Re-exported pure single-line MCP JSON-RPC dispatcher.
pub const handleMcpLine = mcp.handleMcpLine;
/// Re-exported deterministic SSH argv builder.
pub const buildSshArgs = ssh.buildSshArgs;
/// Re-exported `zmux doctor` report structure.
pub const DoctorReport = doctor.DoctorReport;

/// Panic handler that restores terminal state before delegating to the default panic.
pub const panic = std.debug.FullPanic(cliPanic);

fn cliPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    connect_terminal.leaveTerminal();
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Entry point of `zmux`: exits 2 on usage errors, 1 on runtime failures, 0 on success.
pub fn main(init: std.process.Init) void {
    defer connect_terminal.reportRestoreFailure();
    runMain(init) catch |err| {
        connect_terminal.reportRestoreFailure();
        switch (err) {
            error.InvalidArguments => std.process.exit(2),
            error.ReportedFailure, error.RpcError => {},
            else => help.printDiagnostic(init.io, "{s}", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
}

fn runMain(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var failure: args.ParseFailure = .{ .err = error.UnknownFlag };
    const parsed = args.parse(argv, &failure) catch {
        return reportParseFailure(io, failure);
    };
    return dispatch(allocator, io, parsed);
}

/// Dispatch one parsed `zmux` command.
pub fn dispatch(allocator: std.mem.Allocator, io: std.Io, parsed: args.ParsedArgs) !void {
    assert(parsed.ssh_opt_len <= args.max_ssh_opts);
    switch (parsed.command) {
        .help => try help.printUsage(io),
        .version => try help.printVersion(io),
        .attach => try attach.run(allocator, io, parsed),
        .ssh => try ssh.run(allocator, io, parsed),
        .mcp => try mcp.run(allocator, io, parsed.socket_path, parsed.spawn_daemon),
        .doctor => try doctor.run(allocator, io, parsed.socket_path, parsed.json, 1),
        .daemon => try execDaemon(allocator, io, parsed.command_args),
        .new,
        .ls,
        .run,
        .send,
        .screen,
        .capture,
        .wait,
        .signal,
        .split,
        .close,
        .kill,
        .rename,
        .shutdown,
        .events,
        .record,
        => try verbs.run(allocator, io, parsed, 1),
    }
}

/// Locate sibling `zmuxd` (or `smithers-session-daemon`) and replace this process via `execve`.
pub fn execDaemon(allocator: std.mem.Allocator, io: std.Io, extra_args: []const []const u8) !void {
    const self_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse ".";
    const daemon_path = (try rpc.findDaemonBinary(allocator, io, self_dir)) orelse {
        return help.diagnostic(io, "could not find zmuxd next to {f} or on PATH", .{help.escaped(self_path)});
    };
    defer allocator.free(daemon_path);

    const z_args = try buildDaemonExecArgv(allocator, daemon_path, extra_args);
    defer freeSentinelArgv(allocator, z_args);
    const c_argv = try allocator.allocSentinel(?[*:0]const u8, z_args.len, null);
    defer allocator.free(c_argv);
    for (z_args, 0..) |item, idx| c_argv[idx] = item.ptr;

    assert(c_argv.len == extra_args.len + 1);
    const err = sys.execvpeZ(z_args[0].ptr, c_argv.ptr, sys.currentEnviron());
    return help.diagnostic(io, "failed to exec {f}: {s}", .{ help.escaped(daemon_path), @errorName(err) });
}

/// Build the NUL-terminated argv array `[daemon_path, extra_args...]` for `zmux daemon`.
pub fn buildDaemonExecArgv(
    allocator: std.mem.Allocator,
    daemon_path: []const u8,
    extra_args: []const []const u8,
) ![][:0]u8 {
    assert(daemon_path.len > 0);
    const out = try allocator.alloc([:0]u8, extra_args.len + 1);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    out[0] = try allocator.dupeSentinel(u8, daemon_path, 0);
    filled = 1;
    for (extra_args, 0..) |arg, idx| {
        out[idx + 1] = try allocator.dupeSentinel(u8, arg, 0);
        filled += 1;
    }
    assert(filled == out.len);
    return out;
}

/// Free a slice of NUL-terminated strings allocated by `buildDaemonExecArgv`.
pub fn freeSentinelArgv(allocator: std.mem.Allocator, argv: [][:0]u8) void {
    for (argv) |item| allocator.free(item);
    allocator.free(argv);
}

fn reportParseFailure(io: std.Io, failure: args.ParseFailure) error{InvalidArguments} {
    const tok = help.escaped(failure.arg orelse "");
    return switch (failure.err) {
        error.MissingValue => help.fail(io, "missing value for {f}", .{tok}),
        error.InvalidValue => help.fail(io, "invalid value: {f}", .{tok}),
        error.UnknownFlag => help.fail(io, "unknown flag: {f}", .{tok}),
        error.UnexpectedArgument => help.fail(io, "unexpected argument: {f}", .{tok}),
        error.MissingArgument => help.fail(io, "missing required {f}", .{tok}),
        error.TooManySshOptions => help.fail(io, "too many --ssh-opt flags (max {d})", .{args.max_ssh_opts}),
    };
}

test "buildDaemonExecArgv prepends daemon path and forwards remaining args" {
    const alloc = std.testing.allocator;
    const argv = try buildDaemonExecArgv(alloc, "/usr/local/bin/zmuxd", &.{ "--socket", "/tmp/z.sock" });
    defer freeSentinelArgv(alloc, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/usr/local/bin/zmuxd", argv[0]);
    try std.testing.expectEqualStrings("--socket", argv[1]);
    try std.testing.expectEqualStrings("/tmp/z.sock", argv[2]);
}

test "top-level cli facade exports all subsystems and parses end-to-end" {
    const p = try parseArgs(&.{ "zmux", "mcp", "--no-spawn", "--socket", "/tmp/m.sock" }, null);
    try std.testing.expectEqual(Command.mcp, p.command);
    try std.testing.expect(!p.spawn_daemon);
    try std.testing.expectEqualStrings("/tmp/m.sock", p.socket_path.?);
    try std.testing.expect(std.mem.indexOf(u8, help.usageText(), "zmux mcp") == null);
    try std.testing.expect(std.mem.indexOf(u8, help.usageText(), "mcp") != null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("cli/args.zig");
    _ = @import("cli/args_sub.zig");
    _ = @import("cli/help.zig");
    _ = @import("cli/rpc.zig");
    _ = @import("cli/verbs.zig");
    _ = @import("cli/stream.zig");
    _ = @import("cli/attach.zig");
    _ = @import("cli/mcp.zig");
    _ = @import("cli/mcp_tools.zig");
    _ = @import("cli/ssh.zig");
    _ = @import("cli/doctor.zig");
}
