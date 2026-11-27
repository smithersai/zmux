//! Event sink plumbing: the manager trampoline every native emits through,
//! sink installation and the allocation-free clear barrier, and respawn
//! announcements.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const log = @import("../log.zig");
const respawn = @import("respawn.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const RecordingSink = mux.test_support.RecordingSink;
const cat_opts = mux.test_support.cat_opts;

/// Called once per respawn, after the old generation is quiesced and before
/// the new generation can deliver any event, from every respawn path (RPC,
/// `executeCommandLine`, `executeBinding`).
pub const RespawnListener = struct {
    context: *anyopaque,
    notify: *const fn (context: *anyopaque, native: *NativeSession) void,
};

/// Manager whose sink the current thread is running inside, so a clear from
/// inside a callback does not wait for itself.
threadlocal var sink_callback_manager: ?*const Manager = null;

/// Pane id and generation of an event, for respawn gating. Null for events
/// that carry no generation.
pub fn eventGateKey(event: native_mod.Event) ?struct { pane_id: []const u8, generation: u64 } {
    return switch (event) {
        .foreground_changed => null,
        .session_exited => |params| .{ .pane_id = params.session_id, .generation = params.generation },
        .pane_output => |params| .{ .pane_id = params.pane_id, .generation = params.generation },
        .pane_activity => |params| .{ .pane_id = params.pane_id, .generation = params.generation },
        .pane_bell => |params| .{ .pane_id = params.pane_id, .generation = params.generation },
    };
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
    const trampoline = nativeSinkLocked(self);
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
    assert(self.sink_in_flight <= (if (reentrant) self.sink_reentrant_waiters else 0));
}

/// The sink natives get: the manager trampoline when a sink is set.
pub fn nativeSinkLocked(self: *Manager) ?native_mod.EventSink {
    if (self.event_sink == null) return null;
    return .{
        .context = self,
        .emit = emitThroughManager,
        .emit_osc = emitOscThroughManager,
    };
}

/// Pane id and generation of an OSC event, for respawn gating.
pub fn oscEventGateKey(event: native_mod.OscEvent) struct { pane_id: []const u8, generation: u64 } {
    return switch (event) {
        .pane_title_changed => |p| .{ .pane_id = p.pane_id, .generation = p.generation },
        .pane_cwd_changed => |p| .{ .pane_id = p.pane_id, .generation = p.generation },
        .pane_prompt_changed => |p| .{ .pane_id = p.pane_id, .generation = p.generation },
        .pane_status_changed => |p| .{ .pane_id = p.pane_id, .generation = p.generation },
    };
}

/// Every native OSC event passes through here with the same respawn gating
/// and `clearEventSinks` barrier as `emitThroughManager`.
fn emitOscThroughManager(context: *anyopaque, event: native_mod.OscEvent) void {
    const self: *Manager = @ptrCast(@alignCast(context));
    const key = oscEventGateKey(event);
    self.sink_mutex.lockUncancelable(self.io);
    self.sink_in_flight += 1;
    while (respawn.isGatedLocked(self, key.pane_id, key.generation)) {
        self.gate_changed.waitUncancelable(self.io, &self.sink_mutex);
    }
    const sink = self.event_sink;
    self.sink_mutex.unlock(self.io);

    if (sink) |active| {
        if (active.emit_osc) |emit_fn| {
            const previous = sink_callback_manager;
            sink_callback_manager = self;
            emit_fn(active.context, event);
            sink_callback_manager = previous;
        }
    }
    finishSinkCall(self);
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
        while (respawn.isGatedLocked(self, k.pane_id, k.generation)) {
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
    finishSinkCall(self);
}

/// Marks an in-flight event sink callback complete and wakes any waiters.
pub fn finishSinkCall(self: *Manager) void {
    self.sink_mutex.lockUncancelable(self.io);
    defer self.sink_mutex.unlock(self.io);
    assert(self.sink_in_flight > 0);
    self.sink_in_flight -= 1;
    if (self.sink_in_flight == 0 or self.sink_in_flight <= self.sink_reentrant_waiters) {
        self.sink_idle.broadcast(self.io);
    }
}

/// Notifies the registered respawn listener of a replacement `NativeSession`.
pub fn announceRespawn(self: *Manager, native: *NativeSession) void {
    assert(native.id.len > 0);
    const listener = blk: {
        self.sink_mutex.lockUncancelable(self.io);
        defer self.sink_mutex.unlock(self.io);
        const listener = self.respawn_listener orelse return;
        self.sink_in_flight += 1;
        assert(self.sink_in_flight > 0);
        break :blk listener;
    };
    defer finishSinkCall(self);
    const previous = sink_callback_manager;
    sink_callback_manager = self;
    defer sink_callback_manager = previous;
    assert(sink_callback_manager == self);
    listener.notify(listener.context, native);
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
            while (!self.release.load(.seq_cst)) {
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch |err| {
                    log.debug("mux_test_held_sink_sleep_failed", .{ .err = err });
                };
            }
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
