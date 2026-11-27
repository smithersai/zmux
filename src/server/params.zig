const std = @import("std");
const assert = std.debug.assert;
const buffer_mod = @import("../buffer.zig");
const mux = @import("../mux.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const test_support_mod = @import("test_support.zig");
const envContains = test_support_mod.envContains;
const parseJson = test_support_mod.parseJson;

fn paramValue(params: ?Value, key: []const u8) ?Value {
    const params_value = params orelse return null;
    if (params_value != .object) return null;
    const value = params_value.object.get(key) orelse return null;
    if (value == .null) return null;
    assert(value != .null);
    return value;
}

/// String param `key`, null when absent, `InvalidParams` when present with another type.
pub fn optionalString(params: ?Value, key: []const u8) !?[]const u8 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidParams,
    };
}

/// Value of the first key in `keys` present as a string param, else null.
pub fn firstStringParam(params: ?Value, keys: []const []const u8) !?[]const u8 {
    for (keys) |key| {
        if (try optionalString(params, key)) |value| return value;
    }
    return null;
}

/// Bool param `key`, null when absent, `InvalidParams` when present with another type.
pub fn optionalBool(params: ?Value, key: []const u8) !?bool {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidParams,
    };
}

/// Absent → null. Wrong type, negative, fractional, or out of range for `T`
/// → `InvalidParams`.
pub fn optionalInt(comptime T: type, params: ?Value, key: []const u8) !?T {
    const value = paramValue(params, key) orelse return null;
    const integer = switch (value) {
        .integer => |n| n,
        else => return error.InvalidParams,
    };
    if (integer < 0) return error.InvalidParams;
    assert(integer >= 0);
    return std.math.cast(T, integer) orelse error.InvalidParams;
}

/// Numeric param `key` as `f64` (accepts integer or float JSON values), null when absent.
pub fn optionalFloat(params: ?Value, key: []const u8) !?f64 {
    const value = paramValue(params, key) orelse return null;
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => error.InvalidParams,
    };
}

/// Object param `key`, null when absent, `InvalidParams` when present with another type.
pub fn objectParam(params: ?Value, key: []const u8) !?Value {
    const value = paramValue(params, key) orelse return null;
    if (value != .object) return error.InvalidParams;
    assert(value == .object);
    return value;
}

/// Terminal rows or columns: an integer in 1..65535, else `InvalidDimensions`.
pub fn dimensionParam(params: ?Value, key: []const u8, default: u16) !u16 {
    const value = paramValue(params, key) orelse return default;
    const integer = switch (value) {
        .integer => |n| n,
        else => return error.InvalidParams,
    };
    if (integer < 1 or integer > std.math.maxInt(u16)) return error.InvalidDimensions;
    const dimension: u16 = @intCast(integer);
    assert(dimension >= 1);
    return dimension;
}

/// Session target from `sessionId` or its `id` alias.
pub fn sessionIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "sessionId", "id" });
}

/// Pane target from `paneId` or one of its aliases (`targetPaneId`, `target`, `sessionId`, `id`).
pub fn paneIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "paneId", "targetPaneId", "target", "sessionId", "id" });
}

/// Window target from `windowId` or one of its aliases (`targetWindowId`, `target`, `id`).
pub fn windowIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "windowId", "targetWindowId", "target", "id" });
}

/// Mux client target from `clientId` or one of its aliases (`targetClientId`, `id`).
pub fn clientIdParam(params: ?Value) !?[]const u8 {
    return firstStringParam(params, &.{ "clientId", "targetClientId", "id" });
}

/// Split axis from `axis` (`horizontal`/`h`/`-h` or vertical), else from the `horizontal` flag.
pub fn axisParam(params: ?Value) !mux.Axis {
    const axis = try optionalString(params, "axis") orelse {
        return if (try optionalBool(params, "horizontal") orelse false) .horizontal else .vertical;
    };
    if (std.mem.eql(u8, axis, "horizontal") or std.mem.eql(u8, axis, "h") or std.mem.eql(u8, axis, "-h")) {
        return .horizontal;
    }
    if (std.mem.eql(u8, axis, "vertical") or std.mem.eql(u8, axis, "v") or std.mem.eql(u8, axis, "-v")) {
        return .vertical;
    }
    return error.InvalidAxis;
}

/// Scrollback capacity from `scrollbackBytes`: the default when absent, non-zero and capped.
pub fn scrollbackBytesFromParams(params: ?Value) !usize {
    const bytes = try optionalInt(usize, params, "scrollbackBytes") orelse return buffer_mod.default_capacity;
    if (bytes == 0) return error.InvalidParams;
    if (bytes > buffer_mod.max_capacity) return error.ScrollbackBytesTooLarge;
    assert(bytes > 0 and bytes <= buffer_mod.max_capacity);
    return bytes;
}

/// Create options parsed from request params, plus the env and metadata storage they borrow.
pub const MuxCreateArgs = struct {
    allocator: Allocator,
    env_entries: ?[][]const u8 = null,
    metadata_entries: ?[]mux.MetadataEntry = null,
    opts: mux.CreateOptions,

    pub fn deinit(self: *MuxCreateArgs) void {
        if (self.env_entries) |entries| freeStringSlice(self.allocator, entries);
        if (self.metadata_entries) |entries| freeMetadataEntries(self.allocator, entries);
        self.env_entries = null;
        self.metadata_entries = null;
        self.opts = .{};
    }
};

/// How `muxCreateArgsFromParams` interprets request aliases.
pub const CreateArgsOptions = struct {
    // When true, `id` falls back into the title slot. Only `session.create`
    // sets this: for `window.new` and `pane.split` the request's `id` field
    // already aliases the *target* (via paneIdParam / sessionIdParam), and
    // repurposing it as the new window/pane title would silently rename
    // them on every call.
    id_aliases_title: bool = false,
};

/// Reject a string the kernel would truncate at its first NUL.
fn spawnString(value: ?[]const u8) !?[]const u8 {
    const text = value orelse return null;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSpawnArgument;
    return text;
}

/// Parse and validate every create parameter before any side effect.
pub fn muxCreateArgsFromParams(allocator: Allocator, params: ?Value, options: CreateArgsOptions) !MuxCreateArgs {
    if (params) |value| switch (value) {
        .object, .null => {},
        else => return error.InvalidParams,
    };

    const title_keys: []const []const u8 = if (options.id_aliases_title)
        &.{ "title", "name", "id" }
    else
        &.{ "title", "name" };
    const title = try firstStringParam(params, title_keys);
    const shell = try spawnString(try optionalString(params, "shell"));
    const command = try spawnString(try optionalString(params, "command"));
    const cwd = try spawnString(try firstStringParam(params, &.{ "cwd", "workingDirectory" }));
    const rows = try dimensionParam(params, "rows", 24);
    const cols = try dimensionParam(params, "cols", 80);
    const scrollback_bytes = try scrollbackBytesFromParams(params);
    const clear_env = try optionalBool(params, "clearEnv") orelse false;
    assert(rows >= 1 and cols >= 1);
    assert(scrollback_bytes > 0);

    const env_entries = try envEntriesFromParams(allocator, params);
    errdefer if (env_entries) |entries| freeStringSlice(allocator, entries);

    const metadata_entries = try metadataEntriesFromParams(allocator, params, "metadata");
    errdefer if (metadata_entries) |entries| freeMetadataEntries(allocator, entries);

    // `env` merges over the daemon environment by default (D3); `clearEnv`
    // asks for full replacement.
    const opts: mux.CreateOptions = .{
        .title = title,
        .shell = shell,
        .command = command,
        .cwd = cwd,
        .env = if (env_entries) |entries| entries else null,
        .env_mode = if (clear_env) .replace else .merge,
        .rows = rows,
        .cols = cols,
        .scrollback_bytes = scrollback_bytes,
        .metadata = metadata_entries,
    };
    return .{
        .allocator = allocator,
        .env_entries = env_entries,
        .metadata_entries = metadata_entries,
        .opts = opts,
    };
}

/// Parse an optional string-to-string JSON object `key` into owned `mux.MetadataEntry` pairs.
pub fn metadataEntriesFromParams(
    allocator: Allocator,
    params: ?Value,
    key: []const u8,
) !?[]mux.MetadataEntry {
    const obj_val = paramValue(params, key) orelse return null;
    if (obj_val != .object) return error.InvalidParams;
    const count = obj_val.object.count();
    const list = try allocator.alloc(mux.MetadataEntry, count);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |entry| {
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        allocator.free(list);
    }
    var it = obj_val.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        if (k.len == 0 or std.mem.indexOfScalar(u8, k, 0) != null) return error.InvalidParams;
        if (std.mem.indexOfScalar(u8, v, 0) != null) return error.InvalidParams;
        const owned_k = try allocator.dupe(u8, k);
        errdefer allocator.free(owned_k);
        const owned_v = try allocator.dupe(u8, v);
        list[filled] = .{ .key = owned_k, .value = owned_v };
        filled += 1;
    }
    assert(filled == count);
    return list;
}

/// Free a slice of owned `mux.MetadataEntry` pairs returned by `metadataEntriesFromParams`.
pub fn freeMetadataEntries(allocator: Allocator, entries: []const mux.MetadataEntry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    allocator.free(entries);
}

/// `env` / `environment`: an object of string values only. Anything else is
/// `InvalidParams`; a key that is empty or contains `=` or NUL, or a value
/// with NUL, is `InvalidSpawnArgument`. Values are never re-serialized.
pub fn envEntriesFromParams(allocator: Allocator, params: ?Value) !?[][]const u8 {
    const env_value = paramValue(params, "env") orelse paramValue(params, "environment") orelse return null;
    if (env_value != .object) return error.InvalidParams;

    var entries = std.ArrayList([]const u8).empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    var it = env_value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = switch (entry.value_ptr.*) {
            .string => |text| text,
            else => return error.InvalidParams,
        };
        if (key.len == 0 or std.mem.indexOfAny(u8, key, "=\x00") != null) return error.InvalidSpawnArgument;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSpawnArgument;

        const env_entry = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
        errdefer allocator.free(env_entry);
        assert(env_entry.len == key.len + 1 + value.len);
        try entries.append(allocator, env_entry);
    }
    assert(entries.items.len == env_value.object.count());

    return try entries.toOwnedSlice(allocator);
}

/// Free each string in `entries`, then the slice itself.
pub fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

test "server parses aliases for session id" {
    var parsed = try parseJson("{\"id\":\"sess-1\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess-1", (try sessionIdParam(parsed.value)).?);
}

test "mux create args treats id as title only for session create" {
    var parsed = try parseJson("{\"id\":\"target-pane\",\"rows\":40,\"cols\":120}");
    defer parsed.deinit();

    var target_args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer target_args.deinit();
    try std.testing.expect(target_args.opts.title == null);
    try std.testing.expectEqual(@as(u16, 40), target_args.opts.rows);
    try std.testing.expectEqual(@as(u16, 120), target_args.opts.cols);

    var create_args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{ .id_aliases_title = true });
    defer create_args.deinit();
    try std.testing.expectEqualStrings("target-pane", create_args.opts.title.?);
}

test "mux create args passes string environment values through unchanged" {
    var parsed = try parseJson("{\"env\":{\"TEXT\":\"one\",\"COUNT\":\"7\",\"EMPTY\":\"\"},\"scrollbackBytes\":4096}");
    defer parsed.deinit();

    var args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer args.deinit();

    try std.testing.expectEqual(@as(usize, 4096), args.opts.scrollback_bytes);
    const entries = args.opts.env orelse return error.MissingEnvEntries;
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expect(envContains(entries, "TEXT=one"));
    try std.testing.expect(envContains(entries, "COUNT=7"));
    try std.testing.expect(envContains(entries, "EMPTY="));
}

test "mux create args rejects non-string env values and unsafe spawn strings" {
    const Case = struct { json: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .json = "{\"env\":{\"COUNT\":7}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"FLAG\":true}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"NESTED\":{\"a\":1}}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"LIST\":[1]}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"NULLED\":null}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":[\"A=1\"]}", .err = error.InvalidParams },
        .{ .json = "{\"env\":\"A=1\"}", .err = error.InvalidParams },
        .{ .json = "{\"environment\":{\"COUNT\":7}}", .err = error.InvalidParams },
        .{ .json = "{\"env\":{\"A=B\":\"x\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"env\":{\"\":\"x\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"env\":{\"A\":\"x\\u0000y\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"env\":{\"A\\u0000B\":\"x\"}}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"shell\":\"/bin/sh\\u0000x\"}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"command\":\"a\\u0000b\"}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"cwd\":\"/tmp\\u0000x\"}", .err = error.InvalidSpawnArgument },
        .{ .json = "{\"shell\":7}", .err = error.InvalidParams },
        .{ .json = "{\"title\":false}", .err = error.InvalidParams },
        .{ .json = "{\"clearEnv\":\"yes\"}", .err = error.InvalidParams },
        .{ .json = "{\"rows\":0}", .err = error.InvalidDimensions },
        .{ .json = "{\"cols\":65536}", .err = error.InvalidDimensions },
        .{ .json = "{\"rows\":\"24\"}", .err = error.InvalidParams },
        .{ .json = "{\"scrollbackBytes\":0}", .err = error.InvalidParams },
        .{ .json = "{\"scrollbackBytes\":-1}", .err = error.InvalidParams },
        .{ .json = "{\"scrollbackBytes\":\"big\"}", .err = error.InvalidParams },
        .{ .json = "7", .err = error.InvalidParams },
        .{ .json = "\"text\"", .err = error.InvalidParams },
        .{ .json = "[1,2]", .err = error.InvalidParams },
    };
    for (cases) |case| {
        var parsed = try parseJson(case.json);
        defer parsed.deinit();
        if (muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{})) |created| {
            var args = created;
            args.deinit();
            std.debug.print("accepted {s}\n", .{case.json});
            return error.TestExpectedError;
        } else |err| {
            if (err != case.err) {
                std.debug.print("{s}: got {s}\n", .{ case.json, @errorName(err) });
                return error.TestUnexpectedError;
            }
        }
    }
}

test "mux create args parses clearEnv" {
    var parsed = try parseJson("{\"clearEnv\":true,\"env\":{\"A\":\"1\"}}");
    defer parsed.deinit();
    var args = try muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{});
    defer args.deinit();
    try std.testing.expect(args.opts.env_mode == .replace);

    var merged = try parseJson("{\"env\":{\"A\":\"1\"}}");
    defer merged.deinit();
    var merge_args = try muxCreateArgsFromParams(std.testing.allocator, merged.value, .{});
    defer merge_args.deinit();
    try std.testing.expect(merge_args.opts.env_mode == .merge);
}

test "mux create args rejects oversize scrollbackBytes" {
    const max = buffer_mod.max_capacity;
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"scrollbackBytes\":{}}}", .{max + 1});
    defer std.testing.allocator.free(payload);

    var parsed = try parseJson(payload);
    defer parsed.deinit();
    try std.testing.expectError(
        error.ScrollbackBytesTooLarge,
        muxCreateArgsFromParams(std.testing.allocator, parsed.value, .{}),
    );
}

test "typed params reject wrong types instead of falling back to defaults" {
    var parsed = try parseJson(
        "{\"n\":5,\"neg\":-1,\"frac\":1.5,\"text\":\"5\",\"flag\":true,\"nil\":null,\"big\":70000,\"huge\":99999999999999999999}",
    );
    defer parsed.deinit();
    const params: ?Value = parsed.value;

    try std.testing.expectEqual(@as(?u16, 5), try optionalInt(u16, params, "n"));
    try std.testing.expectEqual(@as(?u16, null), try optionalInt(u16, params, "missing"));
    try std.testing.expectEqual(@as(?u16, null), try optionalInt(u16, params, "nil"));
    try std.testing.expectEqual(@as(?u16, null), try optionalInt(u16, null, "n"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "neg"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "frac"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "text"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "flag"));
    try std.testing.expectError(error.InvalidParams, optionalInt(u16, params, "big"));
    try std.testing.expectError(error.InvalidParams, optionalInt(usize, params, "huge"));

    try std.testing.expectEqual(@as(?bool, true), try optionalBool(params, "flag"));
    try std.testing.expectEqual(@as(?bool, null), try optionalBool(params, "missing"));
    try std.testing.expectError(error.InvalidParams, optionalBool(params, "n"));
    try std.testing.expectError(error.InvalidParams, optionalBool(params, "text"));

    try std.testing.expectEqualStrings("5", (try optionalString(params, "text")).?);
    try std.testing.expect((try optionalString(params, "missing")) == null);
    try std.testing.expectError(error.InvalidParams, optionalString(params, "n"));
    try std.testing.expectError(error.InvalidParams, optionalString(params, "flag"));

    try std.testing.expectEqual(@as(u16, 24), try dimensionParam(params, "missing", 24));
    try std.testing.expectEqual(@as(u16, 5), try dimensionParam(params, "n", 24));
    try std.testing.expectError(error.InvalidDimensions, dimensionParam(params, "neg", 24));
    try std.testing.expectError(error.InvalidDimensions, dimensionParam(params, "big", 24));
    try std.testing.expectError(error.InvalidParams, dimensionParam(params, "text", 24));
    try std.testing.expectError(error.InvalidParams, dimensionParam(params, "frac", 24));
}

test "axisParam accepts aliases and rejects unknown axes" {
    var horizontal_string = try parseJson("{\"axis\":\"-h\"}");
    defer horizontal_string.deinit();
    try std.testing.expectEqual(mux.Axis.horizontal, try axisParam(horizontal_string.value));

    var horizontal_bool = try parseJson("{\"horizontal\":true}");
    defer horizontal_bool.deinit();
    try std.testing.expectEqual(mux.Axis.horizontal, try axisParam(horizontal_bool.value));

    var vertical = try parseJson("{\"axis\":\"v\"}");
    defer vertical.deinit();
    try std.testing.expectEqual(mux.Axis.vertical, try axisParam(vertical.value));

    var default_axis = try parseJson("{}");
    defer default_axis.deinit();
    try std.testing.expectEqual(mux.Axis.vertical, try axisParam(default_axis.value));

    var unknown = try parseJson("{\"axis\":\"diagonal\"}");
    defer unknown.deinit();
    try std.testing.expectError(error.InvalidAxis, axisParam(unknown.value));

    var wrong_type = try parseJson("{\"axis\":7}");
    defer wrong_type.deinit();
    try std.testing.expectError(error.InvalidParams, axisParam(wrong_type.value));
}
