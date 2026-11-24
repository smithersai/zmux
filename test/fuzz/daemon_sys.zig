const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const daemon = zmux.daemon;
const daemon_hooks = daemon.fuzz_hooks;
const socket_path = zmux.internal.socket_path;
const server = zmux.server;
const sys = zmux.sys;

/// `socket_path.GetEnv` over fuzzer-chosen values; the same resolver
/// `zmux-connect` calls with the process environment.
const FuzzEnv = struct {
    threadlocal var zmux_socket: ?[]const u8 = null;
    threadlocal var smithers_socket: ?[]const u8 = null;
    threadlocal var xdg_runtime_dir: ?[]const u8 = null;
    threadlocal var home: ?[]const u8 = null;

    fn get(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "ZMUX_SOCKET")) return zmux_socket;
        if (std.mem.eql(u8, name, "SMITHERS_SESSION_SOCKET")) return smithers_socket;
        if (std.mem.eql(u8, name, "XDG_RUNTIME_DIR")) return xdg_runtime_dir;
        if (std.mem.eql(u8, name, "HOME")) return home;
        return null;
    }
};

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
    FuzzEnv.zmux_socket = zmux_sock;
    FuzzEnv.smithers_socket = smithers_sock;
    FuzzEnv.xdg_runtime_dir = xdg;
    FuzzEnv.home = home;

    // Differential parity invariant: `zmuxd` and `zmux-connect` MUST ALWAYS
    // resolve the exact same default socket path (or the same error) for
    // every environment. Both now go through `socket_path.resolve`; the
    // daemon wraps it with its own env plumbing.
    const d_result = daemon_hooks.socketPathFromEnvFn(allocator, zmux_sock, smithers_sock, xdg, home);
    defer if (d_result) |p| allocator.free(p) else |_| {};
    const c_result = socket_path.resolve(allocator, null, FuzzEnv.get);
    defer if (c_result) |p| allocator.free(p) else |_| {};

    // `resolve` is exactly `resolveUnvalidated` followed by `validate`.
    const raw_result = socket_path.resolveUnvalidated(allocator, null, FuzzEnv.get);
    defer if (raw_result) |p| allocator.free(p) else |_| {};

    if (d_result) |d_path| {
        const c_path = try c_result;
        try std.testing.expectEqualSlices(u8, d_path, c_path);
        try std.testing.expectEqualSlices(u8, d_path, try raw_result);
    } else |d_err| {
        try std.testing.expectError(d_err, c_result);
        if (raw_result) |raw| {
            try std.testing.expectError(d_err, socket_path.validate(raw));
        } else |raw_err| try std.testing.expectEqual(d_err, raw_err);
    }

    // Check precedence contract: a nonempty $ZMUX_SOCKET wins, made absolute.
    if (zmux_sock) |v| {
        if (v.len > 0) {
            if (socket_path.absolutize(allocator, v)) |abs| {
                defer allocator.free(abs);
                try std.testing.expectEqualStrings(abs, try raw_result);
            } else |err| try std.testing.expectError(err, raw_result);
        }
    }

    const path = raw_result catch return;
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(path));

    // Check validateSocketPath, socketPathTooLongMessage, pidPath, and sys.UnixAddress parity.
    if (daemon_hooks.validateSocketPathFn(path)) |_| {
        try std.testing.expect(path.len <= server.max_socket_path_len);
        const addr = try sys.UnixAddress.init(path);
        try std.testing.expectEqualSlices(u8, path, addr.sockaddr.path[0..path.len]);
        try std.testing.expectEqual(@as(u8, 0), addr.sockaddr.path[path.len]);
    } else |err| {
        if (err == error.SocketPathTooLong) {
            try std.testing.expect(path.len > server.max_socket_path_len);
            try std.testing.expectError(error.NameTooLong, sys.UnixAddress.init(path));
        }
    }

    var msg_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const msg = daemon_hooks.socketPathTooLongMessageFn(&msg_buf, path);
    try std.testing.expect(msg.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), msg[msg.len - 1]);

    const pid_p = try daemon_hooks.pidPathFn(allocator, path);
    defer allocator.free(pid_p);
    try std.testing.expect(std.mem.startsWith(u8, pid_p, path));
    try std.testing.expect(std.mem.endsWith(u8, pid_p, ".pid"));

    // OOM safety across both path resolvers and pidPath
    const fail_idx = smith.valueRangeAtMost(u8, 0, 4);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (daemon_hooks.socketPathFromEnvFn(fa, zmux_sock, smithers_sock, xdg, home)) |p| fa.free(p) else |_| {}
    if (socket_path.resolve(fa, null, FuzzEnv.get)) |p| fa.free(p) else |_| {}
    if (daemon_hooks.pidPathFn(fa, path)) |p| fa.free(p) else |_| {}
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
