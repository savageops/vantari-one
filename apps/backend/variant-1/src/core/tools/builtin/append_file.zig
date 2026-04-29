const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "append_file",
    .description = "Append text to an existing workspace file or create it if it does not exist. JSON arguments require path and content.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Required workspace-relative file path to append to." },
    \\    "content": { "type": "string", "description": "Required text to append." }
    \\  },
    \\  "required": ["path", "content"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"notes/todo.md\",\"content\":\"beta\\n\"}",
    .usage_hint = "Use append_file for additive writes only. Use write_file instead when you need to replace the full file.",
};

pub const availability = module.AvailabilitySpec{};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    try fsutil.appendText(file_path, parsed.value.content);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nAPPENDED_BYTES {d}",
        .{ file_path, parsed.value.content.len },
    );
    defer allocator.free(summary);

    return module.okEnvelope(allocator, definition.name, summary);
}
