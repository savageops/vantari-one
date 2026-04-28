const std = @import("std");

pub const Config = struct {
    openai_base_url: []u8,
    openai_api_key: []u8,
    openai_model: []u8,
    auth_provider: ?[]u8 = null,
    subscription_plan_label: ?[]u8 = null,
    subscription_status: ?[]u8 = null,
    max_steps: usize,
    workspace_root: []u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.openai_base_url);
        allocator.free(self.openai_api_key);
        allocator.free(self.openai_model);
        if (self.auth_provider) |value| allocator.free(value);
        if (self.subscription_plan_label) |value| allocator.free(value);
        if (self.subscription_status) |value| allocator.free(value);
        allocator.free(self.workspace_root);
    }
};

pub const AuthType = enum {
    api_key,
    oauth,
};

pub const SubscriptionSource = enum {
    manual,
    provider,
    inferred,
};

pub const SessionStatus = enum {
    initialized,
    running,
    completed,
    failed,
    cancelled,
};

pub const SessionRecord = struct {
    id: []u8,
    prompt: []u8,
    status: SessionStatus,
    parent_session_id: ?[]u8 = null,
    continued_from_session_id: ?[]u8 = null,
    display_name: ?[]u8 = null,
    agent_profile: ?[]u8 = null,
    failure_reason: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: SessionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.prompt);
        if (self.parent_session_id) |value| allocator.free(value);
        if (self.continued_from_session_id) |value| allocator.free(value);
        if (self.display_name) |value| allocator.free(value);
        if (self.agent_profile) |value| allocator.free(value);
        if (self.failure_reason) |value| allocator.free(value);
    }
};

pub const ProgressSnapshot = struct {
    session_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    output: []const u8,
    updated_at_ms: i64,
};

pub const SessionEvent = struct {
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,

    pub fn deinit(self: SessionEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.message);
    }
};

pub fn deinitSessionRecords(allocator: std.mem.Allocator, sessions: []SessionRecord) void {
    for (sessions) |session| session.deinit(allocator);
    allocator.free(sessions);
}

pub fn deinitSessionEvents(allocator: std.mem.Allocator, events: []SessionEvent) void {
    for (events) |event| event.deinit(allocator);
    allocator.free(events);
}

pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const SessionMessageRole = enum {
    user,
    assistant,
};

pub const SessionMessage = struct {
    id: []u8,
    seq: u64,
    role: SessionMessageRole,
    content: []u8,
    timestamp_ms: i64,

    pub fn deinit(self: SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.content);
    }
};

pub fn deinitSessionMessages(allocator: std.mem.Allocator, messages: []SessionMessage) void {
    for (messages) |message| message.deinit(allocator);
    allocator.free(messages);
}

pub const ContextCheckpoint = struct {
    id: []u8,
    entry_type: []u8,
    created_at_ms: i64,
    source_seq_start: u64,
    source_seq_end: u64,
    first_kept_seq: u64,
    tokens_before_estimate: u64,
    tokens_after_estimate: u64,
    aggressiveness_milli: u16 = 350,
    compacted_entry_count: u32 = 0,
    trigger: []u8,
    summary: []u8,

    pub fn deinit(self: ContextCheckpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.entry_type);
        allocator.free(self.trigger);
        allocator.free(self.summary);
    }
};

pub fn deinitContextCheckpoints(allocator: std.mem.Allocator, checkpoints: []ContextCheckpoint) void {
    for (checkpoints) |checkpoint| checkpoint.deinit(allocator);
    allocator.free(checkpoints);
}

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    example_json: ?[]const u8 = null,
    usage_hint: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
    }
};

pub const ChatMessage = struct {
    role: MessageRole,
    content: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},

    pub fn deinit(self: ChatMessage, allocator: std.mem.Allocator) void {
        if (self.content) |value| allocator.free(value);
        if (self.tool_call_id) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }
};

pub const CompletionRequest = struct {
    messages: []const ChatMessage,
    tool_definitions: []const ToolDefinition = &.{},
};

pub const CompletionResponse = struct {
    model: []u8,
    content: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},

    pub fn deinit(self: CompletionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        if (self.content) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }

    pub fn hasToolCalls(self: CompletionResponse) bool {
        return self.tool_calls.len > 0;
    }
};

pub const SessionRunResult = struct {
    session_id: []u8,
    output: []u8,

    pub fn deinit(self: SessionRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.output);
    }
};

pub fn statusLabel(status: SessionStatus) []const u8 {
    return switch (status) {
        .initialized => "initialized",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

pub fn parseStatusLabel(label: []const u8) !SessionStatus {
    if (std.mem.eql(u8, label, "initialized")) return .initialized;
    if (std.mem.eql(u8, label, "pending")) return .initialized;
    if (std.mem.eql(u8, label, "running")) return .running;
    if (std.mem.eql(u8, label, "completed")) return .completed;
    if (std.mem.eql(u8, label, "failed")) return .failed;
    if (std.mem.eql(u8, label, "cancelled")) return .cancelled;
    return error.InvalidStatus;
}

pub fn roleLabel(role: MessageRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn sessionMessageRoleLabel(role: SessionMessageRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
    };
}

pub fn parseSessionMessageRole(label: []const u8) !SessionMessageRole {
    if (std.mem.eql(u8, label, "user")) return .user;
    if (std.mem.eql(u8, label, "assistant")) return .assistant;
    return error.InvalidSessionMessageRole;
}

pub fn initTextMessage(
    allocator: std.mem.Allocator,
    role: MessageRole,
    text: []const u8,
) !ChatMessage {
    return .{
        .role = role,
        .content = try allocator.dupe(u8, text),
    };
}

pub fn initToolMessage(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    text: []const u8,
) !ChatMessage {
    return .{
        .role = .tool,
        .content = try allocator.dupe(u8, text),
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
    };
}

pub fn initAssistantToolCallMessage(
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: []const ToolCall,
) !ChatMessage {
    return .{
        .role = .assistant,
        .content = if (content) |value| try allocator.dupe(u8, value) else null,
        .tool_calls = try cloneToolCalls(allocator, tool_calls),
    };
}

pub fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ToolCall) ![]ToolCall {
    if (tool_calls.len == 0) return &.{};

    var owned_calls = try allocator.alloc(ToolCall, tool_calls.len);
    errdefer allocator.free(owned_calls);

    for (tool_calls, 0..) |tool_call, index| {
        owned_calls[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments_json = try allocator.dupe(u8, tool_call.arguments_json),
        };
    }

    return owned_calls;
}
