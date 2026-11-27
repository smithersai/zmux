//! VT terminal state bridge for `NativeSession`: OSC event collection,
//! semantic status, plain-text/ANSI restore rendering, delta scrollback
//! replay, non-terminating signal delivery, and info JSON serialization.

const std = @import("std");
const buffer = @import("../buffer.zig");
const vt_mod = @import("../vt.zig");
const root = @import("../native.zig");
const session = @import("session.zig");
const events = @import("events.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const NativeSession = session.NativeSession;
const ExitInfo = root.ExitInfo;

/// Semantic pane activity status combining process state, OSC 7501/133, and idle time.
pub const SemanticStatus = enum {
    running,
    idle,
    waiting_for_input,
    exited,

    /// Wire-format label for this semantic status.
    pub fn label(self: SemanticStatus) []const u8 {
        return @tagName(self);
    }
};

/// Result of `NativeSession.scrollbackSliceSince` for gap-free attach resumption.
pub const DeltaTail = struct {
    tail: buffer.Tail,
    resumed: bool,
    truncated: bool,
};

const max_queued_prompts: usize = 8;
const max_queued_statuses: usize = 8;

const QueuedStatus = struct {
    status: vt_mod.AgentStatus,
    msg_buf: [vt_mod.osc.max_notification_bytes]u8 = undefined,
    msg_len: usize = 0,
};

/// Stack-allocated collector populated synchronously by `vt.Terminal.feed` while
/// `NativeSession.mutex` is held, then emitted after the mutex is released.
pub const OscCollector = struct {
    term: *const vt_mod.Terminal,
    has_title: bool = false,
    title_buf: [vt_mod.osc.max_title_bytes]u8 = undefined,
    title_len: usize = 0,
    has_cwd: bool = false,
    cwd_buf: [vt_mod.osc.max_cwd_bytes]u8 = undefined,
    cwd_len: usize = 0,
    prompts: [max_queued_prompts]vt_mod.osc.PromptChange = undefined,
    prompt_len: usize = 0,
    statuses: [max_queued_statuses]QueuedStatus = undefined,
    status_len: usize = 0,

    /// Construct a VT `EventCallback` bound to this collector.
    pub fn callback(self: *OscCollector) vt_mod.EventCallback {
        return .{ .ctx = self, .on_event = onVtEvent };
    }

    /// True if any OSC state changed during the fed chunk.
    pub fn anyChanged(self: *const OscCollector) bool {
        return self.has_title or self.has_cwd or self.prompt_len > 0 or self.status_len > 0;
    }

    fn onVtEvent(ctx: ?*anyopaque, event: vt_mod.VtEvent) void {
        const self: *OscCollector = @ptrCast(@alignCast(ctx orelse return));
        switch (event) {
            .title_changed => |title| {
                const n = @min(title.len, self.title_buf.len);
                @memcpy(self.title_buf[0..n], title[0..n]);
                self.title_len = n;
                self.has_title = true;
            },
            .cwd_changed => |cwd| {
                const n = @min(cwd.len, self.cwd_buf.len);
                @memcpy(self.cwd_buf[0..n], cwd[0..n]);
                self.cwd_len = n;
                self.has_cwd = true;
            },
            .prompt_changed => |prompt| {
                if (self.prompt_len < self.prompts.len) {
                    self.prompts[self.prompt_len] = prompt;
                    self.prompt_len += 1;
                } else {
                    self.prompts[self.prompts.len - 1] = prompt;
                }
            },
            .status_changed => |st| {
                const idx = if (self.status_len < self.statuses.len) blk: {
                    const pos = self.status_len;
                    self.status_len += 1;
                    break :blk pos;
                } else self.statuses.len - 1;
                const notif = self.term.osc.notification();
                const n = @min(notif.len, self.statuses[idx].msg_buf.len);
                self.statuses[idx].status = st;
                @memcpy(self.statuses[idx].msg_buf[0..n], notif[0..n]);
                self.statuses[idx].msg_len = n;
            },
            .clipboard_changed, .bell => {},
        }
    }

    /// Emit all collected OSC events through `native`'s sink without holding `mutex`.
    pub fn emitAll(self: *const OscCollector, native: *NativeSession) void {
        assert(self.title_len <= self.title_buf.len);
        assert(self.cwd_len <= self.cwd_buf.len);
        assert(self.prompt_len <= self.prompts.len);
        assert(self.status_len <= self.statuses.len);
        const gen = native.generation_value;
        if (self.has_title) {
            _ = events.emitOscEvent(native, .{ .pane_title_changed = .{
                .pane_id = native.id,
                .title = self.title_buf[0..self.title_len],
                .generation = gen,
            } });
        }
        if (self.has_cwd) {
            _ = events.emitOscEvent(native, .{ .pane_cwd_changed = .{
                .pane_id = native.id,
                .cwd = self.cwd_buf[0..self.cwd_len],
                .generation = gen,
            } });
        }
        for (self.prompts[0..self.prompt_len]) |prompt| {
            _ = events.emitOscEvent(native, .{ .pane_prompt_changed = .{
                .pane_id = native.id,
                .prompt_state = @tagName(prompt.state),
                .last_exit_code = prompt.exit_code,
                .command_seq = prompt.command_seq,
                .generation = gen,
            } });
        }
        for (self.statuses[0..self.status_len]) |st| {
            const msg: ?[]const u8 = if (st.msg_len > 0) st.msg_buf[0..st.msg_len] else null;
            _ = events.emitOscEvent(native, .{ .pane_status_changed = .{
                .pane_id = native.id,
                .status = @tagName(st.status),
                .message = msg,
                .generation = gen,
            } });
        }
    }
};

/// Feed `data` into `self.vt` while `self.mutex` is already held, collecting
/// any OSC events into `collector` so they can be emitted after unlocking.
pub fn feedVtLocked(self: *NativeSession, data: []const u8, collector: *OscCollector) void {
    assert(data.len > 0);
    assert(collector.term == &self.vt);
    self.vt.callback = collector.callback();
    defer self.vt.callback = null;
    self.vt.feed(data);
}

/// Compute semantic pane status from process state, OSC 7501/133, and output recency.
pub fn semanticStatus(self: *NativeSession) SemanticStatus {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return semanticStatusLocked(self);
}

/// Compute semantic status while `self.mutex` is already held.
pub fn semanticStatusLocked(self: *NativeSession) SemanticStatus {
    if (self.state_value.load(.monotonic) == .terminated) return .exited;
    switch (self.vt.osc.agent_status) {
        .waiting_for_input => return .waiting_for_input,
        .idle, .done => return .idle,
        .working => return .running,
        .unknown => {},
    }
    switch (self.vt.osc.prompt_state) {
        .prompt, .input => return .waiting_for_input,
        .running => return .running,
        .unknown => {},
    }
    if (self.last_output_ms) |last_ms| {
        if (session.monotonicMs(self) - last_ms >= root.activity_idle_ms) return .idle;
    } else {
        return .idle;
    }
    return .running;
}

/// Render the terminal viewport (and optional scrollback lines) as UTF-8 plain text.
pub fn plainText(self: *NativeSession, allocator: Allocator, opts: vt_mod.ScreenOptions) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    assert(self.vt.rows() >= 1 and self.vt.cols() >= 1);
    return vt_mod.renderPlainText(&self.vt, allocator, opts);
}

/// Render a self-contained ANSI/DEC restore sequence representing the current VT state.
pub fn ansiRestore(self: *NativeSession, allocator: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    assert(self.vt.rows() >= 1 and self.vt.cols() >= 1);
    return vt_mod.renderAnsiRestore(&self.vt, allocator);
}

/// Copy retained scrollback bytes from `from_offset` up to `endOffset`, bounded by
/// `max_bytes`. Reports `resumed = true` when `from_offset` is still retained and fits.
pub fn scrollbackSliceSince(
    self: *NativeSession,
    allocator: Allocator,
    from_offset: u64,
    max_bytes: usize,
) !DeltaTail {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const start_off = self.scrollback.startOffset();
    const end_off = self.scrollback.endOffset();
    assert(start_off <= end_off);

    if (from_offset >= start_off and from_offset <= end_off) {
        const avail: usize = @intCast(end_off - from_offset);
        if (avail <= max_bytes) {
            const bytes = try self.scrollback.view().copyRange(allocator, self.scrollback.len - avail);
            assert(bytes.len == avail);
            return .{
                .tail = .{ .bytes = bytes, .start_offset = from_offset, .end_offset = end_off },
                .resumed = true,
                .truncated = false,
            };
        }
        const tail = try self.scrollback.snapshotTail(allocator, max_bytes);
        return .{ .tail = tail, .resumed = false, .truncated = true };
    }
    const tail = try self.scrollback.snapshotTail(allocator, max_bytes);
    return .{ .tail = tail, .resumed = false, .truncated = true };
}

/// Return the current monotonic scrollback byte offset.
pub fn scrollbackEndOffset(self: *NativeSession) u64 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.scrollback.endOffset();
}

/// Deliver `sig` to the pane's foreground process group (or child process when
/// `to_group` is false) without terminating the pane itself.
pub fn sendSignal(self: *NativeSession, sig: std.posix.SIG, to_group: bool) !void {
    if (!self.isRunning()) return error.SessionTerminated;
    assert(self.handle.child_pid > 0);
    try self.handle.sendSignal(sig, to_group);
}

/// Write the opening `{` and all `NativeSession` JSON fields without the closing `}`.
pub fn writeInfoJsonFields(self: *NativeSession, writer: *std.Io.Writer) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    assert(self.id.len > 0);

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
    try writer.print(",\"scrollbackBytes\":{},\"exitStatus\":", .{self.scrollback.len});
    try writeOptionalU32(writer, self.exit_status);
    const exit: ExitInfo = session.exitInfoLocked(self) orelse .{ .exit_code = null, .signal = null };
    try writer.writeAll(",\"exitCode\":");
    try writeOptionalU32(writer, exit.exit_code);
    try writer.writeAll(",\"signal\":");
    try writeOptionalU32(writer, exit.signal);
    try writer.print(",\"generation\":{}", .{self.generation_value});
}

/// Serialize `NativeSession` metadata as a complete JSON object.
pub fn infoJson(self: *NativeSession, allocator: Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    errdefer out.deinit();
    try writeInfoJsonFields(self, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeOptionalU32(writer: *std.Io.Writer, value: ?u32) !void {
    if (value) |v| {
        try writer.print("{}", .{v});
    } else {
        try writer.writeAll("null");
    }
}

test "OscCollector captures title, cwd, prompt, and agent status safely" {
    var term = try vt_mod.Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 20 });
    defer term.deinit();
    var collector: OscCollector = .{ .term = &term };
    term.callback = collector.callback();
    term.feed("\x1b]2;editor\x07\x1b]7;file://host/work/dir\x07\x1b]133;C\x07\x1b]133;D;0\x07\x1b]7501;working;building\x07");
    term.callback = null;

    try std.testing.expect(collector.anyChanged());
    try std.testing.expect(collector.has_title);
    try std.testing.expectEqualStrings("editor", collector.title_buf[0..collector.title_len]);
    try std.testing.expect(collector.has_cwd);
    try std.testing.expectEqualStrings("/work/dir", collector.cwd_buf[0..collector.cwd_len]);
    try std.testing.expectEqual(@as(usize, 2), collector.prompt_len);
    try std.testing.expectEqual(@as(?i32, 0), collector.prompts[1].exit_code);
    try std.testing.expectEqual(@as(usize, 1), collector.status_len);
    try std.testing.expectEqual(vt_mod.AgentStatus.working, collector.statuses[0].status);
    try std.testing.expectEqualStrings("building", collector.statuses[0].msg_buf[0..collector.statuses[0].msg_len]);
}

const OscCapture = struct {
    rec: @import("harness.zig").Recorder = .{},
    mutex: std.Io.Mutex = .init,
    titles: usize = 0,
    cwds: usize = 0,
    prompts: usize = 0,
    statuses: usize = 0,
    last_exit: ?i32 = null,

    fn sink(self: *OscCapture) events.EventSink {
        return .{ .context = self, .emit = onEvent, .emit_osc = onOsc };
    }

    fn deinit(self: *OscCapture) void {
        self.rec.deinit();
    }

    fn onEvent(ctx: *anyopaque, ev: events.Event) void {
        const self: *OscCapture = @ptrCast(@alignCast(ctx));
        const rec_sink = self.rec.sink();
        rec_sink.emit(rec_sink.context, ev);
    }

    fn onOsc(ctx: *anyopaque, ev: events.OscEvent) void {
        const self: *OscCapture = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        switch (ev) {
            .pane_title_changed => self.titles += 1,
            .pane_cwd_changed => self.cwds += 1,
            .pane_prompt_changed => |p| {
                self.prompts += 1;
                self.last_exit = p.last_exit_code;
            },
            .pane_status_changed => self.statuses += 1,
        }
    }
};

test "NativeSession emits all four OSC callbacks, tracks semantic status, and serves delta scrollback" {
    const harness = @import("harness.zig");
    if (!harness.supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var osc_cap: OscCapture = .{};
    defer osc_cap.deinit();

    const native = try NativeSession.create(allocator, std.testing.io, .{
        .id = "vt-osc-test",
        .shell = "/bin/sh",
        .command = "printf '\\033]2;build\\007\\033]7;file://h/tmp\\007\\033]133;C\\007\\033]133;D;0\\007\\033]7501;waiting_for_input;approve\\007HI\\n'; sleep 30",
        .rows = 10,
        .cols = 40,
        .scrollback_bytes = 4096,
        .event_sink = osc_cap.sink(),
    });
    defer native.destroy();

    try osc_cap.rec.waitForOutput("HI", 5_000);
    try std.testing.expectEqual(SemanticStatus.waiting_for_input, native.semanticStatus());

    osc_cap.mutex.lockUncancelable(std.testing.io);
    const titles = osc_cap.titles;
    const cwds = osc_cap.cwds;
    const prompts = osc_cap.prompts;
    const statuses = osc_cap.statuses;
    const last_exit = osc_cap.last_exit;
    osc_cap.mutex.unlock(std.testing.io);
    try std.testing.expect(titles >= 1);
    try std.testing.expect(cwds >= 1);
    try std.testing.expect(prompts >= 2);
    try std.testing.expect(statuses >= 1);
    try std.testing.expectEqual(@as(?i32, 0), last_exit);

    const plain = try native.plainText(allocator, .{});
    defer allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "HI") != null);

    const restore = try native.ansiRestore(allocator);
    defer allocator.free(restore);
    try std.testing.expect(std.mem.indexOf(u8, restore, "HI") != null);

    const end_off = native.scrollbackEndOffset();
    const exact = try native.scrollbackSliceSince(allocator, end_off - 2, 1024);
    defer allocator.free(exact.tail.bytes);
    try std.testing.expect(exact.resumed and !exact.truncated);
    try std.testing.expectEqual(@as(usize, 2), exact.tail.bytes.len);

    const past = try native.scrollbackSliceSince(allocator, end_off + 99, 1024);
    defer allocator.free(past.tail.bytes);
    try std.testing.expect(!past.resumed and past.truncated);

    native.terminate();
    try std.testing.expectEqual(SemanticStatus.exited, native.semanticStatus());
}
