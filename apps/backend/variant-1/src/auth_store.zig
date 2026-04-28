const std = @import("std");
const fsutil = @import("fsutil.zig");

pub const Error = error{
    InvalidAuthState,
    MissingAuth,
    MissingProvider,
};

pub const AuthBootstrap = struct {
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    subscription_plan_id: ?[]const u8 = null,
    subscription_plan_label: ?[]const u8 = null,
    subscription_status: ?[]const u8 = null,
    subscription_source: ?[]const u8 = null,
};

pub const ResolvedAuth = struct {
    provider_id: []u8,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    subscription_plan_id: ?[]u8 = null,
    subscription_plan_label: ?[]u8 = null,
    subscription_status: ?[]u8 = null,

    pub fn deinit(self: ResolvedAuth, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
        if (self.subscription_plan_id) |value| allocator.free(value);
        if (self.subscription_plan_label) |value| allocator.free(value);
        if (self.subscription_status) |value| allocator.free(value);
    }
};

pub fn resolveOrSeed(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    bootstrap: ?AuthBootstrap,
) !ResolvedAuth {
    const path = try authFilePath(allocator, workspace_root);
    defer allocator.free(path);

    if (fsutil.fileExists(path)) {
        return readActiveProvider(allocator, path);
    }

    const seed = bootstrap orelse return Error.MissingAuth;
    try writeBootstrapAuthFile(allocator, path, seed);
    return cloneBootstrap(allocator, seed);
}

pub fn authFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "auth", "auth.json" });
}

fn readActiveProvider(allocator: std.mem.Allocator, path: []const u8) !ResolvedAuth {
    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidAuthState;
    const root = parsed.value.object;

    const active_provider_value = root.get("active_provider") orelse return Error.MissingProvider;
    if (active_provider_value != .string) return Error.InvalidAuthState;
    const active_provider = active_provider_value.string;

    const providers_value = root.get("providers") orelse return Error.MissingProvider;
    if (providers_value != .object) return Error.InvalidAuthState;

    const provider_value = providers_value.object.get(active_provider) orelse return Error.MissingProvider;
    if (provider_value != .object) return Error.InvalidAuthState;
    const provider_object = provider_value.object;

    const base_url = try cloneRequiredString(allocator, provider_object, "base_url");
    errdefer allocator.free(base_url);
    const api_key = try cloneRequiredString(allocator, provider_object, "api_key");
    errdefer allocator.free(api_key);
    const model = try cloneRequiredString(allocator, provider_object, "model");
    errdefer allocator.free(model);

    var subscription_plan_id: ?[]u8 = null;
    errdefer if (subscription_plan_id) |value| allocator.free(value);
    var subscription_plan_label: ?[]u8 = null;
    errdefer if (subscription_plan_label) |value| allocator.free(value);
    var subscription_status: ?[]u8 = null;
    errdefer if (subscription_status) |value| allocator.free(value);

    if (provider_object.get("subscription")) |subscription_value| {
        if (subscription_value == .object) {
            subscription_plan_id = try cloneOptionalString(allocator, subscription_value.object, "plan_id");
            subscription_plan_label = try cloneOptionalString(allocator, subscription_value.object, "plan_label");
            subscription_status = try cloneOptionalString(allocator, subscription_value.object, "status");
        }
    }

    return .{
        .provider_id = try allocator.dupe(u8, active_provider),
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .subscription_plan_id = subscription_plan_id,
        .subscription_plan_label = subscription_plan_label,
        .subscription_status = subscription_status,
    };
}

fn cloneBootstrap(allocator: std.mem.Allocator, bootstrap: AuthBootstrap) !ResolvedAuth {
    return .{
        .provider_id = try allocator.dupe(u8, bootstrap.provider_id),
        .base_url = try allocator.dupe(u8, bootstrap.base_url),
        .api_key = try allocator.dupe(u8, bootstrap.api_key),
        .model = try allocator.dupe(u8, bootstrap.model),
        .subscription_plan_id = if (bootstrap.subscription_plan_id) |value| try allocator.dupe(u8, value) else null,
        .subscription_plan_label = if (bootstrap.subscription_plan_label) |value| try allocator.dupe(u8, value) else null,
        .subscription_status = if (bootstrap.subscription_status) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneRequiredString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return Error.InvalidAuthState;
    if (value != .string) return Error.InvalidAuthState;
    return allocator.dupe(u8, value.string);
}

fn cloneOptionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

fn writeBootstrapAuthFile(allocator: std.mem.Allocator, path: []const u8, bootstrap: AuthBootstrap) !void {
    const now = std.time.milliTimestamp();

    var payload = std.array_list.Managed(u8).init(allocator);
    defer payload.deinit();

    var writer = payload.writer();
    try writer.writeAll("{\n  \"version\": 1,\n  \"active_provider\": ");
    try writeJsonString(writer, bootstrap.provider_id);
    try writer.writeAll(",\n  \"providers\": {\n    ");
    try writeJsonString(writer, bootstrap.provider_id);
    try writer.writeAll(": {\n      \"auth_type\": \"api_key\",\n      \"api_key\": ");
    try writeJsonString(writer, bootstrap.api_key);
    try writer.writeAll(",\n      \"base_url\": ");
    try writeJsonString(writer, bootstrap.base_url);
    try writer.writeAll(",\n      \"model\": ");
    try writeJsonString(writer, bootstrap.model);
    try writer.writeAll(",\n      \"subscription\": {\n        \"plan_id\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_plan_id);
    try writer.writeAll(",\n        \"plan_label\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_plan_label);
    try writer.writeAll(",\n        \"status\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_status);
    try writer.writeAll(",\n        \"source\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_source);
    try writer.print(",\n        \"last_verified_at_ms\": {d}\n      }}", .{now});
    try writer.print(",\n      \"updated_at_ms\": {d}\n    }}\n  }}\n}}\n", .{now});

    try fsutil.writeText(path, payload.items);
}

fn writeOptionalJsonString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
        return;
    }
    try writer.writeAll("null");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}
