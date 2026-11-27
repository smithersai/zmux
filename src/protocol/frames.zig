//! Single-allocation wire frames for `pane_output` notifications and
//! `client.attach` results, base64-encoding raw bytes in place.

const std = @import("std");
const json_text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const assert = std.debug.assert;
const isPlainJsonAscii = json_text.isPlainJsonAscii;

const pane_output_suffix_offset = "\",\"offset\":";
const pane_output_suffix_generation = ",\"generation\":";
const pane_output_suffix_end = "}}\n";
const pane_output_suffix_fixed = pane_output_suffix_offset.len + pane_output_suffix_generation.len +
    pane_output_suffix_end.len;
/// Largest `paneOutputSuffix` result: the fixed bytes plus two maximal u64s.
pub const pane_output_suffix_max = pane_output_suffix_fixed + 2 * std.fmt.count("{d}", .{std.math.maxInt(u64)});

/// The bytes after `data_base64`'s value, in `PaneOutputParams` field order,
/// so the fast paths match `std.json.Stringify` byte for byte.
pub fn paneOutputSuffix(buf: *[pane_output_suffix_max]u8, offset: u64, generation: u64) []const u8 {
    // `buf` holds two maximal u64s plus the fixed bytes, so `printInt` and
    // the copies cannot overflow it.
    var pos: usize = 0;
    @memcpy(buf[pos..][0..pane_output_suffix_offset.len], pane_output_suffix_offset);
    pos += pane_output_suffix_offset.len;
    pos += std.fmt.printInt(buf[pos..], offset, 10, .lower, .{});
    @memcpy(buf[pos..][0..pane_output_suffix_generation.len], pane_output_suffix_generation);
    pos += pane_output_suffix_generation.len;
    pos += std.fmt.printInt(buf[pos..], generation, 10, .lower, .{});
    @memcpy(buf[pos..][0..pane_output_suffix_end.len], pane_output_suffix_end);
    pos += pane_output_suffix_end.len;
    assert(pos > pane_output_suffix_fixed);
    assert(pos <= buf.len);
    return buf[0..pos];
}

/// Format a `pane_output` notification directly from raw PTY bytes in a single
/// pre-sized allocation, avoiding intermediate base64 buffers and redundant
/// JSON escape scans over the base64 alphabet.
pub fn paneOutputNotification(
    allocator: Allocator,
    pane_id: []const u8,
    raw_bytes: []const u8,
    offset: u64,
    generation: u64,
) ![]u8 {
    const prefix = "{\"jsonrpc\":\"2.0\",\"method\":\"pane_output\",\"params\":{\"pane_id\":";
    const mid = ",\"data_base64\":\"";
    var suffix_buf: [pane_output_suffix_max]u8 = undefined;
    const suffix = paneOutputSuffix(&suffix_buf, offset, generation);
    assert(suffix.len <= suffix_buf.len);
    const b64_len = std.base64.standard.Encoder.calcSize(raw_bytes.len);

    if (isPlainJsonAscii(pane_id)) {
        const total = prefix.len + 1 + pane_id.len + 1 + mid.len + b64_len + suffix.len;
        const out = try allocator.alloc(u8, total);
        var pos: usize = 0;
        @memcpy(out[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        out[pos] = '"';
        pos += 1;
        @memcpy(out[pos..][0..pane_id.len], pane_id);
        pos += pane_id.len;
        out[pos] = '"';
        pos += 1;
        @memcpy(out[pos..][0..mid.len], mid);
        pos += mid.len;
        _ = std.base64.standard.Encoder.encode(out[pos..][0..b64_len], raw_bytes);
        pos += b64_len;
        assert(pos + suffix.len == total);
        @memcpy(out[pos..][0..suffix.len], suffix);
        return out;
    }

    var escaped_id: std.Io.Writer.Allocating = try .initCapacity(allocator, pane_id.len + 16);
    defer escaped_id.deinit();
    try std.json.Stringify.value(pane_id, .{}, &escaped_id.writer);
    const id_slice = escaped_id.written();

    const total = prefix.len + id_slice.len + mid.len + b64_len + suffix.len;
    const out = try allocator.alloc(u8, total);
    var pos: usize = 0;
    @memcpy(out[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out[pos..][0..id_slice.len], id_slice);
    pos += id_slice.len;
    @memcpy(out[pos..][0..mid.len], mid);
    pos += mid.len;
    _ = std.base64.standard.Encoder.encode(out[pos..][0..b64_len], raw_bytes);
    pos += b64_len;
    assert(pos + suffix.len == total);
    @memcpy(out[pos..][0..suffix.len], suffix);
    return out;
}

/// Format a `client.attach` JSON-RPC result in a single pre-sized allocation,
/// base64-encoding `replay_bytes` directly into the output frame.
pub fn attachResult(
    allocator: Allocator,
    id_json: []const u8,
    client_id: []const u8,
    session_id: []const u8,
    window_id: []const u8,
    pane_id: []const u8,
    rows: u16,
    cols: u16,
    replay_bytes: []const u8,
) ![]u8 {
    var head: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer head.deinit();
    try head.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"clientId\":{f},\"sessionId\":{f}," ++
            "\"windowId\":{f},\"paneId\":{f},\"rows\":{},\"cols\":{},\"replayBase64\":\"",
        .{
            id_json,
            std.json.fmt(client_id, .{}),
            std.json.fmt(session_id, .{}),
            std.json.fmt(window_id, .{}),
            std.json.fmt(pane_id, .{}),
            rows,
            cols,
        },
    );
    const head_slice = head.written();
    assert(head_slice.len > 0);
    const b64_len = std.base64.standard.Encoder.calcSize(replay_bytes.len);
    const suffix = "\"}}\n";
    const out = try allocator.alloc(u8, head_slice.len + b64_len + suffix.len);
    @memcpy(out[0..head_slice.len], head_slice);
    _ = std.base64.standard.Encoder.encode(out[head_slice.len..][0..b64_len], replay_bytes);
    @memcpy(out[head_slice.len + b64_len ..][0..suffix.len], suffix);
    return out;
}

test "attachResult emits valid single-line JSON with inline base64 replay" {
    const frame = try attachResult(
        std.testing.allocator,
        "42",
        "client-1",
        "sess-1",
        "win-1",
        "pane-1",
        40,
        120,
        "replay data",
    );
    defer std.testing.allocator.free(frame);

    try std.testing.expect(frame[frame.len - 1] == '\n');
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, frame, .{});
    defer parsed.deinit();
    const res = parsed.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("client-1", res.get("clientId").?.string);
    try std.testing.expectEqualStrings("pane-1", res.get("paneId").?.string);
    try std.testing.expectEqual(@as(i64, 40), res.get("rows").?.integer);
    try std.testing.expectEqual(@as(i64, 120), res.get("cols").?.integer);
    try std.testing.expectEqualStrings("cmVwbGF5IGRhdGE=", res.get("replayBase64").?.string);
}
