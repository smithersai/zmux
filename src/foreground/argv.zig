//! Owned argv types and the Darwin `KERN_PROCARGS2` parser.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const posix = std.posix;
const assert = std.debug.assert;

/// Name and argv of a foreground process. Owns `comm` and every `argv` entry;
/// release them with `deinit`.
pub const ProcessInfo = struct {
    allocator: Allocator,
    pid: posix.pid_t,
    comm: []u8,
    argv: [][]u8,
    /// True when argv was cut: by the kernel buffer, the /proc read bound,
    /// or `max_serialized_argv_bytes`.
    argv_truncated: bool = false,
    /// True when the OS lookup failed and `comm`/`argv` are the `pid-<n>`
    /// fallback. Callers should not `Tracker.commit` such a result, so a later
    /// poll retries the lookup.
    degraded: bool = false,

    pub fn deinit(self: *ProcessInfo) void {
        self.allocator.free(self.comm);
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

/// Parse a `KERN_PROCARGS2` buffer and return only the argv slice.
/// See `parseProcArgs` for the format and the truncation flag.
pub fn parseProcArgsBuffer(allocator: Allocator, buffer: []const u8, fallback_path: []const u8) Allocator.Error![][]u8 {
    return (try parseProcArgs(allocator, buffer, fallback_path)).argv;
}

/// Owned argv parsed from a process-arguments buffer.
pub const ParsedArgv = struct {
    argv: [][]u8,
    /// The buffer ended before `argc` arguments were read.
    truncated: bool = false,
};

/// Pointer size of every process Darwin still runs. XNU pads the saved exec
/// path to this alignment (`exec_extract_strings`).
const procargs_pointer_size: usize = 8;

/// Parse a Darwin `KERN_PROCARGS2` buffer:
///
///     argc:u32 | exec_path NUL | NUL padding | argv[0] NUL ... argv[argc-1] NUL | envp ...
///
/// The environment follows argv with no separator and may hold secrets, so
/// the parser must consume exactly `argc` strings starting at the true argv
/// boundary. That boundary is established independently of the argv bytes:
/// XNU pads `exec_path NUL` with NULs to a pointer-size multiple, so the
/// length of the padding follows from the path length alone. NULs past the
/// padding are empty leading arguments (`argv[0] == ""`) and each consumes
/// one of the `argc` slots. Inside the argv area each NUL ends exactly one
/// argument, so an empty argument (`git commit -m ""`) also consumes a slot.
///
/// When the NUL run is shorter than the padding the layout is not the one
/// described here and the boundary is ambiguous: only `fallback_path` is
/// reported, with `truncated = true`, and nothing after the path is read. A
/// buffer that ends before `argc` arguments returns what was parsed with
/// `truncated = true`.
pub fn parseProcArgs(allocator: Allocator, buffer: []const u8, fallback_path: []const u8) Allocator.Error!ParsedArgv {
    if (buffer.len < @sizeOf(u32)) return .{ .argv = try fallbackArgv(allocator, fallback_path) };

    const argc_u32 = std.mem.readInt(u32, buffer[0..@sizeOf(u32)], builtin.cpu.arch.endian());
    const argc = @as(usize, @intCast(argc_u32));
    if (argc == 0) return .{ .argv = try fallbackArgv(allocator, fallback_path) };

    var offset: usize = @sizeOf(u32);
    while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
    const path_len = offset - @sizeOf(u32);
    const run_start = offset;
    while (offset < buffer.len and buffer[offset] == 0) : (offset += 1) {}
    const nul_run = offset - run_start;

    // Terminator plus padding up to the pointer-size boundary.
    const pad = (procargs_pointer_size - (path_len + 1) % procargs_pointer_size) % procargs_pointer_size;
    const expected_run = 1 + pad;
    assert(expected_run <= procargs_pointer_size);
    // The buffer ends inside the NUL run (no argument is visible), or the
    // run is too short for the documented layout: the argv boundary cannot
    // be established, so report the executable alone.
    if (offset >= buffer.len or nul_run < expected_run) {
        return .{ .argv = try fallbackArgv(allocator, fallback_path), .truncated = true };
    }
    assert(nul_run >= expected_run);
    assert(offset < buffer.len);

    // The list is the single owner of every argument until `toOwnedSlice`.
    var argv = std.ArrayList([]u8).empty;
    errdefer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }
    try argv.ensureTotalCapacity(allocator, @min(argc, 64));

    var remaining = argc;
    var leading_empty = @min(nul_run - expected_run, argc);
    while (leading_empty > 0) : (leading_empty -= 1) {
        const arg = try allocator.dupe(u8, "");
        errdefer allocator.free(arg);
        try argv.append(allocator, arg);
        remaining -= 1;
    }

    var cut = false;
    while (remaining > 0 and offset < buffer.len) {
        const start = offset;
        while (offset < buffer.len and buffer[offset] != 0) : (offset += 1) {}
        // An argument cut off by the end of the buffer is still reported,
        // but marks the result truncated below.
        const terminated = offset < buffer.len;

        const arg = try allocator.dupe(u8, buffer[start..offset]);
        errdefer allocator.free(arg);
        try argv.append(allocator, arg);
        remaining -= 1;

        if (!terminated) {
            cut = true;
            break;
        }
        offset += 1;
    }
    assert(argv.items.len + remaining == argc);
    assert(offset <= buffer.len);
    return .{ .argv = try argv.toOwnedSlice(allocator), .truncated = remaining > 0 or cut };
}

/// Argv holding only `fallback_path`, or an empty argv when it is empty.
pub fn fallbackArgv(allocator: Allocator, fallback_path: []const u8) Allocator.Error![][]u8 {
    if (fallback_path.len == 0) return allocator.alloc([]u8, 0);

    var argv = try allocator.alloc([]u8, 1);
    errdefer allocator.free(argv);
    argv[0] = try allocator.dupe(u8, fallback_path);
    return argv;
}

/// Free every argument in `argv` and the slice itself.
pub fn freeArgv(allocator: Allocator, argv: [][]u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

test "parse proc args buffer extracts argv after exec path" {
    // "/bin/zsh" is 8 bytes: its terminator plus 7 padding NULs reach the
    // next pointer boundary.
    const buffer = procArgsFixture(3, "/bin/zsh" ++ fixtureBytes(0, 8) ++ "git\x00status\x00--short\x00HOME=/\x00");
    const parsed = try parseProcArgs(std.testing.allocator, &buffer, "/bin/zsh");
    const argv = parsed.argv;
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expect(!parsed.truncated);

    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("status", argv[1]);
    try std.testing.expectEqualStrings("--short", argv[2]);
}

fn fixtureBytes(comptime byte: u8, comptime count: usize) [count]u8 {
    return @splat(byte);
}

fn procArgsFixture(comptime argc: u32, comptime body: []const u8) [4 + body.len]u8 {
    var out: [4 + body.len]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], argc, builtin.cpu.arch.endian());
    @memcpy(out[4..], body);
    return out;
}

fn expectProcArgs(buffer: []const u8, expected: []const []const u8, truncated: bool) !void {
    const parsed = try parseProcArgs(std.testing.allocator, buffer, "/bin/x");
    defer freeArgv(std.testing.allocator, parsed.argv);
    try std.testing.expectEqual(expected.len, parsed.argv.len);
    for (expected, parsed.argv) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(truncated, parsed.truncated);
    for (parsed.argv) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "SECRET") == null);
}

// Fixtures use the exec path "/bin/x" (6 bytes): its terminator plus one
// padding NUL reach the pointer boundary, so argv starts after two NULs.

test "KERN_PROCARGS2 empty argv element never exposes envp" {
    const buffer = procArgsFixture(3, "/bin/x\x00\x00x\x00\x00y\x00SECRET=1\x00");
    try expectProcArgs(&buffer, &.{ "x", "", "y" }, false);
}

test "KERN_PROCARGS2 trailing and repeated empty arguments" {
    const trailing = procArgsFixture(2, "/bin/x\x00\x00x\x00\x00SECRET=1\x00");
    try expectProcArgs(&trailing, &.{ "x", "" }, false);

    const repeated = procArgsFixture(4, "/bin/x\x00\x00git\x00\x00\x00z\x00SECRET=1\x00HOME=/\x00");
    try expectProcArgs(&repeated, &.{ "git", "", "", "z" }, false);
}

test "KERN_PROCARGS2 empty argv[0] consumes a slot and never exposes envp" {
    // One NUL beyond the padding: argv[0] is "".
    const one = procArgsFixture(2, "/bin/x\x00\x00\x00arg\x00SECRET=1\x00HOME=/\x00");
    try expectProcArgs(&one, &.{ "", "arg" }, false);

    // Two empty leading arguments, then one real one.
    const two = procArgsFixture(3, "/bin/x\x00\x00\x00\x00arg\x00SECRET=1\x00");
    try expectProcArgs(&two, &.{ "", "", "arg" }, false);

    // Every argument is empty: the first non-NUL byte is already envp.
    const all = procArgsFixture(2, "/bin/x\x00\x00\x00\x00SECRET=1\x00SECRET=2\x00");
    try expectProcArgs(&all, &.{ "", "" }, false);

    // More NULs than argc slots cannot be arguments; nothing past them is read.
    const excess = procArgsFixture(1, "/bin/x\x00\x00\x00\x00\x00SECRET=1\x00");
    try expectProcArgs(&excess, &.{""}, false);

    // Every exec path length, with an empty argv[0] and a real argv[1].
    inline for (1..18) |path_len| {
        const path = comptime "/" ++ fixtureBytes('p', path_len - 1);
        const pad = comptime (procargs_pointer_size - (path_len + 1) % procargs_pointer_size) % procargs_pointer_size;
        const body = comptime path ++ "\x00" ++ fixtureBytes(0, pad) ++ "\x00" ++ "arg\x00SECRET=1\x00SECRET=2\x00";
        const buffer = comptime procArgsFixture(2, body);
        try expectProcArgs(&buffer, &.{ "", "arg" }, false);
    }
}

test "KERN_PROCARGS2 ambiguous argv boundary reports only the exec path" {
    // "/bin/zsh" needs 8 NULs before argv. A shorter run does not match the
    // documented layout, so no string after the path is trusted.
    const short_run = procArgsFixture(2, "/bin/zsh\x00\x00SECRET=1\x00SECRET=2\x00");
    try expectProcArgs(&short_run, &.{"/bin/x"}, true);

    const no_padding = procArgsFixture(1, "/bin/zsh\x00SECRET=1\x00");
    try expectProcArgs(&no_padding, &.{"/bin/x"}, true);
}

test "KERN_PROCARGS2 truncated buffer reports truncation" {
    const short = procArgsFixture(3, "/bin/x\x00\x00a\x00b");
    try expectProcArgs(&short, &.{ "a", "b" }, true);

    const ends_after_nul = procArgsFixture(3, "/bin/x\x00\x00a\x00");
    try expectProcArgs(&ends_after_nul, &.{"a"}, true);
}

test "KERN_PROCARGS2 degenerate buffers fall back to the exec path" {
    try expectProcArgs("ab", &.{"/bin/x"}, false);
    const zero = procArgsFixture(0, "/bin/x\x00SECRET=1\x00");
    try expectProcArgs(&zero, &.{"/bin/x"}, false);
    const path_only = procArgsFixture(2, "/bin/x\x00\x00\x00");
    try expectProcArgs(&path_only, &.{"/bin/x"}, true);
    const unterminated_path = procArgsFixture(2, "/bin/x");
    try expectProcArgs(&unterminated_path, &.{"/bin/x"}, true);
}

fn parseProcArgsForAllocTest(allocator: Allocator, buffer: []const u8) !void {
    const parsed = try parseProcArgs(allocator, buffer, "/bin/x");
    freeArgv(allocator, parsed.argv);
}

test "parseProcArgs frees partial results on allocation failure" {
    const buffer = procArgsFixture(3, "/bin/x\x00\x00x\x00\x00y\x00SECRET=1\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &buffer)});
    const leading_empty = procArgsFixture(3, "/bin/x\x00\x00\x00\x00y\x00SECRET=1\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &leading_empty)});
}

test "parseProcArgs fallback branches survive every allocation failure" {
    // Positive argc with no parseable argument used to deinit the argv list
    // twice when the fallback allocation failed.
    const path_only = procArgsFixture(2, "/bin/x\x00\x00\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &path_only)});
    const ambiguous = procArgsFixture(2, "/bin/zsh\x00\x00SECRET=1\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &ambiguous)});
    const zero = procArgsFixture(0, "/bin/x\x00");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseProcArgsForAllocTest, .{@as([]const u8, &zero)});
}
