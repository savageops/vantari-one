const std = @import("std");
const types = @import("../../shared/types.zig");

pub const Error = error{
    EmptyToolName,
    InvalidToolName,
    MissingDescription,
    MissingParametersSchema,
    InvalidParametersSchema,
};

pub const ToolSource = enum {
    builtin,
    plugin,
};

pub const ToolSocket = struct {
    source: ToolSource,
    owner_id: []const u8,
    definition: types.ToolDefinition,
};

pub fn validateDefinition(allocator: std.mem.Allocator, definition: types.ToolDefinition) !void {
    try validateName(definition.name);
    if (std.mem.trim(u8, definition.description, " \t\r\n").len == 0) return Error.MissingDescription;
    if (std.mem.trim(u8, definition.parameters_json, " \t\r\n").len == 0) return Error.MissingParametersSchema;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, definition.parameters_json, .{}) catch {
        return Error.InvalidParametersSchema;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidParametersSchema;
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return Error.EmptyToolName;

    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or
            (char >= '0' and char <= '9') or
            char == '_';
        if (!ok) return Error.InvalidToolName;
    }
}

test "tool socket validates compact lowercase tool contracts" {
    const definition = types.ToolDefinition{
        .name = "read_file",
        .description = "Read a file.",
        .parameters_json = "{\"type\":\"object\",\"additionalProperties\":false}",
    };

    try validateDefinition(std.testing.allocator, definition);
    try std.testing.expectError(Error.InvalidToolName, validateName("ReadFile"));
    try std.testing.expectError(Error.InvalidParametersSchema, validateDefinition(std.testing.allocator, .{
        .name = "bad_schema",
        .description = "Bad schema.",
        .parameters_json = "[]",
    }));
}
