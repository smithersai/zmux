const std = @import("std");

const buffer = @import("buffer.zig");
const native_mod = @import("native.zig");
const sys = @import("sys.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const NativeSessionOptions = native_mod.NativeSessionOptions;

/// Error names the mux contract returns (review §1.10).
pub const ContractError = error{ DuplicateSessionName, NameShadowsId, InvalidName, LimitExceeded, PaneRunning, InvalidAxis };

/// Shared deadline `terminateAll` gives every pane after `beginTerminate`.
pub const terminate_all_deadline_ms: i64 = 500;

/// Owned identifiers for a pane plus one retained reference to its native
/// session. `deinit` frees the ids and releases the native.
pub const PaneHandle = struct {
    allocator: Allocator,
    session_id: []u8,
    window_id: []u8,
    pane_id: []u8,
    native: *NativeSession,

    pub fn deinit(self: *PaneHandle) void {
        self.native.release();
        self.freeIds();
        self.* = undefined;
    }

    /// Allocates the ids up front so the caller can create the pane without a
    /// later allocation failure. `native` is set by `adopt`.
    fn initIds(allocator: Allocator, session_id: []const u8, window_id: []const u8, pane_id: []const u8) !PaneHandle {
        const owned_session = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session);
        const owned_window = try allocator.dupe(u8, window_id);
        errdefer allocator.free(owned_window);
        const owned_pane = try allocator.dupe(u8, pane_id);
        return .{
            .allocator = allocator,
            .session_id = owned_session,
            .window_id = owned_window,
            .pane_id = owned_pane,
            .native = undefined,
        };
    }

    fn freeIds(self: *PaneHandle) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.window_id);
        self.allocator.free(self.pane_id);
    }

    /// Retains `native`. Must run under the manager mutex, while the pane that
    /// owns `native` is still reachable.
    fn adopt(self: *PaneHandle, native: *NativeSession) PaneHandle {
        native.retain();
        self.native = native;
        return self.*;
    }
};

/// Drop a handle the caller does not need.
fn discardHandle(handle: PaneHandle) void {
    var owned = handle;
    owned.deinit();
}

pub const AttachResult = struct {
    client: ClientSnapshot,
    created: bool,
    exited: bool,
    exit: ?native_mod.ExitInfo,
    generation: u64,
};

pub const RespawnOptions = struct { kill: bool = false };

pub const Counts = struct { sessions: usize, panes: usize, live_panes: usize };

pub const DetachReason = enum { pane_removed, session_removed, remote_detach };

pub const DetachedClient = struct { client_id: []u8, reason: DetachReason };

/// Free a slice returned by `Manager.takeDetachedClients`.
pub fn freeDetachedClients(allocator: Allocator, items: []DetachedClient) void {
    for (items) |item| allocator.free(item.client_id);
    allocator.free(items);
}

pub const Limits = struct {
    max_panes: usize = 256,
    max_clients: usize = 1024,
    max_bindings: usize = 1024,
    max_total_scrollback_bytes: usize = 1024 * 1024 * 1024,
    max_layout_depth: usize = 32,
};

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
    env_mode: native_mod.EnvMode = .merge,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,

    pub fn fromOptions(allocator: Allocator, opts: CreateOptions) !SpawnSpec {
        var spec: SpawnSpec = .{
            .env_mode = opts.env_mode,
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
            .env_mode = self.env_mode,
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
    /// `.merge` lays `env` over the daemon environment; `.replace` starts the
    /// child with `env` only (plus the default `TERM` when it is unset).
    env_mode: native_mod.EnvMode = .merge,
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

    pub const LeafHit = struct {
        node: *LayoutNode,
        /// Number of splits above the leaf; a root leaf has depth 0.
        depth: usize,
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

    /// Recursion depth is bounded by `Limits.max_layout_depth`.
    pub fn findLeaf(self: *LayoutNode, pane_id: []const u8, depth: usize) ?LeafHit {
        switch (self.*) {
            .leaf => |existing| return if (std.mem.eql(u8, existing, pane_id)) .{ .node = self, .depth = depth } else null,
            .split => |split| return split.first.findLeaf(pane_id, depth + 1) orelse split.second.findLeaf(pane_id, depth + 1),
        }
    }

    /// Replaces the leaf `target_pane_id` with a split of copies of the leaf
    /// and `new_pane_id`. Returns false, allocating nothing, when the leaf is
    /// absent. OutOfMemory leaves the tree unchanged.
    pub fn replaceLeafWithSplit(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        new_pane_id: []const u8,
        split_id: []const u8,
    ) !bool {
        if (self.findLeaf(target_pane_id, 0) == null) return false;
        const first = try LayoutNode.leafNode(allocator, target_pane_id);
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
        return self.replaceLeafWithSplitOwned(allocator, target_pane_id, axis, owned_split_id, first, second);
    }

    /// Like `replaceLeafWithSplit`, but takes ownership of `split_id`,
    /// `first`, and `second` only when it returns true. Never allocates.
    pub fn replaceLeafWithSplitOwned(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        split_id: []u8,
        first: *LayoutNode,
        second: *LayoutNode,
    ) bool {
        const hit = self.findLeaf(target_pane_id, 0) orelse return false;
        allocator.free(hit.node.leaf);
        hit.node.* = .{ .split = .{ .id = split_id, .axis = axis, .first = first, .second = second } };
        return true;
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
    /// Current spawn recipe. `resizePane`, `attachClient`, and `switchClient`
    /// keep `rows`/`cols` at the last applied geometry so a respawn reuses it.
    spawn: SpawnSpec,
    native: *NativeSession,
    alerts: AlertState = .{},

    /// Tears down the native. Never call this with the manager mutex held: the
    /// reader thread may be blocked in the event sink waiting for that mutex.
    ///
    /// The sink is cleared first, waiting for an in-flight callback, so a
    /// public handle that outlives the pane can never call into the sink's
    /// context after removal (the reader may still drain final output).
    pub fn deinit(self: *Pane, allocator: Allocator) void {
        // `setEventSink(null)` waits for in-flight callbacks except on the
        // native's own reader thread, where waiting would wait for itself.
        self.native.setEventSink(null);
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
    /// Unique across sessions, never empty, never equal to an existing id.
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

/// A logical attachment of one terminal to one pane. A recorded client is
/// always attached, so JSON reports `"active":true`.
pub const Client = struct {
    id: []u8,
    session_id: []u8,
    window_id: []u8,
    pane_id: []u8,
    rows: u16,
    cols: u16,

    pub fn deinit(self: *Client, allocator: Allocator) void {
        allocator.free(self.id);
        self.deinitKeepId(allocator);
    }

    /// Frees everything except `id`, whose ownership moved elsewhere.
    fn deinitKeepId(self: *Client, allocator: Allocator) void {
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
    /// Always parses with `Manager.parseCommandLine`.
    command: []u8,
    /// Client hint: the key may repeat without the prefix. The daemon does not
    /// interpret it.
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

    /// Tears down natives: call only after releasing the manager mutex.
    fn deinit(self: RemovedItems, allocator: Allocator) void {
        if (self.pane) |pane| pane.deinit(allocator);
        if (self.window) |window| window.deinit(allocator);
        if (self.session) |session| session.deinit(allocator);
    }
};

const PaneRef = struct { session: *Session, window: *Window, pane: *Pane };
const WindowRef = struct { session: *Session, window: *Window };

/// Splits a `command.exec` line into mux words. Space, tab, CR, and LF delimit
/// words; single quotes are literal; double quotes and bare backslashes escape
/// one byte. The shell command after the mux words is never re-tokenized.
const CommandScanner = struct {
    line: []const u8,
    pos: usize = 0,

    const Word = struct { start: usize, text: []u8 };

    fn isSpace(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
    }

    fn next(self: *CommandScanner, allocator: Allocator) !?Word {
        while (self.pos < self.line.len and isSpace(self.line[self.pos])) self.pos += 1;
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        while (self.pos < self.line.len and !isSpace(self.line[self.pos])) {
            switch (self.line[self.pos]) {
                '\'' => {
                    const close = std.mem.indexOfScalarPos(u8, self.line, self.pos + 1, '\'') orelse return error.UnsupportedCommand;
                    try out.appendSlice(allocator, self.line[self.pos + 1 .. close]);
                    self.pos = close + 1;
                },
                '"' => {
                    self.pos += 1;
                    while (true) {
                        if (self.pos >= self.line.len) return error.UnsupportedCommand;
                        const byte = self.line[self.pos];
                        if (byte == '"') {
                            self.pos += 1;
                            break;
                        }
                        if (byte == '\\' and self.pos + 1 < self.line.len) {
                            try out.append(allocator, self.line[self.pos + 1]);
                            self.pos += 2;
                            continue;
                        }
                        try out.append(allocator, byte);
                        self.pos += 1;
                    }
                },
                '\\' => {
                    if (self.pos + 1 >= self.line.len) return error.UnsupportedCommand;
                    try out.append(allocator, self.line[self.pos + 1]);
                    self.pos += 2;
                },
                else => |byte| {
                    try out.append(allocator, byte);
                    self.pos += 1;
                },
            }
        }
        return .{ .start = start, .text = try out.toOwnedSlice(allocator) };
    }

    fn tail(line: []const u8, start: usize) ?[]const u8 {
        const rest = std.mem.trim(u8, line[start..], " \t\r\n");
        return if (rest.len == 0) null else rest;
    }
};

/// Called once per respawn, after the old generation is quiesced and before
/// the new generation can deliver any event, from every respawn path (RPC,
/// `executeCommandLine`, `executeBinding`).
pub const RespawnListener = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, native: *NativeSession) void,
};

/// A respawned generation whose events wait until its announcement is out.
const RespawnGate = struct {
    pane_id: []u8,
    generation: u64,
};

/// Manager whose sink the current thread is running inside, so a clear from
/// inside a callback does not wait for itself.
threadlocal var sink_callback_manager: ?*const Manager = null;

/// Pane id and generation of an event, for respawn gating. Null for events
/// that carry no generation.
fn eventGateKey(event: native_mod.Event) ?struct { pane_id: []const u8, generation: u64 } {
    return switch (event) {
        .foreground_changed => null,
        .session_exited => |params| .{ .pane_id = params.session_id, .generation = params.generation },
        .pane_output => |params| .{ .pane_id = params.pane_id, .generation = params.generation },
        .pane_activity => |params| .{ .pane_id = params.pane_id, .generation = params.generation },
        .pane_bell => |params| .{ .pane_id = params.pane_id, .generation = params.generation },
    };
}

pub const Manager = struct {
    allocator: Allocator,
    /// Shared with every spawned `NativeSession`; supplies mutexes, clocks,
    /// and sleeps.
    io: std.Io,
    /// Use `setEventSink`/`clearEventSinks`; they also update existing panes.
    /// Natives never call this sink directly: they call `emitThroughManager`,
    /// which counts the callback in `sink_in_flight`. Written holding both
    /// `mutex` and `sink_mutex`; read under either.
    event_sink: ?native_mod.EventSink = null,
    mutex: std.Io.Mutex = .init,
    /// Guards `event_sink` writes, `respawn_listener`, `sink_in_flight`, and
    /// `respawn_gates`. Lock order: `mutex` before `sink_mutex`.
    sink_mutex: std.Io.Mutex = .init,
    /// Broadcast when `sink_in_flight` reaches zero.
    sink_idle: std.Io.Condition = .init,
    /// Broadcast when a respawn gate lifts.
    gate_changed: std.Io.Condition = .init,
    /// Callbacks into `event_sink` or `respawn_listener` currently running or
    /// waiting on a respawn gate, from every native, attached or not.
    /// `clearEventSinks` waits for zero without allocating.
    sink_in_flight: usize = 0,
    /// Re-entrant `clearEventSinks` calls currently waiting inside a sink
    /// callback. Tracked so `finishSinkCall` wakes a re-entrant waiter when
    /// another callback finishes, and two re-entrant callers do not deadlock.
    sink_reentrant_waiters: usize = 0,
    respawn_listener: ?RespawnListener = null,
    respawn_gates: std.ArrayList(RespawnGate) = .empty,
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    /// Index over every pane in `sessions`. Keys borrow `Pane.id`; an entry
    /// is removed before its pane is detached from the tree.
    panes_by_id: std.StringHashMapUnmanaged(PaneRef) = .empty,
    /// Index over `clients`. Keys borrow `Client.id`.
    clients_by_id: std.StringHashMapUnmanaged(*Client) = .empty,
    key_bindings: std.ArrayList(KeyBinding) = .empty,
    /// Invariant: `capacity >= items.len + clients.items.len`, so moving a
    /// client here during removal never allocates.
    detached_clients: std.ArrayList(DetachedClient) = .empty,
    next_session_id: usize = 0,
    next_window_id: usize = 0,
    next_pane_id: usize = 0,
    next_split_id: usize = 0,
    next_client_id: usize = 0,
    /// Successful `NativeSession.create` calls. Lets tests prove a rejected
    /// request spawned no child.
    spawn_count: usize = 0,
    limits: Limits = .{},

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
        for (self.detached_clients.items) |item| self.allocator.free(item.client_id);
        self.detached_clients.deinit(self.allocator);
        for (self.respawn_gates.items) |gate| self.allocator.free(gate.pane_id);
        self.respawn_gates.deinit(self.allocator);
    }

    /// Live panes (native not terminated).
    pub fn count(self: *Manager) usize {
        return self.counts().live_panes;
    }

    pub fn sessionCount(self: *Manager) usize {
        return self.counts().sessions;
    }

    pub fn paneCount(self: *Manager) usize {
        return self.counts().panes;
    }

    /// Session, pane, and live-pane counts from one critical section.
    pub fn counts(self: *Manager) Counts {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var result: Counts = .{ .sessions = self.sessions.items.len, .panes = 0, .live_panes = 0 };
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    result.panes += 1;
                    if (pane.native.finalizedExitInfo() == null) result.live_panes += 1;
                }
            }
        }
        return result;
    }

    /// Returns a retained native session. Caller owns one release(). The
    /// reference is taken under the mutex, so a concurrent terminate cannot
    /// free the native first.
    pub fn create(self: *Manager, opts: CreateOptions) !*NativeSession {
        var handle = try self.createSessionPane(opts);
        defer handle.deinit();
        handle.native.retain();
        return handle.native;
    }

    /// `opts.title`, when set, names the session (see `validateSessionNameLocked`).
    pub fn createSessionPane(self: *Manager, opts: CreateOptions) !PaneHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.createSessionPaneLocked(opts, opts.title);
    }

    pub fn newWindow(self: *Manager, session_id: []const u8, opts: CreateOptions) !PaneHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const session = self.findSessionLocked(session_id) orelse return error.SessionNotFound;
        try self.checkPaneLimitsLocked(opts.scrollback_bytes);
        const window_id = try self.nextIdLocked("win", &self.next_window_id);
        defer self.allocator.free(window_id);
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);
        var handle = try PaneHandle.initIds(self.allocator, session.id, window_id, pane_id);
        errdefer handle.freeIds();

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

        // Last fallible step; everything after it commits.
        const pane = try self.createPaneLocked(session, window, pane_id, opts);
        window.panes.appendAssumeCapacity(pane);
        session.windows.appendAssumeCapacity(window);
        self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = session, .window = window, .pane = pane });

        session.next_window_index += 1;
        self.allocator.free(session.active_window_id);
        session.active_window_id = active_window_id;
        return handle.adopt(pane.native);
    }

    pub fn splitPane(self: *Manager, target_pane_id: []const u8, axis: Axis, opts: CreateOptions) !PaneHandle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
        // The pane list and the layout agree (checkInvariants); a missing
        // leaf is reported, never assumed away.
        const leaf = found.window.layout.findLeaf(found.pane.id, 0) orelse return error.PaneNotFound;
        if (leaf.depth + 1 > self.limits.max_layout_depth) return error.LimitExceeded;
        try self.checkPaneLimitsLocked(opts.scrollback_bytes);

        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);
        var handle = try PaneHandle.initIds(self.allocator, found.session.id, found.window.id, pane_id);
        errdefer handle.freeIds();
        const split_id = try self.nextIdLocked("split", &self.next_split_id);
        errdefer self.allocator.free(split_id);

        const first = try self.allocator.create(LayoutNode);
        errdefer self.allocator.destroy(first);
        const second = try LayoutNode.leafNode(self.allocator, pane_id);
        errdefer {
            second.deinit(self.allocator);
            self.allocator.destroy(second);
        }
        try found.window.panes.ensureUnusedCapacity(self.allocator, 1);
        try self.panes_by_id.ensureUnusedCapacity(self.allocator, 1);
        const active_pane_id = try self.allocator.dupe(u8, pane_id);
        errdefer self.allocator.free(active_pane_id);

        // Last fallible step; everything after it commits.
        const pane = try self.createPaneLocked(found.session, found.window, pane_id, opts);
        first.* = .{ .leaf = leaf.node.leaf };
        leaf.node.* = .{ .split = .{ .id = split_id, .axis = axis, .first = first, .second = second } };
        found.window.panes.appendAssumeCapacity(pane);
        self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = found.session, .window = found.window, .pane = pane });
        self.allocator.free(found.window.active_pane_id);
        found.window.active_pane_id = active_pane_id;
        return handle.adopt(pane.native);
    }

    pub fn selectPane(self: *Manager, pane_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.findPaneWithParentsLocked(pane_id) orelse return error.PaneNotFound;
        const active_pane = try self.allocator.dupe(u8, found.pane.id);
        errdefer self.allocator.free(active_pane);
        const active_window = try self.allocator.dupe(u8, found.window.id);
        self.allocator.free(found.window.active_pane_id);
        found.window.active_pane_id = active_pane;
        self.allocator.free(found.session.active_window_id);
        found.session.active_window_id = active_window;
    }

    pub fn selectWindow(self: *Manager, window_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.findWindowWithParentLocked(window_id) orelse return error.WindowNotFound;
        try replaceOwnedString(self.allocator, &found.session.active_window_id, found.window.id);
    }

    /// `session_id` may be a pane id, a session id, or a session name. Fails
    /// with `InvalidName`, `DuplicateSessionName`, or `NameShadowsId`.
    pub fn renameSession(self: *Manager, session_id: []const u8, title: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.resolveTargetSessionLocked(session_id) orelse return error.SessionNotFound;
        if (std.mem.eql(u8, session.name, title)) return;
        try self.validateSessionNameLocked(title, session);
        try replaceOwnedString(self.allocator, &session.name, title);
    }

    pub fn renameWindow(self: *Manager, window_id: []const u8, title: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const found = self.findWindowWithParentLocked(window_id) orelse return error.WindowNotFound;
        try validateNameText(title);
        try replaceOwnedString(self.allocator, &found.window.name, title);
    }

    /// Updates the pane title and the native title, so `session.info`,
    /// `session.list`, and `mux.snapshot` agree.
    pub fn renamePane(self: *Manager, pane_id: []const u8, title: []const u8, custom: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return error.PaneNotFound;
        try validateNameText(title);
        const owned = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned);
        try pane.native.setTitle(title);
        self.allocator.free(pane.title);
        pane.title = owned;
        pane.has_custom_title = custom;
    }

    /// Replace the pane's native session with a fresh spawn of the same spec,
    /// at the current geometry, with the next generation. Fails with
    /// `PaneRunning` when the current child is running and `opts.kill` is
    /// false. A failed spawn leaves the old native in place, untouched.
    ///
    /// Event order is fixed for every caller: callbacks of the old generation
    /// stop and drain, then `respawn_listener` announces the new generation,
    /// and only then can the new generation's events reach the sink.
    pub fn respawnPane(self: *Manager, pane_id: []const u8, opts: RespawnOptions) !*NativeSession {
        var old_native: *NativeSession = undefined;
        var new_native: *NativeSession = undefined;
        var gated = false;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // Like every pane target: a pane id, or a session id or name
            // standing for that session's active pane.
            const pane = (self.resolveTargetPaneLocked(pane_id) orelse return error.PaneNotFound).pane;
            if (!opts.kill and pane.native.finalizedExitInfo() == null) return error.PaneRunning;
            const generation = pane.native.generation() + 1;
            const sink = self.nativeSinkLocked();
            if (sink != null) {
                // Before the spawn: the new reader may emit at once.
                try self.addRespawnGate(pane.id, generation);
                gated = true;
            }
            errdefer if (gated) self.liftRespawnGate(pane.id, generation);
            var native_opts = pane.spawn.nativeOptions(pane.id, sink);
            native_opts.title = pane.title;
            native_opts.generation = generation;
            new_native = try NativeSession.create(self.allocator, self.io, native_opts);
            self.spawn_count += 1;
            old_native = pane.native;
            // No old-generation callback starts once the swap is visible.
            // Does not wait, so it is safe under the manager mutex.
            old_native.dropEventSink();
            pane.native = new_native;
            // Reset once, at swap time. A later markExited for the new
            // generation must survive the old native's teardown below.
            pane.alerts.exited = false;
            new_native.retain();
        }

        // Outside the mutex: clearEventSink waits for an in-flight emit, and
        // the sink may itself wait for the manager mutex. Clearing first means
        // no session_exited for the old generation reaches the sink, and no
        // old event follows the announcement.
        old_native.clearEventSink();
        self.announceRespawn(new_native);
        if (gated) self.liftRespawnGate(new_native.id, new_native.generation());
        old_native.stopForOwnerRelease();
        old_native.destroy();
        return new_native;
    }

    pub fn attachClient(self: *Manager, target_pane_id: []const u8, rows: u16, cols: u16) !ClientSnapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const found = self.resolveTargetPaneLocked(target_pane_id) orelse return error.PaneNotFound;
        return self.attachClientLocked(found, rows, cols);
    }

    /// Attach a client to `target`, creating a session named `target` first
    /// when `create_opts` is non-null and the target does not resolve. One
    /// critical section covers lookup, creation, and attach. Never fails on an
    /// exited pane; reports `exited` and `exit` instead.
    pub fn attachOrCreateClient(self: *Manager, target: []const u8, rows: u16, cols: u16, create_opts: ?CreateOptions) !AttachResult {
        // Declared before the lock so a rollback tears down after unlock.
        var rollback: RemovedItems = .{};
        defer rollback.deinit(self.allocator);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var created = false;
        const found: PaneRef = self.resolveTargetPaneLocked(target) orelse blk: {
            var opts = create_opts orelse return error.PaneNotFound;
            if (self.clients.items.len >= self.limits.max_clients) return error.LimitExceeded;
            if (opts.title == null) opts.title = target;
            var handle = try self.createSessionPaneLocked(opts, target);
            // Not the last reference: the pane holds one under this lock.
            defer handle.deinit();
            created = true;
            break :blk self.findPaneWithParentsLocked(handle.pane_id).?;
        };
        errdefer if (created) {
            rollback = self.takeSessionLocked(found.session);
        };

        const client = try self.attachClientLocked(found, rows, cols);
        const exit = found.pane.native.finalizedExitInfo();
        return .{
            .client = client,
            .created = created,
            .exited = exit != null,
            .exit = exit,
            .generation = found.pane.native.generation(),
        };
    }

    /// Reap only panes whose native still runs; exited panes cost nothing.
    pub fn reapExitedPanes(self: *Manager) void {
        _ = self.reapExitedPanesCounted();
    }

    /// Returns how many natives were visited.
    fn reapExitedPanesCounted(self: *Manager) usize {
        self.mutex.lockUncancelable(self.io);
        var live: usize = 0;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.native.isRunning()) live += 1;
                }
            }
        }
        if (live == 0) {
            self.mutex.unlock(self.io);
            return 0;
        }
        var stack_buf: [64]*NativeSession = undefined;
        var heap_buf: ?[]*NativeSession = null;
        defer if (heap_buf) |buf| self.allocator.free(buf);
        const natives: []*NativeSession = if (live <= stack_buf.len) stack_buf[0..live] else blk: {
            const allocated = self.allocator.alloc(*NativeSession, live) catch {
                self.mutex.unlock(self.io);
                return 0;
            };
            heap_buf = allocated;
            break :blk allocated;
        };
        var used: usize = 0;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (used == natives.len) break;
                    if (!pane.native.isRunning()) continue;
                    pane.native.retain();
                    natives[used] = pane.native;
                    used += 1;
                }
            }
        }
        self.mutex.unlock(self.io);

        for (natives[0..used]) |native| {
            _ = native.reapExited();
            native.release();
        }
        return used;
    }

    pub fn paneScrollbackSnapshot(self: *Manager, allocator: Allocator, pane_id: []const u8) ![]u8 {
        const native = try self.retainPaneNative(pane_id);
        defer native.release();
        return native.scrollbackSnapshot(allocator);
    }

    pub fn paneScrollbackTail(self: *Manager, allocator: Allocator, pane_id: []const u8, max_bytes: usize) !buffer.Tail {
        const native = try self.retainPaneNative(pane_id);
        defer native.release();
        return native.scrollbackTail(allocator, max_bytes);
    }

    /// Detach at the owner's request. Records nothing in `takeDetachedClients`.
    pub fn detachClient(self: *Manager, client_id: []const u8) bool {
        return self.detachClientWithReason(client_id, null);
    }

    /// Detach a client on behalf of a connection that does not own it. The
    /// client is reported by `takeDetachedClients` with `.remote_detach` so the
    /// server can notify the owner.
    pub fn detachClientRemote(self: *Manager, client_id: []const u8) bool {
        return self.detachClientWithReason(client_id, .remote_detach);
    }

    fn detachClientWithReason(self: *Manager, client_id: []const u8, reason: ?DetachReason) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const client = self.clients_by_id.get(client_id) orelse return false;
        const index = std.mem.indexOfScalar(*Client, self.clients.items, client).?;
        self.removeClientAtLocked(index, reason);
        return true;
    }

    /// Clients pruned by pane or session removal, or detached remotely, since
    /// the last call. Caller frees with `freeDetachedClients(allocator, ...)`.
    pub fn takeDetachedClients(self: *Manager, allocator: Allocator) ![]DetachedClient {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = try allocator.alloc(DetachedClient, self.detached_clients.items.len);
        var filled: usize = 0;
        errdefer {
            for (result[0..filled]) |item| allocator.free(item.client_id);
            allocator.free(result);
        }
        for (self.detached_clients.items) |item| {
            result[filled] = .{ .client_id = try allocator.dupe(u8, item.client_id), .reason = item.reason };
            filled += 1;
        }
        for (self.detached_clients.items) |item| self.allocator.free(item.client_id);
        self.detached_clients.clearRetainingCapacity();
        return result;
    }

    /// Moves the client to `pane_id` and resizes that pane to the client's
    /// size (last writer wins). All allocation happens before any change.
    pub fn switchClient(self: *Manager, client_id: []const u8, pane_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const client = self.findClientLocked(client_id) orelse return error.ClientNotFound;
        const found = self.findPaneWithParentsLocked(pane_id) orelse return error.PaneNotFound;
        const session_id = try self.allocator.dupe(u8, found.session.id);
        errdefer self.allocator.free(session_id);
        const window_id = try self.allocator.dupe(u8, found.window.id);
        errdefer self.allocator.free(window_id);
        const owned_pane_id = try self.allocator.dupe(u8, found.pane.id);
        errdefer self.allocator.free(owned_pane_id);
        try applyPaneSize(found.pane, client.rows, client.cols);

        self.allocator.free(client.session_id);
        client.session_id = session_id;
        self.allocator.free(client.window_id);
        client.window_id = window_id;
        self.allocator.free(client.pane_id);
        client.pane_id = owned_pane_id;
    }

    /// Rejects a command `parseCommandLine` cannot run with `InvalidParams`.
    pub fn bindKey(self: *Manager, table: []const u8, key: []const u8, command: []const u8, repeat: bool) !void {
        var parsed = parseCommandLine(self.allocator, command) catch |err| switch (err) {
            error.UnsupportedCommand => return error.InvalidParams,
            else => |other| return other,
        };
        const is_noop = parsed == .noop;
        parsed.deinit(self.allocator);
        if (is_noop or table.len == 0 or key.len == 0) return error.InvalidParams;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.key_bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.table, table) and std.mem.eql(u8, binding.key, key)) {
                try replaceOwnedString(self.allocator, &binding.command, command);
                binding.repeat = repeat;
                return;
            }
        }

        if (self.key_bindings.items.len >= self.limits.max_bindings) return error.LimitExceeded;
        try self.key_bindings.ensureUnusedCapacity(self.allocator, 1);
        const owned_table = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(owned_table);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_command = try self.allocator.dupe(u8, command);
        self.key_bindings.appendAssumeCapacity(.{
            .table = owned_table,
            .key = owned_key,
            .command = owned_command,
            .repeat = repeat,
        });
    }

    /// Returns true when a binding was removed.
    pub fn unbindKey(self: *Manager, table: []const u8, key: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.key_bindings.items, 0..) |*binding, index| {
            if (std.mem.eql(u8, binding.table, table) and std.mem.eql(u8, binding.key, key)) {
                binding.deinit(self.allocator);
                _ = self.key_bindings.orderedRemove(index);
                return true;
            }
        }
        return false;
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

    /// Grammar (tmux subset):
    ///   split-window|splitw [-h|-v]... [--] [shell-command]
    ///   new-window|neww [-n name]... [--] [shell-command]
    ///   respawn-pane|respawnp
    /// Mux words follow `CommandScanner` quoting. The shell command is the
    /// original text after the mux words, byte for byte, minus outer
    /// whitespace. Unknown commands or flags fail with `UnsupportedCommand`.
    pub fn parseCommandLine(allocator: Allocator, line: []const u8) !ParsedCommand {
        var scanner: CommandScanner = .{ .line = line };
        const name = (try scanner.next(allocator)) orelse return .noop;
        defer allocator.free(name.text);

        if (std.mem.eql(u8, name.text, "split-window") or std.mem.eql(u8, name.text, "splitw")) {
            var axis: Axis = .vertical;
            const tail_start = while (try scanner.next(allocator)) |word| {
                const start = word.start;
                const flag = classifyFlag(word.text);
                allocator.free(word.text);
                switch (flag) {
                    .h => axis = .horizontal,
                    .v => axis = .vertical,
                    .end => break scanner.pos,
                    .word => break start,
                    .n, .other => return error.UnsupportedCommand,
                }
            } else line.len;
            return .{ .split_window = .{ .axis = axis, .command = try dupeOpt(allocator, CommandScanner.tail(line, tail_start)) } };
        }
        if (std.mem.eql(u8, name.text, "new-window") or std.mem.eql(u8, name.text, "neww")) {
            var title: ?[]u8 = null;
            errdefer if (title) |value| allocator.free(value);
            const tail_start = while (try scanner.next(allocator)) |word| {
                const start = word.start;
                const flag = classifyFlag(word.text);
                allocator.free(word.text);
                switch (flag) {
                    .n => {
                        const value = (try scanner.next(allocator)) orelse return error.UnsupportedCommand;
                        if (title) |old| allocator.free(old);
                        title = value.text;
                    },
                    .end => break scanner.pos,
                    .word => break start,
                    .h, .v, .other => return error.UnsupportedCommand,
                }
            } else line.len;
            const command = try dupeOpt(allocator, CommandScanner.tail(line, tail_start));
            return .{ .new_window = .{ .title = title, .command = command } };
        }
        if (std.mem.eql(u8, name.text, "respawn-pane") or std.mem.eql(u8, name.text, "respawnp")) {
            if (try scanner.next(allocator)) |extra| {
                allocator.free(extra.text);
                return error.UnsupportedCommand;
            }
            return .respawn_pane;
        }
        return error.UnsupportedCommand;
    }

    const Flag = enum { h, v, n, end, other, word };

    fn classifyFlag(text: []const u8) Flag {
        if (std.mem.eql(u8, text, "-h")) return .h;
        if (std.mem.eql(u8, text, "-v")) return .v;
        if (std.mem.eql(u8, text, "-n")) return .n;
        if (std.mem.eql(u8, text, "--")) return .end;
        if (std.mem.startsWith(u8, text, "-")) return .other;
        return .word;
    }

    /// New panes inherit the target pane's size and cwd.
    pub fn executeCommandLine(self: *Manager, line: []const u8, target_pane_id: []const u8) !void {
        var parsed = try parseCommandLine(self.allocator, line);
        defer parsed.deinit(self.allocator);
        if (parsed == .noop) return;
        if (parsed == .respawn_pane) {
            const native = try self.respawnPane(target_pane_id, .{ .kill = true });
            native.release();
            return;
        }

        var session_id: []u8 = undefined;
        var cwd: ?[]u8 = null;
        var rows: u16 = undefined;
        var cols: u16 = undefined;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
            session_id = try self.allocator.dupe(u8, found.session.id);
            errdefer self.allocator.free(session_id);
            cwd = try dupeOpt(self.allocator, found.pane.spawn.cwd);
            rows = found.pane.spawn.rows;
            cols = found.pane.spawn.cols;
        }
        defer self.allocator.free(session_id);
        defer if (cwd) |value| self.allocator.free(value);

        switch (parsed) {
            .noop, .respawn_pane => unreachable,
            .split_window => |split| discardHandle(try self.splitPane(target_pane_id, split.axis, .{
                .command = split.command,
                .cwd = cwd,
                .rows = rows,
                .cols = cols,
            })),
            .new_window => |nw| discardHandle(try self.newWindow(session_id, .{
                .title = nw.title,
                .command = nw.command,
                .cwd = cwd,
                .rows = rows,
                .cols = cols,
            })),
        }
    }

    /// Assert all internal structural invariants of the mux state graph.
    /// Intended for stateful fuzz and model-checking suites.
    pub fn checkInvariants(self: *Manager, allocator: Allocator) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var seen_sessions = std.StringHashMap(void).init(allocator);
        defer seen_sessions.deinit();
        var seen_names = std.StringHashMap(void).init(allocator);
        defer seen_names.deinit();
        var seen_windows = std.StringHashMap(void).init(allocator);
        defer seen_windows.deinit();
        var seen_panes = std.StringHashMap(void).init(allocator);
        defer seen_panes.deinit();
        var seen_clients = std.StringHashMap(void).init(allocator);
        defer seen_clients.deinit();

        for (self.sessions.items) |session| {
            if ((try seen_sessions.fetchPut(session.id, {})) != null) return error.DuplicateSessionId;
            if ((try seen_names.fetchPut(session.name, {})) != null) return error.DuplicateSessionName;
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

        for (self.sessions.items) |session| {
            if (self.idExistsLocked(session.name, session)) return error.NameShadowsId;
        }

        for (self.clients.items) |client| {
            if ((try seen_clients.fetchPut(client.id, {})) != null) return error.DuplicateClientId;
            const found = self.findPaneWithParentsLocked(client.pane_id) orelse return error.DanglingClient;
            if (!std.mem.eql(u8, found.session.id, client.session_id)) return error.ClientSessionMismatch;
            if (!std.mem.eql(u8, found.window.id, client.window_id)) return error.ClientWindowMismatch;
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
        if (self.detached_clients.capacity < self.detached_clients.items.len + self.clients.items.len) {
            return error.DetachedCapacityShort;
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

    /// Stores the event's `ts_ms`. Ignores events from a stale `generation`.
    pub fn markActivity(self: *Manager, pane_id: []const u8, generation: u64, ts_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return;
        if (pane.native.generation() != generation) return;
        pane.alerts.activity = true;
        pane.alerts.last_activity_ms = ts_ms;
    }

    /// Stores the event's `ts_ms`. Ignores events from a stale `generation`.
    pub fn markBell(self: *Manager, pane_id: []const u8, generation: u64, ts_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return;
        if (pane.native.generation() != generation) return;
        pane.alerts.bell = true;
        pane.alerts.last_bell_ms = ts_ms;
    }

    /// `pane_id` is the `session_exited` event's id, which is a pane id.
    /// Ignores events from a stale `generation`.
    pub fn markExited(self: *Manager, pane_id: []const u8, generation: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return;
        if (pane.native.generation() != generation) return;
        pane.alerts.exited = true;
    }

    /// `markExited` that reports whether the event is current. False only when
    /// the pane exists and runs another generation: the event is stale and
    /// must not be broadcast. An unknown pane (removed, or never a pane) is
    /// not stale.
    pub fn markExitedIfCurrent(self: *Manager, pane_id: []const u8, generation: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return true;
        if (pane.native.generation() != generation) return false;
        pane.alerts.exited = true;
        return true;
    }

    /// False only when `pane_id` exists and runs another generation.
    pub fn isCurrentGeneration(self: *Manager, pane_id: []const u8, generation: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return true;
        return pane.native.generation() == generation;
    }

    /// `native.stopInput` on every pane: wakes writers blocked on a full PTY.
    pub fn interruptInput(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| pane.native.stopInput();
            }
        }
    }

    /// Set the manager sink and apply it to every existing native, so panes
    /// created before the server starts also report events.
    /// A null `sink` is `clearEventSinks`. The manager must not move while a
    /// sink is installed: natives hold its address.
    pub fn setEventSink(self: *Manager, sink: ?native_mod.EventSink) void {
        if (sink == null) return self.clearEventSinks();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        {
            self.sink_mutex.lockUncancelable(self.io);
            defer self.sink_mutex.unlock(self.io);
            self.event_sink = sink;
        }
        const trampoline = self.nativeSinkLocked();
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| pane.native.setEventSink(trampoline);
            }
        }
    }

    /// Install (or with null, remove) the respawn announcement hook. Cleared
    /// by `clearEventSinks`, which also waits for a running announcement.
    pub fn setRespawnListener(self: *Manager, listener: ?RespawnListener) void {
        self.sink_mutex.lockUncancelable(self.io);
        defer self.sink_mutex.unlock(self.io);
        self.respawn_listener = listener;
    }

    /// Null the manager sink and the respawn listener, stop every attached
    /// native from starting a callback, then wait until no callback into the
    /// sink or listener is running, from any native: attached, removed but
    /// still draining, or replaced by a respawn. Never allocates, so the
    /// barrier holds under memory exhaustion. After return the sink's
    /// context may be freed. From inside a sink callback it waits for every
    /// callback but the caller's own.
    pub fn clearEventSinks(self: *Manager) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            {
                self.sink_mutex.lockUncancelable(self.io);
                defer self.sink_mutex.unlock(self.io);
                self.event_sink = null;
                self.respawn_listener = null;
            }
            // dropEventSink does not wait, so it is safe under the mutex.
            for (self.sessions.items) |session| {
                for (session.windows.items) |window| {
                    for (window.panes.items) |pane| pane.native.dropEventSink();
                }
            }
        }
        // Outside the manager mutex: a running callback may be waiting for it.
        self.sink_mutex.lockUncancelable(self.io);
        defer self.sink_mutex.unlock(self.io);
        const reentrant = sink_callback_manager == self;
        if (reentrant) {
            self.sink_reentrant_waiters += 1;
            if (self.sink_in_flight <= self.sink_reentrant_waiters) {
                self.sink_idle.broadcast(self.io);
            }
        }
        defer if (reentrant) {
            self.sink_reentrant_waiters -= 1;
        };
        while (self.sink_in_flight > (if (reentrant) self.sink_reentrant_waiters else 0)) {
            self.sink_idle.waitUncancelable(self.io, &self.sink_mutex);
        }
    }

    /// The sink natives get: the manager trampoline when a sink is set.
    fn nativeSinkLocked(self: *Manager) ?native_mod.EventSink {
        if (self.event_sink == null) return null;
        return .{ .context = self, .emit = emitThroughManager };
    }

    /// Every native event passes through here, so `clearEventSinks` can
    /// count and wait for callbacks from natives it can no longer reach.
    fn emitThroughManager(context: *anyopaque, event: native_mod.Event) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        const key = eventGateKey(event);
        self.sink_mutex.lockUncancelable(self.io);
        // Counted before waiting on a gate: a clear must also wait for a
        // callback that is parked here.
        self.sink_in_flight += 1;
        if (key) |k| {
            while (self.isGatedLocked(k.pane_id, k.generation)) {
                self.gate_changed.waitUncancelable(self.io, &self.sink_mutex);
            }
        }
        const sink = self.event_sink;
        self.sink_mutex.unlock(self.io);

        if (sink) |active| {
            const previous = sink_callback_manager;
            sink_callback_manager = self;
            active.emit(active.context, event);
            sink_callback_manager = previous;
        }
        self.finishSinkCall();
    }

    fn finishSinkCall(self: *Manager) void {
        self.sink_mutex.lockUncancelable(self.io);
        defer self.sink_mutex.unlock(self.io);
        self.sink_in_flight -= 1;
        if (self.sink_in_flight == 0 or self.sink_in_flight <= self.sink_reentrant_waiters) {
            self.sink_idle.broadcast(self.io);
        }
    }

    fn announceRespawn(self: *Manager, native: *NativeSession) void {
        const listener = blk: {
            self.sink_mutex.lockUncancelable(self.io);
            defer self.sink_mutex.unlock(self.io);
            const listener = self.respawn_listener orelse return;
            self.sink_in_flight += 1;
            break :blk listener;
        };
        defer self.finishSinkCall();
        const previous = sink_callback_manager;
        sink_callback_manager = self;
        defer sink_callback_manager = previous;
        listener.notify(listener.context, native);
    }

    /// Caller holds `mutex`. Allocates before the spawn so a failure changes
    /// nothing.
    fn addRespawnGate(self: *Manager, pane_id: []const u8, generation: u64) !void {
        const owned = try self.allocator.dupe(u8, pane_id);
        errdefer self.allocator.free(owned);
        self.sink_mutex.lockUncancelable(self.io);
        defer self.sink_mutex.unlock(self.io);
        try self.respawn_gates.append(self.allocator, .{ .pane_id = owned, .generation = generation });
    }

    fn liftRespawnGate(self: *Manager, pane_id: []const u8, generation: u64) void {
        self.sink_mutex.lockUncancelable(self.io);
        defer self.sink_mutex.unlock(self.io);
        for (self.respawn_gates.items, 0..) |gate, index| {
            if (gate.generation == generation and std.mem.eql(u8, gate.pane_id, pane_id)) {
                const removed = self.respawn_gates.swapRemove(index);
                self.allocator.free(removed.pane_id);
                break;
            }
        }
        self.gate_changed.broadcast(self.io);
    }

    fn isGatedLocked(self: *Manager, pane_id: []const u8, generation: u64) bool {
        for (self.respawn_gates.items) |gate| {
            if (gate.generation == generation and std.mem.eql(u8, gate.pane_id, pane_id)) return true;
        }
        return false;
    }

    /// Resize a pane: the native PTY (when running), the spawn spec used by
    /// respawn, and every client attached to the pane. Last writer wins;
    /// detaching does not restore an earlier size.
    pub fn resizePane(self: *Manager, pane_id: []const u8, rows: u16, cols: u16) !void {
        if (rows == 0 or cols == 0) return error.InvalidDimensions;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return error.PaneNotFound;
        try applyPaneSize(pane, rows, cols);
        for (self.clients.items) |client| {
            if (!std.mem.eql(u8, client.pane_id, pane.id)) continue;
            client.rows = rows;
            client.cols = cols;
        }
    }

    pub fn find(self: *Manager, id: []const u8) ?*NativeSession {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = (self.resolveTargetPaneLocked(id) orelse return null).pane;
        pane.native.retain();
        return pane.native;
    }

    /// Remove a pane (by id) or a whole session (by id, then name). Removing
    /// the last pane removes its session. Returns false when nothing matches,
    /// and also on OutOfMemory, in which case nothing changed.
    pub fn terminate(self: *Manager, id: []const u8) bool {
        const removed = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.findPaneWithParentsLocked(id)) |found| {
                if (found.window.panes.items.len == 1 and found.session.windows.items.len == 1) {
                    break :blk self.takeSessionLocked(found.session);
                }
                break :blk self.takePaneLocked(found) catch return false;
            }
            const session = self.findSessionLocked(id) orelse return false;
            break :blk self.takeSessionLocked(session);
        };
        removed.deinit(self.allocator);
        return true;
    }

    /// Remove every session and client. Starts teardown of every native, then
    /// waits for all of them against one shared deadline with the mutex
    /// released.
    pub fn terminateAll(self: *Manager) void {
        self.mutex.lockUncancelable(self.io);
        var sessions = self.sessions;
        self.sessions = .empty;
        self.panes_by_id.clearRetainingCapacity();
        while (self.clients.items.len > 0) self.removeClientAtLocked(self.clients.items.len - 1, .session_removed);
        self.mutex.unlock(self.io);

        // `sessions` is now private to this call.
        for (sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.native.state() != .terminated) pane.native.beginTerminate();
                }
            }
        }
        const deadline_ms = sys.monotonicMs() + terminate_all_deadline_ms;
        for (sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.native.state() != .terminated) pane.native.awaitTerminated(deadline_ms);
                }
            }
        }
        for (sessions.items) |session| session.deinit(self.allocator);
        sessions.deinit(self.allocator);
    }

    /// One object per pane: the native `infoJson` fields plus `sessionId`,
    /// `sessionName`, `windowId`, `paneId`, and `paneTitle`.
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

    // ---- internals (all *Locked functions require the mutex) ----

    /// Creates a session whose name is `name orelse <session id>`. Checks the
    /// name and limits before any allocation or fork.
    fn createSessionPaneLocked(self: *Manager, opts: CreateOptions, name: ?[]const u8) !PaneHandle {
        if (name) |value| try self.validateSessionNameLocked(value, null);
        try self.checkPaneLimitsLocked(opts.scrollback_bytes);

        const session_id = try self.nextIdLocked("sess", &self.next_session_id);
        errdefer self.allocator.free(session_id);
        const window_id = try self.nextIdLocked("win", &self.next_window_id);
        defer self.allocator.free(window_id);
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);
        var handle = try PaneHandle.initIds(self.allocator, session_id, window_id, pane_id);
        errdefer handle.freeIds();

        const session_name = try self.allocator.dupe(u8, name orelse session_id);
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
        // Last fallible step; everything after it commits.
        const pane = try self.createPaneLocked(session, window, pane_id, opts);
        window.panes.appendAssumeCapacity(pane);
        session.windows.appendAssumeCapacity(window);
        self.sessions.appendAssumeCapacity(session);
        self.panes_by_id.putAssumeCapacity(pane.id, .{ .session = session, .window = window, .pane = pane });
        return handle.adopt(pane.native);
    }

    /// Spawns the native as the final fallible step, so callers commit
    /// infallibly after it and never tear a native down under the mutex.
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

        const native = try NativeSession.create(self.allocator, self.io, spawn.nativeOptions(pane_id, self.nativeSinkLocked()));
        self.spawn_count += 1;

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

    /// All fallible work (limits, reservations, allocation, resize) happens
    /// before the client is recorded. Skips the resize on an exited pane.
    fn attachClientLocked(self: *Manager, found: PaneRef, rows: u16, cols: u16) !ClientSnapshot {
        if (self.clients.items.len >= self.limits.max_clients) return error.LimitExceeded;
        try self.detached_clients.ensureTotalCapacity(
            self.allocator,
            self.detached_clients.items.len + self.clients.items.len + 1,
        );
        try self.clients.ensureUnusedCapacity(self.allocator, 1);
        try self.clients_by_id.ensureUnusedCapacity(self.allocator, 1);

        const client_id = try self.nextIdLocked("client", &self.next_client_id);
        errdefer self.allocator.free(client_id);
        const session_id = try self.allocator.dupe(u8, found.session.id);
        errdefer self.allocator.free(session_id);
        const window_id = try self.allocator.dupe(u8, found.window.id);
        errdefer self.allocator.free(window_id);
        const pane_id = try self.allocator.dupe(u8, found.pane.id);
        errdefer self.allocator.free(pane_id);
        const client = try self.allocator.create(Client);
        errdefer self.allocator.destroy(client);
        client.* = .{
            .id = client_id,
            .session_id = session_id,
            .window_id = window_id,
            .pane_id = pane_id,
            .rows = rows,
            .cols = cols,
        };
        var snapshot = try ClientSnapshot.fromClient(self.allocator, client);
        errdefer snapshot.deinit(self.allocator);
        try applyPaneSize(found.pane, rows, cols);

        self.clients.appendAssumeCapacity(client);
        self.clients_by_id.putAssumeCapacity(client.id, client);
        return snapshot;
    }

    /// Resize the native when it runs, then record the size in the spec.
    fn applyPaneSize(pane: *Pane, rows: u16, cols: u16) !void {
        if (pane.native.isRunning()) {
            pane.native.resize(cols, rows) catch |err| switch (err) {
                // Exited between the check and the ioctl: same as not running.
                error.SessionTerminated => {},
                else => |other| return other,
            };
        }
        pane.spawn.rows = rows;
        pane.spawn.cols = cols;
    }

    fn retainPaneNative(self: *Manager, pane_id: []const u8) !*NativeSession {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const pane = self.findPaneLocked(pane_id) orelse return error.PaneNotFound;
        pane.native.retain();
        return pane.native;
    }

    fn retainAllNativesLocked(self: *Manager) ![]*NativeSession {
        const natives = try self.allocator.alloc(*NativeSession, self.paneSlotCountLocked());
        var used: usize = 0;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    pane.native.retain();
                    natives[used] = pane.native;
                    used += 1;
                }
            }
        }
        return natives;
    }

    fn checkPaneLimitsLocked(self: *Manager, scrollback_bytes: usize) !void {
        var panes: usize = 0;
        var scrollback: usize = 0;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    panes += 1;
                    scrollback +|= pane.spawn.scrollback_bytes;
                }
            }
        }
        if (panes >= self.limits.max_panes) return error.LimitExceeded;
        const total = std.math.add(usize, scrollback, scrollback_bytes) catch return error.LimitExceeded;
        if (total > self.limits.max_total_scrollback_bytes) return error.LimitExceeded;
    }

    /// A session name must be valid text, must not equal any existing id
    /// (ids always win lookups, so the name would be unreachable), and must
    /// be unique. `exclude` is the session being renamed.
    fn validateSessionNameLocked(self: *Manager, name: []const u8, exclude: ?*Session) !void {
        try validateNameText(name);
        if (self.idExistsLocked(name, exclude)) return error.NameShadowsId;
        for (self.sessions.items) |session| {
            if (session == exclude) continue;
            if (std.mem.eql(u8, session.name, name)) return error.DuplicateSessionName;
        }
    }

    /// True when `text` equals a session, window, or pane id. The id of
    /// `exclude` itself does not count.
    fn idExistsLocked(self: *Manager, text: []const u8, exclude: ?*Session) bool {
        for (self.sessions.items) |session| {
            if (session != exclude and std.mem.eql(u8, session.id, text)) return true;
            for (session.windows.items) |window| {
                if (std.mem.eql(u8, window.id, text)) return true;
                for (window.panes.items) |pane| {
                    if (std.mem.eql(u8, pane.id, text)) return true;
                }
            }
        }
        return false;
    }

    fn nextIdLocked(self: *Manager, prefix: []const u8, next: *usize) ![]u8 {
        next.* += 1;
        return std.fmt.allocPrint(self.allocator, "{s}-{d}-{x}", .{ prefix, next.*, std.Io.Clock.real.now(self.io).nanoseconds });
    }

    /// Exact id first, then name, so an id always wins.
    fn findSessionLocked(self: *Manager, id: []const u8) ?*Session {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.id, id)) return session;
        }
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.name, id)) return session;
        }
        return null;
    }

    /// Exact id first, then name. Window names are only unique per session,
    /// so a name lookup returns the first match.
    fn findWindowWithParentLocked(self: *Manager, id: []const u8) ?WindowRef {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                if (std.mem.eql(u8, window.id, id)) return .{ .session = session, .window = window };
            }
        }
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                if (std.mem.eql(u8, window.name, id)) return .{ .session = session, .window = window };
            }
        }
        return null;
    }

    fn findPaneWithParentsLocked(self: *Manager, id: []const u8) ?PaneRef {
        return self.panes_by_id.get(id);
    }

    // Resolve a target identifier to a pane. Tries pane id first, then
    // session id, then session name (resolving to that session's active
    // window and active pane). This lets clients attach by a tmux-style name
    // like "work" without having to remember the auto-generated pane id.
    fn resolveTargetPaneLocked(self: *Manager, id: []const u8) ?PaneRef {
        if (self.findPaneWithParentsLocked(id)) |hit| return hit;

        const session = self.findSessionLocked(id) orelse return null;
        for (session.windows.items) |window| {
            if (!std.mem.eql(u8, window.id, session.active_window_id)) continue;
            const hit = self.panes_by_id.get(window.active_pane_id) orelse return null;
            return if (hit.window == window) hit else null;
        }
        return null;
    }

    fn resolveTargetSessionLocked(self: *Manager, id: []const u8) ?*Session {
        if (self.findPaneWithParentsLocked(id)) |hit| return hit.session;
        return self.findSessionLocked(id);
    }

    fn findPaneLocked(self: *Manager, id: []const u8) ?*Pane {
        const found = self.findPaneWithParentsLocked(id) orelse return null;
        return found.pane;
    }

    fn findClientLocked(self: *Manager, id: []const u8) ?*Client {
        return self.clients_by_id.get(id);
    }

    fn paneSlotCountLocked(self: *Manager) usize {
        return self.panes_by_id.count();
    }

    /// Never allocates: `detached_clients` capacity is reserved at attach.
    fn removeClientAtLocked(self: *Manager, index: usize, reason: ?DetachReason) void {
        const client = self.clients.orderedRemove(index);
        _ = self.clients_by_id.remove(client.id);
        if (reason) |why| {
            if (self.detached_clients.items.len < self.detached_clients.capacity) {
                self.detached_clients.appendAssumeCapacity(.{ .client_id = client.id, .reason = why });
                client.deinitKeepId(self.allocator);
                return;
            }
        }
        client.deinit(self.allocator);
    }

    const ClientLink = enum { session, pane };

    fn detachClientsLocked(self: *Manager, link: ClientLink, id: []const u8, reason: DetachReason) void {
        var index: usize = 0;
        while (index < self.clients.items.len) {
            const client = self.clients.items[index];
            const value = switch (link) {
                .session => client.session_id,
                .pane => client.pane_id,
            };
            if (std.mem.eql(u8, value, id)) {
                self.removeClientAtLocked(index, reason);
            } else {
                index += 1;
            }
        }
    }

    /// Never fails. Prunes clients of the session.
    fn takeSessionLocked(self: *Manager, session: *Session) RemovedItems {
        const index = std.mem.indexOfScalar(*Session, self.sessions.items, session) orelse return .{};
        self.detachClientsLocked(.session, session.id, .session_removed);
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| _ = self.panes_by_id.remove(pane.id);
        }
        return .{ .session = self.sessions.swapRemove(index) };
    }

    /// Removes one pane, and its window when that was the window's last pane.
    /// Allocates the successor active ids first, so OutOfMemory changes
    /// nothing. Prunes clients of the pane. The caller handles the
    /// last-pane-of-last-window case with `takeSessionLocked`.
    fn takePaneLocked(self: *Manager, found: PaneRef) !RemovedItems {
        const session = found.session;
        const window = found.window;
        const index = std.mem.indexOfScalar(*Pane, window.panes.items, found.pane) orelse return .{};
        const removes_window = window.panes.items.len == 1;
        std.debug.assert(!removes_window or session.windows.items.len > 1);

        var new_active_pane: ?[]u8 = null;
        errdefer if (new_active_pane) |value| self.allocator.free(value);
        if (!removes_window and std.mem.eql(u8, window.active_pane_id, found.pane.id)) {
            const successor = window.panes.items[if (index == 0) 1 else 0];
            new_active_pane = try self.allocator.dupe(u8, successor.id);
        }
        var new_active_window: ?[]u8 = null;
        if (removes_window and std.mem.eql(u8, session.active_window_id, window.id)) {
            const successor = for (session.windows.items) |candidate| {
                if (candidate != window) break candidate;
            } else unreachable;
            new_active_window = try self.allocator.dupe(u8, successor.id);
        }

        // Commit: nothing below can fail.
        self.detachClientsLocked(.pane, found.pane.id, .pane_removed);
        const removed = window.panes.swapRemove(index);
        _ = self.panes_by_id.remove(removed.id);
        _ = window.layout.removeLeaf(self.allocator, removed.id);
        if (new_active_pane) |value| {
            self.allocator.free(window.active_pane_id);
            window.active_pane_id = value;
        }
        if (!removes_window) return .{ .pane = removed };

        const window_index = std.mem.indexOfScalar(*Window, session.windows.items, window).?;
        const removed_window = session.windows.swapRemove(window_index);
        if (new_active_window) |value| {
            self.allocator.free(session.active_window_id);
            session.active_window_id = value;
        }
        return .{ .window = removed_window, .pane = removed };
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
                "{{\"id\":{f},\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f},\"rows\":{},\"cols\":{},\"active\":true}}",
                .{
                    std.json.fmt(client.id, .{}),
                    std.json.fmt(client.session_id, .{}),
                    std.json.fmt(client.window_id, .{}),
                    std.json.fmt(client.pane_id, .{}),
                    client.rows,
                    client.cols,
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
        "{{\"id\":{f},\"windowId\":{f},\"sessionId\":{f},\"index\":{},\"title\":{f},\"hasCustomTitle\":{},\"state\":{f},\"generation\":{},\"pid\":{},\"rows\":{},\"cols\":{},\"cwd\":",
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

/// Names are non-empty and contain no NUL byte.
fn validateNameText(name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
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

fn createNewWindowAndSplitForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const opts: CreateOptions = .{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    };
    var first = try manager.createSessionPane(opts);
    defer first.deinit();
    discardHandle(try manager.newWindow(first.session_id, opts));
    discardHandle(try manager.splitPane(first.pane_id, .horizontal, opts));
}

fn attachClientForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    });

    defer pane.deinit();
    var client = try manager.attachClient(pane.pane_id, 30, 100);
    defer client.deinit(allocator);
}

fn respawnPaneForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "cat",
        .scrollback_bytes = 4096,
    });

    defer pane.deinit();
    const pane_id = try allocator.dupe(u8, pane.pane_id);
    defer allocator.free(pane_id);

    const native = try manager.respawnPane(pane_id, .{ .kill = true });
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

test "mux manager splits panes and records layout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first_id, second.pane_id));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"axis\":\"horizontal\"") != null);
}

test "removing a nested pane keeps the surviving sibling subtree in layout" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    const second_id = try std.testing.allocator.dupe(u8, second.pane_id);
    defer std.testing.allocator.free(second_id);
    var third = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    defer third.deinit();
    const third_id = try std.testing.allocator.dupe(u8, third.pane_id);
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

    var fourth = try manager.splitPane(third_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });

    defer fourth.deinit();
    try std.testing.expect(!std.mem.eql(u8, fourth.pane_id, third_id));
}

test "attachClient resolves a session name to its active pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });

    defer pane.deinit();
    const expected_pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
    defer std.testing.allocator.free(expected_pane_id);

    var client = try manager.attachClient("work", 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected_pane_id, client.pane_id);
}

test "attachClient still resolves an explicit pane id" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });

    defer pane.deinit();
    const pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
    defer std.testing.allocator.free(pane_id);

    var client = try manager.attachClient(pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(pane_id, client.pane_id);
}

test "attachClient on an unknown name returns PaneNotFound" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    discardHandle(try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    }));
    try std.testing.expectError(error.PaneNotFound, manager.attachClient("ghost", 24, 80));
}

test "session-targeted APIs resolve pane id session id and session name" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var pane = try manager.createSessionPane(.{
        .title = "work",
        .shell = "/bin/sh",
        .command = "cat",
    });

    defer pane.deinit();
    const pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
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

    var first = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    const session_id = try std.testing.allocator.dupe(u8, first.session_id);
    defer std.testing.allocator.free(session_id);
    discardHandle(try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" }));

    try std.testing.expectEqual(@as(usize, 1), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 2), manager.paneCount());
    try std.testing.expect(manager.terminate(session_id));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 0), manager.paneCount());
}

test "mux key binding executes tmux-like split command" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
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

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
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

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
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

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);

    try std.testing.expectError(error.UnsupportedCommand, manager.executeCommandLine("split-window -x", first_id));
    try std.testing.expectError(error.UnsupportedCommand, manager.executeCommandLine("new-window -x", first_id));
    try std.testing.expectError(error.UnsupportedCommand, manager.executeCommandLine("respawn-pane extra", first_id));
    try std.testing.expectEqual(@as(usize, 1), manager.paneCount());
}

test "switchClient moves a logical client to another pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .vertical, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    const second_id = try std.testing.allocator.dupe(u8, second.pane_id);
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

    var pane = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer pane.deinit();
    var client = try manager.attachClient(pane.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"silence\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"active\":true") != null);
}

test "terminating a split pane collapses layout and keeps the remaining pane" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer first.deinit();
    const first_id = try std.testing.allocator.dupe(u8, first.pane_id);
    defer std.testing.allocator.free(first_id);
    var second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "cat" });
    defer second.deinit();
    const second_id = try std.testing.allocator.dupe(u8, second.pane_id);
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

    var pane = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat" });

    defer pane.deinit();
    const pane_id = try std.testing.allocator.dupe(u8, pane.pane_id);
    defer std.testing.allocator.free(pane_id);

    var client = try manager.attachClient(pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expect(manager.detachClient(client.id));
    try std.testing.expectEqualStrings(pane_id, client.pane_id);
}

test "manager count ignores terminated panes for idle accounting" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    discardHandle(try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" }));

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

// ---- Round-1 review fixes (Track T3) ----

const cat_opts: CreateOptions = .{ .shell = "/bin/sh", .command = "cat", .scrollback_bytes = 4096 };

fn waitForNoLivePanes(manager: *Manager) !void {
    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (std.Io.Clock.awake.now(io).compare(.lt, deadline)) {
        manager.reapExitedPanes();
        if (manager.counts().live_panes == 0) return;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return error.PaneStillLive;
}

fn paneState(manager: *Manager, pane_id: []const u8) !struct { alerts: AlertState, generation: u64, rows: u16, cols: u16 } {
    manager.mutex.lockUncancelable(manager.io);
    defer manager.mutex.unlock(manager.io);
    const pane = manager.findPaneLocked(pane_id) orelse return error.PaneNotFound;
    return .{ .alerts = pane.alerts, .generation = pane.native.generation(), .rows = pane.spawn.rows, .cols = pane.spawn.cols };
}

/// Records `session_exited` generations and forwards them to `manager`, as
/// the server does.
const RecordingSink = struct {
    mutex: std.Io.Mutex = .init,
    manager: ?*Manager = null,
    exited: [64]u64 = undefined,
    exited_len: usize = 0,

    fn sink(self: *RecordingSink) native_mod.EventSink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, event: native_mod.Event) void {
        const self: *RecordingSink = @ptrCast(@alignCast(context));
        switch (event) {
            .session_exited => |params| {
                {
                    self.mutex.lockUncancelable(std.testing.io);
                    defer self.mutex.unlock(std.testing.io);
                    if (self.exited_len < self.exited.len) {
                        self.exited[self.exited_len] = params.generation;
                        self.exited_len += 1;
                    }
                }
                if (self.manager) |manager| manager.markExited(params.session_id, params.generation);
            },
            else => {},
        }
    }

    fn sawExitedGeneration(self: *RecordingSink, generation: u64) bool {
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        return std.mem.indexOfScalar(u64, self.exited[0..self.exited_len], generation) != null;
    }
};

const StressContext = struct {
    manager: *Manager,
    iterations: usize,
    failures: std.atomic.Value(usize) = .init(0),
    creates: std.atomic.Value(usize) = .init(0),

    fn createLoop(self: *StressContext) void {
        for (0..self.iterations) |_| {
            const native = self.manager.create(.{ .title = "w", .shell = "/bin/sh", .command = "cat", .scrollback_bytes = 4096 }) catch |err| {
                if (err != error.DuplicateSessionName) _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };
            _ = self.creates.fetchAdd(1, .seq_cst);
            // Touch the native after create returned: a UAF shows up here.
            if (native.generation() != 0) _ = self.failures.fetchAdd(1, .seq_cst);
            if (native.infoJson(std.testing.allocator)) |info| {
                std.testing.allocator.free(info);
            } else |_| _ = self.failures.fetchAdd(1, .seq_cst);
            native.release();
        }
    }

    fn terminateLoop(self: *StressContext) void {
        for (0..self.iterations) |_| _ = self.manager.terminate("w");
    }
};

test "C1: concurrent create and terminate by name never use a freed native" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var ctx: StressContext = .{ .manager = &manager, .iterations = 300 };
    const creator = try std.Thread.spawn(.{}, StressContext.createLoop, .{&ctx});
    const terminator = try std.Thread.spawn(.{}, StressContext.terminateLoop, .{&ctx});
    creator.join();
    terminator.join();

    try std.testing.expectEqual(@as(usize, 0), ctx.failures.load(.seq_cst));
    try std.testing.expect(ctx.creates.load(.seq_cst) > 0);
    try manager.checkInvariants(std.testing.allocator);
    try std.testing.expect(manager.sessionCount() <= 1);
}

test "PaneHandle deinit releases exactly one native reference" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    const native = handle.native;
    // One reference for the pane, one for the handle.
    try std.testing.expectEqual(@as(u32, 2), native.ref_count.load(.seq_cst));
    handle.deinit();
    try std.testing.expectEqual(@as(u32, 1), native.ref_count.load(.seq_cst));

    const created = try manager.create(cat_opts);
    try std.testing.expectEqual(@as(u32, 2), created.ref_count.load(.seq_cst));
    created.release();
}

const AttachRace = struct {
    manager: *Manager,
    created: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),

    fn run(self: *AttachRace) void {
        var result = self.manager.attachOrCreateClient("work", 24, 80, cat_opts) catch {
            _ = self.failures.fetchAdd(1, .seq_cst);
            return;
        };
        defer result.client.deinit(std.testing.allocator);
        if (result.created) _ = self.created.fetchAdd(1, .seq_cst);
    }
};

test "attachOrCreateClient creates exactly one session under concurrent callers" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var race: AttachRace = .{ .manager = &manager };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, AttachRace.run, .{&race});
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 0), race.failures.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), race.created.load(.seq_cst));
    const totals = manager.counts();
    try std.testing.expectEqual(@as(usize, 1), totals.sessions);
    try std.testing.expectEqual(@as(usize, 1), totals.panes);
    try manager.checkInvariants(std.testing.allocator);

    const list = try manager.listJson(std.testing.allocator);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"sessionName\":\"work\"") != null);
}

test "attachOrCreateClient succeeds on an exited pane and reports exit info" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(.{ .title = "done", .shell = "/bin/sh", .command = "true" });
    defer handle.deinit();
    try waitForNoLivePanes(&manager);

    var result = try manager.attachOrCreateClient("done", 30, 100, null);
    defer result.client.deinit(std.testing.allocator);
    try std.testing.expect(!result.created);
    try std.testing.expect(result.exited);
    try std.testing.expectEqual(@as(?u32, 0), result.exit.?.exit_code);
    try std.testing.expectEqual(@as(u64, 0), result.generation);
    try std.testing.expectEqualStrings(handle.pane_id, result.client.pane_id);

    // Plain attach and switch also skip the resize on an exited pane.
    var plain = try manager.attachClient(handle.pane_id, 40, 120);
    defer plain.deinit(std.testing.allocator);
    try manager.switchClient(plain.id, handle.pane_id);
    try std.testing.expectEqual(@as(u16, 40), (try paneState(&manager, handle.pane_id)).rows);
}

test "attachOrCreateClient without create options does not create" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    try std.testing.expectError(error.PaneNotFound, manager.attachOrCreateClient("ghost", 24, 80, null));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectError(error.InvalidName, manager.attachOrCreateClient("", 24, 80, cat_opts));
    try std.testing.expectEqual(@as(usize, 0), manager.spawn_count);
}

test "attachOrCreateClient rolls back the new session when attach fails" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    manager.limits.max_clients = 0;

    try std.testing.expectError(error.LimitExceeded, manager.attachOrCreateClient("work", 24, 80, cat_opts));
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expectEqual(@as(usize, 0), manager.spawn_count);
}

test "session names reject duplicates, id shadowing, and invalid text" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var work = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });
    defer work.deinit();
    var other = try manager.createSessionPane(cat_opts);
    defer other.deinit();
    const spawned = manager.spawn_count;

    try std.testing.expectError(error.DuplicateSessionName, manager.createSessionPane(.{ .title = "work", .command = "cat" }));
    try std.testing.expectError(error.NameShadowsId, manager.createSessionPane(.{ .title = other.session_id, .command = "cat" }));
    try std.testing.expectError(error.NameShadowsId, manager.createSessionPane(.{ .title = work.pane_id, .command = "cat" }));
    try std.testing.expectError(error.InvalidName, manager.createSessionPane(.{ .title = "", .command = "cat" }));
    try std.testing.expectError(error.InvalidName, manager.createSessionPane(.{ .title = "a\x00b", .command = "cat" }));
    try std.testing.expectEqual(spawned, manager.spawn_count);

    try std.testing.expectError(error.DuplicateSessionName, manager.renameSession(other.session_id, "work"));
    try std.testing.expectError(error.NameShadowsId, manager.renameSession(other.session_id, work.window_id));
    try std.testing.expectError(error.InvalidName, manager.renameSession(other.session_id, ""));
    try manager.renameSession("work", "work");
    try manager.renameSession(other.session_id, "play");
    try std.testing.expectError(error.InvalidName, manager.renameWindow(work.window_id, ""));
    try std.testing.expectError(error.InvalidName, manager.renamePane(work.pane_id, "x\x00", true));
    try manager.checkInvariants(std.testing.allocator);
}

test "terminate by id removes the intended session after a swapRemove" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var a = try manager.createSessionPane(.{ .title = "a", .shell = "/bin/sh", .command = "cat" });
    defer a.deinit();
    var b = try manager.createSessionPane(.{ .title = "b", .shell = "/bin/sh", .command = "cat" });
    defer b.deinit();
    var c = try manager.createSessionPane(.{ .title = "c", .shell = "/bin/sh", .command = "cat" });
    defer c.deinit();

    try std.testing.expect(manager.terminate(a.session_id));
    try std.testing.expect(manager.terminate(c.session_id));
    try std.testing.expect(!manager.terminate(c.session_id));
    const remaining = manager.find("b") orelse return error.MissingSession;
    defer remaining.release();
    try std.testing.expectEqualStrings(b.pane_id, remaining.id);
    try std.testing.expectEqual(@as(usize, 1), manager.sessionCount());
}

test "respawn without kill rejects a running pane; kill drops old-generation exit events" {
    var recorder: RecordingSink = .{};
    var manager = Manager.init(std.testing.allocator, std.testing.io, recorder.sink());
    defer manager.deinit();
    recorder.manager = &manager;

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();

    try std.testing.expectError(error.PaneRunning, manager.respawnPane(handle.pane_id, .{}));
    try std.testing.expectEqual(@as(u64, 0), (try paneState(&manager, handle.pane_id)).generation);

    const fresh = try manager.respawnPane(handle.pane_id, .{ .kill = true });
    defer fresh.release();
    try std.testing.expectEqual(@as(u64, 1), fresh.generation());
    try std.testing.expect(fresh.isRunning());

    std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    try std.testing.expect(!recorder.sawExitedGeneration(0));
    const state = try paneState(&manager, handle.pane_id);
    try std.testing.expectEqual(@as(u64, 1), state.generation);
    try std.testing.expect(!state.alerts.exited);
}

test "respawn keeps the new generation's exited alert set during old teardown" {
    var recorder: RecordingSink = .{};
    var manager = Manager.init(std.testing.allocator, std.testing.io, recorder.sink());
    defer manager.deinit();
    recorder.manager = &manager;

    var handle = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" });
    defer handle.deinit();
    try waitForNoLivePanes(&manager);

    const fresh = try manager.respawnPane(handle.pane_id, .{});
    defer fresh.release();
    try std.testing.expectEqual(@as(u64, 1), fresh.generation());
    try waitForNoLivePanes(&manager);

    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(3));
    while (!(try paneState(&manager, handle.pane_id)).alerts.exited) {
        if (std.Io.Clock.awake.now(io).compare(.gt, deadline)) return error.ExitedAlertLost;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(recorder.sawExitedGeneration(1));
}

test "mark functions ignore stale generations and keep the event timestamp" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    const fresh = try manager.respawnPane(handle.pane_id, .{ .kill = true });
    fresh.release();

    manager.markActivity(handle.pane_id, 0, 111);
    manager.markBell(handle.pane_id, 0, 222);
    manager.markExited(handle.pane_id, 0);
    var state = try paneState(&manager, handle.pane_id);
    try std.testing.expect(!state.alerts.activity);
    try std.testing.expect(!state.alerts.bell);
    try std.testing.expect(!state.alerts.exited);

    manager.markActivity(handle.pane_id, 1, 333);
    manager.markBell(handle.pane_id, 1, 444);
    manager.markExited(handle.pane_id, 1);
    state = try paneState(&manager, handle.pane_id);
    try std.testing.expectEqual(@as(i64, 333), state.alerts.last_activity_ms);
    try std.testing.expectEqual(@as(i64, 444), state.alerts.last_bell_ms);
    try std.testing.expect(state.alerts.exited);

    // markExited takes a pane id; a session name must not match.
    manager.markExited(handle.session_id, 1);
}

test "limits reject panes, clients, bindings, scrollback, and depth before any spawn" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    manager.limits = .{ .max_panes = 2, .max_clients = 1, .max_bindings = 1, .max_total_scrollback_bytes = 3 * 4096, .max_layout_depth = 32 };

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    discardHandle(try manager.splitPane(first.pane_id, .vertical, cat_opts));
    const spawned = manager.spawn_count;
    try std.testing.expectEqual(@as(usize, 2), spawned);
    try std.testing.expectError(error.LimitExceeded, manager.createSessionPane(cat_opts));
    try std.testing.expectError(error.LimitExceeded, manager.newWindow(first.session_id, cat_opts));
    try std.testing.expectError(error.LimitExceeded, manager.splitPane(first.pane_id, .vertical, cat_opts));
    try std.testing.expectEqual(spawned, manager.spawn_count);

    manager.limits.max_panes = 10;
    try std.testing.expectError(error.LimitExceeded, manager.createSessionPane(.{ .command = "cat", .scrollback_bytes = 8192 }));
    try std.testing.expectEqual(spawned, manager.spawn_count);

    var client = try manager.attachClient(first.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try std.testing.expectError(error.LimitExceeded, manager.attachClient(first.pane_id, 24, 80));

    try manager.bindKey("prefix", "%", "split-window -h", false);
    try manager.bindKey("prefix", "%", "split-window -v", true);
    try std.testing.expectError(error.LimitExceeded, manager.bindKey("prefix", "c", "new-window", false));
    try manager.checkInvariants(std.testing.allocator);
}

test "split enforces max_layout_depth" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();
    manager.limits.max_layout_depth = 3;

    var root = try manager.createSessionPane(cat_opts);
    defer root.deinit();
    var target = try std.testing.allocator.dupe(u8, root.pane_id);
    defer std.testing.allocator.free(target);
    for (0..3) |_| {
        var next = try manager.splitPane(target, .vertical, cat_opts);
        defer next.deinit();
        std.testing.allocator.free(target);
        target = try std.testing.allocator.dupe(u8, next.pane_id);
    }
    const spawned = manager.spawn_count;
    try std.testing.expectError(error.LimitExceeded, manager.splitPane(target, .vertical, cat_opts));
    try std.testing.expectEqual(spawned, manager.spawn_count);
    // A shallower leaf can still split.
    discardHandle(try manager.splitPane(root.pane_id, .horizontal, cat_opts));
    try manager.checkInvariants(std.testing.allocator);
}

test "removing panes and sessions prunes clients into takeDetachedClients" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var second = try manager.splitPane(first.pane_id, .vertical, cat_opts);
    defer second.deinit();
    var on_first = try manager.attachClient(first.pane_id, 24, 80);
    defer on_first.deinit(std.testing.allocator);
    var on_second = try manager.attachClient(second.pane_id, 24, 80);
    defer on_second.deinit(std.testing.allocator);
    var remote = try manager.attachClient(first.pane_id, 24, 80);
    defer remote.deinit(std.testing.allocator);

    try std.testing.expect(manager.terminate(second.pane_id));
    try manager.checkInvariants(std.testing.allocator);
    {
        const detached = try manager.takeDetachedClients(std.testing.allocator);
        defer freeDetachedClients(std.testing.allocator, detached);
        try std.testing.expectEqual(@as(usize, 1), detached.len);
        try std.testing.expectEqualStrings(on_second.id, detached[0].client_id);
        try std.testing.expectEqual(DetachReason.pane_removed, detached[0].reason);
    }

    try std.testing.expect(manager.detachClientRemote(remote.id));
    try std.testing.expect(!manager.detachClientRemote(remote.id));
    try std.testing.expect(manager.terminate(first.session_id));
    const clients = try manager.clientsJson(std.testing.allocator);
    defer std.testing.allocator.free(clients);
    try std.testing.expectEqualStrings("[]", clients);

    const detached = try manager.takeDetachedClients(std.testing.allocator);
    defer freeDetachedClients(std.testing.allocator, detached);
    try std.testing.expectEqual(@as(usize, 2), detached.len);
    try std.testing.expectEqualStrings(remote.id, detached[0].client_id);
    try std.testing.expectEqual(DetachReason.remote_detach, detached[0].reason);
    try std.testing.expectEqualStrings(on_first.id, detached[1].client_id);
    try std.testing.expectEqual(DetachReason.session_removed, detached[1].reason);

    const empty = try manager.takeDetachedClients(std.testing.allocator);
    defer freeDetachedClients(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "terminateAll prunes clients with session_removed" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    var client = try manager.attachClient(handle.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    manager.terminateAll();

    const detached = try manager.takeDetachedClients(std.testing.allocator);
    defer freeDetachedClients(std.testing.allocator, detached);
    try std.testing.expectEqual(@as(usize, 1), detached.len);
    try std.testing.expectEqual(DetachReason.session_removed, detached[0].reason);
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
}

test "checkInvariants catches a dangling client" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    var client = try manager.attachClient(handle.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);
    try manager.checkInvariants(std.testing.allocator);

    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        try replaceOwnedString(manager.allocator, &manager.clients.items[0].pane_id, "pane-ghost");
    }
    try std.testing.expectError(error.DanglingClient, manager.checkInvariants(std.testing.allocator));
    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        try replaceOwnedString(manager.allocator, &manager.clients.items[0].pane_id, handle.pane_id);
    }
    try manager.checkInvariants(std.testing.allocator);
}

test "resizePane updates the spec, attached clients, and respawn geometry" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    var client = try manager.attachClient(handle.pane_id, 24, 80);
    defer client.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidDimensions, manager.resizePane(handle.pane_id, 0, 80));
    try std.testing.expectError(error.PaneNotFound, manager.resizePane("pane-ghost", 50, 200));
    try manager.resizePane(handle.pane_id, 50, 200);
    const fresh = try manager.respawnPane(handle.pane_id, .{ .kill = true });
    fresh.release();

    const state = try paneState(&manager, handle.pane_id);
    try std.testing.expectEqual(@as(u16, 50), state.rows);
    try std.testing.expectEqual(@as(u16, 200), state.cols);
    const clients = try manager.clientsJson(std.testing.allocator);
    defer std.testing.allocator.free(clients);
    try std.testing.expect(std.mem.indexOf(u8, clients, "\"rows\":50,\"cols\":200") != null);
}

test "parseCommandLine keeps quoted mux words and a byte-exact shell tail" {
    const allocator = std.testing.allocator;
    {
        var parsed = try Manager.parseCommandLine(allocator, "new-window -n \"my logs\" -- echo \"a   b\"");
        defer parsed.deinit(allocator);
        try std.testing.expectEqualStrings("my logs", parsed.new_window.title.?);
        try std.testing.expectEqualStrings("echo \"a   b\"", parsed.new_window.command.?);
    }
    {
        var parsed = try Manager.parseCommandLine(allocator, "split-window\t-h\techo  'x  y'\t");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(Axis.horizontal, parsed.split_window.axis);
        try std.testing.expectEqualStrings("echo  'x  y'", parsed.split_window.command.?);
    }
    {
        var parsed = try Manager.parseCommandLine(allocator, "splitw -- -h");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(Axis.vertical, parsed.split_window.axis);
        try std.testing.expectEqualStrings("-h", parsed.split_window.command.?);
    }
    {
        var parsed = try Manager.parseCommandLine(allocator, "neww -n 'it''s' ");
        defer parsed.deinit(allocator);
        try std.testing.expectEqualStrings("its", parsed.new_window.title.?);
        try std.testing.expect(parsed.new_window.command == null);
    }
    {
        var parsed = try Manager.parseCommandLine(allocator, "  \t ");
        defer parsed.deinit(allocator);
        try std.testing.expect(parsed == .noop);
    }
    try std.testing.expectError(error.UnsupportedCommand, Manager.parseCommandLine(allocator, "new-window -n \"open"));
    try std.testing.expectError(error.UnsupportedCommand, Manager.parseCommandLine(allocator, "new-window -n"));
    try std.testing.expectError(error.UnsupportedCommand, Manager.parseCommandLine(allocator, "split-window -n x"));
    try std.testing.expectError(error.UnsupportedCommand, Manager.parseCommandLine(allocator, "bogus-cmd"));
}

test "parseCommandLine never leaks on allocation failure" {
    const Runner = struct {
        fn run(allocator: Allocator) !void {
            var parsed = try Manager.parseCommandLine(allocator, "new-window -n \"my logs\" -n again -- echo \"a   b\"");
            parsed.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Runner.run, .{});
}

test "command exec new-window inherits the target pane's size and cwd" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat", .cwd = "/tmp", .rows = 33, .cols = 99 });
    defer first.deinit();
    try manager.executeCommandLine("new-window -n \"my logs\" -- echo \"a   b\"", first.pane_id);

    manager.mutex.lockUncancelable(manager.io);
    defer manager.mutex.unlock(manager.io);
    const session = manager.sessions.items[0];
    const found = manager.findWindowWithParentLocked(session.active_window_id) orelse return error.MissingWindow;
    try std.testing.expectEqualStrings("my logs", found.window.name);
    const pane = found.window.panes.items[0];
    try std.testing.expectEqualStrings("echo \"a   b\"", pane.spawn.command.?);
    try std.testing.expectEqualStrings("/tmp", pane.spawn.cwd.?);
    try std.testing.expectEqual(@as(u16, 33), pane.spawn.rows);
    try std.testing.expectEqual(@as(u16, 99), pane.spawn.cols);
}

test "bindKey rejects commands it cannot run and unbindKey removes bindings" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    try std.testing.expectError(error.InvalidParams, manager.bindKey("prefix", "x", "bogus-cmd", false));
    try std.testing.expectError(error.InvalidParams, manager.bindKey("prefix", "x", "split-window -z", false));
    try std.testing.expectError(error.InvalidParams, manager.bindKey("prefix", "x", "   ", false));
    try std.testing.expectError(error.InvalidParams, manager.bindKey("prefix", "", "new-window", false));
    try manager.bindKey("prefix", "c", "new-window -n 'two words'", true);
    try std.testing.expect(manager.unbindKey("prefix", "c"));
    try std.testing.expect(!manager.unbindKey("prefix", "c"));
    const keys = try manager.keysJson(std.testing.allocator);
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualStrings("[]", keys);
}

test "renamePane updates the native title so list, info, and snapshot agree" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(.{ .title = "work", .shell = "/bin/sh", .command = "cat" });
    defer handle.deinit();
    try manager.renamePane(handle.pane_id, "editor", true);

    const info = try handle.native.infoJson(std.testing.allocator);
    defer std.testing.allocator.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "\"title\":\"editor\"") != null);
    const list = try manager.listJson(std.testing.allocator);
    defer std.testing.allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"sessionName\":\"work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"paneTitle\":\"editor\"") != null);
    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"title\":\"editor\"") != null);
}

test "reapExitedPanes visits only live panes" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    for (0..3) |_| discardHandle(try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" }));
    try waitForNoLivePanes(&manager);
    discardHandle(try manager.createSessionPane(cat_opts));
    try std.testing.expectEqual(@as(usize, 1), manager.reapExitedPanesCounted());
    const totals = manager.counts();
    try std.testing.expectEqual(@as(usize, 4), totals.sessions);
    try std.testing.expectEqual(@as(usize, 4), totals.panes);
    try std.testing.expectEqual(@as(usize, 1), totals.live_panes);
}

test "terminateAll shares one deadline across panes that ignore SIGTERM" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    for (0..20) |_| discardHandle(try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "trap '' TERM; sleep 100", .scrollback_bytes = 4096 }));
    const io = std.testing.io;
    io.sleep(.fromMilliseconds(300), .awake) catch {};

    const start = std.Io.Clock.awake.now(io);
    manager.terminateAll();
    const elapsed_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
    try std.testing.expect(elapsed_ms < 1000);
}

test "interruptInput, setEventSink, and clearEventSinks reach existing panes" {
    var recorder: RecordingSink = .{};
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(cat_opts);
    defer handle.deinit();
    try std.testing.expect(handle.native.event_sink == null);
    manager.setEventSink(recorder.sink());
    try std.testing.expect(handle.native.event_sink != null);
    manager.clearEventSinks();
    try std.testing.expect(handle.native.event_sink == null);
    try std.testing.expect(manager.event_sink == null);

    manager.interruptInput();
    try std.testing.expectError(error.InputClosed, handle.native.send("x", false));
}

/// A sink shaped like the server's: every event takes the manager mutex.
const LockingSink = struct {
    manager: *Manager,
    events: std.atomic.Value(usize) = .init(0),

    fn sink(self: *LockingSink) native_mod.EventSink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, event: native_mod.Event) void {
        const self: *LockingSink = @ptrCast(@alignCast(context));
        _ = self.events.fetchAdd(1, .seq_cst);
        switch (event) {
            .pane_output => |out| self.manager.markActivity(out.pane_id, out.generation, 1),
            .session_exited => |exit| self.manager.markExited(exit.session_id, exit.generation),
            else => _ = self.manager.counts(),
        }
    }
};

test "sink removal never waits for an emit while holding the manager mutex" {
    // Regression: clearing a native sink blocks until in-flight emits return,
    // and the server's sink takes the manager mutex. Every removal path
    // (respawn, terminate, setEventSink(null), clearEventSinks, terminateAll)
    // must therefore clear outside that mutex. A deadlock hangs this test.
    const io = std.testing.io;
    var manager = Manager.init(std.testing.allocator, io, null);
    defer manager.deinit();
    var locking: LockingSink = .{ .manager = &manager };

    const flood: CreateOptions = .{ .shell = "/bin/sh", .command = "while :; do echo flood; done", .scrollback_bytes = 4096 };
    for (0..6) |round| {
        manager.setEventSink(locking.sink());
        var first = try manager.createSessionPane(flood);
        defer first.deinit();
        var second = try manager.splitPane(first.pane_id, .vertical, flood);
        defer second.deinit();

        // Let both readers get into the sink.
        const seen = locking.events.load(.seq_cst);
        const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
        while (locking.events.load(.seq_cst) < seen + 20) {
            if (std.Io.Clock.awake.now(io).compare(.gt, deadline)) return error.MissingEvents;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }

        const respawned = try manager.respawnPane(first.pane_id, .{ .kill = true });
        respawned.release();
        try std.testing.expect(manager.terminate(second.pane_id));
        switch (round % 3) {
            0 => manager.setEventSink(null),
            1 => manager.clearEventSinks(),
            else => {},
        }
        manager.terminateAll();
    }
}

/// Allocator that fails every allocation once `fail` is set. Thread-safe as
/// long as `child` is.
const ToggleFailAllocator = struct {
    child: Allocator,
    fail: std.atomic.Value(bool) = .init(false),

    fn allocator(self: *ToggleFailAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *ToggleFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail.load(.seq_cst)) return null;
        return self.child.rawAlloc(len, alignment, ret);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *ToggleFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail.load(.seq_cst) and new_len > memory.len) return false;
        return self.child.rawResize(memory, alignment, new_len, ret);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *ToggleFailAllocator = @ptrCast(@alignCast(ctx));
        if (self.fail.load(.seq_cst)) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *ToggleFailAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret);
    }
};

/// Parks the first callback until `release` is set, and counts callbacks
/// that start after `cleared` is set (each one would touch a freed context).
const HeldSink = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    cleared: std.atomic.Value(bool) = .init(false),
    late_calls: std.atomic.Value(usize) = .init(0),

    fn sink(self: *HeldSink) native_mod.EventSink {
        return .{ .context = self, .emit = emit };
    }

    fn emit(context: *anyopaque, event: native_mod.Event) void {
        _ = event;
        const self: *HeldSink = @ptrCast(@alignCast(context));
        if (self.cleared.load(.seq_cst)) _ = self.late_calls.fetchAdd(1, .seq_cst);
        if (!self.entered.swap(true, .seq_cst)) {
            while (!self.release.load(.seq_cst)) std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    fn clearThread(manager: *Manager, done: *std.atomic.Value(bool)) void {
        manager.clearEventSinks();
        done.store(true, .seq_cst);
    }
};

test "C01: clearEventSinks waits for a held callback under OOM, and a removed pane's retained handle never calls the sink" {
    const io = std.testing.io;
    var failing: ToggleFailAllocator = .{ .child = std.testing.allocator };
    var manager = Manager.init(failing.allocator(), io, null);
    defer manager.deinit();
    var held: HeldSink = .{};
    manager.setEventSink(held.sink());

    // A removed pane whose public handle outlives removal: its native must
    // lose the sink at removal, before the manager forgets it.
    var removed = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "cat", .scrollback_bytes = 4096 });
    defer removed.deinit();
    var kept = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "printf go; cat", .scrollback_bytes = 4096 });
    defer kept.deinit();

    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (!held.entered.load(.seq_cst)) {
        if (std.Io.Clock.awake.now(io).compare(.gt, deadline)) return error.MissingEvents;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }

    try std.testing.expect(removed.native.event_sink != null);
    try std.testing.expect(manager.terminate(removed.pane_id));
    try std.testing.expect(removed.native.event_sink == null);

    // Every allocation fails from here: the barrier must still hold.
    failing.fail.store(true, .seq_cst);
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, HeldSink.clearThread, .{ &manager, &done });
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    // The held callback is still running, so the clear has not returned.
    try std.testing.expect(!done.load(.seq_cst));
    held.release.store(true, .seq_cst);
    thread.join();
    failing.fail.store(false, .seq_cst);
    try std.testing.expect(done.load(.seq_cst));
    held.cleared.store(true, .seq_cst);

    // New output on the surviving pane never reaches the cleared sink.
    try kept.native.send("more", true);
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 0), held.late_calls.load(.seq_cst));
}

/// Checks the respawn event order: no event of a generation before its
/// announcement, and no event of an older generation after it.
const OrderSink = struct {
    announced: std.atomic.Value(u64) = .init(0),
    announcements: std.atomic.Value(usize) = .init(0),
    violations: std.atomic.Value(usize) = .init(0),

    fn sink(self: *OrderSink) native_mod.EventSink {
        return .{ .context = self, .emit = emit };
    }

    fn listener(self: *OrderSink) RespawnListener {
        return .{ .context = self, .notify = notify };
    }

    fn emit(context: *anyopaque, event: native_mod.Event) void {
        const self: *OrderSink = @ptrCast(@alignCast(context));
        const key = eventGateKey(event) orelse return;
        if (key.generation != self.announced.load(.seq_cst)) _ = self.violations.fetchAdd(1, .seq_cst);
    }

    fn notify(context: *anyopaque, native: *NativeSession) void {
        const self: *OrderSink = @ptrCast(@alignCast(context));
        self.announced.store(native.generation(), .seq_cst);
        _ = self.announcements.fetchAdd(1, .seq_cst);
        // Widen the window in which the new reader is already emitting.
        std.testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    }
};

test "H09: every respawn path announces once, after old events and before new ones" {
    const io = std.testing.io;
    var manager = Manager.init(std.testing.allocator, io, null);
    defer manager.deinit();
    var order: OrderSink = .{};
    manager.setEventSink(order.sink());
    manager.setRespawnListener(order.listener());

    var handle = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "while :; do echo flood; done", .scrollback_bytes = 4096 });
    defer handle.deinit();
    try manager.bindKey("prefix", "R", "respawn-pane", false);

    for (0..6) |round| {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
        switch (round % 3) {
            0 => (try manager.respawnPane(handle.pane_id, .{ .kill = true })).release(),
            1 => try manager.executeCommandLine("respawn-pane", handle.pane_id),
            else => {
                const command = (try manager.executeBinding("prefix", "R", handle.pane_id)).?;
                std.testing.allocator.free(command);
            },
        }
    }
    io.sleep(.fromMilliseconds(20), .awake) catch {};
    manager.clearEventSinks();
    try std.testing.expectEqual(@as(usize, 6), order.announcements.load(.seq_cst));
    try std.testing.expectEqual(@as(u64, 6), order.announced.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), order.violations.load(.seq_cst));
}

test "paneScrollbackTail returns pane output and rejects unknown panes" {
    var manager = Manager.init(std.testing.allocator, std.testing.io, null);
    defer manager.deinit();

    var handle = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "printf hello; cat" });
    defer handle.deinit();
    try std.testing.expectError(error.PaneNotFound, manager.paneScrollbackTail(std.testing.allocator, "pane-ghost", 64));

    const io = std.testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(3));
    while (true) {
        const tail = try manager.paneScrollbackTail(std.testing.allocator, handle.pane_id, 64);
        defer std.testing.allocator.free(tail.bytes);
        if (std.mem.indexOf(u8, tail.bytes, "hello") != null) break;
        if (std.Io.Clock.awake.now(io).compare(.gt, deadline)) return error.MissingOutput;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
}

fn switchClientForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var second = try manager.splitPane(first.pane_id, .vertical, cat_opts);
    defer second.deinit();
    var client = try manager.attachClient(first.pane_id, 24, 80);
    defer client.deinit(allocator);

    const result = manager.switchClient(client.id, second.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const expected = if (result) |_| second.pane_id else |_| first.pane_id;
        try std.testing.expectEqualStrings(expected, manager.clients.items[0].pane_id);
    }
    try result;
}

fn selectPaneForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var other_window = try manager.newWindow(first.session_id, cat_opts);
    defer other_window.deinit();

    const result = manager.selectPane(first.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const session = manager.sessions.items[0];
        // All or nothing: the active window moves only with the pane.
        const expected = if (result) |_| first.window_id else |_| other_window.window_id;
        try std.testing.expectEqualStrings(expected, session.active_window_id);
    }
    try result;
}

fn terminatePaneForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    var first = try manager.createSessionPane(cat_opts);
    defer first.deinit();
    var second = try manager.splitPane(first.pane_id, .vertical, cat_opts);
    defer second.deinit();
    var lone = try manager.newWindow(first.session_id, cat_opts);
    defer lone.deinit();
    var client = try manager.attachClient(second.pane_id, 24, 80);
    defer client.deinit(allocator);

    // `second` is the active pane; `lone` is the active window.
    const removed_pane = manager.terminate(second.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    if (!removed_pane) return error.OutOfMemory;
    const removed_window = manager.terminate(lone.pane_id);
    try manager.checkInvariants(std.testing.allocator);
    if (!removed_window) return error.OutOfMemory;
    try std.testing.expectEqual(@as(usize, 1), manager.paneCount());
}

fn attachOrCreateForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const result = manager.attachOrCreateClient("work", 24, 80, cat_opts);
    try manager.checkInvariants(std.testing.allocator);
    var attached = result catch |err| {
        try std.testing.expectEqual(@as(usize, 0), manager.sessionCount());
        return err;
    };
    defer attached.client.deinit(allocator);
    try std.testing.expect(attached.created);
}

fn bindKeyForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    try manager.bindKey("prefix", "c", "new-window -n 'a b' -- top", false);
    try manager.bindKey("prefix", "c", "split-window -h", true);
    try std.testing.expect(manager.unbindKey("prefix", "c"));
}

test "switchClient allocation failures leave the client fully on its old pane" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, switchClientForFailureTest, .{});
}

test "selectPane allocation failures commit both selections or neither" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, selectPaneForFailureTest, .{});
}

test "pane and window removal allocation failures keep invariants" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, terminatePaneForFailureTest, .{});
}

test "attachOrCreateClient allocation failures leave no session behind" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, attachOrCreateForFailureTest, .{});
}

test "bindKey allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bindKeyForFailureTest, .{});
}
