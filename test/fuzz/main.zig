//! Entry point for zmux's fast coverage-guided structured fuzz suite.
//!
//! Run corpus smoke tests:
//!   zig build test
//!   zig build fuzz
//!
//! Run coverage-guided fuzzing (bounded or continuous):
//!   zig build fuzz --fuzz=100K
//!   zig build fuzz --fuzz

comptime {
    _ = @import("buffer.zig");
    _ = @import("protocol.zig");
    _ = @import("line_reader.zig");
    _ = @import("log.zig");
    _ = @import("foreground.zig");
    _ = @import("native.zig");
    _ = @import("mux.zig");
    _ = @import("server.zig");
    _ = @import("connect.zig");
    _ = @import("daemon_sys.zig");
}
