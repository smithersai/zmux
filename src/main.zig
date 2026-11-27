//! Feature-minimal tmux-style PTY session server for the Smithers App.
//!
//! `zmux` deliberately implements only the app-facing contract: a durable
//! local daemon owns PTY child processes, app/client processes attach and
//! detach over a UNIX socket, and server-owned PTYs keep running with
//! bounded scrollback capture for replay on reattach.

/// Fixed-capacity scrollback ring that keeps each pane's newest output.
pub const buffer = @import("buffer.zig");
/// `libzmux` C99 ABI exports for embedding zmux from C, Swift, Rust, Python, and Go.
pub const c_api = @import("c_api.zig");
/// Unified `zmux` CLI binary, built-in MCP server, SSH attach, and diagnostics.
pub const cli = @import("cli.zig");
/// `zmux-connect` client: attaches a terminal to a daemon session.
pub const connect = @import("connect.zig");
/// `zmuxd` entry point: argument parsing and daemon startup.
pub const daemon = @import("daemon.zig");
/// Foreground process tracking for a PTY's controlling terminal.
pub const foreground = @import("foreground.zig");
/// Session and pane manager shared by the daemon and native embedders.
pub const mux = @import("mux.zig");
/// In-process sessions for embedders that do not run a daemon.
pub const native = @import("native.zig");
/// JSON-RPC wire types and framing for the daemon protocol.
pub const protocol = @import("protocol.zig");
/// PTY allocation and child process spawning.
pub const pty = @import("pty.zig");
/// Cross-platform `kqueue`/`epoll` OS event reactor for zero-poll PTY and PID waits.
pub const reactor = @import("reactor.zig");
/// UNIX-socket daemon server that owns sessions and serves clients.
pub const server = @import("server.zig");
/// POSIX plumbing `std.Io` does not model (raw descriptors, `AF_UNIX`
/// sockets, signals). Exported for the bundled executables and tests; it is
/// not part of the stable embedding API.
pub const sys = @import("sys.zig");
/// Zero-dependency VT100/xterm/OSC virtual terminal state engine.
pub const vt = @import("vt.zig");

/// Internal modules exposed for the repository's own test and fuzz suites;
/// not part of the stable embedding API.
pub const internal = struct {
    pub const log = @import("log.zig");
    pub const rpc_line_reader = @import("rpc_line_reader.zig");
    pub const socket_path = @import("socket_path.zig");
};

/// An in-process PTY session; see `native`.
pub const NativeSession = native.NativeSession;
/// Options for `NativeSession.create`.
pub const NativeSessionOptions = native.NativeSessionOptions;
/// The daemon server; see `server`.
pub const Server = server.Server;
/// The session manager; see `mux`.
pub const SessionManager = mux.Manager;

comptime {
    // A default-sized pane must fit the ring without being clamped.
    @import("std").debug.assert(buffer.default_capacity <= buffer.max_capacity);
    @import("std").debug.assert(protocol.max_json_depth >= 16);
    @import("std").debug.assert(protocol.max_json_nodes >= 1024);
}

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    // Internal modules with their own tests that the public surface above
    // does not re-export.
    _ = @import("log.zig");
    _ = @import("rpc_line_reader.zig");
    _ = @import("sys.zig");
    _ = @import("socket_path.zig");

    // Check the shared declarations even when a particular target does not
    // reach them through a binary entry point.
    std.testing.refAllDecls(protocol);
    std.testing.refAllDecls(internal.rpc_line_reader.LineReader);
    std.testing.refAllDecls(buffer.ScrollbackBuffer);
    std.testing.refAllDecls(foreground.Tracker);
    std.testing.refAllDecls(sys);
    std.testing.refAllDecls(pty.Pty);
    std.testing.refAllDecls(native.NativeSession);
    std.testing.refAllDecls(mux.Manager);
    std.testing.refAllDecls(mux.PaneHandle);
    std.testing.refAllDecls(internal.socket_path);
    std.testing.refAllDecls(vt.Terminal);
    std.testing.refAllDecls(reactor.Reactor);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(c_api);
}

test "advertised top-level modules are exported" {
    const std = @import("std");

    try std.testing.expect(@hasDecl(@This(), "connect"));
    try std.testing.expect(@hasDecl(@This(), "pty"));
    try std.testing.expect(@hasDecl(@This(), "foreground"));
}

test "README library example compiles against the current API" {
    const std = @import("std");
    // Mirrors the README "Library use" snippet and checks the core stateful
    // constructors; taking function addresses forces semantic analysis so a
    // signature change breaks this test.
    const Example = struct {
        fn main(init: std.process.Init) !void {
            var srv = try Server.init(init.gpa, init.io, "/tmp/zmux.sock", 60);
            defer srv.deinit();
            try srv.run();
        }

        fn standalone(allocator: std.mem.Allocator, io: std.Io) !void {
            var manager = SessionManager.init(allocator, io, null);
            defer manager.deinit();
            const session = try NativeSession.create(allocator, io, .{ .id = "work" });
            defer session.release();
        }
    };
    _ = &Example.main;
    _ = &Example.standalone;
}

test "README request and notification examples match the wire types" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const readme = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "README.md", allocator, .limited(256 * 1024));
    defer allocator.free(readme);

    const ping_prefix = "# {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":";
    const ping_start = std.mem.indexOf(u8, readme, ping_prefix) orelse return error.MissingPingExample;
    const ping_line = readme[ping_start + 2 ..];
    const ping_end = std.mem.indexOfScalar(u8, ping_line, '\n') orelse return error.MissingPingExample;
    const Ping = struct { jsonrpc: []const u8, id: u32, result: struct { version: []const u8 } };
    const ping = try std.json.parseFromSlice(Ping, allocator, ping_line[0..ping_end], .{ .ignore_unknown_fields = true });
    defer ping.deinit();
    // The README describes the package release. The release workflow also
    // checks that the package and protocol versions agree before publication.
    const manifest = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "build.zig.zon", allocator, .limited(64 * 1024));
    defer allocator.free(manifest);
    const version_prefix = ".version = \"";
    const version_start = (std.mem.indexOf(u8, manifest, version_prefix) orelse return error.MissingPackageVersion) + version_prefix.len;
    const version_end = std.mem.indexOfScalar(u8, manifest[version_start..], '"') orelse return error.MissingPackageVersion;
    try std.testing.expectEqualStrings(manifest[version_start..][0..version_end], ping.value.result.version);

    var examples = std.mem.splitSequence(u8, readme, "```json\n");
    _ = examples.next();
    const request_example = examples.next() orelse return error.MissingRequestExample;
    const request_end = std.mem.indexOf(u8, request_example, "```") orelse return error.UnclosedExample;
    const Request = struct {
        jsonrpc: []const u8,
        id: u32,
        method: []const u8,
        params: struct { id: []const u8, rows: u16, cols: u16, command: []const u8 },
    };
    const request = try std.json.parseFromSlice(Request, allocator, request_example[0..request_end], .{});
    defer request.deinit();
    try std.testing.expectEqualStrings("2.0", request.value.jsonrpc);
    try std.testing.expectEqualStrings("session.create", request.value.method);
    try std.testing.expectEqualStrings("work", request.value.params.id);
    try std.testing.expectEqual(@as(u16, 40), request.value.params.rows);
    try std.testing.expectEqual(@as(u16, 120), request.value.params.cols);

    const event_example = examples.next() orelse return error.MissingNotificationExample;
    const event_end = std.mem.indexOf(u8, event_example, "```") orelse return error.UnclosedExample;
    const Notification = struct { jsonrpc: []const u8, method: []const u8, params: protocol.PaneOutputParams };
    const event = try std.json.parseFromSlice(Notification, allocator, event_example[0..event_end], .{});
    defer event.deinit();
    try std.testing.expectEqualStrings(protocol.pane_output_method, event.value.method);
    try std.testing.expectEqual(@as(u64, 12), event.value.params.offset);
    try std.testing.expectEqual(@as(u64, 1), event.value.params.generation);
}

test "all top-level public modules are exported" {
    const std = @import("std");
    const names = [_][]const u8{
        "buffer",     "c_api",  "cli",    "connect",  "daemon",
        "foreground", "mux",    "native", "protocol", "pty",
        "reactor",    "server", "sys",    "vt",       "internal",
    };
    inline for (names) |name| {
        try std.testing.expect(@hasDecl(@This(), name));
    }
}

test "internal namespace exports log, rpc_line_reader, and socket_path" {
    const std = @import("std");
    try std.testing.expect(@hasDecl(internal, "log"));
    try std.testing.expect(@hasDecl(internal, "rpc_line_reader"));
    try std.testing.expect(@hasDecl(internal, "socket_path"));
}

test "top-level convenience aliases match module declarations" {
    const std = @import("std");
    try std.testing.expect(NativeSession == native.NativeSession);
    try std.testing.expect(NativeSessionOptions == native.NativeSessionOptions);
    try std.testing.expect(Server == server.Server);
    try std.testing.expect(SessionManager == mux.Manager);
}

test "scrollback default and max capacity bounds are consistent" {
    const std = @import("std");
    try std.testing.expect(buffer.default_capacity > 0);
    try std.testing.expect(buffer.default_capacity <= buffer.max_capacity);
}

test "scrollback ring preserves newest bytes and endOffset via main re-export" {
    const std = @import("std");
    var ring = try buffer.ScrollbackBuffer.init(std.testing.allocator, 8);
    defer ring.deinit();
    ring.append("12345");
    ring.append("67890");
    try std.testing.expectEqual(@as(u64, 10), ring.endOffset());
    const snap = try ring.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("34567890", snap);
}

test "protocol version agrees with build.zig.zon package version" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig.zon",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(manifest);
    const prefix = ".version = \"";
    const start = (std.mem.indexOf(u8, manifest, prefix) orelse return error.MissingVersion) + prefix.len;
    const end = std.mem.indexOfScalar(u8, manifest[start..], '"') orelse return error.MissingVersion;
    try std.testing.expectEqualStrings(manifest[start..][0..end], protocol.version);
}

test "protocol JSON-RPC standard error codes match D2 specification" {
    const std = @import("std");
    try std.testing.expectEqual(@as(i32, -32700), protocol.ErrorCode.parse_error);
    try std.testing.expectEqual(@as(i32, -32600), protocol.ErrorCode.invalid_request);
    try std.testing.expectEqual(@as(i32, -32601), protocol.ErrorCode.method_not_found);
    try std.testing.expectEqual(@as(i32, -32602), protocol.ErrorCode.invalid_params);
    try std.testing.expectEqual(@as(i32, -32603), protocol.ErrorCode.internal_error);
    try std.testing.expectEqual(@as(i32, -32000), protocol.ErrorCode.session_error);
}

test "protocol notification method constants are stable" {
    const std = @import("std");
    try std.testing.expectEqualStrings("pane_output", protocol.pane_output_method);
    try std.testing.expectEqualStrings("foreground_changed", protocol.foreground_changed_method);
    try std.testing.expectEqualStrings("session_exited", protocol.session_exited_method);
    try std.testing.expectEqualStrings("pane_activity", protocol.pane_activity_method);
    try std.testing.expectEqualStrings("pane_bell", protocol.pane_bell_method);
    try std.testing.expectEqualStrings("pane_output_dropped", protocol.pane_output_dropped_method);
    try std.testing.expectEqualStrings("pane_respawned", protocol.pane_respawned_method);
    try std.testing.expectEqualStrings("client_detached", protocol.client_detached_method);
}

test "protocol parseRequest handles valid daemon.ping request" {
    const std = @import("std");
    var req = try protocol.parseRequest(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\"}",
    );
    defer req.deinit();
    try std.testing.expectEqualStrings("daemon.ping", req.method);
    try std.testing.expect(!protocol.isNotification(&req));
}

test "protocol parseRequest rejects batch array" {
    const std = @import("std");
    try std.testing.expectError(
        error.BatchUnsupported,
        protocol.parseRequest(std.testing.allocator, "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.ping\"}]"),
    );
}

test "protocol parseRequest rejects malformed JSON" {
    const std = @import("std");
    try std.testing.expectError(
        error.ParseError,
        protocol.parseRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\""),
    );
}

test "protocol errorCodeFor maps DuplicateSessionName to conflict" {
    const std = @import("std");
    const mapped = protocol.errorCodeFor(error.DuplicateSessionName);
    try std.testing.expectEqual(@as(i32, protocol.ErrorCode.session_error), mapped.code);
    try std.testing.expectEqual(protocol.ErrorKind.conflict, mapped.kind);
}

test "SessionManager initializes empty and cleans up without leaking" {
    const std = @import("std");
    var manager = SessionManager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
}

test "LineReader default state has empty pending buffer and cleans up" {
    const std = @import("std");
    var reader = internal.rpc_line_reader.LineReader{};
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 0), reader.start);
    try std.testing.expectEqual(@as(usize, 0), reader.end);
    try std.testing.expect(!reader.discarding);
}

test "socket path rejects empty input" {
    const std = @import("std");
    try std.testing.expectError(error.EmptySocketPath, internal.socket_path.validate(""));
}

test "socket path accepts short absolute unix socket path" {
    try internal.socket_path.validate("/tmp/zmux-test.sock");
}

test "socket path rejects overlong unix socket path" {
    const std = @import("std");
    var buf: [256]u8 = undefined;
    @memset(&buf, 'a');
    buf[0] = '/';
    try std.testing.expectError(error.SocketPathTooLong, internal.socket_path.validate(&buf));
}

test "log level parsing accepts canonical level names" {
    const std = @import("std");
    try std.testing.expectEqual(internal.log.Level.err, try internal.log.parseLevel("error"));
    try std.testing.expectEqual(internal.log.Level.warn, try internal.log.parseLevel("warn"));
    try std.testing.expectEqual(internal.log.Level.info, try internal.log.parseLevel("info"));
    try std.testing.expectEqual(internal.log.Level.debug, try internal.log.parseLevel("debug"));
}

test "log level parsing rejects unknown level names" {
    const std = @import("std");
    try std.testing.expectError(error.InvalidLogLevel, internal.log.parseLevel("verbose-invalid"));
    try std.testing.expectError(error.InvalidLogLevel, internal.log.parseLevel(""));
}

test "NativeSessionOptions defaults are bounded and non-zero" {
    const std = @import("std");
    const opts = NativeSessionOptions{ .id = "smoke" };
    try std.testing.expectEqualStrings("smoke", opts.id);
    try std.testing.expect(opts.rows > 0);
    try std.testing.expect(opts.cols > 0);
}
