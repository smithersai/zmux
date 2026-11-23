//! Socket path resolution shared by the daemon and the connect client.
//!
//! Owned by T4 (review round 1, §1.11); consumed by T5. Phase 0 lands the
//! contract with today's precedence (`daemon.socketPath` ==
//! `connect.resolveSocketPath`) so both binaries can switch to it.

const std = @import("std");

const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ EmptySocketPath, SocketPathContainsNul, SocketPathTooLong, NoSocketDirectory, CurrentDirUnavailable, OutOfMemory };

pub const GetEnv = *const fn (name: []const u8) ?[]const u8;

/// Precedence: `override` > `$ZMUX_SOCKET` > `$SMITHERS_SESSION_SOCKET` >
/// `$XDG_RUNTIME_DIR/smithers-sessions.sock` > `$HOME/.smithers/sessions.sock`
/// > `/tmp/zmux-<euid>/sessions.sock`. Returns an absolute, validated path.
pub fn resolve(allocator: Allocator, override: ?[]const u8, getenv: GetEnv) Error![]u8 {
    const raw = try resolveRaw(allocator, override, getenv);
    defer allocator.free(raw);
    const path = try absolutize(allocator, raw);
    errdefer allocator.free(path);
    try validate(path);
    return path;
}

fn resolveRaw(allocator: Allocator, override: ?[]const u8, getenv: GetEnv) Error![]u8 {
    if (override) |value| {
        if (value.len == 0) return error.EmptySocketPath;
        return allocator.dupe(u8, value);
    }
    if (nonEmpty(getenv("ZMUX_SOCKET"))) |value| return allocator.dupe(u8, value);
    if (nonEmpty(getenv("SMITHERS_SESSION_SOCKET"))) |value| return allocator.dupe(u8, value);
    if (nonEmpty(getenv("XDG_RUNTIME_DIR"))) |xdg| return std.fs.path.join(allocator, &.{ xdg, "smithers-sessions.sock" });
    if (nonEmpty(getenv("HOME"))) |home| return std.fs.path.join(allocator, &.{ home, ".smithers", "sessions.sock" });
    return std.fmt.allocPrint(allocator, "/tmp/zmux-{d}/sessions.sock", .{sys.geteuid()});
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
}

/// Resolve a relative `path` against the current working directory.
pub fn absolutize(allocator: Allocator, path: []const u8) Error![]u8 {
    if (path.len == 0) return error.EmptySocketPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.SocketPathContainsNul;
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var cwd_buf: [std.posix.PATH_MAX]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.CurrentDirUnavailable;
    const cwd = std.mem.sliceTo(@as([*:0]u8, @ptrCast(cwd_ptr)), 0);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

/// Nonempty, no NUL, absolute, and fits `sockaddr_un.sun_path`.
pub fn validate(path: []const u8) Error!void {
    if (path.len == 0) return error.EmptySocketPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.SocketPathContainsNul;
    if (!std.fs.path.isAbsolute(path)) return error.NoSocketDirectory;
    if (path.len > sys.max_unix_path_len) return error.SocketPathTooLong;
}

/// True when the socket's parent is a daemon-managed directory (which must be
/// 0700): `$HOME/.smithers` or `/tmp/zmux-<euid>`. `$XDG_RUNTIME_DIR` is
/// managed by the OS, and explicit paths belong to the caller.
pub fn isDefaultManaged(path: []const u8, getenv: GetEnv) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    if (nonEmpty(getenv("HOME"))) |home| {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const managed = std.fmt.bufPrint(&buf, "{s}/.smithers", .{std.mem.trimEnd(u8, home, "/")}) catch return false;
        if (std.mem.eql(u8, parent, managed)) return true;
    }
    var buf: [64]u8 = undefined;
    const fallback = std.fmt.bufPrint(&buf, "/tmp/zmux-{d}", .{sys.geteuid()}) catch return false;
    return std.mem.eql(u8, parent, fallback);
}
