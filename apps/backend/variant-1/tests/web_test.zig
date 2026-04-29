const std = @import("std");
const VAR1 = @import("VAR1");

const MockSession = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    status: []u8,
    prompt: []u8,
    output: ?[]u8 = null,
    parent_session_id: ?[]u8 = null,
    continued_from_session_id: ?[]u8 = null,
    display_name: ?[]u8 = null,
    agent_profile: ?[]u8 = null,
    failure_reason: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
    messages: std.array_list.Managed(VAR1.shared.types.SessionMessage),
    events: std.array_list.Managed(VAR1.shared.types.SessionEvent),

    fn init(allocator: std.mem.Allocator, session_id: []const u8, prompt: []const u8, status: []const u8) !MockSession {
        const now_ms = std.time.milliTimestamp();
        var session = MockSession{
            .allocator = allocator,
            .session_id = try allocator.dupe(u8, session_id),
            .status = try allocator.dupe(u8, status),
            .prompt = try allocator.dupe(u8, prompt),
            .created_at_ms = now_ms,
            .updated_at_ms = now_ms,
            .messages = std.array_list.Managed(VAR1.shared.types.SessionMessage).init(allocator),
            .events = std.array_list.Managed(VAR1.shared.types.SessionEvent).init(allocator),
        };
        try session.messages.append(.{
            .id = try allocator.dupe(u8, "msg-1"),
            .seq = 1,
            .role = .user,
            .content = try allocator.dupe(u8, prompt),
            .timestamp_ms = now_ms,
        });
        return session;
    }

    fn deinit(self: *MockSession) void {
        self.allocator.free(self.session_id);
        self.allocator.free(self.status);
        self.allocator.free(self.prompt);
        if (self.output) |value| self.allocator.free(value);
        if (self.parent_session_id) |value| self.allocator.free(value);
        if (self.continued_from_session_id) |value| self.allocator.free(value);
        if (self.display_name) |value| self.allocator.free(value);
        if (self.agent_profile) |value| self.allocator.free(value);
        if (self.failure_reason) |value| self.allocator.free(value);
        for (self.messages.items) |message| message.deinit(self.allocator);
        self.messages.deinit();
        for (self.events.items) |event| event.deinit(self.allocator);
        self.events.deinit();
    }

    fn addAssistantOutput(self: *MockSession, output: []const u8, event_type: []const u8) !void {
        if (self.output) |value| self.allocator.free(value);
        self.output = try self.allocator.dupe(u8, output);
        self.updated_at_ms = std.time.milliTimestamp();
        try self.replaceStatus("completed");
        const seq = self.nextMessageSeq();
        const id = try self.messageId(seq);
        try self.messages.append(.{
            .id = id,
            .seq = seq,
            .role = .assistant,
            .content = try self.allocator.dupe(u8, output),
            .timestamp_ms = self.updated_at_ms,
        });
        try self.events.append(.{
            .event_type = try self.allocator.dupe(u8, event_type),
            .message = try self.allocator.dupe(u8, output),
            .timestamp_ms = self.updated_at_ms,
        });
    }

    fn addUserMessage(self: *MockSession, prompt: []const u8) !void {
        self.allocator.free(self.prompt);
        self.prompt = try self.allocator.dupe(u8, prompt);
        self.updated_at_ms = std.time.milliTimestamp();
        try self.replaceStatus("initialized");
        const seq = self.nextMessageSeq();
        const id = try self.messageId(seq);
        try self.messages.append(.{
            .id = id,
            .seq = seq,
            .role = .user,
            .content = try self.allocator.dupe(u8, prompt),
            .timestamp_ms = self.updated_at_ms,
        });
    }

    fn nextMessageSeq(self: MockSession) u64 {
        var max_seq: u64 = 0;
        for (self.messages.items) |message| {
            if (message.seq > max_seq) max_seq = message.seq;
        }
        return max_seq + 1;
    }

    fn messageId(self: MockSession, seq: u64) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "msg-{d}", .{seq});
    }

    fn replaceStatus(self: *MockSession, next_status: []const u8) !void {
        self.allocator.free(self.status);
        self.status = try self.allocator.dupe(u8, next_status);
    }
};

const MockNotification = struct {
    sequence: u64,
    method: []u8,
    params_json: []u8,

    fn deinit(self: MockNotification, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.params_json);
    }
};

const MockKernelContext = struct {
    allocator: std.mem.Allocator,
    sessions: std.array_list.Managed(MockSession),
    last_method: ?[]u8 = null,
    last_params: ?[]u8 = null,
    next_session_number: usize = 1,
    notification: ?MockNotification = null,

    fn init(allocator: std.mem.Allocator) MockKernelContext {
        return .{
            .allocator = allocator,
            .sessions = std.array_list.Managed(MockSession).init(allocator),
        };
    }

    fn deinit(self: *MockKernelContext) void {
        for (self.sessions.items) |*session| session.deinit();
        self.sessions.deinit();
        if (self.last_method) |value| self.allocator.free(value);
        if (self.last_params) |value| self.allocator.free(value);
        if (self.notification) |value| value.deinit(self.allocator);
    }

    fn recordCall(self: *MockKernelContext, method: []const u8, params_json: []const u8) !void {
        if (self.last_method) |value| self.allocator.free(value);
        if (self.last_params) |value| self.allocator.free(value);
        self.last_method = try self.allocator.dupe(u8, method);
        self.last_params = try self.allocator.dupe(u8, params_json);
    }

    fn setNotification(self: *MockKernelContext, sequence: u64, method: []const u8, params_json: []const u8) !void {
        if (self.notification) |value| value.deinit(self.allocator);
        self.notification = .{
            .sequence = sequence,
            .method = try self.allocator.dupe(u8, method),
            .params_json = try self.allocator.dupe(u8, params_json),
        };
    }

    fn seedCompletedSession(self: *MockKernelContext, session_id: []const u8, prompt: []const u8, output: []const u8) !void {
        var session = try MockSession.init(self.allocator, session_id, prompt, "completed");
        try session.addAssistantOutput(output, "assistant_response");
        try self.sessions.append(session);
    }

    fn seedInitializedSession(self: *MockKernelContext, session_id: []const u8, prompt: []const u8) !void {
        var session = try MockSession.init(self.allocator, session_id, prompt, "initialized");
        try session.events.append(.{
            .event_type = try self.allocator.dupe(u8, "session_started"),
            .message = try self.allocator.dupe(u8, "VAR1 session initialized."),
            .timestamp_ms = session.created_at_ms,
        });
        try self.sessions.append(session);
    }

    fn findSession(self: *MockKernelContext, session_id: []const u8) ?*MockSession {
        for (self.sessions.items) |*session| {
            if (std.mem.eql(u8, session.session_id, session_id)) return session;
        }
        return null;
    }
};

fn mockKernelCall(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) anyerror!VAR1.host.stdio_rpc.RpcCallResult {
    var ctx: *MockKernelContext = @ptrCast(@alignCast(ctx_ptr.?));
    try ctx.recordCall(method, params_json);

    if (std.mem.eql(u8, method, VAR1.shared.protocol.types.methods.health_get)) {
        return .{
            .result_json = try renderJsonAlloc(allocator, .{
                .ok = true,
                .model = "gemma-4-26b-a4b-it-apex",
                .workspace_root = "E:/tmp/workspace",
                .base_url = "http://127.0.0.1:1234",
                .api_key = "sk-secret",
            }),
        };
    }

    if (std.mem.eql(u8, method, VAR1.shared.protocol.types.methods.session_list)) {
        var summaries = try allocator.alloc(VAR1.shared.protocol.types.SessionSummary, ctx.sessions.items.len);
        defer allocator.free(summaries);

        for (ctx.sessions.items, 0..) |session, index| {
            summaries[index] = makeSummary(session);
        }

        return .{
            .result_json = try renderJsonAlloc(allocator, .{
                .sessions = summaries,
            }),
        };
    }

    if (std.mem.eql(u8, method, VAR1.shared.protocol.types.methods.session_get)) {
        const Args = struct {
            session_id: []const u8,
        };

        var parsed = try std.json.parseFromSlice(Args, allocator, params_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const session = ctx.findSession(parsed.value.session_id) orelse return error.SessionNotFound;
        const latest_event = if (session.events.items.len > 0) session.events.items[session.events.items.len - 1] else null;

        return .{
            .result_json = try renderJsonAlloc(allocator, .{
                .session = makeSummary(session.*),
                .latest_event = latest_event,
                .messages = session.messages.items,
                .events = session.events.items,
            }),
        };
    }

    if (std.mem.eql(u8, method, VAR1.shared.protocol.types.methods.session_create)) {
        const Args = struct {
            prompt: []const u8,
        };

        var parsed = try std.json.parseFromSlice(Args, allocator, params_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const session_id = try std.fmt.allocPrint(ctx.allocator, "session-created-{d}", .{ctx.next_session_number});
        ctx.next_session_number += 1;

        const session = try MockSession.init(ctx.allocator, session_id, parsed.value.prompt, "initialized");
        ctx.allocator.free(session_id);
        try ctx.sessions.append(session);

        return .{
            .result_json = try renderJsonAlloc(allocator, .{
                .session = makeSummary(ctx.sessions.items[ctx.sessions.items.len - 1]),
            }),
        };
    }

    if (std.mem.eql(u8, method, VAR1.shared.protocol.types.methods.session_send)) {
        const Args = struct {
            session_id: []const u8,
            prompt: ?[]const u8 = null,
        };

        var parsed = try std.json.parseFromSlice(Args, allocator, params_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const session = ctx.findSession(parsed.value.session_id) orelse return error.SessionNotFound;
        if (parsed.value.prompt) |prompt| {
            try session.addUserMessage(prompt);
        }
        if (session.events.items.len == 0) {
            try session.events.append(.{
                .event_type = try ctx.allocator.dupe(u8, "session_started"),
                .message = try ctx.allocator.dupe(u8, "VAR1 session initialized."),
                .timestamp_ms = std.time.milliTimestamp(),
            });
        }
        try session.addAssistantOutput("3", "assistant_response");

        return .{
            .result_json = try renderJsonAlloc(allocator, .{
                .session = makeSummary(session.*),
            }),
        };
    }

    return .{
        .error_json = try allocator.dupe(u8, "{\"code\":-32601,\"message\":\"Method not found\"}"),
    };
}

fn mockWaitNotificationAfter(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    after_sequence: u64,
    _: usize,
) anyerror!?VAR1.host.stdio_rpc.Notification {
    const ctx: *MockKernelContext = @ptrCast(@alignCast(ctx_ptr.?));
    const notification = ctx.notification orelse return null;
    if (notification.sequence <= after_sequence) return null;

    return .{
        .sequence = notification.sequence,
        .method = try allocator.dupe(u8, notification.method),
        .params_json = try allocator.dupe(u8, notification.params_json),
    };
}

fn makeSummary(session: MockSession) VAR1.shared.protocol.types.SessionSummary {
    return .{
        .session_id = session.session_id,
        .status = session.status,
        .prompt = session.prompt,
        .output = session.output,
        .parent_session_id = session.parent_session_id,
        .continued_from_session_id = session.continued_from_session_id,
        .display_name = session.display_name,
        .agent_profile = session.agent_profile,
        .failure_reason = session.failure_reason,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = session.updated_at_ms,
    };
}

fn makeBridge(allocator: std.mem.Allocator, ctx: *MockKernelContext) VAR1.host.http_bridge.Bridge {
    return VAR1.host.http_bridge.Bridge.initWithKernel(allocator, .{
        .context = ctx,
        .callFn = mockKernelCall,
        .waitNotificationAfterFn = mockWaitNotificationAfter,
    });
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

test "web route exposes bridge root text instead of embedded workbench html" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const response = try VAR1.host.http_bridge.route(
        std.testing.allocator,
        &bridge,
        .GET,
        "/",
        "",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "VAR1 HTTP bridge ready.") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "apps/frontend/var1-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "VAR1 Workbench") == null);
}

test "web route forwards json-rpc payloads and preserves caller ids" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const response = try VAR1.host.http_bridge.routeWithAccess(
        std.testing.allocator,
        &bridge,
        .POST,
        "/rpc",
        "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"health/get\",\"params\":{\"probe\":true}}",
        "http://127.0.0.1:4310",
        VAR1.host.http_bridge.test_bridge_token,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"result\":") != null);
    try std.testing.expectEqualStrings("health/get", ctx.last_method.?);
    try std.testing.expect(std.mem.indexOf(u8, ctx.last_params.?, "\"probe\":true") != null);
}

test "web route renders session notifications as sse snapshots" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    try ctx.setNotification(
        4,
        VAR1.shared.protocol.types.notification_methods.session_event,
        "{\"session_id\":\"session-1\",\"event_type\":\"assistant_response\",\"message\":\"3\"}",
    );
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const response = try VAR1.host.http_bridge.routeWithAccess(
        std.testing.allocator,
        &bridge,
        .GET,
        "/events?since=0",
        "",
        "http://127.0.0.1:4310",
        VAR1.host.http_bridge.test_bridge_token,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("text/event-stream; charset=utf-8", response.content_type);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "id: 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "event: session/event") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"session_id\":\"session-1\"") != null);
}

test "web route rejects unapproved browser origins" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const response = try VAR1.host.http_bridge.routeWithAccess(
        std.testing.allocator,
        &bridge,
        .GET,
        "/api/health",
        "",
        "https://example.com",
        null,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.forbidden, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"error\":\"ForbiddenOrigin\"") != null);
    try std.testing.expect(!std.mem.eql(u8, response.cors_origin, "*"));
}

test "web route denies null origin and allows explicit local origins" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const null_origin_response = try VAR1.host.http_bridge.routeWithAccess(
        std.testing.allocator,
        &bridge,
        .GET,
        "/api/health",
        "",
        "null",
        null,
    );
    defer null_origin_response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.forbidden, null_origin_response.status);
    try std.testing.expect(std.mem.indexOf(u8, null_origin_response.body, "\"error\":\"ForbiddenOrigin\"") != null);

    const local_response = try VAR1.host.http_bridge.routeWithAccess(
        std.testing.allocator,
        &bridge,
        .GET,
        "/api/health",
        "",
        "http://127.0.0.1:5173",
        null,
    );
    defer local_response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.ok, local_response.status);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", local_response.cors_origin);
    try std.testing.expect(std.mem.indexOf(u8, local_response.body, "\"bridge_token\":\"test-bridge-token\"") != null);
}

test "web route requires bridge token for rpc and event access" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const response = try VAR1.host.http_bridge.routeWithAccess(
        std.testing.allocator,
        &bridge,
        .POST,
        "/rpc",
        "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"health/get\",\"params\":{}}",
        "http://localhost:5173",
        null,
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(std.http.Status.unauthorized, response.status);
    try std.testing.expectEqualStrings("http://localhost:5173", response.cors_origin);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"error\":\"BridgeTokenRequired\"") != null);
}

test "web route rejects removed api facade" {
    var ctx = MockKernelContext.init(std.testing.allocator);
    defer ctx.deinit();
    var bridge = makeBridge(std.testing.allocator, &ctx);

    const health_response = try VAR1.host.http_bridge.route(
        std.testing.allocator,
        &bridge,
        .GET,
        "/api/health",
        "",
    );
    defer health_response.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, health_response.body, "\"model\":\"gemma-4-26b-a4b-it-apex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health_response.body, "\"bridge_token\":\"test-bridge-token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, health_response.body, "sk-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, health_response.body, "\"api_key\":\"[redacted]\"") != null);

    const root_response = try VAR1.host.http_bridge.route(
        std.testing.allocator,
        &bridge,
        .GET,
        "/api/tasks",
        "",
    );
    defer root_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, root_response.status);
    try std.testing.expect(std.mem.indexOf(u8, root_response.body, "\"error\":\"NotFound\"") != null);

    const nested_response = try VAR1.host.http_bridge.route(
        std.testing.allocator,
        &bridge,
        .POST,
        "/api/tasks/session-existing/messages",
        "",
    );
    defer nested_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.not_found, nested_response.status);
    try std.testing.expect(std.mem.indexOf(u8, nested_response.body, "\"error\":\"NotFound\"") != null);
}

test "bridge access module owns origin redaction and audit classification" {
    try std.testing.expectEqualStrings(
        VAR1.host.bridge_access.default_cors_origin,
        VAR1.host.bridge_access.allowedCorsOrigin(null).?,
    );
    try std.testing.expectEqualStrings(
        "http://[::1]:5173",
        VAR1.host.bridge_access.allowedCorsOrigin("http://[::1]:5173").?,
    );
    try std.testing.expect(VAR1.host.bridge_access.allowedCorsOrigin("null") == null);
    try std.testing.expect(VAR1.host.bridge_access.allowedCorsOrigin("https://example.com") == null);
    try std.testing.expect(VAR1.host.bridge_access.tokenValid("token-1", "token-1"));
    try std.testing.expect(!VAR1.host.bridge_access.tokenValid("token-1", "token-2"));
    try std.testing.expectEqualStrings(
        "session_write",
        VAR1.host.bridge_access.auditAction(VAR1.shared.protocol.types.methods.session_send).?,
    );

    const payload = try VAR1.host.bridge_access.redactAndAttachHandshake(
        std.testing.allocator,
        "{\"ok\":true,\"api_key\":\"sk-secret\",\"nested\":{\"authorization\":\"Bearer abc\",\"safe\":\"value\"}}",
        "token-1",
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "sk-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Bearer abc") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"api_key\":\"[redacted]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"authorization\":\"[redacted]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"bridge_token\":\"token-1\"") != null);
}
