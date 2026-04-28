const std = @import("std");
const fsutil = @import("fsutil.zig");
const harness_tools = @import("harness_tools.zig");
const types = @import("types.zig");

// TODO: Keep the built-in tool surface small and high-signal.

pub const Error = error{
    AgentServiceUnavailable,
    CommandFailed,
    CommandTerminated,
    InvalidArguments,
    MissingParentSession,
    PatternNotFound,
    UnknownTool,
};

pub const CommandOutput = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const CommandRunner = struct {
    context: ?*anyopaque,
    runFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) anyerror!CommandOutput,

    pub fn run(
        self: CommandRunner,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) anyerror!CommandOutput {
        return self.runFn(self.context, allocator, cwd, argv);
    }
};

pub const AgentService = struct {
    context: ?*anyopaque,
    launchFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        prompt: []const u8,
        name: ?[]const u8,
    ) anyerror![]u8,
    statusFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
    ) anyerror![]u8,
    waitFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
        timeout_ms: usize,
    ) anyerror![]u8,
    listFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror![]u8,

    pub fn launch(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        prompt: []const u8,
        name: ?[]const u8,
    ) anyerror![]u8 {
        return self.launchFn(self.context, allocator, parent_session_id, prompt, name);
    }

    pub fn status(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
    ) anyerror![]u8 {
        return self.statusFn(self.context, allocator, parent_session_id, agent_name);
    }

    pub fn wait(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
        timeout_ms: usize,
    ) anyerror![]u8 {
        return self.waitFn(self.context, allocator, parent_session_id, agent_name, timeout_ms);
    }

    pub fn list(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror![]u8 {
        return self.listFn(self.context, allocator, parent_session_id);
    }
};

pub const ExecutionContext = struct {
    workspace_root: []const u8,
    parent_session_id: ?[]const u8 = null,
    agent_service: ?AgentService = null,
    harness_tools_enabled: bool = false,
};

const file_tool_definitions = [_]types.ToolDefinition{
    .{
        .name = "list_files",
        .description = "List files under an existing workspace path. JSON arguments accept only optional path and max_results fields. Omit path or use \".\" for the workspace root. Use this before read_file or search_files when you do not know the exact path yet.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "path": { "type": "string", "description": "Optional existing workspace-relative file or directory path to list. Defaults to the workspace root when omitted or set to ." },
        \\    "max_results": { "type": "integer", "minimum": 1, "description": "Optional maximum number of paths to return." }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"path\":\"src\",\"max_results\":100}",
        .usage_hint = "Use an existing workspace-relative path only. Start with path:\".\" or omit path when you need workspace discovery.",
    },
    .{
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
    },
    .{
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
        .example_json = "{\"path\":\"src/tools.zig\",\"start_line\":1,\"end_line\":80}",
        .usage_hint = "Pass a file path, not a directory. Use list_files to discover paths and search_files to locate matching files first.",
    },
    .{
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
    },
    .{
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
    },
    .{
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
        .example_json = "{\"path\":\"src/tools.zig\",\"old_text\":\"alpha\",\"new_text\":\"beta\",\"replace_all\":false}",
        .usage_hint = "replace_in_file performs exact string replacement, not regex replacement. Read the file first when you need to confirm the current text.",
    },
};

const agent_tool_definitions = [_]types.ToolDefinition{
    .{
        .name = "launch_agent",
        .description = "Launch another VAR1 agent as a named child run. JSON arguments require prompt and optionally accept name. Use this only for a bounded child task you want the harness to execute separately.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt": { "type": "string", "description": "Required exact prompt for the child VAR1 agent to execute." },
        \\    "name": { "type": "string", "description": "Optional short display name for the child agent. Defaults to an auto-generated name." }
        \\  },
        \\  "required": ["prompt"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"prompt\":\"Inspect src/tools.zig and summarize search_files.\",\"name\":\"search-audit\"}",
        .usage_hint = "Keep the child prompt bounded and self-contained. Use the returned name for agent_status or wait_agent.",
    },
    .{
        .name = "agent_status",
        .description = "Inspect the latest status and journal-backed progress metadata for a named child agent without blocking. JSON arguments require name.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Required child agent name returned by launch_agent." }
        \\  },
        \\  "required": ["name"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"name\":\"search-audit\"}",
        .usage_hint = "Use agent_status for non-blocking supervision when you only need the current child snapshot.",
    },
    .{
        .name = "wait_agent",
        .description = "Wait up to timeout_ms for a named child agent. JSON arguments require name and optionally accept timeout_ms. If the child does not finish in time, the tool returns its current snapshot instead of failing.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Required child agent name returned by launch_agent." },
        \\    "timeout_ms": { "type": "integer", "minimum": 1, "description": "Optional timeout in milliseconds. Defaults to 30000." }
        \\  },
        \\  "required": ["name"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"name\":\"search-audit\",\"timeout_ms\":30000}",
        .usage_hint = "Use wait_agent only when you are ready to spend bounded time collecting a result or current snapshot.",
    },
    .{
        .name = "list_agents",
        .description = "List the child agents launched by the current parent task, including their names and statuses. JSON arguments must be an empty object.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{}",
        .usage_hint = "Do not invent arguments for list_agents. Call it with an empty JSON object only.",
    },
};

const harness_tool_definitions = harness_tools.definitions;
const file_plus_harness_tool_definitions = file_tool_definitions ++ harness_tool_definitions;
const file_plus_agent_tool_definitions = file_tool_definitions ++ agent_tool_definitions;
const all_tool_definitions = file_plus_harness_tool_definitions ++ agent_tool_definitions;

fn toolDefinitionByName(tool_name: []const u8) ?types.ToolDefinition {
    const lookup_name = canonicalToolName(tool_name);
    for (all_tool_definitions) |tool_definition| {
        if (std.mem.eql(u8, tool_definition.name, lookup_name)) return tool_definition;
    }

    return null;
}

fn canonicalToolName(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "rg_search")) return "search_files";
    return tool_name;
}

pub fn harnessToolsRelevant(prompt: []const u8) bool {
    const keywords = [_][]const u8{
        ".var",
        "init_harness",
        "harness_",
        "todo slice",
        "task record",
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
    if (execution_context.harness_tools_enabled) {
        return if (execution_context.agent_service != null) all_tool_definitions[0..] else file_plus_harness_tool_definitions[0..];
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

        try output.writer().writeAll("}");
    }

    try output.writer().writeAll("]}");
    return output.toOwnedSlice();
}

pub fn buildAgentSystemPrompt(allocator: std.mem.Allocator, execution_context: ExecutionContext) ![]u8 {
    const catalog = try renderCatalog(allocator, execution_context);
    defer allocator.free(catalog);
    const harness_note = if (execution_context.harness_tools_enabled)
        "Harness tools are enabled because this task is explicitly harness-related. Use init_harness only when the canonical structure is missing or incomplete. Do not call harness_todo just to track the current run. If you call harness_task with action:\"upsert\", provide task_name, status, and objective. If you call harness_todo with action:\"upsert\", provide category, task_name, status, and objective."
    else
        "Harness tools are not in the current catalog because this task is not explicitly harness-related. For normal coding work, use file tools and agent tools only, and do not invent extra harness bookkeeping.";

    return std.fmt.allocPrint(
        allocator,
        \\You are VAR1, a coding harness agent operating inside the workspace root `{s}`.
        \\Use the built-in tools whenever they help you inspect, search, create, or edit files.
        \\Tool arguments must be valid JSON objects that match the declared schema exactly and use only the documented keys.
        \\If a tool returns ok:false or includes a tool error hint, repair the call instead of repeating the same failing arguments.
        \\Use list_files to discover paths, search_files to search contents, read_file to inspect a known file, write_file to replace a file, append_file to add text, and replace_in_file for exact string swaps.
        \\If the task explicitly touches harness process state, use the canonical .var tools instead of inventing a second ledger or runtime surface.
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
        .{ execution_context.workspace_root, harness_note, catalog },
    );
}

pub fn toolErrorHint(tool_name: []const u8, error_name: []const u8) ?[]const u8 {
    const is_schema_error = std.mem.eql(u8, error_name, "InvalidArguments") or
        std.mem.eql(u8, error_name, "MissingField") or
        std.mem.eql(u8, error_name, "UnexpectedToken");

    if (is_schema_error) {
        if (std.mem.eql(u8, tool_name, "harness_todo")) {
            return "Use valid JSON. harness_todo upsert requires category, task_name, status, and objective. The current run already has a runtime-managed todo slice, so skip harness_todo unless you need a separate repo-level execution slice.";
        }

        if (std.mem.eql(u8, tool_name, "harness_task")) {
            return "Use valid JSON. harness_task upsert requires task_name, status, and objective.";
        }

        return "Arguments did not match the tool schema. Repair the JSON object and retry with only the declared fields.";
    }

    if (std.mem.eql(u8, error_name, "PathOutsideWorkspace")) {
        return "The requested path escaped the workspace root. Retry with a workspace-relative path only and never use .. or an absolute path.";
    }

    if (std.mem.eql(u8, error_name, "FileNotFound")) {
        if (std.mem.eql(u8, canonicalToolName(tool_name), "search_files")) {
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

    if (std.mem.eql(u8, error_name, "CommandFailed") and std.mem.eql(u8, canonicalToolName(tool_name), "search_files")) {
        return "search_files failed. Confirm the search path with list_files and retry with a smaller, valid workspace-relative target, or switch to read_file if you already know the file.";
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
    if (std.mem.eql(u8, tool_name, "rg_search")) return "search_files";
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
        return executeListFiles(allocator, execution_context.workspace_root, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "search_files") or std.mem.eql(u8, tool_call.name, "rg_search")) {
        return executeSearchFiles(allocator, execution_context.workspace_root, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return executeReadFile(allocator, execution_context.workspace_root, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return executeWriteFile(allocator, execution_context.workspace_root, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "append_file")) {
        return executeAppendFile(allocator, execution_context.workspace_root, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "replace_in_file")) {
        return executeReplaceInFile(allocator, execution_context.workspace_root, tool_call.arguments_json);
    }
    if (harness_tools.handles(tool_call.name)) {
        return harness_tools.execute(allocator, execution_context.workspace_root, tool_call.name, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "launch_agent")) {
        return executeLaunchAgent(allocator, execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "agent_status")) {
        return executeAgentStatus(allocator, execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "wait_agent")) {
        return executeWaitAgent(allocator, execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "list_agents")) {
        return executeListAgents(allocator, execution_context);
    }

    return Error.UnknownTool;
}

fn executeLaunchAgent(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return Error.MissingParentSession;

    const Args = struct {
        prompt: []const u8,
        name: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const content = try service.launch(
        allocator,
        parent_session_id,
        parsed.value.prompt,
        parsed.value.name,
    );
    defer allocator.free(content);

    return okEnvelope(allocator, "launch_agent", content);
}

fn executeAgentStatus(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return Error.MissingParentSession;

    const Args = struct {
        name: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const content = try service.status(allocator, parent_session_id, parsed.value.name);
    defer allocator.free(content);

    return okEnvelope(allocator, "agent_status", content);
}

fn executeWaitAgent(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return Error.MissingParentSession;

    const Args = struct {
        name: []const u8,
        timeout_ms: usize = 30_000,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const content = try service.wait(
        allocator,
        parent_session_id,
        parsed.value.name,
        parsed.value.timeout_ms,
    );
    defer allocator.free(content);

    return okEnvelope(allocator, "wait_agent", content);
}

fn executeListAgents(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
) ![]u8 {
    const service = execution_context.agent_service orelse return Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return Error.MissingParentSession;

    const content = try service.list(allocator, parent_session_id);
    defer allocator.free(content);

    return okEnvelope(allocator, "list_agents", content);
}

fn executeListFiles(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    _: CommandRunner,
) ![]u8 {
    const Args = struct {
        path: ?[]const u8 = null,
        max_results: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const search_path = try fsutil.resolveInWorkspace(
        allocator,
        workspace_root,
        parsed.value.path orelse ".",
    );
    defer allocator.free(search_path);

    const root_abs = try fsutil.resolveAbsolute(allocator, workspace_root);
    defer allocator.free(root_abs);

    const search_prefix = try std.fs.path.relative(allocator, root_abs, search_path);
    defer allocator.free(search_prefix);

    const listed = try collectFiles(allocator, search_path, search_prefix, parsed.value.max_results orelse 200);
    defer allocator.free(listed);

    return okEnvelope(allocator, "list_files", listed);
}

fn executeSearchFiles(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    runner: CommandRunner,
) ![]u8 {
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
        workspace_root,
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

    var result = try runner.run(allocator, workspace_root, argv.items);
    defer result.deinit(allocator);

    if (result.exit_code != 0) return Error.CommandFailed;

    const rendered_hits = try renderSearchHits(
        allocator,
        workspace_root,
        result.stdout,
        parsed.value.glob,
        max_results_value,
    );
    defer allocator.free(rendered_hits);

    if (rendered_hits.len == 0) {
        return okEnvelope(allocator, "search_files", "No matches.");
    }

    return okEnvelope(allocator, "search_files", rendered_hits);
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

fn executeReadFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
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
        return Error.InvalidArguments;
    }

    const file_path = try fsutil.resolveInWorkspace(allocator, workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    const contents = try fsutil.readTextAlloc(allocator, file_path);
    defer allocator.free(contents);

    const selected = try renderLineRange(allocator, contents, parsed.value.start_line, parsed.value.end_line);
    defer allocator.free(selected);

    const content = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\n{s}",
        .{ file_path, selected },
    );
    defer allocator.free(content);

    return okEnvelope(allocator, "read_file", content);
}

fn executeWriteFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try fsutil.resolveInWorkspace(allocator, workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    try fsutil.writeText(file_path, parsed.value.content);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nBYTES {d}",
        .{ file_path, parsed.value.content.len },
    );
    defer allocator.free(summary);

    return okEnvelope(allocator, "write_file", summary);
}

fn executeAppendFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try fsutil.resolveInWorkspace(allocator, workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    try fsutil.appendText(file_path, parsed.value.content);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nAPPENDED_BYTES {d}",
        .{ file_path, parsed.value.content.len },
    );
    defer allocator.free(summary);

    return okEnvelope(allocator, "append_file", summary);
}

fn executeReplaceInFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
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

    const file_path = try fsutil.resolveInWorkspace(allocator, workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    const original = try fsutil.readTextAlloc(allocator, file_path);
    defer allocator.free(original);

    const replace_result = try replaceText(
        allocator,
        original,
        parsed.value.old_text,
        parsed.value.new_text,
        parsed.value.replace_all,
    );
    defer allocator.free(replace_result.contents);

    if (replace_result.replacements == 0) return Error.PatternNotFound;

    try fsutil.writeText(file_path, replace_result.contents);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nREPLACEMENTS {d}",
        .{ file_path, replace_result.replacements },
    );
    defer allocator.free(summary);

    return okEnvelope(allocator, "replace_in_file", summary);
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

fn okEnvelope(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":{f},\"content\":{f}}}",
        .{
            std.json.fmt(tool_name, .{}),
            std.json.fmt(content, .{}),
        },
    );
}

fn renderLineRange(
    allocator: std.mem.Allocator,
    content: []const u8,
    start_line: ?usize,
    end_line: ?usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const start = start_line orelse 1;
    const finish = end_line orelse std.math.maxInt(usize);

    var line_number: usize = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| : (line_number += 1) {
        if (line_number < start or line_number > finish) continue;
        try output.writer().print("{d}: {s}\n", .{ line_number, line });
    }

    return output.toOwnedSlice();
}

fn replaceText(
    allocator: std.mem.Allocator,
    input: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    replace_all: bool,
) !struct { contents: []u8, replacements: usize } {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var cursor: usize = 0;
    var replacements: usize = 0;

    while (std.mem.indexOfPos(u8, input, cursor, old_text)) |match_index| {
        try output.writer().writeAll(input[cursor..match_index]);
        try output.writer().writeAll(new_text);
        cursor = match_index + old_text.len;
        replacements += 1;

        if (!replace_all) break;
    }

    try output.writer().writeAll(input[cursor..]);

    return .{
        .contents = try output.toOwnedSlice(),
        .replacements = replacements,
    };
}

fn limitLines(allocator: std.mem.Allocator, input: []const u8, max_results: usize) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var iter = std.mem.splitScalar(u8, input, '\n');
    var line_count: usize = 0;
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (line_count >= max_results) break;
        try output.writer().print("{s}\n", .{line});
        line_count += 1;
    }

    return output.toOwnedSlice();
}

fn collectFiles(
    allocator: std.mem.Allocator,
    search_path: []const u8,
    search_prefix: []const u8,
    max_results: usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var dir = std.fs.openDirAbsolute(search_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const single_path = try normalizeToolPath(
                allocator,
                if (std.mem.eql(u8, search_prefix, ".")) std.fs.path.basename(search_path) else search_prefix,
            );
            defer allocator.free(single_path);

            try output.writer().print("{s}\n", .{single_path});
            return output.toOwnedSlice();
        },
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var line_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (line_count >= max_results) break;

        const display_path = if (std.mem.eql(u8, search_prefix, "."))
            try allocator.dupe(u8, entry.path)
        else
            try fsutil.join(allocator, &.{ search_prefix, entry.path });
        defer allocator.free(display_path);

        const normalized_path = try normalizeToolPath(allocator, display_path);
        defer allocator.free(normalized_path);

        try output.writer().print("{s}\n", .{normalized_path});
        line_count += 1;
    }

    return output.toOwnedSlice();
}

fn normalizeToolPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep == '/') return normalized;

    for (normalized) |*byte| {
        if (byte.* == std.fs.path.sep) byte.* = '/';
    }

    return normalized;
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
    try std.testing.expect(std.mem.indexOf(u8, catalog, "harness_todo") == null);
}
