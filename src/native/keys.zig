//! tmux-style key names mapped to terminal input byte sequences.

const std = @import("std");
const session = @import("session.zig");
const control = @import("control.zig");
const assert = std.debug.assert;

// Single-byte control sequences for Ctrl-<letter>: C-a => 0x01 .. C-z => 0x1A.
// Stored in a container-level const so `ctrlKeySequence` can hand back a
// stable slice into read-only data rather than a dangling stack pointer.
const ctrl_key_sequences = blk: {
    var table: [26][1]u8 = undefined;
    var i: u8 = 0;
    while (i < 26) : (i += 1) table[i] = [1]u8{i + 1};
    break :blk table;
};

fn keyEql(key: []const u8, name: []const u8) bool {
    assert(name.len > 0);
    return std.ascii.eqlIgnoreCase(key, name);
}

// Parse tmux-style Ctrl-<letter> names ("C-a", "c-a") into their control byte.
fn ctrlKeySequence(key: []const u8) ?[]const u8 {
    if (key.len != 3) return null;
    if (key[0] != 'C' and key[0] != 'c') return null;
    if (key[1] != '-') return null;
    const c = key[2];
    if (!std.ascii.isAlphabetic(c)) return null;
    const index = std.ascii.toUpper(c) - 'A';
    assert(index < ctrl_key_sequences.len);
    return &ctrl_key_sequences[index];
}

/// Terminal byte sequence for a tmux-style key name (case-insensitive), such
/// as `Enter`, `C-a`, `ArrowUp`, or `F5`; null for an unknown name.
pub fn keySequence(key: []const u8) ?[]const u8 {
    if (ctrlKeySequence(key)) |sequence| return sequence;

    if (keyEql(key, "Enter") or keyEql(key, "Return")) return "\r";
    if (keyEql(key, "Tab")) return "\t";
    if (keyEql(key, "Backspace")) return "\x7f";
    if (keyEql(key, "Escape") or keyEql(key, "Esc")) return "\x1b";
    if (keyEql(key, "Space")) return " ";
    if (keyEql(key, "ArrowUp") or keyEql(key, "Up")) return "\x1b[A";
    if (keyEql(key, "ArrowDown") or keyEql(key, "Down")) return "\x1b[B";
    if (keyEql(key, "ArrowRight") or keyEql(key, "Right")) return "\x1b[C";
    if (keyEql(key, "ArrowLeft") or keyEql(key, "Left")) return "\x1b[D";
    if (keyEql(key, "Home")) return "\x1b[H";
    if (keyEql(key, "End")) return "\x1b[F";
    if (keyEql(key, "PageUp")) return "\x1b[5~";
    if (keyEql(key, "PageDown")) return "\x1b[6~";
    if (keyEql(key, "Insert")) return "\x1b[2~";
    if (keyEql(key, "Delete")) return "\x1b[3~";
    if (keyEql(key, "F1")) return "\x1bOP";
    if (keyEql(key, "F2")) return "\x1bOQ";
    if (keyEql(key, "F3")) return "\x1bOR";
    if (keyEql(key, "F4")) return "\x1bOS";
    if (keyEql(key, "F5")) return "\x1b[15~";
    if (keyEql(key, "F6")) return "\x1b[17~";
    if (keyEql(key, "F7")) return "\x1b[18~";
    if (keyEql(key, "F8")) return "\x1b[19~";
    if (keyEql(key, "F9")) return "\x1b[20~";
    if (keyEql(key, "F10")) return "\x1b[21~";
    if (keyEql(key, "F11")) return "\x1b[23~";
    if (keyEql(key, "F12")) return "\x1b[24~";
    return null;
}

test "native session key names map to terminal sequences" {
    try std.testing.expectEqualStrings("\x1b[A", keySequence("ArrowUp").?);
    try std.testing.expectEqualStrings("\r", keySequence("Enter").?);
    try std.testing.expect(keySequence("Unknown") == null);
}

test "native session key map covers ctrl, navigation, and function keys" {
    // Ctrl-<letter> control bytes.
    try std.testing.expectEqualStrings("\x01", keySequence("C-a").?);
    try std.testing.expectEqualStrings("\x03", keySequence("C-c").?);
    try std.testing.expectEqualStrings("\x04", keySequence("C-d").?);
    try std.testing.expectEqualStrings("\x1a", keySequence("C-z").?);
    try std.testing.expectEqualStrings("\x03", keySequence("c-C").?);

    // Navigation / editing keys.
    try std.testing.expectEqualStrings("\x1b[H", keySequence("Home").?);
    try std.testing.expectEqualStrings("\x1b[F", keySequence("End").?);
    try std.testing.expectEqualStrings("\x1b[5~", keySequence("PageUp").?);
    try std.testing.expectEqualStrings("\x1b[6~", keySequence("PageDown").?);
    try std.testing.expectEqualStrings("\x1b[2~", keySequence("Insert").?);
    try std.testing.expectEqualStrings("\x1b[3~", keySequence("Delete").?);
    try std.testing.expectEqualStrings(" ", keySequence("Space").?);

    // Function keys (xterm sequences).
    try std.testing.expectEqualStrings("\x1bOP", keySequence("F1").?);
    try std.testing.expectEqualStrings("\x1bOS", keySequence("F4").?);
    try std.testing.expectEqualStrings("\x1b[15~", keySequence("F5").?);
    try std.testing.expectEqualStrings("\x1b[21~", keySequence("F10").?);
    try std.testing.expectEqualStrings("\x1b[24~", keySequence("F12").?);

    // Case-insensitive matching keeps the original names working.
    try std.testing.expectEqualStrings("\r", keySequence("enter").?);
    try std.testing.expectEqualStrings("\x1b", keySequence("ESCAPE").?);

    // Unrecognized keys still return null.
    try std.testing.expect(keySequence("C-4") == null);
    try std.testing.expect(keySequence("F13") == null);
    try std.testing.expect(keySequence("Meta") == null);
}
