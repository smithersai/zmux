//! Condition-variable wait engine (`pane.wait`) and sentinel-framed command
//! execution (`pane.exec`) for `NativeSession`, with zero busy-spinning.

const std = @import("std");
const protocol = @import("../protocol.zig");
const vt_mod = @import("../vt.zig");
const sys = @import("../sys.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const NativeSession = session.NativeSession;

/// Maximum raw tail scanned per pattern check to keep `pane.wait` bounded.
const wait_scan_max_bytes: usize = 256 * 1024;
/// Upper bound on regex backtracking steps per call to prevent ReDoS.
const regex_max_steps: usize = 100_000;
/// Maximum captured output bytes returned by `pane.exec`.
pub const exec_capture_max_bytes: usize = 2 * 1024 * 1024;

/// Why `NativeSession.waitCondition` resolved.
pub const WaitReason = enum {
    pattern,
    exit,
    idle,
    prompt,
    status,
    timeout,

    /// Wire-format label matching OpenRPC `PaneWaitResult.reason`.
    pub fn label(self: WaitReason) []const u8 {
        return @tagName(self);
    }
};

/// Conditions awaited by `NativeSession.waitCondition`.
pub const WaitOptions = struct {
    pattern: ?[]const u8 = null,
    regex: bool = false,
    exit: bool = false,
    idle_ms: ?u64 = null,
    prompt_state: ?vt_mod.PromptState = null,
    agent_status: ?vt_mod.AgentStatus = null,
    command_done: bool = false,
    foreground_return: bool = false,
    timeout_ms: u64 = 30_000,
    /// Optional minimum scrollback offset for pattern matching.
    from_offset: ?u64 = null,
    /// Optional external stop flag (e.g. server shutdown / closed connection).
    stop_flag: ?*const std.atomic.Value(bool) = null,
};

/// Owned outcome of `NativeSession.waitCondition`.
pub const WaitResult = struct {
    matched: bool,
    reason: WaitReason,
    match_text: ?[]u8 = null,
    exit_code: ?u32 = null,
    signal: ?u32 = null,
    generation: u64 = 0,
    offset: u64 = 0,
    screen_text: []u8,

    /// Free owned string buffers.
    pub fn deinit(self: *WaitResult, allocator: Allocator) void {
        if (self.match_text) |m| allocator.free(m);
        allocator.free(self.screen_text);
        self.* = undefined;
    }
};

/// Owned outcome of `NativeSession.execInPane`.
pub const ExecResult = struct {
    exit_code: ?i32 = null,
    signal: ?u32 = null,
    output: []u8,
    timed_out: bool = false,
    duration_ms: u64 = 0,

    /// Release captured output bytes.
    pub fn deinit(self: *ExecResult, allocator: Allocator) void {
        allocator.free(self.output);
        self.* = undefined;
    }
};

var exec_nonce_counter: std.atomic.Value(u64) = .init(1);

/// Wait on `self.state_changed` until any requested condition in `opts` is met
/// or `opts.timeout_ms` elapses. Performs zero busy-spinning.
pub fn waitCondition(self: *NativeSession, allocator: Allocator, opts: WaitOptions) !WaitResult {
    assert(opts.timeout_ms >= 1);
    const start_ms = session.monotonicMs(self);
    const timeout_i64: i64 = @intCast(@min(opts.timeout_ms, @as(u64, std.math.maxInt(i64) / 2)));
    const deadline_ms = start_ms + timeout_i64;
    assert(deadline_ms >= start_ms);

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const initial_cmd_seq = self.vt.osc.command_seq;
    while (true) {
        if (try checkConditionsLocked(self, allocator, opts, start_ms, initial_cmd_seq)) |res| {
            return res;
        }
        const now_ms = session.monotonicMs(self);
        const stopped = self.input_stopped.load(.seq_cst) or
            (opts.stop_flag != null and opts.stop_flag.?.load(.seq_cst));
        if (stopped or now_ms >= deadline_ms) {
            return buildResultLocked(self, allocator, false, .timeout, null);
        }
        const sleep_ms = nextWakeMsLocked(self, opts, start_ms, now_ms, deadline_ms);
        assert(sleep_ms >= 1);
        self.state_changed.waitTimeout(self.io, &self.mutex, .{
            .duration = .{ .raw = .fromMilliseconds(sleep_ms), .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return buildResultLocked(self, allocator, false, .timeout, null),
        };
    }
}

fn nextWakeMsLocked(
    self: *const NativeSession,
    opts: WaitOptions,
    start_ms: i64,
    now_ms: i64,
    deadline_ms: i64,
) i64 {
    var wake_at = deadline_ms;
    if (opts.idle_ms) |idle_u64| {
        const idle_i64: i64 = @intCast(@min(idle_u64, @as(u64, std.math.maxInt(i64) / 2)));
        const ref_ms = self.last_output_ms orelse start_ms;
        wake_at = @min(wake_at, ref_ms + idle_i64);
    }
    if (opts.foreground_return) {
        wake_at = @min(wake_at, now_ms + 50);
    }
    return @max(@as(i64, 1), wake_at - now_ms);
}

fn checkConditionsLocked(
    self: *NativeSession,
    allocator: Allocator,
    opts: WaitOptions,
    start_ms: i64,
    initial_cmd_seq: u64,
) !?WaitResult {
    if (opts.exit and (self.stream_finalized.load(.seq_cst) or self.state_value.load(.monotonic) == .terminated)) {
        return try buildResultLocked(self, allocator, true, .exit, null);
    }
    if (opts.pattern) |pat| {
        if (try matchPaneTextLocked(self, allocator, pat, opts.regex, opts.from_offset)) |matched| {
            errdefer allocator.free(matched);
            return try buildResultLocked(self, allocator, true, .pattern, matched);
        }
    }
    if (opts.prompt_state) |want| {
        if (self.vt.osc.prompt_state == want) {
            return try buildResultLocked(self, allocator, true, .prompt, null);
        }
    }
    if (opts.command_done and
        self.vt.osc.command_seq > initial_cmd_seq and
        self.vt.osc.prompt_state != .running)
    {
        return try buildResultLocked(self, allocator, true, .prompt, null);
    }
    if (opts.agent_status) |want| {
        if (self.vt.osc.agent_status == want) {
            return try buildResultLocked(self, allocator, true, .status, null);
        }
    }
    if (opts.foreground_return) {
        const fg = self.handle.foregroundPgid();
        if (fg == self.handle.child_pid) {
            return try buildResultLocked(self, allocator, true, .prompt, null);
        }
    }
    if (opts.idle_ms) |idle_u64| {
        const idle_i64: i64 = @intCast(@min(idle_u64, @as(u64, std.math.maxInt(i64) / 2)));
        const ref_ms = self.last_output_ms orelse start_ms;
        if (session.monotonicMs(self) - ref_ms >= idle_i64) {
            return try buildResultLocked(self, allocator, true, .idle, null);
        }
    }
    return null;
}

fn buildResultLocked(
    self: *NativeSession,
    allocator: Allocator,
    matched: bool,
    reason: WaitReason,
    match_text: ?[]u8,
) !WaitResult {
    const screen_text = try vt_mod.renderPlainText(&self.vt, allocator, .{});
    const exit = session.exitInfoLocked(self);
    return .{
        .matched = matched,
        .reason = reason,
        .match_text = match_text,
        .exit_code = if (exit) |e| e.exit_code else null,
        .signal = if (exit) |e| e.signal else null,
        .generation = self.generation_value,
        .offset = self.scrollback.endOffset(),
        .screen_text = screen_text,
    };
}

fn matchPaneTextLocked(
    self: *NativeSession,
    allocator: Allocator,
    pattern: []const u8,
    use_regex: bool,
    from_offset: ?u64,
) !?[]u8 {
    if (pattern.len == 0) return try allocator.dupe(u8, "");
    const end_off = self.scrollback.endOffset();
    const start_off = self.scrollback.startOffset();
    const scan_from = if (from_offset) |off| @max(off, start_off) else start_off;
    if (end_off > scan_from) {
        const avail: usize = @intCast(@min(end_off - scan_from, wait_scan_max_bytes));
        const raw = try self.scrollback.view().copyRange(allocator, self.scrollback.len - avail);
        defer allocator.free(raw);
        if (findMatch(raw, pattern, use_regex)) |hit| {
            return try allocator.dupe(u8, hit);
        }
    }
    if (from_offset == null) {
        const plain = try vt_mod.renderPlainText(&self.vt, allocator, .{});
        defer allocator.free(plain);
        if (findMatch(plain, pattern, use_regex)) |hit| {
            return try allocator.dupe(u8, hit);
        }
    }
    return null;
}

/// Run `command` inside a live shell pane using split-printf sentinel framing so
/// PTY input echo never triggers false matches, then collect exit code and output.
pub fn execInPane(
    self: *NativeSession,
    allocator: Allocator,
    command: []const u8,
    timeout_ms: u64,
    capture_output: bool,
    stop_flag: ?*const std.atomic.Value(bool),
) !ExecResult {
    const trimmed = std.mem.trimEnd(u8, command, "\r\n");
    assert(trimmed.len > 0);
    if (!self.isRunning()) return error.SessionTerminated;

    const started_ms = session.monotonicMs(self);
    const nonce = exec_nonce_counter.fetchAdd(1, .monotonic) ^
        @as(u64, @truncate(@as(u96, @bitCast(std.Io.Clock.real.now(self.io).nanoseconds))));
    var start_tok: [32]u8 = undefined;
    var end_tok: [32]u8 = undefined;
    const s_part = try std.fmt.bufPrint(&start_tok, "S_{x:0>16}", .{nonce});
    const e_part = try std.fmt.bufPrint(&end_tok, "E_{x:0>16}", .{nonce});

    var start_marker_buf: [48]u8 = undefined;
    var end_prefix_buf: [48]u8 = undefined;
    const start_marker = try std.fmt.bufPrint(&start_marker_buf, "__ZMUX_{s}__", .{s_part});
    const end_prefix = try std.fmt.bufPrint(&end_prefix_buf, "__ZMUX_{s}:", .{e_part});
    assert(start_marker.len > 0 and end_prefix.len > 0);

    const start_offset = self.scrollbackEndOffset();
    const wrapped = try std.fmt.allocPrint(
        allocator,
        "printf '__ZMUX_%s__\\n' '{s}'; {s}; __zmux_ec=$?; printf '\\n__ZMUX_%s:%d__\\n' '{s}' \"$__zmux_ec\"",
        .{ s_part, trimmed, e_part },
    );
    defer allocator.free(wrapped);
    try self.send(wrapped, true);

    var end_pat_buf: [64]u8 = undefined;
    const end_pat = try std.fmt.bufPrint(&end_pat_buf, "{s}[0-9]+__", .{end_prefix});
    var waited = try waitCondition(self, allocator, .{
        .pattern = end_pat,
        .regex = true,
        .exit = true,
        .timeout_ms = timeout_ms,
        .from_offset = start_offset,
        .stop_flag = stop_flag,
    });
    defer waited.deinit(allocator);

    const elapsed: u64 = @intCast(@max(@as(i64, 0), session.monotonicMs(self) - started_ms));
    return extractExecResult(self, allocator, start_offset, start_marker, end_prefix, &waited, capture_output, elapsed);
}

fn extractExecResult(
    self: *NativeSession,
    allocator: Allocator,
    start_offset: u64,
    start_marker: []const u8,
    end_prefix: []const u8,
    waited: *const WaitResult,
    capture_output: bool,
    elapsed_ms: u64,
) !ExecResult {
    const delta = try self.scrollbackSliceSince(allocator, start_offset, exec_capture_max_bytes);
    defer allocator.free(delta.tail.bytes);
    const raw = delta.tail.bytes;

    var exit_code: ?i32 = if (waited.exit_code) |c| @intCast(c) else null;
    const end_idx = std.mem.indexOf(u8, raw, end_prefix);
    if (end_idx) |idx| {
        const after = raw[idx + end_prefix.len ..];
        if (std.mem.indexOf(u8, after, "__")) |close| {
            exit_code = std.fmt.parseInt(i32, after[0..close], 10) catch exit_code;
        }
    }

    const out_bytes = if (!capture_output)
        try allocator.alloc(u8, 0)
    else
        try sliceCommandBody(allocator, raw, start_marker, end_idx);
    return .{
        .exit_code = exit_code,
        .signal = waited.signal,
        .output = out_bytes,
        .timed_out = waited.reason == .timeout and end_idx == null,
        .duration_ms = elapsed_ms,
    };
}

fn sliceCommandBody(
    allocator: Allocator,
    raw: []const u8,
    start_marker: []const u8,
    end_idx: ?usize,
) ![]u8 {
    var body_start: usize = 0;
    if (std.mem.indexOf(u8, raw, start_marker)) |idx| {
        body_start = idx + start_marker.len;
        if (body_start < raw.len and raw[body_start] == '\r') body_start += 1;
        if (body_start < raw.len and raw[body_start] == '\n') body_start += 1;
    }
    var body_end = end_idx orelse raw.len;
    if (body_end < body_start) body_end = body_start;
    if (body_end > body_start and raw[body_end - 1] == '\n') body_end -= 1;
    if (body_end > body_start and raw[body_end - 1] == '\r') body_end -= 1;
    assert(body_start <= body_end and body_end <= raw.len);
    return allocator.dupe(u8, raw[body_start..body_end]);
}

/// Match `pattern` against `haystack` either as a literal substring or as a
/// bounded regular expression (`^`, `$`, `.`, `*`, `+`, `?`, `[...]`, `\d/\w/\s`).
pub fn findMatch(haystack: []const u8, pattern: []const u8, use_regex: bool) ?[]const u8 {
    if (!use_regex) {
        const pos = std.mem.indexOf(u8, haystack, pattern) orelse return null;
        assert(pos + pattern.len <= haystack.len);
        return haystack[pos .. pos + pattern.len];
    }
    var steps: usize = 0;
    if (pattern.len > 0 and pattern[0] == '^') {
        const end = matchHere(pattern[1..], haystack, 0, &steps) orelse return null;
        assert(end <= haystack.len);
        return haystack[0..end];
    }
    var start: usize = 0;
    while (start <= haystack.len) : (start += 1) {
        if (steps >= regex_max_steps) return null;
        if (matchHere(pattern, haystack, start, &steps)) |end| {
            assert(end >= start and end <= haystack.len);
            return haystack[start..end];
        }
    }
    return null;
}

fn matchHere(pat: []const u8, text: []const u8, pos: usize, steps: *usize) ?usize {
    if (steps.* >= regex_max_steps) return null;
    steps.* += 1;
    if (pat.len == 0) return pos;
    if (pat.len == 1 and pat[0] == '$') return if (pos == text.len) pos else null;

    const atom = parseAtom(pat);
    const rest = pat[atom.len..];
    if (rest.len > 0 and (rest[0] == '*' or rest[0] == '+' or rest[0] == '?')) {
        return matchQuantified(atom, rest[0], rest[1..], text, pos, steps);
    }
    if (pos < text.len and atomMatches(atom, text[pos])) {
        return matchHere(rest, text, pos + 1, steps);
    }
    return null;
}

fn matchQuantified(
    atom: Atom,
    quant: u8,
    rest: []const u8,
    text: []const u8,
    pos: usize,
    steps: *usize,
) ?usize {
    const min_rep: usize = if (quant == '+') 1 else 0;
    const max_rep: usize = if (quant == '?') 1 else text.len - pos;
    var matched: usize = 0;
    while (matched < max_rep and pos + matched < text.len and atomMatches(atom, text[pos + matched])) {
        matched += 1;
    }
    var take = matched;
    while (true) {
        if (take < min_rep) return null;
        if (matchHere(rest, text, pos + take, steps)) |end| return end;
        if (take == min_rep) return null;
        take -= 1;
    }
}

const Atom = struct {
    kind: enum { any, literal, digit, word, space, class },
    byte: u8 = 0,
    slice: []const u8 = "",
    len: usize = 1,
};

fn parseAtom(pat: []const u8) Atom {
    assert(pat.len > 0);
    if (pat[0] == '.') return .{ .kind = .any, .len = 1 };
    if (pat[0] == '\\' and pat.len >= 2) {
        return switch (pat[1]) {
            'd' => .{ .kind = .digit, .len = 2 },
            'w' => .{ .kind = .word, .len = 2 },
            's' => .{ .kind = .space, .len = 2 },
            else => .{ .kind = .literal, .byte = pat[1], .len = 2 },
        };
    }
    if (pat[0] == '[') {
        if (std.mem.indexOfScalarPos(u8, pat, 1, ']')) |close| {
            return .{ .kind = .class, .slice = pat[1..close], .len = close + 1 };
        }
    }
    return .{ .kind = .literal, .byte = pat[0], .len = 1 };
}

fn atomMatches(atom: Atom, b: u8) bool {
    return switch (atom.kind) {
        .any => b != '\n',
        .literal => b == atom.byte,
        .digit => std.ascii.isDigit(b),
        .word => std.ascii.isAlphanumeric(b) or b == '_',
        .space => std.ascii.isWhitespace(b),
        .class => classMatches(atom.slice, b),
    };
}

fn classMatches(spec: []const u8, b: u8) bool {
    const negate = spec.len > 0 and spec[0] == '^';
    const body = if (negate) spec[1..] else spec;
    var i: usize = 0;
    var hit = false;
    while (i < body.len) {
        if (i + 2 < body.len and body[i + 1] == '-') {
            if (b >= body[i] and b <= body[i + 2]) hit = true;
            i += 3;
        } else {
            if (b == body[i]) hit = true;
            i += 1;
        }
    }
    return if (negate) !hit else hit;
}

test "findMatch supports literal substring and bounded regex matching" {
    try std.testing.expectEqualStrings("world", findMatch("hello world", "world", false).?);
    try std.testing.expect(findMatch("hello", "xyz", false) == null);
    try std.testing.expectEqualStrings("code:42__", findMatch("xx code:42__ yy", "code:[0-9]+__", true).?);
    try std.testing.expectEqualStrings("abc", findMatch("abc123", "^[a-z]+", true).?);
    try std.testing.expect(findMatch("123abc", "^[a-z]+", true) == null);
    try std.testing.expectEqualStrings("99", findMatch("exit=99", "\\d+$", true).?);
}

test "waitCondition resolves pattern, regex, OSC prompt/status, idle, exit, and timeout" {
    const harness = @import("harness.zig");
    if (!harness.supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const native = try NativeSession.create(allocator, std.testing.io, .{
        .id = "wait-live-test",
        .shell = "/bin/sh",
        .command = "printf 'TOKEN_42\\n\\033]133;A\\007\\033]7501;done;ok\\007'; sleep 0.2; exit 3",
    });
    defer native.destroy();

    var pat = try native.waitCondition(allocator, .{ .pattern = "TOKEN_[0-9]+", .regex = true, .timeout_ms = 5_000 });
    defer pat.deinit(allocator);
    try std.testing.expect(pat.matched);
    try std.testing.expectEqual(WaitReason.pattern, pat.reason);
    try std.testing.expectEqualStrings("TOKEN_42", pat.match_text.?);

    var pr = try native.waitCondition(allocator, .{ .prompt_state = .prompt, .timeout_ms = 5_000 });
    defer pr.deinit(allocator);
    try std.testing.expect(pr.matched and pr.reason == .prompt);

    var st = try native.waitCondition(allocator, .{ .agent_status = .done, .timeout_ms = 5_000 });
    defer st.deinit(allocator);
    try std.testing.expect(st.matched and st.reason == .status);

    var ex = try native.waitCondition(allocator, .{ .exit = true, .timeout_ms = 5_000 });
    defer ex.deinit(allocator);
    try std.testing.expect(ex.matched and ex.reason == .exit);
    try std.testing.expectEqual(@as(?u32, 3), ex.exit_code);

    var to = try native.waitCondition(allocator, .{ .pattern = "NEVER_PRESENT", .timeout_ms = 20 });
    defer to.deinit(allocator);
    try std.testing.expect(!to.matched and to.reason == .timeout);
}

test "execInPane collects command exit code and stdout without input-echo false matches" {
    const harness = @import("harness.zig");
    if (!harness.supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    const native = try NativeSession.create(allocator, std.testing.io, .{
        .id = "exec-live-test",
        .shell = "/bin/sh",
        .env = &.{ "HOME=/nonexistent", "PS1=$ " },
    });
    defer native.destroy();

    var r0 = try native.execInPane(allocator, "printf 'HELLO_EXEC'", 5_000, true, null);
    defer r0.deinit(allocator);
    try std.testing.expect(!r0.timed_out);
    try std.testing.expectEqual(@as(?i32, 0), r0.exit_code);
    try std.testing.expectEqualStrings("HELLO_EXEC", r0.output);

    var r7 = try native.execInPane(allocator, "(exit 7)", 5_000, false, null);
    defer r7.deinit(allocator);
    try std.testing.expect(!r7.timed_out);
    try std.testing.expectEqual(@as(?i32, 7), r7.exit_code);
    try std.testing.expectEqual(@as(usize, 0), r7.output.len);
}
