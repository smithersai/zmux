//! JSON-RPC error codes, the Zig error-name mapping table, and the
//! `error.data.kind` response envelope.

const std = @import("std");
const json_text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const assert = std.debug.assert;
const writeJsonStringLossy = json_text.writeJsonStringLossy;

/// JSON-RPC 2.0 error codes; `session_error` covers zmux domain failures.
pub const ErrorCode = struct {
    pub const parse_error = -32700;
    pub const invalid_request = -32600;
    pub const method_not_found = -32601;
    pub const invalid_params = -32602;
    pub const internal_error = -32603;
    pub const session_error = -32000;
};

/// Machine-readable error category sent in `error.data.kind`.
pub const ErrorKind = enum {
    parse,
    invalid_request,
    method_not_found,
    invalid_params,
    not_found,
    terminated,
    conflict,
    limit,
    spawn_failed,
    io,
    internal,
};

/// JSON-RPC error code and kind for one Zig error name.
pub const ErrorMapping = struct { code: i32, kind: ErrorKind };

/// Global error-name to JSON-RPC code table (review K0).
pub fn errorCodeFor(err: anyerror) ErrorMapping {
    const Entry = struct { names: []const []const u8, mapping: ErrorMapping };
    const C = ErrorCode;
    const e = struct {
        fn f(names: []const []const u8, code: i32, kind: ErrorKind) Entry {
            return .{ .names = names, .mapping = .{ .code = code, .kind = kind } };
        }
    }.f;
    const table = [_]Entry{
        e(&.{ "ParseError", "SyntaxError", "UnexpectedEndOfInput" }, C.parse_error, .parse),
        e(&.{
            "InvalidRequest", "InvalidId", "NestingTooDeep", "BatchUnsupported", "MessageTooLarge", "TruncatedFrame",
        }, C.invalid_request, .invalid_request),
        e(&.{"MethodNotFound"}, C.method_not_found, .method_not_found),
        e(&.{
            "InvalidParams",           "InvalidSpawnArgument", "UnknownKey",
            "ScrollbackBytesTooLarge", "InvalidName",          "InvalidAxis",
            "InvalidDimensions",       "InvalidRatio",         "InvalidSignal",
        }, C.invalid_params, .invalid_params),
        e(&.{
            "SessionNotFound", "WindowNotFound", "PaneNotFound", "ClientNotFound", "SplitNotFound",
        }, C.session_error, .not_found),
        e(&.{"SessionTerminated"}, C.session_error, .terminated),
        e(&.{
            "DuplicateSessionName", "NameShadowsId", "PaneRunning", "RecordingActive",
        }, C.session_error, .conflict),
        e(&.{"LimitExceeded"}, C.session_error, .limit),
        e(&.{ "OpenPtyFailed", "ForkFailed", "ChildSetupFailed", "SpawnFailed" }, C.session_error, .spawn_failed),
        e(&.{ "InputTimeout", "InputClosed", "BrokenPipe", "InputOutput", "WriteZero" }, C.session_error, .io),
    };
    const name = @errorName(err);
    inline for (table) |entry| {
        for (entry.names) |candidate| {
            if (std.mem.eql(u8, name, candidate)) return entry.mapping;
        }
    }
    return .{ .code = ErrorCode.internal_error, .kind = .internal };
}

/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":C,"message":"M","data":{"kind":"K"}}}`
pub fn errorWithKind(allocator: Allocator, id_json: []const u8, code: i32, message: []const u8, kind: ErrorKind) ![]u8 {
    assert(id_json.len > 0);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{},\"message\":",
        .{ id_json, code },
    );
    try writeJsonStringLossy(&out.writer, message);
    try out.writer.print(",\"data\":{{\"kind\":\"{s}\"}}}}}}\n", .{@tagName(kind)});
    assert(out.written().len > id_json.len);
    return out.toOwnedSlice();
}

test "errorCodeFor maps every K0 error name" {
    const Case = struct { err: anyerror, code: i32, kind: ErrorKind };
    const cases = [_]Case{
        .{ .err = error.ParseError, .code = -32700, .kind = .parse },
        .{ .err = error.SyntaxError, .code = -32700, .kind = .parse },
        .{ .err = error.UnexpectedEndOfInput, .code = -32700, .kind = .parse },
        .{ .err = error.InvalidRequest, .code = -32600, .kind = .invalid_request },
        .{ .err = error.InvalidId, .code = -32600, .kind = .invalid_request },
        .{ .err = error.NestingTooDeep, .code = -32600, .kind = .invalid_request },
        .{ .err = error.BatchUnsupported, .code = -32600, .kind = .invalid_request },
        .{ .err = error.MessageTooLarge, .code = -32600, .kind = .invalid_request },
        .{ .err = error.TruncatedFrame, .code = -32600, .kind = .invalid_request },
        .{ .err = error.MethodNotFound, .code = -32601, .kind = .method_not_found },
        .{ .err = error.InvalidParams, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidSpawnArgument, .code = -32602, .kind = .invalid_params },
        .{ .err = error.UnknownKey, .code = -32602, .kind = .invalid_params },
        .{ .err = error.ScrollbackBytesTooLarge, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidName, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidAxis, .code = -32602, .kind = .invalid_params },
        .{ .err = error.InvalidDimensions, .code = -32602, .kind = .invalid_params },
        .{ .err = error.SessionNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.WindowNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.PaneNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.ClientNotFound, .code = -32000, .kind = .not_found },
        .{ .err = error.SessionTerminated, .code = -32000, .kind = .terminated },
        .{ .err = error.DuplicateSessionName, .code = -32000, .kind = .conflict },
        .{ .err = error.NameShadowsId, .code = -32000, .kind = .conflict },
        .{ .err = error.PaneRunning, .code = -32000, .kind = .conflict },
        .{ .err = error.LimitExceeded, .code = -32000, .kind = .limit },
        .{ .err = error.OpenPtyFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.ForkFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.ChildSetupFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.SpawnFailed, .code = -32000, .kind = .spawn_failed },
        .{ .err = error.InputTimeout, .code = -32000, .kind = .io },
        .{ .err = error.InputClosed, .code = -32000, .kind = .io },
        .{ .err = error.BrokenPipe, .code = -32000, .kind = .io },
        .{ .err = error.InputOutput, .code = -32000, .kind = .io },
        .{ .err = error.WriteZero, .code = -32000, .kind = .io },
        .{ .err = error.OutOfMemory, .code = -32603, .kind = .internal },
        .{ .err = error.SomethingNobodyMapped, .code = -32603, .kind = .internal },
    };
    for (cases) |case| {
        const mapping = errorCodeFor(case.err);
        errdefer std.debug.print("error.{s}\n", .{@errorName(case.err)});
        try std.testing.expectEqual(case.code, mapping.code);
        try std.testing.expectEqual(case.kind, mapping.kind);
    }
}

test "errorWithKind emits the documented envelope" {
    const json = try errorWithKind(std.testing.allocator, "7", -32000, "PaneNotFound", .not_found);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32000,\"message\":\"PaneNotFound\",\"data\":{\"kind\":\"not_found\"}}}\n",
        json,
    );
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
}
