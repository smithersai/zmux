//! Mux command lines: the `command.exec` scanner and parser, key bindings,
//! and execution of parsed commands against a `Manager`.

const std = @import("std");

const mux = @import("../mux.zig");
const native_mod = @import("../native.zig");
const types = @import("types.zig");
const lookup = @import("lookup.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Manager = mux.Manager;
const NativeSession = native_mod.NativeSession;
const CreateOptions = types.CreateOptions;
const PaneHandle = types.PaneHandle;
const PaneRef = types.PaneRef;
const Axis = layout.Axis;
const replaceOwnedString = types.replaceOwnedString;
const dupeOpt = types.dupeOpt;
const discardHandle = types.discardHandle;

/// Splits a `command.exec` line into mux words. Space, tab, CR, and LF delimit
/// words; single quotes are literal; double quotes and bare backslashes escape
/// one byte. The shell command after the mux words is never re-tokenized.
pub const CommandScanner = struct {
    line: []const u8,
    pos: usize = 0,

    const Word = struct { start: usize, text: []u8 };

    fn isSpace(byte: u8) bool {
        return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
    }

    fn next(self: *CommandScanner, allocator: Allocator) !?Word {
        assert(self.pos <= self.line.len);
        while (self.pos < self.line.len and isSpace(self.line[self.pos])) self.pos += 1;
        if (self.pos >= self.line.len) return null;
        const start = self.pos;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        while (self.pos < self.line.len and !isSpace(self.line[self.pos])) {
            switch (self.line[self.pos]) {
                '\'' => {
                    const close = std.mem.indexOfScalarPos(u8, self.line, self.pos + 1, '\'') orelse
                        return error.UnsupportedCommand;
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
        // Every branch above consumes at least one byte.
        assert(self.pos > start);
        assert(self.pos <= self.line.len);
        return .{ .start = start, .text = try out.toOwnedSlice(allocator) };
    }

    fn tail(line: []const u8, start: usize) ?[]const u8 {
        assert(start <= line.len);
        const rest = std.mem.trim(u8, line[start..], " \t\r\n");
        return if (rest.len == 0) null else rest;
    }
};

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
    assert(self.key_bindings.items.len <= self.limits.max_bindings);
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

/// Looks up `(table, key)` and executes its bound tmux command against `target_pane_id`.
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

/// Parsed representation of a supported tmux-style control command line.
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
        const command = try dupeOpt(allocator, CommandScanner.tail(line, tail_start));
        return .{ .split_window = .{ .axis = axis, .command = command } };
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
        const found = lookup.findPaneWithParentsLocked(self, target_pane_id) orelse return error.PaneNotFound;
        session_id = try self.allocator.dupe(u8, found.session.id);
        errdefer self.allocator.free(session_id);
        cwd = try dupeOpt(self.allocator, found.pane.spawn.cwd);
        rows = found.pane.spawn.rows;
        cols = found.pane.spawn.cols;
    }
    defer self.allocator.free(session_id);
    defer if (cwd) |value| self.allocator.free(value);

    assert(parsed != .noop and parsed != .respawn_pane);
    switch (parsed) {
        // Both returned before the lookup above.
        .noop, .respawn_pane => {},
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
        const active = lookup.findPaneLocked(&manager, window.active_pane_id) orelse return error.MissingPane;
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
        const found = lookup.findWindowWithParentLocked(&manager, session.active_window_id) orelse return error.MissingWindow;
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
    const found = lookup.findWindowWithParentLocked(&manager, session.active_window_id) orelse return error.MissingWindow;
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

fn bindKeyForFailureTest(allocator: Allocator) !void {
    var manager = Manager.init(allocator, std.testing.io, null);
    defer manager.deinit();

    try manager.bindKey("prefix", "c", "new-window -n 'a b' -- top", false);
    try manager.bindKey("prefix", "c", "split-window -h", true);
    try std.testing.expect(manager.unbindKey("prefix", "c"));
}

test "bindKey allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bindKeyForFailureTest, .{});
}
