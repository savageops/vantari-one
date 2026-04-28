const std = @import("std");
const tool_sockets = @import("../tools/sockets.zig");

pub const Error = error{
    MissingPluginId,
    InvalidPluginId,
    MissingPluginVersion,
    MissingSocketName,
    InvalidSocketName,
    MissingSocketEntry,
};

pub const PluginSocketKind = enum {
    tool,
    provider,
    context,
    event,
};

pub const PluginSocket = struct {
    kind: PluginSocketKind,
    name: []const u8,
    entry: []const u8,
};

pub const PluginManifest = struct {
    id: []const u8,
    version: []const u8,
    sockets: []const PluginSocket = &.{},
};

pub fn validateManifest(manifest: PluginManifest) !void {
    try validatePluginId(manifest.id);
    if (std.mem.trim(u8, manifest.version, " \t\r\n").len == 0) return Error.MissingPluginVersion;

    for (manifest.sockets) |socket| {
        if (std.mem.trim(u8, socket.name, " \t\r\n").len == 0) return Error.MissingSocketName;
        if (std.mem.trim(u8, socket.entry, " \t\r\n").len == 0) return Error.MissingSocketEntry;
        if (socket.kind == .tool) {
            tool_sockets.validateName(socket.name) catch return Error.InvalidSocketName;
        }
    }
}

pub fn validatePluginId(id: []const u8) !void {
    if (id.len == 0) return Error.MissingPluginId;

    for (id) |char| {
        const ok = (char >= 'a' and char <= 'z') or
            (char >= '0' and char <= '9') or
            char == '-' or
            char == '_';
        if (!ok) return Error.InvalidPluginId;
    }
}

test "plugin manifest validates ids and declared sockets only" {
    const sockets = [_]PluginSocket{.{
        .kind = .tool,
        .name = "lookup_ticket",
        .entry = "tools/lookup_ticket",
    }};

    try validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = sockets[0..],
    });

    try std.testing.expectError(Error.InvalidPluginId, validateManifest(.{
        .id = "Tickets",
        .version = "0.1.0",
    }));

    try std.testing.expectError(Error.InvalidSocketName, validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = &.{.{
            .kind = .tool,
            .name = "lookup-ticket",
            .entry = "tools/lookup_ticket",
        }},
    }));
}
