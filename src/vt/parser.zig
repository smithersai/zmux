//! Streaming Paul Williams / VT500 escape sequence state machine and
//! chunk-boundary-safe UTF-8 decoder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const style_mod = @import("style.zig");

const SgrParam = style_mod.SgrParam;
const max_subparams = style_mod.max_subparams;

/// Maximum number of semicolon-separated CSI parameters parsed per sequence.
pub const max_csi_params: usize = 16;
/// Maximum number of intermediate bytes (`0x20..0x2F`) retained per sequence.
pub const max_intermediates: usize = 4;
/// Maximum retained OSC payload size (64 KiB clipboard + OSC 52 header overhead).
pub const max_osc_bytes: usize = 64 * 1024 + 64;

/// VT500 parser state machine states.
pub const State = enum(u8) {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    dcs_ignore,
};

/// Decoded CSI dispatch payload delivered to the terminal handler.
pub const CsiEvent = struct {
    params: []const SgrParam,
    intermediates: []const u8,
    private: u8,
    final: u8,

    /// Return parameter `index`, substituting `default_val` when omitted or zero.
    pub fn param(self: CsiEvent, index: usize, default_val: u16) u16 {
        if (index >= self.params.len) return default_val;
        const v = self.params[index].value;
        return if (v == 0) default_val else v;
    }

    /// Return parameter `index`, substituting `default_val` only when omitted.
    pub fn rawParam(self: CsiEvent, index: usize, default_val: u16) u16 {
        if (index >= self.params.len) return default_val;
        return self.params[index].value;
    }
};

/// Streaming VT500 + UTF-8 parser. Chunk splitting at any byte boundary yields
/// identical dispatched actions.
pub const Parser = struct {
    state: State = .ground,
    utf8_buf: [4]u8 = @splat(0),
    utf8_len: u8 = 0,
    utf8_expected: u8 = 0,
    csi_params: [max_csi_params]SgrParam = @splat(SgrParam{}),
    csi_param_count: u8 = 0,
    csi_cur: SgrParam = .{},
    csi_has_digits: bool = false,
    csi_in_subparam: bool = false,
    csi_sub_overflow: bool = false,
    csi_private: u8 = 0,
    intermediates: [max_intermediates]u8 = @splat(0),
    intermediate_len: u8 = 0,
    osc_buf: std.ArrayList(u8) = .empty,
    osc_overflow: bool = false,
    esc_pending: bool = false,
    oom_drops: u64 = 0,

    /// Release the lazily grown OSC buffer.
    pub fn deinit(self: *Parser, allocator: Allocator) void {
        assert(self.utf8_len <= self.utf8_expected);
        self.osc_buf.deinit(allocator);
        self.* = .{};
    }

    /// Reset parser state back to `.ground`, keeping existing OSC capacity.
    pub fn reset(self: *Parser) void {
        self.state = .ground;
        self.utf8_len = 0;
        self.utf8_expected = 0;
        self.clearCsi();
        self.intermediate_len = 0;
        self.osc_buf.clearRetainingCapacity();
        self.osc_overflow = false;
        self.esc_pending = false;
        assert(self.state == .ground and self.utf8_expected == 0);
    }

    /// Feed an arbitrary byte slice into the parser, invoking `handler` callbacks:
    /// `print(u21)`, `execute(u8)`, `escDispatch([]const u8, u8)`,
    /// `csiDispatch(CsiEvent)`, and `oscDispatch([]const u8)`.
    pub fn feed(self: *Parser, allocator: Allocator, bytes: []const u8, handler: anytype) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.state == .ground and self.utf8_expected == 0) {
                while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x7E) : (i += 1) {
                    handler.print(bytes[i]);
                }
                if (i >= bytes.len) break;
            }
            self.step(allocator, bytes[i], handler);
            i += 1;
        }
        assert(self.utf8_len <= self.utf8_expected);
        assert(self.csi_param_count <= max_csi_params);
        assert(self.intermediate_len <= max_intermediates);
    }

    fn step(self: *Parser, allocator: Allocator, byte: u8, handler: anytype) void {
        if (self.state == .osc_string) {
            self.stepOsc(allocator, byte, handler);
            return;
        }
        if (self.state == .dcs_ignore) {
            self.stepDcsIgnore(byte, handler);
            return;
        }
        if (self.state == .ground and self.utf8_expected > 0) {
            if ((byte & 0xC0) == 0x80) {
                self.advanceUtf8(byte, handler);
                return;
            }
            self.flushIncompleteUtf8(handler);
        }
        if (byte == 0x18 or byte == 0x1A) {
            self.state = .ground;
            self.clearCsi();
            self.intermediate_len = 0;
            return;
        }
        if (byte == 0x1B) {
            self.state = .escape;
            self.intermediate_len = 0;
            return;
        }
        if (byte < 0x20) {
            handler.execute(byte);
            return;
        }
        if (byte == 0x7F) return;

        switch (self.state) {
            .ground => self.stepGround(byte, handler),
            .escape => self.stepEscape(byte, handler),
            .escape_intermediate => self.stepEscapeIntermediate(byte, handler),
            .csi_entry => self.stepCsiEntry(byte, handler),
            .csi_param => self.stepCsiParam(byte, handler),
            .csi_intermediate => self.stepCsiIntermediate(byte, handler),
            .csi_ignore => {
                if (byte >= 0x40 and byte <= 0x7E) self.state = .ground;
            },
            .osc_string, .dcs_ignore => {},
        }
    }

    fn stepGround(self: *Parser, byte: u8, handler: anytype) void {
        assert(self.utf8_expected == 0);
        if (byte >= 0x20 and byte <= 0x7E) {
            handler.print(byte);
            return;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (seq_len >= 2 and seq_len <= 4) {
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = @intCast(seq_len);
            assert(self.utf8_len < self.utf8_expected);
        } else {
            handler.print(0xFFFD);
        }
    }

    fn advanceUtf8(self: *Parser, byte: u8, handler: anytype) void {
        assert(self.utf8_expected >= 2 and self.utf8_expected <= 4);
        assert(self.utf8_len < self.utf8_expected);
        self.utf8_buf[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len == self.utf8_expected) {
            const len = self.utf8_expected;
            self.utf8_len = 0;
            self.utf8_expected = 0;
            const cp = std.unicode.utf8Decode(self.utf8_buf[0..len]) catch 0xFFFD;
            handler.print(cp);
        }
    }

    fn flushIncompleteUtf8(self: *Parser, handler: anytype) void {
        assert(self.utf8_expected > 0);
        self.utf8_len = 0;
        self.utf8_expected = 0;
        handler.print(0xFFFD);
    }

    fn stepEscape(self: *Parser, byte: u8, handler: anytype) void {
        if (byte >= 0x20 and byte <= 0x2F) {
            self.pushIntermediate(byte);
            self.state = .escape_intermediate;
            return;
        }
        switch (byte) {
            '[' => {
                self.clearCsi();
                self.intermediate_len = 0;
                self.state = .csi_entry;
            },
            ']' => {
                self.osc_buf.clearRetainingCapacity();
                self.osc_overflow = false;
                self.esc_pending = false;
                self.state = .osc_string;
            },
            'P', '_', '^', 'X' => {
                self.esc_pending = false;
                self.state = .dcs_ignore;
            },
            else => {
                if (byte >= 0x30 and byte <= 0x7E) {
                    handler.escDispatch(self.intermediates[0..self.intermediate_len], byte);
                }
                self.state = .ground;
            },
        }
    }

    fn stepEscapeIntermediate(self: *Parser, byte: u8, handler: anytype) void {
        if (byte >= 0x20 and byte <= 0x2F) {
            self.pushIntermediate(byte);
            return;
        }
        if (byte >= 0x30 and byte <= 0x7E) {
            handler.escDispatch(self.intermediates[0..self.intermediate_len], byte);
        }
        self.state = .ground;
    }

    fn stepCsiEntry(self: *Parser, byte: u8, handler: anytype) void {
        switch (byte) {
            0x20...0x2F => {
                self.pushIntermediate(byte);
                self.state = .csi_intermediate;
            },
            0x30...0x39 => {
                self.state = .csi_param;
                self.accumulateDigit(byte - '0');
            },
            ':' => {
                self.state = .csi_param;
                self.beginSubparam();
            },
            ';' => {
                self.state = .csi_param;
                self.commitParam();
            },
            0x3C...0x3F => {
                self.csi_private = byte;
                self.state = .csi_param;
            },
            0x40...0x7E => self.finishCsi(byte, handler),
            else => self.state = .csi_ignore,
        }
    }

    fn stepCsiParam(self: *Parser, byte: u8, handler: anytype) void {
        switch (byte) {
            0x20...0x2F => {
                if (self.csi_has_digits) self.commitParam();
                self.pushIntermediate(byte);
                self.state = .csi_intermediate;
            },
            0x30...0x39 => self.accumulateDigit(byte - '0'),
            ':' => self.beginSubparam(),
            ';' => self.commitParam(),
            0x3C...0x3F => self.state = .csi_ignore,
            0x40...0x7E => {
                if (self.csi_has_digits) self.commitParam();
                self.finishCsi(byte, handler);
            },
            else => self.state = .csi_ignore,
        }
    }

    fn stepCsiIntermediate(self: *Parser, byte: u8, handler: anytype) void {
        if (byte >= 0x20 and byte <= 0x2F) {
            self.pushIntermediate(byte);
            return;
        }
        if (byte >= 0x40 and byte <= 0x7E) {
            self.finishCsi(byte, handler);
            return;
        }
        self.state = .csi_ignore;
    }

    fn stepOsc(self: *Parser, allocator: Allocator, byte: u8, handler: anytype) void {
        if (self.esc_pending) {
            self.esc_pending = false;
            if (byte == '\\') {
                self.finishOsc(handler);
                return;
            }
            self.state = .escape;
            self.intermediate_len = 0;
            self.step(allocator, byte, handler);
            return;
        }
        if (byte == 0x07) {
            self.finishOsc(handler);
            return;
        }
        if (byte == 0x1B) {
            self.esc_pending = true;
            return;
        }
        if (byte == 0x18 or byte == 0x1A) {
            self.osc_buf.clearRetainingCapacity();
            self.osc_overflow = false;
            self.state = .ground;
            return;
        }
        if (byte < 0x20 or byte == 0x7F or self.osc_overflow) return;
        if (self.osc_buf.items.len >= max_osc_bytes) {
            self.osc_overflow = true;
            return;
        }
        self.osc_buf.append(allocator, byte) catch {
            self.oom_drops += 1;
            self.osc_overflow = true;
        };
    }

    fn stepDcsIgnore(self: *Parser, byte: u8, handler: anytype) void {
        _ = handler;
        if (self.esc_pending) {
            self.esc_pending = false;
            if (byte == '\\') {
                self.state = .ground;
                return;
            }
            if (byte == 0x1B) {
                self.esc_pending = true;
            }
            return;
        }
        if (byte == 0x1B) {
            self.esc_pending = true;
        } else if (byte == 0x18 or byte == 0x1A) {
            self.state = .ground;
        }
    }

    fn finishOsc(self: *Parser, handler: anytype) void {
        self.state = .ground;
        self.esc_pending = false;
        if (!self.osc_overflow) {
            handler.oscDispatch(self.osc_buf.items);
        }
        self.osc_buf.clearRetainingCapacity();
        self.osc_overflow = false;
    }

    fn finishCsi(self: *Parser, final: u8, handler: anytype) void {
        assert(self.csi_param_count <= max_csi_params);
        assert(self.intermediate_len <= max_intermediates);
        const ev: CsiEvent = .{
            .params = self.csi_params[0..self.csi_param_count],
            .intermediates = self.intermediates[0..self.intermediate_len],
            .private = self.csi_private,
            .final = final,
        };
        self.state = .ground;
        handler.csiDispatch(ev);
    }

    fn clearCsi(self: *Parser) void {
        self.csi_param_count = 0;
        self.csi_cur = .{};
        self.csi_has_digits = false;
        self.csi_in_subparam = false;
        self.csi_sub_overflow = false;
        self.csi_private = 0;
    }

    fn accumulateDigit(self: *Parser, digit: u8) void {
        assert(digit <= 9);
        self.csi_has_digits = true;
        if (!self.csi_in_subparam) {
            self.csi_cur.value = self.csi_cur.value *| 10 +| digit;
            return;
        }
        if (self.csi_sub_overflow or self.csi_cur.sub_count == 0) return;
        const idx = self.csi_cur.sub_count - 1;
        assert(idx < max_subparams);
        self.csi_cur.subs[idx] = self.csi_cur.subs[idx] *| 10 +| digit;
    }

    fn beginSubparam(self: *Parser) void {
        self.csi_has_digits = true;
        self.csi_in_subparam = true;
        if (self.csi_cur.sub_count < max_subparams) {
            self.csi_cur.subs[self.csi_cur.sub_count] = 0;
            self.csi_cur.sub_count += 1;
        } else {
            self.csi_sub_overflow = true;
        }
    }

    fn commitParam(self: *Parser) void {
        if (self.csi_param_count < max_csi_params) {
            self.csi_params[self.csi_param_count] = self.csi_cur;
            self.csi_param_count += 1;
        }
        self.csi_cur = .{};
        self.csi_in_subparam = false;
        self.csi_sub_overflow = false;
        self.csi_has_digits = true;
    }

    fn pushIntermediate(self: *Parser, byte: u8) void {
        if (self.intermediate_len < max_intermediates) {
            self.intermediates[self.intermediate_len] = byte;
            self.intermediate_len += 1;
        }
    }
};

test "Parser splits UTF-8 codepoints and CSI/OSC sequences across 1-byte chunks" {
    const Sink = struct {
        prints: std.ArrayList(u21) = .empty,
        csi_count: usize = 0,
        last_csi_final: u8 = 0,
        last_csi_sub0: u16 = 0,
        osc_count: usize = 0,
        alloc: Allocator,

        pub fn print(self: *@This(), cp: u21) void {
            self.prints.append(self.alloc, cp) catch return;
        }
        pub fn execute(_: *@This(), _: u8) void {}
        pub fn escDispatch(_: *@This(), _: []const u8, _: u8) void {}
        pub fn csiDispatch(self: *@This(), ev: CsiEvent) void {
            self.csi_count += 1;
            self.last_csi_final = ev.final;
            if (ev.params.len > 0 and ev.params[0].sub_count > 0) {
                self.last_csi_sub0 = ev.params[0].subs[0];
            }
        }
        pub fn oscDispatch(self: *@This(), _: []const u8) void {
            self.osc_count += 1;
        }
    };

    const sample = "A中🚀\x1b[38:2::10:20:30m\x1b]2;title\x1b\\\x1bPqignored\x1b\\Z";
    var whole_sink: Sink = .{ .alloc = std.testing.allocator };
    defer whole_sink.prints.deinit(std.testing.allocator);
    var p1: Parser = .{};
    defer p1.deinit(std.testing.allocator);
    p1.feed(std.testing.allocator, sample, &whole_sink);

    var byte_sink: Sink = .{ .alloc = std.testing.allocator };
    defer byte_sink.prints.deinit(std.testing.allocator);
    var p2: Parser = .{};
    defer p2.deinit(std.testing.allocator);
    for (sample) |b| p2.feed(std.testing.allocator, &.{b}, &byte_sink);

    try std.testing.expectEqualSlices(u21, whole_sink.prints.items, byte_sink.prints.items);
    try std.testing.expectEqualSlices(u21, &.{ 'A', 0x4E2D, 0x1F680, 'Z' }, whole_sink.prints.items);
    try std.testing.expectEqual(@as(usize, 1), byte_sink.csi_count);
    try std.testing.expectEqual(@as(u8, 'm'), byte_sink.last_csi_final);
    try std.testing.expectEqual(@as(u16, 2), byte_sink.last_csi_sub0);
    try std.testing.expectEqual(@as(usize, 1), byte_sink.osc_count);
}

test "Parser handles ESC intermediates, CAN abort, and malformed UTF-8" {
    const Sink = struct {
        prints: usize = 0,
        escs: usize = 0,
        last_inter: u8 = 0,
        last_esc_final: u8 = 0,
        pub fn print(self: *@This(), _: u21) void {
            self.prints += 1;
        }
        pub fn execute(_: *@This(), _: u8) void {}
        pub fn escDispatch(self: *@This(), inter: []const u8, final: u8) void {
            self.escs += 1;
            self.last_inter = if (inter.len > 0) inter[0] else 0;
            self.last_esc_final = final;
        }
        pub fn csiDispatch(_: *@This(), _: CsiEvent) void {}
        pub fn oscDispatch(_: *@This(), _: []const u8) void {}
    };
    var sink: Sink = .{};
    var p: Parser = .{};
    defer p.deinit(std.testing.allocator);

    // Charset designation ESC ( B should dispatch ESC without printing 'B'.
    // CAN (0x18) aborts CSI; stray 0xFF and truncated 0xE2 0x82 produce U+FFFD.
    p.feed(std.testing.allocator, "\x1b(B\x1b[12\x18\xff\xe2\x82!", &sink);
    try std.testing.expectEqual(@as(usize, 1), sink.escs);
    try std.testing.expectEqual(@as(u8, '('), sink.last_inter);
    try std.testing.expectEqual(@as(u8, 'B'), sink.last_esc_final);
    try std.testing.expectEqual(@as(usize, 3), sink.prints); // 0xFFFD, 0xFFFD, '!'
}
