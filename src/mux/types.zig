//! Mux value types: handles, options, the session/window/pane/client tree
//! nodes, and small owned-string helpers.

const std = @import("std");

const buffer = @import("../buffer.zig");
const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const NativeSession = native_mod.NativeSession;
const NativeSessionOptions = native_mod.NativeSessionOptions;
const LayoutNode = layout.LayoutNode;
const Manager = mux.Manager;
const cat_opts = mux.test_support.cat_opts;

/// Error names the mux contract returns (review §1.10).
pub const ContractError = error{
    DuplicateSessionName,
    NameShadowsId,
    InvalidName,
    LimitExceeded,
    PaneRunning,
    InvalidAxis,
};

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
    pub fn initIds(
        allocator: Allocator,
        session_id: []const u8,
        window_id: []const u8,
        pane_id: []const u8,
    ) !PaneHandle {
        assert(session_id.len > 0);
        assert(window_id.len > 0);
        assert(pane_id.len > 0);
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

    pub fn freeIds(self: *PaneHandle) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.window_id);
        self.allocator.free(self.pane_id);
    }

    /// Retains `native`. Must run under the manager mutex, while the pane that
    /// owns `native` is still reachable.
    pub fn adopt(self: *PaneHandle, native: *NativeSession) PaneHandle {
        assert(self.pane_id.len > 0);
        native.retain();
        self.native = native;
        return self.*;
    }
};

/// Drop a handle the caller does not need.
pub fn discardHandle(handle: PaneHandle) void {
    var owned = handle;
    owned.deinit();
}

/// Result of `Manager.attachOrCreateClient`: the new client, whether the
/// session was created, and the pane's exit state and generation.
pub const AttachResult = struct {
    client: ClientSnapshot,
    created: bool,
    exited: bool,
    exit: ?native_mod.ExitInfo,
    generation: u64,
};

/// Options for `Manager.respawnPane`. `kill` replaces a still-running child.
pub const RespawnOptions = struct { kill: bool = false };

/// Session, pane, and live-pane totals taken in one critical section.
pub const Counts = struct { sessions: usize, panes: usize, live_panes: usize };

/// Why a client was detached without its owner asking.
pub const DetachReason = enum { pane_removed, session_removed, remote_detach };

/// A detached client id and its reason, as returned by
/// `Manager.takeDetachedClients`.
pub const DetachedClient = struct { client_id: []u8, reason: DetachReason };

/// Free a slice returned by `Manager.takeDetachedClients`.
pub fn freeDetachedClients(allocator: Allocator, items: []DetachedClient) void {
    for (items) |item| allocator.free(item.client_id);
    allocator.free(items);
}

/// Resource caps the manager enforces before allocating or spawning.
pub const Limits = struct {
    max_panes: usize = 256,
    max_clients: usize = 1024,
    max_bindings: usize = 1024,
    max_total_scrollback_bytes: usize = 1024 * 1024 * 1024,
    max_layout_depth: usize = 32,
};

/// Owned spawn recipe of a pane, kept so `respawnPane` can re-run it.
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

    pub fn nativeOptions(
        self: *const SpawnSpec,
        id: []const u8,
        event_sink: ?native_mod.EventSink,
    ) NativeSessionOptions {
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

/// Borrowed spawn parameters for a new pane. The manager copies what it keeps.
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

/// Activity, bell, and exit flags of a pane, with the last event times.
pub const AlertState = struct {
    activity: bool = false,
    bell: bool = false,
    exited: bool = false,
    last_activity_ms: i64 = 0,
    last_bell_ms: i64 = 0,
};

/// One terminal pane: ids, title, spawn recipe, and its native session.
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

/// A window: its panes, the layout tree over them, and the active pane.
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

/// A named session: its windows, the active window, and index counters.
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
    pub fn deinitKeepId(self: *Client, allocator: Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.window_id);
        allocator.free(self.pane_id);
        allocator.destroy(self);
    }
};

/// Owned copy of a `Client`, safe to use after the manager mutex is released.
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

/// A key bound to a mux command line within a key table.
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

/// Detached mux items queued for teardown outside the manager mutex.
pub const RemovedItems = struct {
    session: ?*Session = null,
    window: ?*Window = null,
    pane: ?*Pane = null,

    /// Tears down natives: call only after releasing the manager mutex.
    pub fn deinit(self: RemovedItems, allocator: Allocator) void {
        if (self.pane) |pane| pane.deinit(allocator);
        if (self.window) |window| window.deinit(allocator);
        if (self.session) |session| session.deinit(allocator);
    }
};

/// Resolved parent chain `(session, window, pane)` for a pane lookup.
pub const PaneRef = struct { session: *Session, window: *Window, pane: *Pane };
/// Resolved parent chain `(session, window)` for a window lookup.
pub const WindowRef = struct { session: *Session, window: *Window };

/// Names are non-empty and contain no NUL byte.
pub fn validateNameText(name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
    assert(name.len > 0);
}

/// Duplicates an optional string slice with `allocator`.
pub fn dupeOpt(allocator: Allocator, value: ?[]const u8) !?[]u8 {
    const out = if (value) |text| try allocator.dupe(u8, text) else null;
    assert((out == null) == (value == null));
    return out;
}

/// Duplicates a slice of string slices with `allocator`.
pub fn dupeStringSlice(allocator: Allocator, entries: []const []const u8) ![][]const u8 {
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
    assert(filled == copy.len);
    return copy;
}

/// Frees a slice of owned strings previously allocated by `dupeStringSlice`.
pub fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

/// Atomically replaces an owned string slot with a duplicate of `value`.
pub fn replaceOwnedString(allocator: Allocator, slot: *[]u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = replacement;
    assert(std.mem.eql(u8, slot.*, value));
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
