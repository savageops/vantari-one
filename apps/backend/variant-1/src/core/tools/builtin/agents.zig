const std = @import("std");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definitions = [_]types.ToolDefinition{
    .{
        .name = "launch_agent",
        .description = "Launch another VAR1 agent as a named child run. JSON arguments require prompt and optionally accept name. Use this only for bounded child work you want VAR1 to execute separately.",
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
        .example_json = "{\"prompt\":\"Inspect src/core/tools/runtime.zig and summarize search_files.\",\"name\":\"search-audit\"}",
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
        .description = "List the child agents launched by the current parent session, including their names and statuses. JSON arguments must be an empty object.",
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

pub const availability = module.AvailabilitySpec{};

pub fn handles(tool_name: []const u8) bool {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, tool_name)) return true;
    }
    return false;
}

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    tool_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "launch_agent")) {
        return executeLaunchAgent(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "agent_status")) {
        return executeAgentStatus(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "wait_agent")) {
        return executeWaitAgent(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "list_agents")) {
        return executeListAgents(allocator, execution_context);
    }

    return module.Error.UnknownTool;
}

fn executeLaunchAgent(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

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

    return module.okEnvelope(allocator, "launch_agent", content);
}

fn executeAgentStatus(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const Args = struct {
        name: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const content = try service.status(allocator, parent_session_id, parsed.value.name);
    defer allocator.free(content);

    return module.okEnvelope(allocator, "agent_status", content);
}

fn executeWaitAgent(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

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

    return module.okEnvelope(allocator, "wait_agent", content);
}

fn executeListAgents(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const content = try service.list(allocator, parent_session_id);
    defer allocator.free(content);

    return module.okEnvelope(allocator, "list_agents", content);
}
