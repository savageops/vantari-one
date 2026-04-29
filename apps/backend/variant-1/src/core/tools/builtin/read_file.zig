const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "read_file",
    .description = "Read an existing file from the workspace. JSON arguments require path and optionally accept start_line and end_line. Line numbers are 1-based and inclusive.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Required existing workspace-relative file path to read." },
    \\    "start_line": { "type": "integer", "minimum": 1, "description": "Optional 1-based starting line." },
    \\    "end_line": { "type": "integer", "minimum": 1, "description": "Optional 1-based ending line." }
    \\  },
    \\  "required": ["path"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src/core/tools/runtime.zig\",\"start_line\":1,\"end_line\":80}",
    .usage_hint = "Pass a file path, not a directory. Use list_files to discover paths and search_files to locate matching files first.",
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
        start_line: ?usize = null,
        end_line: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.start_line != null and parsed.value.end_line != null and parsed.value.start_line.? > parsed.value.end_line.?) {
        return module.Error.InvalidArguments;
    }

    const file_path = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    const contents = try fsutil.readTextAlloc(allocator, file_path);
    defer allocator.free(contents);

    const selected = try module.renderLineRange(allocator, contents, parsed.value.start_line, parsed.value.end_line);
    defer allocator.free(selected);

    const content = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\n{s}",
        .{ file_path, selected },
    );
    defer allocator.free(content);

    return module.okEnvelope(allocator, definition.name, content);
}
