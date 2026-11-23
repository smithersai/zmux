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

    const connect = b.addExecutable(.{
        .name = "zmux-connect",
        .root_module = createRootModule(b, target, optimize, "src/connect.zig"),
    });

    // iOS cannot spawn local PTY child processes; package artifacts are only
    // installed for desktop/server targets.
    if (target.result.os.tag != .ios) {
        b.installArtifact(daemon);
        b.getInstallStep().dependOn(&b.addInstallArtifact(daemon, .{ .dest_sub_path = "smithers-session-daemon" }).step);
        b.installArtifact(connect);
        b.getInstallStep().dependOn(&b.addInstallArtifact(connect, .{ .dest_sub_path = "smithers-session-connect" }).step);
    }

    const test_step = b.step("test", "Run zmux unit and integration tests");

    const root_tests = b.addTest(.{ .root_module = createRootModule(b, target, optimize, "src/main.zig") });
    test_step.dependOn(&b.addRunArtifact(root_tests).step);

    // The integration tests are an embedder: they import the exported `zmux`
    // module directly, proving downstream packages inherit libc/libutil/libproc
    // automatically without re-linking them by hand.
    const integration_options = b.addOptions();
    const fixtures = b.addWriteFiles();
    integration_options.addOptionPath("zmuxd_path", fixtures.addCopyFile(daemon.getEmittedBin(), "zmuxd"));
    integration_options.addOptionPath("smithers_session_daemon_path", fixtures.addCopyFile(daemon.getEmittedBin(), "smithers-session-daemon"));
    integration_options.addOptionPath("zmux_connect_path", fixtures.addCopyFile(connect.getEmittedBin(), "zmux-connect"));
    integration_options.addOptionPath("smithers_session_connect_path", fixtures.addCopyFile(connect.getEmittedBin(), "smithers-session-connect"));
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/session_daemon.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmux", .module = root_mod }},
    });
    integration_mod.addOptions("test_build_options", integration_options);
    const integration_filter = b.option([]const u8, "integration-filter", "Run integration tests whose names contain this text");
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
        .filters = if (integration_filter) |filter| &.{filter} else &.{},
    });
    const run_integration = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration.step);
    b.step("test-integration", "Run zmux integration tests").dependOn(&run_integration.step);
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

/// `openpty(3)` lives in libutil on Linux; `proc_pidinfo(3)` in libproc on macOS.
fn linkPtyLibraries(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .linux) module.linkSystemLibrary("util", .{});
    if (target.result.os.tag == .macos) module.linkSystemLibrary("proc", .{});
}
