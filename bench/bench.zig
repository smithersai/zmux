const std = @import("std");
const builtin = @import("builtin");

pub const Allocator = std.mem.Allocator;

pub const BenchOptions = struct {
    /// Logical bytes processed per iteration (used to compute MB/s when > 0).
    bytes_per_op: usize = 0,
    /// Number of timed samples per benchmark (after 1 warmup sample).
    samples: usize = 7,
    /// Target duration for each timed sample in nanoseconds.
    min_sample_ns: u64 = 15 * std.time.ns_per_ms,
    /// Minimum iterations per sample.
    min_iters: usize = 1,
    /// Maximum iterations per sample (caps calibration for ultra-fast ops).
    max_iters: usize = 5_000_000,
    /// Optional fixed iteration count per sample (skips calibration when non-null).
    fixed_iters: ?usize = null,
};

pub const BenchResult = struct {
    name: []const u8,
    iterations_per_sample: usize,
    samples: usize,
    bytes_per_op: usize,
    min_ns: f64,
    median_ns: f64,
    mean_ns: f64,
    p95_ns: f64,
    max_ns: f64,
    ops_per_sec: f64,
    mb_per_sec: ?f64,
};

pub const Runner = struct {
    allocator: Allocator,
    io: std.Io,
    suite: []const u8,
    filter: ?[]const u8 = null,
    json_out: ?[]const u8 = null,
    samples_override: ?usize = null,
    min_sample_ms_override: ?u64 = null,
    quick: bool = false,
    results: std.ArrayList(BenchResult) = .empty,

    pub fn init(allocator: Allocator, io: std.Io, suite: []const u8, argv: []const []const u8) !Runner {
        var runner: Runner = .{
            .allocator = allocator,
            .io = io,
            .suite = suite,
        };

        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if (std.mem.eql(u8, arg, "--json-out")) {
                i += 1;
                if (i >= argv.len) return error.MissingJsonOutPath;
                runner.json_out = argv[i];
            } else if (std.mem.eql(u8, arg, "--filter")) {
                i += 1;
                if (i >= argv.len) return error.MissingFilter;
                runner.filter = argv[i];
            } else if (std.mem.eql(u8, arg, "--samples")) {
                i += 1;
                if (i >= argv.len) return error.MissingSamples;
                runner.samples_override = try std.fmt.parseInt(usize, argv[i], 10);
            } else if (std.mem.eql(u8, arg, "--min-sample-ms")) {
                i += 1;
                if (i >= argv.len) return error.MissingMinSampleMs;
                runner.min_sample_ms_override = try std.fmt.parseInt(u64, argv[i], 10);
            } else if (std.mem.eql(u8, arg, "--quick")) {
                runner.quick = true;
            }
        }

        try runner.printHeader();
        return runner;
    }

    pub fn deinit(self: *Runner) void {
        self.results.deinit(self.allocator);
    }

    pub fn shouldRun(self: *const Runner, name: []const u8) bool {
        const needle = self.filter orelse return true;
        return std.mem.indexOf(u8, name, needle) != null;
    }

    /// Run a benchmark function `fn (ctx: @TypeOf(ctx)) !void` (or returning void).
    pub fn run(
        self: *Runner,
        name: []const u8,
        opts: BenchOptions,
        ctx: anytype,
        comptime func: anytype,
    ) !void {
        if (!self.shouldRun(name)) return;

        const base_samples = self.samples_override orelse if (self.quick) @min(opts.samples, 3) else opts.samples;
        const sample_count = @max(base_samples, 1);
        const target_ns: u64 = if (self.min_sample_ms_override) |ms|
            ms * std.time.ns_per_ms
        else if (self.quick)
            @min(opts.min_sample_ns, 5 * std.time.ns_per_ms)
        else
            opts.min_sample_ns;

        const iters = if (opts.fixed_iters) |fixed|
            @max(fixed, 1)
        else
            try self.calibrate(opts, target_ns, ctx, func);

        // Warmup sample.
        try runBatch(iters, ctx, func);

        const per_op_ns = try self.allocator.alloc(f64, sample_count);
        defer self.allocator.free(per_op_ns);

        var sum_ns: f64 = 0;
        for (0..sample_count) |s| {
            const start = std.Io.Clock.awake.now(self.io);
            try runBatch(iters, ctx, func);
            const elapsed_raw = start.untilNow(self.io, .awake).toNanoseconds();
            const elapsed_ns: f64 = @floatFromInt(@max(elapsed_raw, 1));
            const op_ns = elapsed_ns / @as(f64, @floatFromInt(iters));
            per_op_ns[s] = op_ns;
            sum_ns += op_ns;
        }

        std.mem.sort(f64, per_op_ns, {}, std.sort.asc(f64));

        const min_ns = per_op_ns[0];
        const max_ns = per_op_ns[sample_count - 1];
        const median_ns = if (sample_count % 2 == 1)
            per_op_ns[sample_count / 2]
        else
            (per_op_ns[sample_count / 2 - 1] + per_op_ns[sample_count / 2]) / 2.0;
        const p95_idx = @min(sample_count - 1, (sample_count * 95 + 99) / 100 - 1);
        const p95_ns = per_op_ns[p95_idx];
        const mean_ns = sum_ns / @as(f64, @floatFromInt(sample_count));
        const ops_per_sec = if (median_ns > 0) 1_000_000_000.0 / median_ns else 0;
        const mb_per_sec: ?f64 = if (opts.bytes_per_op > 0 and median_ns > 0)
            (@as(f64, @floatFromInt(opts.bytes_per_op)) / (1024.0 * 1024.0)) * ops_per_sec
        else
            null;

        const res: BenchResult = .{
            .name = name,
            .iterations_per_sample = iters,
            .samples = sample_count,
            .bytes_per_op = opts.bytes_per_op,
            .min_ns = min_ns,
            .median_ns = median_ns,
            .mean_ns = mean_ns,
            .p95_ns = p95_ns,
            .max_ns = max_ns,
            .ops_per_sec = ops_per_sec,
            .mb_per_sec = mb_per_sec,
        };
        try self.results.append(self.allocator, res);
        try self.printRow(res);
    }

    fn calibrate(
        self: *Runner,
        opts: BenchOptions,
        target_ns: u64,
        ctx: anytype,
        comptime func: anytype,
    ) !usize {
        var iters: usize = @max(opts.min_iters, 1);
        while (true) {
            const start = std.Io.Clock.awake.now(self.io);
            try runBatch(iters, ctx, func);
            const elapsed_raw = start.untilNow(self.io, .awake).toNanoseconds();
            const elapsed: u64 = @intCast(@max(elapsed_raw, 1));
            if (elapsed >= target_ns or iters >= opts.max_iters) {
                return iters;
            }
            // Scale up smoothly toward target_ns without overshooting wildly.
            const factor: usize = if (elapsed < target_ns / 10)
                10
            else
                @max(@as(usize, 2), @as(usize, @intCast(@min((target_ns + elapsed - 1) / elapsed, 10))));
            iters = @min(iters *| factor, opts.max_iters);
        }
    }

    pub fn finish(self: *Runner) !void {
        if (self.json_out) |path| {
            try self.writeJsonReport(path);
        }
    }

    fn printHeader(self: *const Runner) !void {
        var buf: [2048]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &buf);
        try out.interface.print(
            "\n=== zmux bench: {s} (zig {s}, {s}) ===\n",
            .{ self.suite, builtin.zig_version_string, @tagName(builtin.mode) },
        );
        try out.interface.print(
            "{s:<46} {s:>12} {s:>12} {s:>13} {s:>11}\n",
            .{ "benchmark", "median", "p95", "ops/s", "throughput" },
        );
        try out.interface.print(
            "{s:-<46} {s:->12} {s:->12} {s:->13} {s:->11}\n",
            .{ "", "", "", "", "" },
        );
        try out.interface.flush();
    }

    fn printRow(self: *const Runner, res: BenchResult) !void {
        var buf: [2048]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(self.io, &buf);
        var med_buf: [32]u8 = undefined;
        var p95_buf: [32]u8 = undefined;
        var ops_buf: [32]u8 = undefined;
        var mb_buf: [32]u8 = undefined;

        const med_str = formatDurationNs(&med_buf, res.median_ns);
        const p95_str = formatDurationNs(&p95_buf, res.p95_ns);
        const ops_str = formatRate(&ops_buf, res.ops_per_sec);
        const mb_str = if (res.mb_per_sec) |mb|
            formatThroughput(&mb_buf, mb)
        else
            "-";

        try out.interface.print(
            "{s:<46} {s:>12} {s:>12} {s:>13} {s:>11}\n",
            .{ res.name, med_str, p95_str, ops_str, mb_str },
        );
        try out.interface.flush();
    }

    fn writeJsonReport(self: *const Runner, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) {
                std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
            }
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try out.writer.print(
            "{{\"suite\":{f},\"zigVersion\":{f},\"optimize\":{f},\"os\":{f},\"arch\":{f},\"benchmarks\":[",
            .{
                std.json.fmt(self.suite, .{}),
                std.json.fmt(builtin.zig_version_string, .{}),
                std.json.fmt(@tagName(builtin.mode), .{}),
                std.json.fmt(@tagName(builtin.os.tag), .{}),
                std.json.fmt(@tagName(builtin.cpu.arch), .{}),
            },
        );
        for (self.results.items, 0..) |res, idx| {
            if (idx > 0) try out.writer.writeByte(',');
            try out.writer.print(
                "{{\"name\":{f},\"iterations\":{d},\"samples\":{d},\"bytesPerOp\":{d}," ++
                    "\"minNs\":{d:.2},\"medianNs\":{d:.2},\"meanNs\":{d:.2},\"p95Ns\":{d:.2}," ++
                    "\"maxNs\":{d:.2},\"opsPerSec\":{d:.2},\"mbPerSec\":",
                .{
                    std.json.fmt(res.name, .{}),
                    res.iterations_per_sample,
                    res.samples,
                    res.bytes_per_op,
                    res.min_ns,
                    res.median_ns,
                    res.mean_ns,
                    res.p95_ns,
                    res.max_ns,
                    res.ops_per_sec,
                },
            );
            if (res.mb_per_sec) |mb| {
                try out.writer.print("{d:.2}", .{mb});
            } else {
                try out.writer.writeAll("null");
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeAll("]}\n");

        const payload = try out.toOwnedSlice();
        defer self.allocator.free(payload);

        var file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, payload);
    }
};

fn runBatch(iters: usize, ctx: anytype, comptime func: anytype) !void {
    const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const is_error_union = @typeInfo(Ret) == .error_union;
    for (0..iters) |_| {
        if (is_error_union) {
            try func(ctx);
        } else {
            func(ctx);
        }
    }
}

pub fn doNotOptimize(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
}

pub fn formatDurationNs(buf: []u8, ns: f64) []const u8 {
    if (ns >= 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} s", .{ns / 1_000_000_000.0}) catch "?";
    } else if (ns >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} ms", .{ns / 1_000_000.0}) catch "?";
    } else if (ns >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} us", .{ns / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} ns", .{ns}) catch "?";
    }
}

pub fn formatRate(buf: []u8, ops: f64) []const u8 {
    if (ops >= 1_000_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} G/s", .{ops / 1_000_000_000.0}) catch "?";
    } else if (ops >= 1_000_000.0) {
        return std.fmt.bufPrint(buf, "{d:.2} M/s", .{ops / 1_000_000.0}) catch "?";
    } else if (ops >= 1_000.0) {
        return std.fmt.bufPrint(buf, "{d:.1} K/s", .{ops / 1_000.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} /s", .{ops}) catch "?";
    }
}

pub fn formatThroughput(buf: []u8, mb_s: f64) []const u8 {
    if (mb_s >= 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.2} GB/s", .{mb_s / 1024.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{mb_s}) catch "?";
    }
}
