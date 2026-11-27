//! JSON views of manager state for `session.list`, `mux.snapshot`,
//! `mux.clients`, and `mux.keys`.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const Pane = types.Pane;
const Session = types.Session;
const Window = types.Window;

/// One object per pane: the native `infoJson` fields plus `sessionId`,
/// `sessionName`, `windowId`, `paneId`, and `paneTitle`.
pub fn listJson(self: *Manager, allocator: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const hint = @max(@as(usize, 64), self.panes_by_id.count() * 256);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, hint);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    for (self.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                if (!first) try out.writer.writeByte(',');
                first = false;
                try pane.native.writeInfoJsonFields(&out.writer);
                try out.writer.print(
                    ",\"sessionId\":{f},\"sessionName\":{f},\"windowId\":{f},\"paneId\":{f},\"paneTitle\":{f}}}",
                    .{
                        std.json.fmt(session.id, .{}),
                        std.json.fmt(session.name, .{}),
                        std.json.fmt(window.id, .{}),
                        std.json.fmt(pane.id, .{}),
                        std.json.fmt(pane.title, .{}),
                    },
                );
            }
        }
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

/// Serializes the full mux graph (sessions, clients, and key bindings) to JSON.
pub fn snapshotJson(self: *Manager, allocator: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const hint = 128 + self.panes_by_id.count() * 384 + self.clients.items.len * 160;
    assert(hint >= 128);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, hint);
    errdefer out.deinit();
    try out.writer.writeAll("{\"sessions\":[");
    for (self.sessions.items, 0..) |session, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeSessionJsonLocked(self, &out.writer, session);
    }
    try out.writer.writeAll("],\"clients\":");
    try writeClientsJsonLocked(self, &out.writer);
    try out.writer.writeAll(",\"keyBindings\":");
    try writeKeyBindingsJsonLocked(self, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

/// Serializes all currently attached clients to a JSON array.
pub fn clientsJson(self: *Manager, allocator: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const hint = @max(@as(usize, 64), self.clients.items.len * 160);
    assert(hint >= 64);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, hint);
    errdefer out.deinit();
    try writeClientsJsonLocked(self, &out.writer);
    return out.toOwnedSlice();
}

/// Serializes all registered prefix key bindings to a JSON array.
pub fn keysJson(self: *Manager, allocator: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const hint = @max(@as(usize, 64), self.key_bindings.items.len * 96);
    assert(hint >= 64);
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, hint);
    errdefer out.deinit();
    try writeKeyBindingsJsonLocked(self, &out.writer);
    return out.toOwnedSlice();
}

/// Writes a single session JSON object while the manager mutex is held.
pub fn writeSessionJsonLocked(self: *Manager, writer: *std.Io.Writer, session: *Session) !void {
    assert(session.windows.items.len > 0);
    try writer.print(
        "{{\"id\":{f},\"name\":{f},\"activeWindowId\":{f},\"windows\":[",
        .{
            std.json.fmt(session.id, .{}),
            std.json.fmt(session.name, .{}),
            std.json.fmt(session.active_window_id, .{}),
        },
    );
    for (session.windows.items, 0..) |window, index| {
        if (index > 0) try writer.writeByte(',');
        try writeWindowJsonLocked(self, writer, window);
    }
    try writer.writeByte(']');
    if (session.metadata.count() > 0) {
        try writer.writeAll(",\"metadata\":");
        try session.metadata.writeJson(writer);
    }
    try writer.writeByte('}');
}

/// Writes a single window JSON object while the manager mutex is held.
pub fn writeWindowJsonLocked(self: *Manager, writer: *std.Io.Writer, window: *Window) !void {
    _ = self;
    assert(window.panes.items.len > 0);
    try writer.print(
        "{{\"id\":{f},\"sessionId\":{f},\"index\":{},\"name\":{f},\"activePaneId\":{f},\"layout\":",
        .{
            std.json.fmt(window.id, .{}),
            std.json.fmt(window.session_id, .{}),
            window.index,
            std.json.fmt(window.name, .{}),
            std.json.fmt(window.active_pane_id, .{}),
        },
    );
    try window.layout.writeJson(writer);
    try writer.writeAll(",\"panes\":[");
    for (window.panes.items, 0..) |pane, index| {
        if (index > 0) try writer.writeByte(',');
        try writePaneJson(writer, pane);
    }
    try writer.writeAll("],\"zoomedPaneId\":");
    if (window.zoomed_pane_id) |zid| {
        try writer.print("{f}", .{std.json.fmt(zid, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

/// Writes the attached clients JSON array while the manager mutex is held.
pub fn writeClientsJsonLocked(self: *Manager, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (self.clients.items, 0..) |client, index| {
        if (index > 0) try writer.writeByte(',');
        try writeClientFields(
            writer,
            client.id,
            client.session_id,
            client.window_id,
            client.pane_id,
            client.rows,
            client.cols,
            client.read_only,
            client.resize_policy,
        );
    }
    try writer.writeByte(']');
}

/// Serialize one owned `ClientSnapshot` as a JSON `ClientInfo` object.
pub fn clientJson(allocator: Allocator, client: *const types.ClientSnapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 192);
    errdefer out.deinit();
    try writeClientFields(
        &out.writer,
        client.id,
        client.session_id,
        client.window_id,
        client.pane_id,
        client.rows,
        client.cols,
        client.read_only,
        client.resize_policy,
    );
    return out.toOwnedSlice();
}

fn writeClientFields(
    writer: *std.Io.Writer,
    id: []const u8,
    session_id: []const u8,
    window_id: []const u8,
    pane_id: []const u8,
    rows: u16,
    cols: u16,
    read_only: bool,
    resize_policy: types.ResizePolicy,
) !void {
    try writer.print(
        "{{\"id\":{f},\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f}," ++
            "\"rows\":{},\"cols\":{},\"active\":true,\"readOnly\":{},\"resizePolicy\":{f}}}",
        .{
            std.json.fmt(id, .{}),
            std.json.fmt(session_id, .{}),
            std.json.fmt(window_id, .{}),
            std.json.fmt(pane_id, .{}),
            rows,
            cols,
            read_only,
            std.json.fmt(resize_policy.label(), .{}),
        },
    );
}

/// Writes the key bindings JSON array while the manager mutex is held.
pub fn writeKeyBindingsJsonLocked(self: *Manager, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (self.key_bindings.items, 0..) |binding, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"table\":{f},\"key\":{f},\"command\":{f},\"repeat\":{}}}",
            .{
                std.json.fmt(binding.table, .{}),
                std.json.fmt(binding.key, .{}),
                std.json.fmt(binding.command, .{}),
                binding.repeat,
            },
        );
    }
    try writer.writeByte(']');
}

fn writePaneJson(writer: *std.Io.Writer, pane: *const Pane) !void {
    try writer.print(
        "{{\"id\":{f},\"windowId\":{f},\"sessionId\":{f},\"index\":{},\"title\":{f}," ++
            "\"hasCustomTitle\":{},\"state\":{f},\"generation\":{},\"pid\":{}," ++
            "\"rows\":{},\"cols\":{},\"cwd\":",
        .{
            std.json.fmt(pane.id, .{}),
            std.json.fmt(pane.window_id, .{}),
            std.json.fmt(pane.session_id, .{}),
            pane.index,
            std.json.fmt(pane.title, .{}),
            pane.has_custom_title,
            std.json.fmt(pane.native.state().label(), .{}),
            pane.native.generation(),
            pane.native.handle.child_pid,
            pane.spawn.rows,
            pane.spawn.cols,
        },
    );
    if (pane.spawn.cwd) |cwd| try writer.print("{f}", .{std.json.fmt(cwd, .{})}) else try writer.writeAll("null");
    try writer.print(
        ",\"command\":{f},\"alerts\":{{\"activity\":{},\"bell\":{},\"exited\":{}," ++
            "\"lastActivityMs\":{},\"lastBellMs\":{}}}",
        .{
            std.json.fmt(pane.spawn.command orelse "", .{}),
            pane.alerts.activity,
            pane.alerts.bell,
            pane.alerts.exited,
            pane.alerts.last_activity_ms,
            pane.alerts.last_bell_ms,
        },
    );
    if (pane.metadata.count() > 0) {
        try writer.writeAll(",\"metadata\":");
        try pane.metadata.writeJson(writer);
    }
    try writer.writeByte('}');
}

test "mux manager creates session window and pane state" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{ .title = "one", .shell = "/bin/sh", .command = "cat" });

    defer pane.deinit();
    try std.testing.expect(std.mem.startsWith(u8, pane.session_id, "sess-"));
    try std.testing.expect(std.mem.startsWith(u8, pane.window_id, "win-"));
    try std.testing.expect(std.mem.startsWith(u8, pane.pane_id, "pane-"));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"windows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"panes\"") != null);
}

test "snapshot omits dead pane silence field and reports attached clients active" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer pane.deinit();
    var client = try manager.attachClient(pane.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"silence\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"active\":true") != null);
}
