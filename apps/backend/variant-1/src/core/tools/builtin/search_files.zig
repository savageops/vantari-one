const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");
const registry = @import("../registry.zig");

pub const definition = types.ToolDefinition{
    .name = "search_files",
    .description = "Search file contents with iex under an existing workspace path. JSON arguments accept pattern plus optional path, glob, and max_results fields. Use list_files first when you do not know the path, and use read_file when you already know the file to inspect.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pattern": { "type": "string", "description": "Required iex expression or literal pattern to search for." },
    \\    "path": { "type": "string", "description": "Optional existing workspace-relative file or directory path to search. Defaults to the workspace root when omitted or set to ." },
    \\    "glob": { "type": "string", "description": "Optional wildcard filter on matched file paths, for example *.zig or src/*.zig." },
    \\    "max_results": { "type": "integer", "minimum": 1, "description": "Optional maximum number of matching lines to return." }
    \\  },
    \\  "required": ["pattern"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}",
    .usage_hint = "pattern is required. path must already exist inside the workspace. Use list_files first when unsure, and switch to read_file when you already know the target file.",
};

pub const availability = module.AvailabilitySpec{
    .dependency = .{
        .kind = .external_command,
        .name = "iex",
    },
};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    runner: module.CommandRunner,
) ![]u8 {
    try registry.ensureAvailable(allocator, execution_context.command_probe, definition.name);

    const Args = struct {
        pattern: []const u8,
        path: ?[]const u8 = null,
        glob: ?[]const u8 = null,
        max_results: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const search_path = try fsutil.resolveInWorkspace(
        allocator,
        execution_context.workspace_root,
        parsed.value.path orelse ".",
    );
    defer allocator.free(search_path);

    const max_results_value = parsed.value.max_results orelse 50;
    const scan_max_hits = if (parsed.value.glob != null) max_results_value * 5 else max_results_value;
    const max_results_string = try std.fmt.allocPrint(allocator, "{d}", .{scan_max_hits});
    defer allocator.free(max_results_string);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("iex");
    try argv.append("search");
    try argv.append("--json");
    try argv.append("--max-hits");
    try argv.append(max_results_string);
    try argv.append(parsed.value.pattern);
    try argv.append(search_path);

    var result = try runner.run(allocator, execution_context.workspace_root, argv.items);
    defer result.deinit(allocator);

    if (result.exit_code != 0) return module.Error.CommandFailed;

    const rendered_hits = try renderSearchHits(
        allocator,
        execution_context.workspace_root,
        result.stdout,
        parsed.value.glob,
        max_results_value,
    );
    defer allocator.free(rendered_hits);

    if (rendered_hits.len == 0) {
        return module.okEnvelope(allocator, definition.name, "No matches.");
    }

    return module.okEnvelope(allocator, definition.name, rendered_hits);
}

fn renderSearchHits(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    search_json: []const u8,
    glob: ?[]const u8,
    max_results: usize,
) ![]u8 {
    const SearchHit = struct {
        path: []const u8,
        line: usize,
        column: usize,
        preview: []const u8,
    };

    const SearchResponse = struct {
        hits: ?[]SearchHit = null,
    };

    var parsed = try std.json.parseFromSlice(SearchResponse, allocator, search_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.hits == null or parsed.value.hits.?.len == 0) {
        return allocator.dupe(u8, "");
    }

    const workspace_root_abs = try fsutil.resolveAbsolute(allocator, workspace_root);
    defer allocator.free(workspace_root_abs);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var emitted: usize = 0;
    for (parsed.value.hits.?) |hit| {
        const relative_path = try std.fs.path.relative(allocator, workspace_root_abs, hit.path);
        defer allocator.free(relative_path);

        const normalized_path = try normalizeSearchPathForMatch(allocator, relative_path);
        defer allocator.free(normalized_path);

        if (glob) |glob_pattern| {
            if (!globMatchesPath(glob_pattern, normalized_path)) continue;
        }

        if (emitted > 0) try output.writer().writeByte('\n');
        try output.writer().print("{s}:{d}:{s}", .{
            normalized_path,
            hit.line,
            std.mem.trim(u8, hit.preview, " \r\n"),
        });
        emitted += 1;
        if (emitted >= max_results) break;
    }

    return output.toOwnedSlice();
}

fn normalizeSearchPathForMatch(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    for (normalized) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return normalized;
}

fn globMatchesPath(glob_pattern: []const u8, normalized_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, glob_pattern, '/')) |_| {
        return wildcardMatch(glob_pattern, normalized_path);
    }

    const basename = std.fs.path.basename(normalized_path);
    return wildcardMatch(glob_pattern, basename);
}

fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_index: ?usize = null;
    var match_index: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len and (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index])) {
            pattern_index += 1;
            text_index += 1;
            continue;
        }

        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            match_index = text_index;
            pattern_index += 1;
            continue;
        }

        if (star_index) |star| {
            pattern_index = star + 1;
            match_index += 1;
            text_index = match_index;
            continue;
        }

        return false;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') : (pattern_index += 1) {}
    return pattern_index == pattern.len;
}
