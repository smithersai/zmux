//! Mux state: sessions, windows, panes, logical clients, and key bindings,
//! owned by one `Manager`. The implementation lives in `mux/*.zig`; this
//! file defines `Manager` and re-exports the public API.

const std = @import("std");

const buffer = @import("buffer.zig");
const log = @import("log.zig");
const native_mod = @import("native.zig");
const sys = @import("sys.zig");

const types = @import("mux/types.zig");
const layout = @import("mux/layout.zig");
const commands = @import("mux/commands.zig");
const creation = @import("mux/creation.zig");
const lookup = @import("mux/lookup.zig");
const attach = @import("mux/attach.zig");
const removal = @import("mux/removal.zig");
const events = @import("mux/events.zig");
const respawn = @import("mux/respawn.zig");
const json = @import("mux/json.zig");
const invariants = @import("mux/invariants.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const NativeSession = native_mod.NativeSession;
const PaneRef = types.PaneRef;
const RespawnGate = respawn.RespawnGate;

/// Error names the mux contract returns (review §1.10).
pub const ContractError = types.ContractError;

/// Shared deadline `terminateAll` gives every pane after `beginTerminate`.
pub const terminate_all_deadline_ms = types.terminate_all_deadline_ms;

/// Owned identifiers for a pane plus one retained reference to its native
/// session. `deinit` frees the ids and releases the native.
pub const PaneHandle = types.PaneHandle;

/// Result of `Manager.attachOrCreateClient`: the new client, whether the
/// session was created, and the pane's exit state and generation.
pub const AttachResult = types.AttachResult;

/// Options for `Manager.respawnPane`. `kill` replaces a still-running child.
pub const RespawnOptions = types.RespawnOptions;

/// Session, pane, and live-pane totals taken in one critical section.
pub const Counts = types.Counts;

/// Why a client was detached without its owner asking.
pub const DetachReason = types.DetachReason;

/// A detached client id and its reason, as returned by
/// `Manager.takeDetachedClients`.
pub const DetachedClient = types.DetachedClient;

/// Free a slice returned by `Manager.takeDetachedClients`.
pub const freeDetachedClients = types.freeDetachedClients;

/// Resource caps the manager enforces before allocating or spawning.
pub const Limits = types.Limits;

/// Split direction of a layout node.
pub const Axis = layout.Axis;

/// Owned spawn recipe of a pane, kept so `respawnPane` can re-run it.
pub const SpawnSpec = types.SpawnSpec;

/// Borrowed spawn parameters for a new pane. The manager copies what it keeps.
pub const CreateOptions = types.CreateOptions;

/// Binary layout tree of a window: leaves hold pane ids, splits hold two
/// children and an axis.
pub const LayoutNode = layout.LayoutNode;

/// Activity, bell, and exit flags of a pane, with the last event times.
pub const AlertState = types.AlertState;

/// One terminal pane: ids, title, spawn recipe, and its native session.
pub const Pane = types.Pane;

/// A window: its panes, the layout tree over them, and the active pane.
pub const Window = types.Window;

/// A named session: its windows, the active window, and index counters.
pub const Session = types.Session;

/// A logical attachment of one terminal to one pane.
pub const Client = types.Client;

/// Owned copy of a `Client`, safe to use after the manager mutex is released.
pub const ClientSnapshot = types.ClientSnapshot;

/// A key bound to a mux command line within a key table.
pub const KeyBinding = types.KeyBinding;

/// Called once per respawn, after the old generation is quiesced and before
/// the new generation can deliver any event.
pub const RespawnListener = events.RespawnListener;

/// Owns every session, window, pane, client, and key binding. All public
/// methods lock `mutex`; methods named `*Locked` require it held.
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

    pub const create = creation.create;
    pub const createSessionPane = creation.createSessionPane;
    pub const newWindow = creation.newWindow;
    pub const splitPane = creation.splitPane;
    pub const selectPane = lookup.selectPane;
    pub const selectWindow = lookup.selectWindow;
    pub const renameSession = lookup.renameSession;
    pub const renameWindow = lookup.renameWindow;
    pub const renamePane = lookup.renamePane;
    pub const find = lookup.find;
    pub const markActivity = lookup.markActivity;
    pub const markBell = lookup.markBell;
    pub const markExited = lookup.markExited;
    pub const markExitedIfCurrent = lookup.markExitedIfCurrent;
    pub const isCurrentGeneration = lookup.isCurrentGeneration;
    pub const respawnPane = respawn.respawnPane;
    pub const attachClient = attach.attachClient;
    pub const attachOrCreateClient = attach.attachOrCreateClient;
    pub const detachClient = attach.detachClient;
    pub const detachClientRemote = attach.detachClientRemote;
    pub const takeDetachedClients = attach.takeDetachedClients;
    pub const switchClient = attach.switchClient;
    pub const resizePane = attach.resizePane;
    pub const reapExitedPanes = removal.reapExitedPanes;
    pub const paneScrollbackSnapshot = removal.paneScrollbackSnapshot;
    pub const paneScrollbackTail = removal.paneScrollbackTail;
    pub const interruptInput = removal.interruptInput;
    pub const terminate = removal.terminate;
    pub const terminateAll = removal.terminateAll;
    pub const bindKey = commands.bindKey;
    pub const unbindKey = commands.unbindKey;
    pub const executeBinding = commands.executeBinding;
    pub const ParsedCommand = commands.ParsedCommand;
    pub const parseCommandLine = commands.parseCommandLine;
    pub const executeCommandLine = commands.executeCommandLine;
    pub const checkInvariants = invariants.checkInvariants;
    pub const setEventSink = events.setEventSink;
    pub const setRespawnListener = events.setRespawnListener;
    pub const clearEventSinks = events.clearEventSinks;
    pub const listJson = json.listJson;
    pub const snapshotJson = json.snapshotJson;
    pub const clientsJson = json.clientsJson;
    pub const keysJson = json.keysJson;

    pub fn init(allocator: Allocator, io: std.Io, event_sink: ?native_mod.EventSink) Manager {
        return .{ .allocator = allocator, .io = io, .event_sink = event_sink };
    }

    pub fn deinit(self: *Manager) void {
        self.terminateAll();
        assert(self.sessions.items.len == 0);
        assert(self.clients.items.len == 0);
        assert(self.panes_by_id.count() == 0);
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
        assert(result.live_panes <= result.panes);
        assert(result.panes == self.panes_by_id.count());
        return result;
    }
};

/// Fixtures shared by the mux submodule tests. Never used by production
/// code; kept here so every `mux/*.zig` test can reach them.
pub const test_support = struct {
    pub const cat_opts: CreateOptions = .{ .shell = "/bin/sh", .command = "cat", .scrollback_bytes = 4096 };

    pub fn waitForNoLivePanes(manager: *Manager) !void {
        const io = std.testing.io;
        const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
        while (std.Io.Clock.awake.now(io).compare(.lt, deadline)) {
            manager.reapExitedPanes();
            if (manager.counts().live_panes == 0) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.PaneStillLive;
    }

    pub const PaneStateView = struct { alerts: AlertState, generation: u64, rows: u16, cols: u16 };

    pub fn paneState(manager: *Manager, pane_id: []const u8) !PaneStateView {
        manager.mutex.lockUncancelable(manager.io);
        defer manager.mutex.unlock(manager.io);
        const pane = lookup.findPaneLocked(manager, pane_id) orelse return error.PaneNotFound;
        return .{
            .alerts = pane.alerts,
            .generation = pane.native.generation(),
            .rows = pane.spawn.rows,
            .cols = pane.spawn.cols,
        };
    }

    /// Records `session_exited` generations and forwards them to `manager`, as
    /// the server does.
    pub const RecordingSink = struct {
        mutex: std.Io.Mutex = .init,
        manager: ?*Manager = null,
        exited: [64]u64 = undefined,
        exited_len: usize = 0,

        pub fn sink(self: *RecordingSink) native_mod.EventSink {
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

        pub fn sawExitedGeneration(self: *RecordingSink, generation: u64) bool {
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            return std.mem.indexOfScalar(u64, self.exited[0..self.exited_len], generation) != null;
        }
    };
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("mux/types.zig");
    _ = @import("mux/layout.zig");
    _ = @import("mux/commands.zig");
    _ = @import("mux/creation.zig");
    _ = @import("mux/lookup.zig");
    _ = @import("mux/attach.zig");
    _ = @import("mux/removal.zig");
    _ = @import("mux/events.zig");
    _ = @import("mux/respawn.zig");
    _ = @import("mux/json.zig");
    _ = @import("mux/invariants.zig");
}
