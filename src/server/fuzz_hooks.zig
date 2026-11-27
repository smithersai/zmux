const std = @import("std");
const assert = std.debug.assert;
const mux = @import("../mux.zig");
const sys = @import("../sys.zig");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const server_mod = @import("../server.zig");
const connection_mod = @import("connection.zig");
const dispatch_mod = @import("dispatch.zig");
const limits_mod = @import("limits.zig");
const params_mod = @import("params.zig");
const payload_mod = @import("payload.zig");
const rpc_session_mod = @import("rpc_session.zig");
const socket_io_mod = @import("socket_io.zig");
const ClientConnection = connection_mod.ClientConnection;
const CreateArgsOptions = params_mod.CreateArgsOptions;
const MuxCreateArgs = params_mod.MuxCreateArgs;
const Payload = payload_mod.Payload;
const Server = server_mod.Server;
const attach_replay_max_bytes = limits_mod.attach_replay_max_bytes;
const axisParam = params_mod.axisParam;
const base64Decode = rpc_session_mod.base64Decode;
const base64Encode = rpc_session_mod.base64Encode;
const broadcast_queue_max_bytes = limits_mod.broadcast_queue_max_bytes;
const clientIdParam = params_mod.clientIdParam;
const control_queue_max_bytes = limits_mod.control_queue_max_bytes;
const dimensionParam = params_mod.dimensionParam;
const envEntriesFromParams = params_mod.envEntriesFromParams;
const errorMappingFor = dispatch_mod.errorMappingFor;
const freeStringSlice = params_mod.freeStringSlice;
const max_request_bytes = limits_mod.max_request_bytes;
const monotonicSeconds = socket_io_mod.monotonicSeconds;
const muxCreateArgsFromParams = params_mod.muxCreateArgsFromParams;
const optionalBool = params_mod.optionalBool;
const optionalInt = params_mod.optionalInt;
const paneIdParam = params_mod.paneIdParam;
const scrollbackBytesFromParams = params_mod.scrollbackBytesFromParams;
const sessionIdParam = params_mod.sessionIdParam;
const truncatedReplay = rpc_session_mod.truncatedReplay;
const windowIdParam = params_mod.windowIdParam;

/// Internal hooks exposed for the repository's own fuzz suites.
pub const fuzz_hooks = struct {
    pub const Connection = ClientConnection;
    pub const CreateArgs = MuxCreateArgs;
    pub const CreateArgsOpts = CreateArgsOptions;
    pub const max_request_size = max_request_bytes;
    pub const attach_replay_cap = attach_replay_max_bytes;
    pub const broadcast_queue_cap = broadcast_queue_max_bytes;
    pub const control_queue_cap = control_queue_max_bytes;

    pub const muxCreateArgs = muxCreateArgsFromParams;
    pub const envEntries = envEntriesFromParams;
    pub const freeEnvEntries = freeStringSlice;
    pub const scrollbackBytes = scrollbackBytesFromParams;
    pub const axis = axisParam;
    pub const sessionId = sessionIdParam;
    pub const paneId = paneIdParam;
    pub const windowId = windowIdParam;
    pub const clientId = clientIdParam;
    pub const boolParamVal = optionalBool;
    pub const intParamVal = optionalInt;
    pub const dimensionVal = dimensionParam;
    pub const replayTail = truncatedReplay;
    pub const b64Encode = base64Encode;
    pub const b64Decode = base64Decode;
    pub const errorMapping = errorMappingFor;

    pub fn createConnection(allocator: Allocator, io: std.Io, fd: posix.fd_t) !*ClientConnection {
        const conn = try ClientConnection.create(allocator, io, fd, null);
        assert(conn.fd == fd);
        assert(conn.server == null);
        return conn;
    }

    pub fn releaseConnection(conn: *ClientConnection) void {
        conn.release();
    }

    pub fn closeConnection(conn: *ClientConnection) void {
        conn.close();
    }

    pub fn isConnectionClosed(conn: *const ClientConnection) bool {
        return conn.isClosed();
    }

    /// Queue a control notification. A terminal failure closes the
    /// connection, as `Server.deliver` does.
    pub fn enqueueBroadcast(conn: *ClientConnection, bytes: []const u8) !void {
        conn.enqueueBroadcast(bytes) catch |err| {
            if (err != error.ConnectionClosed) conn.close();
            return err;
        };
    }

    /// Queue a synthetic `pane_output` frame of `bytes` for `pane_id`.
    pub fn enqueuePaneOutput(conn: *ClientConnection, pane_id: []const u8, bytes: []const u8, offset: u64) !void {
        const owned = try conn.allocator.dupe(u8, bytes);
        errdefer conn.allocator.free(owned);
        const owned_pane = try conn.allocator.dupe(u8, pane_id);
        errdefer conn.allocator.free(owned_pane);
        assert(owned.len == bytes.len);
        assert(owned_pane.len == pane_id.len);
        const payload = try Payload.create(conn.allocator, owned, .{
            .pane_id = owned_pane,
            .data_len = bytes.len,
            .end_offset = offset + bytes.len,
        });
        defer payload.release();
        assert(payload.output != null);
        return conn.enqueue(payload);
    }

    /// Next queued frame without blocking; the caller frees it.
    pub fn takeQueuedWrite(conn: *ClientConnection) ?[]u8 {
        const payload = conn.tryTakeQueuedWrite() orelse return null;
        defer payload.release();
        return conn.allocator.dupe(u8, payload.bytes) catch null;
    }

    pub fn trackMuxClient(conn: *ClientConnection, client_id: []const u8, pane_id: []const u8) !void {
        return conn.trackMuxClient(client_id, pane_id);
    }

    pub fn untrackMuxClient(conn: *ClientConnection, client_id: []const u8) bool {
        return conn.untrackMuxClient(client_id);
    }

    pub fn wantsPaneOutput(conn: *ClientConnection, pane_id: []const u8) bool {
        return conn.wantsPaneOutput(pane_id);
    }

    /// Take every tracked mux client id; the caller frees each id and the list.
    pub fn takeMuxClients(conn: *ClientConnection) std.ArrayList([]u8) {
        var attachments = conn.takeMuxClients();
        defer attachments.deinit(conn.allocator);
        var ids: std.ArrayList([]u8) = .empty;
        ids.ensureTotalCapacityPrecise(conn.allocator, attachments.items.len) catch {
            for (attachments.items) |attachment| attachment.deinit(conn.allocator);
            return .empty;
        };
        for (attachments.items) |attachment| {
            conn.allocator.free(attachment.pane_id);
            ids.appendAssumeCapacity(attachment.client_id);
        }
        assert(ids.items.len == attachments.items.len);
        return ids;
    }

    /// Initialize a Server without binding a UNIX socket on disk so wire-level
    /// JSON-RPC fuzzers can drive `handleClient` over an in-memory socketpair.
    pub fn initInMemoryServer(allocator: Allocator, io: std.Io) !Server {
        const owned_socket_path = try allocator.dupe(u8, "/in-memory/zmux-fuzz.sock");
        assert(std.fs.path.isAbsolute(owned_socket_path));
        return .{
            .allocator = allocator,
            .io = io,
            .socket_path = owned_socket_path,
            .socket_stat = .{ .dev = 0, .ino = 0, .mode = 0, .uid = 0 },
            .listener_fd = -1,
            .manager = mux.Manager.init(allocator, io, null),
            .last_activity_seconds = std.atomic.Value(i64).init(monotonicSeconds(io)),
            .idle_timeout_seconds = 0,
        };
    }

    /// Route native session events through the server, as `run` does.
    pub fn enableEvents(server: *Server) void {
        server.installEventSinks();
    }

    pub fn deinitInMemoryServer(server: *Server) void {
        server.deinit();
    }

    /// Drive a single client connection synchronously until EOF / shutdown.
    /// Takes ownership of `client_fd` (closed when the connection is released,
    /// or here when the connection cannot be allocated).
    pub fn driveClient(server: *Server, client_fd: posix.fd_t) !void {
        const connection = ClientConnection.create(server.allocator, server.io, client_fd, server) catch |err| {
            sys.close(client_fd);
            return err;
        };
        defer connection.release();
        defer connection.close();
        assert(connection.server == server);

        if (!server.registerConnection(connection)) return;
        defer server.unregisterConnection(connection);

        server.handleClient(connection);
    }
};
