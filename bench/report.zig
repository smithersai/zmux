const std = @import("std");
const bench = @import("bench.zig");

const Allocator = std.mem.Allocator;

const Entry = struct {
    suite: []const u8,
    name: []const u8,
    median_ns: f64,
    p95_ns: f64,
    ops_per_sec: f64,
    mb_per_sec: ?f64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var results_dir: []const u8 = ".benchmarks";
    var baseline_path: ?[]const u8 = "bench/baseline.json";
    var write_baseline: ?[]const u8 = null;
    var markdown_out: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--results-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingResultsDir;
            results_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            i += 1;
            if (i >= argv.len) return error.MissingBaseline;
            baseline_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--no-baseline")) {
            baseline_path = null;
        } else if (std.mem.eql(u8, arg, "--write-baseline")) {
            i += 1;
            if (i >= argv.len) return error.MissingWriteBaseline;
            write_baseline = argv[i];
        } else if (std.mem.eql(u8, arg, "--markdown-out")) {
            i += 1;
            if (i >= argv.len) return error.MissingMarkdownOut;
            markdown_out = argv[i];
        }
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Load baseline map: "suite::name" -> median_ns.
    var baseline = std.StringHashMap(f64).init(aa);
    if (baseline_path) |bpath| {
        if (std.Io.Dir.cwd().readFileAlloc(io, bpath, aa, .limited(4 * 1024 * 1024))) |raw| {
            try parseBaseline(aa, raw, &baseline);
        } else |_| {}
    }

    // Read all *.json files in results_dir.
    var file_names = std.ArrayList([]const u8).empty;
    var dir = try std.Io.Dir.cwd().openDir(io, results_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try file_names.append(aa, try aa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, file_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var entries = std.ArrayList(Entry).empty;
    for (file_names.items) |fname| {
        const full = try std.fs.path.join(aa, &.{ results_dir, fname });
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, full, aa, .limited(4 * 1024 * 1024));
        try parseSuiteFile(aa, raw, &entries);
    }

    var report_out: std.Io.Writer.Allocating = .init(aa);
    try writeReportTable(&report_out.writer, entries.items, &baseline);
    const report_text = try report_out.toOwnedSlice();

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout.interface.writeAll(report_text);
    try stdout.interface.flush();

    if (markdown_out) |mpath| {
        if (std.fs.path.dirname(mpath)) |parent| {
            if (parent.len > 0) std.Io.Dir.cwd().createDirPath(io, parent) catch {};
        }
        var f = try std.Io.Dir.cwd().createFile(io, mpath, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, report_text);
    }

    if (write_baseline) |wpath| {
        if (std.fs.path.dirname(wpath)) |parent| {
            if (parent.len > 0) std.Io.Dir.cwd().createDirPath(io, parent) catch {};
        }
        var json_out: std.Io.Writer.Allocating = .init(aa);
        try json_out.writer.writeAll("{\n  \"benchmarks\": [\n");
        for (entries.items, 0..) |e, idx| {
            if (idx > 0) try json_out.writer.writeAll(",\n");
            try json_out.writer.print(
                "    {{\"suite\":{f},\"name\":{f},\"medianNs\":{d:.2},\"p95Ns\":{d:.2},\"opsPerSec\":{d:.2},\"mbPerSec\":",
                .{
                    std.json.fmt(e.suite, .{}),
                    std.json.fmt(e.name, .{}),
                    e.median_ns,
                    e.p95_ns,
                    e.ops_per_sec,
                },
            );
            if (e.mb_per_sec) |mb| {
                try json_out.writer.print("{d:.2}", .{mb});
            } else {
                try json_out.writer.writeAll("null");
            }
            try json_out.writer.writeByte('}');
        }
        try json_out.writer.writeAll("\n  ]\n}\n");
        const payload = try json_out.toOwnedSlice();
        var f = try std.Io.Dir.cwd().createFile(io, wpath, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, payload);
    }
}

fn parseBaseline(aa: Allocator, raw: []const u8, map: *std.StringHashMap(f64)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, aa, raw, .{}) catch return;
    if (parsed.value != .object) return;
    const arr = parsed.value.object.get("benchmarks") orelse return;
    if (arr != .array) return;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const suite_v = item.object.get("suite") orelse continue;
        const name_v = item.object.get("name") orelse continue;
        const med_v = item.object.get("medianNs") orelse continue;
        if (suite_v != .string or name_v != .string) continue;
        const med = jsonNumber(med_v) orelse continue;
        const key = try std.fmt.allocPrint(aa, "{s}::{s}", .{ suite_v.string, name_v.string });
        try map.put(key, med);
    }
}

fn parseSuiteFile(aa: Allocator, raw: []const u8, entries: *std.ArrayList(Entry)) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, aa, raw, .{});
    if (parsed.value != .object) return;
    const suite_v = parsed.value.object.get("suite") orelse return;
    if (suite_v != .string) return;
    const arr = parsed.value.object.get("benchmarks") orelse return;
    if (arr != .array) return;

    for (arr.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        const med = jsonNumber(item.object.get("medianNs") orelse continue) orelse continue;
        const p95 = jsonNumber(item.object.get("p95Ns") orelse continue) orelse med;
        const ops = jsonNumber(item.object.get("opsPerSec") orelse continue) orelse 0;
        const mb = if (item.object.get("mbPerSec")) |v| jsonNumber(v) else null;

        try entries.append(aa, .{
            .suite = try aa.dupe(u8, suite_v.string),
            .name = try aa.dupe(u8, name_v.string),
            .median_ns = med,
            .p95_ns = p95,
            .ops_per_sec = ops,
            .mb_per_sec = mb,
        });
    }
}

fn jsonNumber(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn writeReportTable(
    writer: *std.Io.Writer,
    entries: []const Entry,
    baseline: *const std.StringHashMap(f64),
) !void {
    try writer.writeAll("# zmux Performance Benchmark Report\n\n");
    if (entries.len == 0) {
        try writer.writeAll("_No benchmark result files found._\n");
        return;
    }

    try writer.print(
        "| {s:<16} | {s:<42} | {s:>11} | {s:>11} | {s:>12} | {s:>10} | {s:>14} |\n",
        .{ "Suite", "Benchmark", "Median", "P95", "Ops/s", "Throughput", "vs Baseline" },
    );
    try writer.print(
        "| {s:-<16} | {s:-<42} | {s:->11} | {s:->11} | {s:->12} | {s:->10} | {s:->14} |\n",
        .{ "", "", "", "", "", "", "" },
    );

    var key_buf: [256]u8 = undefined;
    var med_buf: [32]u8 = undefined;
    var p95_buf: [32]u8 = undefined;
    var ops_buf: [32]u8 = undefined;
    var mb_buf: [32]u8 = undefined;
    var delta_buf: [32]u8 = undefined;

    for (entries) |e| {
        const med = bench.formatDurationNs(&med_buf, e.median_ns);
        const p95 = bench.formatDurationNs(&p95_buf, e.p95_ns);
        const ops = bench.formatRate(&ops_buf, e.ops_per_sec);
        const mb = if (e.mb_per_sec) |v| bench.formatThroughput(&mb_buf, v) else "-";

        const delta: []const u8 = blk: {
            const key = std.fmt.bufPrint(&key_buf, "{s}::{s}", .{ e.suite, e.name }) catch break :blk "-";
            const base = baseline.get(key) orelse break :blk "new";
            if (base <= 0) break :blk "-";
            const speedup = base / @max(e.median_ns, 0.001);
            const pct = ((e.median_ns - base) / base) * 100.0;
            if (speedup >= 1.5) {
                break :blk std.fmt.bufPrint(&delta_buf, "{d:.2}x faster", .{speedup}) catch "?";
            } else if (speedup <= 0.67) {
                break :blk std.fmt.bufPrint(&delta_buf, "{d:.2}x slower", .{1.0 / speedup}) catch "?";
            } else if (pct >= 0) {
                break :blk std.fmt.bufPrint(&delta_buf, "+{d:.1}%", .{pct}) catch "?";
            } else {
                break :blk std.fmt.bufPrint(&delta_buf, "{d:.1}%", .{pct}) catch "?";
            }
        };

        try writer.print(
            "| {s:<16} | {s:<42} | {s:>11} | {s:>11} | {s:>12} | {s:>10} | {s:>14} |\n",
            .{ e.suite, e.name, med, p95, ops, mb, delta },
        );
    }

    try writer.print("\nTotal benchmarks: {d}\n", .{entries.len});
}
