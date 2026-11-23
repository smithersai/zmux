//! Feature-minimal tmux-style PTY session server for the Smithers App.
//!
//! `zmux` deliberately implements only the app-facing contract: a durable
//! local daemon owns PTY child processes, app/client processes attach and
//! detach over a UNIX socket, and server-owned PTYs keep running with
//! bounded scrollback capture for replay on reattach.

pub const buffer = @import("buffer.zig");
pub const connect = @import("connect.zig");
pub const daemon = @import("daemon.zig");
pub const foreground = @import("foreground.zig");
pub const mux = @import("mux.zig");
pub const native = @import("native.zig");
pub const protocol = @import("protocol.zig");
pub const pty = @import("pty.zig");
pub const server = @import("server.zig");

pub const NativeSession = native.NativeSession;
pub const NativeSessionOptions = native.NativeSessionOptions;
pub const Server = server.Server;
pub const SessionManager = mux.Manager;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}

test "advertised top-level modules are exported" {
    const std = @import("std");

    try std.testing.expect(@hasDecl(@This(), "connect"));
    try std.testing.expect(@hasDecl(@This(), "pty"));
    try std.testing.expect(@hasDecl(@This(), "foreground"));
}

test "README documents current public wire and lifecycle behavior" {
    const std = @import("std");
    const readme = try std.fs.cwd().readFileAlloc(std.testing.allocator, "README.md", 256 * 1024);
    defer std.testing.allocator.free(readme);

    try std.testing.expect(std.mem.indexOf(u8, readme, "one JSON document per physical line") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session.create\",\"params\":{\"id\":\"work\",\"rows\":40,\"cols\":120,\"command\":\"bash\"}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "\"pid\":12345,\"socketPath\":\"/tmp/zmux.sock\",\"sessions\":0,\"panes\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "\"params\": { \"pane_id\": \"pane-1\", \"data_base64\": \"...base64...\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`pane_activity` | `pane_id`, `last_activity_ms`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`getpeereid(3)` / `LOCAL_PEERCRED`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "manual fork/exec PTY child spawning") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "full comm/argv on macOS and Linux, pid-only fallback on other platforms") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`/proc/<pid>/comm`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`/proc/<pid>/cmdline`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "--log-level <error|warn|info|debug>") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "\"version\":\"" ++ protocol.version ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "zmuxd-linux-arm64.tar.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, ".sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "$ZMUX_SOCKET") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`--idle-seconds 0`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`--spawn-daemon` looks for a sibling `zmuxd`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`<socket>.log`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "`scrollbackBytes`") != null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "LOCAL_PEERPID") == null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "forkpty") == null);
    try std.testing.expect(std.mem.indexOf(u8, readme, "\"session\": \"work\", \"pane\": 0, \"data\"") == null);
}
