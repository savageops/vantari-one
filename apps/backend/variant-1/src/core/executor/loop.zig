const std = @import("std");
const docs_sync = @import("../docs/sync.zig");
const context_builder = @import("../context/index.zig");
const provider = @import("../providers/openai_compatible.zig");
const store = @import("../sessions/store.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    Cancelled,
    MissingAssistantContent,
    StepLimitExceeded,
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    onSessionInitializedFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) anyerror!void = null,
    onSessionEventFn: ?*const fn (
        ctx: ?*anyopaque,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) anyerror!void = null,
    shouldCancelFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) bool = null,

    pub fn onSessionInitialized(self: Hooks, session_id: []const u8) !void {
        if (self.onSessionInitializedFn) |callback| {
            try callback(self.context, session_id);
        }
    }

    pub fn onSessionEvent(
        self: Hooks,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.onSessionEventFn) |callback| {
            try callback(self.context, session_id, event_type, message, status, timestamp_ms);
        }
    }

    pub fn shouldCancel(self: Hooks, session_id: []const u8) bool {
        if (self.shouldCancelFn) |callback| {
            return callback(self.context, session_id);
        }
        return false;
    }
};

pub const RunOptions = struct {
    transport: provider.Transport,
    execution_context: tools.ExecutionContext,
    session_id: ?[]const u8 = null,
    hooks: Hooks = .{},
};

pub fn runPrompt(allocator: std.mem.Allocator, config: types.Config, prompt: []const u8) !types.SessionRunResult {
    return runPromptWithOptions(allocator, config, prompt, .{
        .transport = .{
            .context = null,
            .sendFn = provider.httpSend,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
    });
}

pub fn runPromptWithTransport(
    allocator: std.mem.Allocator,
    config: types.Config,
    prompt: []const u8,
    transport: provider.Transport,
) !types.SessionRunResult {
    return runPromptWithOptions(allocator, config, prompt, .{
        .transport = transport,
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
    });
}

pub fn runPromptWithOptions(
    allocator: std.mem.Allocator,
    config: types.Config,
    prompt: []const u8,
    options: RunOptions,
) !types.SessionRunResult {
    try store.ensureStoreReady(allocator, config.workspace_root);
    try docs_sync.ensureRunStart(allocator, config.workspace_root);

    var session = if (options.session_id) |existing_session_id|
        try store.readSessionRecord(allocator, config.workspace_root, existing_session_id)
    else
        try store.initSession(allocator, config.workspace_root, prompt);
    defer session.deinit(allocator);

    if (session.status == .cancelled) return Error.Cancelled;

    try store.setSessionStatus(allocator, config.workspace_root, &session, .running);
    try options.hooks.onSessionInitialized(session.id);
    try recordSessionEvent(
        allocator,
        config.workspace_root,
        options.hooks,
        session.id,
        "session_started",
        "VAR1 session initialized.",
        session.status,
    );
    try docs_sync.writePending(allocator, config.workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = "",
        .updated_at_ms = session.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, config.workspace_root, "session started");

    var messages = std.array_list.Managed(types.ChatMessage).init(allocator);
    defer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit();
    }

    var execution_context = options.execution_context;
    execution_context.workspace_root = config.workspace_root;
    if (execution_context.parent_session_id == null) {
        execution_context.parent_session_id = session.id;
    }
    if (!execution_context.workspace_state_enabled and tools.workspaceStateRelevant(session.prompt)) {
        execution_context.workspace_state_enabled = true;
    }

    const system_prompt = try tools.buildAgentSystemPrompt(allocator, execution_context);
    defer allocator.free(system_prompt);

    try messages.append(try types.initTextMessage(allocator, .system, system_prompt));
    context_builder.appendProviderMessages(allocator, config.workspace_root, &messages, session) catch |err| {
        try failSession(allocator, config.workspace_root, options.hooks, &session, @errorName(err));
        return err;
    };

    var requires_child_supervision = false;
    var step: usize = 0;
    while (step < config.max_steps) : (step += 1) {
        if (options.hooks.shouldCancel(session.id)) {
            try cancelSession(allocator, config.workspace_root, options.hooks, &session, "Cancellation requested.");
            return Error.Cancelled;
        }

        const completion = provider.completeWithTransport(allocator, config, .{
            .messages = messages.items,
            .tool_definitions = tools.builtinDefinitionsForContext(execution_context),
        }, options.transport) catch |err| {
            try failSession(allocator, config.workspace_root, options.hooks, &session, @errorName(err));
            return err;
        };
        defer completion.deinit(allocator);

        if (completion.hasToolCalls()) {
            const summary = try tools.renderToolCallSummary(allocator, completion.tool_calls);
            defer allocator.free(summary);

            const request_log = try std.fmt.allocPrint(allocator, "tool requested: {s}", .{summary});
            defer allocator.free(request_log);
            try recordSessionEvent(
                allocator,
                config.workspace_root,
                options.hooks,
                session.id,
                "tool_requested",
                request_log,
                session.status,
            );
            try docs_sync.appendLog(allocator, config.workspace_root, request_log);

            try messages.append(try types.initAssistantToolCallMessage(allocator, completion.content, completion.tool_calls));

            for (completion.tool_calls) |tool_call| {
                if (options.hooks.shouldCancel(session.id)) {
                    try cancelSession(allocator, config.workspace_root, options.hooks, &session, "Cancellation requested.");
                    return Error.Cancelled;
                }

                const tool_result = try executeToolCall(allocator, execution_context, tool_call);
                defer allocator.free(tool_result.output);
                defer allocator.free(tool_result.log_line);
                if (tool_result.launched_child) requires_child_supervision = true;

                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_completed",
                    tool_result.log_line,
                    session.status,
                );
                try docs_sync.appendLog(allocator, config.workspace_root, tool_result.log_line);
                try messages.append(try types.initToolMessage(allocator, tool_call.id, tool_result.output));
            }

            continue;
        }

        if (completion.content) |content| {
            if (requires_child_supervision) {
                const child_summary = childStatusSummary(allocator, execution_context) catch ChildStatusSummary{};
                if (child_summary.pending > 0) {
                    const waiting_message = "I will continue once agents complete; if any fail, I will follow up.";
                    try recordSessionEvent(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        session.id,
                        "session_waiting",
                        waiting_message,
                        session.status,
                    );
                    const waiting_log = try std.fmt.allocPrint(allocator, "parent waiting on child agents: {d} pending", .{child_summary.pending});
                    defer allocator.free(waiting_log);
                    try docs_sync.appendLog(allocator, config.workspace_root, waiting_log);

                    try messages.append(try types.initTextMessage(allocator, .assistant, content));
                    const supervision_prompt = try std.fmt.allocPrint(
                        allocator,
                        "Supervision checkpoint: {d} child runs are still non-terminal. Continue supervising child runs internally until they finish or fail. Do not ask the operator to run status tools.",
                        .{child_summary.pending},
                    );
                    defer allocator.free(supervision_prompt);
                    try messages.append(try types.initTextMessage(allocator, .user, supervision_prompt));
                    continue;
                }

                if (child_summary.failed > 0 and !contentMentionsFailure(content)) {
                    try messages.append(try types.initTextMessage(allocator, .assistant, content));
                    const failure_prompt = try std.fmt.allocPrint(
                        allocator,
                        "Child supervision checkpoint: {d} child runs failed. Follow up clearly on those failures in your operator response.",
                        .{child_summary.failed},
                    );
                    defer allocator.free(failure_prompt);
                    try messages.append(try types.initTextMessage(allocator, .user, failure_prompt));
                    continue;
                }
                requires_child_supervision = false;
            }

            const final_output = try sanitizeOperatorResponse(allocator, session.prompt, content);
            defer allocator.free(final_output);

            const final_timestamp = std.time.milliTimestamp();
            try store.appendEvent(allocator, config.workspace_root, session.id, .{
                .event_type = "assistant_response",
                .message = final_output,
                .timestamp_ms = final_timestamp,
            });
            try options.hooks.onSessionEvent(
                session.id,
                "assistant_response",
                final_output,
                types.statusLabel(session.status),
                final_timestamp,
            );
            try store.upsertAssistantSessionMessage(allocator, config.workspace_root, session.id, final_output, final_timestamp);
            try store.writeOutput(allocator, config.workspace_root, session.id, final_output);
            try store.setSessionStatus(allocator, config.workspace_root, &session, .completed);
            try docs_sync.completeSession(allocator, config.workspace_root, .{
                .session_id = session.id,
                .status = types.statusLabel(session.status),
                .prompt = session.prompt,
                .output = final_output,
                .updated_at_ms = session.updated_at_ms,
            });
            try docs_sync.appendLog(allocator, config.workspace_root, "session completed");

            return .{
                .session_id = try allocator.dupe(u8, session.id),
                .output = try allocator.dupe(u8, final_output),
            };
        }

        try failSession(allocator, config.workspace_root, options.hooks, &session, "MissingAssistantContent");
        return Error.MissingAssistantContent;
    }

    try failSession(allocator, config.workspace_root, options.hooks, &session, "StepLimitExceeded");
    return Error.StepLimitExceeded;
}

fn executeToolCall(
    allocator: std.mem.Allocator,
    execution_context: tools.ExecutionContext,
    tool_call: types.ToolCall,
) !struct { output: []u8, log_line: []u8, launched_child: bool } {
    const tool_output = tools.execute(allocator, execution_context, tool_call) catch |err| {
        const error_name = @errorName(err);
        const error_output = try tools.renderExecutionError(allocator, tool_call.name, error_name, tool_call.arguments_json);
        const error_log = if (tools.toolErrorHint(tool_call.name, error_name)) |hint|
            try std.fmt.allocPrint(allocator, "tool errored: {s} ({s}) - {s}", .{
                tools.toolCallLogLabel(tool_call.name),
                error_name,
                hint,
            })
        else
            try std.fmt.allocPrint(allocator, "tool errored: {s} ({s})", .{
                tools.toolCallLogLabel(tool_call.name),
                error_name,
            });
        return .{ .output = error_output, .log_line = error_log, .launched_child = false };
    };

    const success_log = try std.fmt.allocPrint(allocator, "tool completed: {s}", .{tools.toolCallLogLabel(tool_call.name)});
    return .{
        .output = tool_output,
        .log_line = success_log,
        .launched_child = std.mem.eql(u8, tool_call.name, "launch_agent"),
    };
}

const ChildStatusSummary = struct {
    pending: usize = 0,
    failed: usize = 0,
};

fn childStatusSummary(allocator: std.mem.Allocator, execution_context: tools.ExecutionContext) !ChildStatusSummary {
    const service = execution_context.agent_service orelse return .{};
    const parent_session_id = execution_context.parent_session_id orelse return .{};

    const listing = try service.list(allocator, parent_session_id);
    defer allocator.free(listing);

    if (std.mem.eql(u8, std.mem.trim(u8, listing, " \r\n"), "No child agents.")) return .{};

    var summary: ChildStatusSummary = .{};
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        const status_label = statusLabelFromListLine(line) orelse continue;
        if (!isTerminalStatusLabel(status_label)) {
            summary.pending += 1;
            continue;
        }
        if (std.mem.eql(u8, status_label, "failed") or std.mem.eql(u8, status_label, "cancelled")) {
            summary.failed += 1;
        }
    }

    return summary;
}

fn statusLabelFromListLine(line: []const u8) ?[]const u8 {
    const status_key = " STATUS ";
    const status_start = std.mem.indexOf(u8, line, status_key) orelse return null;
    const value_start = status_start + status_key.len;
    const remainder = line[value_start..];
    const value_end = std.mem.indexOfScalar(u8, remainder, ' ') orelse remainder.len;
    return remainder[0..value_end];
}

fn isTerminalStatusLabel(status_label: []const u8) bool {
    return std.mem.eql(u8, status_label, "completed") or
        std.mem.eql(u8, status_label, "failed") or
        std.mem.eql(u8, status_label, "cancelled");
}

fn contentMentionsFailure(content: []const u8) bool {
    const keywords = [_][]const u8{
        "fail",
        "failed",
        "failure",
        "errored",
        "error",
        "cancelled",
    };

    for (keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(content, keyword) != null) return true;
    }

    return false;
}

fn sanitizeOperatorResponse(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    content: []const u8,
) ![]u8 {
    if (promptRequestsToolDocumentation(prompt) or !contentLeaksInternalToolNames(content)) {
        return allocator.dupe(u8, content);
    }

    const redacted = try redactInternalToolNames(allocator, content);
    if (!contentLeaksInternalToolNames(redacted)) {
        return redacted;
    }

    allocator.free(redacted);
    return allocator.dupe(u8, "I completed the request and can provide an operator-safe summary.");
}

fn promptRequestsToolDocumentation(prompt: []const u8) bool {
    const keywords = [_][]const u8{
        "tool",
        "tools",
        "catalog",
        "launch_agent",
        "agent_status",
        "wait_agent",
        "list_agents",
    };

    for (keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(prompt, keyword) != null) return true;
    }

    return false;
}

fn contentLeaksInternalToolNames(content: []const u8) bool {
    const tool_names = [_][]const u8{
        "launch_agent",
        "agent_status",
        "wait_agent",
        "list_agents",
    };

    for (tool_names) |tool_name| {
        if (std.ascii.indexOfIgnoreCase(content, tool_name) != null) return true;
    }

    return false;
}

const ToolNameAlias = struct {
    internal_name: []const u8,
    public_phrase: []const u8,
};

fn redactInternalToolNames(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const aliases = [_]ToolNameAlias{
        .{ .internal_name = "launch_agent", .public_phrase = "child-run orchestration" },
        .{ .internal_name = "agent_status", .public_phrase = "child-run status checks" },
        .{ .internal_name = "wait_agent", .public_phrase = "child-run wait checks" },
        .{ .internal_name = "list_agents", .public_phrase = "child-run listing" },
    };

    var redacted = try allocator.dupe(u8, content);
    errdefer allocator.free(redacted);

    for (aliases) |alias| {
        const updated = try replaceAllIgnoreCaseOwned(allocator, redacted, alias.internal_name, alias.public_phrase);
        allocator.free(redacted);
        redacted = updated;
    }

    return redacted;
}

fn replaceAllIgnoreCaseOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, input);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var cursor: usize = 0;
    while (indexOfIgnoreCasePos(input, needle, cursor)) |match_index| {
        try output.appendSlice(input[cursor..match_index]);
        try output.appendSlice(replacement);
        cursor = match_index + needle.len;
    }

    try output.appendSlice(input[cursor..]);
    return output.toOwnedSlice();
}

fn indexOfIgnoreCasePos(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len) return null;

    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }

    return null;
}

fn cancelSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    reason: []const u8,
) !void {
    try store.setSessionStatus(allocator, workspace_root, session, .cancelled);
    try recordSessionEvent(allocator, workspace_root, hooks, session.id, "session_cancelled", reason, session.status);
    try docs_sync.writePending(allocator, workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = reason,
        .updated_at_ms = session.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, workspace_root, "session cancelled");
}

fn failSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    failure_reason: []const u8,
) !void {
    try recordSessionEvent(allocator, workspace_root, hooks, session.id, "session_failed", failure_reason, session.status);
    try store.setSessionFailure(allocator, workspace_root, session, failure_reason);
    try docs_sync.writePending(allocator, workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = failure_reason,
        .updated_at_ms = session.updated_at_ms,
    });

    const log_line = try std.fmt.allocPrint(allocator, "session failed: {s}", .{failure_reason});
    defer allocator.free(log_line);
    try docs_sync.appendLog(allocator, workspace_root, log_line);
}

fn recordSessionEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session_id: []const u8,
    event_type: []const u8,
    message: []const u8,
    status: types.SessionStatus,
) !void {
    const timestamp_ms = std.time.milliTimestamp();
    try store.appendEvent(allocator, workspace_root, session_id, .{
        .event_type = event_type,
        .message = message,
        .timestamp_ms = timestamp_ms,
    });
    try hooks.onSessionEvent(session_id, event_type, message, types.statusLabel(status), timestamp_ms);
}
