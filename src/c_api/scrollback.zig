//! Scrollback handle implementation backing the `zmux_scrollback_*` C ABI.

const std = @import("std");

const buffer = @import("../buffer.zig");

const Allocator = std.mem.Allocator;
const ScrollbackBuffer = buffer.ScrollbackBuffer;
const assert = std.debug.assert;
const c = std.c;

/// Copy `bytes` into a `malloc`-backed NUL-terminated C string released via `zmux_string_free`.
pub fn allocCString(bytes: []const u8) ?[*:0]u8 {
    if (bytes.len == std.math.maxInt(usize)) return null;
    const raw = c.malloc(bytes.len + 1) orelse return null;
    const ptr: [*]u8 = @ptrCast(raw);
    if (bytes.len > 0) @memcpy(ptr[0..bytes.len], bytes);
    ptr[bytes.len] = 0;
    assert(ptr[bytes.len] == 0);
    return ptr[0..bytes.len :0].ptr;
}

/// Free a string allocated with `allocCString`. Safe with `null`.
pub fn freeCString(ptr: ?[*:0]u8) void {
    if (ptr) |p| c.free(@ptrCast(p));
}

/// Opaque C handle wrapping `ScrollbackBuffer` and its owning allocator.
pub const Handle = struct {
    allocator: Allocator,
    inner: ScrollbackBuffer,

    /// Allocate a new handle with a ring of `capacity_bytes` (clamped to `[1, max_capacity]`).
    pub fn create(allocator: Allocator, capacity_bytes: usize) Allocator.Error!*Handle {
        const handle = try allocator.create(Handle);
        errdefer allocator.destroy(handle);
        const inner = try ScrollbackBuffer.init(allocator, capacity_bytes);
        assert(inner.capacity() >= 1);
        assert(inner.capacity() <= buffer.max_capacity);
        handle.* = .{ .allocator = allocator, .inner = inner };
        return handle;
    }

    /// Destroy `self` and free its backing ring.
    pub fn destroy(self: *Handle) void {
        const allocator = self.allocator;
        assert(self.inner.capacity() >= 1);
        self.inner.deinit();
        allocator.destroy(self);
    }

    /// Append `bytes` into the underlying ring buffer.
    pub fn append(self: *Handle, bytes: []const u8) void {
        const before = self.inner.endOffset();
        self.inner.append(bytes);
        assert(self.inner.endOffset() == before + bytes.len);
    }

    /// Monotonic stream offset one past the newest appended byte.
    pub fn endOffset(self: *const Handle) u64 {
        assert(self.inner.startOffset() <= self.inner.endOffset());
        return self.inner.endOffset();
    }

    /// Stream offset of the oldest byte retained in the ring.
    pub fn startOffset(self: *const Handle) u64 {
        assert(self.inner.startOffset() <= self.inner.endOffset());
        return self.inner.startOffset();
    }

    /// Capture up to `max_lines` lines (bounded by `max_bytes`, or full capacity when `max_bytes == 0`).
    /// Returns a freshly allocated slice owned by `allocator`.
    pub fn captureLinesAlloc(
        self: *const Handle,
        allocator: Allocator,
        max_lines: usize,
        max_bytes: usize,
    ) Allocator.Error![]u8 {
        const cap = self.inner.capacity();
        assert(cap >= 1);
        const limit = if (max_bytes == 0) cap else max_bytes;
        const out = try self.inner.captureLastLinesBounded(allocator, max_lines, limit);
        assert(out.len <= limit);
        return out;
    }
};

test "scrollback handle create, append, offsets, and capture roundtrip" {
    const h = try Handle.create(std.testing.allocator, 16);
    defer h.destroy();

    try std.testing.expectEqual(@as(u64, 0), h.startOffset());
    try std.testing.expectEqual(@as(u64, 0), h.endOffset());

    h.append("line1\nline2\nline3\n");
    try std.testing.expectEqual(@as(u64, 18), h.endOffset());
    try std.testing.expectEqual(@as(u64, 2), h.startOffset());

    const two = try h.captureLinesAlloc(std.testing.allocator, 2, 0);
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings("line2\nline3\n", two);

    const bounded = try h.captureLinesAlloc(std.testing.allocator, 5, 6);
    defer std.testing.allocator.free(bounded);
    try std.testing.expectEqualStrings("line3\n", bounded);
}

test "scrollback handle propagates allocation failure without leaking" {
    var fail0 = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Handle.create(fail0.allocator(), 32));
    try std.testing.expectEqual(fail0.allocated_bytes, fail0.freed_bytes);

    var fail1 = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, Handle.create(fail1.allocator(), 32));
    try std.testing.expectEqual(fail1.allocated_bytes, fail1.freed_bytes);
}

test "allocCString and freeCString handle empty and non-empty payloads" {
    const empty = allocCString("") orelse return error.OutOfMemory;
    defer freeCString(empty);
    try std.testing.expectEqualStrings("", std.mem.span(empty));

    const text = allocCString("zmux-c-api") orelse return error.OutOfMemory;
    defer freeCString(text);
    try std.testing.expectEqualStrings("zmux-c-api", std.mem.span(text));

    freeCString(null);
}
