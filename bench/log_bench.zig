const std = @import("std");
const bench = @import("bench");
const log = @import("log");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var runner = try bench.Runner.init(allocator, io, "log", argv);
    defer runner.deinit();

    const saved = log.getLevel();
    defer log.setLevel(saved);
    log.setLevel(.warn);

    // 1. Suppressed hot-path check (debug/info when level=.warn).
    try runner.run("emit_suppressed_debug", .{}, {}, struct {
        fn f(_: void) void {
            log.debug("hot_path_event", .{ .active = @as(usize, 12), .bytes = @as(usize, 8192) });
        }
    }.f);

    // 2. Structured JSON formatting (plain ASCII fields).
    try runner.run("format_structured_plain", .{}, {}, struct {
        fn f(_: void) void {
            var buf: [log.max_line_bytes]u8 = undefined;
            const line = log.format(&buf, .warn, 1795397750743, 4242, "client_backlogged", .{
                .queued_bytes = @as(usize, 1048572),
                .rejected_bytes = @as(usize, 4096),
                .max_queued_bytes = @as(usize, 1048576),
                .socket_path = @as([]const u8, "/tmp/zmux-501/sessions.sock"),
            });
            bench.doNotOptimize(line.ptr);
        }
    }.f);

    // 3. Structured JSON formatting with heavy escaping.
    const escaped_str = "line1\nline2\t\"quoted\"\\path\\with\x01control\x1fchars";
    try runner.run("format_structured_escaped", .{ .bytes_per_op = escaped_str.len }, escaped_str, struct {
        fn f(s: []const u8) void {
            var buf: [log.max_line_bytes]u8 = undefined;
            const line = log.format(&buf, .err, 1795397750743, 4242, "escaped_event", .{
                .detail = s,
                .err = error.Unexpected,
            });
            bench.doNotOptimize(line.ptr);
        }
    }.f);

    // 4. Truncation / rollback path.
    const huge: [log.max_line_bytes * 2]u8 = @splat('x');
    try runner.run("format_overflow_truncation", .{}, &huge, struct {
        fn f(h: []const u8) void {
            var buf: [log.max_line_bytes]u8 = undefined;
            const line = log.format(&buf, .warn, 1795397750743, 4242, "big_event", .{
                .payload = h,
                .count = @as(u32, 9),
            });
            bench.doNotOptimize(line.ptr);
        }
    }.f);

    // 5. parseLevel across variants.
    try runner.run("parseLevel_mixed", .{}, {}, struct {
        fn f(_: void) void {
            bench.doNotOptimize(log.parseLevel("warning") catch unreachable);
            bench.doNotOptimize(log.parseLevel("DEBUG") catch unreachable);
            bench.doNotOptimize(log.parseLevel("error") catch unreachable);
        }
    }.f);

    try runner.finish();
}
