//! Actionable diagnostics for `zmux doctor`: inspects socket path length,
//! parent directory ownership/mode, sibling `zmuxd` binary discovery, and live
//! daemon `daemon.ping` telemetry without mutating or spawning a daemon.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const connect_terminal = @import("../connect/terminal.zig");
const connect_wire = @import("../connect/wire.zig");
const protocol = @import("../protocol.zig");
const socket_path_mod = @import("../socket_path.zig");
const sys = @import("../sys.zig");
const help = @import("help.zig");
const rpc = @import("rpc.zig");

const test_io = std.testing.io;

/// Complete diagnostic snapshot gathered by `zmux doctor`.
pub const DoctorReport = struct {
    cli_version: []const u8 = protocol.version,
    socket_path: []u8,
    socket_len: usize,
    socket_max_len: usize = sys.max_unix_path_len,
    socket_path_ok: bool,
    parent_dir: []u8,
    parent_exists: bool = false,
    parent_mode: ?u32 = null,
    parent_owned_by_self: bool = false,
    parent_secure: bool = false,
    daemon_bin: ?[]u8 = null,
    daemon_bin_found: bool = false,
    daemon_reachable: bool = false,
    daemon_version: ?[]u8 = null,
    version_matches: bool = false,
    daemon_pid: ?u64 = null,
    sessions: u64 = 0,
    panes: u64 = 0,
    live_panes: u64 = 0,
    connections: u64 = 0,
    dropped_events: u64 = 0,
    rejected_connections: u64 = 0,

    /// Free all owned slices inside the report.
    pub fn deinit(self: *DoctorReport, allocator: std.mem.Allocator) void {
        allocator.free(self.socket_path);
        allocator.free(self.parent_dir);
        if (self.daemon_bin) |b| allocator.free(b);
        if (self.daemon_version) |v| allocator.free(v);
    }
};

/// Run `zmux doctor` and write either the human checklist or `--json` object to `out_fd`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    explicit_socket: ?[]const u8,
    json: bool,
    out_fd: posix.fd_t,
) !void {
    assert(out_fd >= 0);
    var report = try inspect(allocator, io, explicit_socket);
    defer report.deinit(allocator);

    const output = if (json) try formatJson(allocator, &report) else try formatHuman(allocator, &report);
    defer allocator.free(output);
    try connect_terminal.writeAllFd(out_fd, output);
}

/// Inspect local zmux environment and optional live daemon without spawning anything.
pub fn inspect(allocator: std.mem.Allocator, io: std.Io, explicit_socket: ?[]const u8) !DoctorReport {
    const path = try socket_path_mod.resolveUnvalidated(allocator, explicit_socket, socket_path_mod.processEnv);
    errdefer allocator.free(path);
    const parent_slice = std.fs.path.dirname(path) orelse "/";
    const parent_dir = try allocator.dupe(u8, parent_slice);
    errdefer allocator.free(parent_dir);

    const path_ok = if (socket_path_mod.validate(path)) |_| true else |_| false;
    var report: DoctorReport = .{
        .socket_path = path,
        .socket_len = path.len,
        .socket_path_ok = path_ok,
        .parent_dir = parent_dir,
    };
    errdefer report.deinit(allocator);

    inspectParentDir(&report);
    try inspectDaemonBinary(allocator, io, &report);
    if (report.socket_path_ok) try inspectLiveDaemon(allocator, io, &report);
    assert(report.socket_len == report.socket_path.len);
    return report;
}

fn inspectParentDir(report: *DoctorReport) void {
    const is_managed = socket_path_mod.isDefaultManaged(report.socket_path, socket_path_mod.processEnv);
    const st = sys.statAt(sys.cwd_fd, report.parent_dir, !is_managed) catch return;
    if (!st.isDir()) return;
    const perms = st.permissions();
    const self_owned = st.uid == sys.geteuid();
    report.parent_exists = true;
    report.parent_mode = perms;
    report.parent_owned_by_self = self_owned;
    if (is_managed) {
        report.parent_secure = self_owned and (perms & 0o077 == 0);
    } else {
        const trusted_sticky = (st.uid == 0 or self_owned) and (st.mode & 0o1000 != 0);
        report.parent_secure = trusted_sticky or (self_owned and (perms & 0o022 == 0));
    }
}

fn inspectDaemonBinary(allocator: std.mem.Allocator, io: std.Io, report: *DoctorReport) !void {
    const self_path = std.process.executablePathAlloc(io, allocator) catch return;
    defer allocator.free(self_path);
    const self_dir = std.fs.path.dirname(self_path) orelse ".";
    if (try rpc.findDaemonBinary(allocator, io, self_dir)) |bin_path| {
        report.daemon_bin = bin_path;
        report.daemon_bin_found = true;
    }
}

fn inspectLiveDaemon(allocator: std.mem.Allocator, io: std.Io, report: *DoctorReport) !void {
    const deadline = sys.monotonicMs() + 500;
    const fd = rpc.tryConnectPeerVerified(io, report.socket_path, deadline) catch return;
    var client = rpc.RpcClient.initFromFd(allocator, io, fd);
    defer client.deinit();

    const resp = rpc.ping(&client, 1_000) catch return;
    defer resp.deinit(allocator);
    if (resp.rpcError() != null) return;

    const res = resp.result();
    report.daemon_reachable = true;
    if (connect_wire.jsonObjectString(res, "version")) |ver| {
        report.daemon_version = try allocator.dupe(u8, ver);
        report.version_matches = std.mem.eql(u8, ver, protocol.version);
    }
    report.daemon_pid = connect_wire.jsonUnsigned(res, "pid");
    report.sessions = connect_wire.jsonUnsigned(res, "sessions") orelse 0;
    report.panes = connect_wire.jsonUnsigned(res, "panes") orelse 0;
    report.live_panes = connect_wire.jsonUnsigned(res, "livePanes") orelse 0;
    report.connections = connect_wire.jsonUnsigned(res, "connections") orelse 0;
    report.dropped_events = connect_wire.jsonUnsigned(res, "droppedEvents") orelse 0;
    report.rejected_connections = connect_wire.jsonUnsigned(res, "rejectedConnections") orelse 0;
}

/// Format a `DoctorReport` as a concise human-readable diagnostic checklist.
pub fn formatHuman(allocator: std.mem.Allocator, report: *const DoctorReport) ![]u8 {
    assert(report.cli_version.len > 0);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("[ok]   cli version: {s}\n", .{report.cli_version});
    const path_tag = if (report.socket_path_ok) "[ok]  " else "[fail]";
    try w.print(
        "{s} socket path: {f} ({d}/{d} bytes)\n",
        .{ path_tag, help.escaped(report.socket_path), report.socket_len, report.socket_max_len },
    );

    if (report.parent_exists) {
        const dir_tag = if (report.parent_secure) "[ok]  " else "[warn]";
        try w.print(
            "{s} parent dir: {f} (mode 0{o}, owned={})\n",
            .{ dir_tag, help.escaped(report.parent_dir), report.parent_mode orelse 0, report.parent_owned_by_self },
        );
    } else {
        try w.print("[info] parent dir: {f} (not created yet)\n", .{help.escaped(report.parent_dir)});
    }

    if (report.daemon_bin) |bin| {
        try w.print("[ok]   zmuxd binary: {f}\n", .{help.escaped(bin)});
    } else {
        try w.writeAll("[warn] zmuxd binary: not found next to zmux or on PATH\n");
    }

    if (report.daemon_reachable) {
        const ver_tag = if (report.version_matches) "[ok]  " else "[warn]";
        try w.print(
            "{s} daemon live: pid={d} version={s} sessions={d} panes={d} livePanes={d} connections={d} dropped={d}\n",
            .{
                ver_tag,
                report.daemon_pid orelse 0,
                report.daemon_version orelse "unknown",
                report.sessions,
                report.panes,
                report.live_panes,
                report.connections,
                report.dropped_events,
            },
        );
    } else {
        try w.writeAll("[info] daemon live: not running at socket (will auto-spawn on attach)\n");
    }
    return out.toOwnedSlice();
}

/// Format a `DoctorReport` as a compact JSON object followed by a newline.
pub fn formatJson(allocator: std.mem.Allocator, report: *const DoctorReport) ![]u8 {
    assert(report.socket_max_len > 0);
    return std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(.{
        .cliVersion = report.cli_version,
        .socketPath = report.socket_path,
        .socketPathLen = report.socket_len,
        .socketPathMaxLen = report.socket_max_len,
        .socketPathOk = report.socket_path_ok,
        .parentDir = report.parent_dir,
        .parentExists = report.parent_exists,
        .parentMode = report.parent_mode,
        .parentOwnedBySelf = report.parent_owned_by_self,
        .parentSecure = report.parent_secure,
        .daemonBinary = report.daemon_bin,
        .daemonBinaryFound = report.daemon_bin_found,
        .daemonReachable = report.daemon_reachable,
        .daemonVersion = report.daemon_version,
        .versionMatches = report.version_matches,
        .daemonPid = report.daemon_pid,
        .sessions = report.sessions,
        .panes = report.panes,
        .livePanes = report.live_panes,
        .connections = report.connections,
        .droppedEvents = report.dropped_events,
        .rejectedConnections = report.rejected_connections,
    }, .{})});
}

test "doctor inspect and formatters produce valid JSON and readable checklist" {
    const alloc = std.testing.allocator;
    var report = try inspect(alloc, test_io, "/tmp/zmux-doctor-nonexistent.sock");
    defer report.deinit(alloc);

    try std.testing.expect(report.socket_path_ok);
    try std.testing.expect(report.parent_exists);
    try std.testing.expect(!report.daemon_reachable);

    const human = try formatHuman(alloc, &report);
    defer alloc.free(human);
    try std.testing.expect(std.mem.indexOf(u8, human, "cli version:") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "socket path:") != null);

    const json = try formatJson(alloc, &report);
    defer alloc.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(protocol.version, parsed.value.object.get("cliVersion").?.string);
    try std.testing.expectEqual(false, parsed.value.object.get("daemonReachable").?.bool);
}
