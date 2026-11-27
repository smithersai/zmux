//! Bounded asciicast v2 session recording for `NativeSession`.
//!
//! Captures `(monotonic_ns, bytes)` frames in an in-memory ring (default cap
//! 8 MiB / 65,536 frames) and optionally streams valid asciicast v2 NDJSON
//! directly to an absolute file path opened `0600` close-on-exec.

const std = @import("std");
const protocol = @import("../protocol.zig");
const sys = @import("../sys.zig");
const log = @import("../log.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const NativeSession = session.NativeSession;

/// Default maximum payload bytes retained by an in-memory or file recording (8 MiB).
pub const default_max_bytes: usize = 8 * 1024 * 1024;
/// Upper ceiling on `max_bytes` accepted from RPC callers (64 MiB).
pub const hard_max_bytes: usize = 64 * 1024 * 1024;
/// Maximum number of frames retained in the in-memory recording ring.
pub const max_ring_frames: usize = 65_536;

/// Parameters for `NativeSession.startRecording`.
pub const StartOptions = struct {
    /// Optional absolute output path to stream asciicast v2 NDJSON into.
    path: ?[]const u8 = null,
    /// Maximum payload/file bytes to record before stopping writes.
    max_bytes: usize = default_max_bytes,
};

/// Snapshot of a pane's recording status for `pane.record`.
pub const RecordStatus = struct {
    recording: bool,
    path: ?[]u8,
    bytes_written: u64,
    started_at_ms: ?i64,

    /// Release any owned path string.
    pub fn deinit(self: *RecordStatus, allocator: Allocator) void {
        if (self.path) |p| allocator.free(p);
        self.* = .{ .recording = false, .path = null, .bytes_written = 0, .started_at_ms = null };
    }
};

const Frame = struct {
    rel_ns: u64,
    bytes: []u8,
};

/// Bounded asciicast v2 recorder embedded inside `NativeSession`.
/// Allocates nothing until `start` is invoked.
pub const Recorder = struct {
    active: bool = false,
    started_mono_ns: i128 = 0,
    started_at_ms: ?i64 = null,
    initial_rows: u16 = 24,
    initial_cols: u16 = 80,
    max_bytes: usize = default_max_bytes,
    ring_bytes: usize = 0,
    bytes_written: u64 = 0,
    frames: std.ArrayList(Frame) = .empty,
    file_path: ?[]u8 = null,
    file_fd: sys.fd_t = -1,

    /// Release all retained frames, path memory, and any open file descriptor.
    pub fn deinit(self: *Recorder, allocator: Allocator) void {
        self.closeFile();
        self.clearFrames(allocator);
        self.frames.deinit(allocator);
        if (self.file_path) |p| allocator.free(p);
        self.* = .{};
    }

    fn closeFile(self: *Recorder) void {
        if (self.file_fd >= 0) {
            sys.close(self.file_fd);
            self.file_fd = -1;
        }
    }

    fn clearFrames(self: *Recorder, allocator: Allocator) void {
        for (self.frames.items) |frame| allocator.free(frame.bytes);
        self.frames.clearRetainingCapacity();
        self.ring_bytes = 0;
        assert(self.ring_bytes == 0);
    }

    /// Start a fresh recording session. Fails with `RecordingActive` if active.
    pub fn start(
        self: *Recorder,
        allocator: Allocator,
        io: std.Io,
        rows: u16,
        cols: u16,
        opts: StartOptions,
    ) !void {
        if (self.active) return error.RecordingActive;
        assert(rows >= 1 and cols >= 1);
        const cap = @min(@max(opts.max_bytes, 1), hard_max_bytes);
        const owned_path = if (opts.path) |p| blk: {
            if (p.len == 0 or !std.fs.path.isAbsolute(p) or std.mem.indexOfScalar(u8, p, 0) != null) {
                return error.InvalidParams;
            }
            break :blk try allocator.dupe(u8, p);
        } else null;
        errdefer if (owned_path) |p| allocator.free(p);

        const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
        const mono_ns = std.Io.Clock.awake.now(io).nanoseconds;
        var fd: sys.fd_t = -1;
        var header_written: u64 = 0;
        if (owned_path) |p| {
            fd = openRecordingFile(p) catch return error.InputOutput;
            errdefer sys.close(fd);
            var hdr_buf: [160]u8 = undefined;
            const hdr = formatHeader(&hdr_buf, cols, rows, @divFloor(now_ms, 1000));
            sys.writeAll(fd, hdr) catch return error.InputOutput;
            header_written = hdr.len;
        }

        self.closeFile();
        self.clearFrames(allocator);
        if (self.file_path) |old| allocator.free(old);
        self.file_path = owned_path;
        self.file_fd = fd;
        self.active = true;
        self.started_mono_ns = mono_ns;
        self.started_at_ms = now_ms;
        self.initial_rows = rows;
        self.initial_cols = cols;
        self.max_bytes = cap;
        self.bytes_written = header_written;
        assert(self.active);
    }

    /// Stop the active recording and flush/close any open file descriptor.
    pub fn stop(self: *Recorder) void {
        self.active = false;
        self.closeFile();
        assert(!self.active and self.file_fd == -1);
    }

    /// Record one output chunk under the session mutex. Drops oldest ring frames
    /// when `max_bytes` or `max_ring_frames` would be exceeded.
    pub fn recordChunk(self: *Recorder, allocator: Allocator, io: std.Io, data: []const u8) void {
        if (!self.active or data.len == 0) return;
        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
        const rel_ns: u64 = if (now_ns > self.started_mono_ns) @intCast(now_ns - self.started_mono_ns) else 0;

        if (self.file_fd >= 0) {
            self.writeFrameToFile(allocator, rel_ns, data);
        }
        self.appendRingFrame(allocator, rel_ns, data);
    }

    fn appendRingFrame(self: *Recorder, allocator: Allocator, rel_ns: u64, data: []const u8) void {
        const keep = if (data.len > self.max_bytes) data[data.len - self.max_bytes ..] else data;
        assert(keep.len <= self.max_bytes);
        while (self.frames.items.len >= max_ring_frames or self.ring_bytes + keep.len > self.max_bytes) {
            if (self.frames.items.len == 0) break;
            const oldest = self.frames.orderedRemove(0);
            assert(self.ring_bytes >= oldest.bytes.len);
            self.ring_bytes -= oldest.bytes.len;
            allocator.free(oldest.bytes);
        }
        const copy = allocator.dupe(u8, keep) catch |err| {
            log.debug("recording_ring_oom", .{ .err = err });
            return;
        };
        self.frames.append(allocator, .{ .rel_ns = rel_ns, .bytes = copy }) catch |err| {
            allocator.free(copy);
            log.debug("recording_frame_append_oom", .{ .err = err });
            return;
        };
        self.ring_bytes += copy.len;
        if (self.file_fd < 0) self.bytes_written += copy.len;
    }

    fn writeFrameToFile(self: *Recorder, allocator: Allocator, rel_ns: u64, data: []const u8) void {
        assert(self.file_fd >= 0);
        if (self.bytes_written >= self.max_bytes) return;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        writeEventLine(&out.writer, rel_ns, data) catch return;
        const line = out.written();
        if (self.bytes_written + line.len > self.max_bytes) return;
        sys.writeAll(self.file_fd, line) catch |err| {
            log.warn("recording_file_write_failed", .{ .err = err });
            self.closeFile();
            return;
        };
        self.bytes_written += line.len;
    }

    /// Format the retained in-memory frames as a complete asciicast v2 NDJSON document.
    pub fn exportAsciicast(self: *const Recorder, allocator: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256 + self.ring_bytes);
        errdefer out.deinit();
        var hdr_buf: [160]u8 = undefined;
        const ts_sec: i64 = if (self.started_at_ms) |ms| @divFloor(ms, 1000) else 0;
        const hdr = formatHeader(&hdr_buf, self.initial_cols, self.initial_rows, ts_sec);
        try out.writer.writeAll(hdr);
        for (self.frames.items) |frame| {
            try writeEventLine(&out.writer, frame.rel_ns, frame.bytes);
        }
        return out.toOwnedSlice();
    }
};

/// Start asciicast v2 recording on `self`.
pub fn startRecording(self: *NativeSession, opts: StartOptions) !RecordStatus {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const rows = self.vt.rows();
    const cols = self.vt.cols();
    try self.recorder.start(self.allocator, self.io, rows, cols, opts);
    return statusLocked(self, self.allocator);
}

/// Stop any active asciicast v2 recording on `self`.
pub fn stopRecording(self: *NativeSession, allocator: Allocator) !RecordStatus {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.recorder.stop();
    return statusLocked(self, allocator);
}

/// Inspect the current recording status of `self`.
pub fn recordingStatus(self: *NativeSession, allocator: Allocator) !RecordStatus {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return statusLocked(self, allocator);
}

/// Export the bounded in-memory recording ring as valid asciicast v2 NDJSON.
pub fn exportAsciicast(self: *NativeSession, allocator: Allocator) ![]u8 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.recorder.exportAsciicast(allocator);
}

fn statusLocked(self: *const NativeSession, allocator: Allocator) !RecordStatus {
    const path = if (self.recorder.file_path) |p| try allocator.dupe(u8, p) else null;
    return .{
        .recording = self.recorder.active,
        .path = path,
        .bytes_written = self.recorder.bytes_written,
        .started_at_ms = self.recorder.started_at_ms,
    };
}

fn openRecordingFile(path: []const u8) !sys.fd_t {
    const flags: std.c.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    };
    const fd = try sys.open(path, flags, 0o600);
    assert(fd >= 0);
    return fd;
}

fn formatHeader(buf: *[160]u8, cols: u16, rows: u16, timestamp_sec: i64) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"version\":2,\"width\":{d},\"height\":{d},\"timestamp\":{d}}}\n",
        .{ cols, rows, timestamp_sec },
    ) catch buf[0..0];
}

fn writeEventLine(w: *std.Io.Writer, rel_ns: u64, data: []const u8) !void {
    const secs = rel_ns / std.time.ns_per_s;
    const micros = (rel_ns % std.time.ns_per_s) / std.time.ns_per_us;
    try w.print("[{d}.{d:0>6},\"o\",", .{ secs, micros });
    try protocol.writeJsonStringLossy(w, data);
    try w.writeAll("]\n");
}

test "Recorder captures bounded frames and exports valid asciicast v2 NDJSON" {
    const allocator = std.testing.allocator;
    var rec: Recorder = .{};
    defer rec.deinit(allocator);

    try rec.start(allocator, std.testing.io, 24, 80, .{ .max_bytes = 32 });
    try std.testing.expectError(error.RecordingActive, rec.start(allocator, std.testing.io, 24, 80, .{}));

    rec.recordChunk(allocator, std.testing.io, "hello\r\n");
    rec.recordChunk(allocator, std.testing.io, "world\r\n");
    rec.stop();

    const cast = try rec.exportAsciicast(allocator);
    defer allocator.free(cast);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cast, "\n"), '\n');
    const hdr_line = lines.next().?;
    var hdr = try std.json.parseFromSlice(std.json.Value, allocator, hdr_line, .{});
    defer hdr.deinit();
    try std.testing.expectEqual(@as(i64, 2), hdr.value.object.get("version").?.integer);
    try std.testing.expectEqual(@as(i64, 80), hdr.value.object.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 24), hdr.value.object.get("height").?.integer);

    const ev1_line = lines.next().?;
    var ev1 = try std.json.parseFromSlice(std.json.Value, allocator, ev1_line, .{});
    defer ev1.deinit();
    try std.testing.expectEqualStrings("o", ev1.value.array.items[1].string);
    try std.testing.expectEqualStrings("hello\r\n", ev1.value.array.items[2].string);
}

test "NativeSession streams asciicast v2 recording to file and in-memory ring" {
    const harness = @import("harness.zig");
    if (!harness.supported_os) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var rec: harness.Recorder = .{};
    defer rec.deinit();
    const native = try NativeSession.create(allocator, std.testing.io, .{
        .id = "rec-live-test",
        .shell = "/bin/sh",
        .command = "exec cat",
        .rows = 12,
        .cols = 40,
        .event_sink = rec.sink(),
    });
    defer native.destroy();

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/zmux-rec-test-{d}.cast", .{native.handle.child_pid});
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch |err| {
        log.debug("test_rec_delete_failed", .{ .err = err });
    };

    var st1 = try native.startRecording(.{ .path = path, .max_bytes = 64 * 1024 });
    defer st1.deinit(allocator);
    try std.testing.expect(st1.recording);
    try std.testing.expectEqualStrings(path, st1.path.?);
    try std.testing.expectError(error.RecordingActive, native.startRecording(.{}));

    try native.send("RECORDED_LINE", true);
    try rec.waitForOutput("RECORDED_LINE", 5_000);

    var st2 = try native.stopRecording(allocator);
    defer st2.deinit(allocator);
    try std.testing.expect(!st2.recording);
    try std.testing.expect(st2.bytes_written > 0);

    const exported = try native.exportAsciicast(allocator);
    defer allocator.free(exported);
    try std.testing.expect(std.mem.indexOf(u8, exported, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported, "RECORDED_LINE") != null);

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    var file_buf: [4096]u8 = undefined;
    const n = try file.readPositionalAll(std.testing.io, &file_buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, file_buf[0..n], "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_buf[0..n], "RECORDED_LINE") != null);
}
