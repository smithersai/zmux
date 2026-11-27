//! Subcommand-specific flag and positional argument parsers for `zmux`.

const std = @import("std");
const assert = std.debug.assert;
const args = @import("args.zig");
const help = @import("help.zig");

const ParsedArgs = args.ParsedArgs;
const ParseError = args.ParseError;
const ParseFailure = args.ParseFailure;
const failWith = args.failWith;
const nextValue = args.nextValue;
const tryCommonFlag = args.tryCommonFlag;

/// Dispatch subcommand argument parsing based on `out.command`.
pub fn parseSubcommand(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    switch (out.command) {
        .attach => try parseAttach(out, rest, failure),
        .new => try parseNew(out, rest, failure),
        .run => try parseRun(out, rest, failure),
        .send => try parseSend(out, rest, failure),
        .screen => try parseScreen(out, rest, failure),
        .capture => try parseCapture(out, rest, failure),
        .wait => try parseWait(out, rest, failure),
        .signal => try parseSignal(out, rest, failure),
        .split => try parseSplit(out, rest, failure),
        .events => try parseEvents(out, rest, failure),
        .record => try parseRecord(out, rest, failure),
        .ssh => try parseSsh(out, rest, failure),
        .ls, .shutdown, .mcp, .doctor => try parseSimple(out, rest, 0, failure),
        .close, .kill => try parseSimple(out, rest, 1, failure),
        .rename => try parseSimple(out, rest, 2, failure),
        .help, .version, .daemon => {},
    }
    if (out.show_help) out.command = .help;
}

/// Parse arguments for `zmux [attach] <name>`.
pub fn parseAttach(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--no-create")) {
            out.auto_create = false;
        } else if (opts and std.mem.eql(u8, a, "--readonly")) {
            out.read_only = true;
        } else if (opts and std.mem.eql(u8, a, "--command")) {
            out.cmd_text = try nextValue(rest, &i, a, failure);
        } else if (opts and std.mem.eql(u8, a, "--detach-key")) {
            const val = try nextValue(rest, &i, a, failure);
            out.detach_key = help.parseDetachKey(val) catch return failWith(failure, error.InvalidValue, val);
        } else if (opts and std.mem.eql(u8, a, "--replay")) {
            const val = try nextValue(rest, &i, a, failure);
            out.replay = parseReplayMode(val) orelse return failWith(failure, error.InvalidValue, val);
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "session name");
    assert(out.target != null);
}

fn parseReplayMode(val: []const u8) ?args.ReplayMode {
    if (std.mem.eql(u8, val, "raw")) return .raw;
    if (std.mem.eql(u8, val, "vt")) return .vt;
    return null;
}

fn parseU16Positive(val: []const u8, failure: ?*ParseFailure) ParseError!u16 {
    const parsed = std.fmt.parseInt(u16, val, 10) catch return failWith(failure, error.InvalidValue, val);
    if (parsed == 0) return failWith(failure, error.InvalidValue, val);
    assert(parsed >= 1);
    return parsed;
}

fn parseU64Value(val: []const u8, min_val: u64, failure: ?*ParseFailure) ParseError!u64 {
    const parsed = std.fmt.parseInt(u64, val, 10) catch return failWith(failure, error.InvalidValue, val);
    if (parsed < min_val) return failWith(failure, error.InvalidValue, val);
    assert(parsed >= min_val);
    return parsed;
}

fn parseNew(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--command")) {
            out.cmd_text = try nextValue(rest, &i, a, failure);
        } else if (opts and std.mem.eql(u8, a, "--cwd")) {
            out.cwd = try nextValue(rest, &i, a, failure);
        } else if (opts and std.mem.eql(u8, a, "--rows")) {
            out.rows = try parseU16Positive(try nextValue(rest, &i, a, failure), failure);
        } else if (opts and std.mem.eql(u8, a, "--cols")) {
            out.cols = try parseU16Positive(try nextValue(rest, &i, a, failure), failure);
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
}

fn parseRun(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--")) {
            if (out.target == null) return failWith(failure, error.MissingArgument, "target");
            out.command_args = rest[i + 1 ..];
            break;
        } else if (try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (std.mem.eql(u8, a, "--timeout-ms")) {
            out.timeout_ms = try parseU64Value(try nextValue(rest, &i, a, failure), 1, failure);
        } else if (a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            out.command_args = rest[i..];
            break;
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    if (out.command_args.len == 0) return failWith(failure, error.MissingArgument, "command");
    assert(out.target != null and out.command_args.len > 0);
}

fn parseSend(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--enter")) {
            out.enter = true;
        } else if (opts and std.mem.eql(u8, a, "--stdin")) {
            out.use_stdin = true;
        } else if (opts and std.mem.eql(u8, a, "--key")) {
            out.key = try nextValue(rest, &i, a, failure);
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else if (out.second_arg == null) {
            out.second_arg = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    if (out.key == null and !out.use_stdin and out.second_arg == null and !out.enter) {
        return failWith(failure, error.MissingArgument, "text, --key, or --stdin");
    }
    assert(out.target != null);
}

fn parseScreen(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--format")) {
            const val = try nextValue(rest, &i, a, failure);
            out.screen_format = parseScreenFormat(val) orelse return failWith(failure, error.InvalidValue, val);
        } else if (opts and std.mem.eql(u8, a, "--scrollback")) {
            const val = try nextValue(rest, &i, a, failure);
            out.scrollback = @intCast(try parseU64Value(val, 0, failure));
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    assert(out.target != null);
}

fn parseScreenFormat(val: []const u8) ?args.ScreenFormat {
    if (std.mem.eql(u8, val, "plain")) return .plain;
    if (std.mem.eql(u8, val, "ansi")) return .ansi;
    if (std.mem.eql(u8, val, "cells")) return .cells;
    if (std.mem.eql(u8, val, "json")) return .json;
    return null;
}

fn parseCapture(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and (std.mem.eql(u8, a, "--lines") or std.mem.eql(u8, a, "-n"))) {
            const val = try nextValue(rest, &i, a, failure);
            out.lines = @intCast(try parseU64Value(val, 0, failure));
        } else if (opts and (std.mem.eql(u8, a, "--follow") or std.mem.eql(u8, a, "-f"))) {
            out.follow = true;
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    assert(out.target != null);
}

fn parseWait(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--pattern")) {
            out.pattern = try nextValue(rest, &i, a, failure);
        } else if (opts and std.mem.eql(u8, a, "--exit")) {
            out.wait_exit = true;
        } else if (opts and std.mem.eql(u8, a, "--idle-ms")) {
            out.idle_ms = try parseU64Value(try nextValue(rest, &i, a, failure), 1, failure);
        } else if (opts and std.mem.eql(u8, a, "--command-done")) {
            out.command_done = true;
        } else if (opts and std.mem.eql(u8, a, "--timeout-ms")) {
            out.timeout_ms = try parseU64Value(try nextValue(rest, &i, a, failure), 1, failure);
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    if (out.pattern == null and !out.wait_exit and out.idle_ms == null and !out.command_done) {
        return failWith(failure, error.MissingArgument, "wait condition");
    }
    assert(out.target != null);
}

fn parseSignal(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    try parseSimple(out, rest, 2, failure);
    if (out.show_help) return;
    const raw_sig = out.second_arg orelse return failWith(failure, error.MissingArgument, "signal");
    out.second_arg = args.normalizeSignal(raw_sig) orelse return failWith(failure, error.InvalidValue, raw_sig);
    assert(out.second_arg != null);
}

fn parseSplit(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and std.mem.eql(u8, a, "-h")) {
            out.split_axis = .horizontal;
        } else if (opts and std.mem.eql(u8, a, "-v")) {
            out.split_axis = .vertical;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--command")) {
            out.cmd_text = try nextValue(rest, &i, a, failure);
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    assert(out.target != null);
}

fn parseEvents(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (std.mem.eql(u8, a, "--panes")) {
            out.panes_csv = try nextValue(rest, &i, a, failure);
        } else if (a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
}

fn parseRecord(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--out")) {
            out.out_file = try nextValue(rest, &i, a, failure);
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else if (out.record_action == null) {
            out.record_action = parseRecordAction(a) orelse return failWith(failure, error.InvalidValue, a);
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "target");
    if (out.record_action == null) return failWith(failure, error.MissingArgument, "action");
    assert(out.target != null and out.record_action != null);
}

fn parseRecordAction(val: []const u8) ?args.RecordAction {
    if (std.mem.eql(u8, val, "start")) return .start;
    if (std.mem.eql(u8, val, "stop")) return .stop;
    if (std.mem.eql(u8, val, "export")) return .@"export";
    if (std.mem.eql(u8, val, "status")) return .status;
    return null;
}

fn parseSsh(out: *ParsedArgs, rest: []const []const u8, failure: ?*ParseFailure) ParseError!void {
    var opts = true;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and std.mem.eql(u8, a, "--remote-socket")) {
            out.remote_socket = try nextValue(rest, &i, a, failure);
        } else if (opts and std.mem.eql(u8, a, "--ssh-opt")) {
            const val = try nextValue(rest, &i, a, failure);
            if (out.ssh_opt_len >= args.max_ssh_opts) return failWith(failure, error.TooManySshOptions, val);
            out.ssh_opts[out.ssh_opt_len] = val;
            out.ssh_opt_len += 1;
        } else if (opts and std.mem.eql(u8, a, "--detach-key")) {
            const val = try nextValue(rest, &i, a, failure);
            out.detach_key = help.parseDetachKey(val) catch return failWith(failure, error.InvalidValue, val);
        } else if (opts and std.mem.eql(u8, a, "--readonly")) {
            out.read_only = true;
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (out.target == null) {
            out.target = a;
        } else if (out.second_arg == null) {
            out.second_arg = a;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (out.target == null) return failWith(failure, error.MissingArgument, "host");
    assert(out.ssh_opt_len <= args.max_ssh_opts);
}

fn parseSimple(
    out: *ParsedArgs,
    rest: []const []const u8,
    expected_pos: u8,
    failure: ?*ParseFailure,
) ParseError!void {
    assert(expected_pos <= 2);
    var opts = true;
    var pos: u8 = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (opts and std.mem.eql(u8, a, "--")) {
            opts = false;
        } else if (opts and try tryCommonFlag(out, rest, &i, failure)) {
            if (out.show_help) return;
        } else if (opts and a.len > 0 and a[0] == '-') {
            return failWith(failure, error.UnknownFlag, a);
        } else if (pos == 0 and expected_pos >= 1) {
            out.target = a;
            pos += 1;
        } else if (pos == 1 and expected_pos >= 2) {
            out.second_arg = a;
            pos += 1;
        } else {
            return failWith(failure, error.UnexpectedArgument, a);
        }
    }
    if (pos < expected_pos) {
        const label = if (pos == 0) "target" else "argument";
        return failWith(failure, error.MissingArgument, label);
    }
}

test "session management, screen, capture, wait, and run verbs parse accurately" {
    const new_cmd = try args.parse(&.{ "zmux", "new", "work", "--cwd", "/tmp", "--rows", "40", "--cols", "120" }, null);
    try std.testing.expectEqual(args.Command.new, new_cmd.command);
    try std.testing.expectEqualStrings("work", new_cmd.target.?);
    try std.testing.expectEqual(@as(?u16, 40), new_cmd.rows);
    try std.testing.expectEqual(@as(?u16, 120), new_cmd.cols);

    const run_cmd = try args.parse(&.{ "zmux", "run", "work", "--timeout-ms", "5000", "--", "echo", "hi" }, null);
    try std.testing.expectEqual(args.Command.run, run_cmd.command);
    try std.testing.expectEqual(@as(u64, 5000), run_cmd.timeout_ms);
    try std.testing.expectEqual(@as(usize, 2), run_cmd.command_args.len);

    const wait_cmd = try args.parse(&.{ "zmux", "wait", "work", "--pattern", "ok", "--command-done" }, null);
    try std.testing.expectEqual(args.Command.wait, wait_cmd.command);
    try std.testing.expect(wait_cmd.command_done);

    const cap_cmd = try args.parse(&.{ "zmux", "tail", "work", "--lines", "50", "--follow" }, null);
    try std.testing.expectEqual(args.Command.capture, cap_cmd.command);
    try std.testing.expectEqual(@as(usize, 50), cap_cmd.lines);
    try std.testing.expect(cap_cmd.follow);
}

test "signal, split, record, ssh, mcp, doctor, and daemon forwarding parse accurately" {
    const sig = try args.parse(&.{ "zmux", "signal", "p1", "int" }, null);
    try std.testing.expectEqualStrings("SIGINT", sig.second_arg.?);

    const spl = try args.parse(&.{ "zmux", "split", "p1", "-h", "--command", "sh" }, null);
    try std.testing.expectEqual(args.SplitAxis.horizontal, spl.split_axis);
    try std.testing.expectEqualStrings("sh", spl.cmd_text.?);

    const rec = try args.parse(&.{ "zmux", "record", "p1", "export", "--out", "/tmp/x.cast" }, null);
    try std.testing.expectEqual(args.RecordAction.@"export", rec.record_action.?);
    try std.testing.expectEqualStrings("/tmp/x.cast", rec.out_file.?);

    const ssh_cmd = try args.parse(&.{
        "zmux", "ssh", "me@box", "dev", "--ssh-opt", "Port=2222", "--remote-socket", "/tmp/r.sock", "--readonly",
    }, null);
    try std.testing.expectEqualStrings("me@box", ssh_cmd.target.?);
    try std.testing.expectEqual(@as(usize, 1), ssh_cmd.sshOptions().len);

    const dm = try args.parse(&.{ "zmux", "daemon", "--socket", "/tmp/d.sock", "--idle-timeout", "30" }, null);
    try std.testing.expectEqual(@as(usize, 4), dm.command_args.len);
}

test "invalid flags and missing required arguments populate ParseFailure" {
    var fail_info: ParseFailure = .{ .err = error.UnknownFlag };
    try std.testing.expectError(error.UnknownFlag, args.parse(&.{ "zmux", "--bogus" }, &fail_info));
    try std.testing.expectEqual(error.UnknownFlag, fail_info.err);

    try std.testing.expectError(error.InvalidValue, args.parse(&.{ "zmux", "signal", "p1", "BOGUS" }, &fail_info));
    try std.testing.expectError(error.MissingArgument, args.parse(&.{ "zmux", "wait", "p1" }, &fail_info));
    try std.testing.expectError(error.MissingArgument, args.parse(&.{ "zmux", "send", "p1" }, &fail_info));
    try std.testing.expectError(error.InvalidValue, args.parse(&.{ "zmux", "new", "--rows", "0" }, &fail_info));
}
