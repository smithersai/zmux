//! Feature-minimal tmux-style PTY session server for the Smithers App.
//!
//! `zmux` deliberately implements only the app-facing contract: a durable
//! local daemon owns PTY child processes, app/client processes attach and
//! detach over a UNIX socket, and server-owned PTYs keep running with
//! bounded scrollback capture for replay on reattach.

/// Fixed-capacity scrollback ring that keeps each pane's newest output.
pub const buffer = @import("buffer.zig");
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
/// UNIX-socket daemon server that owns sessions and serves clients.
pub const server = @import("server.zig");
/// POSIX plumbing `std.Io` does not model (raw descriptors, `AF_UNIX`
/// sockets, signals). Exported for the bundled executables and tests; it is
/// not part of the stable embedding API.
pub const sys = @import("sys.zig");

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
