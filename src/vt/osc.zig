//! Bounded OSC (Operating System Command) state handler for titles (OSC 0/2),
//! live CWD (OSC 7), clipboard (OSC 52), shell integration (OSC 133), and
//! agent semantic status / notifications (OSC 7501, OSC 9, OSC 777).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Maximum retained bytes for dynamic window/pane titles (OSC 0 / OSC 2).
pub const max_title_bytes: usize = 512;
/// Maximum retained bytes for percent-decoded CWD paths (OSC 7).
pub const max_cwd_bytes: usize = 4096;
/// Maximum retained bytes for OSC 52 base64 clipboard payloads.
pub const max_clipboard_bytes: usize = 64 * 1024;
/// Maximum retained bytes for OSC 52 clipboard selection target (e.g. `"c"`).
pub const max_clipboard_sel_bytes: usize = 16;
/// Maximum retained bytes for agent notification text (OSC 9 / OSC 777 / OSC 7501).
pub const max_notification_bytes: usize = 512;

/// Shell integration prompt lifecycle tracked via OSC 133 (FinalTerm/FTCS).
pub const PromptState = enum {
    unknown,
    prompt,
    input,
    running,
};

/// Semantic agent activity status tracked via OSC 7501, OSC 9;4, and OSC 777.
pub const AgentStatus = enum {
    unknown,
    idle,
    working,
    waiting_for_input,
    done,
};

/// Payload emitted when OSC 133 updates shell prompt or command status.
pub const PromptChange = struct {
    state: PromptState,
    exit_code: ?i32,
    command_seq: u64,
};

/// Payload emitted when OSC 52 updates the clipboard selection and data.
pub const ClipboardEvent = struct {
    selection: []const u8,
    data: []const u8,
};

/// Semantic terminal events delivered to an optional `EventCallback`.
pub const VtEvent = union(enum) {
    title_changed: []const u8,
    cwd_changed: []const u8,
    prompt_changed: PromptChange,
    status_changed: AgentStatus,
    clipboard_changed: ClipboardEvent,
    bell: void,
};

/// Optional callback hook invoked synchronously on OSC and bell events.
pub const EventCallback = struct {
    ctx: ?*anyopaque = null,
    on_event: *const fn (ctx: ?*anyopaque, event: VtEvent) void,

    /// Invoke `self` with `event` when a callback is configured.
    pub fn emit(self: ?EventCallback, event: VtEvent) void {
        if (self) |cb| cb.on_event(cb.ctx, event);
    }
};

/// Bounded OSC metadata store owned by `Terminal`.
pub const OscState = struct {
    allocator: Allocator,
    title_buf: [max_title_bytes]u8 = undefined,
    title_len: usize = 0,
    notif_buf: [max_notification_bytes]u8 = undefined,
    notif_len: usize = 0,
    clip_sel_buf: [max_clipboard_sel_bytes]u8 = undefined,
    clip_sel_len: usize = 0,
    cwd_buf: []u8 = &.{},
    cwd_len: usize = 0,
    clip_buf: []u8 = &.{},
    clip_len: usize = 0,
    /// Current OSC 133 shell prompt phase.
    prompt_state: PromptState = .unknown,
    /// Exit status reported by the most recent OSC 133;D command completion.
    last_command_exit: ?i32 = null,
    /// Monotonic counter incremented on each OSC 133;C command start.
    command_seq: u64 = 0,
    /// Current agent semantic status (OSC 7501 / OSC 9;4 / OSC 777).
    agent_status: AgentStatus = .unknown,
    /// Number of dynamic OSC updates dropped due to allocator OOM.
    oom_drops: u64 = 0,

    /// Initialize an empty `OscState` using `allocator` for lazy large fields.
    pub fn init(allocator: Allocator) OscState {
        return .{ .allocator = allocator };
    }

    /// Free any lazily allocated CWD or clipboard buffers.
    pub fn deinit(self: *OscState) void {
        assert(self.cwd_len <= self.cwd_buf.len);
        assert(self.clip_len <= self.clip_buf.len);
        if (self.cwd_buf.len > 0) self.allocator.free(self.cwd_buf);
        if (self.clip_buf.len > 0) self.allocator.free(self.clip_buf);
        self.cwd_buf = &.{};
        self.clip_buf = &.{};
        self.reset();
    }

    /// Clear all retained OSC state without releasing already-owned capacity.
    pub fn reset(self: *OscState) void {
        self.title_len = 0;
        self.notif_len = 0;
        self.clip_sel_len = 0;
        self.cwd_len = 0;
        self.clip_len = 0;
        self.prompt_state = .unknown;
        self.last_command_exit = null;
        self.command_seq = 0;
        self.agent_status = .unknown;
        assert(self.title_len == 0 and self.cwd_len == 0);
    }

    /// Return the current dynamic window/pane title (valid UTF-8, `<= 512 B`).
    pub fn title(self: *const OscState) []const u8 {
        assert(self.title_len <= max_title_bytes);
        return self.title_buf[0..self.title_len];
    }

    /// Return the current working directory from OSC 7 (valid UTF-8, `<= 4096 B`).
    pub fn cwd(self: *const OscState) []const u8 {
        assert(self.cwd_len <= self.cwd_buf.len);
        return self.cwd_buf[0..self.cwd_len];
    }

    /// Return the last OSC 52 selection target (e.g. `"c"`).
    pub fn clipboardSelection(self: *const OscState) []const u8 {
        assert(self.clip_sel_len <= max_clipboard_sel_bytes);
        return self.clip_sel_buf[0..self.clip_sel_len];
    }

    /// Return the last OSC 52 base64 clipboard payload (`<= 64 KiB`).
    pub fn clipboardData(self: *const OscState) []const u8 {
        assert(self.clip_len <= self.clip_buf.len);
        return self.clip_buf[0..self.clip_len];
    }

    /// Return the most recent notification text from OSC 9 / 777 / 7501.
    pub fn notification(self: *const OscState) []const u8 {
        assert(self.notif_len <= max_notification_bytes);
        return self.notif_buf[0..self.notif_len];
    }

    /// Dispatch a raw OSC payload (without leading `ESC ]` or trailing ST/BEL).
    pub fn handle(self: *OscState, payload: []const u8, cb: ?EventCallback) void {
        const sep = std.mem.indexOfScalar(u8, payload, ';') orelse return;
        const code = std.fmt.parseInt(u16, payload[0..sep], 10) catch return;
        const body = payload[sep + 1 ..];
        switch (code) {
            0, 2 => self.handleTitle(body, cb),
            7 => self.handleCwd(body, cb),
            9 => self.handleOsc9(body, cb),
            52 => self.handleClipboard(body, cb),
            133 => self.handlePrompt(body, cb),
            777 => self.handleOsc777(body, cb),
            7501 => self.handleAgentStatus(body, cb),
            else => {},
        }
    }

    fn handleTitle(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        self.title_len = sanitizeUtf8Into(&self.title_buf, body);
        assert(self.title_len <= max_title_bytes);
        assert(std.unicode.utf8ValidateSlice(self.title()));
        EventCallback.emit(cb, .{ .title_changed = self.title() });
    }

    fn handleCwd(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        if (body.len < 7 or !std.ascii.eqlIgnoreCase(body[0..7], "file://")) return;
        const after_scheme = body[7..];
        const path_idx = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return;
        const raw_path = after_scheme[path_idx..];

        var decoded: [max_cwd_bytes]u8 = undefined;
        const dec_len = percentDecodeInto(&decoded, raw_path);
        var clean: [max_cwd_bytes]u8 = undefined;
        const clean_len = sanitizeUtf8Into(&clean, decoded[0..dec_len]);

        if (!self.storeDynamic(&self.cwd_buf, &self.cwd_len, clean[0..clean_len], max_cwd_bytes)) return;
        assert(std.unicode.utf8ValidateSlice(self.cwd()));
        EventCallback.emit(cb, .{ .cwd_changed = self.cwd() });
    }

    fn handleClipboard(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        const sep = std.mem.indexOfScalar(u8, body, ';') orelse return;
        const sel = body[0..sep];
        const data = body[sep + 1 ..];
        if (std.mem.eql(u8, data, "?")) return;

        var clean_sel_len: usize = 0;
        for (sel) |b| {
            if (clean_sel_len >= max_clipboard_sel_bytes) break;
            if (b >= 0x20 and b <= 0x7E) {
                self.clip_sel_buf[clean_sel_len] = b;
                clean_sel_len += 1;
            }
        }
        const bounded_len = @min(data.len, max_clipboard_bytes);
        if (!self.ensureCap(&self.clip_buf, bounded_len, max_clipboard_bytes)) return;
        var out_len: usize = 0;
        for (data[0..bounded_len]) |b| {
            if (b > 0x20 and b <= 0x7E) {
                self.clip_buf[out_len] = b;
                out_len += 1;
            }
        }
        self.clip_sel_len = clean_sel_len;
        self.clip_len = out_len;
        assert(self.clip_len <= max_clipboard_bytes);
        EventCallback.emit(cb, .{ .clipboard_changed = .{
            .selection = self.clipboardSelection(),
            .data = self.clipboardData(),
        } });
    }

    fn handlePrompt(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        if (body.len == 0) return;
        const sep = std.mem.indexOfScalar(u8, body, ';');
        const tag = if (sep) |idx| body[0..idx] else body;
        const rest = if (sep) |idx| body[idx + 1 ..] else "";
        if (tag.len == 0) return;

        switch (tag[0]) {
            'A' => self.prompt_state = .prompt,
            'B' => self.prompt_state = .input,
            'C' => {
                self.prompt_state = .running;
                self.command_seq += 1;
            },
            'D' => {
                self.prompt_state = .unknown;
                const code_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                const code_slice = rest[0..code_end];
                self.last_command_exit = if (code_slice.len > 0)
                    std.fmt.parseInt(i32, code_slice, 10) catch null
                else
                    null;
            },
            else => return,
        }
        EventCallback.emit(cb, .{ .prompt_changed = .{
            .state = self.prompt_state,
            .exit_code = self.last_command_exit,
            .command_seq = self.command_seq,
        } });
    }

    fn handleAgentStatus(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        const sep = std.mem.indexOfScalar(u8, body, ';');
        const token = std.mem.trim(u8, if (sep) |idx| body[0..idx] else body, " \t");
        const parsed = parseAgentStatus(token) orelse return;
        self.agent_status = parsed;
        if (sep) |idx| {
            self.notif_len = sanitizeUtf8Into(&self.notif_buf, body[idx + 1 ..]);
        }
        EventCallback.emit(cb, .{ .status_changed = self.agent_status });
    }

    fn handleOsc9(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        if (std.mem.startsWith(u8, body, "4;")) {
            const rest = body[2..];
            const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            const state_num = std.fmt.parseInt(u8, rest[0..end], 10) catch return;
            self.agent_status = switch (state_num) {
                0 => .idle,
                1, 3 => .working,
                2 => .done,
                4 => .waiting_for_input,
                else => return,
            };
            EventCallback.emit(cb, .{ .status_changed = self.agent_status });
            return;
        }
        self.notif_len = sanitizeUtf8Into(&self.notif_buf, body);
        assert(self.notif_len <= max_notification_bytes);
    }

    fn handleOsc777(self: *OscState, body: []const u8, cb: ?EventCallback) void {
        const sep = std.mem.indexOfScalar(u8, body, ';') orelse return;
        const verb = body[0..sep];
        const rest = body[sep + 1 ..];
        if (std.ascii.eqlIgnoreCase(verb, "status")) {
            self.handleAgentStatus(rest, cb);
            return;
        }
        if (!std.ascii.eqlIgnoreCase(verb, "notify")) return;
        if (std.mem.indexOfScalar(u8, rest, ';')) |split| {
            const head = rest[0..split];
            const msg = rest[split + 1 ..];
            if (head.len == 0) {
                self.notif_len = sanitizeUtf8Into(&self.notif_buf, msg);
                return;
            }
            const first = sanitizeUtf8Into(&self.notif_buf, head);
            if (first + 2 < max_notification_bytes and msg.len > 0) {
                self.notif_buf[first] = ':';
                self.notif_buf[first + 1] = ' ';
                const rem = sanitizeUtf8Into(self.notif_buf[first + 2 ..], msg);
                self.notif_len = first + 2 + rem;
            } else {
                self.notif_len = first;
            }
        } else {
            self.notif_len = sanitizeUtf8Into(&self.notif_buf, rest);
        }
        assert(self.notif_len <= max_notification_bytes);
    }

    fn ensureCap(self: *OscState, buf: *[]u8, needed: usize, max_cap: usize) bool {
        assert(needed <= max_cap);
        if (needed <= buf.len) return true;
        const alloc_len = @min(@max(needed, 128), max_cap);
        const next = self.allocator.alloc(u8, alloc_len) catch {
            self.oom_drops += 1;
            return false;
        };
        if (buf.len > 0) self.allocator.free(buf.*);
        buf.* = next;
        assert(buf.len >= needed and buf.len <= max_cap);
        return true;
    }

    fn storeDynamic(self: *OscState, buf: *[]u8, len_out: *usize, src: []const u8, max_cap: usize) bool {
        assert(src.len <= max_cap);
        if (!self.ensureCap(buf, src.len, max_cap)) return false;
        @memcpy(buf.*[0..src.len], src);
        len_out.* = src.len;
        return true;
    }
};

fn parseAgentStatus(token: []const u8) ?AgentStatus {
    const val = if (std.mem.startsWith(u8, token, "status=")) token[7..] else token;
    if (std.ascii.eqlIgnoreCase(val, "idle")) return .idle;
    if (std.ascii.eqlIgnoreCase(val, "working") or
        std.ascii.eqlIgnoreCase(val, "running") or
        std.ascii.eqlIgnoreCase(val, "busy")) return .working;
    if (std.ascii.eqlIgnoreCase(val, "waiting_for_input") or
        std.ascii.eqlIgnoreCase(val, "waiting") or
        std.ascii.eqlIgnoreCase(val, "needs_input") or
        std.ascii.eqlIgnoreCase(val, "input")) return .waiting_for_input;
    if (std.ascii.eqlIgnoreCase(val, "done") or
        std.ascii.eqlIgnoreCase(val, "complete") or
        std.ascii.eqlIgnoreCase(val, "completed")) return .done;
    if (std.ascii.eqlIgnoreCase(val, "unknown") or
        std.ascii.eqlIgnoreCase(val, "clear")) return .unknown;
    return null;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn percentDecodeInto(dst: []u8, src: []const u8) usize {
    var i: usize = 0;
    var out: usize = 0;
    while (i < src.len and out < dst.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            if (hexNibble(src[i + 1])) |hi| {
                if (hexNibble(src[i + 2])) |lo| {
                    dst[out] = (hi << 4) | lo;
                    out += 1;
                    i += 3;
                    continue;
                }
            }
        }
        dst[out] = src[i];
        out += 1;
        i += 1;
    }
    assert(out <= dst.len);
    return out;
}

/// Copy valid non-control UTF-8 codepoints from `src` into `dst`, dropping C0/DEL
/// controls and replacing malformed UTF-8 sequences without splitting codepoints.
pub fn sanitizeUtf8Into(dst: []u8, src: []const u8) usize {
    var i: usize = 0;
    var out: usize = 0;
    while (i < src.len and out < dst.len) {
        const b = src[i];
        if (b < 0x20 or b == 0x7F) {
            i += 1;
            continue;
        }
        if (b < 0x80) {
            dst[out] = b;
            out += 1;
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 0;
        if (seq_len == 0 or i + seq_len > src.len or !std.unicode.utf8ValidateSlice(src[i .. i + seq_len])) {
            if (out + 3 <= dst.len) {
                @memcpy(dst[out .. out + 3], "\u{FFFD}");
                out += 3;
            }
            i += 1;
            continue;
        }
        if (out + seq_len > dst.len) break;
        @memcpy(dst[out .. out + seq_len], src[i .. i + seq_len]);
        out += seq_len;
        i += seq_len;
    }
    assert(out <= dst.len);
    assert(std.unicode.utf8ValidateSlice(dst[0..out]));
    return out;
}

test "OSC 0/2 title sanitization and UTF-8 truncation bound" {
    var osc = OscState.init(std.testing.allocator);
    defer osc.deinit();

    osc.handle("2;vim\x07 \x1bhello\xff世界", null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(osc.title()));
    try std.testing.expectEqualStrings("vim hello\u{FFFD}世界", osc.title());

    var huge: [700]u8 = undefined;
    @memset(&huge, 'x');
    huge[0] = '0';
    huge[1] = ';';
    osc.handle(&huge, null);
    try std.testing.expectEqual(max_title_bytes, osc.title().len);
}

test "OSC 7 percent-decodes CWD and OSC 52 stores clipboard" {
    var osc = OscState.init(std.testing.allocator);
    defer osc.deinit();

    osc.handle("7;file://macbook.local/Users/will/my%20repo%2Fsub", null);
    try std.testing.expectEqualStrings("/Users/will/my repo/sub", osc.cwd());

    osc.handle("52;c;SGVsbG8=", null);
    try std.testing.expectEqualStrings("c", osc.clipboardSelection());
    try std.testing.expectEqualStrings("SGVsbG8=", osc.clipboardData());

    // Query '?' must not overwrite stored clipboard data.
    osc.handle("52;c;?", null);
    try std.testing.expectEqualStrings("SGVsbG8=", osc.clipboardData());
}

test "OSC 133 shell integration, OSC 7501/9/777 status, and EventCallback" {
    const Recorder = struct {
        events: usize = 0,
        last_status: AgentStatus = .unknown,
        last_prompt: PromptState = .unknown,
        fn onEvent(ctx: ?*anyopaque, ev: VtEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events += 1;
            switch (ev) {
                .status_changed => |s| self.last_status = s,
                .prompt_changed => |p| self.last_prompt = p.state,
                else => {},
            }
        }
    };
    var rec: Recorder = .{};
    const cb: EventCallback = .{ .ctx = &rec, .on_event = Recorder.onEvent };

    var osc = OscState.init(std.testing.allocator);
    defer osc.deinit();

    osc.handle("133;A", cb);
    osc.handle("133;B", cb);
    osc.handle("133;C", cb);
    osc.handle("133;D;42", cb);
    try std.testing.expectEqual(@as(u64, 1), osc.command_seq);
    try std.testing.expectEqual(@as(?i32, 42), osc.last_command_exit);
    try std.testing.expectEqual(PromptState.unknown, osc.prompt_state);

    osc.handle("7501;working;compiling", cb);
    try std.testing.expectEqual(AgentStatus.working, osc.agent_status);
    try std.testing.expectEqualStrings("compiling", osc.notification());
    osc.handle("9;4;4;50", cb);
    try std.testing.expectEqual(AgentStatus.waiting_for_input, osc.agent_status);
    osc.handle("777;notify;Build;Passed", cb);
    try std.testing.expectEqualStrings("Build: Passed", osc.notification());
    try std.testing.expectEqual(@as(usize, 6), rec.events);
}
