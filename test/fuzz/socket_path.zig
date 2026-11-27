//! Coverage-guided fuzzing of socket path resolution: `resolve` with a fuzzed
//! environment, `absolutize`, `validate`, and `isDefaultManaged`, checked
//! against independent reference rules.

const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const socket_path = zmux.internal.socket_path;
const max_len = zmux.sys.max_unix_path_len;
const Smith = std.testing.Smith;

/// `GetEnv` is a plain function pointer, so the fuzzed environment lives in
/// thread-local state, like `socket_path`'s own `TestEnv`.
const FuzzEnv = struct {
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

/// Bytes that drive the interesting branches: separators, dots, NUL.
const path_weights: []const Smith.Weight = &.{
    .value(u8, '/', 6),
    .value(u8, '.', 6),
    .value(u8, 0, 1),
    .rangeAtMost(u8, 'a', 'z', 4),
    .rangeAtMost(u8, 0x01, 0xff, 1),
};

/// Draw a path biased toward `/`, `.`, and NUL, or one whose length sits
/// within a byte of the `sun_path` limit.
fn drawPath(smith: *Smith, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= max_len + 2);
    if (smith.valueRangeAtMost(u8, 0, 3) != 0) {
        return buf[0..smith.sliceWeightedBytes(buf, path_weights)];
    }
    const len = max_len - 1 + @as(usize, smith.valueRangeAtMost(u8, 0, 2));
    @memset(buf[0..len], 's');
    buf[0] = '/';
    if (smith.value(bool)) buf[len - 1] = '/';
    return buf[0..len];
}

fn referenceValidate(path: []const u8) socket_path.Error!void {
    if (path.len == 0) return error.EmptySocketPath;
    for (path) |byte| if (byte == 0) return error.SocketPathContainsNul;
    if (path[0] != '/' or path[path.len - 1] == '/') return error.NoSocketDirectory;
    if (path.len > max_len) return error.SocketPathTooLong;
}

/// `path` with leading `./` segments (and the slashes after them) removed.
fn referenceStripDotSlash(path: []const u8) []const u8 {
    var rest = path;
    while (rest.len >= 2 and rest[0] == '.' and rest[1] == '/') {
        rest = rest[2..];
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    }
    return rest;
}

fn expectSameResult(expected: socket_path.Error!void, actual: socket_path.Error!void) !void {
    if (expected) |_| {
        try actual;
    } else |expected_err| {
        try std.testing.expectError(expected_err, actual);
    }
}

fn fuzzValidate(_: void, smith: *Smith) !void {
    var buf: [max_len + 64]u8 = undefined;
    const path = drawPath(smith, &buf);
    try expectSameResult(referenceValidate(path), socket_path.validate(path));
}

fn fuzzAbsolutize(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    var buf: [max_len + 64]u8 = undefined;
    const path = drawPath(smith, &buf);

    const result = socket_path.absolutize(allocator, path) catch |err| {
        const stripped = referenceStripDotSlash(path);
        const expected: socket_path.Error = if (path.len == 0)
            error.EmptySocketPath
        else if (std.mem.indexOfScalar(u8, path, 0) != null)
            error.SocketPathContainsNul
        else if (stripped.len == 0 or std.mem.eql(u8, stripped, "."))
            error.EmptySocketPath
        else
            error.CurrentDirUnavailable;
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer allocator.free(result);

    try std.testing.expect(path.len > 0);
    try std.testing.expect(result.len > 0 and result[0] == '/');
    try std.testing.expect(std.mem.indexOfScalar(u8, result, 0) == null);
    if (path[0] == '/') {
        try std.testing.expectEqualStrings(path, result);
        return;
    }
    const stripped = referenceStripDotSlash(path);
    try std.testing.expect(!std.mem.startsWith(u8, stripped, "./"));
    try std.testing.expect(std.mem.endsWith(u8, result, stripped));
    try std.testing.expect(result.len > stripped.len);
    try std.testing.expectEqual(@as(u8, '/'), result[result.len - stripped.len - 1]);
}

/// One fuzzed environment value: unset, empty, or a drawn path.
fn drawEnvValue(smith: *Smith, buf: []u8) ?[]const u8 {
    return switch (smith.valueRangeAtMost(u8, 0, 3)) {
        0 => null,
        1 => "",
        else => drawPath(smith, buf),
    };
}

fn fuzzResolve(_: void, smith: *Smith) !void {
    const allocator = std.testing.allocator;
    defer FuzzEnv.reset();
    var bufs: [5][max_len + 64]u8 = undefined;
    FuzzEnv.zmux_socket = drawEnvValue(smith, &bufs[0]);
    FuzzEnv.smithers_socket = drawEnvValue(smith, &bufs[1]);
    FuzzEnv.xdg_runtime_dir = drawEnvValue(smith, &bufs[2]);
    FuzzEnv.home = drawEnvValue(smith, &bufs[3]);
    const override: ?[]const u8 = if (smith.value(bool)) drawPath(smith, &bufs[4]) else null;

    // `resolve` must equal `resolveUnvalidated` followed by `validate`.
    const unvalidated = socket_path.resolveUnvalidated(allocator, override, FuzzEnv.get) catch |err| {
        try std.testing.expectError(err, socket_path.resolve(allocator, override, FuzzEnv.get));
        return;
    };
    defer allocator.free(unvalidated);
    try std.testing.expect(std.fs.path.isAbsolute(unvalidated));
    try std.testing.expect(std.mem.indexOfScalar(u8, unvalidated, 0) == null);

    const resolved = socket_path.resolve(allocator, override, FuzzEnv.get) catch |err| {
        try std.testing.expectError(err, socket_path.validate(unvalidated));
        return;
    };
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(unvalidated, resolved);
    try referenceValidate(resolved);
    try std.testing.expect(resolved.len <= max_len);

    // An absolute override wins over the whole environment.
    if (override) |value| {
        if (value.len > 0 and value[0] == '/') try std.testing.expectEqualStrings(value, resolved);
    }
}

fn fuzzIsDefaultManaged(_: void, smith: *Smith) !void {
    defer FuzzEnv.reset();
    var home_buf: [256]u8 = undefined;
    var path_buf: [max_len + 64]u8 = undefined;
    const home = drawEnvValue(smith, &home_buf);
    FuzzEnv.home = home;

    // Arbitrary paths never crash, and a managed answer names a managed parent.
    const path = drawPath(smith, &path_buf);
    if (socket_path.isDefaultManaged(path, FuzzEnv.get)) {
        try std.testing.expect(std.mem.indexOf(u8, path, "/.smithers/") != null or
            std.mem.startsWith(u8, path, "/tmp/zmux-"));
    }

    // A file directly in the uid fallback directory is always managed.
    var name_buf: [16]u8 = undefined;
    const name_len = smith.sliceWeightedBytes(name_buf[1..], &.{.rangeAtMost(u8, 'a', 'z', 1)});
    name_buf[0] = 'n';
    const name = name_buf[0 .. name_len + 1];
    var fallback_buf: [64]u8 = undefined;
    const fallback = try std.fmt.bufPrint(&fallback_buf, "/tmp/zmux-{d}/{s}", .{ zmux.sys.geteuid(), name });
    try std.testing.expect(socket_path.isDefaultManaged(fallback, FuzzEnv.get));

    // A file directly in `$HOME/.smithers` is managed for any nonempty HOME.
    const home_value = home orelse return;
    if (home_value.len == 0) return;
    var end = home_value.len;
    while (end > 1 and home_value[end - 1] == '/') end -= 1;
    var managed_buf: [home_buf.len + 32]u8 = undefined;
    const managed = try std.fmt.bufPrint(&managed_buf, "{s}/.smithers/{s}", .{ home_value[0..end], name });
    try std.testing.expect(socket_path.isDefaultManaged(managed, FuzzEnv.get));
}

test "fuzz: socket_path.validate matches the reference rules" {
    try std.testing.fuzz({}, fuzzValidate, .{
        .corpus = &.{
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "/tmp/zmux.sock" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "rel/a.sock" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "/tmp/dir/" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "/a\x00b" } }),
            corpus.seed(&.{ .{ .int = 0 }, .{ .int = 2 }, .{ .int = 0 } }),
            corpus.seed(&.{ .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } }),
        },
    });
}

test "fuzz: socket_path.absolutize joins relative paths and drops leading ./" {
    try std.testing.fuzz({}, fuzzAbsolutize, .{
        .corpus = &.{
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "./a.sock" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = ".//./a.sock" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "./" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "../a.sock" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "/abs.sock" } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .slice = "a\x00" } }),
        },
    });
}

test "fuzz: socket_path.resolve output is absolute and validated under any environment" {
    try std.testing.fuzz({}, fuzzResolve, .{
        .corpus = &.{
            corpus.seed(&.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 } }),
            corpus.seed(&.{
                .{ .int = 1 },
                .{ .int = 1 },
                .{ .int = 2 },
                .{ .int = 1 },
                .{ .slice = "/run/user/7/" },
                .{ .int = 0 },
                .{ .int = 0 },
            }),
            corpus.seed(&.{
                .{ .int = 2 },
                .{ .int = 1 },
                .{ .slice = "./z.sock" },
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .int = 0 },
            }),
        },
    });
}

test "fuzz: socket_path.isDefaultManaged accepts managed parents only" {
    try std.testing.fuzz({}, fuzzIsDefaultManaged, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .int = 2 },
                .{ .int = 1 },
                .{ .slice = "/home/u//" },
                .{ .int = 1 },
                .{ .slice = "/home/u/.smithers/s.sock" },
                .{ .slice = "sock" },
            }),
            corpus.seed(&.{ .{ .int = 0 }, .{ .int = 1 }, .{ .slice = "/tmp/zmux-0/x" }, .{ .slice = "" } }),
        },
    });
}
