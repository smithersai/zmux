//! Bounded string key-value metadata store for panes and sessions (`pane.metadata`).
//!
//! Serialized JSON size is strictly capped at `max_metadata_bytes` (16 KiB) and
//! updates are validated and built into a fresh map before swapping atomically,
//! so `OutOfMemory` or `LimitExceeded` leaves existing state untouched.

const std = @import("std");
const mux = @import("../mux.zig");
const lookup = @import("lookup.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;

/// Maximum serialized JSON byte size for a pane or session metadata object (16 KiB).
pub const max_metadata_bytes: usize = 16 * 1024;

/// Borrowed key-value pair passed when creating or updating metadata.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Owned response snapshot for `pane.metadata`.
pub const PaneMetadataSnapshot = struct {
    pane_id: []u8,
    metadata_json: []u8,

    /// Free owned snapshot buffers.
    pub fn deinit(self: *PaneMetadataSnapshot, allocator: Allocator) void {
        allocator.free(self.pane_id);
        allocator.free(self.metadata_json);
        self.* = undefined;
    }
};

/// Bounded string-to-string metadata map owned by a `Pane` or `Session`.
pub const MetadataMap = struct {
    entries: std.StringArrayHashMapUnmanaged([]u8) = .empty,

    /// Free every owned key, value, and the underlying map storage.
    pub fn deinit(self: *MetadataMap, allocator: Allocator) void {
        for (self.entries.keys(), self.entries.values()) |k, v| {
            allocator.free(k);
            allocator.free(v);
        }
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// Number of stored metadata entries.
    pub fn count(self: *const MetadataMap) usize {
        return self.entries.count();
    }

    /// Look up the value stored for `key`, or null if absent.
    pub fn get(self: *const MetadataMap, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    /// Serialize this metadata map as a compact JSON object (`{}` when empty).
    pub fn writeJson(self: *const MetadataMap, writer: *std.Io.Writer) !void {
        assert(self.entries.keys().len == self.entries.values().len);
        try writer.writeByte('{');
        for (self.entries.keys(), self.entries.values(), 0..) |k, v, idx| {
            if (idx > 0) try writer.writeByte(',');
            try writer.print("{f}:{f}", .{ std.json.fmt(k, .{}), std.json.fmt(v, .{}) });
        }
        try writer.writeByte('}');
    }

    /// Allocate a fresh serialized JSON string of this metadata map.
    pub fn toJsonAlloc(self: *const MetadataMap, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
        errdefer out.deinit();
        try self.writeJson(&out.writer);
        const owned = try out.toOwnedSlice();
        assert(owned.len >= 2 and owned[0] == '{' and owned[owned.len - 1] == '}');
        return owned;
    }

    /// Construct a validated copy of `self` with optional `replace`, `set_entries`,
    /// and `remove_keys` applied, enforcing `max_metadata_bytes`.
    pub fn cloneAndApply(
        self: *const MetadataMap,
        allocator: Allocator,
        set_entries: ?[]const Entry,
        remove_keys: ?[]const []const u8,
        replace: bool,
    ) !MetadataMap {
        var next: MetadataMap = .{};
        errdefer next.deinit(allocator);

        if (!replace) {
            for (self.entries.keys(), self.entries.values()) |k, v| {
                try putOwned(&next, allocator, k, v);
            }
        }
        if (remove_keys) |keys| {
            for (keys) |k| {
                if (k.len == 0 or std.mem.indexOfScalar(u8, k, 0) != null) return error.InvalidParams;
                removeOwned(&next, allocator, k);
            }
        }
        if (set_entries) |pairs| {
            for (pairs) |pair| {
                if (pair.key.len == 0 or std.mem.indexOfScalar(u8, pair.key, 0) != null) {
                    return error.InvalidParams;
                }
                if (std.mem.indexOfScalar(u8, pair.value, 0) != null) return error.InvalidParams;
                try putOwned(&next, allocator, pair.key, pair.value);
            }
        }

        const encoded = try next.toJsonAlloc(allocator);
        defer allocator.free(encoded);
        if (encoded.len > max_metadata_bytes) return error.LimitExceeded;
        assert(encoded.len >= 2 and encoded.len <= max_metadata_bytes);
        return next;
    }

    /// Build a fresh `MetadataMap` from initial creation entries (empty when null).
    pub fn fromEntries(allocator: Allocator, entries: ?[]const Entry) !MetadataMap {
        const empty: MetadataMap = .{};
        if (entries == null) return empty;
        return empty.cloneAndApply(allocator, entries, null, true);
    }
};

fn putOwned(map: *MetadataMap, allocator: Allocator, key: []const u8, value: []const u8) !void {
    assert(key.len > 0);
    if (map.entries.getPtr(key)) |slot| {
        const owned_val = try allocator.dupe(u8, value);
        allocator.free(slot.*);
        slot.* = owned_val;
        return;
    }
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_val = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_val);
    try map.entries.put(allocator, owned_key, owned_val);
}

fn removeOwned(map: *MetadataMap, allocator: Allocator, key: []const u8) void {
    assert(key.len > 0);
    const idx = map.entries.getIndex(key) orelse return;
    const old_k = map.entries.keys()[idx];
    const old_v = map.entries.values()[idx];
    map.entries.orderedRemoveAt(idx);
    allocator.free(old_k);
    allocator.free(old_v);
    assert(map.entries.getIndex(key) == null);
}

/// Read, merge, replace, or delete string metadata on a pane and return its
/// canonical pane id plus serialized metadata JSON object.
pub fn updatePaneMetadata(
    self: *Manager,
    allocator: Allocator,
    target: []const u8,
    set_entries: ?[]const Entry,
    remove_keys: ?[]const []const u8,
    replace: bool,
) !PaneMetadataSnapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = lookup.resolveTargetPaneLocked(self, target) orelse return error.PaneNotFound;
    const pane = found.pane;
    const has_mutation = replace or set_entries != null or remove_keys != null;
    if (has_mutation) {
        var next = try pane.metadata.cloneAndApply(self.allocator, set_entries, remove_keys, replace);
        errdefer next.deinit(self.allocator);
        const owned_id = try allocator.dupe(u8, pane.id);
        errdefer allocator.free(owned_id);
        const json = try next.toJsonAlloc(allocator);
        pane.metadata.deinit(self.allocator);
        pane.metadata = next;
        return .{ .pane_id = owned_id, .metadata_json = json };
    }
    const owned_id = try allocator.dupe(u8, pane.id);
    errdefer allocator.free(owned_id);
    const json = try pane.metadata.toJsonAlloc(allocator);
    return .{ .pane_id = owned_id, .metadata_json = json };
}

/// Merge or replace metadata entries on a pane.
pub fn setPaneMetadata(self: *Manager, target: []const u8, entries: []const Entry, replace: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const found = lookup.resolveTargetPaneLocked(self, target) orelse return error.PaneNotFound;
    const next = try found.pane.metadata.cloneAndApply(self.allocator, entries, null, replace);
    found.pane.metadata.deinit(self.allocator);
    found.pane.metadata = next;
}

/// Merge or replace metadata entries on a session.
pub fn setSessionMetadata(self: *Manager, target: []const u8, entries: []const Entry, replace: bool) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const session = lookup.resolveTargetSessionLocked(self, target) orelse return error.SessionNotFound;
    const next = try session.metadata.cloneAndApply(self.allocator, entries, null, replace);
    session.metadata.deinit(self.allocator);
    session.metadata = next;
}

test "MetadataMap supports merge, replace, remove, and 16 KiB limit" {
    const allocator = std.testing.allocator;
    var map: MetadataMap = .{};
    defer map.deinit(allocator);

    var m1 = try map.cloneAndApply(allocator, &.{
        .{ .key = "role", .value = "builder" },
        .{ .key = "task", .value = "1" },
    }, null, false);
    map.deinit(allocator);
    map = m1;
    try std.testing.expectEqualStrings("builder", map.get("role").?);

    m1 = try map.cloneAndApply(allocator, &.{.{ .key = "task", .value = "2" }}, &.{"role"}, false);
    map.deinit(allocator);
    map = m1;
    try std.testing.expect(map.get("role") == null);
    try std.testing.expectEqualStrings("2", map.get("task").?);

    const huge = try allocator.alloc(u8, max_metadata_bytes + 32);
    defer allocator.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(
        error.LimitExceeded,
        map.cloneAndApply(allocator, &.{.{ .key = "big", .value = huge }}, null, false),
    );
    try std.testing.expectEqualStrings("2", map.get("task").?);
}

test "Manager stores initial pane metadata, updates pane/session metadata, and emits snapshot JSON" {
    const allocator = std.testing.allocator;
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    const init_meta = [_]Entry{.{ .key = "agent", .value = "worker" }};
    var p1 = try manager.createSessionPane(.{
        .shell = "/bin/sh",
        .command = "exec cat",
        .metadata = &init_meta,
    });
    defer p1.deinit();

    var snap1 = try manager.updatePaneMetadata(allocator, p1.pane_id, &.{.{ .key = "step", .value = "1" }}, null, false);
    defer snap1.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, snap1.metadata_json, "\"agent\":\"worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snap1.metadata_json, "\"step\":\"1\"") != null);

    try manager.setSessionMetadata(p1.session_id, &.{.{ .key = "env", .value = "ci" }}, true);
    const full = try manager.snapshotJson(allocator);
    defer allocator.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"agent\":\"worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "\"env\":\"ci\"") != null);

    var snap2 = try manager.updatePaneMetadata(allocator, p1.pane_id, null, &.{"agent"}, false);
    defer snap2.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, snap2.metadata_json, "agent") == null);
    try std.testing.expect(std.mem.indexOf(u8, snap2.metadata_json, "\"step\":\"1\"") != null);
}
