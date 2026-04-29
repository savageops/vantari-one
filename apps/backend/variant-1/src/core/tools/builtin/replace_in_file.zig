const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "replace_in_file",
    .description = "Replace exact text in an existing workspace file. JSON arguments require path, old_text, and new_text, with optional replace_all for every match.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Required existing workspace-relative file path to edit." },
    \\    "old_text": { "type": "string", "description": "Required exact text to replace." },
    \\    "new_text": { "type": "string", "description": "Required replacement text." },
    \\    "replace_all": { "type": "boolean", "description": "When true, replace every match instead of only the first one." }
    \\  },
    \\  "required": ["path", "old_text", "new_text"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src/core/tools/runtime.zig\",\"old_text\":\"alpha\",\"new_text\":\"beta\",\"replace_all\":false}",
    .usage_hint = "replace_in_file performs exact string replacement, not regex replacement. Read the file first when you need to confirm the current text.",
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
        old_text: []const u8,
        new_text: []const u8,
        replace_all: bool = false,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    const original = try fsutil.readTextAlloc(allocator, file_path);
    defer allocator.free(original);

    const replace_result = try module.replaceText(
        allocator,
        original,
        parsed.value.old_text,
        parsed.value.new_text,
        parsed.value.replace_all,
    );
    defer allocator.free(replace_result.contents);

    if (replace_result.replacements == 0) return module.Error.PatternNotFound;

    try fsutil.writeText(file_path, replace_result.contents);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nREPLACEMENTS {d}",
        .{ file_path, replace_result.replacements },
    );
    defer allocator.free(summary);

    return module.okEnvelope(allocator, definition.name, summary);
}
