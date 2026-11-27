//! The interactive attach loop: polls stdin, stdout and the daemon socket,
//! forwards input, writes pane output, and ends with a `RunOutcome`.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const assert = std.debug.assert;
const sys = @import("../sys.zig");
const LineReader = @import("../rpc_line_reader.zig").LineReader;
const cli = @import("cli.zig");
const events = @import("events.zig");
const rpc = @import("rpc.zig");
const terminal = @import("terminal.zig");
const wire = @import("wire.zig");

const buffer_size = wire.buffer_size;
const rpc_line_max = wire.rpc_line_max;
const outbound_max = wire.outbound_max;
const partial_frame_timeout_ms = wire.partial_frame_timeout_ms;
const pipe_quiet_ms = wire.pipe_quiet_ms;
const send_reply_timeout_ms = wire.send_reply_timeout_ms;
const max_pending_sends = wire.max_pending_sends;
const run_loop_poll_timeout_ms = wire.run_loop_poll_timeout_ms;
const default_detach_key = wire.default_detach_key;
const diagnostic = cli.diagnostic;
const RunOutcome = events.RunOutcome;
const RunState = events.RunState;
const handleServerLine = events.handleServerLine;
const Deadline = rpc.Deadline;
const readRpcResponse = rpc.readRpcResponse;
const WriteQueue = terminal.WriteQueue;
const pollUnsupported = terminal.pollUnsupported;
const readStdinChunk = terminal.readStdinChunk;
const currentTerminalSize = terminal.currentTerminalSize;
const g_winch_flag = &terminal.g_winch_flag;

const test_io = std.testing.io;

/// Initial state of the interactive loop.
pub const RunLoopOptions = struct {
    pane_id: []const u8,
    client_id: []const u8 = "",
    generation: ?u64 = null,
    replay_end: ?u64 = null,
    detach_key: ?u8 = null,
    piped: bool = false,
    bootstrap_lines: []const []const u8 = &.{},
    io: std.Io,
};

/// Run the interactive attach loop until the session ends.
pub fn runLoop(
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    socket_fd: posix.fd_t,
    reader: *LineReader,
    allocator: std.mem.Allocator,
    options: RunLoopOptions,
) !RunOutcome {
    assert(options.pane_id.len > 0);
    try sys.setNonBlocking(socket_fd);
    var loop: RunLoop = .{
        .stdin_fd = stdin_fd,
        .stdout_fd = stdout_fd,
        .socket_fd = socket_fd,
        .reader = reader,
        .allocator = allocator,
        .options = options,
        .state = .{
            .pane_id = options.pane_id,
            .client_id = options.client_id,
            .generation = options.generation,
            .next_offset = options.replay_end,
        },
        .bootstrap_lines = options.bootstrap_lines,
        .stdin_unpollable = pollUnsupported(stdin_fd),
        .stdout_unpollable = pollUnsupported(stdout_fd),
    };
    defer loop.deinit();
    while (true) {
        if (try loop.step()) |outcome| return outcome;
    }
}

/// The interactive attach loop's state. `step` runs one poll turn; each
/// phase of a turn is its own method.
const RunLoop = struct {
    stdin_fd: posix.fd_t,
    stdout_fd: posix.fd_t,
    socket_fd: posix.fd_t,
    reader: *LineReader,
    allocator: std.mem.Allocator,
    options: RunLoopOptions,
    state: RunState,
    outbound: WriteQueue = .{},
    partial_since: ?i64 = null,
    pending_output: ?[]u8 = null,
    output_sent: usize = 0,
    stdin_eof: bool = false,
    quiet_until: ?i64 = null,
    bootstrap_lines: []const []const u8,
    eof_outcome: ?RunOutcome = null,
    resize_pending: bool = true,
    buf: [buffer_size]u8 = undefined,
    stdin_unpollable: bool,
    stdout_unpollable: bool,

    // Leave space for a worst-case input frame and a detach frame.
    const queue_headroom = buffer_size * 2 + 4096;
    comptime {
        assert(queue_headroom < outbound_max);
    }

    pub fn deinit(self: *RunLoop) void {
        if (self.state.switched_pane) |pane| self.allocator.free(pane);
        self.state.pending_sends.deinit(self.allocator);
        self.outbound.bytes.deinit(self.allocator);
        if (self.pending_output) |bytes| self.allocator.free(bytes);
    }

    /// One loop turn. Returns the outcome once the session is over.
    pub fn step(self: *RunLoop) !?RunOutcome {
        assert(self.output_sent == 0 or self.pending_output != null);
        if (self.pending_output == null and (self.eof_outcome == null or self.state.pending_sends.count() != 0)) {
            try self.drainLines();
        }

        const awaiting_sends = self.state.pending_sends.count() != 0;
        if (try self.checkDeadlines(awaiting_sends)) |outcome| return outcome;

        const can_queue = self.outbound.pending().len <= outbound_max - queue_headroom;
        try self.queueResize(can_queue);

        const read_socket = self.pending_output == null and (self.eof_outcome == null or awaiting_sends);
        const socket_events: i16 = (if (read_socket) @as(i16, posix.POLL.IN) else 0) |
            (if (self.outbound.pending().len != 0) @as(i16, posix.POLL.OUT) else 0);
        const want_stdin = !self.stdin_eof and self.eof_outcome == null and can_queue and
            self.state.pending_sends.count() < max_pending_sends;
        const want_stdout = self.pending_output != null;
        const stdin_poll_fd = if (want_stdin and !self.stdin_unpollable) self.stdin_fd else -1;
        const stdout_poll_fd = if (want_stdout and !self.stdout_unpollable) self.stdout_fd else -1;
        var fds = [_]posix.pollfd{
            .{ .fd = stdin_poll_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (socket_events != 0) self.socket_fd else -1, .events = socket_events, .revents = 0 },
            .{ .fd = stdout_poll_fd, .events = posix.POLL.OUT, .revents = 0 },
        };
        // An unpollable stdout (see pollUnsupported) is written without
        // waiting; an unpollable stdin is read once per loop turn.
        _ = try posix.poll(&fds, if (want_stdout and self.stdout_unpollable) 0 else run_loop_poll_timeout_ms);
        if (want_stdin and self.stdin_unpollable) fds[0].revents = posix.POLL.IN;
        if (want_stdout and self.stdout_unpollable) fds[2].revents = posix.POLL.OUT;
        if ((fds[2].revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0) return error.OutputClosed;
        // POLLNVAL counts as writable: Darwin's poll(2) rejects character
        // devices such as /dev/null with POLLNVAL. The write then succeeds,
        // or fails with the real error for a descriptor that is not open.
        if ((fds[2].revents & (posix.POLL.OUT | posix.POLL.NVAL)) != 0) try self.writeOutput();
        if (try self.serviceSocket(fds[1].revents, socket_events)) |outcome| return outcome;

        // POLLNVAL counts as readable: Darwin's poll(2) rejects character
        // devices such as /dev/null with POLLNVAL instead of reporting them
        // ready. The read then returns EOF (or the real error) rather than
        // leaving the loop spinning on a descriptor poll will never accept.
        if ((fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL)) != 0) {
            return self.serviceStdin();
        }
        return null;
    }

    /// Handle bootstrap lines and complete buffered frames until output is
    /// pending or the session is over.
    pub fn drainLines(self: *RunLoop) !void {
        const allocator = self.allocator;
        while (self.bootstrap_lines.len != 0 or self.reader.hasBufferedLine()) {
            const owned = if (self.bootstrap_lines.len == 0)
                (try self.reader.nextBufferedLineAlloc(allocator, rpc_line_max)).?
            else
                null;
            defer if (owned) |bytes| allocator.free(bytes);
            const line = owned orelse self.bootstrap_lines[0];
            if (owned == null) self.bootstrap_lines = self.bootstrap_lines[1..];
            if (try handleServerLine(allocator, line, &self.state, &self.pending_output, self.options.io)) |outcome|
                self.eof_outcome = outcome;
            self.quiet_until = null;
            self.partial_since = null;
            if (self.pending_output != null) break;
            if (self.eof_outcome != null and self.state.pending_sends.count() == 0) break;
        }
        // Move a partial frame out of the fixed-size staging buffer so
        // the next read can continue it.
        if (self.pending_output == null and !self.reader.hasBufferedLine() and self.reader.end > self.reader.start) {
            if (self.partial_since == null) self.partial_since = sys.monotonicMs();
            _ = try self.reader.nextBufferedLineAlloc(allocator, rpc_line_max);
        }
    }

    /// The outcome to return now, if the session is done or a deadline passed.
    pub fn checkDeadlines(self: *RunLoop, awaiting_sends: bool) !?RunOutcome {
        if (self.eof_outcome) |outcome| {
            const detach_flushed = outcome != .detached or self.outbound.pending().len == 0;
            if (!awaiting_sends and self.pending_output == null and detach_flushed) return outcome;
        }
        const now = sys.monotonicMs();
        if (self.partial_since) |started| {
            if (now - started >= partial_frame_timeout_ms) return .connection_lost;
        }
        if (self.outbound.pending().len != 0 and now >= self.outbound.deadline) {
            return diagnostic(self.options.io, "timed out sending interactive requests", .{});
        }
        if (awaiting_sends and now >= self.state.send_reply_deadline)
            return diagnostic(self.options.io, "timed out waiting for session.send replies", .{});
        const idle = !awaiting_sends and self.outbound.pending().len == 0 and
            self.pending_output == null and self.partial_since == null;
        if (self.stdin_eof and idle) {
            const quiet_until = self.quiet_until orelse now + pipe_quiet_ms;
            self.quiet_until = quiet_until;
            if (now >= quiet_until) return .exited;
        }
        return null;
    }

    /// Queue `session.resize` after SIGWINCH (and once at start).
    pub fn queueResize(self: *RunLoop, can_queue: bool) !void {
        self.resize_pending = g_winch_flag.swap(false, .seq_cst) or self.resize_pending;
        if (self.eof_outcome != null or !self.resize_pending or !can_queue) return;
        self.resize_pending = false;
        const size = currentTerminalSize(self.stdout_fd, self.stdin_fd) orelse return;
        assert(size.rows > 0 and size.cols > 0);
        try self.state.queue(self.allocator, &self.outbound, "session.resize", .{
            .sessionId = self.state.pane_id,
            .rows = size.rows,
            .cols = size.cols,
        });
    }

    /// Write as much pending pane output to stdout as it accepts.
    pub fn writeOutput(self: *RunLoop) !void {
        const bytes = self.pending_output orelse return;
        const n = sys.write(self.stdout_fd, bytes[self.output_sent..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        self.output_sent += n;
        assert(self.output_sent <= bytes.len);
        if (self.output_sent == bytes.len) {
            self.allocator.free(bytes);
            self.pending_output = null;
            self.output_sent = 0;
        }
    }

    /// Read from and flush to the daemon socket per its poll result.
    pub fn serviceSocket(self: *RunLoop, revents: i16, socket_events: i16) !?RunOutcome {
        const hup = (revents & posix.POLL.HUP) != 0;
        if (socket_events & posix.POLL.IN != 0 and (revents & (posix.POLL.IN | posix.POLL.HUP)) != 0) {
            const filled = self.reader.fillOnce(self.socket_fd) catch |err| switch (@as(anyerror, err)) {
                error.ConnectionClosed, error.ConnectionResetByPeer => return .connection_lost,
                else => return err,
            };
            switch (filled) {
                .data => self.quiet_until = null,
                .eof => return .connection_lost,
                .would_block => if (hup) return .connection_lost,
            }
        } else if ((revents & (posix.POLL.ERR | posix.POLL.NVAL)) != 0 or
            (socket_events & posix.POLL.OUT != 0 and hup and self.pending_output == null))
        {
            return .connection_lost;
        }
        if (hup and socket_events & posix.POLL.IN == 0) {
            // Finish pending terminal output before reading EOF from the socket.
            self.outbound.bytes.clearRetainingCapacity();
            self.outbound.sent = 0;
        } else if ((revents & posix.POLL.OUT) != 0) {
            self.outbound.flush(self.socket_fd) catch |err| switch (err) {
                error.BrokenPipe, error.ConnectionResetByPeer => {
                    // Read already queued final frames before handling EOF.
                    self.outbound.bytes.clearRetainingCapacity();
                    self.outbound.sent = 0;
                },
                else => return err,
            };
        }
        return null;
    }

    /// Forward one stdin chunk as `session.send`, honoring the detach chord.
    pub fn serviceStdin(self: *RunLoop) !?RunOutcome {
        switch (try readStdinChunk(self.stdin_fd, &self.buf)) {
            .again => {},
            .eof => {
                if (!self.options.piped) return .exited;
                self.stdin_eof = true;
            },
            .bytes => |bytes| {
                assert(bytes.len > 0);
                const chord = if (self.options.detach_key) |key| std.mem.indexOfScalar(u8, bytes, key) else null;
                const input = bytes[0 .. chord orelse bytes.len];
                if (input.len != 0) {
                    const send_id = self.state.next_id;
                    try self.state.queueSend(self.allocator, &self.outbound, input);
                    if (self.options.piped) {
                        if (self.state.pending_sends.count() == 0)
                            self.state.send_reply_deadline = sys.monotonicMs() + send_reply_timeout_ms;
                        try self.state.pending_sends.put(self.allocator, send_id, {});
                    }
                }
                if (chord != null) {
                    assert(input.len < bytes.len);
                    try self.state.queue(self.allocator, &self.outbound, "client.detach", .{
                        .clientId = self.state.client_id,
                    });
                    self.eof_outcome = .detached;
                }
            },
        }
        return null;
    }
};

test "run loop drains frames already buffered behind the RPC response" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    const out = try sys.pipe();
    defer sys.close(out[0]);
    defer sys.close(out[1]);
    const frames = "{\"id\":1,\"result\":{}}\n" ++
        "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\"}}\n" ++
        "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\"}}\n";
    try sys.sendAll(pair[1], frames);
    _ = c.shutdown(pair[1], 1);
    var reader: LineReader = .{};
    defer reader.deinit();
    const response = try readRpcResponse(alloc, &reader, pair[0], 1, .fromNow(test_io, 500));
    defer response.deinit(alloc);
    try std.testing.expect(reader.hasBufferedLine());
    try std.testing.expectEqual(RunOutcome.session_ended, try runLoop(
        input[0],
        out[1],
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .io = test_io },
    ));
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try posix.read(out[0], &bytes));
    try std.testing.expectEqualStrings("ok", &bytes);
}

test "run loop writes to and reads from unpollable devices such as /dev/null" {
    // Darwin's poll(2) reports POLLNVAL for an open /dev/null. The loop must
    // still deliver output to it and see EOF from it.
    const alloc = std.testing.allocator;
    const devnull = try sys.openZ("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    defer sys.close(devnull);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);

    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    try sys.sendAll(pair[1], "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"b2s=\"}}\n" ++
        "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\"}}\n");
    _ = c.shutdown(pair[1], 1);
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectEqual(RunOutcome.session_ended, try runLoop(input[0], devnull, pair[0], &reader, alloc, .{ .pane_id = "p", .io = test_io }));

    const quiet = try sys.socketPair();
    defer sys.close(quiet[0]);
    defer sys.close(quiet[1]);
    var quiet_reader: LineReader = .{};
    defer quiet_reader.deinit();
    try std.testing.expectEqual(RunOutcome.exited, try runLoop(devnull, 1, quiet[0], &quiet_reader, alloc, .{ .pane_id = "p", .io = test_io }));
}

test "run loop completes a frame larger than the line reader staging buffer" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    const frame = try alloc.alloc(u8, 10_000);
    defer alloc.free(frame);
    @memset(frame, ' ');
    const exit_frame = "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\"}}\n";
    @memcpy(frame[frame.len - exit_frame.len ..], exit_frame);
    // The frame exceeds the default AF_UNIX send buffer on Darwin (8 KiB), so
    // the writer runs beside the loop that drains it.
    const Writer = struct {
        fn run(fd: posix.fd_t, bytes: []const u8) void {
            sys.sendAll(fd, bytes) catch {};
            _ = c.shutdown(fd, 1);
        }
    };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{ pair[1], frame });
    var reader: LineReader = .{};
    defer reader.deinit();
    const outcome = runLoop(
        input[0],
        1,
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .io = test_io },
    );
    // Unblock the writer if the loop stopped before draining the frame.
    _ = c.shutdown(pair[0], 0);
    writer.join();
    try std.testing.expectEqual(RunOutcome.session_ended, try outcome);
}

test "run loop ends at EOF when stdin is /dev/null" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    // Darwin's poll(2) reports POLLNVAL for /dev/null; the loop must still
    // read it and see EOF instead of spinning.
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    try std.testing.expect(null_fd >= 0);
    defer sys.close(null_fd);
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectEqual(RunOutcome.exited, try runLoop(
        null_fd,
        1,
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .io = test_io },
    ));
}

test "run loop writes pane output to /dev/null" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    // Darwin's poll(2) reports POLLNVAL for /dev/null; that is not a closed
    // output.
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .WRONLY });
    try std.testing.expect(null_fd >= 0);
    defer sys.close(null_fd);
    try sys.sendAll(pair[1], "{\"method\":\"pane_output\",\"params\":{\"pane_id\":\"p\",\"data_base64\":\"aGk=\"}}\n" ++
        "{\"method\":\"session_exited\",\"params\":{\"session_id\":\"p\"}}\n");
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectEqual(RunOutcome.session_ended, try runLoop(
        input[0],
        null_fd,
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .io = test_io },
    ));
}

test "run loop sends detach while a partial frame is pending" {
    const alloc = std.testing.allocator;
    const pair = try sys.socketPair();
    defer sys.close(pair[0]);
    defer sys.close(pair[1]);
    const input = try sys.pipe();
    defer sys.close(input[0]);
    defer sys.close(input[1]);
    try sys.sendAll(pair[1], "{");
    try sys.writeAll(input[1], "a\x1c");
    var reader: LineReader = .{};
    defer reader.deinit();
    try std.testing.expectEqual(RunOutcome.detached, try runLoop(
        input[0],
        1,
        pair[0],
        &reader,
        alloc,
        .{ .pane_id = "p", .client_id = "c", .detach_key = default_detach_key, .io = test_io },
    ));
    var requests: LineReader = .{};
    defer requests.deinit();
    const deadline = Deadline.fromNow(test_io, 500);
    const send = try requests.readLineAllocTimeout(alloc, test_io, pair[1], rpc_line_max, deadline.timeout());
    defer alloc.free(send);
    const detach = try requests.readLineAllocTimeout(alloc, test_io, pair[1], rpc_line_max, deadline.timeout());
    defer alloc.free(detach);
    try std.testing.expect(std.mem.indexOf(u8, send, "\"id\":101,\"method\":\"session.send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detach, "\"id\":102,\"method\":\"client.detach\"") != null);
}
