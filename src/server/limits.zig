const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const server_mod = @import("../server.zig");
const max_socket_path_len = server_mod.max_socket_path_len;

/// Largest request frame, in bytes, the server reads before answering `LimitExceeded`.
pub const max_request_bytes = 1024 * 1024;

/// Cap the raw scrollback replay delivered on attach. 256 KiB comfortably
/// covers a TUI's visible state + a few screenfuls of history while keeping
/// the attach payload bounded. When scrollback is larger, only the tail
/// (most recent bytes) is replayed.
pub const attach_replay_max_bytes: usize = 256 * 1024;

/// Cap on `session.capture`. The response carries the bytes twice (`text` and
/// `textBase64`), so this keeps the frame under `max_response_bytes`.
pub const capture_max_bytes: usize = 4 * 1024 * 1024;

/// High-water mark for `pane_output` queued on one connection. Past it the
/// queued output is dropped and replaced by one `pane_output_dropped` notice
/// per pane; the connection stays open.
pub const broadcast_queue_max_bytes: usize = 1024 * 1024;

/// Cap on queued control notifications (everything except `pane_output`). A
/// connection that exceeds it is not reading at all and is disconnected.
pub const control_queue_max_bytes: usize = 4 * 1024 * 1024;

/// A single serialized event larger than this is dropped instead of queued,
/// so one oversized event can never count as backlog on every connection.
pub const max_event_bytes: usize = broadcast_queue_max_bytes;

/// Most payloads one writer-thread wakeup takes from the queue.
pub const writer_batch_max = 16;

/// Batches up to this size are copied into one buffer and written with a
/// single syscall.
pub const writer_coalesce_bytes = 64 * 1024;

/// `SO_SNDTIMEO` applied to every client socket so one blocked `send` cannot stall a writer.
pub const socket_send_timeout_seconds: isize = 2;

/// Overall budget for writing one frame to a client, on every platform.
pub const send_deadline_ms: i64 = 5000;

/// A new connection must deliver its first complete frame within this time.
pub const first_frame_deadline_ms: i64 = 10_000;

/// Once a frame has started arriving it must complete within this time.
pub const partial_frame_deadline_ms: i64 = 30_000;

/// Room for a compact mutation result (three generated ids, a generation, and
/// the envelope), reserved before the mutation commits.
pub const compact_reply_reserve_bytes: usize = 512;

/// Pause before retrying `accept` after a transient listener error.
pub const accept_backoff_ms: i64 = 50;

/// Budget for probing whether an existing socket still has a live server behind it.
pub const stale_probe_timeout_ms: i64 = 1000;

/// Name of the socket inside its private staging directory. Kept to one byte so
/// the staging path fits in `sun_path` for nearly every valid socket path.
pub const staged_socket_name = "s";

/// Name prefix of the private staging directory a socket is bound in before publication.
pub const staging_dir_prefix = ".zmux-";

/// Most random hex characters appended to `staging_dir_prefix`.
pub const staging_dir_random_hex_max = 8;

/// Fewest random hex characters that keep a staging directory name unguessable.
pub const staging_dir_random_hex_min = 4;

/// Name collisions tolerated before staging directory creation fails.
pub const staging_dir_attempts = 16;

/// Sent to the owning connection when another connection switches its client.
pub const client_switched_method = "client_switched";

/// Response bytes reserved for the capture reply's envelope and keys.
pub const capture_envelope_reserve_bytes: usize = 4096;

// Limits that must agree with each other, checked at compile time.
comptime {
    // A capture reply carries its text twice (raw and base64) plus the envelope.
    assert(capture_max_bytes * 2 + capture_envelope_reserve_bytes <= server_mod.max_response_bytes);
    assert(attach_replay_max_bytes <= broadcast_queue_max_bytes);
    assert(max_event_bytes <= broadcast_queue_max_bytes);
    assert(broadcast_queue_max_bytes <= control_queue_max_bytes);
    assert(staging_dir_random_hex_min <= staging_dir_random_hex_max);
    assert(staging_dir_random_hex_max % 2 == 0);
    assert(staging_dir_prefix.len + staged_socket_name.len < max_socket_path_len);
    assert(writer_batch_max > 0);
    assert(first_frame_deadline_ms <= partial_frame_deadline_ms);
}

test "max_socket_path_len matches the platform sun_path capacity" {
    const expected: usize = switch (builtin.os.tag) {
        .linux => 107,
        .macos, .ios, .tvos, .watchos, .visionos => 103,
        else => return error.SkipZigTest,
    };
    try std.testing.expectEqual(expected, max_socket_path_len);
}
