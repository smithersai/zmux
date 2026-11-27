//! Virtual terminal handle backing the `zmux_vt_*` C99 ABI.

const std = @import("std");

const scrollback_impl = @import("scrollback.zig");
const vt = @import("../vt.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c_alloc = std.heap.c_allocator;

/// C status values shared with `c_api.zig` (`zmux_status_t`).
pub const VtStatus = enum(c_int) {
    ok = 0,
    err_invalid_arg = 1,
    err_oom = 2,
    _,
};

/// Opaque C handle wrapping a pure-Zig `vt.Terminal` and its allocator.
pub const VtHandle = struct {
    allocator: Allocator,
    term: vt.Terminal,

    /// Allocate a VT handle of `rows x cols` with `max_scrollback` retained lines.
    pub fn create(
        allocator: Allocator,
        rows: u16,
        cols: u16,
        max_scrollback: usize,
    ) Allocator.Error!*VtHandle {
        assert(rows >= 1 and cols >= 1);
        const handle = try allocator.create(VtHandle);
        errdefer allocator.destroy(handle);
        const term = try vt.Terminal.init(allocator, .{
            .rows = rows,
            .cols = cols,
            .scrollback_lines = max_scrollback,
        });
        assert(term.rows() == rows and term.cols() == cols);
        handle.* = .{ .allocator = allocator, .term = term };
        return handle;
    }

    /// Destroy `self` and release all terminal buffers.
    pub fn destroy(self: *VtHandle) void {
        const allocator = self.allocator;
        assert(self.term.rows() >= 1 and self.term.cols() >= 1);
        self.term.deinit();
        allocator.destroy(self);
    }

    /// Feed raw PTY bytes into the VT parser.
    pub fn feed(self: *VtHandle, bytes: []const u8) void {
        assert(self.term.rows() >= 1 and self.term.cols() >= 1);
        self.term.feed(bytes);
    }

    /// Resize the VT grid to `rows x cols`.
    pub fn resize(self: *VtHandle, rows: u16, cols: u16) Allocator.Error!void {
        assert(rows >= 1 and cols >= 1);
        try self.term.resize(rows, cols);
        assert(self.term.rows() == rows and self.term.cols() == cols);
    }

    /// Render clean plain text without ANSI escapes.
    pub fn plainTextAlloc(
        self: *const VtHandle,
        allocator: Allocator,
        scrollback_lines: usize,
    ) Allocator.Error![]u8 {
        assert(self.term.rows() >= 1);
        return self.term.plainText(allocator, .{
            .include_scrollback = scrollback_lines,
        }) catch return error.OutOfMemory;
    }

    /// Render a self-contained ANSI/DEC terminal state restoration sequence.
    pub fn ansiRestoreAlloc(self: *const VtHandle, allocator: Allocator) Allocator.Error![]u8 {
        assert(self.term.rows() >= 1);
        return self.term.ansiRestore(allocator) catch return error.OutOfMemory;
    }

    /// Render the structured screen JSON object into a newly allocated buffer.
    pub fn screenJsonAlloc(
        self: *const VtHandle,
        allocator: Allocator,
        scrollback_lines: usize,
    ) Allocator.Error![]u8 {
        assert(self.term.rows() >= 1);
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        self.term.writeScreenJson(&out.writer, .{
            .include_scrollback = scrollback_lines,
        }) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

/// Allocate a new virtual terminal of `rows x cols` (`NULL` on invalid dimensions or OOM).
pub export fn zmux_vt_new(rows: u16, cols: u16, max_scrollback: usize) callconv(.c) ?*VtHandle {
    if (rows == 0 or cols == 0) return null;
    return VtHandle.create(c_alloc, rows, cols, max_scrollback) catch null;
}

/// Destroy a virtual terminal handle created with `zmux_vt_new`. Safe with `NULL`.
pub export fn zmux_vt_free(handle: ?*VtHandle) callconv(.c) void {
    const h = handle orelse return;
    h.destroy();
}

/// Feed `len` raw PTY bytes into `handle`.
pub export fn zmux_vt_feed(handle: ?*VtHandle, data: ?[*]const u8, len: usize) callconv(.c) VtStatus {
    const h = handle orelse return .err_invalid_arg;
    if (len == 0) return .ok;
    const ptr = data orelse return .err_invalid_arg;
    h.feed(ptr[0..len]);
    return .ok;
}

/// Resize `handle` to `rows x cols`.
pub export fn zmux_vt_resize(handle: ?*VtHandle, rows: u16, cols: u16) callconv(.c) VtStatus {
    const h = handle orelse return .err_invalid_arg;
    if (rows == 0 or cols == 0) return .err_invalid_arg;
    h.resize(rows, cols) catch return .err_oom;
    return .ok;
}

/// Render ANSI-free plain text from `handle`; free with `zmux_string_free`.
pub export fn zmux_vt_plain_text(
    handle: ?*const VtHandle,
    scrollback_lines: usize,
    out_buf: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) VtStatus {
    const dst = out_buf orelse return .err_invalid_arg;
    dst.* = null;
    if (out_len) |lp| lp.* = 0;
    const h = handle orelse return .err_invalid_arg;
    const text = h.plainTextAlloc(c_alloc, scrollback_lines) catch return .err_oom;
    defer c_alloc.free(text);
    const cstr = scrollback_impl.allocCString(text) orelse return .err_oom;
    assert(cstr[text.len] == 0);
    dst.* = cstr;
    if (out_len) |lp| lp.* = text.len;
    return .ok;
}

/// Render a lossless ANSI/DEC restore payload from `handle`; free with `zmux_string_free`.
pub export fn zmux_vt_ansi_restore(
    handle: ?*const VtHandle,
    out_buf: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) VtStatus {
    const dst = out_buf orelse return .err_invalid_arg;
    dst.* = null;
    if (out_len) |lp| lp.* = 0;
    const h = handle orelse return .err_invalid_arg;
    const ansi = h.ansiRestoreAlloc(c_alloc) catch return .err_oom;
    defer c_alloc.free(ansi);
    const cstr = scrollback_impl.allocCString(ansi) orelse return .err_oom;
    assert(cstr[ansi.len] == 0);
    dst.* = cstr;
    if (out_len) |lp| lp.* = ansi.len;
    return .ok;
}

/// Render structured VT screen JSON from `handle`; free with `zmux_string_free`.
pub export fn zmux_vt_screen_json(
    handle: ?*const VtHandle,
    scrollback_lines: usize,
    out_buf: ?*?[*:0]u8,
    out_len: ?*usize,
) callconv(.c) VtStatus {
    const dst = out_buf orelse return .err_invalid_arg;
    dst.* = null;
    if (out_len) |lp| lp.* = 0;
    const h = handle orelse return .err_invalid_arg;
    const json = h.screenJsonAlloc(c_alloc, scrollback_lines) catch return .err_oom;
    defer c_alloc.free(json);
    const cstr = scrollback_impl.allocCString(json) orelse return .err_oom;
    assert(cstr[json.len] == 0);
    dst.* = cstr;
    if (out_len) |lp| lp.* = json.len;
    return .ok;
}

test "VtHandle create, feed, resize, plain text, ansi restore, and screen json" {
    const h = try VtHandle.create(std.testing.allocator, 6, 40, 32);
    defer h.destroy();

    h.feed("\x1b]2;demo\x07\x1b[32mhello\x1b[0m\r\nworld");
    const plain = try h.plainTextAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "world") != null);

    const ansi = try h.ansiRestoreAlloc(std.testing.allocator);
    defer std.testing.allocator.free(ansi);
    try std.testing.expect(ansi.len > 0);

    const json = try h.screenJsonAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("demo", parsed.value.object.get("title").?.string);

    try h.resize(10, 80);
    try std.testing.expectEqual(@as(u16, 10), h.term.rows());
    try std.testing.expectEqual(@as(u16, 80), h.term.cols());
}

test "zmux_vt_* C exports reject null handles and zero dimensions safely" {
    try std.testing.expect(zmux_vt_new(0, 80, 10) == null);
    try std.testing.expect(zmux_vt_new(24, 0, 10) == null);
    zmux_vt_free(null);
    try std.testing.expectEqual(VtStatus.err_invalid_arg, zmux_vt_feed(null, "a", 1));
    try std.testing.expectEqual(VtStatus.err_invalid_arg, zmux_vt_resize(null, 24, 80));

    const h = zmux_vt_new(8, 32, 16) orelse return error.OutOfMemory;
    defer zmux_vt_free(h);
    try std.testing.expectEqual(VtStatus.ok, zmux_vt_feed(h, null, 0));
    try std.testing.expectEqual(VtStatus.err_invalid_arg, zmux_vt_feed(h, null, 3));
    try std.testing.expectEqual(VtStatus.err_invalid_arg, zmux_vt_resize(h, 0, 10));

    var out: ?[*:0]u8 = null;
    var out_len: usize = 0;
    try std.testing.expectEqual(VtStatus.ok, zmux_vt_feed(h, "abc", 3));
    try std.testing.expectEqual(VtStatus.ok, zmux_vt_plain_text(h, 0, &out, &out_len));
    defer scrollback_impl.freeCString(out);
    try std.testing.expect(out != null and out_len >= 3);
}
