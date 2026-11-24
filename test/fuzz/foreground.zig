const std = @import("std");
const builtin = @import("builtin");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const foreground = zmux.foreground;

fn fuzzLinuxProcParsers(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    var raw_buf: [1024]u8 = undefined;
    const raw = corpus.drawBytes(smith, &raw_buf);

    // 1. parseLinuxProcComm invariants
    const comm = foreground.parseLinuxProcComm(raw);
    try std.testing.expect(comm.len <= raw.len);
    if (comm.len > 0) {
        const last = comm[comm.len - 1];
        try std.testing.expect(last != '\n' and last != '\r' and last != 0 and last != ' ' and last != '\t');
    }
    // Idempotent
    try std.testing.expectEqualSlices(u8, comm, foreground.parseLinuxProcComm(comm));

    // 2. parseLinuxProcCmdline differential check against reference split
    const argv = try foreground.parseLinuxProcCmdline(allocator, raw);
    defer foreground.freeArgv(allocator, argv);

    // Every argument is NUL-terminated: only the single final NUL is
    // stripped, so empty arguments (`a\0\0` -> ["a", ""]) survive.
    if (raw.len == 0) {
        try std.testing.expectEqual(@as(usize, 0), argv.len);
    } else {
        const trimmed = if (raw[raw.len - 1] == 0) raw[0 .. raw.len - 1] else raw;
        try std.testing.expectEqual(std.mem.count(u8, trimmed, "\x00") + 1, argv.len);
        var reconstructed: std.ArrayList(u8) = .empty;
        defer reconstructed.deinit(allocator);
        for (argv, 0..) |arg, idx| {
            // No individual arg may contain an embedded NUL byte.
            try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, arg, 0));
            if (idx > 0) try reconstructed.append(allocator, 0);
            try reconstructed.appendSlice(allocator, arg);
        }
        try std.testing.expectEqualSlices(u8, trimmed, reconstructed.items);
    }

    // 3. OOM leak check on parseLinuxProcCmdline
    const fail_idx = smith.valueRangeAtMost(u8, 0, 8);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (foreground.parseLinuxProcCmdline(fa, raw)) |a| {
        foreground.freeArgv(fa, a);
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzDarwinProcArgsBuffer(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;

    var buf: [1024]u8 = undefined;
    var fb_buf: [128]u8 = undefined;
    const raw = corpus.drawBytes(smith, &buf);
    const fallback = corpus.drawBytes(smith, &fb_buf);

    const argv = try foreground.parseProcArgsBuffer(allocator, raw, fallback);
    defer foreground.freeArgv(allocator, argv);

    // Every parsed argument must be NUL-free (unless fallback was returned
    // verbatim with embedded NULs). Empty arguments are legal: `git commit -m ""`.
    if (argv.len == 1 and std.mem.eql(u8, argv[0], fallback)) {
        // Fallback path accepted verbatim.
    } else {
        for (argv) |arg| {
            try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, arg, 0));
        }
    }

    // Must never allocate more args than possible non-empty NUL-separated tokens
    // in `raw` (+1 for fallback).
    try std.testing.expect(argv.len <= raw.len + 1);

    // OOM safety check
    const fail_idx = smith.valueRangeAtMost(u8, 0, 8);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
    const fa = failing.allocator();
    if (foreground.parseProcArgsBuffer(fa, raw, fallback)) |a| {
        foreground.freeArgv(fa, a);
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

fn fuzzForegroundTracker(_: void, smith: *std.testing.Smith) !void {
    const shell_pid = smith.valueRangeAtMost(i32, 1, 10000);
    var tracker = foreground.Tracker.init(shell_pid);

    var ref_last: ?i32 = null;
    var steps: usize = 0;
    while (!smith.eos() and steps < 128) : (steps += 1) {
        const pgid: i32 = switch (smith.valueRangeAtMost(u8, 0, 4)) {
            0 => shell_pid,
            1 => 0,
            2 => -1,
            3 => smith.valueRangeAtMost(i32, 1, 8),
            else => smith.value(i32),
        };
        // `observe` is pure: it reports a change against the last committed
        // group (the shell group included) and records nothing.
        const got = tracker.observe(pgid);
        try std.testing.expectEqual(got, tracker.observe(pgid));
        const expected = blk: {
            if (pgid <= 0) break :blk false;
            if (ref_last) |last| break :blk last != pgid;
            break :blk true;
        };
        // The emit may fail; only a successful emit commits, so a failed
        // one is retried on the next poll.
        if (got and smith.value(bool)) {
            tracker.commit(pgid);
            ref_last = pgid;
            try std.testing.expect(!tracker.observe(pgid));
        }
        try std.testing.expectEqual(expected, got);
    }
}

test "fuzz: foreground Linux /proc/{comm,cmdline} parsers and OOM safety" {
    try std.testing.fuzz({}, fuzzLinuxProcParsers, .{
        .corpus = &.{
            corpus.sliceSeed(""),
            corpus.sliceSeed("\x00\x00\x00"),
            corpus.sliceSeed("git\x00status\x00--short\x00"),
            corpus.sliceSeed("echo\x00\x00x\x00\x00"),
            corpus.sliceSeed("bash\r\n \t\x00"),
        },
    });
}

test "fuzz: foreground Darwin KERN_PROCARGS2 binary parser and OOM safety" {
    // Seed with huge argc (0xFFFFFFFF) + tiny buffer to verify no OOM-bomb!
    const huge_argc_seed = comptime blk: {
        var b: [16]u8 = @splat(0);
        std.mem.writeInt(u32, b[0..4], std.math.maxInt(u32), builtin.cpu.arch.endian());
        @memcpy(b[4..8], "/sh\x00");
        @memcpy(b[8..12], "a\x00b\x00");
        break :blk b;
    };
    // Regression seed: valid argc=1 with zero args triggers fallbackArgv after
    // argv.deinit(); fail_idx=0 induces OOM inside fallbackArgv (previously GPF).
    const empty_args_seed = comptime blk: {
        var b: [8]u8 = @splat(0);
        std.mem.writeInt(u32, b[0..4], 1, builtin.cpu.arch.endian());
        break :blk b;
    };
    try std.testing.fuzz({}, fuzzDarwinProcArgsBuffer, .{
        .corpus = &.{
            corpus.seed(&.{ .{ .slice = "" }, .{ .slice = "/bin/sh" }, .{ .int = 0 } }),
            corpus.seed(&.{ .{ .slice = &huge_argc_seed }, .{ .slice = "/bin/zsh" }, .{ .int = 1 } }),
            corpus.seed(&.{ .{ .slice = &empty_args_seed }, .{ .slice = "/bin/sh" }, .{ .int = 0 } }),
        },
    });
}

test "fuzz: foreground.Tracker PGID deduplication state machine" {
    try std.testing.fuzz({}, fuzzForegroundTracker, .{});
}

test "parseProcArgs: OOM in fallback after an empty argv area does not double free" {
    // argc = 1 and no argv bytes: the parser discards its argv list and
    // falls back. Fail the fallback allocation (index 1; index 0 is the argv
    // capacity) so the errdefer runs over the discarded list.
    var raw: [8]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], 1, builtin.cpu.arch.endian());
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, foreground.parseProcArgsBuffer(failing.allocator(), &raw, "/bin/sh"));
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
