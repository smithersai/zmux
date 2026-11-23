const std = @import("std");

const buffer = @import("buffer.zig");
const foreground = @import("foreground.zig");
const pty = @import("pty.zig");
const protocol = @import("protocol.zig");

pub const NativeSessionState = enum(u8) {
    creating,
    running,
    terminated,

    pub fn label(self: NativeSessionState) []const u8 {
        return @tagName(self);
    }

    pub fn canTransition(self: NativeSessionState, next: NativeSessionState) bool {
        return switch (self) {
            .creating => next == .running or next == .terminated,
            .running => next == .terminated,
            .terminated => false,
        };
    }
};

pub const NativeSessionOptions = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,
    event_sink: ?EventSink = null,
};

pub const Event = union(enum) {
    foreground_changed: protocol.ForegroundChangedParams,
    session_exited: protocol.SessionExitedParams,
    pane_output: PaneOutputEvent,
    pane_activity: PaneActivityEvent,
    pane_bell: PaneBellEvent,
};

pub const PaneOutputEvent = struct {
    pane_id: []const u8,
    data: []const u8,
};

pub const PaneActivityEvent = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
};

pub const PaneBellEvent = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
};

pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) void,
};

/// A single PTY-backed shell with bounded scrollback and a background reader
/// thread. Reference counted: `create` returns one reference; `release` (or
/// `destroy`) drops it and the last release terminates the child.
///
/// `io` supplies the mutex, clock, and sleep primitives. The reader runs on a
/// dedicated `std.Thread` doing blocking `poll(2)`/`read(2)` on the PTY master,
/// so any `std.Io` implementation whose `Mutex` and `sleep` are thread-safe
/// works (for example `std.Io.Threaded`).
pub const NativeSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    id: []u8,
    title_value: []u8,
    shell_value: ?[]u8,
    cwd_value: ?[]u8,
    handle: pty.Pty,
    scrollback: buffer.ScrollbackBuffer,
    state_value: std.atomic.Value(NativeSessionState) = std.atomic.Value(NativeSessionState).init(.creating),
    exit_status: ?u32 = null,
    event_sink: ?EventSink = null,
    foreground_tracker: foreground.Tracker,
    next_foreground_check_ms: i64 = 0,
    reader_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, opts: NativeSessionOptions) !*NativeSession {
        const native = try allocator.create(NativeSession);
        errdefer allocator.destroy(native);

        const id = try allocator.dupe(u8, opts.id);
        errdefer allocator.free(id);

        const native_title = try allocator.dupe(u8, opts.title orelse opts.id);
        errdefer allocator.free(native_title);

        const shell = if (opts.shell) |value| try allocator.dupe(u8, value) else null;
        errdefer if (shell) |value| allocator.free(value);

        const cwd = if (opts.cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| allocator.free(value);

        var scrollback = try buffer.ScrollbackBuffer.init(allocator, opts.scrollback_bytes);
        errdefer scrollback.deinit();

        var handle = try pty.Pty.spawn(allocator, io, .{
            .shell = opts.shell,
            .command = opts.command,
            .cwd = opts.cwd,
            .env = opts.env,
            .rows = opts.rows,
            .cols = opts.cols,
        });
        errdefer handle.close();

        native.* = .{
            .allocator = allocator,
            .io = io,
            .id = id,
            .title_value = native_title,
            .shell_value = shell,
            .cwd_value = cwd,
            .handle = handle,
            .scrollback = scrollback,
            .event_sink = opts.event_sink,
            .foreground_tracker = foreground.Tracker.init(handle.child_pid),
            .state_value = std.atomic.Value(NativeSessionState).init(.running),
        };
        native.handle.setExitObserver(.{
            .context = native,
            .callback = NativeSession.onPtyExited,
        });

        native.reader_thread = try std.Thread.spawn(.{}, NativeSession.readerLoop, .{native});
        return native;
    }

    pub fn retain(self: *NativeSession) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *NativeSession) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        if (prev == 1) {
            self.destroyInternal();
        }
    }

    pub fn destroy(self: *NativeSession) void {
        self.release();
    }

    fn destroyInternal(self: *NativeSession) void {
        self.reader_stop.store(true, .seq_cst);
        if (self.state() != .terminated) {
            self.terminate();
        } else {
            _ = self.reapExitedBriefly();
        }
        if (self.reader_thread) |thread| thread.join();
        self.clearEventSink();
        self.handle.close();
        self.scrollback.deinit();
        self.allocator.free(self.id);
        self.allocator.free(self.title_value);
        if (self.shell_value) |value| self.allocator.free(value);
        if (self.cwd_value) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }

    pub fn state(self: *NativeSession) NativeSessionState {
        return self.state_value.load(.acquire);
    }

    pub fn terminate(self: *NativeSession) void {
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);

        self.handle.terminate();

        // Try to reap the child, waiting briefly for it to exit
        var status: ?u32 = null;
        var attempts: usize = 0;
        while (attempts < 20) : (attempts += 1) {
            if (self.reapExited()) |exit_status| {
                status = exit_status;
                break;
            }
            if (self.handle.isReaped()) break;
            self.sleepMs(10);
        }

        // If still not exited after 200ms, send SIGKILL
        if (status == null) {
            self.handle.kill();
            // Wait one more time after SIGKILL
            var kill_attempts: usize = 0;
            while (kill_attempts < 10) : (kill_attempts += 1) {
                if (self.reapExited()) |exit_status| {
                    status = exit_status;
                    break;
                }
                if (self.handle.isReaped()) break;
                self.sleepMs(10);
            }
        }

        self.markTerminated(status);
    }

    pub fn stopForOwnerRelease(self: *NativeSession) void {
        if (self.state() != .terminated) {
            self.terminate();
        } else {
            _ = self.reapExitedBriefly();
        }
    }

    pub fn reapExited(self: *NativeSession) ?u32 {
        if (self.handle.reapExited()) |status| {
            self.markTerminated(status);
            return status;
        }
        if (self.handle.isReaped()) {
            self.markTerminated(null);
        }
        return null;
    }

    pub fn send(self: *NativeSession, text: []const u8, enter: bool) !void {
        try self.handle.write(text);
        if (enter) try self.handle.write("\r");
    }

    pub fn sendKey(self: *NativeSession, key: []const u8) !void {
        const sequence = keySequence(key) orelse return error.UnknownKey;
        try self.handle.write(sequence);
    }

    pub fn resize(self: *NativeSession, cols: u16, rows: u16) !void {
        if (self.state() == .terminated) return error.SessionTerminated;
        try self.handle.resize(cols, rows);
    }

    pub fn capture(self: *NativeSession, allocator: std.mem.Allocator, lines: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.captureLastLines(allocator, lines);
    }

    pub fn scrollbackSnapshot(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.snapshot(allocator);
    }

    pub fn scrollbackTail(self: *NativeSession, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.scrollback.snapshotTail(allocator, max_bytes);
    }

    pub fn writeInput(self: *NativeSession, bytes: []const u8) !void {
        try self.handle.write(bytes);
    }

    /// Write the opening `{` and all `NativeSession` JSON fields without the
    /// closing `}`, allowing callers such as `mux.Manager.listJson` to append
    /// additional fields directly into one output buffer with zero intermediate
    /// allocations.
    pub fn writeInfoJsonFields(self: *NativeSession, writer: *std.Io.Writer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try writer.print(
            "{{\"id\":{f},\"title\":{f},\"pid\":{},\"state\":{f},\"cwd\":",
            .{
                std.json.fmt(self.id, .{}),
                std.json.fmt(self.title_value, .{}),
                self.handle.child_pid,
                std.json.fmt(self.state_value.load(.monotonic).label(), .{}),
            },
        );
        if (self.cwd_value) |cwd| {
            try writer.print("{f}", .{std.json.fmt(cwd, .{})});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"shell\":");
        if (self.shell_value) |shell| {
            try writer.print("{f}", .{std.json.fmt(shell, .{})});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(
            ",\"scrollbackBytes\":{},\"exitStatus\":",
            .{self.scrollback.len},
        );
        if (self.exit_status) |status| {
            try writer.print("{}", .{status});
        } else {
            try writer.writeAll("null");
        }
    }

    pub fn infoJson(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        errdefer out.deinit();
        try self.writeInfoJsonFields(&out.writer);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    fn readerLoop(self: *NativeSession) void {
        var read_buf: [32 * 1024]u8 = undefined;
        while (!self.reader_stop.load(.acquire)) {
            if (self.state() == .terminated) return;
            self.pollForegroundChange() catch {};

            const readable = self.handle.pollReadable(100) catch {
                const status = self.reapExitedBriefly();
                self.markTerminated(status);
                return;
            };
            if (!readable) continue;

            const n = self.handle.read(&read_buf) catch {
                const status = self.reapExitedBriefly();
                self.markTerminated(status);
                return;
            };
            if (n == 0) {
                const status = self.reapExitedBriefly();
                self.markTerminated(status);
                return;
            }
            const chunk = read_buf[0..n];
            self.mutex.lockUncancelable(self.io);
            self.scrollback.append(chunk);
            const sink = self.event_sink;
            self.mutex.unlock(self.io);

            if (sink) |active| {
                active.emit(active.context, .{ .pane_output = .{
                    .pane_id = self.id,
                    .data = chunk,
                } });
                const now_ms = self.nowMs();
                active.emit(active.context, .{ .pane_activity = .{
                    .pane_id = self.id,
                    .last_activity_ms = now_ms,
                } });
                if (std.mem.indexOfScalar(u8, chunk, 0x07) != null) {
                    active.emit(active.context, .{ .pane_bell = .{
                        .pane_id = self.id,
                        .last_bell_ms = now_ms,
                    } });
                }
            }
        }
    }

    fn pollForegroundChange(self: *NativeSession) !void {
        const now_ms = self.monotonicMs();
        if (now_ms < self.next_foreground_check_ms) return;
        self.next_foreground_check_ms = now_ms + foreground.poll_interval_ms;

        var process = (try self.foreground_tracker.poll(self.allocator, self.io, self.handle.master_fd)) orelse return;
        defer process.deinit();

        self.emitEvent(.{ .foreground_changed = .{
            .session_id = self.id,
            .pid = process.pid,
            .comm = process.comm,
            .argv = process.argv,
        } });
    }

    fn emitEvent(self: *NativeSession, event: Event) void {
        self.mutex.lockUncancelable(self.io);
        const sink = self.event_sink;
        self.mutex.unlock(self.io);
        const active = sink orelse return;
        active.emit(active.context, event);
    }

    pub fn setEventSink(self: *NativeSession, sink: ?EventSink) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.event_sink = sink;
    }

    pub fn clearEventSink(self: *NativeSession) void {
        self.setEventSink(null);
    }

    fn nowMs(self: *NativeSession) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    fn monotonicMs(self: *NativeSession) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn sleepMs(self: *NativeSession, ms: i64) void {
        // Plain threads are never canceled; ignoring error.Canceled is safe.
        self.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }

    fn reapExitedBriefly(self: *NativeSession) ?u32 {
        const previous = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(previous);

        var attempts: usize = 0;
        while (attempts < 50) : (attempts += 1) {
            if (self.reapExited()) |status| return status;
            if (self.handle.isReaped()) return null;
            self.sleepMs(10);
        }
        return null;
    }

    fn onPtyExited(context: *anyopaque, pid: std.posix.pid_t, status: ?u32) void {
        const self: *NativeSession = @ptrCast(@alignCast(context));
        self.markTerminated(status);
        self.emitEvent(.{ .session_exited = .{
            .session_id = self.id,
            .pid = pid,
            .exit_code = if (status) |value| if (std.posix.W.IFEXITED(value)) std.posix.W.EXITSTATUS(value) else null else null,
            .signal = if (status) |value| if (std.posix.W.IFSIGNALED(value)) @backingInt(std.posix.W.TERMSIG(value)) else null else null,
        } });
    }

    fn markTerminated(self: *NativeSession, status: ?u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state_value.store(.terminated, .release);
        if (self.exit_status == null) {
            self.exit_status = if (status) |value| decodedExitStatus(value) else null;
        }
    }
};

pub fn decodedExitStatus(status: u32) u32 {
    if (std.posix.W.IFEXITED(status)) return std.posix.W.EXITSTATUS(status);
    if (std.posix.W.IFSIGNALED(status)) return @backingInt(std.posix.W.TERMSIG(status));
    return status;
}

// Single-byte control sequences for Ctrl-<letter>: C-a => 0x01 .. C-z => 0x1A.
// Stored in a container-level const so `ctrlKeySequence` can hand back a
// stable slice into read-only data rather than a dangling stack pointer.
const ctrl_key_sequences = blk: {
    var table: [26][1]u8 = undefined;
    var i: u8 = 0;
    while (i < 26) : (i += 1) table[i] = [1]u8{i + 1};
    break :blk table;
};

fn keyEql(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

// Parse tmux-style Ctrl-<letter> names ("C-a", "c-a") into their control byte.
fn ctrlKeySequence(key: []const u8) ?[]const u8 {
    if (key.len != 3) return null;
    if (key[0] != 'C' and key[0] != 'c') return null;
    if (key[1] != '-') return null;
    const c = key[2];
    if (!std.ascii.isAlphabetic(c)) return null;
    const index = std.ascii.toUpper(c) - 'A';
    return &ctrl_key_sequences[index];
}

pub fn keySequence(key: []const u8) ?[]const u8 {
    if (ctrlKeySequence(key)) |sequence| return sequence;

    if (keyEql(key, "Enter") or keyEql(key, "Return")) return "\r";
    if (keyEql(key, "Tab")) return "\t";
    if (keyEql(key, "Backspace")) return "\x7f";
    if (keyEql(key, "Escape") or keyEql(key, "Esc")) return "\x1b";
    if (keyEql(key, "Space")) return " ";
    if (keyEql(key, "ArrowUp") or keyEql(key, "Up")) return "\x1b[A";
    if (keyEql(key, "ArrowDown") or keyEql(key, "Down")) return "\x1b[B";
    if (keyEql(key, "ArrowRight") or keyEql(key, "Right")) return "\x1b[C";
    if (keyEql(key, "ArrowLeft") or keyEql(key, "Left")) return "\x1b[D";
    if (keyEql(key, "Home")) return "\x1b[H";
    if (keyEql(key, "End")) return "\x1b[F";
    if (keyEql(key, "PageUp")) return "\x1b[5~";
    if (keyEql(key, "PageDown")) return "\x1b[6~";
    if (keyEql(key, "Insert")) return "\x1b[2~";
    if (keyEql(key, "Delete")) return "\x1b[3~";
    if (keyEql(key, "F1")) return "\x1bOP";
    if (keyEql(key, "F2")) return "\x1bOQ";
    if (keyEql(key, "F3")) return "\x1bOR";
    if (keyEql(key, "F4")) return "\x1bOS";
    if (keyEql(key, "F5")) return "\x1b[15~";
    if (keyEql(key, "F6")) return "\x1b[17~";
    if (keyEql(key, "F7")) return "\x1b[18~";
    if (keyEql(key, "F8")) return "\x1b[19~";
    if (keyEql(key, "F9")) return "\x1b[20~";
    if (keyEql(key, "F10")) return "\x1b[21~";
    if (keyEql(key, "F11")) return "\x1b[23~";
    if (keyEql(key, "F12")) return "\x1b[24~";
    return null;
}

test "native session state machine keeps PTY running until termination" {
    try std.testing.expect(NativeSessionState.creating.canTransition(.running));
    try std.testing.expect(NativeSessionState.running.canTransition(.terminated));
    try std.testing.expect(!NativeSessionState.terminated.canTransition(.running));
}

test "native session key names map to terminal sequences" {
    try std.testing.expectEqualStrings("\x1b[A", keySequence("ArrowUp").?);
    try std.testing.expectEqualStrings("\r", keySequence("Enter").?);
    try std.testing.expect(keySequence("Unknown") == null);
}

test "native session key map covers ctrl, navigation, and function keys" {
    // Ctrl-<letter> control bytes.
    try std.testing.expectEqualStrings("\x01", keySequence("C-a").?);
    try std.testing.expectEqualStrings("\x03", keySequence("C-c").?);
    try std.testing.expectEqualStrings("\x04", keySequence("C-d").?);
    try std.testing.expectEqualStrings("\x1a", keySequence("C-z").?);
    try std.testing.expectEqualStrings("\x03", keySequence("c-C").?);

    // Navigation / editing keys.
    try std.testing.expectEqualStrings("\x1b[H", keySequence("Home").?);
    try std.testing.expectEqualStrings("\x1b[F", keySequence("End").?);
    try std.testing.expectEqualStrings("\x1b[5~", keySequence("PageUp").?);
    try std.testing.expectEqualStrings("\x1b[6~", keySequence("PageDown").?);
    try std.testing.expectEqualStrings("\x1b[2~", keySequence("Insert").?);
    try std.testing.expectEqualStrings("\x1b[3~", keySequence("Delete").?);
    try std.testing.expectEqualStrings(" ", keySequence("Space").?);

    // Function keys (xterm sequences).
    try std.testing.expectEqualStrings("\x1bOP", keySequence("F1").?);
    try std.testing.expectEqualStrings("\x1bOS", keySequence("F4").?);
    try std.testing.expectEqualStrings("\x1b[15~", keySequence("F5").?);
    try std.testing.expectEqualStrings("\x1b[21~", keySequence("F10").?);
    try std.testing.expectEqualStrings("\x1b[24~", keySequence("F12").?);

    // Case-insensitive matching keeps the original names working.
    try std.testing.expectEqualStrings("\r", keySequence("enter").?);
    try std.testing.expectEqualStrings("\x1b", keySequence("ESCAPE").?);

    // Unrecognized keys still return null.
    try std.testing.expect(keySequence("C-4") == null);
    try std.testing.expect(keySequence("F13") == null);
    try std.testing.expect(keySequence("Meta") == null);
}

test "decoded exit status unwraps waitpid status words" {
    try std.testing.expectEqual(@as(u32, 7), decodedExitStatus(7 << 8));
}
