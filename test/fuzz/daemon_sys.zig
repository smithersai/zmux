const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const daemon = zmux.daemon;
const daemon_hooks = daemon.fuzz_hooks;
const connect_hooks = zmux.connect.fuzz_hooks;
const server = zmux.server;
const sys = zmux.sys;

fn fuzzDaemonConnectSocketPathParity(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    var b3: [128]u8 = undefined;
    var b4: [128]u8 = undefined;

    const zmux_sock: ?[]const u8 = if (smith.value(bool)) corpus.drawAsciiSlice(smith, &b1) else null;
    const smithers_sock: ?[]const u8 = if (smith.value(bool)) corpus.drawAsciiSlice(smith, &b2) else null;
    const xdg: ?[]const u8 = if (smith.value(bool)) corpus.drawAsciiSlice(smith, &b3) else null;
    const home: ?[]const u8 = if (smith.value(bool)) corpus.drawAsciiSlice(smith, &b4) else null;

    // Differential parity invariant: `zmuxd` and `zmux-connect` MUST ALWAYS
    // resolve the exact same default socket path for every environment!
    const d_path = try daemon_hooks.socketPathFromEnvFn(allocator, zmux_sock, smithers_sock, xdg, home);
    defer allocator.free(d_path);
    const c_path = try connect_hooks.resolveSocketPathFromEnvFn(allocator, zmux_sock, smithers_sock, xdg, home);
    defer allocator.free(c_path);

    try std.testing.expectEqualSlices(u8, d_path, c_path);
    try std.testing.expect(d_path.len > 0);

    // Check precedence contract.
    if (zmux_sock) |v| {
        if (v.len > 0) try std.testing.expectEqualStrings(v, d_path);
    }

    // Check validateSocketPath, socketPathTooLongMessage, pidPath, and sys.UnixAddress parity.
    if (d_path.len <= server.max_socket_path_len) {
        try daemon_hooks.validateSocketPathFn(d_path);
        const addr = try sys.UnixAddress.init(d_path);
        try std.testing.expectEqualSlices(u8, d_path, addr.sockaddr.path[0..d_path.len]);
        try std.testing.expectEqual(@as(u8, 0), addr.sockaddr.path[d_path.len]);
    } else {
        try std.testing.expectError(error.SocketPathTooLong, daemon_hooks.validateSocketPathFn(d_path));
        try std.testing.expectError(error.NameTooLong, sys.UnixAddress.init(d_path));
    }

    var msg_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const msg = daemon_hooks.socketPathTooLongMessageFn(&msg_buf, d_path);
    try std.testing.expect(msg.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), msg[msg.len - 1]);

    const pid_p = try daemon_hooks.pidPathFn(allocator, d_path);
    defer allocator.free(pid_p);
    try std.testing.expect(std.mem.startsWith(u8, pid_p, d_path));
    try std.testing.expect(std.mem.endsWith(u8, pid_p, ".pid"));

    // OOM safety across both path resolvers and pidPath
    const fail_idx = smith.valueRangeAtMost(u8, 0, 4);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (daemon_hooks.socketPathFromEnvFn(fa, zmux_sock, smithers_sock, xdg, home)) |p| fa.free(p) else |_| {}
    if (connect_hooks.resolveSocketPathFromEnvFn(fa, zmux_sock, smithers_sock, xdg, home)) |p| fa.free(p) else |_| {}
    if (daemon_hooks.pidPathFn(fa, d_path)) |p| fa.free(p) else |_| {}
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzDaemonCliArgs(_: void, smith: *std.testing.Smith) !void {
    const tokens = [_][]const u8{
        "zmuxd",
        "--socket",
        "/tmp/zmux.sock",
        "--idle-seconds",
        "0",
        "3600",
        "-1",
        "9223372036854775807",
        "999999999999999999999",
        "not-a-number",
        "--log-level",
        "error",
        "warn",
        "info",
        "debug",
        "DEBUG",
        "trace",
        "--version",
        "-V",
        "--help",
        "-h",
        "--bogus",
        "",
    };

    var argv_buf: [12][]const u8 = undefined;
    argv_buf[0] = "zmuxd";
    var argc: usize = 1;
    while (!smith.eos() and argc < argv_buf.len) : (argc += 1) {
        argv_buf[argc] = tokens[smith.index(tokens.len)];
    }

    var failure: daemon.ParseArgsFailure = .{ .err = error.UnknownFlag };
    if (daemon_hooks.parseArgsFn(argv_buf[0..argc], &failure)) |_| {
        // Valid parse
    } else |err| {
        try std.testing.expectEqual(err, failure.err);
    }
}

fn fuzzSysUnixAddressAndIo(_: void, smith: *std.testing.Smith) !void {
    var path_buf: [256]u8 = undefined;
    const path = corpus.drawBytes(smith, &path_buf);

    if (path.len <= sys.max_unix_path_len) {
        const addr = try sys.UnixAddress.init(path);
        try std.testing.expectEqualSlices(u8, path, addr.sockaddr.path[0..path.len]);
        try std.testing.expectEqual(@as(u8, 0), addr.sockaddr.path[path.len]);
    } else {
        try std.testing.expectError(error.NameTooLong, sys.UnixAddress.init(path));
    }

    // Round-trip arbitrary binary bytes over a socketPair via sys.sendAll / sys.read.
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    try sys.sendAll(pair[1], path);
    sys.close(pair[1]);

    var read_back: [256]u8 = undefined;
    var got_len: usize = 0;
    while (got_len < path.len) {
        const n = try sys.read(pair[0], read_back[got_len..]);
        if (n == 0) break;
        got_len += n;
    }
    try std.testing.expectEqualSlices(u8, path, read_back[0..got_len]);
    var eof_byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try sys.read(pair[0], &eof_byte));
}

test "fuzz: daemon vs connect socket path parity and path validation" {
    try std.testing.fuzz({}, fuzzDaemonConnectSocketPathParity, .{});
}

test "fuzz: daemon CLI argument parser" {
    try std.testing.fuzz({}, fuzzDaemonCliArgs, .{});
}

test "fuzz: sys.UnixAddress boundaries and socketPair sendAll round-trip" {
    try std.testing.fuzz({}, fuzzSysUnixAddressAndIo, .{});
}
