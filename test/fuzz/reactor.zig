const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const reactor = zmux.reactor;
const sys = zmux.sys;

const Reactor = reactor.Reactor;
const Event = reactor.Event;
const Interests = reactor.Interests;

const PipeSlot = struct {
    rfd: sys.fd_t = -1,
    wfd: sys.fd_t = -1,
    watched: bool = false,
    token: u64 = 0,
    interests: Interests = .{},
    pending_bytes: usize = 0,
    writer_closed: bool = false,

    fn open() !PipeSlot {
        const fds = try sys.pipeCloexec();
        return .{ .rfd = fds[0], .wfd = fds[1] };
    }

    fn close(self: *PipeSlot) void {
        if (self.rfd >= 0) {
            sys.close(self.rfd);
            self.rfd = -1;
        }
        if (self.wfd >= 0) {
            sys.close(self.wfd);
            self.wfd = -1;
        }
    }
};

fn findSlotByFd(slots: []const PipeSlot, fd: sys.fd_t) ?usize {
    for (slots, 0..) |slot, i| {
        if (slot.rfd == fd) return i;
    }
    return null;
}

fn fuzzReactorModel(_: void, smith: *std.testing.Smith) !void {
    const allocator = std.testing.allocator;
    const slot_count: usize = smith.valueRangeAtMost(u8, 1, 6);

    var slots: [6]PipeSlot = @splat(.{});
    var opened: usize = 0;
    defer for (0..opened) |i| slots[i].close();
    for (0..slot_count) |i| {
        slots[i] = try PipeSlot.open();
        opened += 1;
    }

    var r = try Reactor.init(allocator);
    defer r.deinit();

    var expected_watched: usize = 0;
    var wake_pending = false;

    const Op = enum(u8) {
        watch,
        modify,
        unwatch,
        write_bytes,
        drain_read,
        close_writer,
        wake,
        wait_poll,
        oom_watch,
    };

    var steps: usize = 0;
    while (!smith.eos() and steps < 96) : (steps += 1) {
        const op = smith.value(Op);
        const idx: usize = smith.valueRangeAtMost(u8, 0, @intCast(slot_count - 1));
        const slot = &slots[idx];

        switch (op) {
            .watch => {
                const token = smith.value(u64);
                const interests: Interests = .{
                    .read = smith.value(bool),
                    .write = false,
                };
                if (slot.watched) {
                    try std.testing.expectError(error.AlreadyWatched, r.watchFd(slot.rfd, token, interests));
                } else {
                    try r.watchFd(slot.rfd, token, interests);
                    slot.watched = true;
                    slot.token = token;
                    slot.interests = interests;
                    expected_watched += 1;
                }
            },
            .modify => {
                const token = smith.value(u64);
                const interests: Interests = .{
                    .read = smith.value(bool),
                    .write = false,
                };
                if (!slot.watched) {
                    try std.testing.expectError(error.NotFound, r.modifyFd(slot.rfd, token, interests));
                } else {
                    try r.modifyFd(slot.rfd, token, interests);
                    slot.token = token;
                    slot.interests = interests;
                }
            },
            .unwatch => {
                r.unwatchFd(slot.rfd);
                if (slot.watched) {
                    slot.watched = false;
                    expected_watched -= 1;
                }
            },
            .write_bytes => {
                if (!slot.writer_closed and slot.pending_bytes < 256) {
                    var payload: [16]u8 = undefined;
                    const len: usize = smith.valueRangeAtMost(u8, 1, payload.len);
                    @memset(payload[0..len], 'z');
                    const n = try sys.write(slot.wfd, payload[0..len]);
                    slot.pending_bytes += n;
                }
            },
            .drain_read => {
                if (slot.pending_bytes > 0) {
                    var buf: [32]u8 = undefined;
                    const to_read = @min(slot.pending_bytes, buf.len);
                    const n = try sys.read(slot.rfd, buf[0..to_read]);
                    slot.pending_bytes -= n;
                }
            },
            .close_writer => {
                if (!slot.writer_closed and slot.wfd >= 0) {
                    sys.close(slot.wfd);
                    slot.wfd = -1;
                    slot.writer_closed = true;
                }
            },
            .wake => {
                try r.wake();
                wake_pending = true;
            },
            .wait_poll => {
                var events: [16]Event = undefined;
                const cap: usize = smith.valueRangeAtMost(u8, 0, events.len);
                const ready = try r.wait(events[0..cap], 0);
                try std.testing.expect(ready.len <= cap);
                for (ready) |ev| {
                    switch (ev.kind) {
                        .wakeup => {
                            try std.testing.expect(wake_pending);
                            try std.testing.expectEqual(@as(u64, 0), ev.token);
                            wake_pending = false;
                        },
                        .fd_readable => {
                            const s_idx = findSlotByFd(slots[0..slot_count], ev.fd) orelse
                                return error.UnexpectedFdEvent;
                            const s = &slots[s_idx];
                            try std.testing.expect(s.watched);
                            try std.testing.expectEqual(s.token, ev.token);
                            try std.testing.expect(s.pending_bytes > 0);
                        },
                        .fd_hup => {
                            const s_idx = findSlotByFd(slots[0..slot_count], ev.fd) orelse
                                return error.UnexpectedFdEvent;
                            const s = &slots[s_idx];
                            try std.testing.expect(s.watched);
                            try std.testing.expectEqual(s.token, ev.token);
                            try std.testing.expect(s.writer_closed);
                        },
                        .fd_writable, .fd_err, .pid_exited => {},
                    }
                }
            },
            .oom_watch => {
                const fail_idx = smith.valueRangeAtMost(u8, 0, 2);
                var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_idx });
                var oom_reactor = Reactor.init(failing.allocator()) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                    continue;
                };
                defer oom_reactor.deinit();
                if (oom_reactor.watchFd(slot.rfd, 1, .{ .read = true })) |_| {
                    oom_reactor.unwatchFd(slot.rfd);
                } else |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                }
            },
        }

        try std.testing.expectEqual(expected_watched, r.watchedFdCount());
    }
}

test "fuzz: Reactor multi-pipe registration, readiness, wake, and OOM safety" {
    try std.testing.fuzz({}, fuzzReactorModel, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .int = 2 }, // 2 pipe slots
                .{ .eos = false },
                .{ .int = 0 }, // watch
                .{ .int = 0 }, // slot 0
                .{ .int = 0x1122 }, // token
                .{ .int = 1 }, // read = true
                .{ .eos = false },
                .{ .int = 3 }, // write_bytes
                .{ .int = 0 }, // slot 0
                .{ .int = 4 }, // 4 bytes
                .{ .eos = false },
                .{ .int = 6 }, // wake
                .{ .int = 0 },
                .{ .eos = false },
                .{ .int = 7 }, // wait_poll
                .{ .int = 0 },
                .{ .int = 8 }, // cap = 8
                .{ .eos = false },
                .{ .int = 4 }, // drain_read
                .{ .int = 0 },
                .{ .eos = false },
                .{ .int = 5 }, // close_writer
                .{ .int = 0 },
                .{ .eos = false },
                .{ .int = 7 }, // wait_poll -> fd_hup
                .{ .int = 0 },
                .{ .int = 4 },
                .{ .eos = false },
                .{ .int = 8 }, // oom_watch
                .{ .int = 1 },
                .{ .int = 0 },
                .{ .eos = true },
            }),
        },
    });
}
