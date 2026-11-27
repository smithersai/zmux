//! Socket path resolution shared by the daemon and the connect client.
//!
//! One implementation of the precedence both binaries use (review round 1,
//! §1.11). Every path this module returns is absolute and fits
//! `sockaddr_un.sun_path`, so `Server.init` accepts it unchanged.

const std = @import("std");
const builtin = @import("builtin");

const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Every way resolving or validating a socket path can fail.
pub const Error = error{
    EmptySocketPath,
    SocketPathContainsNul,
    SocketPathTooLong,
    NoSocketDirectory,
    CurrentDirUnavailable,
    OutOfMemory,
};

/// Environment lookup: the value of `name`, or null when unset. A plain
/// function pointer, so tests and fuzzers swap in thread-local fakes.
pub const GetEnv = *const fn (name: []const u8) ?[]const u8;

/// Precedence: `override` > `$ZMUX_SOCKET` > `$SMITHERS_SESSION_SOCKET` >
/// `$XDG_RUNTIME_DIR/smithers-sessions.sock` > `$HOME/.smithers/sessions.sock`
/// > `/tmp/zmux-<euid>/sessions.sock`. Returns an absolute, validated path.
pub fn resolve(allocator: Allocator, override: ?[]const u8, getenv: GetEnv) Error![]u8 {
    const path = try resolveUnvalidated(allocator, override, getenv);
    errdefer allocator.free(path);
    try validate(path);
    assert(path.len <= sys.max_unix_path_len);
    return path;
}

/// `resolve` without the final `validate`: the path is absolute and free of
/// NUL bytes but may exceed `sun_path`. Callers that report the offending
/// path in a "too long" message use this and call `validate` themselves.
pub fn resolveUnvalidated(allocator: Allocator, override: ?[]const u8, getenv: GetEnv) Error![]u8 {
    const raw = try resolveRaw(allocator, override, getenv);
    defer allocator.free(raw);
    const path = try absolutize(allocator, raw);
    assert(std.fs.path.isAbsolute(path));
    return path;
}

fn resolveRaw(allocator: Allocator, override: ?[]const u8, getenv: GetEnv) Error![]u8 {
    if (override) |value| {
        if (value.len == 0) return error.EmptySocketPath;
        return allocator.dupe(u8, value);
    }
    if (nonEmpty(getenv("ZMUX_SOCKET"))) |value| return allocator.dupe(u8, value);
    if (nonEmpty(getenv("SMITHERS_SESSION_SOCKET"))) |value| return allocator.dupe(u8, value);
    if (nonEmpty(getenv("XDG_RUNTIME_DIR"))) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "smithers-sessions.sock" });
    }
    if (nonEmpty(getenv("HOME"))) |home| return std.fs.path.join(allocator, &.{ home, ".smithers", "sessions.sock" });
    return std.fmt.allocPrint(allocator, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid()});
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Resolve a relative `path` against the current working directory (D6).
/// An absolute path is returned unchanged. Leading `./` components are
/// dropped; `..` is left for the kernel to resolve, because resolving it
/// lexically is wrong across symlinks.
pub fn absolutize(allocator: Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0) return error.EmptySocketPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.SocketPathContainsNul;
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    var relative = path;
    while (std.mem.startsWith(u8, relative, "./")) {
        relative = relative[2..];
        while (relative.len > 0 and relative[0] == '/') relative = relative[1..];
    }
    // "." or "./" names the directory itself, which can never be a socket.
    if (relative.len == 0 or std.mem.eql(u8, relative, ".")) return error.EmptySocketPath;
    assert(!std.mem.startsWith(u8, relative, "./"));

    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentDirUnavailable;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_ptr)), 0);
    if (cwd.len == 0 or cwd[0] != '/') return error.CurrentDirUnavailable;
    return std.fs.path.join(allocator, &.{ cwd, relative });
}

/// Nonempty, no NUL, absolute, names a file (no trailing `/`), and fits
/// `sockaddr_un.sun_path`.
pub fn validate(path: []const u8) Error!void {
    if (path.len == 0) return error.EmptySocketPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.SocketPathContainsNul;
    if (!std.fs.path.isAbsolute(path)) return error.NoSocketDirectory;
    if (path[path.len - 1] == '/') return error.NoSocketDirectory;
    if (path.len > sys.max_unix_path_len) return error.SocketPathTooLong;
}

/// True when the socket's parent is a daemon-managed directory (which must be
/// 0700): `$HOME/.smithers` or `/tmp/zmux-<euid>`. `$XDG_RUNTIME_DIR` is
/// managed by the OS, and explicit paths belong to the caller.
pub fn isDefaultManaged(path: []const u8, getenv: GetEnv) bool {
    const parent = trimTrailingSlashes(std.fs.path.dirname(path) orelse return false);
    if (parent.len == 0) return false;
    if (nonEmpty(getenv("HOME"))) |home| {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const managed = std.fmt.bufPrint(&buf, "{s}/.smithers", .{trimTrailingSlashes(home)}) catch return false;
        if (std.mem.eql(u8, parent, managed)) return true;
    }
    var buf: [64]u8 = undefined;
    const fallback = std.fmt.bufPrint(&buf, "/tmp/zmux-{d}", .{sys.geteuid()}) catch return false;
    return std.mem.eql(u8, parent, fallback);
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

/// `GetEnv` backed by the process environment (`getenv(3)`). For callers that
/// hold no `std.process.Environ.Map`, such as `Server.init`.
pub fn processEnv(name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (name.len >= buf.len) return null;
    assert(name.len < buf.len);
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const value = std.c.getenv(buf[0..name.len :0].ptr) orelse return null;
    return std.mem.sliceTo(value, 0);
}

// ---------------------------------------------------------------------------
// Tests

const TestEnv = struct {
    threadlocal var zmux_socket: ?[]const u8 = null;
    threadlocal var smithers_socket: ?[]const u8 = null;
    threadlocal var xdg_runtime_dir: ?[]const u8 = null;
    threadlocal var home: ?[]const u8 = null;

    fn reset() void {
        zmux_socket = null;
        smithers_socket = null;
        xdg_runtime_dir = null;
        home = null;
    }

    fn get(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "ZMUX_SOCKET")) return zmux_socket;
        if (std.mem.eql(u8, name, "SMITHERS_SESSION_SOCKET")) return smithers_socket;
        if (std.mem.eql(u8, name, "XDG_RUNTIME_DIR")) return xdg_runtime_dir;
        if (std.mem.eql(u8, name, "HOME")) return home;
        return null;
    }
};

fn expectResolved(expected: []const u8, override: ?[]const u8) !void {
    const path = try resolve(std.testing.allocator, override, TestEnv.get);
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(expected, path);
}

test "resolve follows override > env > XDG > HOME > uid fallback" {
    defer TestEnv.reset();
    TestEnv.reset();

    var fallback_buf: [64]u8 = undefined;
    const fallback = try std.fmt.bufPrint(&fallback_buf, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid()});
    try expectResolved(fallback, null);

    TestEnv.home = "/home/u";
    try expectResolved("/home/u/.smithers/sessions.sock", null);

    TestEnv.xdg_runtime_dir = "/run/user/7";
    try expectResolved("/run/user/7/smithers-sessions.sock", null);

    TestEnv.smithers_socket = "/s/smithers.sock";
    try expectResolved("/s/smithers.sock", null);

    TestEnv.zmux_socket = "/s/zmux.sock";
    try expectResolved("/s/zmux.sock", null);

    try expectResolved("/s/override.sock", "/s/override.sock");
}

test "resolve skips empty environment values" {
    defer TestEnv.reset();
    TestEnv.reset();
    TestEnv.zmux_socket = "";
    TestEnv.smithers_socket = "";
    TestEnv.xdg_runtime_dir = "";
    TestEnv.home = "/home/u";
    try expectResolved("/home/u/.smithers/sessions.sock", null);
}

test "resolve rejects an empty override and an over-long path" {
    defer TestEnv.reset();
    TestEnv.reset();
    try std.testing.expectError(error.EmptySocketPath, resolve(std.testing.allocator, "", TestEnv.get));

    const too_long: [sys.max_unix_path_len + 1]u8 = @splat('s');
    var path: [sys.max_unix_path_len + 1]u8 = too_long;
    path[0] = '/';
    try std.testing.expectError(error.SocketPathTooLong, resolve(std.testing.allocator, &path, TestEnv.get));

    // resolveUnvalidated still returns it, so a caller can report the path.
    const unvalidated = try resolveUnvalidated(std.testing.allocator, &path, TestEnv.get);
    defer std.testing.allocator.free(unvalidated);
    try std.testing.expectEqualStrings(&path, unvalidated);
}

test "resolve absolutizes a relative override and relative environment value" {
    defer TestEnv.reset();
    TestEnv.reset();

    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.SkipZigTest;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_ptr)), 0);
    // A deep build directory can push the joined path past sun_path.
    if (cwd.len + "/z.sock".len > sys.max_unix_path_len) return error.SkipZigTest;

    const expected = try std.fs.path.join(std.testing.allocator, &.{ cwd, "z.sock" });
    defer std.testing.allocator.free(expected);

    try expectResolved(expected, "./z.sock");
    try expectResolved(expected, "z.sock");
    TestEnv.zmux_socket = "z.sock";
    try expectResolved(expected, null);
}

test "absolutize keeps absolute paths, joins relative ones, and rejects empty or NUL" {
    const allocator = std.testing.allocator;

    const absolute = try absolutize(allocator, "/tmp/a.sock");
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/a.sock", absolute);

    const relative = try absolutize(allocator, "sub/a.sock");
    defer allocator.free(relative);
    try std.testing.expect(std.fs.path.isAbsolute(relative));
    try std.testing.expect(std.mem.endsWith(u8, relative, "/sub/a.sock"));

    const dotted = try absolutize(allocator, ".//./a.sock");
    defer allocator.free(dotted);
    try std.testing.expect(std.mem.endsWith(u8, dotted, "/a.sock"));
    try std.testing.expect(std.mem.indexOf(u8, dotted, "/./") == null);

    // `..` is preserved for the kernel.
    const parent = try absolutize(allocator, "../a.sock");
    defer allocator.free(parent);
    try std.testing.expect(std.mem.endsWith(u8, parent, "/../a.sock"));

    try std.testing.expectError(error.EmptySocketPath, absolutize(allocator, ""));
    try std.testing.expectError(error.EmptySocketPath, absolutize(allocator, "."));
    try std.testing.expectError(error.EmptySocketPath, absolutize(allocator, "./"));
    try std.testing.expectError(error.SocketPathContainsNul, absolutize(allocator, "a\x00b"));
}

test "validate accepts the sun_path limit and rejects malformed paths" {
    var at_limit: [sys.max_unix_path_len]u8 = @splat('s');
    at_limit[0] = '/';
    try validate(&at_limit);
    try validate("/tmp/zmux.sock");

    var too_long: [sys.max_unix_path_len + 1]u8 = @splat('s');
    too_long[0] = '/';
    try std.testing.expectError(error.SocketPathTooLong, validate(&too_long));
    try std.testing.expectError(error.EmptySocketPath, validate(""));
    try std.testing.expectError(error.SocketPathContainsNul, validate("/tmp/a\x00.sock"));
    try std.testing.expectError(error.NoSocketDirectory, validate("relative.sock"));
    try std.testing.expectError(error.NoSocketDirectory, validate("./relative.sock"));
    try std.testing.expectError(error.NoSocketDirectory, validate("/tmp/dir/"));
}

test "isDefaultManaged is true only for HOME/.smithers and /tmp/zmux-<euid>" {
    defer TestEnv.reset();
    TestEnv.reset();

    var fallback_buf: [64]u8 = undefined;
    const fallback = try std.fmt.bufPrint(&fallback_buf, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid()});
    try std.testing.expect(isDefaultManaged(fallback, TestEnv.get));

    var other_uid_buf: [64]u8 = undefined;
    const other_uid = try std.fmt.bufPrint(&other_uid_buf, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid() +% 1});
    try std.testing.expect(!isDefaultManaged(other_uid, TestEnv.get));

    try std.testing.expect(!isDefaultManaged("/home/u/.smithers/sessions.sock", TestEnv.get));
    TestEnv.home = "/home/u/";
    try std.testing.expect(isDefaultManaged("/home/u/.smithers/sessions.sock", TestEnv.get));
    try std.testing.expect(isDefaultManaged("/home/u/.smithers/other.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("/home/u/.smithers/sub/sessions.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("/home/u/sessions.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("/tmp/explicit.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("/run/user/7/smithers-sessions.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("relative.sock", TestEnv.get));
}

test "processEnv reads the process environment" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;
    try std.testing.expect(processEnv("ZMUX_SOCKET_PATH_TEST_SURELY_UNSET_VARIABLE") == null);
    if (std.c.getenv("PATH")) |raw| {
        try std.testing.expectEqualStrings(std.mem.sliceTo(raw, 0), processEnv("PATH").?);
    }
}

test "resolve rejects an override that names only the current directory" {
    try std.testing.expectError(error.EmptySocketPath, resolve(std.testing.allocator, "./", TestEnv.get));
    try std.testing.expectError(error.EmptySocketPath, resolve(std.testing.allocator, ".//.", TestEnv.get));
}

test "resolve rejects NUL bytes in an override and in the environment" {
    defer TestEnv.reset();
    TestEnv.reset();
    try std.testing.expectError(error.SocketPathContainsNul, resolve(std.testing.allocator, "/a\x00b", TestEnv.get));
    TestEnv.zmux_socket = "/tmp/a\x00.sock";
    try std.testing.expectError(error.SocketPathContainsNul, resolve(std.testing.allocator, null, TestEnv.get));
}

test "resolve rejects an override that ends in a slash" {
    try std.testing.expectError(error.NoSocketDirectory, resolve(std.testing.allocator, "/tmp/dir/", TestEnv.get));
}

test "resolve joins XDG_RUNTIME_DIR with a trailing slash without doubling it" {
    defer TestEnv.reset();
    TestEnv.reset();
    TestEnv.xdg_runtime_dir = "/run/user/7/";
    try expectResolved("/run/user/7/smithers-sessions.sock", null);
}

test "resolve prefers SMITHERS_SESSION_SOCKET over XDG when ZMUX_SOCKET is empty" {
    defer TestEnv.reset();
    TestEnv.reset();
    TestEnv.zmux_socket = "";
    TestEnv.smithers_socket = "/s/smithers.sock";
    TestEnv.xdg_runtime_dir = "/run/user/7";
    TestEnv.home = "/home/u";
    try expectResolved("/s/smithers.sock", null);
}

test "resolve rejects a derived XDG path past sun_path" {
    defer TestEnv.reset();
    TestEnv.reset();
    var dir: [sys.max_unix_path_len]u8 = @splat('d');
    dir[0] = '/';
    TestEnv.xdg_runtime_dir = &dir;
    try std.testing.expectError(error.SocketPathTooLong, resolve(std.testing.allocator, null, TestEnv.get));
}

test "resolve accepts an override exactly at the sun_path limit" {
    var at_limit: [sys.max_unix_path_len]u8 = @splat('s');
    at_limit[0] = '/';
    try expectResolved(&at_limit, &at_limit);
}

test "resolve propagates allocation failure at every allocation without leaking" {
    defer TestEnv.reset();
    TestEnv.reset();
    TestEnv.home = "/home/u";
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, resolve(failing.allocator(), null, TestEnv.get));
    }
    var enough = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const path = try resolve(enough.allocator(), null, TestEnv.get);
    defer enough.allocator().free(path);
    try std.testing.expectEqualStrings("/home/u/.smithers/sessions.sock", path);
}

test "absolutize drops only leading ./ segments and keeps inner ones" {
    const allocator = std.testing.allocator;
    const inner = try absolutize(allocator, "a/./b.sock");
    defer allocator.free(inner);
    try std.testing.expect(std.mem.endsWith(u8, inner, "/a/./b.sock"));

    const repeated = try absolutize(allocator, "./././c.sock");
    defer allocator.free(repeated);
    try std.testing.expect(std.mem.endsWith(u8, repeated, "/c.sock"));
    try std.testing.expect(std.mem.indexOf(u8, repeated, "/./") == null);

    try std.testing.expectError(error.EmptySocketPath, absolutize(allocator, ".///"));
    try std.testing.expectError(error.EmptySocketPath, absolutize(allocator, "././."));
}

test "absolutize checks NUL before treating a path as absolute" {
    try std.testing.expectError(error.SocketPathContainsNul, absolutize(std.testing.allocator, "/abs\x00"));
    try std.testing.expectError(error.SocketPathContainsNul, absolutize(std.testing.allocator, "\x00"));
}

test "validate reports errors in a fixed precedence order" {
    try std.testing.expectError(error.SocketPathContainsNul, validate("rel\x00/"));
    try std.testing.expectError(error.NoSocketDirectory, validate("/"));
    try std.testing.expectError(error.NoSocketDirectory, validate("/a//"));

    var long_dir: [sys.max_unix_path_len + 8]u8 = @splat('s');
    long_dir[0] = '/';
    long_dir[long_dir.len - 1] = '/';
    try std.testing.expectError(error.NoSocketDirectory, validate(&long_dir));
}

test "isDefaultManaged ignores an empty HOME and paths with no parent" {
    defer TestEnv.reset();
    TestEnv.reset();
    TestEnv.home = "";
    try std.testing.expect(!isDefaultManaged("/.smithers/sessions.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("/", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("sessions.sock", TestEnv.get));
}

test "isDefaultManaged matches a HOME/.smithers parent with a trailing slash" {
    defer TestEnv.reset();
    TestEnv.reset();
    TestEnv.home = "/home/u";
    try std.testing.expect(isDefaultManaged("/home/u/.smithers//sessions.sock", TestEnv.get));
    try std.testing.expect(!isDefaultManaged("/home/u/.smithersx/sessions.sock", TestEnv.get));
}

test "processEnv returns null for a name that does not fit its buffer" {
    const long_name: [128]u8 = @splat('P');
    try std.testing.expect(processEnv(&long_name) == null);
}
