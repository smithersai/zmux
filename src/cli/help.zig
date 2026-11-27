//! Output, diagnostics, usage text, and terminal-safe escaping for `zmux`.

const std = @import("std");
const assert = std.debug.assert;
const connect_cli = @import("../connect/cli.zig");
const log = @import("../log.zig");
const protocol = @import("../protocol.zig");

/// Formatter that escapes terminal control bytes while preserving UTF-8.
pub const Escaped = connect_cli.Escaped;

/// Wrap `bytes` for escaped formatting in diagnostics and tables.
pub const escaped = connect_cli.escaped;

/// Parse a `--detach-key` spec (`ctrl-<letter>`, `ctrl-\`, or `none`).
pub const parseDetachKey = connect_cli.parseDetachKey;

/// Map a single key character to its ASCII control byte (`0x01..0x1A` or `0x1C`).
pub const controlByte = connect_cli.controlByte;

/// Structured JSON-RPC error payload returned by a zmux daemon.
pub const RpcErrorDetail = struct {
    code: ?i64 = null,
    message: []const u8,
    kind: ?[]const u8 = null,

    /// Return true when this error has `data.kind == kind`.
    pub fn isKind(self: RpcErrorDetail, target_kind: []const u8) bool {
        assert(target_kind.len > 0);
        return std.mem.eql(u8, self.kind orelse return false, target_kind);
    }

    /// Return true when the daemon rejected the method as unknown (`-32601`).
    pub fn isMethodNotFound(self: RpcErrorDetail) bool {
        if (self.code) |c| {
            if (c == protocol.ErrorCode.method_not_found) return true;
        }
        return self.isKind("method_not_found");
    }
};

/// Write one best-effort formatted message to stderr.
pub fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch |err| return log.debug("cli_stderr_failed", .{ .err = err });
    w.interface.flush() catch |err| log.debug("cli_stderr_failed", .{ .err = err });
}

/// Write raw bytes to stderr.
pub fn stderrWrite(io: std.Io, bytes: []const u8) !void {
    assert(bytes.len <= 16 * 1024 * 1024);
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

/// Write raw bytes to stdout.
pub fn stdoutWrite(io: std.Io, bytes: []const u8) !void {
    assert(bytes.len <= 16 * 1024 * 1024);
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

/// Print `zmux: <message>` to stderr.
pub fn printDiagnostic(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    writeStderr(io, "zmux: " ++ fmt ++ "\n", args);
}

/// Print a diagnostic to stderr and return `error.ReportedFailure`.
pub fn diagnostic(io: std.Io, comptime fmt: []const u8, args: anytype) error{ReportedFailure} {
    printDiagnostic(io, fmt, args);
    return error.ReportedFailure;
}

/// Print a usage error to stderr and return `error.InvalidArguments`.
pub fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    writeStderr(io, "zmux: " ++ fmt ++ "\nTry 'zmux --help' for usage.\n", args);
    return error.InvalidArguments;
}

/// Print an escaped RPC error message and return `error.RpcError`.
pub fn reportRpcError(io: std.Io, err: RpcErrorDetail) error{RpcError} {
    assert(err.message.len > 0);
    if (err.kind) |k| {
        printDiagnostic(io, "{f} ({f})", .{ escaped(err.message), escaped(k) });
    } else {
        printDiagnostic(io, "{f}", .{escaped(err.message)});
    }
    return error.RpcError;
}

/// Print the zmux CLI version line to stdout.
pub fn printVersion(io: std.Io) !void {
    const line = "zmux " ++ protocol.version ++ "\n";
    assert(line.len > 5);
    try stdoutWrite(io, line);
}

/// Print top-level zmux CLI usage text to stdout.
pub fn printUsage(io: std.Io) !void {
    const text = usageText();
    assert(text.len > 100);
    try stdoutWrite(io, text);
}

/// Return the static top-level usage string for `zmux --help`.
pub fn usageText() []const u8 {
    return (
        \\Usage: zmux [global flags] <name> [attach flags]
        \\       zmux [global flags] <command> [args]
        \\
        \\Global flags:
        \\  --socket PATH      Daemon UNIX socket path
        \\  --no-spawn         Do not auto-start zmuxd when missing
        \\  --json             Emit raw JSON output
        \\  -V, --version      Print zmux version
        \\  -h, --help         Show this help text
        \\
        \\Interactive commands:
        \\  [attach] <name>    Attach or create session (--no-create, --command CMD,
        \\                     --detach-key KEY, --readonly, --replay raw|vt)
        \\  ssh <host> [name]  Attach over SSH tunnel with auto-reconnect and offset resume
        \\                     (--remote-socket PATH, --ssh-opt OPT, --detach-key KEY, --readonly)
        \\
        \\Session and pane commands:
        \\  new [name]         Create session (--command CMD, --cwd DIR, --rows N, --cols N)
        \\  ls                 List sessions and panes
        \\  run <id> [--] cmd  Execute command in pane (--timeout-ms N)
        \\  exec <id> <cmd>    Alias for run
        \\  send <id> [text]   Send input (--enter, --key KEY, --stdin)
        \\  screen <id>        Read rendered VT screen (--format plain|ansi|cells|json, --scrollback N)
        \\  capture <id>       Capture scrollback (--lines N, --follow)
        \\  tail <id>          Alias for capture
        \\  wait <id>          Wait for condition (--pattern STR, --exit, --idle-ms N,
        \\                     --command-done, --timeout-ms N)
        \\  signal <id> <SIG>  Send signal (INT, TERM, KILL, HUP, STOP, CONT, WINCH, USR1, USR2)
        \\  split <id>         Split pane (-h, -v, --command CMD)
        \\  close <id>         Close pane (falls back to terminate on v0.4.0 daemons)
        \\  kill <id>          Terminate session
        \\  rename <id> <name> Rename session
        \\  events             Stream live NDJSON events (--panes a,b)
        \\  record <id> <act>  Record asciicast v2 (start|stop|export|status, --out FILE)
        \\  shutdown           Stop the local zmuxd daemon
        \\
        \\Integrations and diagnostics:
        \\  mcp                Run built-in stdio Model Context Protocol (MCP) server
        \\  doctor             Inspect socket permissions, daemon health, and binary versions
        \\  daemon [args...]   Exec sibling zmuxd with forwarded arguments
        \\
    );
}

test "RpcErrorDetail identifies method not found by code or kind" {
    const by_code: RpcErrorDetail = .{ .code = -32601, .message = "MethodNotFound" };
    try std.testing.expect(by_code.isMethodNotFound());
    const by_kind: RpcErrorDetail = .{ .code = null, .message = "missing", .kind = "method_not_found" };
    try std.testing.expect(by_kind.isMethodNotFound());
    const other: RpcErrorDetail = .{ .code = -32000, .message = "PaneNotFound", .kind = "not_found" };
    try std.testing.expect(!other.isMethodNotFound());
    try std.testing.expect(other.isKind("not_found"));
}

test "usageText covers core commands and avoids forbidden punctuation" {
    const text = usageText();
    try std.testing.expect(std.mem.indexOf(u8, text, "zmux [global flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ssh <host>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "doctor") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, text, ';'));
}
