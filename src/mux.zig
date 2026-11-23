const std = @import("std");

const buffer = @import("buffer.zig");
const native_mod = @import("native.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const NativeSessionOptions = native_mod.NativeSessionOptions;

pub const Axis = enum {
    horizontal,
    vertical,

    pub fn label(self: Axis) []const u8 {
        return @tagName(self);
    }
};

pub const SpawnSpec = struct {
    title: ?[]u8 = null,
    shell: ?[]u8 = null,
    command: ?[]u8 = null,
    cwd: ?[]u8 = null,
    env: ?[][]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,

    pub fn fromOptions(allocator: Allocator, opts: CreateOptions) !SpawnSpec {
        var spec: SpawnSpec = .{
            .rows = opts.rows,
            .cols = opts.cols,
            .scrollback_bytes = opts.scrollback_bytes,
        };
        errdefer spec.deinit(allocator);

        spec.title = try dupeOpt(allocator, opts.title);
        spec.shell = try dupeOpt(allocator, opts.shell);
        spec.command = try dupeOpt(allocator, opts.command);
        spec.cwd = try dupeOpt(allocator, opts.cwd);
        spec.env = if (opts.env) |entries| try dupeStringSlice(allocator, entries) else null;
        return spec;
    }

    pub fn nativeOptions(self: *const SpawnSpec, id: []const u8, event_sink: ?native_mod.EventSink) NativeSessionOptions {
        return .{
            .id = id,
            .title = self.title,
            .shell = self.shell,
            .command = self.command,
            .cwd = self.cwd,
            .env = self.env,
            .rows = self.rows,
            .cols = self.cols,
            .scrollback_bytes = self.scrollback_bytes,
            .event_sink = event_sink,
        };
    }

    pub fn deinit(self: *SpawnSpec, allocator: Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.shell) |value| allocator.free(value);
        if (self.command) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.env) |entries| freeStringSlice(allocator, entries);
        self.* = .{};
    }
};

pub const CreateOptions = struct {
    title: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,
};

pub const LayoutNode = union(enum) {
    leaf: []u8,
    split: Split,

    const RemoveLeafResult = enum {
        not_found,
        removed,
        self_is_target,
    };

    pub const Split = struct {
        id: []u8,
        axis: Axis,
        first: *LayoutNode,
        second: *LayoutNode,
    };

    pub fn leafNode(allocator: Allocator, pane_id: []const u8) !*LayoutNode {
        const node = try allocator.create(LayoutNode);
        errdefer allocator.destroy(node);
        node.* = .{ .leaf = try allocator.dupe(u8, pane_id) };
        return node;
    }

    pub fn deinit(self: *LayoutNode, allocator: Allocator) void {
        switch (self.*) {
            .leaf => |pane_id| allocator.free(pane_id),
            .split => |split| {
                allocator.free(split.id);
                split.first.deinit(allocator);
                allocator.destroy(split.first);
                split.second.deinit(allocator);
                allocator.destroy(split.second);
            },
        }
    }

    pub fn replaceLeafWithSplit(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        new_pane_id: []const u8,
        split_id: []const u8,
    ) !bool {
        switch (self.*) {
            .leaf => |existing| {
                if (!std.mem.eql(u8, existing, target_pane_id)) return false;

                const first = try LayoutNode.leafNode(allocator, existing);
                errdefer {
                    first.deinit(allocator);
                    allocator.destroy(first);
                }
                const second = try LayoutNode.leafNode(allocator, new_pane_id);
                errdefer {
                    second.deinit(allocator);
                    allocator.destroy(second);
                }
                const owned_split_id = try allocator.dupe(u8, split_id);
                errdefer allocator.free(owned_split_id);

                allocator.free(existing);
                self.* = .{ .split = .{
                    .id = owned_split_id,
                    .axis = axis,
                    .first = first,
                    .second = second,
                } };
                return true;
            },
            .split => |split| {
                if (try split.first.replaceLeafWithSplit(allocator, target_pane_id, axis, new_pane_id, split_id)) {
                    return true;
                }
                return split.second.replaceLeafWithSplit(allocator, target_pane_id, axis, new_pane_id, split_id);
            },
        }
    }

    pub fn replaceLeafWithSplitOwned(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        split_id: []u8,
        first: *LayoutNode,
        second: *LayoutNode,
    ) bool {
        switch (self.*) {
            .leaf => |existing| {
                if (!std.mem.eql(u8, existing, target_pane_id)) return false;
                allocator.free(existing);
                self.* = .{ .split = .{
                    .id = split_id,
                    .axis = axis,
                    .first = first,
                    .second = second,
                } };
                return true;
            },
            .split => |split| {
                if (split.first.replaceLeafWithSplitOwned(allocator, target_pane_id, axis, split_id, first, second)) {
                    return true;
                }
                return split.second.replaceLeafWithSplitOwned(allocator, target_pane_id, axis, split_id, first, second);
            },
        }
    }

    pub fn removeLeaf(self: *LayoutNode, allocator: Allocator, pane_id: []const u8) bool {
        return self.removeLeafInternal(allocator, pane_id) != .not_found;
    }

    fn removeLeafInternal(self: *LayoutNode, allocator: Allocator, pane_id: []const u8) RemoveLeafResult {
        switch (self.*) {
            .leaf => |existing| return if (std.mem.eql(u8, existing, pane_id)) .self_is_target else .not_found,
            .split => |split| {
                switch (split.first.removeLeafInternal(allocator, pane_id)) {
                    .self_is_target => {
                        const replacement = split.second.*;
                        split.first.deinit(allocator);
                        allocator.destroy(split.first);
                        allocator.free(split.id);
                        allocator.destroy(split.second);
                        self.* = replacement;
                        return .removed;
                    },
                    .removed => return .removed,
                    .not_found => {},
                }
                switch (split.second.removeLeafInternal(allocator, pane_id)) {
                    .self_is_target => {
                        const replacement = split.first.*;
                        split.second.deinit(allocator);
                        allocator.destroy(split.second);
                        allocator.free(split.id);
                        allocator.destroy(split.first);
                        self.* = replacement;
                        return .removed;
                    },
                    .removed => return .removed,
                    .not_found => {},
                }
                return .not_found;
            },
        }
    }

    pub fn writeJson(self: *const LayoutNode, writer: *std.Io.Writer) !void {
        switch (self.*) {
            .leaf => |pane_id| {
                try writer.print("{{\"kind\":\"leaf\",\"paneId\":{f}}}", .{std.json.fmt(pane_id, .{})});
            },
            .split => |split| {
                try writer.print(
                    "{{\"kind\":\"split\",\"id\":{f},\"axis\":{f},\"first\":",
                    .{ std.json.fmt(split.id, .{}), std.json.fmt(split.axis.label(), .{}) },
                );
                try split.first.writeJson(writer);
                try writer.writeAll(",\"second\":");
                try split.second.writeJson(writer);
                try writer.writeByte('}');
            },
        }
    }
};

pub const AlertState = struct {
    activity: bool = false,
    bell: bool = false,
    exited: bool = false,
    last_activity_ms: i64 = 0,
    last_bell_ms: i64 = 0,
};

pub const Pane = struct {
    id: []u8,
    window_id: []u8,
    session_id: []u8,
    index: usize,
    title: []u8,
    has_custom_title: bool = false,
    spawn: SpawnSpec,
    native: *NativeSession,
    alerts: AlertState = .{},

    pub fn deinit(self: *Pane, allocator: Allocator) void {
        self.native.stopForOwnerRelease();
        self.native.destroy();
        self.spawn.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.window_id);
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.destroy(self);
    }
};

pub const Window = struct {
    id: []u8,
    session_id: []u8,
    index: usize,
    name: []u8,
    active_pane_id: []u8,
    panes: std.ArrayList(*Pane) = .empty,
    layout: *LayoutNode,

    pub fn deinit(self: *Window, allocator: Allocator) void {
        for (self.panes.items) |pane| pane.deinit(allocator);
        self.panes.deinit(allocator);
        self.layout.deinit(allocator);
        allocator.destroy(self.layout);
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.name);
        allocator.free(self.active_pane_id);
        allocator.destroy(self);
    }
};

pub const Session = struct {
    id: []u8,
    name: []u8,
    active_window_id: []u8,
    windows: std.ArrayList(*Window) = .empty,
    next_window_index: usize = 0,
    next_pane_index: usize = 0,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        for (self.windows.items) |window| window.deinit(allocator);
        self.windows.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.active_window_id);
        allocator.destroy(self);
    }
};

pub const Client = struct {
    id: []u8,
    session_id: []u8,
    window_id: []u8,
    pane_id: []u8,
    rows: u16,
    cols: u16,
    active: bool = true,

    pub fn deinit(self: *Client, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.window_id);
        allocator.free(self.pane_id);
        allocator.destroy(self);
    }
};

pub const ClientSnapshot = struct {
    id: []u8,
    session_id: []u8,
    window_id: []u8,
    pane_id: []u8,
    rows: u16,
    cols: u16,

    pub fn fromClient(allocator: Allocator, client: *const Client) !ClientSnapshot {
        const id = try allocator.dupe(u8, client.id);
        errdefer allocator.free(id);
        const session_id = try allocator.dupe(u8, client.session_id);
        errdefer allocator.free(session_id);
        const window_id = try allocator.dupe(u8, client.window_id);
        errdefer allocator.free(window_id);
        const pane_id = try allocator.dupe(u8, client.pane_id);
        errdefer allocator.free(pane_id);
        return .{
            .id = id,
            .session_id = session_id,
            .window_id = window_id,
            .pane_id = pane_id,
            .rows = client.rows,
            .cols = client.cols,
        };
    }

    pub fn deinit(self: *ClientSnapshot, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.window_id);
        allocator.free(self.pane_id);
        self.* = undefined;
    }
};

pub const KeyBinding = struct {
    table: []u8,
    key: []u8,
    command: []u8,
    repeat: bool = false,

    pub fn deinit(self: *KeyBinding, allocator: Allocator) void {
        allocator.free(self.table);
        allocator.free(self.key);
        allocator.free(self.command);
    }
};

const RemovedItems = struct {
    session: ?*Session = null,
    window: ?*Window = null,
    pane: ?*Pane = null,

    fn deinit(self: RemovedItems, allocator: Allocator) void {
        if (self.pane) |pane| pane.deinit(allocator);
        if (self.window) |window| window.deinit(allocator);
        if (self.session) |session| session.deinit(allocator);
    }
};

const PaneLocation = struct {
    session: *Session,
    window: *Window,
    pane: *Pane,
};

pub const Manager = struct {
    allocator: Allocator,
    /// Shared with every spawned `NativeSession`; supplies mutexes, clocks,
    /// and sleeps.
    io: std.Io,
    event_sink: ?native_mod.EventSink = null,
    mutex: std.Io.Mutex = .init,
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    panes_by_id: std.StringHashMapUnmanaged(PaneLocation) = .empty,
    clients_by_id: std.StringHashMapUnmanaged(*Client) = .empty,
    key_bindings: std.ArrayList(KeyBinding) = .empty,
    next_session_id: usize = 0,
    next_window_id: usize = 0,
    next_pane_id: usize = 0,
    next_split_id: usize = 0,
    next_client_id: usize = 0,

    pub fn init(allocator: Allocator, io: std.Io, event_sink: ?native_mod.EventSink) Manager {
        return .{ .allocator = allocator, .io = io, .event_sink = event_sink };
    }

    pub fn deinit(self: *Manager) void {
        self.terminateAll();
        self.panes_by_id.deinit(self.allocator);
        self.clients_by_id.deinit(self.allocator);
        for (self.clients.items) |client| client.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        for (self.key_bindings.items) |*binding| binding.deinit(self.allocator);
        self.key_bindings.deinit(self.allocator);
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var total: usize = 0;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.native.state() != .terminated) total += 1;
                }
            }
        }
        return total;
    }

    pub fn sessionCount(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sessions.items.len;
    }

    pub fn paneCount(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.paneSlotCountLocked();
    }

    /// Returns a retained native session. Caller owns one release().
    pub fn create(self: *Manager, opts: CreateOptions) !*NativeSession {
        const pane = try self.createSessionPane(opts);
        pane.native.retain();
        return pane.native;
    }

    pub fn createSessionPane(self: *Manager, opts: CreateOptions) !*Pane {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const session_id = try self.nextIdLocked("sess", &self.next_session_id);
        errdefer self.allocator.free(session_id);
        const window_id = try self.nextIdLocked("win", &self.next_window_id);
        defer self.allocator.free(window_id);
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);

        const session_name = try self.allocator.dupe(u8, opts.title orelse session_id);
        errdefer self.allocator.free(session_name);
        const window_name = try self.allocator.dupe(u8, opts.title orelse "1");
        errdefer self.allocator.free(window_name);
        const session_active_window_id = try self.allocator.dupe(u8, window_id);
        errdefer self.allocator.free(session_active_window_id);

        var session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{
            .id = session_id,
            .name = session_name,
            .active_window_id = session_active_window_id,
        };

        const window_owned_id = try self.allocator.dupe(u8, window_id);
        errdefer self.allocator.free(window_owned_id);
        const window_session_id = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(window_session_id);
        const window_active_pane_id = try self.allocator.dupe(u8, pane_id);
        errdefer self.allocator.free(window_active_pane_id);
        const window_layout = try LayoutNode.leafNode(self.allocator, pane_id);
        errdefer {
            window_layout.deinit(self.allocator);
            self.allocator.destroy(window_layout);
        }

        var window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .id = window_owned_id,
            .session_id = window_session_id,
            .index = 0,
            .name = window_name,
            .active_pane_id = window_active_pane_id,
            .layout = window_layout,
        };

        try window.panes.ensureUnusedCapacity(self.allocator, 1);
        errdefer window.panes.deinit(self.allocator);
        try session.windows.ensureUnusedCapacity(self.allocator, 1);
        errdefer session.windows.deinit(self.allocator);
        try self.sessions.ensureUnusedCapacity(self.allocator, 1);
        try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
        const pane = try self.createPaneLocked(session, window, pane_id, opts);
        window.panes.appendAssumeCapacity(pane);
        session.windows.appendAssumeCapacity(window);
        self.sessions.appendAssumeCapacity(session);
        self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = session, .window = window, .pane = pane });
        return pane;
    }

    pub fn newWindow(self: *Manager, session_id: []const u8, opts: CreateOptions) !*Pane {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const session = self.findSessionLocked(session_id) orelse return error.SessionNotFound;
        const window_id = try self.nextIdLocked("win", &self.next_window_id);
        defer self.allocator.free(window_id);
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);

        const window_name = try self.allocator.dupe(u8, opts.title orelse "window");
        errdefer self.allocator.free(window_name);
        const window_owned_id = try self.allocator.dupe(u8, window_id);
        errdefer self.allocator.free(window_owned_id);
        const window_session_id = try self.allocator.dupe(u8, session.id);
        errdefer self.allocator.free(window_session_id);
        const window_active_pane_id = try self.allocator.dupe(u8, pane_id);
        errdefer self.allocator.free(window_active_pane_id);
        const window_layout = try LayoutNode.leafNode(self.allocator, pane_id);
        errdefer {
            window_layout.deinit(self.allocator);
            self.allocator.destroy(window_layout);
        }

        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .id = window_owned_id,
            .session_id = window_session_id,
            .index = session.next_window_index + 1,
            .name = window_name,
            .active_pane_id = window_active_pane_id,
            .layout = window_layout,
        };

        try window.panes.ensureUnusedCapacity(self.allocator, 1);
        errdefer window.panes.deinit(self.allocator);
        try session.windows.ensureUnusedCapacity(self.allocator, 1);
        try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
        const active_window_id = try self.allocator.dupe(u8, window.id);
        errdefer self.allocator.free(active_window_id);

        const pane = try self.createPaneLocked(session, window, pane_id, opts);
        window.panes.appendAssumeCapacity(pane);
        session.windows.appendAssumeCapacity(window);
        self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = session, .window = window, .pane = pane });

        session.next_window_index += 1;
        self.allocator.free(session.active_window_id);
        session.active_window_id = active_window_id;
        return pane;
    }

    pub fn splitPane(self: *Manager, target_pane_id: []const u8, axis: Axis, opts: CreateOptions) !*Pane {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);
        const split_id = try self.nextIdLocked("split", &self.next_split_id);
        var split_id_owned = true;
        errdefer if (split_id_owned) self.allocator.free(split_id);

        const first = try LayoutNode.leafNode(self.allocator, target_pane_id);
        errdefer {
            first.deinit(self.allocator);
            self.allocator.destroy(first);
        }
        const second = try LayoutNode.leafNode(self.allocator, pane_id);
        errdefer {
            second.deinit(self.allocator);
            self.allocator.destroy(second);
        }
        try found.window.panes.ensureUnusedCapacity(self.allocator, 1);
        try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
        const active_pane_id = try self.allocator.dupe(u8, pane_id);
        errdefer self.allocator.free(active_pane_id);

        const pane = try self.createPaneLocked(found.session, found.window, pane_id, opts);
        if (!found.window.layout.replaceLeafWithSplitOwned(self.allocator, target_pane_id, axis, split_id, first, second)) {
            unreachable;
        }
        split_id_owned = false;
        found.window.panes.appendAssumeCapacity(pane);
        self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = found.session, .window = found.window, .pane = pane });
        self.allocator.free(found.window.active_pane_id);
        found.window.active_pane_id = active_pane_id;
        return pane;
    }

    pub fn selectPane(self: *Manager, pane_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.findPaneWithParentsLocked(pane_id) orelse return error.PaneNotFound;
        const new_active_pane = try self.allocator.dupe(u8, found.pane.id);
        errdefer self.allocator.free(new_active_pane);
        const new_active_window = try self.allocator.dupe(u8, found.window.id);

        self.allocator.free(found.window.active_pane_id);
        found.window.active_pane_id = new_active_pane;
        self.allocator.free(found.session.active_window_id);
        found.session.active_window_id = new_active_window;
    }

    pub fn selectWindow(self: *Manager, window_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.findWindowWithParentLocked(window_id) orelse return error.WindowNotFound;
        try replaceOwnedString(self.allocator, &found.session.active_window_id, found.window.id);
    }

    pub fn renameSession(self: *Manager, session_id: []const u8, title: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.resolveTargetSessionLocked(session_id) orelse return error.SessionNotFound;
        try replaceOwnedString(self.allocator, &session.name, title);
    }

    pub fn renameWindow(self: *Manager, window_id: []const u8, title: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const found = self.findWindowWithParentLocked(window_id) orelse return error.WindowNotFound;
        try replaceOwnedString(self.allocator, &found.window.name, title);
    }

    pub fn renamePane(self: *Manager, pane_id: []const u8, title: []const u8, custom: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return error.PaneNotFound;
        try replaceOwnedString(self.allocator, &pane.title, title);
        pane.has_custom_title = custom;
    }

    pub fn respawnPane(self: *Manager, pane_id: []const u8) !*NativeSession {
        var old_native: *NativeSession = undefined;
        var new_native: *NativeSession = undefined;

        self.mutex.lockUncancelable(self.io);
        {
            const pane = self.findPaneLocked(pane_id) orelse {
                self.mutex.unlock(self.io);
                return error.PaneNotFound;
            };
            new_native = NativeSession.create(self.allocator, self.io, pane.spawn.nativeOptions(pane.id, self.event_sink)) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            old_native = pane.native;
            pane.native = new_native;
            pane.alerts.exited = false;
            new_native.retain();
        }
        self.mutex.unlock(self.io);

        old_native.stopForOwnerRelease();
        old_native.destroy();
        self.mutex.lockUncancelable(self.io);
        if (self.findPaneLocked(pane_id)) |pane| {
            if (pane.native == new_native) pane.alerts.exited = false;
        }
        self.mutex.unlock(self.io);
        return new_native;
    }

    pub fn attachClient(self: *Manager, target_pane_id: []const u8, rows: u16, cols: u16) !ClientSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.resolveTargetPaneLocked(target_pane_id) orelse return error.PaneNotFound;
        try found.pane.native.resize(cols, rows);

        const client_id = try self.nextIdLocked("client", &self.next_client_id);
        var client_id_owned = true;
        errdefer if (client_id_owned) self.allocator.free(client_id);
        const session_id = try self.allocator.dupe(u8, found.session.id);
        var session_id_owned = true;
        errdefer if (session_id_owned) self.allocator.free(session_id);
        const window_id = try self.allocator.dupe(u8, found.window.id);
        var window_id_owned = true;
        errdefer if (window_id_owned) self.allocator.free(window_id);
        const owned_pane_id = try self.allocator.dupe(u8, found.pane.id);
        var pane_id_owned = true;
        errdefer if (pane_id_owned) self.allocator.free(owned_pane_id);

        const client = try self.allocator.create(Client);
        var raw_client_owned = true;
        errdefer if (raw_client_owned) self.allocator.destroy(client);
        client.* = .{
            .id = client_id,
            .session_id = session_id,
            .window_id = window_id,
            .pane_id = owned_pane_id,
            .rows = rows,
            .cols = cols,
            .active = true,
        };
        client_id_owned = false;
        session_id_owned = false;
        window_id_owned = false;
        pane_id_owned = false;
        var client_owned = true;
        errdefer if (client_owned) client.deinit(self.allocator);
        raw_client_owned = false;

        try self.clients.ensureUnusedCapacity(self.allocator, 1);
        try self.clients_by_id.ensureUnusedCapacity(self.allocator, 1);
        self.clients.appendAssumeCapacity(client);
        self.clients_by_id.putAssumeCapacity(client.id, client);
        var appended = true;
        client_owned = false;
        errdefer if (appended) {
            const removed = self.clients.swapRemove(self.clients.items.len - 1);
            _ = self.clients_by_id.remove(removed.id);
            removed.deinit(self.allocator);
        };

        const snapshot = try ClientSnapshot.fromClient(self.allocator, client);
        appended = false;
        return snapshot;
    }

    pub fn reapExitedPanes(self: *Manager) void {
        var stack_buf: [64]*NativeSession = undefined;
        var heap_buf: ?[]*NativeSession = null;
        var count_used: usize = 0;

        self.mutex.lockUncancelable(self.io);
        const total_panes = self.paneSlotCountLocked();
        if (total_panes == 0) {
            self.mutex.unlock(self.io);
            return;
        }
        const natives: []*NativeSession = if (total_panes <= stack_buf.len)
            stack_buf[0..total_panes]
        else blk: {
            const allocated = self.allocator.alloc(*NativeSession, total_panes) catch {
                self.mutex.unlock(self.io);
                return;
            };
            heap_buf = allocated;
            break :blk allocated;
        };
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    pane.native.retain();
                    natives[count_used] = pane.native;
                    count_used += 1;
                }
            }
        }
        self.mutex.unlock(self.io);
        defer if (heap_buf) |buf| self.allocator.free(buf);

        for (natives[0..count_used]) |native| {
            _ = native.reapExited();
            native.release();
        }
    }

    pub fn paneScrollbackSnapshot(self: *Manager, allocator: Allocator, pane_id: []const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        const pane = self.findPaneLocked(pane_id) orelse {
            self.mutex.unlock(self.io);
            return error.PaneNotFound;
        };
        const native = pane.native;
        native.retain();
        self.mutex.unlock(self.io);
        defer native.release();
        return native.scrollbackSnapshot(allocator);
    }

    pub fn paneScrollbackTail(self: *Manager, allocator: Allocator, pane_id: []const u8, max_bytes: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        const pane = self.findPaneLocked(pane_id) orelse {
            self.mutex.unlock(self.io);
            return error.PaneNotFound;
        };
        const native = pane.native;
        native.retain();
        self.mutex.unlock(self.io);
        defer native.release();
        return native.scrollbackTail(allocator, max_bytes);
    }

    pub fn detachClient(self: *Manager, client_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const removed_entry = self.clients_by_id.fetchRemove(client_id) orelse return false;
        const removed = removed_entry.value;
        for (self.clients.items, 0..) |client, index| {
            if (client == removed) {
                _ = self.clients.swapRemove(index);
                break;
            }
        }
        removed.deinit(self.allocator);
        return true;
    }

    pub fn switchClient(self: *Manager, client_id: []const u8, pane_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const client = self.findClientLocked(client_id) orelse return error.ClientNotFound;
        const found = self.findPaneWithParentsLocked(pane_id) orelse return error.PaneNotFound;
        try found.pane.native.resize(client.cols, client.rows);

        const new_session_id = try self.allocator.dupe(u8, found.session.id);
        errdefer self.allocator.free(new_session_id);
        const new_window_id = try self.allocator.dupe(u8, found.window.id);
        errdefer self.allocator.free(new_window_id);
        const new_pane_id = try self.allocator.dupe(u8, found.pane.id);

        self.allocator.free(client.session_id);
        client.session_id = new_session_id;
        self.allocator.free(client.window_id);
        client.window_id = new_window_id;
        self.allocator.free(client.pane_id);
        client.pane_id = new_pane_id;
    }

    pub fn bindKey(self: *Manager, table: []const u8, key: []const u8, command: []const u8, repeat: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.key_bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.table, table) and std.mem.eql(u8, binding.key, key)) {
                try replaceOwnedString(self.allocator, &binding.command, command);
                binding.repeat = repeat;
                return;
            }
        }

        const owned_table = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(owned_table);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_command = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_command);

        try self.key_bindings.append(self.allocator, .{
            .table = owned_table,
            .key = owned_key,
            .command = owned_command,
            .repeat = repeat,
        });
    }

    pub fn executeBinding(self: *Manager, table: []const u8, key: []const u8, target_pane_id: []const u8) !?[]u8 {
        const command = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.key_bindings.items) |binding| {
                if (std.mem.eql(u8, binding.table, table) and std.mem.eql(u8, binding.key, key)) {
                    break :blk try self.allocator.dupe(u8, binding.command);
                }
            }
            break :blk null;
        } orelse return null;
        errdefer self.allocator.free(command);
        try self.executeCommandLine(command, target_pane_id);
        return command;
    }

    pub const ParsedCommand = union(enum) {
        noop,
        split_window: struct {
            axis: Axis,
            command: ?[]u8,
        },
        new_window: struct {
            title: ?[]u8,
            command: ?[]u8,
        },
        respawn_pane,

        pub fn deinit(self: *ParsedCommand, allocator: Allocator) void {
            switch (self.*) {
                .noop, .respawn_pane => {},
                .split_window => |split| {
                    if (split.command) |cmd| allocator.free(cmd);
                },
                .new_window => |nw| {
                    if (nw.title) |t| allocator.free(t);
                    if (nw.command) |cmd| allocator.free(cmd);
                },
            }
            self.* = .noop;
        }
    };

    pub fn parseCommandLine(allocator: Allocator, line: []const u8) !ParsedCommand {
        var iter = std.mem.tokenizeScalar(u8, line, ' ');
        const command = iter.next() orelse return .noop;
        if (std.mem.eql(u8, command, "split-window") or std.mem.eql(u8, command, "splitw")) {
            var axis: Axis = .vertical;
            var command_buffer: std.Io.Writer.Allocating = .init(allocator);
            defer command_buffer.deinit();
            var collecting_command = false;
            while (iter.next()) |token| {
                if (!collecting_command and std.mem.eql(u8, token, "-h")) {
                    axis = .horizontal;
                    continue;
                }
                if (!collecting_command and std.mem.eql(u8, token, "-v")) {
                    axis = .vertical;
                    continue;
                }
                if (!collecting_command and std.mem.startsWith(u8, token, "-")) return error.UnsupportedCommand;
                collecting_command = true;
                try appendCommandToken(&command_buffer.writer, token);
            }
            const owned_cmd: ?[]u8 = if (command_buffer.written().len > 0)
                try command_buffer.toOwnedSlice()
            else
                null;
            return .{ .split_window = .{ .axis = axis, .command = owned_cmd } };
        }
        if (std.mem.eql(u8, command, "new-window") or std.mem.eql(u8, command, "neww")) {
            var title: ?[]const u8 = null;
            var command_buffer: std.Io.Writer.Allocating = .init(allocator);
            defer command_buffer.deinit();
            var collecting_command = false;
            while (iter.next()) |token| {
                if (!collecting_command and std.mem.eql(u8, token, "-n")) {
                    title = iter.next() orelse return error.UnsupportedCommand;
                    continue;
                }
                if (!collecting_command and std.mem.startsWith(u8, token, "-")) return error.UnsupportedCommand;
                collecting_command = true;
                try appendCommandToken(&command_buffer.writer, token);
            }
            const owned_title: ?[]u8 = if (title) |t| try allocator.dupe(u8, t) else null;
            errdefer if (owned_title) |t| allocator.free(t);
            const owned_cmd: ?[]u8 = if (command_buffer.written().len > 0)
                try command_buffer.toOwnedSlice()
            else
                null;
            return .{ .new_window = .{ .title = owned_title, .command = owned_cmd } };
        }
        if (std.mem.eql(u8, command, "respawn-pane") or std.mem.eql(u8, command, "respawnp")) {
            if (iter.next() != null) return error.UnsupportedCommand;
            return .respawn_pane;
        }
        return error.UnsupportedCommand;
    }

    pub fn executeCommandLine(self: *Manager, line: []const u8, target_pane_id: []const u8) !void {
        var parsed = try parseCommandLine(self.allocator, line);
        defer parsed.deinit(self.allocator);
        switch (parsed) {
            .noop => return,
            .split_window => |split| {
                _ = try self.splitPane(target_pane_id, split.axis, .{
                    .command = split.command,
                });
            },
            .new_window => |nw| {
                const found = blk: {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
                    break :blk try self.allocator.dupe(u8, found.session.id);
                };
                defer self.allocator.free(found);
                _ = try self.newWindow(found, .{
                    .title = nw.title,
                    .command = nw.command,
                });
            },
            .respawn_pane => {
                const native = try self.respawnPane(target_pane_id);
                native.release();
            },
        }
    }

    /// Assert all internal structural invariants of the mux state graph.
    /// Intended for stateful fuzz and model-checking suites.
    pub fn checkInvariants(self: *Manager, allocator: Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var seen_sessions = std.StringHashMap(void).init(allocator);
        defer seen_sessions.deinit();
        var seen_windows = std.StringHashMap(void).init(allocator);
        defer seen_windows.deinit();
        var seen_panes = std.StringHashMap(void).init(allocator);
        defer seen_panes.deinit();
        var seen_clients = std.StringHashMap(void).init(allocator);
        defer seen_clients.deinit();

        for (self.sessions.items) |session| {
            if ((try seen_sessions.fetchPut(session.id, {})) != null) return error.DuplicateSessionId;
            if (session.windows.items.len == 0) return error.EmptySession;

            var active_window_found = false;
            for (session.windows.items) |window| {
                if ((try seen_windows.fetchPut(window.id, {})) != null) return error.DuplicateWindowId;
                if (!std.mem.eql(u8, window.session_id, session.id)) return error.WindowSessionMismatch;
                if (std.mem.eql(u8, window.id, session.active_window_id)) active_window_found = true;
                if (window.panes.items.len == 0) return error.EmptyWindow;

                var layout_leaves = std.StringHashMap(void).init(allocator);
                defer layout_leaves.deinit();
                try collectLayoutLeaves(window.layout, &layout_leaves);

                var active_pane_found = false;
                for (window.panes.items) |pane| {
                    if ((try seen_panes.fetchPut(pane.id, {})) != null) return error.DuplicatePaneId;
                    if (!std.mem.eql(u8, pane.session_id, session.id)) return error.PaneSessionMismatch;
                    if (!std.mem.eql(u8, pane.window_id, window.id)) return error.PaneWindowMismatch;
                    if (!std.mem.eql(u8, pane.native.id, pane.id)) return error.PaneNativeIdMismatch;
                    if (std.mem.eql(u8, pane.id, window.active_pane_id)) active_pane_found = true;
                    if (!layout_leaves.contains(pane.id)) return error.PaneMissingFromLayout;
                }
                if (!active_pane_found) return error.DanglingActivePane;
                if (layout_leaves.count() != window.panes.items.len) return error.LayoutPaneCountMismatch;
            }
            if (!active_window_found) return error.DanglingActiveWindow;
        }

        for (self.clients.items) |client| {
            if ((try seen_clients.fetchPut(client.id, {})) != null) return error.DuplicateClientId;
            if (self.clients_by_id.get(client.id) != client) return error.ClientIndexMismatch;
        }
        if (self.panes_by_id.count() != seen_panes.count()) return error.PaneIndexCountMismatch;
        if (self.clients_by_id.count() != seen_clients.count()) return error.ClientIndexCountMismatch;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    const loc = self.panes_by_id.get(pane.id) orelse return error.PaneIndexMissing;
                    if (loc.session != session or loc.window != window or loc.pane != pane) return error.PaneIndexMismatch;
                }
            }
        }
    }

    fn collectLayoutLeaves(node: *const LayoutNode, leaves: *std.StringHashMap(void)) !void {
        switch (node.*) {
            .leaf => |pane_id| {
                if ((try leaves.fetchPut(pane_id, {})) != null) return error.DuplicateLayoutLeaf;
            },
            .split => |split| {
                try collectLayoutLeaves(split.first, leaves);
                try collectLayoutLeaves(split.second, leaves);
            },
        }
    }

    pub fn markActivity(self: *Manager, pane_id: []const u8) void {
        self.markActivityAt(pane_id, std.Io.Clock.real.now(self.io).toMilliseconds());
    }

    pub fn markActivityAt(self: *Manager, pane_id: []const u8, timestamp_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.findPaneLocked(pane_id)) |pane| {
            pane.alerts.activity = true;
            pane.alerts.last_activity_ms = timestamp_ms;
        }
    }

    pub fn markBell(self: *Manager, pane_id: []const u8) void {
        self.markBellAt(pane_id, std.Io.Clock.real.now(self.io).toMilliseconds());
    }

    pub fn markBellAt(self: *Manager, pane_id: []const u8, timestamp_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.findPaneLocked(pane_id)) |pane| {
            pane.alerts.bell = true;
            pane.alerts.last_bell_ms = timestamp_ms;
        }
    }

    pub fn markExited(self: *Manager, pane_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.resolveTargetPaneLocked(pane_id)) |found| {
            const pane = found.pane;
            pane.alerts.exited = true;
        }
    }

    pub fn find(self: *Manager, id: []const u8) ?*NativeSession {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = (self.resolveTargetPaneLocked(id) orelse return null).pane;
        pane.native.retain();
        return pane.native;
    }

    pub fn terminate(self: *Manager, id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        const removed = if (self.findPaneWithParentsLocked(id)) |found|
            if (found.window.panes.items.len == 1 and found.session.windows.items.len == 1)
                self.takeSessionLocked(found.session.id)
            else
                self.takePaneLocked(found.session, found.window, id)
        else if (self.findSessionLocked(id)) |session|
            self.takeSessionLocked(session.id)
        else {
            self.mutex.unlock(self.io);
            return false;
        };
        self.mutex.unlock(self.io);

        removed.deinit(self.allocator);
        return true;
    }

    pub fn terminateAll(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        var sessions = self.sessions;
        self.sessions = .empty;
        self.panes_by_id.clearRetainingCapacity();
        self.mutex.unlock(self.io);

        for (sessions.items) |session| session.deinit(self.allocator);
        sessions.deinit(self.allocator);
    }

    pub fn listJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(@as(usize, 64), self.panes_by_id.count() * 256));
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
                        ",\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f}}}",
                        .{ std.json.fmt(session.id, .{}), std.json.fmt(window.id, .{}), std.json.fmt(pane.id, .{}) },
                    );
                }
            }
        }
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }

    pub fn snapshotJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const hint = 128 + self.panes_by_id.count() * 384 + self.clients.items.len * 160;
        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, hint);
        errdefer out.deinit();
        try out.writer.writeAll("{\"sessions\":[");
        for (self.sessions.items, 0..) |session, index| {
            if (index > 0) try out.writer.writeByte(',');
            try self.writeSessionJsonLocked(&out.writer, session);
        }
        try out.writer.writeAll("],\"clients\":");
        try self.writeClientsJsonLocked(&out.writer);
        try out.writer.writeAll(",\"keyBindings\":");
        try self.writeKeyBindingsJsonLocked(&out.writer);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    pub fn clientsJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(@as(usize, 64), self.clients.items.len * 160));
        errdefer out.deinit();
        try self.writeClientsJsonLocked(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn keysJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(@as(usize, 64), self.key_bindings.items.len * 96));
        errdefer out.deinit();
        try self.writeKeyBindingsJsonLocked(&out.writer);
        return out.toOwnedSlice();
    }

    fn createPaneLocked(self: *Manager, session: *Session, window: *Window, pane_id: []const u8, opts: CreateOptions) !*Pane {
        var spawn = try SpawnSpec.fromOptions(self.allocator, opts);
        errdefer spawn.deinit(self.allocator);

        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        const title = try self.allocator.dupe(u8, opts.title orelse pane_id);
        errdefer self.allocator.free(title);
        const owned_pane_id = try self.allocator.dupe(u8, pane_id);
        errdefer self.allocator.free(owned_pane_id);
        const owned_window_id = try self.allocator.dupe(u8, window.id);
        errdefer self.allocator.free(owned_window_id);
        const owned_session_id = try self.allocator.dupe(u8, session.id);
        errdefer self.allocator.free(owned_session_id);

        const native = try NativeSession.create(self.allocator, self.io, spawn.nativeOptions(pane_id, self.event_sink));

        pane.* = .{
            .id = owned_pane_id,
            .window_id = owned_window_id,
            .session_id = owned_session_id,
            .index = session.next_pane_index,
            .title = title,
            .spawn = spawn,
            .native = native,
        };
        session.next_pane_index += 1;
        return pane;
    }

    fn nextIdLocked(self: *Manager, prefix: []const u8, next: *usize) ![]u8 {
        next.* += 1;
        return std.fmt.allocPrint(self.allocator, "{s}-{d}-{x}", .{ prefix, next.*, std.Io.Clock.real.now(self.io).nanoseconds });
    }

    fn findSessionLocked(self: *Manager, id: []const u8) ?*Session {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.id, id) or std.mem.eql(u8, session.name, id)) return session;
        }
        return null;
    }

    fn findWindowWithParentLocked(self: *Manager, id: []const u8) ?struct { session: *Session, window: *Window } {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                if (std.mem.eql(u8, window.id, id) or std.mem.eql(u8, window.name, id)) {
                    return .{ .session = session, .window = window };
                }
            }
        }
        return null;
    }

    fn findPaneWithParentsLocked(self: *Manager, id: []const u8) ?PaneLocation {
        return self.panes_by_id.get(id);
    }

    // Resolve a target identifier to a pane. Tries pane id first, then falls
    // back to session id / session name (resolving to that session's active
    // window and active pane). This lets clients attach by a tmux-style name
    // like "work" without having to remember the auto-generated pane id.
    fn resolveTargetPaneLocked(self: *Manager, id: []const u8) ?PaneLocation {
        if (self.panes_by_id.get(id)) |hit| return hit;

        const session = self.findSessionLocked(id) orelse return null;
        for (session.windows.items) |window| {
            if (!std.mem.eql(u8, window.id, session.active_window_id)) continue;
            if (self.panes_by_id.get(window.active_pane_id)) |hit| return hit;
        }
        return null;
    }

    fn resolveTargetSessionLocked(self: *Manager, id: []const u8) ?*Session {
        if (self.panes_by_id.get(id)) |hit| return hit.session;
        return self.findSessionLocked(id);
    }

    fn findPaneLocked(self: *Manager, id: []const u8) ?*Pane {
        const found = self.panes_by_id.get(id) orelse return null;
        return found.pane;
    }

    fn findClientLocked(self: *Manager, id: []const u8) ?*Client {
        return self.clients_by_id.get(id);
    }

    fn paneSlotCountLocked(self: *Manager) usize {
        return self.panes_by_id.count();
    }

    fn takeSessionLocked(self: *Manager, id: []const u8) RemovedItems {
        for (self.sessions.items, 0..) |session, index| {
            if (std.mem.eql(u8, session.id, id)) {
                const removed = self.sessions.swapRemove(index);
                for (removed.windows.items) |window| {
                    for (window.panes.items) |pane| {
                        _ = self.panes_by_id.remove(pane.id);
                    }
                }
                return .{ .session = removed };
            }
        }
        return .{};
    }

    fn takePaneLocked(self: *Manager, session: *Session, window: *Window, pane_id: []const u8) RemovedItems {
        for (window.panes.items, 0..) |pane, index| {
            if (std.mem.eql(u8, pane.id, pane_id)) {
                const removed = window.panes.swapRemove(index);
                _ = self.panes_by_id.remove(removed.id);
                _ = window.layout.removeLeaf(self.allocator, pane_id);
                if (std.mem.eql(u8, window.active_pane_id, pane_id) and window.panes.items.len > 0) {
                    replaceOwnedString(self.allocator, &window.active_pane_id, window.panes.items[0].id) catch {};
                }
                if (window.panes.items.len == 0 and session.windows.items.len > 1) {
                    return .{
                        .window = self.takeWindowLocked(session, window.id),
                        .pane = removed,
                    };
                }
                return .{ .pane = removed };
            }
        }
        return .{};
    }

    fn takeWindowLocked(self: *Manager, session: *Session, window_id: []const u8) ?*Window {
        for (session.windows.items, 0..) |window, index| {
            if (std.mem.eql(u8, window.id, window_id)) {
                const removed = session.windows.swapRemove(index);
                if (std.mem.eql(u8, session.active_window_id, window_id) and session.windows.items.len > 0) {
                    replaceOwnedString(self.allocator, &session.active_window_id, session.windows.items[0].id) catch {};
                }
                return removed;
            }
        }
        return null;
    }

    fn writeSessionJsonLocked(self: *Manager, writer: *std.Io.Writer, session: *Session) !void {
        try writer.print(
            "{{\"id\":{f},\"name\":{f},\"activeWindowId\":{f},\"windows\":[",
            .{ std.json.fmt(session.id, .{}), std.json.fmt(session.name, .{}), std.json.fmt(session.active_window_id, .{}) },
        );
        for (session.windows.items, 0..) |window, index| {
            if (index > 0) try writer.writeByte(',');
            try self.writeWindowJsonLocked(writer, window);
        }
        try writer.writeAll("]}");
    }

    fn writeWindowJsonLocked(self: *Manager, writer: *std.Io.Writer, window: *Window) !void {
        _ = self;
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
        try writer.writeAll("]}");
    }

    fn writeClientsJsonLocked(self: *Manager, writer: *std.Io.Writer) !void {
        try writer.writeByte('[');
        for (self.clients.items, 0..) |client, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"id\":{f},\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f},\"rows\":{},\"cols\":{},\"active\":{}}}",
                .{
                    std.json.fmt(client.id, .{}),
                    std.json.fmt(client.session_id, .{}),
                    std.json.fmt(client.window_id, .{}),
                    std.json.fmt(client.pane_id, .{}),
                    client.rows,
                    client.cols,
                    client.active,
                },
            );
        }
        try writer.writeByte(']');
    }

    fn writeKeyBindingsJsonLocked(self: *Manager, writer: *std.Io.Writer) !void {
        try writer.writeByte('[');
        for (self.key_bindings.items, 0..) |binding, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"table\":{f},\"key\":{f},\"command\":{f},\"repeat\":{}}}",
                .{ std.json.fmt(binding.table, .{}), std.json.fmt(binding.key, .{}), std.json.fmt(binding.command, .{}), binding.repeat },
            );
        }
        try writer.writeByte(']');
    }
};

fn writePaneJson(writer: *std.Io.Writer, pane: *const Pane) !void {
    try writer.print(
        "{{\"id\":{f},\"windowId\":{f},\"sessionId\":{f},\"index\":{},\"title\":{f},\"hasCustomTitle\":{},\"state\":{f},\"pid\":{},\"cwd\":",
        .{
            std.json.fmt(pane.id, .{}),
            std.json.fmt(pane.window_id, .{}),
            std.json.fmt(pane.session_id, .{}),
            pane.index,
            std.json.fmt(pane.title, .{}),
            pane.has_custom_title,
            std.json.fmt(pane.native.state().label(), .{}),
            pane.native.handle.child_pid,
        },
    );
    if (pane.spawn.cwd) |cwd| try writer.print("{f}", .{std.json.fmt(cwd, .{})}) else try writer.writeAll("null");
    try writer.print(
        ",\"command\":{f},\"alerts\":{{\"activity\":{},\"bell\":{},\"exited\":{},\"lastActivityMs\":{},\"lastBellMs\":{}}}}}",
        .{
            std.json.fmt(pane.spawn.command orelse "", .{}),
            pane.alerts.activity,
            pane.alerts.bell,
            pane.alerts.exited,
            pane.alerts.last_activity_ms,
            pane.alerts.last_bell_ms,
        },
    );
}

fn dupeOpt(allocator: Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn dupeStringSlice(allocator: Allocator, entries: []const []const u8) ![][]const u8 {
    const copy = try allocator.alloc([]const u8, entries.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |entry| allocator.free(entry);
        allocator.free(copy);
    }
    for (entries, 0..) |entry, index| {
        copy[index] = try allocator.dupe(u8, entry);
        filled += 1;
    }
    return copy;
}

fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

fn replaceOwnedString(allocator: Allocator, slot: *[]u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = replacement;
}

fn appendCommandToken(writer: *std.Io.Writer, token: []const u8) !void {
    if (writer.end > 0) try writer.writeByte(' ');
    try writer.writeAll(token);
}

fn createNewWindowAndSplitForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const opts: CreateOptions = .{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    };
    const first = try manager.createSessionPane(opts);
    _ = try manager.newWindow(first.session_id, opts);
    _ = try manager.splitPane(first.id, .horizontal, opts);
}

fn attachClientForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    });
    var client = try manager.attachClient(pane.id, 30, 100);
    defer client.deinit(allocator);
}

fn respawnPaneForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    });
    const pane_id = try allocator.dupe(u8, pane.id);
    defer allocator.free(pane_id);

    const native = try manager.respawnPane(pane_id);
    native.release();
}

fn layoutContainsPane(node: *const LayoutNode, pane_id: []const u8) bool {
    return switch (node.*) {
        .leaf => |existing| std.mem.eql(u8, existing, pane_id),
        .split => |split| layoutContainsPane(split.first, pane_id) or layoutContainsPane(split.second, pane_id),
    };
}

test "mux manager creates session window and pane state" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{ .title = "one", .shell = "/bin/sh", .command = "cat" });
    try std.testing.expect(std.mem.startsWith(u8, pane.session_id, "sess-"));
    try std.testing.expect(std.mem.startsWith(u8, pane.window_id, "win-"));
    try std.testing.expect(std.mem.startsWith(u8, pane.id, "pane-"));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"windows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"panes\"") != null);
}

test "mux manager splits panes and records layout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    const second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    try std.testing.expect(!std.mem.eql(u8, first_id, second.id));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"axis\":\"horizontal\"") != null);
}

test "removing a nested pane keeps the surviving sibling subtree in layout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    const second = try manager.splitPane(first_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });
    const second_id = try std.testing.allocator.dupe(u8, second.id);
    defer std.testing.allocator.free(second_id);
    const third = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    const third_id = try std.testing.allocator.dupe(u8, third.id);
    defer std.testing.allocator.free(third_id);

    try std.testing.expect(manager.terminate(first_id));

    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const window = manager.sessions.items[0].windows.items[0];
        try std.testing.expect(window.layout.* == .split);
        try std.testing.expect(!layoutContainsPane(window.layout, first_id));
        try std.testing.expect(layoutContainsPane(window.layout, second_id));
        try std.testing.expect(layoutContainsPane(window.layout, third_id));
    }

    const fourth = try manager.splitPane(third_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });
    try std.testing.expect(!std.mem.eql(u8, fourth.id, third_id));
}

test "attachClient resolves a session name to its active pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });
    const expected_pane_id = try std.testing.allocator.dupe(u8, pane.id);
    defer std.testing.allocator.free(expected_pane_id);

    var client = try manager.attachClient("work", 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected_pane_id, client.pane_id);
}

test "attachClient still resolves an explicit pane id" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });
    const pane_id = try std.testing.allocator.dupe(u8, pane.id);
    defer std.testing.allocator.free(pane_id);

    var client = try manager.attachClient(pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(pane_id, client.pane_id);
}

test "attachClient on an unknown name returns PaneNotFound" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    _ = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });
    try std.testing.expectError(error.PaneNotFound, manager.attachClient("ghost", 24, 80));
}

test "session-targeted APIs resolve pane id session id and session name" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });
    const pane_id = try std.testing.allocator.dupe(u8, pane.id);
    defer std.testing.allocator.free(pane_id);
    const session_id = try std.testing.allocator.dupe(u8, pane.session_id);
    defer std.testing.allocator.free(session_id);

    const by_session_id = manager.find(session_id) orelse return error.MissingSession;
    defer by_session_id.release();
    try std.testing.expectEqualStrings(pane_id, by_session_id.id);

    const by_name = manager.find("work") orelse return error.MissingSession;
    defer by_name.release();
    try std.testing.expectEqualStrings(pane_id, by_name.id);

    try manager.renameSession(pane_id, "renamed-work");
    const by_renamed = manager.find("renamed-work") orelse return error.MissingSession;
    defer by_renamed.release();
    try std.testing.expectEqualStrings(pane_id, by_renamed.id);
}

test "terminate by session id removes the whole session" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    const session_id = try std.testing.allocator.dupe(u8, first.session_id);
    defer std.testing.allocator.free(session_id);
    _ = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });

    try std.testing.expectEqual(@as(usize, 1), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 2), manager.paneCount());
    try std.testing.expect(manager.terminate(session_id));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 0), manager.paneCount());
}

test "mux key binding executes tmux-like split command" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    try manager.bindKey("prefix", "%", "split-window -h", false);
    const command = try manager.executeBinding("prefix", "%", first_id);
    defer if (command) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(command != null);
    try std.testing.expectEqual(@as(usize, 2), manager.count());
}

test "command exec split-window passes trailing shell command to new pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);

    try manager.executeCommandLine("split-window -h /bin/echo SPLIT_CMD_RAN", first_id);

    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const window = manager.sessions.items[0].windows.items[0];
        const active = manager.findPaneLocked(window.active_pane_id) orelse return error.MissingPane;
        try std.testing.expectEqualStrings("/bin/echo SPLIT_CMD_RAN", active.spawn.command.?);
        try std.testing.expect(window.layout.* == .split);
        try std.testing.expectEqual(Axis.horizontal, window.layout.split.axis);
    }
}

test "command exec new-window honors name and shell command" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);

    try manager.executeCommandLine("new-window -n logs /bin/echo NEW_CMD_RAN", first_id);

    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const session = manager.sessions.items[0];
        const found = manager.findWindowWithParentLocked(session.active_window_id) orelse return error.MissingWindow;
        try std.testing.expectEqualStrings("logs", found.window.name);
        try std.testing.expectEqualStrings("/bin/echo NEW_CMD_RAN", found.window.panes.items[0].spawn.command.?);
    }
}

test "command exec rejects unsupported flags instead of dropping them" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);

    try std.testing.expectError(error.UnsupportedCommand, manager.executeCommandLine("split-window -x", first_id));
    try std.testing.expectError(error.UnsupportedCommand, manager.executeCommandLine("new-window -x", first_id));
    try std.testing.expectError(error.UnsupportedCommand, manager.executeCommandLine("respawn-pane extra", first_id));
    try std.testing.expectEqual(@as(usize, 1), manager.paneCount());
}

test "switchClient moves a logical client to another pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    const second = try manager.splitPane(first_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });
    const second_id = try std.testing.allocator.dupe(u8, second.id);
    defer std.testing.allocator.free(second_id);

    var client = try manager.attachClient(first_id, 25, 90);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(first_id, client.pane_id);

    try manager.switchClient(client.id, second_id);
    try std.testing.expectEqual(@as(u16, 25), client.rows);
    try std.testing.expectEqual(@as(u16, 90), client.cols);

    const clients = try manager.clientsJson(std.testing.allocator);
    defer std.testing.allocator.free(clients);
    try std.testing.expect(std.mem.indexOf(u8, clients, second_id) != null);
}

test "snapshot omits dead pane silence field and reports attached clients active" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    var client = try manager.attachClient(pane.id, 24, 80);
    defer client.deinit(std.testing.allocator);

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"silence\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"active\":true") != null);
}

test "terminating a split pane collapses layout and keeps the remaining pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    const second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    const second_id = try std.testing.allocator.dupe(u8, second.id);
    defer std.testing.allocator.free(second_id);

    try std.testing.expectEqual(@as(usize, 2), manager.count());
    try std.testing.expect(manager.terminate(second_id));
    try std.testing.expectEqual(@as(usize, 1), manager.count());

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, first_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, second_id) == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") == null);
}

test "manager create returns a retained native that survives concurrent removal" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const native = try manager.create(.{ .shell = "/bin/sh", .command = "cat" });
    defer native.release();
    const id = try std.testing.allocator.dupe(u8, native.id);
    defer std.testing.allocator.free(id);

    try std.testing.expect(manager.terminate(id));

    const info = try native.infoJson(std.testing.allocator);
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "\"state\":\"terminated\"") != null);
}

test "attachClient returns an owned snapshot that survives detach" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });
    const pane_id = try std.testing.allocator.dupe(u8, pane.id);
    defer std.testing.allocator.free(pane_id);

    var client = try manager.attachClient(pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expect(manager.detachClient(client.id));
    try std.testing.expectEqualStrings(pane_id, client.pane_id);
}

test "manager count ignores terminated panes for idle accounting" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    _ = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" });

    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (std.Io.Clock.awake.now(io).compare(.lt, deadline)) {
        manager.reapExitedPanes();
        if (manager.count() == 0) return;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.PaneStillCountedAsLive;
}

test "manager pane creation allocation failures clean up without native teardown under lock" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createNewWindowAndSplitForFailureTest, .{});
}

test "manager attach allocation failures clean up client ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, attachClientForFailureTest, .{});
}

test "manager respawn allocation failures leave the old pane reachable" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, respawnPaneForFailureTest, .{});
}
