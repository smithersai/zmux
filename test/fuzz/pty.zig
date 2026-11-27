//! Coverage-guided fuzzing of pty's pure spawn-preparation helpers: option
//! validation, environment construction, exec candidate resolution, the
//! child's startup errno decoding, and `/proc` line parsing. No child
//! process is ever spawned and no descriptor is opened.

const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const pty = zmux.pty;
const hooks = pty.fuzz_hooks;

const max_entries = 8;
const entry_cap = 24;

/// Draw up to `max_entries` byte strings from `smith` into `storage`.
fn drawEntries(
    smith: *std.testing.Smith,
    storage: *[max_entries][entry_cap]u8,
    out: *[max_entries][]const u8,
) []const []const u8 {
    const count = smith.valueRangeAtMost(u8, 0, max_entries);
    for (0..count) |i| {
        out[i] = corpus.drawBytes(smith, &storage[i]);
    }
    return out[0..count];
}

fn hasNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

/// Independent statement of `validateSpawnOptions`.
fn referenceValid(opts: pty.SpawnOptions) bool {
    if (opts.shell) |v| if (v.len == 0 or hasNul(v)) return false;
    if (opts.command) |v| if (hasNul(v)) return false;
    if (opts.cwd) |v| if (v.len == 0 or hasNul(v)) return false;
    if (opts.env) |entries| for (entries) |entry| {
        if (hasNul(entry)) return false;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
        if (eq == 0) return false;
    };
    return true;
}

fn drawOptional(smith: *std.testing.Smith, buf: []u8) ?[]const u8 {
    if (smith.value(bool)) return null;
    return corpus.drawBytes(smith, buf);
}

fn fuzzValidateSpawnOptions(_: void, smith: *std.testing.Smith) !void {
    var shell_buf: [32]u8 = undefined;
    var command_buf: [32]u8 = undefined;
    var cwd_buf: [32]u8 = undefined;
    var storage: [max_entries][entry_cap]u8 = undefined;
    var slices: [max_entries][]const u8 = undefined;

    const opts: pty.SpawnOptions = .{
        .shell = drawOptional(smith, &shell_buf),
        .command = drawOptional(smith, &command_buf),
        .cwd = drawOptional(smith, &cwd_buf),
        .env = if (smith.value(bool)) null else drawEntries(smith, &storage, &slices),
        .rows = smith.value(u16),
        .cols = smith.value(u16),
        .env_mode = smith.value(pty.EnvMode),
    };
    const accepted = if (hooks.validateSpawnOptionsFn(opts)) |_| true else |err| blk: {
        try std.testing.expectEqual(error.InvalidSpawnArgument, err);
        break :blk false;
    };
    try std.testing.expectEqual(referenceValid(opts), accepted);
}

/// Draw `KEY=VALUE`-shaped entries over a tiny alphabet so keys collide.
fn drawEnvEntries(
    smith: *std.testing.Smith,
    storage: *[max_entries][entry_cap]u8,
    out: *[max_entries][]const u8,
) []const []const u8 {
    const alphabet = "ABT=ERMx";
    const count = smith.valueRangeAtMost(u8, 0, max_entries);
    var kept: usize = 0;
    for (0..count) |_| {
        const len = smith.valueRangeAtMost(u8, 1, entry_cap - 1);
        const buf = &storage[kept];
        for (buf[0..len]) |*byte| byte.* = alphabet[smith.valueRangeAtMost(u8, 0, alphabet.len - 1)];
        if (smith.value(bool) and len >= 5) @memcpy(buf[0..5], "TERM=");
        const entry = buf[0..len];
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        out[kept] = entry;
        kept += 1;
    }
    return out[0..kept];
}

fn keyOf(entry: []const u8) []const u8 {
    return entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
}

/// Index of the last entry in `entries` whose key is `key`, or null.
fn lastIndexOfKey(entries: []const []const u8, key: []const u8) ?usize {
    var found: ?usize = null;
    for (entries, 0..) |entry, i| {
        if (std.mem.eql(u8, keyOf(entry), key)) found = i;
    }
    return found;
}

/// Build the expected `envp` from the documented `buildEnv` contract.
fn referenceEnv(
    base: []const []const u8,
    supplied: []const []const u8,
    mode: pty.EnvMode,
    out: *[2 * max_entries + 1][]const u8,
) []const []const u8 {
    var n: usize = 0;
    var has_term = false;
    if (mode == .merge) for (base) |entry| {
        if (lastIndexOfKey(supplied, keyOf(entry)) != null) continue;
        if (std.mem.eql(u8, keyOf(entry), "TERM")) has_term = true;
        out[n] = entry;
        n += 1;
    };
    for (supplied, 0..) |entry, i| {
        if (lastIndexOfKey(supplied, keyOf(entry)).? != i) continue;
        if (std.mem.eql(u8, keyOf(entry), "TERM")) has_term = true;
        out[n] = entry;
        n += 1;
    }
    if (!has_term) {
        out[n] = hooks.default_term_entry_z;
        n += 1;
    }
    return out[0..n];
}

fn fuzzBuildEnv(_: void, smith: *std.testing.Smith) !void {
    var base_storage: [max_entries][entry_cap]u8 = undefined;
    var base_slices: [max_entries][]const u8 = undefined;
    const base = drawEnvEntries(smith, &base_storage, &base_slices);
    var supplied_storage: [max_entries][entry_cap]u8 = undefined;
    var supplied_slices: [max_entries][]const u8 = undefined;
    const supplied = drawEnvEntries(smith, &supplied_storage, &supplied_slices);
    const mode = smith.value(pty.EnvMode);
    const pass_null = supplied.len == 0 and smith.value(bool);

    // NUL-terminated copy of `base` as a C environment block.
    var base_z_storage: [max_entries][entry_cap + 1]u8 = undefined;
    var base_block: [max_entries:null]?[*:0]const u8 = undefined;
    for (base, 0..) |entry, i| {
        @memcpy(base_z_storage[i][0..entry.len], entry);
        base_z_storage[i][entry.len] = 0;
        base_block[i] = @ptrCast(&base_z_storage[i]);
    }
    base_block[base.len] = null;
    const base_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&base_block);

    try hooks.validateSpawnOptionsFn(.{ .env = supplied });

    // Every allocation failure point must clean up without leaking.
    const fail_index = smith.valueRangeAtMost(u8, 0, 40);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    if (hooks.buildEnvList(failing.allocator(), base_ptr, if (pass_null) null else supplied, mode)) |list_const| {
        var list = list_const;
        list.deinit(failing.allocator());
    } else |err| try std.testing.expectEqual(error.OutOfMemory, err);

    var list = try hooks.buildEnvList(std.testing.allocator, base_ptr, if (pass_null) null else supplied, mode);
    defer list.deinit(std.testing.allocator);

    var expected_buf: [2 * max_entries + 1][]const u8 = undefined;
    const expected = referenceEnv(base, supplied, mode, &expected_buf);
    try std.testing.expect(list.isTerminated());
    try std.testing.expectEqual(expected.len, list.len());
    for (expected, 0..) |want, i| try std.testing.expectEqualStrings(want, list.at(i));
}

/// Draw a PATH-like value over an alphabet rich in ':' and '/'.
fn drawPath(smith: *std.testing.Smith, buf: []u8) []const u8 {
    const alphabet = "::/ab.";
    const len = smith.valueRangeAtMost(u16, 0, @intCast(buf.len));
    for (buf[0..len]) |*byte| byte.* = alphabet[smith.valueRangeAtMost(u8, 0, alphabet.len - 1)];
    return buf[0..len];
}

fn fuzzExecCandidates(_: void, smith: *std.testing.Smith) !void {
    var file_buf: [24]u8 = undefined;
    var path_buf: [64]u8 = undefined;
    const file = drawPath(smith, &file_buf);
    if (file.len == 0) return;
    const path_env = drawPath(smith, &path_buf);

    var list = try hooks.execCandidates(std.testing.allocator, file, path_env);
    defer list.deinit(std.testing.allocator);
    try std.testing.expect(list.isTerminated());

    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        try std.testing.expectEqual(@as(usize, 1), list.len());
        try std.testing.expectEqualStrings(file, list.at(0));
        return;
    }
    var it = std.mem.splitScalar(u8, path_env, ':');
    var index: usize = 0;
    var want_buf: [128]u8 = undefined;
    while (it.next()) |component| : (index += 1) {
        const dir = if (component.len == 0) "." else component;
        const want = try std.fmt.bufPrint(&want_buf, "{s}/{s}", .{ dir, file });
        try std.testing.expectEqualStrings(want, list.at(index));
    }
    try std.testing.expectEqual(index, list.len());
}

fn fuzzSmallParsers(_: void, smith: *std.testing.Smith) !void {
    var buf: [96]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);

    // envKey: the bytes before the first '=', or all of them.
    const key = hooks.envKeyFn(raw);
    try std.testing.expect(std.mem.startsWith(u8, raw, key));
    try std.testing.expect(std.mem.indexOfScalar(u8, key, '=') == null);
    if (key.len < raw.len) try std.testing.expectEqual(@as(u8, '='), raw[key.len]);

    // defaultShellFor: a non-empty SHELL wins; otherwise an absolute default.
    const pass_shell = smith.value(bool);
    const shell = hooks.defaultShellForFn(if (pass_shell) raw else null);
    try std.testing.expect(shell.len > 0);
    if (pass_shell and raw.len > 0) {
        try std.testing.expectEqualSlices(u8, raw, shell);
    } else {
        try std.testing.expect(std.fs.path.isAbsolutePosix(shell));
    }

    // procStatState: first non-blank byte after the last ')', else 0.
    const state = hooks.procStatStateFn(raw);
    if (std.mem.lastIndexOfScalar(u8, raw, ')')) |close| {
        const rest = std.mem.trimStart(u8, raw[close + 1 ..], " ");
        try std.testing.expectEqual(if (rest.len > 0) rest[0] else 0, state);
    } else {
        try std.testing.expectEqual(@as(u8, 0), state);
    }

    // procStatusMask: never more than 16 hex digits parse into a u64.
    // A parsed mask implies the field and at least one hex digit after it;
    // a value of 16 or fewer hex digits always parses.
    const field = "SigIgn:";
    const mask = hooks.procStatusMaskFn(raw, field);
    if (std.mem.indexOf(u8, raw, field)) |at| {
        const rest = std.mem.trimStart(u8, raw[at + field.len ..], " \t");
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isHex(rest[digits])) digits += 1;
        if (digits == 0) try std.testing.expect(mask == null);
        if (digits > 0 and digits <= 16) try std.testing.expect(mask != null);
    } else {
        try std.testing.expect(mask == null);
    }

    // errnoFromReport: in range values round-trip, the rest map to SUCCESS.
    const raw_errno = smith.value(i32);
    const decoded = hooks.errnoFromReportFn(raw_errno);
    if (raw_errno < 0 or raw_errno > std.math.maxInt(u16)) {
        try std.testing.expectEqual(std.posix.E.SUCCESS, decoded);
    } else {
        try std.testing.expectEqual(@as(i64, raw_errno), @as(i64, @backingInt(decoded)));
    }
}

test "fuzz: pty.validateSpawnOptions matches a reference validator" {
    try std.testing.fuzz({}, fuzzValidateSpawnOptions, .{});
}

test "fuzz: pty env construction follows the merge/replace contract and cleans up on OOM" {
    try std.testing.fuzz({}, fuzzBuildEnv, .{});
}

test "fuzz: pty exec candidates follow PATH order" {
    try std.testing.fuzz({}, fuzzExecCandidates, .{});
}

test "fuzz: pty envKey, defaultShellFor, /proc parsers and startup errno decoding" {
    try std.testing.fuzz({}, fuzzSmallParsers, .{
        .corpus = &.{
            corpus.sliceSeed("PATH=/bin"),
            corpus.sliceSeed("12 (a) b) Z) Z 1 12"),
            corpus.sliceSeed("SigIgn:\t0000000000000004\n"),
            corpus.sliceSeed("=x"),
        },
    });
}
