const std = @import("std");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const c_api = zmux.c_api;

fn fuzzCApiScrollback(_: void, smith: *std.testing.Smith) !void {
    const cap: usize = smith.valueRangeAtMost(u16, 0, 2048);
    const sb = c_api.zmux_scrollback_new(cap) orelse return;
    defer c_api.zmux_scrollback_free(sb);

    var buf: [256]u8 = undefined;
    var expected_total: u64 = 0;
    var steps: usize = 0;
    while (!smith.eos() and steps < 64) : (steps += 1) {
        const op = smith.valueRangeAtMost(u8, 0, 2);
        switch (op) {
            0 => {
                const chunk = corpus.drawBytes(smith, &buf);
                const status = c_api.zmux_scrollback_append(sb, if (chunk.len == 0) null else chunk.ptr, chunk.len);
                try std.testing.expectEqual(c_api.Status.ok, status);
                expected_total += chunk.len;
                try std.testing.expectEqual(expected_total, c_api.zmux_scrollback_end_offset(sb));
                try std.testing.expect(c_api.zmux_scrollback_start_offset(sb) <= expected_total);
            },
            1 => {
                const lines: usize = smith.valueRangeAtMost(u16, 0, 32);
                const max_bytes: usize = smith.valueRangeAtMost(u16, 0, 512);
                var out: ?[*:0]u8 = null;
                var out_len: usize = 0;
                const status = c_api.zmux_scrollback_capture_lines(sb, lines, max_bytes, &out, &out_len);
                try std.testing.expectEqual(c_api.Status.ok, status);
                defer c_api.zmux_string_free(out);
                try std.testing.expect(out != null);
                try std.testing.expectEqual(@as(u8, 0), out.?[out_len]);
            },
            else => {
                const code: c_api.Status = @fromBackingInt(@intCast(smith.value(i32)));
                const text = std.mem.span(c_api.zmux_status_string(code));
                try std.testing.expect(text.len > 0);
            },
        }
    }
}

fn fuzzCApiVt(_: void, smith: *std.testing.Smith) !void {
    const rows = smith.valueRangeAtMost(u16, 1, 24);
    const cols = smith.valueRangeAtMost(u16, 1, 80);
    const vt_handle = c_api.vt_impl.zmux_vt_new(rows, cols, 16) orelse return;
    defer c_api.vt_impl.zmux_vt_free(vt_handle);

    var buf: [256]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 32) : (steps += 1) {
        switch (smith.valueRangeAtMost(u8, 0, 3)) {
            0 => {
                const chunk = corpus.drawBytes(smith, &buf);
                _ = c_api.vt_impl.zmux_vt_feed(vt_handle, if (chunk.len == 0) null else chunk.ptr, chunk.len);
            },
            1 => {
                const nr = smith.valueRangeAtMost(u16, 1, 24);
                const nc = smith.valueRangeAtMost(u16, 1, 80);
                _ = c_api.vt_impl.zmux_vt_resize(vt_handle, nr, nc);
            },
            2 => {
                var out: ?[*:0]u8 = null;
                var len: usize = 0;
                if (c_api.vt_impl.zmux_vt_plain_text(vt_handle, 4, &out, &len) == .ok) {
                    defer c_api.zmux_string_free(out);
                    try std.testing.expect(out != null);
                    try std.testing.expectEqual(@as(u8, 0), out.?[len]);
                }
            },
            else => {
                var out: ?[*:0]u8 = null;
                var len: usize = 0;
                if (c_api.vt_impl.zmux_vt_screen_json(vt_handle, 2, &out, &len) == .ok) {
                    defer c_api.zmux_string_free(out);
                    try std.testing.expect(out != null);
                    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.?[0..len], .{});
                    defer parsed.deinit();
                    try std.testing.expect(parsed.value == .object);
                }
            },
        }
    }
}

test "fuzz: c_api scrollback handle and status strings" {
    try std.testing.fuzz({}, fuzzCApiScrollback, .{});
}

test "fuzz: c_api virtual terminal handle produces valid NUL-terminated JSON" {
    try std.testing.fuzz({}, fuzzCApiVt, .{});
}
