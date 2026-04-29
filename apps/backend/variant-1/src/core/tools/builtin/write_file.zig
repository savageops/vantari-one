const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "write_file",
    .description = "Create or overwrite a file inside the workspace. JSON arguments require path and content. Parent directories are created automatically for workspace-relative targets.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Required workspace-relative file path to create or overwrite." },
    \\    "content": { "type": "string", "description": "Required full file contents to write." }
    \\  },
    \\  "required": ["path", "content"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"notes/todo.md\",\"content\":\"alpha\\n\"}",
    .usage_hint = "Use write_file when you intend to replace the entire file contents. Paths must stay inside the workspace root.",
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

    try fsutil.writeText(file_path, parsed.value.content);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nBYTES {d}",
        .{ file_path, parsed.value.content.len },
    );
    defer allocator.free(summary);

    return module.okEnvelope(allocator, definition.name, summary);
}
