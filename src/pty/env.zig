//! Pre-fork string preparation for `Pty.spawn`: the child's `envp` and the
//! `execvp(3)` candidate list, both built before `fork` so the child never
//! allocates.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;
const sys = @import("../sys.zig");
const pty = @import("../pty.zig");

const EnvMode = pty.EnvMode;
const is_darwin = builtin.os.tag.isDarwin();

/// A NULL-terminated array of C strings, some owned and some borrowed.
pub const CStringList = struct {
    owned: std.ArrayList([:0]u8) = .empty,
    ptrs: std.ArrayList(?[*:0]const u8) = .empty,

    /// Free the owned entries and the pointer array.
    pub fn deinit(self: *CStringList, allocator: Allocator) void {
        for (self.owned.items) |entry| allocator.free(entry);
        self.owned.deinit(allocator);
        self.ptrs.deinit(allocator);
    }

    /// Append an entry owned by someone else.
    pub fn appendBorrowed(self: *CStringList, allocator: Allocator, entry: [*:0]const u8) !void {
        try self.ptrs.append(allocator, entry);
    }

    /// Append an entry, taking ownership (also on failure).
    pub fn appendOwned(self: *CStringList, allocator: Allocator, entry: [:0]u8) !void {
        self.owned.append(allocator, entry) catch |err| {
            allocator.free(entry);
            return err;
        };
        try self.ptrs.append(allocator, entry.ptr);
    }

    /// Append the NULL terminator.
    pub fn finish(self: *CStringList, allocator: Allocator) !void {
        try self.ptrs.append(allocator, null);
        assert(self.ptrs.items[self.ptrs.items.len - 1] == null);
    }

    /// Valid after `finish`.
    pub fn list(self: *const CStringList) [*:null]const ?[*:0]const u8 {
        assert(self.ptrs.items.len > 0);
        return @ptrCast(self.ptrs.items.ptr);
    }

    /// Entries without the terminator.
    pub fn entries(self: *const CStringList) []const ?[*:0]const u8 {
        assert(self.ptrs.items.len > 0);
        return self.ptrs.items[0 .. self.ptrs.items.len - 1];
    }
};

/// The `KEY` of a `KEY=VALUE` entry (the whole entry when it has no `=`).
pub fn envKey(entry: []const u8) []const u8 {
    return entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
}

/// Build the child's `envp` before `fork`. `.merge` keeps every `base` entry
/// whose key `supplied` does not set, then appends `supplied`; `.replace`
/// uses `supplied` alone. A later duplicate key in `supplied` wins. In both
/// modes `TERM=xterm-256color` is appended when no `TERM` is present.
///
/// Linear in the number of entries: one key index over `supplied` answers
/// both "does `supplied` set this key" and "is this the last entry for it".
pub fn buildEnv(
    allocator: Allocator,
    base: [*:null]const ?[*:0]const u8,
    supplied_opt: ?[]const []const u8,
    mode: EnvMode,
) !CStringList {
    var env: CStringList = .{};
    errdefer env.deinit(allocator);
    const supplied: []const []const u8 = supplied_opt orelse &.{};
    var has_term = false;

    // Key -> index of its last entry in `supplied`.
    var last_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer last_index.deinit(allocator);
    if (supplied.len > std.math.maxInt(u32)) return error.OutOfMemory;
    try last_index.ensureTotalCapacity(allocator, @intCast(supplied.len));
    for (supplied, 0..) |entry, index| last_index.putAssumeCapacity(envKey(entry), index);

    if (mode == .merge) {
        var index: usize = 0;
        while (base[index]) |entry_z| : (index += 1) {
            const key = envKey(std.mem.sliceTo(entry_z, 0));
            if (last_index.contains(key)) continue;
            if (std.mem.eql(u8, key, "TERM")) has_term = true;
            try env.appendBorrowed(allocator, entry_z);
        }
    }
    for (supplied, 0..) |entry, index| {
        const key = envKey(entry);
        if (last_index.get(key).? != index) continue;
        if (std.mem.eql(u8, key, "TERM")) has_term = true;
        try env.appendOwned(allocator, try allocator.dupeSentinel(u8, entry, 0));
    }
    if (!has_term) try env.appendBorrowed(allocator, pty.default_term_entry.ptr);
    try env.finish(allocator);
    assert(env.owned.items.len <= supplied.len);
    return env;
}

/// Resolve the paths `execvp(3)` would try for `file`, before `fork`: `file`
/// itself when it contains '/', otherwise one candidate per `PATH` component.
/// An empty component means the current directory (POSIX), which for the
/// child is the pane's `cwd`.
pub fn resolveExecCandidates(allocator: Allocator, file: []const u8, path_env: []const u8) !CStringList {
    var candidates: CStringList = .{};
    errdefer candidates.deinit(allocator);

    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        try candidates.appendOwned(allocator, try allocator.dupeSentinel(u8, file, 0));
    } else {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |component| {
            const dir = if (component.len == 0) "." else component;
            if (dir.len + 1 + file.len >= posix.PATH_MAX) continue;
            const candidate = try allocator.allocSentinel(u8, dir.len + 1 + file.len, 0);
            assert(candidate.len < posix.PATH_MAX);
            @memcpy(candidate[0..dir.len], dir);
            candidate[dir.len] = '/';
            @memcpy(candidate[dir.len + 1 ..], file);
            try candidates.appendOwned(allocator, candidate);
        }
    }
    try candidates.finish(allocator);
    return candidates;
}

/// The `PATH` the shell is searched in: the daemon's, or the libc default.
pub fn execPathEnv() []const u8 {
    const value = std.c.getenv("PATH") orelse return sys.default_exec_path;
    return std.mem.sliceTo(value, 0);
}

/// The shell used when `SpawnOptions.shell` is null: `$SHELL`, else a platform default.
pub fn defaultShell() []const u8 {
    // The child inherits the libc environment block (see `buildEnv`), so
    // read SHELL from the same place.
    const env_shell: ?[]const u8 = if (std.c.getenv("SHELL")) |shell_z| std.mem.sliceTo(shell_z, 0) else null;
    return defaultShellFor(env_shell);
}

/// `defaultShell` over an explicit `SHELL` value. Never empty.
pub fn defaultShellFor(env_shell: ?[]const u8) []const u8 {
    if (env_shell) |shell| {
        if (shell.len > 0) return shell;
    }
    return if (is_darwin) "/bin/zsh" else "/bin/sh";
}

// ---------------------------------------------------------------------------
// Tests

test "default shell honours SHELL and falls back to an absolute path" {
    try std.testing.expectEqualStrings("/opt/bin/fish", defaultShellFor("/opt/bin/fish"));
    try std.testing.expectEqualStrings("sh", defaultShellFor("sh"));
    try std.testing.expect(std.mem.startsWith(u8, defaultShellFor(null), "/"));
    try std.testing.expect(std.mem.startsWith(u8, defaultShellFor(""), "/"));
}

test "exec candidates follow PATH order and treat an empty component as cwd" {
    const allocator = std.testing.allocator;
    {
        var candidates = try resolveExecCandidates(allocator, "sh", ":/bin");
        defer candidates.deinit(allocator);
        const entries = candidates.entries();
        try std.testing.expectEqual(@as(usize, 2), entries.len);
        try std.testing.expectEqualStrings("./sh", std.mem.sliceTo(entries[0].?, 0));
        try std.testing.expectEqualStrings("/bin/sh", std.mem.sliceTo(entries[1].?, 0));
        try std.testing.expect(candidates.list()[2] == null);
    }
    {
        var candidates = try resolveExecCandidates(allocator, "sh", "/usr/bin::/bin:");
        defer candidates.deinit(allocator);
        const entries = candidates.entries();
        try std.testing.expectEqual(@as(usize, 4), entries.len);
        try std.testing.expectEqualStrings("/usr/bin/sh", std.mem.sliceTo(entries[0].?, 0));
        try std.testing.expectEqualStrings("./sh", std.mem.sliceTo(entries[1].?, 0));
        try std.testing.expectEqualStrings("/bin/sh", std.mem.sliceTo(entries[2].?, 0));
        try std.testing.expectEqualStrings("./sh", std.mem.sliceTo(entries[3].?, 0));
    }
    {
        // A name containing '/' is used as given, with no PATH search.
        var candidates = try resolveExecCandidates(allocator, "bin/tool", "/usr/bin");
        defer candidates.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), candidates.entries().len);
        try std.testing.expectEqualStrings("bin/tool", std.mem.sliceTo(candidates.entries()[0].?, 0));
    }
    try std.testing.checkAllAllocationFailures(allocator, resolveCandidatesForFailureTest, .{});
}

fn resolveCandidatesForFailureTest(allocator: Allocator) !void {
    var candidates = try resolveExecCandidates(allocator, "sh", "/a:/b::/c");
    candidates.deinit(allocator);
}

fn testEnvHas(env: *const CStringList, expected: []const u8) bool {
    for (env.entries()) |entry| {
        if (std.mem.eql(u8, std.mem.sliceTo(entry.?, 0), expected)) return true;
    }
    return false;
}

test "env merge overrides matching keys and keeps the rest of the base" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z", "FOO=old", "FOOBAR=keep" };

    var env = try buildEnv(allocator, &base, &.{ "FOO=new", "EXTRA=1", "EXTRA=2" }, .merge);
    defer env.deinit(allocator);
    try std.testing.expect(testEnvHas(&env, "PATH=/usr/bin"));
    try std.testing.expect(testEnvHas(&env, "HOME=/home/z"));
    try std.testing.expect(testEnvHas(&env, "FOO=new"));
    try std.testing.expect(!testEnvHas(&env, "FOO=old"));
    // Key matching is exact, not a prefix match.
    try std.testing.expect(testEnvHas(&env, "FOOBAR=keep"));
    // The last duplicate in the supplied entries wins.
    try std.testing.expect(testEnvHas(&env, "EXTRA=2"));
    try std.testing.expect(!testEnvHas(&env, "EXTRA=1"));
    // No TERM anywhere: the default is added exactly once.
    try std.testing.expect(testEnvHas(&env, "TERM=" ++ pty.default_term));
    try std.testing.expectEqual(@as(usize, 6), env.entries().len);
    try std.testing.expect(env.list()[6] == null);
}

test "env merge with no supplied entries is the base plus a default TERM" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z" };
    var env = try buildEnv(allocator, &base, null, .merge);
    defer env.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), env.entries().len);
    try std.testing.expect(testEnvHas(&env, "TERM=" ++ pty.default_term));
}

test "env keeps an existing TERM from the base or the supplied entries" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "TERM=screen", "PATH=/usr/bin" };
    {
        var env = try buildEnv(allocator, &base, null, .merge);
        defer env.deinit(allocator);
        try std.testing.expect(testEnvHas(&env, "TERM=screen"));
        try std.testing.expectEqual(@as(usize, 2), env.entries().len);
    }
    {
        var env = try buildEnv(allocator, &base, &.{"TERM=dumb"}, .merge);
        defer env.deinit(allocator);
        try std.testing.expect(testEnvHas(&env, "TERM=dumb"));
        try std.testing.expect(!testEnvHas(&env, "TERM=screen"));
        try std.testing.expectEqual(@as(usize, 2), env.entries().len);
    }
    {
        var env = try buildEnv(allocator, &base, &.{"TERM=vt100"}, .replace);
        defer env.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), env.entries().len);
        try std.testing.expect(testEnvHas(&env, "TERM=vt100"));
    }
}

test "env replace uses only the supplied entries plus a default TERM" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z", "TERM=screen" };
    {
        var env = try buildEnv(allocator, &base, &.{"ONLY=1"}, .replace);
        defer env.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), env.entries().len);
        try std.testing.expect(testEnvHas(&env, "ONLY=1"));
        try std.testing.expect(testEnvHas(&env, "TERM=" ++ pty.default_term));
    }
    {
        var env = try buildEnv(allocator, &base, null, .replace);
        defer env.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), env.entries().len);
        try std.testing.expect(testEnvHas(&env, "TERM=" ++ pty.default_term));
    }
}

fn buildEnvForFailureTest(allocator: Allocator) !void {
    const base = [_:null]?[*:0]const u8{ "PATH=/usr/bin", "HOME=/home/z" };
    var env = try buildEnv(allocator, &base, &.{ "A=1", "B=2", "PATH=/x" }, .merge);
    env.deinit(allocator);
}

test "env construction cleans up on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildEnvForFailureTest, .{});
}

test "env merge keeps only the last value of a repeated key, in order" {
    const allocator = std.testing.allocator;
    const base = [_:null]?[*:0]const u8{ "A=base", "KEEP=base", "TERM=screen" };
    var env = try buildEnv(allocator, &base, &.{ "A=1", "B=1", "A=2", "C=1", "B=2", "A=3" }, .merge);
    defer env.deinit(allocator);
    const entries = env.entries();
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("KEEP=base", std.mem.sliceTo(entries[0].?, 0));
    try std.testing.expectEqualStrings("TERM=screen", std.mem.sliceTo(entries[1].?, 0));
    try std.testing.expectEqualStrings("C=1", std.mem.sliceTo(entries[2].?, 0));
    try std.testing.expectEqualStrings("B=2", std.mem.sliceTo(entries[3].?, 0));
    try std.testing.expectEqualStrings("A=3", std.mem.sliceTo(entries[4].?, 0));
}

test "env merge of many distinct keys is not quadratic" {
    const allocator = std.testing.allocator;
    const count = 40_000;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const supplied = try arena.alloc([]const u8, count);
    for (supplied, 0..) |*entry, index| entry.* = try std.fmt.allocPrint(arena, "ZMUX_KEY_{d}=v", .{index});
    const base_entries = try arena.allocSentinel(?[*:0]const u8, count, null);
    for (base_entries, 0..) |*entry, index| {
        entry.* = (try std.fmt.allocPrintSentinel(arena, "ZMUX_BASE_{d}=v", .{index}, 0)).ptr;
    }

    // A suffix scan per key is 8e8 key comparisons per list here (well over
    // ten seconds in a debug build); the indexed merge takes milliseconds.
    const started = sys.monotonicMs();
    var env = try buildEnv(allocator, base_entries.ptr, supplied, .merge);
    defer env.deinit(allocator);
    try std.testing.expect(sys.monotonicMs() - started < 5000);
    try std.testing.expectEqual(@as(usize, 2 * count + 1), env.entries().len);
}
