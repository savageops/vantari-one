const builtin = @import("builtin");
const std = @import("std");

const module = @import("module.zig");
const list_files = @import("builtin/list_files.zig");
const search_files = @import("builtin/search_files.zig");
const read_file = @import("builtin/read_file.zig");
const write_file = @import("builtin/write_file.zig");
const append_file = @import("builtin/append_file.zig");
const replace_in_file = @import("builtin/replace_in_file.zig");
const agents = @import("builtin/agents.zig");

pub const AvailabilityStatus = enum {
    available,
    unavailable,
};

pub const ResolvedAvailability = struct {
    status: AvailabilityStatus,
    dependency: ?module.Dependency = null,
    dependency_available: ?bool = null,
    reason: ?[]const u8 = null,
};

const AvailabilityEntry = struct {
    name: []const u8,
    spec: module.AvailabilitySpec,
};

const availability_entries = [_]AvailabilityEntry{
    .{ .name = list_files.definition.name, .spec = list_files.availability },
    .{ .name = search_files.definition.name, .spec = search_files.availability },
    .{ .name = read_file.definition.name, .spec = read_file.availability },
    .{ .name = write_file.definition.name, .spec = write_file.availability },
    .{ .name = append_file.definition.name, .spec = append_file.availability },
    .{ .name = replace_in_file.definition.name, .spec = replace_in_file.availability },
    .{ .name = agents.definitions[0].name, .spec = agents.availability },
    .{ .name = agents.definitions[1].name, .spec = agents.availability },
    .{ .name = agents.definitions[2].name, .spec = agents.availability },
    .{ .name = agents.definitions[3].name, .spec = agents.availability },
};

pub fn availabilitySpec(tool_name: []const u8) module.AvailabilitySpec {
    for (availability_entries) |entry| {
        if (std.mem.eql(u8, tool_name, entry.name)) return entry.spec;
    }
    return .{};
}

pub fn resolveAvailability(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
) !ResolvedAvailability {
    const spec = availabilitySpec(tool_name);
    const dependency = spec.dependency orelse return .{ .status = .available };

    const dependency_available = switch (dependency.kind) {
        .none => true,
        .external_command => try commandExists(allocator, probe, dependency.name),
    };

    return .{
        .status = if (dependency_available) .available else .unavailable,
        .dependency = dependency,
        .dependency_available = dependency_available,
        .reason = if (dependency_available) null else "required dependency is unavailable",
    };
}

pub fn ensureAvailable(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
) !void {
    const resolved = try resolveAvailability(allocator, probe, tool_name);
    if (resolved.status == .unavailable) return error.ToolUnavailable;
}

pub fn renderAvailabilityJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
) !void {
    const resolved = try resolveAvailability(allocator, probe, tool_name);
    try writer.writeAll("{\"status\":");
    try writer.print("{f}", .{std.json.fmt(statusLabel(resolved.status), .{})});

    if (resolved.reason) |reason| {
        try writer.writeAll(",\"reason\":");
        try writer.print("{f}", .{std.json.fmt(reason, .{})});
    }

    try writer.writeAll(",\"dependencies\":[");
    if (resolved.dependency) |dependency| {
        try writer.writeAll("{\"kind\":");
        try writer.print("{f}", .{std.json.fmt(dependencyKindLabel(dependency.kind), .{})});
        try writer.writeAll(",\"name\":");
        try writer.print("{f}", .{std.json.fmt(dependency.name, .{})});
        if (resolved.dependency_available) |available| {
            try writer.writeAll(",\"available\":");
            try writer.writeAll(if (available) "true" else "false");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn commandExists(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    command_name: []const u8,
) !bool {
    if (probe) |value| return value.commandExists(allocator, command_name);
    return defaultCommandExists(allocator, command_name);
}

fn defaultCommandExists(allocator: std.mem.Allocator, command_name: []const u8) !bool {
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "where.exe", command_name }
    else
        &[_][]const u8{ "which", command_name };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

pub fn statusLabel(status: AvailabilityStatus) []const u8 {
    return switch (status) {
        .available => "available",
        .unavailable => "unavailable",
    };
}

pub fn dependencyKindLabel(kind: module.DependencyKind) []const u8 {
    return switch (kind) {
        .none => "none",
        .external_command => "external_command",
    };
}

test "availability registry is derived from builtin module definitions" {
    const search_spec = availabilitySpec(search_files.definition.name);
    try std.testing.expect(search_spec.dependency != null);
    try std.testing.expectEqual(module.DependencyKind.external_command, search_spec.dependency.?.kind);
    try std.testing.expectEqualStrings("iex", search_spec.dependency.?.name);

    const agent_spec = availabilitySpec(agents.definitions[0].name);
    try std.testing.expect(agent_spec.dependency == null);
}
