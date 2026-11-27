//! Stateful real-PTY and live UNIX-socket chaos fuzzers for zmux.
//!
//! Run corpus smoke pass:
//!   zig build fuzz-live
//!
//! Run coverage-guided live fuzzing:
//!   zig build fuzz-live --fuzz=200

const std = @import("std");
const builtin = @import("builtin");
const zmux = @import("zmux");
const corpus = @import("corpus.zig");

const mux = zmux.mux;
const Server = zmux.Server;
const sys = zmux.sys;
const LineReader = zmux.internal.rpc_line_reader.LineReader;

const max_live_panes: usize = 4;

fn freeIdList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |id| allocator.free(id);
    list.deinit(allocator);
}

fn verifyManagerJsonAndInvariants(allocator: std.mem.Allocator, manager: *mux.Manager) !void {
    try manager.checkInvariants(allocator);
    try std.testing.expect(manager.count() <= manager.paneCount());

    const snap = try manager.snapshotJson(allocator);
    defer allocator.free(snap);
    var p_snap = try std.json.parseFromSlice(std.json.Value, allocator, snap, .{});
    defer p_snap.deinit();
    try std.testing.expect(p_snap.value == .object);
    try std.testing.expectEqual(manager.sessionCount(), p_snap.value.object.get("sessions").?.array.items.len);

    const list = try manager.listJson(allocator);
    defer allocator.free(list);
    var p_list = try std.json.parseFromSlice(std.json.Value, allocator, list, .{});
    defer p_list.deinit();
    try std.testing.expect(p_list.value == .array);
    try std.testing.expectEqual(manager.paneCount(), p_list.value.array.items.len);

    const clients = try manager.clientsJson(allocator);
    defer allocator.free(clients);
    var p_clients = try std.json.parseFromSlice(std.json.Value, allocator, clients, .{});
    defer p_clients.deinit();
    try std.testing.expect(p_clients.value == .array);

    const keys = try manager.keysJson(allocator);
    defer allocator.free(keys);
    var p_keys = try std.json.parseFromSlice(std.json.Value, allocator, keys, .{});
    defer p_keys.deinit();
    try std.testing.expect(p_keys.value == .array);
}

fn fuzzLiveMuxManager(_: void, smith: *std.testing.Smith) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var manager = mux.Manager.init(allocator, io, null);
    defer manager.deinit();

    var session_ids: std.ArrayList([]u8) = .empty;
    defer freeIdList(allocator, &session_ids);
    var window_ids: std.ArrayList([]u8) = .empty;
    defer freeIdList(allocator, &window_ids);
    var pane_ids: std.ArrayList([]u8) = .empty;
    defer freeIdList(allocator, &pane_ids);
    var client_ids: std.ArrayList([]u8) = .empty;
    defer freeIdList(allocator, &client_ids);

    const Op = enum(u8) {
        create_session,
        new_window,
        split_pane,
        select_pane,
        select_window,
        rename_entities,
        respawn_pane,
        attach_client,
        detach_client,
        switch_client,
        bind_and_dispatch,
        send_and_capture,
        resize_pane,
        mark_alerts_and_reap,
        terminate_target,
    };

    var name_buf: [32]u8 = undefined;
    var input_buf: [64]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 14) : (steps += 1) {
        const op = smith.value(Op);
        switch (op) {
            .create_session => {
                if (manager.paneCount() >= max_live_panes) continue;
                const title = corpus.drawAsciiSlice(smith, &name_buf);
                const cmd: []const u8 = if (smith.value(bool)) "cat" else "exit 0";
                var pane = try manager.createSessionPane(.{
                    .title = if (title.len > 0) title else null,
                    .shell = "/bin/sh",
                    .command = cmd,
                    .rows = smith.valueRangeAtMost(u16, 1, 100),
                    .cols = smith.valueRangeAtMost(u16, 1, 200),
                    .scrollback_bytes = 2048,
                });
                defer pane.deinit();
                try session_ids.append(allocator, try allocator.dupe(u8, pane.session_id));
                try window_ids.append(allocator, try allocator.dupe(u8, pane.window_id));
                try pane_ids.append(allocator, try allocator.dupe(u8, pane.pane_id));
            },
            .new_window => {
                if (manager.paneCount() >= max_live_panes or session_ids.items.len == 0) continue;
                const sid = session_ids.items[smith.index(session_ids.items.len)];
                const title = corpus.drawAsciiSlice(smith, &name_buf);
                if (manager.newWindow(sid, .{
                    .title = if (title.len > 0) title else null,
                    .shell = "/bin/sh",
                    .command = "cat",
                    .scrollback_bytes = 2048,
                })) |handle| {
                    var pane = handle;
                    defer pane.deinit();
                    try window_ids.append(allocator, try allocator.dupe(u8, pane.window_id));
                    try pane_ids.append(allocator, try allocator.dupe(u8, pane.pane_id));
                } else |_| {}
            },
            .split_pane => {
                if (manager.paneCount() >= max_live_panes or pane_ids.items.len == 0) continue;
                const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                const axis = smith.value(mux.Axis);
                if (manager.splitPane(pid, axis, .{
                    .shell = "/bin/sh",
                    .command = "cat",
                    .scrollback_bytes = 2048,
                })) |handle| {
                    var pane = handle;
                    defer pane.deinit();
                    try pane_ids.append(allocator, try allocator.dupe(u8, pane.pane_id));
                } else |_| {}
            },
            .select_pane => {
                if (pane_ids.items.len == 0) continue;
                const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                manager.selectPane(pid) catch {};
            },
            .select_window => {
                if (window_ids.items.len == 0) continue;
                const wid = window_ids.items[smith.index(window_ids.items.len)];
                manager.selectWindow(wid) catch {};
            },
            .rename_entities => {
                const new_name = corpus.drawAsciiSlice(smith, &name_buf);
                if (session_ids.items.len > 0) {
                    manager.renameSession(session_ids.items[smith.index(session_ids.items.len)], new_name) catch {};
                }
                if (window_ids.items.len > 0) {
                    manager.renameWindow(window_ids.items[smith.index(window_ids.items.len)], new_name) catch {};
                }
                if (pane_ids.items.len > 0) {
                    manager.renamePane(pane_ids.items[smith.index(pane_ids.items.len)], new_name, smith.value(bool)) catch {};
                }
            },
            .respawn_pane => {
                if (pane_ids.items.len == 0) continue;
                const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                if (manager.respawnPane(pid, .{ .kill = smith.value(bool) })) |native| {
                    native.release();
                } else |_| {}
            },
            .attach_client => {
                if (pane_ids.items.len == 0) continue;
                const target = if (smith.value(bool))
                    pane_ids.items[smith.index(pane_ids.items.len)]
                else
                    session_ids.items[smith.index(session_ids.items.len)];
                if (manager.attachClient(target, smith.valueRangeAtMost(u16, 1, 80), smith.valueRangeAtMost(u16, 1, 160))) |*snap_val| {
                    var snap = snap_val.*;
                    defer snap.deinit(allocator);
                    try client_ids.append(allocator, try allocator.dupe(u8, snap.id));
                } else |_| {}
            },
            .detach_client => {
                if (client_ids.items.len == 0) continue;
                const idx = smith.index(client_ids.items.len);
                _ = manager.detachClient(client_ids.items[idx]);
                allocator.free(client_ids.swapRemove(idx));
            },
            .switch_client => {
                if (client_ids.items.len == 0 or pane_ids.items.len == 0) continue;
                const cid = client_ids.items[smith.index(client_ids.items.len)];
                const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                manager.switchClient(cid, pid) catch {};
            },
            .bind_and_dispatch => {
                const cmds = [_][]const u8{
                    "split-window -h cat",
                    "new-window -n w cat",
                    "respawn-pane",
                    "invalid-cmd",
                };
                const chosen = cmds[smith.index(cmds.len)];
                if (std.mem.eql(u8, chosen, "invalid-cmd")) {
                    try std.testing.expectError(
                        error.InvalidParams,
                        manager.bindKey("prefix", "k", chosen, smith.value(bool)),
                    );
                } else {
                    try manager.bindKey("prefix", "k", chosen, smith.value(bool));
                    if (pane_ids.items.len > 0 and manager.paneCount() < max_live_panes) {
                        const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                        if (manager.executeBinding("prefix", "k", pid)) |maybe_cmd| {
                            if (maybe_cmd) |owned| allocator.free(owned);
                        } else |_| {}
                    }
                }
            },
            .send_and_capture => {
                if (pane_ids.items.len == 0) continue;
                const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                if (manager.find(pid)) |native| {
                    defer native.release();
                    const text = corpus.drawAsciiSlice(smith, &input_buf);
                    native.send(text, smith.value(bool)) catch {};
                    const keys = [_][]const u8{ "Enter", "C-c", "ArrowUp", "F5", "Unknown" };
                    native.sendKey(keys[smith.index(keys.len)]) catch {};
                    const cap = try native.capture(allocator, smith.valueRangeAtMost(u8, 0, 20));
                    allocator.free(cap);
                    const sb = try native.scrollbackSnapshot(allocator);
                    allocator.free(sb);
                }
            },
            .resize_pane => {
                if (pane_ids.items.len == 0) continue;
                const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                if (manager.find(pid)) |native| {
                    defer native.release();
                    native.resize(smith.valueRangeAtMost(u16, 1, 200), smith.valueRangeAtMost(u16, 1, 100)) catch {};
                }
            },
            .mark_alerts_and_reap => {
                if (pane_ids.items.len > 0) {
                    const pid = pane_ids.items[smith.index(pane_ids.items.len)];
                    if (manager.find(pid)) |native| {
                        const generation = native.generation();
                        native.release();
                        manager.markActivity(pid, generation, 1);
                        manager.markBell(pid, generation, 1);
                        if (smith.value(bool)) manager.markExited(pid, generation);
                    }
                }
                manager.reapExitedPanes();
            },
            .terminate_target => {
                if (smith.value(bool) and pane_ids.items.len > 0) {
                    const idx = smith.index(pane_ids.items.len);
                    _ = manager.terminate(pane_ids.items[idx]);
                    allocator.free(pane_ids.swapRemove(idx));
                } else if (session_ids.items.len > 0) {
                    const idx = smith.index(session_ids.items.len);
                    _ = manager.terminate(session_ids.items[idx]);
                    allocator.free(session_ids.swapRemove(idx));
                }
            },
        }

        try verifyManagerJsonAndInvariants(allocator, &manager);
    }
}

const ServerRunner = struct {
    server: *Server,

    fn run(self: ServerRunner) void {
        self.server.run() catch {};
    }
};

fn readResponseMatchingId(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *LineReader,
    fd: std.posix.fd_t,
    expected_id: i64,
) !std.json.Parsed(std.json.Value) {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (true) {
        const line = try reader.readLineAllocTimeout(allocator, io, fd, 1024 * 1024, .{
            .deadline = .{ .raw = deadline, .clock = .awake },
        });
        defer allocator.free(line);

        var parsed = try corpus.parseSingleLineJsonObject(allocator, line);
        errdefer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
        if (obj.get("id")) |id_val| {
            if (id_val == .integer and id_val.integer == expected_id) {
                return parsed;
            }
        }
        parsed.deinit();
    }
}

fn fuzzLiveUnixSocketServerChaos(_: void, smith: *std.testing.Smith) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    // Chaos clients disconnect at arbitrary points, so the daemon's expected
    // warnings (for example `socket_send_timeout_failed` with EINVAL when
    // macOS rejects SO_SNDTIMEO on an already-reset peer) are not failures.
    const saved_log_level = zmux.internal.log.getLevel();
    zmux.internal.log.setLevel(.err);
    defer zmux.internal.log.setLevel(saved_log_level);

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    const nonce = std.mem.readInt(u64, &seed_bytes, .little);
    const root = if (builtin.os.tag.isDarwin()) "/private/tmp" else "/tmp";
    const socket_path = try std.fmt.allocPrint(allocator, "{s}/zmx-fz-{x:0>16}.sock", .{ root, nonce });
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = Server.init(allocator, io, socket_path, 0) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer srv.deinit();

    const srv_thread = try std.Thread.spawn(.{}, ServerRunner.run, .{ServerRunner{ .server = &srv }});
    var thread_joined = false;
    defer if (!thread_joined) {
        srv.running.store(false, .seq_cst);
        srv_thread.join();
    };

    // Open a primary control connection plus optional chaos connections.
    const ctrl_fd = try sys.connectUnix(socket_path);
    defer sys.close(ctrl_fd);
    var ctrl_reader: LineReader = .{};

    var created_pane_id: ?[]u8 = null;
    defer if (created_pane_id) |id| allocator.free(id);
    var attached_client_id: ?[]u8 = null;
    defer if (attached_client_id) |id| allocator.free(id);

    const Action = enum(u8) {
        ping,
        create_session,
        attach_client,
        send_text_and_b64,
        resize_and_capture,
        split_or_window,
        rename_and_snapshot,
        detach_client,
        chaos_client_garbage,
        terminate_session,
    };

    var next_id: i64 = 1;
    var tmp_buf: [128]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 10) : (steps += 1) {
        switch (smith.value(Action)) {
            .ping => {
                const req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"daemon.ping\"}}\n", .{next_id});
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                try std.testing.expect(resp.value.object.get("result") != null);
                next_id += 1;
            },
            .create_session => {
                if (created_pane_id != null) continue;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.create\",\"params\":{{\"id\":\"fuzz\",\"shell\":\"/bin/sh\",\"command\":\"cat\",\"rows\":24,\"cols\":80,\"scrollbackBytes\":4096}}}}\n",
                    .{next_id},
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                const res = resp.value.object.get("result").?.object;
                created_pane_id = try allocator.dupe(u8, res.get("id").?.string);
                next_id += 1;
            },
            .attach_client => {
                const target = created_pane_id orelse "nonexistent";
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"client.attach\",\"params\":{{\"paneId\":{f},\"rows\":30,\"cols\":100}}}}\n",
                    .{ next_id, std.json.fmt(target, .{}) },
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                if (resp.value.object.get("result")) |res| {
                    if (attached_client_id) |old| allocator.free(old);
                    attached_client_id = try allocator.dupe(u8, res.object.get("clientId").?.string);
                }
                next_id += 1;
            },
            .send_text_and_b64 => {
                const target = created_pane_id orelse "nonexistent";
                const payload = corpus.drawAsciiSlice(smith, &tmp_buf);
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.send\",\"params\":{{\"sessionId\":{f},\"text\":{f},\"enter\":true}}}}\n",
                    .{ next_id, std.json.fmt(target, .{}), std.json.fmt(payload, .{}) },
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                next_id += 1;
            },
            .resize_and_capture => {
                const target = created_pane_id orelse "nonexistent";
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.capture\",\"params\":{{\"sessionId\":{f},\"lines\":20}}}}\n",
                    .{ next_id, std.json.fmt(target, .{}) },
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                next_id += 1;
            },
            .split_or_window => {
                const target = created_pane_id orelse continue;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"pane.split\",\"params\":{{\"paneId\":{f},\"axis\":\"horizontal\",\"shell\":\"/bin/sh\",\"command\":\"cat\",\"scrollbackBytes\":2048}}}}\n",
                    .{ next_id, std.json.fmt(target, .{}) },
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                next_id += 1;
            },
            .rename_and_snapshot => {
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"mux.snapshot\"}}\n",
                    .{next_id},
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                try std.testing.expect(resp.value.object.get("result") != null);
                next_id += 1;
            },
            .detach_client => {
                const cid = attached_client_id orelse continue;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"client.detach\",\"params\":{{\"clientId\":{f}}}}}\n",
                    .{ next_id, std.json.fmt(cid, .{}) },
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                allocator.free(cid);
                attached_client_id = null;
                next_id += 1;
            },
            .chaos_client_garbage => {
                // Separate client sends arbitrary malformed bytes and disconnects abruptly!
                const chaos_fd = try sys.connectUnix(socket_path);
                defer sys.close(chaos_fd);
                const garbage = corpus.drawBytes(smith, &tmp_buf);
                if (std.mem.indexOf(u8, garbage, "daemon.shutdown") == null and
                    std.mem.indexOf(u8, garbage, "session.create") == null)
                {
                    sys.sendAll(chaos_fd, garbage) catch {};
                    sys.sendAll(chaos_fd, "\n") catch {};
                }
            },
            .terminate_session => {
                const target = created_pane_id orelse continue;
                const req = try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session.terminate\",\"params\":{{\"sessionId\":{f}}}}}\n",
                    .{ next_id, std.json.fmt(target, .{}) },
                );
                defer allocator.free(req);
                try sys.sendAll(ctrl_fd, req);
                var resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
                defer resp.deinit();
                allocator.free(target);
                created_pane_id = null;
                next_id += 1;
            },
        }
    }

    // Liveness check after chaos: server must still answer daemon.ping and shut down cleanly.
    const ping_req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"daemon.ping\"}}\n", .{next_id});
    defer allocator.free(ping_req);
    try sys.sendAll(ctrl_fd, ping_req);
    var ping_resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
    ping_resp.deinit();
    next_id += 1;

    const shut_req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"daemon.shutdown\"}}\n", .{next_id});
    defer allocator.free(shut_req);
    try sys.sendAll(ctrl_fd, shut_req);
    var shut_resp = try readResponseMatchingId(allocator, io, &ctrl_reader, ctrl_fd, next_id);
    shut_resp.deinit();

    srv_thread.join();
    thread_joined = true;
}

const EventRecorder = struct {
    output_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    activity_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    bell_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    exit_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn emit(context: *anyopaque, event: zmux.native.Event) void {
        const self: *EventRecorder = @ptrCast(@alignCast(context));
        switch (event) {
            .pane_output => |e| _ = self.output_bytes.fetchAdd(e.data.len, .seq_cst),
            .pane_activity => _ = self.activity_count.fetchAdd(1, .seq_cst),
            .pane_bell => _ = self.bell_count.fetchAdd(1, .seq_cst),
            .session_exited => _ = self.exit_count.fetchAdd(1, .seq_cst),
            .foreground_changed => {},
        }
    }
};

fn fuzzLiveNativeSessionPty(_: void, smith: *std.testing.Smith) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var recorder: EventRecorder = .{};
    const scrollback_cap: usize = switch (smith.valueRangeAtMost(u8, 0, 2)) {
        0 => 64,
        1 => 512,
        else => 4096,
    };

    var title_buf: [32]u8 = undefined;
    const title = corpus.drawAsciiSlice(smith, &title_buf);

    const session = try zmux.NativeSession.create(allocator, io, .{
        .id = "fuzz-pty",
        .title = if (title.len > 0) title else null,
        .shell = "/bin/sh",
        .command = "cat",
        .rows = smith.valueRangeAtMost(u16, 1, 120),
        .cols = smith.valueRangeAtMost(u16, 1, 240),
        .scrollback_bytes = scrollback_cap,
        .event_sink = .{
            .context = &recorder,
            .emit = EventRecorder.emit,
        },
    });
    defer session.release();

    try std.testing.expectEqual(zmux.native.NativeSessionState.running, session.state());

    var input_buf: [64]u8 = undefined;
    var steps: usize = 0;
    while (!smith.eos() and steps < 8) : (steps += 1) {
        switch (smith.valueRangeAtMost(u8, 0, 4)) {
            0 => {
                // Send printable ASCII (avoiding Ctrl-D/Ctrl-C so cat stays up) + optional BEL.
                const byte_weights: []const std.testing.Smith.Weight = &.{
                    .rangeAtMost(u8, 'a', 'z', 4),
                    .value(u8, '\n', 2),
                    .value(u8, 0x07, 1),
                };
                const len = smith.sliceWeightedBytes(&input_buf, byte_weights);
                session.send(input_buf[0..len], smith.value(bool)) catch {};
            },
            1 => {
                session.resize(
                    smith.valueRangeAtMost(u16, 1, 240),
                    smith.valueRangeAtMost(u16, 1, 120),
                ) catch {};
            },
            2 => {
                const info = try session.infoJson(allocator);
                defer allocator.free(info);
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, info, .{});
                defer parsed.deinit();
                try std.testing.expect(parsed.value == .object);
                try std.testing.expectEqualStrings("fuzz-pty", parsed.value.object.get("id").?.string);
                try std.testing.expect(parsed.value.object.get("scrollbackBytes").?.integer <= scrollback_cap);
            },
            3 => {
                const cap = try session.capture(allocator, smith.valueRangeAtMost(u8, 0, 32));
                defer allocator.free(cap);
                try std.testing.expect(cap.len <= scrollback_cap);
                const snap = try session.scrollbackSnapshot(allocator);
                defer allocator.free(snap);
                try std.testing.expect(snap.len <= scrollback_cap);
            },
            else => {
                const keys = [_][]const u8{ "Enter", "Tab", "ArrowUp", "F1", "BogusKey" };
                session.sendKey(keys[smith.index(keys.len)]) catch {};
            },
        }
    }

    session.terminate();
    try std.testing.expectEqual(zmux.native.NativeSessionState.terminated, session.state());
}

fn fuzzLivePrivateSocketBinding(_: void, smith: *std.testing.Smith) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    const nonce = std.mem.readInt(u64, &seed_bytes, .little);
    const root = if (builtin.os.tag.isDarwin()) "/private/tmp" else "/tmp";
    const parent = try std.fmt.allocPrint(allocator, "{s}/zfz-{x:0>12}", .{ root, nonce & 0xffff_ffff_ffff });
    defer allocator.free(parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};

    const Scenario = enum(u8) {
        missing_parent_created_private,
        existing_shared_parent_untouched,
        replace_stale_socket,
        at_sun_path_limit_private,
        over_sun_path_limit_rejected_cleanly,
        replacement_socket_preserved_on_deinit,
    };

    switch (smith.value(Scenario)) {
        .missing_parent_created_private => {
            const socket_path = try std.fs.path.join(allocator, &.{ parent, "s.sock" });
            defer allocator.free(socket_path);

            var srv = Server.init(allocator, io, socket_path, 0) catch |err| switch (err) {
                error.AccessDenied => return error.SkipZigTest,
                else => return err,
            };
            defer srv.deinit();

            const p_stat = try sys.statAt(sys.cwd_fd, parent, true);
            try std.testing.expectEqual(@as(u32, 0o700), p_stat.permissions());
            const s_stat = try sys.statAt(sys.cwd_fd, socket_path, false);
            try std.testing.expect(s_stat.isSocket());
            try std.testing.expectEqual(@as(u32, 0o600), s_stat.permissions());
        },
        .existing_shared_parent_untouched => {
            try sys.mkdir(parent, 0o755);
            try sys.fchmodat(sys.cwd_fd, parent, 0o755);
            const socket_path = try std.fs.path.join(allocator, &.{ parent, "s.sock" });
            defer allocator.free(socket_path);

            var srv = Server.init(allocator, io, socket_path, 0) catch |err| switch (err) {
                error.AccessDenied => return error.SkipZigTest,
                else => return err,
            };
            defer srv.deinit();

            const p_stat = try sys.statAt(sys.cwd_fd, parent, true);
            try std.testing.expectEqual(@as(u32, 0o755), p_stat.permissions());
            const s_stat = try sys.statAt(sys.cwd_fd, socket_path, false);
            try std.testing.expectEqual(@as(u32, 0o600), s_stat.permissions());

            // Must leave zero staging directories behind.
            var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{ .iterate = true });
            defer dir.close(io);
            var it = dir.iterate();
            var count: usize = 0;
            while (try it.next(io)) |_| count += 1;
            try std.testing.expectEqual(@as(usize, 1), count);
        },
        .replace_stale_socket => {
            try sys.mkdir(parent, 0o700);
            const socket_path = try std.fs.path.join(allocator, &.{ parent, "s.sock" });
            defer allocator.free(socket_path);

            const stale_addr = try sys.UnixAddress.init(socket_path);
            const stale_fd = try sys.unixStreamSocket();
            sys.bind(stale_fd, &stale_addr) catch |err| switch (err) {
                error.AccessDenied => {
                    sys.close(stale_fd);
                    return error.SkipZigTest;
                },
                else => {
                    sys.close(stale_fd);
                    return err;
                },
            };
            try sys.listen(stale_fd, 1);
            sys.close(stale_fd);
            const stale_stat = try sys.statAt(sys.cwd_fd, socket_path, false);

            var srv = try Server.init(allocator, io, socket_path, 0);
            defer srv.deinit();
            const live_stat = try sys.statAt(sys.cwd_fd, socket_path, false);
            try std.testing.expect(live_stat.ino != stale_stat.ino or live_stat.dev != stale_stat.dev);
            try std.testing.expectEqual(@as(u32, 0o600), live_stat.permissions());
        },
        .at_sun_path_limit_private => {
            const max_len = zmux.server.max_socket_path_len;
            const socket_path = try allocator.alloc(u8, max_len);
            defer allocator.free(socket_path);
            @memset(socket_path, 's');
            @memcpy(socket_path[0..parent.len], parent);
            socket_path[parent.len] = '/';

            var srv = Server.init(allocator, io, socket_path, 0) catch |err| switch (err) {
                error.AccessDenied => return error.SkipZigTest,
                else => return err,
            };
            defer srv.deinit();

            const s_stat = try sys.statAt(sys.cwd_fd, socket_path, false);
            try std.testing.expectEqual(@as(u32, 0o600), s_stat.permissions());
        },
        .over_sun_path_limit_rejected_cleanly => {
            const over_len = zmux.server.max_socket_path_len + 1 + smith.valueRangeAtMost(u8, 0, 32);
            const socket_path = try allocator.alloc(u8, over_len);
            defer allocator.free(socket_path);
            @memset(socket_path, 's');
            @memcpy(socket_path[0..parent.len], parent);
            socket_path[parent.len] = '/';

            try std.testing.expectError(error.SocketPathTooLong, Server.init(allocator, io, socket_path, 0));
            // Must reject BEFORE creating the parent directory.
            try std.testing.expectError(error.FileNotFound, sys.statAt(sys.cwd_fd, parent, false));
        },
        .replacement_socket_preserved_on_deinit => {
            const socket_path = try std.fs.path.join(allocator, &.{ parent, "s.sock" });
            defer allocator.free(socket_path);

            var srv = Server.init(allocator, io, socket_path, 0) catch |err| switch (err) {
                error.AccessDenied => return error.SkipZigTest,
                else => return err,
            };
            try std.Io.Dir.deleteFileAbsolute(io, socket_path);
            const repl_addr = try sys.UnixAddress.init(socket_path);
            const repl_fd = try sys.unixStreamSocket();
            defer sys.close(repl_fd);
            try sys.bind(repl_fd, &repl_addr);
            try sys.listen(repl_fd, 1);

            srv.deinit();
            // Replacement socket must still exist after original server deinit!
            _ = try sys.statAt(sys.cwd_fd, socket_path, false);
        },
    }
}

fn fuzzLiveDaemonPidLockAndProbe(_: void, smith: *std.testing.Smith) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dhooks = zmux.daemon.fuzz_hooks;

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    const nonce = std.mem.readInt(u64, &seed_bytes, .little);
    const root = if (builtin.os.tag.isDarwin()) "/private/tmp" else "/tmp";
    const sock = try std.fmt.allocPrint(allocator, "{s}/zdp-{x:0>12}.sock", .{ root, nonce & 0xffff_ffff_ffff });
    defer allocator.free(sock);

    const pid_path = try dhooks.pidPathFn(allocator, sock);
    defer allocator.free(pid_path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{sock});
    defer allocator.free(lock_path);
    defer std.Io.Dir.deleteFileAbsolute(io, lock_path) catch {};

    // 1. Validate the socket directory and take the start lock inside it,
    // optionally re-acquiring after release.
    var start = try dhooks.openStartContextFn(sock, dhooks.envGetFn, 500, null);
    defer start.deinit();
    const names = dhooks.siblingNamesFn(sock);
    defer std.Io.Dir.deleteFileAbsolute(io, pid_path) catch {};

    // 2. Write the PID file through the pinned directory, verify contents and
    // 0600 permissions, then remove it only while it is still ours.
    const rounds = smith.valueRangeAtMost(u8, 1, 3);
    for (0..rounds) |_| {
        const written = try dhooks.writePidFileFn(start.dir_fd, names.pid());
        const st = try sys.statAt(sys.cwd_fd, pid_path, false);
        try std.testing.expectEqual(@as(u32, 0o600), st.permissions());
        const content = try std.Io.Dir.cwd().readFileAlloc(io, pid_path, allocator, .limited(64));
        defer allocator.free(content);
        const expected = try std.fmt.allocPrint(allocator, "{}\n", .{sys.getpid()});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, content);
        dhooks.removePidFileFn(start.dir_fd, names.pid(), written);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, pid_path, .{}));
    }
}

fn fuzzLiveMuxOomAtomicity(_: void, smith: *std.testing.Smith) !void {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Create a small 2-window, 2-pane manager under a FailingAllocator that
    // only starts failing AFTER setup completes, then verify OOM during
    // selectPane / switchClient / renameSession / renameWindow / renamePane /
    // attachClient leaves invariants intact and leaks zero bytes!
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    const fa = failing.allocator();

    var manager = mux.Manager.init(fa, io, null);
    defer manager.deinit();

    var p1 = try manager.createSessionPane(.{
        .title = "s1",
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 512,
    });
    const p1_id = try allocator.dupe(u8, p1.pane_id);
    defer allocator.free(p1_id);
    const s1_id = try allocator.dupe(u8, p1.session_id);
    defer allocator.free(s1_id);
    const w1_id = try allocator.dupe(u8, p1.window_id);
    defer allocator.free(w1_id);
    p1.deinit();

    var p2 = try manager.newWindow(s1_id, .{
        .title = "w2",
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 512,
    });
    const p2_id = try allocator.dupe(u8, p2.pane_id);
    defer allocator.free(p2_id);
    p2.deinit();

    var c = try manager.attachClient(p1_id, 24, 80);
    const cid = try allocator.dupe(u8, c.id);
    defer allocator.free(cid);
    c.deinit(fa);

    // Arm failure at a fuzzed offset from current allocation count!
    const offset = smith.valueRangeAtMost(u8, 0, 6);
    failing.fail_index = failing.alloc_index + offset;

    switch (smith.valueRangeAtMost(u8, 0, 5)) {
        0 => manager.selectPane(p1_id) catch {},
        1 => manager.switchClient(cid, p2_id) catch {},
        2 => manager.renameSession(s1_id, "new-session-name") catch {},
        3 => manager.renameWindow(w1_id, "new-window-name") catch {},
        4 => manager.renamePane(p1_id, "new-pane-title", true) catch {},
        else => {
            if (manager.attachClient(p2_id, 30, 100)) |*snap_val| {
                var snap = snap_val.*;
                snap.deinit(fa);
            } else |_| {}
        },
    }

    // Disarm OOM so invariant check & snapshot serialization can run with `allocator`.
    failing.fail_index = std.math.maxInt(usize);
    try manager.checkInvariants(allocator);

    // Also verify every client's (session_id, window_id, pane_id) triple is
    // internally consistent (never half-switched!).
    manager.mutex.lockUncancelable(io);
    defer manager.mutex.unlock(io);
    for (manager.clients.items) |client| {
        var found = false;
        for (manager.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (std.mem.eql(u8, pane.id, client.pane_id)) {
                        try std.testing.expectEqualStrings(session.id, client.session_id);
                        try std.testing.expectEqualStrings(window.id, client.window_id);
                        found = true;
                    }
                }
            }
        }
        try std.testing.expect(found);
    }
}

test "fuzz-live: mux.Manager stateful PTY model checker" {
    try std.testing.fuzz({}, fuzzLiveMuxManager, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .eos = false },
                .{ .int = 0 }, // create_session
                .{ .slice = "work" },
                .{ .int = 1 }, // cat
                .{ .int = 24 },
                .{ .int = 80 },
                .{ .eos = false },
                .{ .int = 2 }, // split_pane
                .{ .int = 0 },
                .{ .int = 0 },
                .{ .eos = false },
                .{ .int = 7 }, // attach_client
                .{ .int = 1 },
                .{ .int = 0 },
                .{ .int = 30 },
                .{ .int = 100 },
                .{ .eos = false },
                .{ .int = 14 }, // terminate_target
                .{ .int = 1 },
                .{ .int = 0 },
                .{ .eos = true },
            }),
        },
    });
}

test "fuzz-live: Server multi-client UNIX-socket JSON-RPC chaos" {
    try std.testing.fuzz({}, fuzzLiveUnixSocketServerChaos, .{
        .corpus = &.{
            corpus.seed(&.{
                .{ .eos = false },
                .{ .int = 0 }, // ping
                .{ .eos = false },
                .{ .int = 1 }, // create_session
                .{ .eos = false },
                .{ .int = 2 }, // attach_client
                .{ .eos = false },
                .{ .int = 8 }, // chaos_client_garbage
                .{ .slice = "{not json" },
                .{ .eos = false },
                .{ .int = 9 }, // terminate_session
                .{ .eos = true },
            }),
        },
    });
}

test "fuzz-live: NativeSession PTY I/O, resize, scrollback, and event sink" {
    try std.testing.fuzz({}, fuzzLiveNativeSessionPty, .{});
}

test "fuzz-live: Server private socket binding, permissions, and sun_path limits" {
    try std.testing.fuzz({}, fuzzLivePrivateSocketBinding, .{});
}

test "fuzz-live: daemon atomic pid file, start lock, and socket liveness probes" {
    try std.testing.fuzz({}, fuzzLiveDaemonPidLockAndProbe, .{});
}

test "fuzz-live: mux.Manager OOM atomicity across select, switch, attach, and rename" {
    try std.testing.fuzz({}, fuzzLiveMuxOomAtomicity, .{
        .corpus = &.{
            // Regression seed: OOM on 3rd allocation inside switchClient
            // (previously tore client.window_id vs client.pane_id).
            corpus.seed(&.{ .{ .int = 2 }, .{ .int = 1 } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .int = 0 } }),
            corpus.seed(&.{ .{ .int = 1 }, .{ .int = 5 } }),
        },
    });
}
