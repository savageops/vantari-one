const std = @import("std");
const protocol_types = @import("../shared/protocol/types.zig");

pub const default_cors_origin = "http://127.0.0.1:4310";

pub fn allowedCorsOrigin(origin: ?[]const u8) ?[]const u8 {
    const value = origin orelse return default_cors_origin;
    if (isLocalHttpOrigin(value)) return value;
    return null;
}

pub fn isTokenRequired(method: std.http.Method, path: []const u8) bool {
    if (method == .POST and std.mem.eql(u8, path, "/rpc")) return true;
    if (method == .GET and std.mem.eql(u8, path, "/events")) return true;
    return false;
}

pub fn tokenValid(expected: []const u8, provided: ?[]const u8) bool {
    const token = provided orelse return false;
    if (token.len != expected.len) return false;

    var diff: u8 = 0;
    for (token, expected) |left, right| {
        diff |= left ^ right;
    }
    return diff == 0;
}

pub fn redactAndAttachHandshake(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    bridge_token: []const u8,
) ![]u8 {
    const redacted = try redactSensitiveJsonPayload(allocator, payload_json);
    defer allocator.free(redacted);

    const trimmed = std.mem.trim(u8, redacted, " \r\n\t");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return allocator.dupe(u8, "{\"ok\":false,\"error\":\"InvalidBridgePayload\"}");
    }

    return std.fmt.allocPrint(
        allocator,
        "{s},\"bridge_token\":{f}}}",
        .{
            trimmed[0 .. trimmed.len - 1],
            std.json.fmt(bridge_token, .{}),
        },
    );
}

pub fn extractSessionId(allocator: std.mem.Allocator, params_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("session_id") orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

pub fn logAudit(method: []const u8, session_id: ?[]const u8) void {
    const action = auditAction(method) orelse return;
    if (session_id) |value| {
        std.debug.print("VAR1 bridge audit action={s} method={s} session_id={s}\n", .{
            action,
            method,
            value,
        });
        return;
    }

    std.debug.print("VAR1 bridge audit action={s} method={s}\n", .{
        action,
        method,
    });
}

pub fn logError(scope: []const u8, session_id: ?[]const u8, err: anyerror) void {
    if (session_id) |value| {
        std.debug.print("VAR1 bridge error scope={s} session_id={s} error={s}\n", .{
            scope,
            value,
            @errorName(err),
        });
        return;
    }

    std.debug.print("VAR1 bridge error scope={s} error={s}\n", .{
        scope,
        @errorName(err),
    });
}

pub fn auditAction(method: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, method, "auth/")) return "auth";
    if (std.mem.eql(u8, method, protocol_types.methods.session_create)) return "session_write";
    if (std.mem.eql(u8, method, protocol_types.methods.session_resume)) return "session_write";
    if (std.mem.eql(u8, method, protocol_types.methods.session_send)) return "session_write";
    if (std.mem.eql(u8, method, protocol_types.methods.session_compact)) return "session_write";
    if (std.mem.eql(u8, method, protocol_types.methods.session_cancel)) return "session_write";
    if (std.mem.eql(u8, method, protocol_types.methods.session_get)) return "session_read";
    if (std.mem.eql(u8, method, protocol_types.methods.session_list)) return "session_read";
    return null;
}

fn redactSensitiveJsonPayload(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch {
        return allocator.dupe(u8, "{\"ok\":false,\"error\":\"InvalidBridgePayload\"}");
    };
    defer parsed.deinit();

    redactSensitiveJsonValue(&parsed.value);
    return renderJsonAlloc(allocator, parsed.value);
}

fn redactSensitiveJsonValue(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (isSensitiveField(entry.key_ptr.*)) {
                    entry.value_ptr.* = .{ .string = "[redacted]" };
                    continue;
                }
                redactSensitiveJsonValue(entry.value_ptr);
            }
        },
        .array => |array| {
            for (array.items) |*item| redactSensitiveJsonValue(item);
        },
        else => {},
    }
}

fn isSensitiveField(field: []const u8) bool {
    return std.ascii.eqlIgnoreCase(field, "api_key") or
        std.ascii.eqlIgnoreCase(field, "access_token") or
        std.ascii.eqlIgnoreCase(field, "refresh_token") or
        std.ascii.eqlIgnoreCase(field, "authorization") or
        std.ascii.eqlIgnoreCase(field, "cookie") or
        std.ascii.eqlIgnoreCase(field, "set_cookie") or
        std.ascii.eqlIgnoreCase(field, "password") or
        std.ascii.eqlIgnoreCase(field, "secret");
}

fn isLocalHttpOrigin(origin: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    const scheme = origin[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return false;

    const authority = origin[scheme_end + 3 ..];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "/?#") != null) return false;

    if (std.mem.startsWith(u8, authority, "[")) {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        const host = authority[1..close];
        const suffix = authority[close + 1 ..];
        if (suffix.len != 0 and (suffix[0] != ':' or suffix.len == 1)) return false;
        return std.mem.eql(u8, host, "::1");
    }

    const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
    const host = authority[0..colon];
    if (colon < authority.len and colon + 1 == authority.len) return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost");
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

test "bridge access allows only explicit local http origins" {
    try std.testing.expectEqualStrings(default_cors_origin, allowedCorsOrigin(null).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", allowedCorsOrigin("http://127.0.0.1:5173").?);
    try std.testing.expectEqualStrings("http://localhost:5173", allowedCorsOrigin("http://localhost:5173").?);
    try std.testing.expectEqualStrings("http://[::1]:5173", allowedCorsOrigin("http://[::1]:5173").?);
    try std.testing.expect(allowedCorsOrigin("null") == null);
    try std.testing.expect(allowedCorsOrigin("https://example.com") == null);
    try std.testing.expect(allowedCorsOrigin("file://local/index.html") == null);
}

test "bridge access redacts health payload before attaching handshake token" {
    const payload = try redactAndAttachHandshake(
        std.testing.allocator,
        "{\"ok\":true,\"api_key\":\"sk-secret\",\"nested\":{\"authorization\":\"Bearer abc\",\"safe\":\"value\"}}",
        "token-1",
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "sk-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Bearer abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"api_key\":\"[redacted]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"authorization\":\"[redacted]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"bridge_token\":\"token-1\"") != null);
}

test "bridge access classifies audited rpc methods" {
    try std.testing.expectEqualStrings("auth", auditAction("auth/status").?);
    try std.testing.expectEqualStrings("session_write", auditAction(protocol_types.methods.session_send).?);
    try std.testing.expectEqualStrings("session_read", auditAction(protocol_types.methods.session_get).?);
    try std.testing.expect(auditAction(protocol_types.methods.health_get) == null);
}
