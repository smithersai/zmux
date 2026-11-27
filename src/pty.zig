//! PTY allocation and child process lifecycle for one pane.
//!
//! `Pty.spawn` does every allocation, `PATH` lookup, and environment merge
//! before `fork`. The forked child runs only async-signal-safe code
//! (`childExec`): it resets signal dispositions, wires the slave to stdio,
//! closes every other descriptor, and reports any setup or `exec` failure to
//! the parent over a close-on-exec pipe, so the caller gets
//! `error.ChildSetupFailed` instead of a pane running in the wrong directory.

const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;
const child_mod = @import("pty/child.zig");
const env_mod = @import("pty/env.zig");
const proc = @import("pty/proc.zig");
const session = @import("pty/session.zig");
const signal = @import("pty/signal.zig");
const spawn_mod = @import("pty/spawn.zig");

/// `TERM` applied when the spawn environment does not set one.
pub const default_term = "xterm-256color";
/// The `TERM` entry appended to an environment that has none.
pub const default_term_entry: [:0]const u8 = "TERM=" ++ default_term;

/// How `SpawnOptions.env` combines with the daemon environment.
pub const EnvMode = enum {
    /// The daemon environment, with `env` entries overriding matching keys.
    merge,
    /// Only the `env` entries.
    replace,
};

/// What `Pty.spawn` runs and how: shell, optional `-c` command, working
/// directory, environment, and initial window size.
pub const SpawnOptions = struct {
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// `KEY=VALUE` entries. See `env_mode`.
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    /// In both modes `TERM=xterm-256color` is added when no `TERM` is present.
    env_mode: EnvMode = .merge,
};

/// Callback invoked once, outside the lock, when the child is reaped.
pub const ExitObserver = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, pid: posix.pid_t, status: ?u32) void,
};

/// The child setup step that failed. Sent over the startup pipe as one byte.
pub const ChildSetupStage = enum(u8) {
    setsid = 1,
    ctty = 2,
    dup2 = 3,
    chdir = 4,
    exec = 5,
    unknown = 255,
};

/// Why a forked child failed before `exec`; see `last_child_setup_failure`.
pub const ChildSetupFailure = struct {
    stage: ChildSetupStage,
    errno: posix.E,
    /// The already-reaped child. Kept so tests can prove no process remains.
    pid: posix.pid_t,
};

/// Detail for the most recent `error.ChildSetupFailed` returned by
/// `Pty.spawn` on this thread. A handshake that timed out reports stage
/// `unknown` with `errno == .TIMEDOUT`; a failed read of the status pipe
/// reports stage `unknown` with the read's errno.
pub threadlocal var last_child_setup_failure: ?ChildSetupFailure = null;

/// How long `Pty.spawn` waits for the child to either `exec` or report a
/// setup failure. A child stuck in `chdir`/`exec` (a dead network mount, a
/// stopped process) is killed and reaped at this deadline and the spawn
/// fails with `error.ChildSetupFailed`, so the caller is never blocked
/// indefinitely.
pub var child_setup_timeout_ms: i64 = 5000;

/// Outcome of one reap attempt, read under a single lock: either the child
/// is still running, or it was collected with this wait status (null when
/// the status was unavailable, for example `ECHILD`).
pub const ReapState = union(enum) {
    running,
    exited: ?u32,
};

/// A child process running on the slave end of a pseudo-terminal, owned
/// through the non-blocking master descriptor.
pub const Pty = session.Pty;

/// Test helper, shared with the native-session tests. True while `pid`
/// names a process that can still run; a zombie does not count.
pub const processRunning = proc.processRunning;

fn hasNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}

/// Reject arguments that cannot be represented faithfully as C strings or
/// `KEY=VALUE` environment entries: an interior NUL would silently truncate
/// a path or command, and an entry with no key or no `=` is not a variable.
pub fn validateSpawnOptions(opts: SpawnOptions) error{InvalidSpawnArgument}!void {
    if (opts.shell) |v| if (v.len == 0 or hasNul(v)) return error.InvalidSpawnArgument;
    if (opts.command) |v| if (hasNul(v)) return error.InvalidSpawnArgument;
    if (opts.cwd) |v| if (v.len == 0 or hasNul(v)) return error.InvalidSpawnArgument;
    if (opts.env) |entries| for (entries) |entry| {
        if (hasNul(entry)) return error.InvalidSpawnArgument;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidSpawnArgument;
        if (eq == 0) return error.InvalidSpawnArgument;
        assert(eq + 1 <= entry.len);
    };
    assert(opts.shell == null or opts.shell.?.len > 0);
}

/// Internal pure helpers exposed for the repository's own fuzz suites. None
/// of them fork, open descriptors, or read the process environment.
pub const fuzz_hooks = struct {
    pub const validateSpawnOptionsFn = validateSpawnOptions;
    pub const envKeyFn = env_mod.envKey;
    pub const defaultShellForFn = env_mod.defaultShellFor;
    pub const procStatStateFn = proc.procStatState;
    pub const procStatusMaskFn = proc.procStatusMask;
    pub const errnoFromReportFn = child_mod.errnoFromReport;
    pub const default_term_entry_z = default_term_entry;

    /// A built `envp` or candidate list. Release with `deinit`.
    pub const StringList = struct {
        inner: env_mod.CStringList,

        /// Free the owned entries and the pointer array.
        pub fn deinit(self: *StringList, allocator: Allocator) void {
            self.inner.deinit(allocator);
        }

        /// Number of entries, not counting the NULL terminator.
        pub fn len(self: *const StringList) usize {
            return self.inner.entries().len;
        }

        /// Entry `index` as a slice (without its NUL).
        pub fn at(self: *const StringList, index: usize) []const u8 {
            assert(index < self.len());
            return std.mem.sliceTo(self.inner.entries()[index].?, 0);
        }

        /// True when the pointer array ends in exactly one NULL.
        pub fn isTerminated(self: *const StringList) bool {
            const items = self.inner.ptrs.items;
            assert(items.len > 0);
            for (items[0 .. items.len - 1]) |item| if (item == null) return false;
            return items[items.len - 1] == null;
        }
    };

    /// `buildEnv` over an explicit `base` environment block.
    pub fn buildEnvList(
        allocator: Allocator,
        base: [*:null]const ?[*:0]const u8,
        supplied: ?[]const []const u8,
        mode: EnvMode,
    ) !StringList {
        return .{ .inner = try env_mod.buildEnv(allocator, base, supplied, mode) };
    }

    /// `resolveExecCandidates` for `file` over an explicit `PATH` value.
    pub fn execCandidates(allocator: Allocator, file: []const u8, path_env: []const u8) !StringList {
        return .{ .inner = try env_mod.resolveExecCandidates(allocator, file, path_env) };
    }
};

// ---------------------------------------------------------------------------
// Tests

test {
    std.testing.refAllDecls(@This());
    _ = @import("pty/child.zig");
    _ = @import("pty/env.zig");
    _ = @import("pty/proc.zig");
    _ = @import("pty/session.zig");
    _ = @import("pty/signal.zig");
    _ = @import("pty/spawn.zig");
}

test "spawn rejects NUL bytes and malformed environment entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cases = [_]SpawnOptions{
        .{ .shell = "/bin/s\x00h" },
        .{ .shell = "" },
        .{ .shell = "/bin/sh", .command = "echo a\x00b" },
        .{ .shell = "/bin/sh", .cwd = "/tm\x00p" },
        .{ .shell = "/bin/sh", .cwd = "" },
        .{ .shell = "/bin/sh", .env = &.{"KEY=va\x00lue"} },
        .{ .shell = "/bin/sh", .env = &.{"K\x00EY=value"} },
        .{ .shell = "/bin/sh", .env = &.{"=value"} },
        .{ .shell = "/bin/sh", .env = &.{""} },
        .{ .shell = "/bin/sh", .env = &.{"NOEQUALS"} },
        .{ .shell = "/bin/sh", .env = &.{ "GOOD=1", "=bad" } },
    };
    for (cases) |opts| {
        try std.testing.expectError(error.InvalidSpawnArgument, Pty.spawn(allocator, io, opts));
    }
    // An empty value and a value containing '=' are both legal.
    try validateSpawnOptions(.{ .env = &.{ "EMPTY=", "URL=a=b" } });
}
