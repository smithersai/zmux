//! Command-line parsing, usage text and stderr diagnostics for `zmux-connect`.

const std = @import("std");
const assert = std.debug.assert;
const log = @import("../log.zig");
const wire = @import("wire.zig");

const default_detach_key = wire.default_detach_key;
const RpcError = wire.RpcError;

/// Options accepted by `zmux-connect [attach] <session_id>`.
pub const ParsedAttachArgs = struct {
    session_id: ?[]const u8 = null,
    explicit_socket_path: ?[]const u8 = null,
    spawn_daemon: bool = false,
    auto_create: bool = true,
    create_command: ?[]const u8 = null,
    show_version: bool = false,
    show_help: bool = false,
    detach_key: ?u8 = default_detach_key,
};

/// Every way `parseAttachArgs` can reject a command line.
pub const ParseAttachArgsError = error{
    MissingSocketValue,
    MissingCommandValue,
    MissingDetachKeyValue,
    InvalidDetachKeyValue,
    UnknownFlag,
    UnexpectedArgument,
};

/// Detail for a `parseAttachArgs` failure: the error and offending argument.
pub const ParseAttachArgsFailure = struct {
    err: ParseAttachArgsError,
    arg: ?[]const u8 = null,
};

/// Parse attach-mode `argv` (program name at index 0). On error, `failure`
/// (when given) receives the details needed for a usage message.
pub fn parseAttachArgs(
    argv: []const []const u8,
    failure: ?*ParseAttachArgsFailure,
) ParseAttachArgsError!ParsedAttachArgs {
    var parsed: ParsedAttachArgs = .{};
    var options = true;
    var explicit_attach = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (options and std.mem.eql(u8, a, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, a, "attach") and parsed.session_id == null and !explicit_attach) {
            explicit_attach = true;
        } else if (options and std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingSocketValue };
                return error.MissingSocketValue;
            }
            parsed.explicit_socket_path = argv[i];
        } else if (options and std.mem.eql(u8, a, "--spawn-daemon")) {
            parsed.spawn_daemon = true;
        } else if (options and std.mem.eql(u8, a, "--no-create")) {
            parsed.auto_create = false;
        } else if (options and std.mem.eql(u8, a, "--command")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingCommandValue };
                return error.MissingCommandValue;
            }
            parsed.create_command = argv[i];
        } else if (options and std.mem.eql(u8, a, "--detach-key")) {
            i += 1;
            if (i >= argv.len) {
                if (failure) |f| f.* = .{ .err = error.MissingDetachKeyValue };
                return error.MissingDetachKeyValue;
            }
            parsed.detach_key = parseDetachKey(argv[i]) catch {
                if (failure) |f| f.* = .{ .err = error.InvalidDetachKeyValue, .arg = argv[i] };
                return error.InvalidDetachKeyValue;
            };
        } else if (options and (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V"))) {
            parsed.show_version = true;
        } else if (options and (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h"))) {
            parsed.show_help = true;
            return parsed;
        } else if (options and a.len > 0 and a[0] == '-') {
            if (failure) |f| f.* = .{ .err = error.UnknownFlag, .arg = a };
            return error.UnknownFlag;
        } else if (parsed.session_id == null) {
            parsed.session_id = a;
        } else {
            if (failure) |f| f.* = .{ .err = error.UnexpectedArgument, .arg = a };
            return error.UnexpectedArgument;
        }
    }
    // `--help` returns early, so a completed scan never requests help.
    assert(!parsed.show_help);
    assert(i == argv.len or argv.len == 0);
    return parsed;
}

/// Parse a `--detach-key` value: `ctrl-<key>` or `none`.
pub fn parseDetachKey(spec: []const u8) !?u8 {
    if (std.ascii.eqlIgnoreCase(spec, "none")) return null;
    if (spec.len == 6 and std.ascii.eqlIgnoreCase(spec[0..5], "ctrl-")) {
        const byte = controlByte(spec[5]) orelse return error.InvalidDetachKey;
        assert(byte >= 0x01 and byte < 0x20);
        return byte;
    }
    return error.InvalidDetachKey;
}

/// Map a key name to its ASCII control byte: letters => C-a..C-z (0x01..0x1A),
/// and backslash => 0x1C so the default Ctrl-\ chord is expressible.
pub fn controlByte(key: u8) ?u8 {
    if (std.ascii.isAlphabetic(key)) {
        const byte = std.ascii.toUpper(key) - 'A' + 1;
        assert(byte >= 0x01 and byte <= 0x1A);
        return byte;
    }
    if (key == '\\') return 0x1C;
    return null;
}

/// A management verb.
pub const Verb = enum { list, kill, rename, shutdown };

/// The verb spelled by `token`, if any.
pub fn parseVerb(token: []const u8) ?Verb {
    if (std.mem.eql(u8, token, "ls")) return .list;
    if (std.mem.eql(u8, token, "kill")) return .kill;
    if (std.mem.eql(u8, token, "rename")) return .rename;
    if (std.mem.eql(u8, token, "shutdown")) return .shutdown;
    return null;
}

/// The command-line spelling of `verb`.
pub fn verbName(verb: Verb) []const u8 {
    return switch (verb) {
        .list => "ls",
        .kill => "kill",
        .rename => "rename",
        .shutdown => "shutdown",
    };
}

/// Arguments of a management verb (`ls`, `kill`, `rename`, `shutdown`).
pub const ParsedVerbArgs = struct {
    target: ?[]const u8 = null,
    new_name: ?[]const u8 = null,
    json: bool = false,
    explicit_socket: ?[]const u8 = null,
    show_help: bool = false,
};

/// Every way `parseVerbArgs` can reject a verb's arguments.
pub const ParseVerbArgsError = error{
    MissingSocketValue,
    UnknownFlag,
    UnexpectedArgument,
    MissingTarget,
    MissingNewName,
};

/// Detail for a `parseVerbArgs` failure: the error and offending argument.
pub const ParseVerbArgsFailure = struct {
    err: ParseVerbArgsError,
    arg: ?[]const u8 = null,
};

/// Parse the arguments after `verb`. On error, `failure` (when given)
/// receives the details needed for a usage message.
pub fn parseVerbArgs(
    verb: Verb,
    rest: []const []const u8,
    failure: ?*ParseVerbArgsFailure,
) ParseVerbArgsError!ParsedVerbArgs {
    var parsed: ParsedVerbArgs = .{};
    const needs_target = (verb == .kill or verb == .rename);
    const needs_new_name = (verb == .rename);

    var options = true;
    var positionals: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (options and std.mem.eql(u8, a, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, a, "--socket")) {
            i += 1;
            if (i >= rest.len) {
                if (failure) |f| f.* = .{ .err = error.MissingSocketValue };
                return error.MissingSocketValue;
            }
            parsed.explicit_socket = rest[i];
        } else if (options and std.mem.eql(u8, a, "--json")) {
            parsed.json = true;
        } else if (options and (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h"))) {
            parsed.show_help = true;
            return parsed;
        } else if (options and a.len > 0 and a[0] == '-') {
            if (failure) |f| f.* = .{ .err = error.UnknownFlag, .arg = a };
            return error.UnknownFlag;
        } else if (positionals == 0 and needs_target) {
            parsed.target = a;
            positionals += 1;
        } else if (positionals == 1 and needs_new_name) {
            assert(parsed.target != null);
            parsed.new_name = a;
            positionals += 1;
        } else {
            if (failure) |f| f.* = .{ .err = error.UnexpectedArgument, .arg = a };
            return error.UnexpectedArgument;
        }
    }

    if (needs_target and parsed.target == null) {
        if (failure) |f| f.* = .{ .err = error.MissingTarget };
        return error.MissingTarget;
    }
    if (needs_new_name and parsed.new_name == null) {
        if (failure) |f| f.* = .{ .err = error.MissingNewName };
        return error.MissingNewName;
    }
    assert(!parsed.show_help and positionals <= 2);
    assert(parsed.target != null or !needs_target);
    assert(parsed.new_name != null or !needs_new_name);
    return parsed;
}

/// Formats bytes with terminal controls escaped as `\\xNN`.
pub const Escaped = struct {
    bytes: []const u8,

    pub fn format(self: Escaped, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        while (i < self.bytes.len) {
            const byte = self.bytes[i];
            // Preserve printable UTF-8, including continuation bytes that
            // would otherwise look like standalone C1 controls.
            const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
            assert(len >= 1 and len <= 4);
            const codepoint = if (len > 1 and i + len <= self.bytes.len)
                std.unicode.utf8Decode(self.bytes[i..][0..len]) catch null
            else
                null;
            if (codepoint) |cp| {
                if (cp >= 0x80 and cp <= 0x9f)
                    try writer.print("\\x{x:0>2}", .{cp})
                else
                    try writer.writeAll(self.bytes[i..][0..len]);
                i += len;
            } else {
                if (byte < 0x20 or (byte >= 0x7f and byte <= 0x9f))
                    try writer.print("\\x{x:0>2}", .{byte})
                else
                    try writer.writeByte(byte);
                i += 1;
            }
        }
        assert(i == self.bytes.len);
    }
};

/// Wrap `bytes` for escaped formatting.
pub fn escaped(bytes: []const u8) Escaped {
    return .{ .bytes = bytes };
}

/// Print the RPC error message and return `error.RpcError`.
pub fn reportRpcError(io: std.Io, err: RpcError) error{RpcError} {
    printDiagnostic(io, "{f}", .{escaped(err.message)});
    return error.RpcError;
}

/// Print a diagnostic and return `error.ReportedFailure`.
pub fn diagnostic(io: std.Io, comptime fmt: []const u8, args: anytype) error{ReportedFailure} {
    printDiagnostic(io, fmt, args);
    return error.ReportedFailure;
}

/// Print `zmux-connect: <message>` to stderr.
pub fn printDiagnostic(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    writeStderr(io, "zmux-connect: " ++ fmt ++ "\n", args);
}

/// Write one best-effort message to stderr. A failed write has nowhere better
/// to go, so it is logged at debug level and otherwise ignored.
pub fn writeStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch |err| return log.debug("stderr_write_failed", .{ .err = err });
    w.interface.flush() catch |err| log.debug("stderr_write_failed", .{ .err = err });
}

/// Write `bytes` to stderr.
pub fn stderrWrite(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}

/// Print a usage error and return `error.InvalidArguments`.
pub fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) error{InvalidArguments} {
    writeStderr(io, "zmux-connect: " ++ fmt ++ "\nTry 'zmux-connect --help' for usage.\n", args);
    return error.InvalidArguments;
}

/// Print the usage text to stdout.
pub fn printUsage(io: std.Io) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(
        \\Usage: zmux-connect [--socket PATH] [attach] <session_id> [--socket PATH] [--spawn-daemon]
        \\                    [--no-create] [--command CMD] [--detach-key KEY]
        \\       zmux-connect <verb> [args] [--socket PATH] [--json]
        \\       smithers-session-connect ... (same interface)
        \\
        \\Attach (default): if <session_id> is not an existing pane id or session
        \\name, a new session with that name is created and then attached.
        \\  --socket PATH      path to the daemon's unix socket
        \\  --                 end options (e.g. zmux-connect -- ls to attach to ls)
        \\  --spawn-daemon     start a daemon if none is running
        \\  --no-create        require an existing session (do not create)
        \\  --command CMD       shell command to run in a newly created session
        \\  --detach-key KEY    detach chord: ctrl-<letter> or none to disable
        \\                     (default: ctrl-\, i.e. Ctrl-\ then detach)
        \\
        \\Management verbs (single JSON-RPC call, add --json for the raw frame):
        \\  ls                 list sessions/panes
        \\  kill <session>     terminate a session
        \\  rename <session> <name>   rename a session
        \\  shutdown           stop the daemon
        \\
    );
    try w.interface.flush();
}

test "explicit attach and the options terminator accept reserved session names" {
    const explicit = try parseAttachArgs(&.{ "zmux-connect", "--socket", "sock", "attach", "ls" }, null);
    try std.testing.expectEqualStrings("ls", explicit.session_id.?);
    try std.testing.expectEqualStrings("sock", explicit.explicit_socket_path.?);
    const literal = try parseAttachArgs(&.{ "zmux-connect", "--", "--help" }, null);
    try std.testing.expectEqualStrings("--help", literal.session_id.?);
    try std.testing.expect(!literal.show_help);
}

test "detach key accepts ctrl chords and none" {
    try std.testing.expectEqual(@as(?u8, 1), try parseDetachKey("CTRL-A"));
    try std.testing.expectEqual(@as(?u8, default_detach_key), try parseDetachKey("ctrl-\\"));
    try std.testing.expectEqual(@as(?u8, null), try parseDetachKey("none"));
    try std.testing.expectError(error.InvalidDetachKey, parseDetachKey("ctrl-zebra"));
}
