const std = @import("std");
const module = @import("module.zig");
const registry = @import("registry.zig");
const workspace_state_tools = @import("workspace_runtime.zig");
const types = @import("../../shared/types.zig");
const list_files = @import("builtin/list_files.zig");
const search_files = @import("builtin/search_files.zig");
const read_file = @import("builtin/read_file.zig");
const write_file = @import("builtin/write_file.zig");
const append_file = @import("builtin/append_file.zig");
const replace_in_file = @import("builtin/replace_in_file.zig");
const agents = @import("builtin/agents.zig");

// TODO: Keep the built-in tool surface small and high-signal.

pub const Error = module.Error;
pub const CommandOutput = module.CommandOutput;
pub const CommandRunner = module.CommandRunner;
pub const CommandProbe = module.CommandProbe;
pub const AgentService = module.AgentService;
pub const ExecutionContext = module.ExecutionContext;

const file_tool_definitions = [_]types.ToolDefinition{
    list_files.definition,
    search_files.definition,
    read_file.definition,
    write_file.definition,
    append_file.definition,
    replace_in_file.definition,
};

const agent_tool_definitions = agents.definitions;

const workspace_state_tool_definitions = workspace_state_tools.definitions;
const file_plus_workspace_state_tool_definitions = file_tool_definitions ++ workspace_state_tool_definitions;
const file_plus_agent_tool_definitions = file_tool_definitions ++ agent_tool_definitions;
const all_tool_definitions = file_plus_workspace_state_tool_definitions ++ agent_tool_definitions;

fn toolDefinitionByName(tool_name: []const u8) ?types.ToolDefinition {
    for (all_tool_definitions) |tool_definition| {
        if (std.mem.eql(u8, tool_definition.name, tool_name)) return tool_definition;
    }

    return null;
}

pub fn workspaceStateRelevant(prompt: []const u8) bool {
    const keywords = [_][]const u8{
        ".var",
        "init_workspace",
        "workspace state",
        "todo slice",
        "session record",
        "changelog",
        "worktree",
        "backup",
        "instruction ingestion",
        "AGENTS.md",
        "tool contracts",
        "memories.md",
    };

    for (keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(prompt, keyword) != null) return true;
    }

    return false;
}

pub fn builtinDefinitions(include_agent_tools: bool) []const types.ToolDefinition {
    return if (include_agent_tools) file_plus_agent_tool_definitions[0..] else file_tool_definitions[0..];
}

pub fn builtinDefinitionsForContext(execution_context: ExecutionContext) []const types.ToolDefinition {
    if (execution_context.workspace_state_enabled) {
        return if (execution_context.agent_service != null) all_tool_definitions[0..] else file_plus_workspace_state_tool_definitions[0..];
    }

    return builtinDefinitions(execution_context.agent_service != null);
}

pub fn renderCatalog(allocator: std.mem.Allocator, execution_context: ExecutionContext) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().print(
        \\VAR1 built-in tools
        \\Workspace root: {s}
        \\
    , .{execution_context.workspace_root});

    for (builtinDefinitionsForContext(execution_context)) |tool_definition| {
        try output.writer().print("- {s}: {s}\n", .{
            tool_definition.name,
            tool_definition.description,
        });
        const availability = try registry.resolveAvailability(allocator, execution_context.command_probe, tool_definition.name);
        try output.writer().print("  Availability: {s}\n", .{registry.statusLabel(availability.status)});
        if (availability.dependency) |dependency| {
            try output.writer().print("  Dependency: {s} {s}", .{
                registry.dependencyKindLabel(dependency.kind),
                dependency.name,
            });
            if (availability.dependency_available) |available| {
                try output.writer().print(" ({s})", .{if (available) "available" else "unavailable"});
            }
            try output.writer().writeByte('\n');
        }
        if (tool_definition.example_json) |example_json| {
            try output.writer().print("  Example JSON: {s}\n", .{example_json});
        }
        if (tool_definition.usage_hint) |usage_hint| {
            try output.writer().print("  Guidance: {s}\n", .{usage_hint});
        }
    }

    return output.toOwnedSlice();
}

pub fn renderCatalogJson(allocator: std.mem.Allocator, execution_context: ExecutionContext) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"workspace_root\":");
    try output.writer().print("{f}", .{std.json.fmt(execution_context.workspace_root, .{})});
    try output.writer().writeAll(",\"tools\":[");

    const definitions = builtinDefinitionsForContext(execution_context);
    for (definitions, 0..) |tool_definition, index| {
        if (index > 0) try output.writer().writeAll(",");

        try output.writer().writeAll("{\"name\":");
        try output.writer().print("{f}", .{std.json.fmt(tool_definition.name, .{})});
        try output.writer().writeAll(",\"description\":");
        try output.writer().print("{f}", .{std.json.fmt(tool_definition.description, .{})});
        try output.writer().writeAll(",\"parameters_schema\":");
        try output.writer().writeAll(tool_definition.parameters_json);

        if (tool_definition.example_json) |example_json| {
            try output.writer().writeAll(",\"contract_example\":");
            try output.writer().writeAll(example_json);
        }

        if (tool_definition.usage_hint) |usage_hint| {
            try output.writer().writeAll(",\"usage_hint\":");
            try output.writer().print("{f}", .{std.json.fmt(usage_hint, .{})});
        }

        try output.writer().writeAll(",\"availability\":");
        try registry.renderAvailabilityJson(output.writer(), allocator, execution_context.command_probe, tool_definition.name);

        try output.writer().writeAll("}");
    }

    try output.writer().writeAll("]}");
    return output.toOwnedSlice();
}

pub fn buildAgentSystemPrompt(allocator: std.mem.Allocator, execution_context: ExecutionContext) ![]u8 {
    const catalog = try renderCatalog(allocator, execution_context);
    defer allocator.free(catalog);
    const workspace_state_note = if (execution_context.workspace_state_enabled)
        "Workspace-state tools are enabled because this request is explicitly .var-state-related. Use init_workspace only when the canonical structure is missing or incomplete. Do not call todo_slice just to track the current run. If you call session_record with action:\"upsert\", provide session_name, status, and objective. If you call todo_slice with action:\"upsert\", provide category, todo_name, status, and objective."
    else
        "Workspace-state tools are not in the current catalog because this request is not explicitly .var-state-related. For normal coding work, use file tools and agent tools only, and do not invent extra workspace-state bookkeeping.";

    return std.fmt.allocPrint(
        allocator,
        \\You are VAR1, a coding kernel agent operating inside the workspace root `{s}`.
        \\Use the built-in tools whenever they help you inspect, search, create, or edit files.
        \\Tool arguments must be valid JSON objects that match the declared schema exactly and use only the documented keys.
        \\If a tool returns ok:false or includes a tool error hint, repair the call instead of repeating the same failing arguments.
        \\Use list_files to discover paths, search_files to search contents, read_file to inspect a known file, write_file to replace a file, append_file to add text, and replace_in_file for exact string swaps.
        \\If the request explicitly touches workspace process state, use the canonical .var tools instead of inventing a second ledger or runtime surface.
        \\{s}
        \\If agent tools are available, you may launch a bounded child VAR1 agent instead of doing all work yourself.
        \\Use agent_status for non-blocking child supervision. Use wait_agent only when you are ready to spend bounded time collecting a child result or current snapshot.
        \\Keep internal tool mechanics private in operator-facing responses. Do not expose raw tool names, tool-call ids, or ask the operator to run supervision commands unless they explicitly asked for tool documentation.
        \\When you delegate child runs, you own supervision. Continue supervising child lifecycle state until each required child reaches terminal state, and if children are still in flight provide this exact update: "I will continue once agents complete; if any fail, I will follow up."
        \\Never invent tool results. Never write outside the workspace root.
        \\Prefer precise, minimal edits over rewriting unrelated content.
        \\When you are done, return a direct final answer for the operator.
        \\
        \\{s}
    ,
        .{ execution_context.workspace_root, workspace_state_note, catalog },
    );
}

pub fn toolErrorHint(tool_name: []const u8, error_name: []const u8) ?[]const u8 {
    const is_schema_error = std.mem.eql(u8, error_name, "InvalidArguments") or
        std.mem.eql(u8, error_name, "MissingField") or
        std.mem.eql(u8, error_name, "UnexpectedToken");

    if (is_schema_error) {
        if (std.mem.eql(u8, tool_name, "todo_slice")) {
            return "Use valid JSON. todo_slice upsert requires category, todo_name, status, and objective. The current run already has a runtime-managed todo slice, so skip todo_slice unless you need a separate repo-level execution slice.";
        }

        if (std.mem.eql(u8, tool_name, "session_record")) {
            return "Use valid JSON. session_record upsert requires session_name, status, and objective.";
        }

        return "Arguments did not match the tool schema. Repair the JSON object and retry with only the declared fields.";
    }

    if (std.mem.eql(u8, error_name, "PathOutsideWorkspace")) {
        return "The requested path escaped the workspace root. Retry with a workspace-relative path only and never use .. or an absolute path.";
    }

    if (std.mem.eql(u8, error_name, "FileNotFound")) {
        if (std.mem.eql(u8, tool_name, "search_files")) {
            return "The search path or the iex executable was not found. Re-check the workspace-relative path with list_files, or switch to read_file if you already know the target file.";
        }
        if (std.mem.eql(u8, tool_name, "list_files")) {
            return "The requested path was not found. Omit path or use . for the workspace root, then retry with an existing workspace-relative path.";
        }
        if (std.mem.eql(u8, tool_name, "read_file")) {
            return "The requested file was not found. Use list_files or search_files to confirm the workspace-relative path before retrying.";
        }
        if (std.mem.eql(u8, tool_name, "replace_in_file")) {
            return "The requested file was not found. Confirm the existing workspace-relative file path with list_files or read_file before retrying.";
        }

        return "The requested workspace path or file was not found. Re-check the workspace-relative path before retrying.";
    }

    if (std.mem.eql(u8, error_name, "CommandFailed") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files failed. Confirm the search path with list_files and retry with a smaller, valid workspace-relative target, or switch to read_file if you already know the file.";
    }

    if (std.mem.eql(u8, error_name, "ToolUnavailable") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files is unavailable because its required iex executable dependency is not resolvable. Use list_files and read_file until capability availability reports search_files as available.";
    }

    return null;
}

pub fn renderToolCallSummary(allocator: std.mem.Allocator, tool_calls: []const types.ToolCall) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    for (tool_calls, 0..) |tool_call, index| {
        if (index > 0) try output.writer().writeAll(", ");
        try output.writer().writeAll(toolCallLogLabel(tool_call.name));
    }

    return output.toOwnedSlice();
}

pub fn toolCallLogLabel(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "launch_agent")) return "child_run_dispatch";
    if (std.mem.eql(u8, tool_name, "agent_status")) return "child_run_status_check";
    if (std.mem.eql(u8, tool_name, "wait_agent")) return "child_run_wait";
    if (std.mem.eql(u8, tool_name, "list_agents")) return "child_run_inventory";
    return tool_name;
}

pub fn renderExecutionError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    error_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"ok\":false,\"tool\":");
    try output.writer().print("{f}", .{std.json.fmt(tool_name, .{})});
    try output.writer().writeAll(",\"error\":");
    try output.writer().print("{f}", .{std.json.fmt(error_name, .{})});
    try output.writer().writeAll(",\"arguments_json\":");
    try output.writer().print("{f}", .{std.json.fmt(arguments_json, .{})});

    if (toolDefinitionByName(tool_name)) |tool_definition| {
        try output.writer().writeAll(",\"parameters_schema\":");
        try output.writer().writeAll(tool_definition.parameters_json);

        if (tool_definition.example_json) |example_json| {
            try output.writer().writeAll(",\"contract_example\":");
            try output.writer().print("{f}", .{std.json.fmt(example_json, .{})});
        }

        if (tool_definition.usage_hint) |usage_hint| {
            try output.writer().writeAll(",\"usage_hint\":");
            try output.writer().print("{f}", .{std.json.fmt(usage_hint, .{})});
        }
    }

    if (toolErrorHint(tool_name, error_name)) |hint| {
        try output.writer().writeAll(",\"hint\":");
        try output.writer().print("{f}", .{std.json.fmt(hint, .{})});
    }

    try output.writer().writeAll("}");
    return output.toOwnedSlice();
}

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    tool_call: types.ToolCall,
) ![]u8 {
    return executeWithRunner(allocator, execution_context, tool_call, .{
        .context = null,
        .runFn = runCommand,
    });
}

pub fn executeWithRunner(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    tool_call: types.ToolCall,
    runner: CommandRunner,
) ![]u8 {
    if (std.mem.eql(u8, tool_call.name, "list_files")) {
        return list_files.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "search_files")) {
        return search_files.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return read_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return write_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "append_file")) {
        return append_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "replace_in_file")) {
        return replace_in_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (workspace_state_tools.handles(tool_call.name)) {
        return workspace_state_tools.execute(allocator, execution_context.workspace_root, tool_call.name, tool_call.arguments_json, runner);
    }
    if (agents.handles(tool_call.name)) {
        return agents.execute(allocator, execution_context, tool_call.name, tool_call.arguments_json);
    }

    return Error.UnknownTool;
}

fn runCommand(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) anyerror!CommandOutput {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => return Error.CommandTerminated,
    };

    return .{
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

test "tool catalog includes the built-in coding tools" {
    const catalog = try renderCatalog(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "search_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "replace_in_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Example JSON: {\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "todo_slice") == null);
}
