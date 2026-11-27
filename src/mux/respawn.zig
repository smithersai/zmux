//! Pane respawn and the generation gates that hold a new generation's
//! events until its announcement is out.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const log = @import("../log.zig");
const events = @import("events.zig");
const lookup = @import("lookup.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const RecordingSink = mux.test_support.RecordingSink;
const RespawnListener = events.RespawnListener;
const RespawnOptions = types.RespawnOptions;
const eventGateKey = events.eventGateKey;
const cat_opts = mux.test_support.cat_opts;
const waitForNoLivePanes = mux.test_support.waitForNoLivePanes;
const paneState = mux.test_support.paneState;

/// A respawned generation whose events wait until its announcement is out.
pub const RespawnGate = struct {
    pane_id: []u8,
    generation: u64,
};

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
        const pane = (lookup.resolveTargetPaneLocked(self, pane_id) orelse return error.PaneNotFound).pane;
        if (!opts.kill and pane.native.finalizedExitInfo() == null) return error.PaneRunning;
        const generation = pane.native.generation() + 1;
        const sink = events.nativeSinkLocked(self);
        if (sink != null) {
            // Before the spawn: the new reader may emit at once.
            try addRespawnGate(self, pane.id, generation);
            gated = true;
        }
        errdefer if (gated) liftRespawnGate(self, pane.id, generation);
        var native_opts = pane.spawn.nativeOptions(pane.id, sink);
        native_opts.title = pane.title;
        native_opts.generation = generation;
        new_native = try NativeSession.create(self.allocator, self.io, native_opts);
        self.spawn_count += 1;
        old_native = pane.native;
        assert(old_native != new_native);
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
    events.announceRespawn(self, new_native);
    if (gated) liftRespawnGate(self, new_native.id, new_native.generation());
    old_native.stopForOwnerRelease();
    old_native.destroy();
    return new_native;
}

/// Caller holds `mutex`. Allocates before the spawn so a failure changes
/// nothing.
pub fn addRespawnGate(self: *Manager, pane_id: []const u8, generation: u64) !void {
    // A respawn always targets a generation after the first.
    assert(generation > 0);
    assert(pane_id.len > 0);
    const owned = try self.allocator.dupe(u8, pane_id);
    errdefer self.allocator.free(owned);
    self.sink_mutex.lockUncancelable(self.io);
    defer self.sink_mutex.unlock(self.io);
    try self.respawn_gates.append(self.allocator, .{ .pane_id = owned, .generation = generation });
}

/// Removes a respawn event gate for `(pane_id, generation)` and wakes parked callbacks.
pub fn liftRespawnGate(self: *Manager, pane_id: []const u8, generation: u64) void {
    assert(pane_id.len > 0);
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

/// Reports whether events for `(pane_id, generation)` are currently gated while `sink_mutex` is held.
pub fn isGatedLocked(self: *Manager, pane_id: []const u8, generation: u64) bool {
    assert(pane_id.len > 0);
    for (self.respawn_gates.items) |gate| {
        if (gate.generation == generation and std.mem.eql(u8, gate.pane_id, pane_id)) return true;
    }
    return false;
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

test "manager respawn allocation failures leave the old pane reachable" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, respawnPaneForFailureTest, .{});
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
        std.testing.io.sleep(.fromMilliseconds(20), .awake) catch |err| {
            log.debug("mux_test_order_sink_sleep_failed", .{ .err = err });
        };
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
