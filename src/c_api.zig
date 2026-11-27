//! `libzmux` C99 ABI entry point (`include/zmux.h`).
//!
//! Exports opaque scrollback and authenticated UNIX-socket JSON-RPC client
//! surfaces so C, Swift, Rust, Python, and Go host apps can embed zmux
//! without requiring the Zig compiler at runtime.

const std = @import("std");

const client_impl = @import("c_api/client.zig");
const scrollback_impl = @import("c_api/scrollback.zig");
/// Virtual terminal C99 ABI exports (`zmux_vt_*`).
pub const vt_impl = @import("c_api/vt.zig");
const protocol = @import("protocol.zig");
const socket_path = @import("socket_path.zig");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c_alloc = std.heap.c_allocator;

/// C99 status codes matching `zmux_status_t` in `include/zmux.h`.
/// Non-exhaustive so unknown integer values passed across FFI never panic.
pub const Status = enum(c_int) {
    ok = 0,
    err_invalid_arg = 1,
    err_oom = 2,
    err_io = 3,
    err_timeout = 4,
    err_protocol = 5,
    err_rpc = 6,
    err_path_too_long = 7,
    err_closed = 8,
    err_not_found = 9,
    err_peer_auth = 10,
    _,
};

/// Opaque C scrollback handle (`zmux_scrollback_t`).
pub const ZmuxScrollback = scrollback_impl.Handle;

/// Opaque C JSON-RPC client handle (`zmux_client_t`).
pub const ZmuxClient = client_impl.Handle;

/// Opaque C virtual terminal handle (`zmux_vt_t`).
pub const ZmuxVt = vt_impl.VtHandle;

comptime {
    // Force Zig to emit the C ABI symbols declared in `src/c_api/vt.zig`.
    _ = vt_impl;
}

/// Return the static NUL-terminated zmux wire protocol version string.
pub export fn zmux_version() callconv(.c) [*:0]const u8 {
    assert(protocol.version.len > 0);
    return protocol.version.ptr;
}

/// Return a static NUL-terminated description for `status`.
pub export fn zmux_status_string(status: Status) callconv(.c) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .err_invalid_arg => "invalid argument",
        .err_oom => "out of memory",
        .err_io => "i/o error",
        .err_timeout => "timed out",
        .err_protocol => "protocol error",
        .err_rpc => "rpc error",
        .err_path_too_long => "path too long",
        .err_closed => "connection closed",
        .err_not_found => "not found",
        .err_peer_auth => "peer authentication failed",
        _ => "unknown status",
    };
}

/// Resolve the default zmux UNIX socket path into `buf` (or query length when `buf == null`).
pub export fn zmux_default_socket_path(
    buf: ?[*]u8,
    buf_len: usize,
    out_len: ?*usize,
) callconv(.c) Status {
    return defaultSocketPathWith(c_alloc, socket_path.processEnv, buf, buf_len, out_len);
}

/// Free a string allocated by `libzmux` (`zmux_scrollback_capture_lines`, `zmux_client_*`).
pub export fn zmux_string_free(ptr: ?[*:0]u8) callconv(.c) void {
    scrollback_impl.freeCString(ptr);
}

/// Allocate a new bounded scrollback ring buffer (`NULL` on OOM).
pub export fn zmux_scrollback_new(capacity_bytes: usize) callconv(.c) ?*ZmuxScrollback {
    return scrollback_impl.Handle.create(c_alloc, capacity_bytes) catch null;
}

/// Destroy a scrollback handle allocated with `zmux_scrollback_new`. Safe with `NULL`.
pub export fn zmux_scrollback_free(sb: ?*ZmuxScrollback) callconv(.c) void {
    const handle = sb orelse return;
    handle.destroy();
}

/// Append `len` bytes from `data` into `sb`.
pub export fn zmux_scrollback_append(
    sb: ?*ZmuxScrollback,
    data: ?[*]const u8,
    len: usize,
) callconv(.c) Status {
    const handle = sb orelse return .err_invalid_arg;
    if (len == 0) return .ok;
    const ptr = data orelse return .err_invalid_arg;
    handle.append(ptr[0..len]);
    return .ok;
}

/// Monotonic stream offset one past the newest appended byte (`0` if `sb == NULL`).
pub export fn zmux_scrollback_end_offset(sb: ?*const ZmuxScrollback) callconv(.c) u64 {
    const handle = sb orelse return 0;
    return handle.endOffset();
}

/// Stream offset of the oldest retained byte (`0` if `sb == NULL`).
pub export fn zmux_scrollback_start_offset(sb: ?*const ZmuxScrollback) callconv(.c) u64 {
    const handle = sb orelse return 0;
    return handle.startOffset();
}

/// Capture up to `max_lines` lines (bounded by `max_bytes`, or full capacity if `0`).
pub export fn zmux_scrollback_capture_lines(
    sb: ?*const ZmuxScrollback,
    max_lines: usize,
    max_bytes: usize,
    out_buf: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    const dst = out_buf orelse return .err_invalid_arg;
    dst.* = null;
    if (out_len) |len_ptr| len_ptr.* = 0;

    const handle = sb orelse return .err_invalid_arg;
    const bytes = handle.captureLinesAlloc(c_alloc, max_lines, max_bytes) catch return .err_oom;
    defer c_alloc.free(bytes);

    const cstr = scrollback_impl.allocCString(bytes) orelse return .err_oom;
    assert(cstr[bytes.len] == 0);
    dst.* = cstr;
    if (out_len) |len_ptr| len_ptr.* = bytes.len;
    return .ok;
}

/// Connect to a zmux daemon UNIX socket and verify same-UID peer credentials.
pub export fn zmux_client_connect(
    path: ?[*:0]const u8,
    timeout_ms: u32,
    out: ?*?*ZmuxClient,
) callconv(.c) Status {
    const dst = out orelse return .err_invalid_arg;
    dst.* = null;

    const override: ?[]const u8 = if (path) |p| std.mem.span(p) else null;
    const handle = client_impl.Handle.connect(c_alloc, override, timeout_ms, socket_path.processEnv) catch |err| {
        return mapClientError(err);
    };
    dst.* = handle;
    assert(dst.* != null);
    return .ok;
}

/// Close and destroy a connected client handle. Safe with `NULL`.
pub export fn zmux_client_close(client: ?*ZmuxClient) callconv(.c) void {
    const handle = client orelse return;
    handle.destroy();
}

/// Send a JSON-RPC 2.0 request and return the matching response JSON frame.
pub export fn zmux_client_call_raw(
    client: ?*ZmuxClient,
    method: ?[*:0]const u8,
    params_json: ?[*:0]const u8,
    timeout_ms: u32,
    out_json: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    const dst = out_json orelse return .err_invalid_arg;
    dst.* = null;
    if (out_len) |len_ptr| len_ptr.* = 0;

    const handle = client orelse return .err_invalid_arg;
    const method_ptr = method orelse return .err_invalid_arg;
    const method_slice = std.mem.span(method_ptr);
    if (method_slice.len == 0) return .err_invalid_arg;
    const params_slice: ?[]const u8 = if (params_json) |p| std.mem.span(p) else null;

    const res = handle.callRaw(c_alloc, method_slice, params_slice, timeout_ms) catch |err| {
        return mapClientError(err);
    };
    defer c_alloc.free(res.json);

    const cstr = scrollback_impl.allocCString(res.json) orelse return .err_oom;
    assert(cstr[res.json.len] == 0);
    dst.* = cstr;
    if (out_len) |len_ptr| len_ptr.* = res.json.len;
    return if (res.is_rpc_error) .err_rpc else .ok;
}

/// Convenience wrapper invoking `"daemon.ping"` with empty params `"{}"`.
pub export fn zmux_client_ping(
    client: ?*ZmuxClient,
    timeout_ms: u32,
    out_json: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    return zmux_client_call_raw(client, "daemon.ping", "{}", timeout_ms, out_json, out_len);
}

/// Read the next newline-delimited JSON frame from `client`.
pub export fn zmux_client_read_frame(
    client: ?*ZmuxClient,
    timeout_ms: u32,
    out_json: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) Status {
    const dst = out_json orelse return .err_invalid_arg;
    dst.* = null;
    if (out_len) |len_ptr| len_ptr.* = 0;

    const handle = client orelse return .err_invalid_arg;
    const frame = handle.readFrame(c_alloc, timeout_ms) catch |err| {
        return mapClientError(err);
    };
    defer c_alloc.free(frame);

    const cstr = scrollback_impl.allocCString(frame) orelse return .err_oom;
    assert(cstr[frame.len] == 0);
    dst.* = cstr;
    if (out_len) |len_ptr| len_ptr.* = frame.len;
    return .ok;
}

fn defaultSocketPathWith(
    allocator: Allocator,
    getenv: socket_path.GetEnv,
    buf: ?[*]u8,
    buf_len: usize,
    out_len: ?*usize,
) Status {
    if (buf == null and buf_len > 0) return .err_invalid_arg;
    if (buf == null and out_len == null) return .err_invalid_arg;
    if (out_len) |len_ptr| len_ptr.* = 0;

    const resolved = socket_path.resolve(allocator, null, getenv) catch |err| {
        return switch (err) {
            error.OutOfMemory => .err_oom,
            error.SocketPathTooLong => .err_path_too_long,
            else => .err_io,
        };
    };
    defer allocator.free(resolved);

    if (out_len) |len_ptr| len_ptr.* = resolved.len;
    const dst = buf orelse return .ok;
    if (buf_len < resolved.len + 1) {
        if (buf_len > 0) dst[0] = 0;
        return .err_path_too_long;
    }
    @memcpy(dst[0..resolved.len], resolved);
    dst[resolved.len] = 0;
    assert(dst[resolved.len] == 0);
    return .ok;
}

fn mapClientError(err: client_impl.Error) Status {
    return switch (err) {
        error.InvalidArg => .err_invalid_arg,
        error.OutOfMemory => .err_oom,
        error.Io => .err_io,
        error.Timeout => .err_timeout,
        error.Protocol => .err_protocol,
        error.PathTooLong => .err_path_too_long,
        error.Closed => .err_closed,
        error.NotFound => .err_not_found,
        error.PeerAuth => .err_peer_auth,
    };
}

test {
    _ = scrollback_impl;
    _ = client_impl;
    _ = vt_impl;
}

test "zmux_version matches protocol.version" {
    try std.testing.expectEqualStrings(protocol.version, std.mem.span(zmux_version()));
}

test "zmux_status_string covers all defined codes and unknown integer values" {
    const cases = [_]Status{
        .ok,          .err_invalid_arg, .err_oom,       .err_io,
        .err_timeout, .err_protocol,    .err_rpc,       .err_path_too_long,
        .err_closed,  .err_not_found,   .err_peer_auth,
    };
    for (cases) |code| {
        const text = std.mem.span(zmux_status_string(code));
        try std.testing.expect(text.len > 0);
        try std.testing.expect(!std.mem.eql(u8, text, "unknown status"));
    }
    const bogus: Status = @fromBackingInt(@intCast(999));
    try std.testing.expectEqualStrings("unknown status", std.mem.span(zmux_status_string(bogus)));
}

test "zmux_default_socket_path queries length and writes NUL-terminated path" {
    var needed: usize = 0;
    try std.testing.expectEqual(Status.ok, zmux_default_socket_path(null, 0, &needed));
    try std.testing.expect(needed > 0);

    var buf: [256]u8 = undefined;
    var written: usize = 0;
    try std.testing.expectEqual(Status.ok, zmux_default_socket_path(&buf, buf.len, &written));
    try std.testing.expectEqual(needed, written);
    try std.testing.expectEqual(@as(u8, 0), buf[written]);
    try std.testing.expect(buf[0] == '/');
}

test "zmux_default_socket_path rejects invalid args and undersized buffers" {
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_default_socket_path(null, 0, null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_default_socket_path(null, 16, null));

    var tiny: [4]u8 = @splat('x');
    var needed: usize = 0;
    try std.testing.expectEqual(Status.err_path_too_long, zmux_default_socket_path(&tiny, tiny.len, &needed));
    try std.testing.expect(needed >= tiny.len);
    try std.testing.expectEqual(@as(u8, 0), tiny[0]);
}

test "defaultSocketPathWith propagates OOM cleanly under FailingAllocator" {
    const FakeEnv = struct {
        fn get(name: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, name, "ZMUX_SOCKET")) "/tmp/fake.sock" else null;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var len: usize = 0;
    try std.testing.expectEqual(Status.err_oom, defaultSocketPathWith(failing.allocator(), FakeEnv.get, null, 0, &len));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "zmux_scrollback lifecycle, wrap offsets, and capture_lines" {
    const sb = zmux_scrollback_new(10) orelse return error.OutOfMemory;
    defer zmux_scrollback_free(sb);

    try std.testing.expectEqual(Status.ok, zmux_scrollback_append(sb, "aaa\nbbb\nccc\n", 12));
    try std.testing.expectEqual(@as(u64, 12), zmux_scrollback_end_offset(sb));
    try std.testing.expectEqual(@as(u64, 2), zmux_scrollback_start_offset(sb));

    var out: ?[*:0]u8 = null;
    var out_len: usize = 0;
    try std.testing.expectEqual(Status.ok, zmux_scrollback_capture_lines(sb, 2, 0, &out, &out_len));
    defer zmux_string_free(out);
    try std.testing.expectEqual(@as(usize, 8), out_len);
    try std.testing.expectEqualStrings("bbb\nccc\n", std.mem.span(out.?));
}

test "zmux_scrollback_capture_lines honors explicit max_bytes cap" {
    const sb = zmux_scrollback_new(64) orelse return error.OutOfMemory;
    defer zmux_scrollback_free(sb);

    const payload = "first\nsecond\nthird\n";
    try std.testing.expectEqual(Status.ok, zmux_scrollback_append(sb, payload.ptr, payload.len));

    var out: ?[*:0]u8 = null;
    var out_len: usize = 0;
    try std.testing.expectEqual(Status.ok, zmux_scrollback_capture_lines(sb, 10, 6, &out, &out_len));
    defer zmux_string_free(out);
    try std.testing.expectEqualStrings("third\n", std.mem.span(out.?));
    try std.testing.expectEqual(@as(usize, 6), out_len);
}

test "zmux_scrollback null guards return safe defaults and invalid_arg" {
    zmux_scrollback_free(null);
    zmux_string_free(null);
    try std.testing.expectEqual(@as(u64, 0), zmux_scrollback_end_offset(null));
    try std.testing.expectEqual(@as(u64, 0), zmux_scrollback_start_offset(null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_scrollback_append(null, "a", 1));

    const sb = zmux_scrollback_new(8) orelse return error.OutOfMemory;
    defer zmux_scrollback_free(sb);
    try std.testing.expectEqual(Status.ok, zmux_scrollback_append(sb, null, 0));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_scrollback_append(sb, null, 3));

    var out: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_scrollback_capture_lines(null, 1, 0, &out, null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_scrollback_capture_lines(sb, 1, 0, null, null));
}

test "zmux_client_connect rejects invalid args, missing socket, and overlong path" {
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_connect("/tmp/x.sock", 50, null));

    var client: ?*ZmuxClient = null;
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_connect("", 50, &client));
    try std.testing.expect(client == null);

    try std.testing.expectEqual(
        Status.err_not_found,
        zmux_client_connect("/tmp/zmux-definitely-nonexistent-c-api.sock", 50, &client),
    );
    try std.testing.expect(client == null);

    var too_long: [sys.max_unix_path_len + 8]u8 = @splat('a');
    too_long[0] = '/';
    too_long[too_long.len - 1] = 0;
    try std.testing.expectEqual(
        Status.err_path_too_long,
        zmux_client_connect(@ptrCast(&too_long), 50, &client),
    );
    try std.testing.expect(client == null);
}

test "zmux_client null guards return err_invalid_arg without crashing" {
    zmux_client_close(null);

    var out: ?[*:0]u8 = null;
    var len: usize = 99;
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_ping(null, 50, &out, &len));
    try std.testing.expect(out == null);
    try std.testing.expectEqual(@as(usize, 0), len);

    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_call_raw(null, "m", "{}", 50, &out, null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_read_frame(null, 50, &out, null));
}

test "zmux_client_call_raw validates method and params_json before I/O" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    var out: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_call_raw(client, null, "{}", 50, &out, null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_call_raw(client, "", "{}", 50, &out, null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_call_raw(client, "m", "{bad", 50, &out, null));
    try std.testing.expectEqual(Status.err_invalid_arg, zmux_client_call_raw(client, "m", "{}", 50, null, null));
}

test "zmux_client_ping roundtrips over a socketpair" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    try sys.sendAll(socks[1], "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"version\":\"0.4.0\"}}\n");

    var out: ?[*:0]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(Status.ok, zmux_client_ping(client, 200, &out, &len));
    defer zmux_string_free(out);
    try std.testing.expectEqual(std.mem.span(out.?).len, len);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(out.?), "\"version\":\"0.4.0\"") != null);
}

test "zmux_client_call_raw returns err_rpc while still populating out_json" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    try sys.sendAll(
        socks[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad params\"}}\n",
    );

    var out: ?[*:0]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(Status.err_rpc, zmux_client_call_raw(client, "session.kill", "{}", 200, &out, &len));
    defer zmux_string_free(out);
    try std.testing.expect(out != null);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(out.?), "bad params") != null);
}

test "zmux_client_call_raw returns err_protocol on mismatched response id" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    try sys.sendAll(socks[1], "{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n");

    var out: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.err_protocol, zmux_client_ping(client, 200, &out, null));
    try std.testing.expect(out == null);
}

test "zmux_client_read_frame receives notification and detects timeout and EOF" {
    const socks = try sys.socketPair();
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    var out: ?[*:0]u8 = null;
    var len: usize = 0;
    try std.testing.expectEqual(Status.err_timeout, zmux_client_read_frame(client, 15, &out, &len));
    try std.testing.expect(out == null);

    try sys.sendAll(socks[1], "{\"jsonrpc\":\"2.0\",\"method\":\"pane_activity\"}\n");
    try std.testing.expectEqual(Status.ok, zmux_client_read_frame(client, 200, &out, &len));
    defer zmux_string_free(out);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"pane_activity\"}", std.mem.span(out.?));

    sys.close(socks[1]);
    var eof_out: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.err_closed, zmux_client_read_frame(client, 200, &eof_out, null));
}

test "zmux_client_connect authenticates peer UID and pings live UNIX socket" {
    var path_buf: [128]u8 = undefined;
    const sock_slice = try std.fmt.bufPrint(
        path_buf[0 .. path_buf.len - 1],
        "/tmp/zmux-capi-test-{d}-{d}.sock",
        .{ sys.getpid(), sys.monotonicMs() },
    );
    path_buf[sock_slice.len] = 0;
    const sock_z: [*:0]const u8 = path_buf[0..sock_slice.len :0].ptr;
    _ = std.c.unlink(sock_z);
    defer _ = std.c.unlink(sock_z);

    const addr = try sys.UnixAddress.init(sock_slice);
    const listen_fd = try sys.unixStreamSocket();
    defer sys.close(listen_fd);
    try sys.bind(listen_fd, &addr);
    try sys.listen(listen_fd, 4);

    const ServerThread = struct {
        fd: sys.fd_t,
        fn run(self: @This()) void {
            const conn = sys.accept(self.fd) catch return;
            defer sys.close(conn);
            var buf: [512]u8 = undefined;
            _ = sys.read(conn, &buf) catch return;
            sys.sendAll(conn, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"version\":\"0.4.0\"}}\n") catch return;
        }
    };
    const srv = try std.Thread.spawn(.{}, ServerThread.run, .{ServerThread{ .fd = listen_fd }});
    defer srv.join();

    var client: ?*ZmuxClient = null;
    try std.testing.expectEqual(Status.ok, zmux_client_connect(sock_z, 1000, &client));
    defer zmux_client_close(client);
    try std.testing.expect(client != null);

    var resp: ?[*:0]u8 = null;
    var resp_len: usize = 0;
    try std.testing.expectEqual(Status.ok, zmux_client_ping(client, 1000, &resp, &resp_len));
    defer zmux_string_free(resp);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(resp.?), "\"version\":\"0.4.0\"") != null);
}

test "zmux_scrollback_new clamps zero capacity to one byte" {
    const sb = zmux_scrollback_new(0) orelse return error.OutOfMemory;
    defer zmux_scrollback_free(sb);
    try std.testing.expectEqual(Status.ok, zmux_scrollback_append(sb, "xyz", 3));
    try std.testing.expectEqual(@as(u64, 2), zmux_scrollback_start_offset(sb));
    try std.testing.expectEqual(@as(u64, 3), zmux_scrollback_end_offset(sb));
}

test "zmux_client_call_raw accepts null params and empty array params" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    try sys.sendAll(
        socks[1],
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":1}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":2}\n",
    );
    var out1: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.ok, zmux_client_call_raw(client, "daemon.ping", null, 200, &out1, null));
    defer zmux_string_free(out1);
    var out2: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.ok, zmux_client_call_raw(client, "daemon.ping", "[]", 200, &out2, null));
    defer zmux_string_free(out2);
}

test "zmux_client_call_raw returns err_protocol on invalid JSON reply" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    try sys.sendAll(socks[1], "not-json\n");
    var out: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.err_protocol, zmux_client_ping(client, 200, &out, null));
    try std.testing.expect(out == null);
}

test "zmux_client_call_raw returns err_timeout when peer does not reply" {
    const socks = try sys.socketPair();
    defer sys.close(socks[1]);
    const client = try client_impl.Handle.fromFd(c_alloc, socks[0]);
    defer zmux_client_close(client);

    var out: ?[*:0]u8 = null;
    try std.testing.expectEqual(Status.err_timeout, zmux_client_ping(client, 15, &out, null));
    try std.testing.expect(out == null);
}
