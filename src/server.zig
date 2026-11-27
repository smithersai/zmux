const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mux = @import("mux.zig");
const socket_path_mod = @import("socket_path.zig");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const accept_mod = @import("server/accept.zig");
const dispatch_mod = @import("server/dispatch.zig");
const events_mod = @import("server/events.zig");
const fuzz_hooks_mod = @import("server/fuzz_hooks.zig");
const lifecycle_mod = @import("server/lifecycle.zig");
const rpc_agent_mod = @import("server/rpc_agent.zig");
const rpc_client_mod = @import("server/rpc_client.zig");
const rpc_layout_mod = @import("server/rpc_layout.zig");
const rpc_pane_mod = @import("server/rpc_pane.zig");
const rpc_screen_mod = @import("server/rpc_screen.zig");
const rpc_session_mod = @import("server/rpc_session.zig");
const startup_mod = @import("server/startup.zig");
const connection_mod = @import("server/connection.zig");
const socket_dir_mod = @import("server/socket_dir.zig");
const socket_io_mod = @import("server/socket_io.zig");
const test_support_mod = @import("server/test_support.zig");
const ClientConnection = connection_mod.ClientConnection;
const bindRawUnixListener = test_support_mod.bindRawUnixListener;
const defaultPeerEuid = socket_io_mod.defaultPeerEuid;
const dupCloexec = socket_dir_mod.dupCloexec;
const requireUnixSocketBind = test_support_mod.requireUnixSocketBind;
const socketExists = test_support_mod.socketExists;
const tempPath = test_support_mod.tempPath;
const test_io = test_support_mod.test_io;
const unlinkIfSame = socket_dir_mod.unlinkIfSame;

/// Largest response the server writes. Clients size their receive limit to
/// match; a larger result fails with `LimitExceeded` instead of a frame the
/// client would reject.
pub const max_response_bytes: usize = 16 * 1024 * 1024;

/// Most client connections served at once; also sizes the listen backlog.
pub const max_client_connections: usize = 256;

/// Longest socket path `bind(2)` accepts: `sun_path` minus its NUL terminator
/// (103 bytes on macOS, 107 on Linux).
pub const max_socket_path_len: usize = sys.max_unix_path_len;

/// JSON-RPC daemon over a private (0600) UNIX socket.
///
/// `init` binds the socket, `run` accepts connections until `daemon.shutdown`,
/// the idle timeout, or the shutdown probe stops it, and `deinit` releases
/// everything. Each connection gets a reader thread, plus a writer thread
/// once a notification is queued for it (`std.Thread`); `io` supplies their
/// mutexes and condition variables, the clocks, sleeps, and randomness. Pass
/// a thread-safe implementation such as `std.Io.Threaded`
/// (`std.process.Init.io` in `main`).
pub const Server = struct {
    pub const ShutdownProbe = *const fn () bool;
    pub const PeerEuidFn = *const fn (fd: posix.fd_t) ?sys.uid_t;

    allocator: Allocator,
    io: std.Io,
    /// Guards `connections` and `stopping`.
    mutex: std.Io.Mutex = .init,
    /// Orders every mux-client ownership transition: attach (manager attach
    /// plus connection tracking), detach, switch (manager, route, notice),
    /// and the detached-client drain. Lock order: `routing_mutex`, then a
    /// connection's `write_mutex`, then `manager.mutex`/`mutex`.
    routing_mutex: std.Io.Mutex = .init,
    socket_path: []u8,
    socket_stat: sys.Stat,
    /// Pinned parent directory of the socket; -1 for an in-memory server.
    socket_dir_fd: posix.fd_t = -1,
    /// True while this server's socket is the one published at `socket_path`.
    published: bool = false,
    listener_fd: posix.fd_t,
    manager: mux.Manager,
    connections: std.ArrayList(*ClientConnection) = .empty,
    /// `connections.items.len`, readable without `mutex`: events skip
    /// serialization entirely while nobody is connected.
    connected_clients: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Set under `mutex` when shutdown begins. A connection that tries to
    /// register afterwards is refused, so `waitForWorkers` cannot hang on a
    /// reader that nobody will close.
    stopping: bool = false,
    active_connections: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_writer_threads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    active_mutex: std.Io.Mutex = .init,
    active_condition: std.Io.Condition = .init,
    /// Monotonic (`.awake` clock) seconds of the last client activity.
    last_activity_seconds: std.atomic.Value(i64),
    idle_timeout_seconds: i64,
    shutdown_probe: ?ShutdownProbe = null,
    /// Events dropped instead of delivered (slow clients, oversized events).
    dropped_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Connections refused at admission (limit, credentials, thread spawn).
    rejected_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Working directory for a pane whose creator names none; null leaves
    /// the daemon's own. Borrowed: must outlive the server.
    default_cwd: ?[]const u8 = null,
    /// Spare descriptor held open while the server runs. When `accept` fails
    /// because the descriptor table is full, the server closes it and accepts
    /// once more, so one control connection (`daemon.ping`,
    /// `session.terminate`, `daemon.shutdown`) can still get in and free
    /// resources. Re-armed as soon as a descriptor is available again.
    spare_fd: posix.fd_t = -1,
    /// Connections admitted by giving up `spare_fd`.
    spare_fd_admissions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Test seam for the listener's `accept`.
    accept_fn: *const fn (listener_fd: posix.fd_t) sys.AcceptError!posix.fd_t = sys.accept,
    /// Seam for credential tests: the effective uid of a connected peer.
    peer_euid_fn: PeerEuidFn = defaultPeerEuid,
    /// Test seam: runs on the worker thread before the connection registers.
    before_register_hook: ?*const fn (server: *Server) void = null,

    /// Bind `socket_path` (absolute) and prepare to serve. A server with no
    /// live panes exits from `run` after `idle_timeout_seconds` without
    /// client activity; 0 or less disables the timeout.
    ///
    /// Fails before touching the filesystem with `error.EmptySocketPath`,
    /// `error.SocketPathContainsNul`, `error.SocketPathNotAbsolute`, or
    /// `error.SocketPathTooLong` for a path `bind(2)` can never accept.
    ///
    /// An existing entry at `socket_path` is never removed unless it is a
    /// stale socket owned by this user: a non-socket fails with
    /// `error.SocketPathNotSocket`, a foreign socket with `error.AccessDenied`,
    /// a live server with `error.AddressInUse`, and an undecidable probe with
    /// `error.ProbeInconclusive`.
    pub fn init(allocator: Allocator, io: std.Io, socket_path: []const u8, idle_timeout_seconds: i64) !Server {
        // Reject before touching the filesystem: a path that can never be
        // bound must not leave a parent directory or lock behind.
        try validateSocketPath(socket_path);
        assert(std.fs.path.isAbsolute(socket_path));
        const dir_fd = try openSocketParent(socket_path, socket_path_mod.processEnv);
        errdefer sys.close(dir_fd);
        assert(dir_fd >= 0);
        return initOwnedDir(allocator, io, dir_fd, socket_path, idle_timeout_seconds);
    }

    /// `init` in a socket directory the caller already opened and validated
    /// (with `openSocketParent`). `dir_fd` stays the caller's; the server
    /// keeps its own duplicate, so the caller's lock and PID files and this
    /// socket are always in the same directory, whatever happens to its
    /// name.
    pub fn initAt(
        allocator: Allocator,
        io: std.Io,
        dir_fd: posix.fd_t,
        socket_path: []const u8,
        idle_timeout_seconds: i64,
    ) !Server {
        assert(dir_fd >= 0);
        try validateSocketPath(socket_path);
        assert(socket_path.len <= max_socket_path_len);
        const owned_dir = try dupCloexec(dir_fd);
        assert(owned_dir >= 0);
        assert(owned_dir != dir_fd);
        errdefer sys.close(owned_dir);
        return initOwnedDir(allocator, io, owned_dir, socket_path, idle_timeout_seconds);
    }

    pub fn deinit(self: *Server) void {
        self.running.store(false, .seq_cst);
        self.unpublish();
        if (self.listener_fd >= 0) sys.close(self.listener_fd);
        self.shutdown();
        assert(!self.published);
        assert(self.active_connections.load(.seq_cst) == 0);
        self.releaseSpareFd();
        assert(self.spare_fd < 0);
        if (self.socket_dir_fd >= 0) sys.close(self.socket_dir_fd);
        self.manager.deinit();
        self.connections.deinit(self.allocator);
        self.allocator.free(self.socket_path);
    }

    /// Remove the socket file if it is still the one this server bound.
    /// Idempotent. The daemon calls it under its start lock so a starting
    /// daemon never observes a half-removed socket.
    pub fn unpublish(self: *Server) void {
        if (!self.published) return;
        self.published = false;
        if (self.socket_dir_fd < 0) return;
        assert(self.socket_path.len > 0);
        unlinkIfSame(self.socket_dir_fd, std.fs.path.basename(self.socket_path), self.socket_stat);
    }

    pub const validateSocketPath = startup_mod.validateSocketPath;
    pub const initOwnedDir = startup_mod.initOwnedDir;
    pub const run = accept_mod.run;
    pub const armSpareFd = accept_mod.armSpareFd;
    pub const releaseSpareFd = accept_mod.releaseSpareFd;
    pub const acceptWithSpareFd = accept_mod.acceptWithSpareFd;
    pub const admit = accept_mod.admit;
    pub const peerAllowed = accept_mod.peerAllowed;
    pub const writeConnectionLimitError = accept_mod.writeConnectionLimitError;
    pub const handleClientThread = accept_mod.handleClientThread;
    pub const handleClient = accept_mod.handleClient;
    pub const readFrame = accept_mod.readFrame;
    pub const shouldExitForIdle = lifecycle_mod.shouldExitForIdle;
    pub const anyAttachedClient = lifecycle_mod.anyAttachedClient;
    pub const shouldStop = lifecycle_mod.shouldStop;
    pub const touch = lifecycle_mod.touch;
    pub const installEventSinks = lifecycle_mod.installEventSinks;
    pub const handleRespawn = lifecycle_mod.handleRespawn;
    pub const shutdown = lifecycle_mod.shutdown;
    pub const beginStop = lifecycle_mod.beginStop;
    pub const registerConnection = lifecycle_mod.registerConnection;
    pub const unregisterConnection = lifecycle_mod.unregisterConnection;
    pub const detachConnectionClients = lifecycle_mod.detachConnectionClients;
    pub const findClientOwner = lifecycle_mod.findClientOwner;
    pub const takeClientOwner = lifecycle_mod.takeClientOwner;
    pub const drainDetachedClients = lifecycle_mod.drainDetachedClients;
    pub const addActiveWriter = lifecycle_mod.addActiveWriter;
    pub const finishActiveWriter = lifecycle_mod.finishActiveWriter;
    pub const finishActiveConnection = lifecycle_mod.finishActiveConnection;
    pub const waitForWorkers = lifecycle_mod.waitForWorkers;
    pub const dispatch = dispatch_mod.dispatch;
    pub const requiredSession = dispatch_mod.requiredSession;
    pub const reply = dispatch_mod.reply;
    pub const replyRaw = dispatch_mod.replyRaw;
    pub const replyOk = dispatch_mod.replyOk;
    pub const replySnapshot = dispatch_mod.replySnapshot;
    pub const writeResponse = dispatch_mod.writeResponse;
    pub const writeErrorFor = dispatch_mod.writeErrorFor;
    pub const createSession = rpc_layout_mod.createSession;
    pub const replyCreatedSession = rpc_layout_mod.replyCreatedSession;
    pub const undoCreate = rpc_layout_mod.undoCreate;
    pub const applyCreateDefaults = rpc_layout_mod.applyCreateDefaults;
    pub const snapshotMux = rpc_layout_mod.snapshotMux;
    pub const newWindow = rpc_layout_mod.newWindow;
    pub const splitPane = rpc_layout_mod.splitPane;
    pub const reserveCompactReply = rpc_layout_mod.reserveCompactReply;
    pub const replyPaneHandle = rpc_layout_mod.replyPaneHandle;
    pub const selectPane = rpc_layout_mod.selectPane;
    pub const selectWindow = rpc_layout_mod.selectWindow;
    pub const renameSession = rpc_layout_mod.renameSession;
    pub const renameWindow = rpc_layout_mod.renameWindow;
    pub const renamePane = rpc_layout_mod.renamePane;
    pub const respawnPane = rpc_layout_mod.respawnPane;
    pub const execCommand = rpc_layout_mod.execCommand;
    pub const attachCreateArgs = rpc_client_mod.attachCreateArgs;
    pub const attachMuxClient = rpc_client_mod.attachMuxClient;
    pub const detachMuxClient = rpc_client_mod.detachMuxClient;
    pub const switchMuxClient = rpc_client_mod.switchMuxClient;
    pub const listMuxClients = rpc_client_mod.listMuxClients;
    pub const subscribeEvents = rpc_client_mod.subscribeEvents;
    pub const bindKey = rpc_client_mod.bindKey;
    pub const dispatchKey = rpc_client_mod.dispatchKey;
    pub const listKeys = rpc_client_mod.listKeys;
    pub const terminateSession = rpc_session_mod.terminateSession;
    pub const listSessions = rpc_session_mod.listSessions;
    pub const infoSession = rpc_session_mod.infoSession;
    pub const resizeSession = rpc_session_mod.resizeSession;
    pub const captureSession = rpc_session_mod.captureSession;
    pub const sendSession = rpc_session_mod.sendSession;
    pub const sendKeySession = rpc_session_mod.sendKeySession;
    pub const screenSession = rpc_screen_mod.screenSession;
    pub const waitPane = rpc_agent_mod.waitPane;
    pub const execPane = rpc_agent_mod.execPane;
    pub const signalPane = rpc_agent_mod.signalPane;
    pub const recordPane = rpc_agent_mod.recordPane;
    pub const closePane = rpc_pane_mod.closePane;
    pub const closeWindow = rpc_pane_mod.closeWindow;
    pub const resizeSplit = rpc_pane_mod.resizeSplit;
    pub const zoomPane = rpc_pane_mod.zoomPane;
    pub const metadataPane = rpc_pane_mod.metadataPane;
    pub const setClientMode = rpc_pane_mod.setClientMode;
    pub const notifyClientDetached = events_mod.notifyClientDetached;
    pub const notifyConnection = events_mod.notifyConnection;
    pub const snapshotConnections = events_mod.snapshotConnections;
    pub const Snapshot = events_mod.Snapshot;
    pub const releaseSnapshot = events_mod.releaseSnapshot;
    pub const deliver = events_mod.deliver;
    pub const broadcastNotification = events_mod.broadcastNotification;
    pub const broadcastControl = events_mod.broadcastControl;
    pub const broadcastPaneOutput = events_mod.broadcastPaneOutput;
    pub const handleNativeEvent = events_mod.handleNativeEvent;
    pub const handleNativeOscEvent = events_mod.handleNativeOscEvent;
};

/// Open and validate the directory that holds a socket path; see
/// `server/startup.zig` for the full trust rules.
pub const openSocketParent = startup_mod.openSocketParent;

/// Internal hooks exposed for the repository's own fuzz suites.
pub const fuzz_hooks = fuzz_hooks_mod.fuzz_hooks;

test {
    std.testing.refAllDecls(@This());
    _ = @import("server/accept.zig");
    _ = @import("server/conn_queue.zig");
    _ = @import("server/conn_routes.zig");
    _ = @import("server/conn_writer.zig");
    _ = @import("server/connection.zig");
    _ = @import("server/dispatch.zig");
    _ = @import("server/events.zig");
    _ = @import("server/fuzz_hooks.zig");
    _ = @import("server/lifecycle.zig");
    _ = @import("server/limits.zig");
    _ = @import("server/params.zig");
    _ = @import("server/payload.zig");
    _ = @import("server/rpc_agent.zig");
    _ = @import("server/rpc_client.zig");
    _ = @import("server/rpc_layout.zig");
    _ = @import("server/rpc_pane.zig");
    _ = @import("server/rpc_screen.zig");
    _ = @import("server/rpc_session.zig");
    _ = @import("server/socket_bind.zig");
    _ = @import("server/socket_dir.zig");
    _ = @import("server/socket_io.zig");
    _ = @import("server/startup.zig");
    _ = @import("server/test_support.zig");
}

test "server deinit does not unlink a replacement socket" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-replaced-socket");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    try std.testing.expect(socketExists(socket_path));

    try std.Io.Dir.deleteFileAbsolute(test_io, socket_path);
    const replacement = try bindRawUnixListener(socket_path);
    defer sys.close(replacement);

    server.deinit();
    try std.testing.expect(socketExists(socket_path));
}

test "server deinit unlinks its owned socket, and unpublish is idempotent" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const socket_path = try tempPath(allocator, "zmx-owned-socket");
    defer allocator.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(test_io, socket_path) catch {};
    try requireUnixSocketBind(socket_path);

    var server = try Server.init(allocator, test_io, socket_path, 0);
    try std.testing.expect(socketExists(socket_path));

    server.unpublish();
    try std.testing.expect(!socketExists(socket_path));

    // A successor binds the same name; the first server must leave it alone.
    const successor = try bindRawUnixListener(socket_path);
    defer sys.close(successor);
    server.unpublish();
    server.deinit();
    try std.testing.expect(socketExists(socket_path));
}
