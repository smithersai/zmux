const std = @import("std");
const builtin = @import("builtin");

/// Oldest supported compiler. zmux tracks one Zig minor series at a time:
/// any 0.17.x patch release at or above this version is accepted, and the
/// next minor (0.18.0) is rejected because Zig breaks std APIs between minors.
const min_zig = std.SemanticVersion{ .major = 0, .minor = 17, .patch = 1 };
const next_unsupported_zig = std.SemanticVersion{ .major = min_zig.major, .minor = min_zig.minor + 1, .patch = 0 };
const macos_deployment_target = std.SemanticVersion{ .major = 14, .minor = 0, .patch = 0 };

comptime {
    if (!isSupportedZig(builtin.zig_version)) {
        const msg = std.fmt.comptimePrint(
            "zmux requires Zig >= {d}.{d}.{d} and < {d}.{d}.{d}. You have {d}.{d}.{d}. Run `zvm use {d}.{d}.{d}`.",
            .{
                min_zig.major,
                min_zig.minor,
                min_zig.patch,
                next_unsupported_zig.major,
                next_unsupported_zig.minor,
                next_unsupported_zig.patch,
                builtin.zig_version.major,
                builtin.zig_version.minor,
                builtin.zig_version.patch,
                min_zig.major,
                min_zig.minor,
                min_zig.patch,
            },
        );
        @compileError(msg);
    }
}

/// True for `min_zig <= version < next_unsupported_zig`, matching on the
/// major.minor series rather than `SemanticVersion.order` alone: semver orders
/// `0.18.0-dev.N` *below* `0.18.0`, but a 0.18 dev compiler already carries the
/// 0.18 std breakage and must be rejected. Pre-releases of a supported patch
/// (`0.17.2-dev.N`) are accepted; `0.17.1-dev.N` predates the minimum and is not.
fn isSupportedZig(version: std.SemanticVersion) bool {
    const same_series = version.major == min_zig.major and version.minor == min_zig.minor;
    return same_series and version.order(min_zig) != .lt;
}

comptime {
    @setEvalBranchQuota(10_000);
    const v = std.SemanticVersion.parse;
    std.debug.assert(isSupportedZig(v("0.17.1") catch unreachable));
    std.debug.assert(isSupportedZig(v("0.17.2") catch unreachable));
    std.debug.assert(isSupportedZig(v("0.17.9-dev.12+abcdef") catch unreachable));
    std.debug.assert(!isSupportedZig(v("0.17.0") catch unreachable));
    std.debug.assert(!isSupportedZig(v("0.17.1-dev.3+abcdef") catch unreachable));
    std.debug.assert(!isSupportedZig(v("0.18.0") catch unreachable));
    std.debug.assert(!isSupportedZig(v("0.18.0-dev.1+abcdef") catch unreachable));
}

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        var query = target.query;
        query.os_version_min = .{ .semver = macos_deployment_target };
        target = b.resolveTargetQuery(query);
    }
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};

    const root_mod = b.addModule("zmux", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkPtyLibraries(root_mod, target);

    const daemon_mod = createRootModule(b, target, optimize, "src/daemon.zig");
    const daemon = b.addExecutable(.{
        .name = "zmuxd",
        .root_module = daemon_mod,
    });

    const smithers_daemon_mod = createRootModule(b, target, optimize, "src/daemon.zig");
    const smithers_daemon = b.addExecutable(.{
        .name = "smithers-session-daemon",
        .root_module = smithers_daemon_mod,
    });

    const connect_mod = createConnectModule(b, target, optimize);
    const connect = b.addExecutable(.{
        .name = "zmux-connect",
        .root_module = connect_mod,
    });

    const smithers_connect_mod = createConnectModule(b, target, optimize);
    const smithers_connect = b.addExecutable(.{
        .name = "smithers-session-connect",
        .root_module = smithers_connect_mod,
    });

    // iOS cannot spawn local PTY child processes; package artifacts are only
    // installed for desktop/server targets.
    if (target.result.os.tag != .ios) {
        b.installArtifact(daemon);
        b.installArtifact(smithers_daemon);
        b.installArtifact(connect);
        b.installArtifact(smithers_connect);
    }

    const test_step = b.step("test", "Run zmux unit and integration tests");

    const root_tests = b.addTest(.{ .root_module = createRootModule(b, target, optimize, "src/main.zig") });
    test_step.dependOn(&b.addRunArtifact(root_tests).step);

    const daemon_tests = b.addTest(.{ .root_module = createRootModule(b, target, optimize, "src/daemon.zig") });
    test_step.dependOn(&b.addRunArtifact(daemon_tests).step);

    const connect_tests = b.addTest(.{ .root_module = createConnectModule(b, target, optimize) });
    test_step.dependOn(&b.addRunArtifact(connect_tests).step);

    // The integration tests are an embedder: they import the exported `zmux`
    // module directly, proving downstream packages inherit libc/libutil/libproc
    // automatically without re-linking them by hand.
    const integration_options = b.addOptions();
    integration_options.addOptionPath("zmuxd_path", daemon.getEmittedBin());
    integration_options.addOptionPath("smithers_session_daemon_path", smithers_daemon.getEmittedBin());
    integration_options.addOptionPath("zmux_connect_path", connect.getEmittedBin());
    integration_options.addOptionPath("smithers_session_connect_path", smithers_connect.getEmittedBin());
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/session_daemon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmux", .module = root_mod }},
    });
    integration_mod.addOptions("test_build_options", integration_options);
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Coverage-guided structured fuzz suite (fast pure + socketpair/pipe targets).
    // Run `zig build fuzz --fuzz=100K` (or `--fuzz` for continuous webui fuzzing).
    // Also wired into `zig build test` so every corpus seed is smoke-tested on
    // every normal test run without requiring `--fuzz`.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmux", .module = root_mod }},
    });
    const fuzz_tests = b.addTest(.{
        .name = "zmux-fuzz",
        .root_module = fuzz_mod,
        .filters = test_filters,
        // Zig 0.17's self-hosted x86_64 backend does not emit SanitizerCoverage
        // PC tables in Debug mode; force LLVM so `--fuzz` always gets real
        // edge-coverage guidance.
        .use_llvm = true,
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    const fuzz_step = b.step("fuzz", "Run fast coverage-guided fuzz tests (pass --fuzz[=N] to fuzz)");
    fuzz_step.dependOn(&run_fuzz.step);
    test_step.dependOn(&run_fuzz.step);

    // Stateful real-PTY and live UNIX-socket chaos fuzzers.
    // Run `zig build fuzz-live --fuzz=200` (each iteration spawns real PTYs).
    const fuzz_live_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz/live.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmux", .module = root_mod }},
    });
    const fuzz_live_tests = b.addTest(.{
        .name = "zmux-fuzz-live",
        .root_module = fuzz_live_mod,
        .filters = test_filters,
        .use_llvm = true,
    });
    const run_fuzz_live = b.addRunArtifact(fuzz_live_tests);
    const fuzz_live_step = b.step("fuzz-live", "Run live PTY and UNIX-socket chaos fuzzers (pass --fuzz[=N] to fuzz)");
    fuzz_live_step.dependOn(&run_fuzz_live.step);
    test_step.dependOn(&run_fuzz_live.step);

    // Granular per-module unit test steps so Smithers PACKAGE.ts can run only
    // affected unit tests when a module changes.
    addUnitTestStep(b, target, optimize, "test-buffer", "src/buffer.zig", "Run buffer unit tests");
    addUnitTestStep(b, target, optimize, "test-protocol", "src/protocol.zig", "Run protocol unit tests");
    addUnitTestStep(b, target, optimize, "test-rpc-line-reader", "src/rpc_line_reader.zig", "Run rpc_line_reader unit tests");
    addUnitTestStep(b, target, optimize, "test-log", "src/log.zig", "Run log unit tests");
    addUnitTestStep(b, target, optimize, "test-foreground", "src/foreground.zig", "Run foreground unit tests");
    addUnitTestStep(b, target, optimize, "test-sys", "src/sys.zig", "Run sys unit tests");
    addUnitTestStep(b, target, optimize, "test-pty", "src/pty.zig", "Run pty unit tests");
    addUnitTestStep(b, target, optimize, "test-native", "src/native.zig", "Run native unit tests");
    addUnitTestStep(b, target, optimize, "test-mux", "src/mux.zig", "Run mux unit tests");
    addUnitTestStep(b, target, optimize, "test-connect", "src/connect.zig", "Run connect unit tests");
    addUnitTestStep(b, target, optimize, "test-server", "src/server.zig", "Run server unit tests");
    addUnitTestStep(b, target, optimize, "test-daemon", "src/daemon.zig", "Run daemon unit tests");
    addUnitTestStep(b, target, optimize, "test-main", "src/main.zig", "Run main library unit tests");
    const test_integration_step = b.step("test-integration", "Run integration test suite");
    test_integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Performance benchmarks: one independent executable per module so each
    // suite compiles and runs only its exact dependency slice. Defaults to
    // ReleaseFast so benchmark numbers reflect optimized production code.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for benchmarks (default: fast)",
    ) orelse if (optimize == .debug) .fast else optimize;

    const bench_harness_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = bench_optimize,
    });

    const bench_step = b.step("bench", "Run all zmux performance benchmark suites");

    // Helper modules scoped strictly to each benchmark's dependencies.
    const mod_buffer = createRootModule(b, target, bench_optimize, "src/buffer.zig");
    const mod_protocol = createRootModule(b, target, bench_optimize, "src/protocol.zig");
    const mod_rpc_line_reader = createRootModule(b, target, bench_optimize, "src/rpc_line_reader.zig");
    const mod_log = createRootModule(b, target, bench_optimize, "src/log.zig");
    const mod_foreground = createRootModule(b, target, bench_optimize, "src/foreground.zig");
    const mod_sys = createRootModule(b, target, bench_optimize, "src/sys.zig");
    const mod_pty = createRootModule(b, target, bench_optimize, "src/pty.zig");
    const mod_native = createRootModule(b, target, bench_optimize, "src/native.zig");
    const mod_mux = createRootModule(b, target, bench_optimize, "src/mux.zig");
    const mod_connect = createRootModule(b, target, bench_optimize, "src/connect.zig");
    const mod_daemon = createRootModule(b, target, bench_optimize, "src/daemon.zig");
    const mod_server = createRootModule(b, target, bench_optimize, "src/server.zig");

    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "buffer", "bench/buffer_bench.zig", &.{
        .{ .name = "buffer", .module = mod_buffer },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "protocol", "bench/protocol_bench.zig", &.{
        .{ .name = "protocol", .module = mod_protocol },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "rpc-line-reader", "bench/rpc_line_reader_bench.zig", &.{
        .{ .name = "rpc_line_reader", .module = mod_rpc_line_reader },
        .{ .name = "sys", .module = mod_sys },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "log", "bench/log_bench.zig", &.{
        .{ .name = "log", .module = mod_log },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "foreground", "bench/foreground_bench.zig", &.{
        .{ .name = "foreground", .module = mod_foreground },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "sys", "bench/sys_bench.zig", &.{
        .{ .name = "sys", .module = mod_sys },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "pty", "bench/pty_bench.zig", &.{
        .{ .name = "pty", .module = mod_pty },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "native", "bench/native_bench.zig", &.{
        .{ .name = "buffer", .module = mod_buffer },
        .{ .name = "native", .module = mod_native },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "mux", "bench/mux_bench.zig", &.{
        .{ .name = "mux", .module = mod_mux },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "connect", "bench/connect_bench.zig", &.{
        .{ .name = "connect", .module = mod_connect },
        .{ .name = "sys", .module = mod_sys },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "daemon", "bench/daemon_bench.zig", &.{
        .{ .name = "daemon", .module = mod_daemon },
    });
    addBenchStep(b, bench_step, target, bench_optimize, bench_harness_mod, "server", "bench/server_bench.zig", &.{
        .{ .name = "buffer", .module = mod_buffer },
        .{ .name = "rpc_line_reader", .module = mod_rpc_line_reader },
        .{ .name = "server", .module = mod_server },
        .{ .name = "sys", .module = mod_sys },
    });

    const report_mod = b.createModule(.{
        .root_source_file = b.path("bench/report.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const report_exe = b.addExecutable(.{
        .name = "zmux-bench-report",
        .root_module = report_mod,
    });
    const run_report = b.addRunArtifact(report_exe);
    run_report.addPassthruArgs();
    const report_step = b.step("bench-report", "Aggregate benchmark JSON outputs and compare against baseline");
    report_step.dependOn(&run_report.step);
}

fn addUnitTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    step_name: []const u8,
    root: []const u8,
    description: []const u8,
) void {
    const unit_tests = b.addTest(.{
        .root_module = createRootModule(b, target, optimize, root),
    });
    const step = b.step(step_name, description);
    step.dependOn(&b.addRunArtifact(unit_tests).step);
}

fn addBenchStep(
    b: *std.Build,
    all_bench_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bench_harness_mod: *std.Build.Module,
    comptime name: []const u8,
    root_path: []const u8,
    imports: []const std.Build.Module.Import,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkPtyLibraries(mod, target);
    mod.addImport("bench", bench_harness_mod);
    for (imports) |imp| mod.addImport(imp.name, imp.module);

    const exe = b.addExecutable(.{
        .name = "bench-" ++ name,
        .root_module = mod,
    });
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();

    const step = b.step("bench-" ++ name, "Run " ++ name ++ " performance benchmarks");
    step.dependOn(&run.step);

    const run_for_all = b.addRunArtifact(exe);
    run_for_all.addPassthruArgs();
    all_bench_step.dependOn(&run_for_all.step);
}

fn createRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkPtyLibraries(module, target);
    return module;
}

fn createConnectModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return createRootModule(b, target, optimize, "src/connect.zig");
}

/// `openpty(3)` lives in libutil on Linux; `proc_pidinfo(3)` in libproc on macOS.
fn linkPtyLibraries(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .linux) module.linkSystemLibrary("util", .{});
    if (target.result.os.tag == .macos) module.linkSystemLibrary("proc", .{});
}
