const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeConfig(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_steps: usize,
) !VAR1.shared.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "gemma-4-e2b-it"),
        .max_steps = max_steps,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn mockSendSuccess(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"There are 3 'r's in the word \"strawberry\"."}}]}
    );
}

fn mockSendFailure(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.ConnectionRefused;
}

fn mockSendLeakyOperatorReply(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"I launched the child agents. You can check progress with agent_status or wait_agent."}}]}
    );
}

const ToolLoopContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
    payloads: [3]?[]u8 = .{ null, null, null },

    fn deinit(self: *ToolLoopContext) void {
        for (self.payloads) |payload| {
            if (payload) |value| self.allocator.free(value);
        }
    }
};

const ResumePromptContext = struct {
    allocator: std.mem.Allocator,
    payload: ?[]u8 = null,

    fn deinit(self: *ResumePromptContext) void {
        if (self.payload) |value| self.allocator.free(value);
    }
};

const OverflowRetryContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
    payloads: [2]?[]u8 = .{ null, null },

    fn deinit(self: *OverflowRetryContext) void {
        for (self.payloads) |payload| {
            if (payload) |value| self.allocator.free(value);
        }
    }
};

const CancelContext = struct {
    checks: usize = 0,
};

const LocalHttpServer = struct {
    server: std.net.Server,
    response: []const u8,
    status: std.http.Status = .ok,
    method: ?std.http.Method = null,
    target_buffer: [256]u8 = undefined,
    target_len: usize = 0,
    authorization_ok: bool = false,
    accept_encoding_ok: bool = false,
    content_type_ok: bool = false,
    body_ok: bool = false,
    err: ?anyerror = null,

    fn serve(ctx: *LocalHttpServer) void {
        ctx.run() catch |err| {
            ctx.err = err;
        };
    }

    fn run(ctx: *LocalHttpServer) !void {
        defer ctx.server.deinit();

        var connection = try ctx.server.accept();
        defer connection.stream.close();
        var read_buffer: [1024]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = connection.stream.reader(&read_buffer);
        var writer = connection.stream.writer(&write_buffer);
        var server = std.http.Server.init(reader.interface(), &writer.interface);
        var request = try server.receiveHead();

        ctx.method = request.head.method;
        if (request.head.target.len > ctx.target_buffer.len) return error.HttpTargetTooLong;
        @memcpy(ctx.target_buffer[0..request.head.target.len], request.head.target);
        ctx.target_len = request.head.target.len;

        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                ctx.authorization_ok = std.mem.eql(u8, header.value, "Bearer test-key");
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) {
                ctx.accept_encoding_ok = std.mem.eql(u8, header.value, "identity");
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                ctx.content_type_ok = std.mem.eql(u8, header.value, "application/json");
            }
        }

        if (request.head.content_length) |content_length| {
            const body_len = std.math.cast(usize, content_length) orelse return error.HttpBodyTooLarge;
            if (body_len > 256) return error.HttpBodyTooLarge;

            var body_reader_buffer: [256]u8 = undefined;
            var body_storage: [256]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_reader_buffer);
            try body_reader.readSliceAll(body_storage[0..body_len]);
            ctx.body_ok = std.mem.eql(u8, body_storage[0..body_len], "{\"hello\":true}");
        }

        try request.respond(ctx.response, .{ .status = ctx.status });
    }
};

fn mockSendToolLoop(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\",\"start_line\":1,\"end_line\":1}"}}]}}]}
        );
    }

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"The first line in context.txt is hello from file."}}]}
    );
}

fn mockSendResumePrompt(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ResumePromptContext = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.payload) |value| ctx.allocator.free(value);
    ctx.payload = try ctx.allocator.dupe(u8, payload);

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"3"}}]}
    );
}

fn mockSendOverflowThenSuccess(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *OverflowRetryContext = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.call_count < ctx.payloads.len) {
        ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);
    }

    defer ctx.call_count += 1;
    if (ctx.call_count == 0) return error.ContextWindowExceeded;

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Recovered after compaction."}}]}
    );
}

fn shouldCancelOnFirstCheck(ctx_ptr: ?*anyopaque, _: []const u8) bool {
    var ctx: *CancelContext = @ptrCast(@alignCast(ctx_ptr.?));
    defer ctx.checks += 1;
    return ctx.checks == 0;
}

test "provider parses a mock OpenAI-compatible chat completion" {
    const config = try makeConfig(std.testing.allocator, ".", 4);
    defer config.deinit(std.testing.allocator);

    var messages = [_]VAR1.shared.types.ChatMessage{
        try VAR1.shared.types.initTextMessage(std.testing.allocator, .user, "how many r in strawberry"),
    };
    defer messages[0].deinit(std.testing.allocator);

    const completion = try VAR1.core.provider_runtime.completeWithTransport(std.testing.allocator, config, .{
        .messages = messages[0..],
        .tool_definitions = VAR1.core.tool_runtime.builtinDefinitions(false),
    }, .{
        .context = null,
        .sendFn = mockSendSuccess,
    });
    defer completion.deinit(std.testing.allocator);

    try std.testing.expect(!completion.hasToolCalls());
    try std.testing.expect(std.mem.indexOf(u8, completion.content.?, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion.content.?, "strawberry") != null);
}

test "provider completion url keeps explicit versioned bases intact" {
    const versioned = try VAR1.core.provider_runtime.completionUrl(std.testing.allocator, "https://api.z.ai/api/coding/paas/v4");
    defer std.testing.allocator.free(versioned);

    const local = try VAR1.core.provider_runtime.completionUrl(std.testing.allocator, "http://127.0.0.1:1234");
    defer std.testing.allocator.free(local);

    try std.testing.expectEqualStrings("https://api.z.ai/api/coding/paas/v4/chat/completions", versioned);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/v1/chat/completions", local);
}

test "provider native http transport posts JSON over a single in-process path" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "{\"ok\":true}",
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    const body = try VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    );
    defer std.testing.allocator.free(body);

    if (local_server.err) |err| return err;

    try std.testing.expectEqualStrings("{\"ok\":true}", body);
    try std.testing.expectEqual(.POST, local_server.method.?);
    try std.testing.expectEqualStrings("/v1/chat/completions", local_server.target_buffer[0..local_server.target_len]);
    try std.testing.expect(local_server.authorization_ok);
    try std.testing.expect(local_server.accept_encoding_ok);
    try std.testing.expect(local_server.content_type_ok);
    try std.testing.expect(local_server.body_ok);
}

test "provider native http transport classifies context overflow status" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "{\"error\":{\"message\":\"maximum context length exceeded\"}}",
        .status = .payload_too_large,
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectError(error.ContextWindowExceeded, VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    ));

    if (local_server.err) |err| return err;
}

test "loop writes runtime state and archives docs on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "how many r in strawberry", .{
        .context = null,
        .sendFn = mockSendSuccess,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "3") != null);

    const changelog_path = try VAR1.core.docs_sync.changelogSlicePath(std.testing.allocator, workspace_root, result.session_id);
    defer std.testing.allocator.free(changelog_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(changelog_path));
}

test "loop can resume a precreated child session and preserve delegation metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var child_session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "how many r in strawberry",
        .{
            .status = .initialized,
            .parent_session_id = "session-parent",
            .display_name = "berry-child",
            .agent_profile = "subagent",
        },
    );
    defer child_session.deinit(std.testing.allocator);

    var context = ResumePromptContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendResumePrompt,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = child_session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(child_session.id, result.session_id);

    var persisted = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, child_session.id);
    defer persisted.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.completed, persisted.status);
    try std.testing.expectEqualStrings("session-parent", persisted.parent_session_id.?);
    try std.testing.expectEqualStrings("berry-child", persisted.display_name.?);
    try std.testing.expectEqualStrings("subagent", persisted.agent_profile.?);
    try std.testing.expect(std.mem.indexOf(u8, context.payload.?, "how many r in strawberry") != null);
}

test "loop resumes a same-session transcript from canonical messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "What is VAR1?",
        .{
            .status = .completed,
        },
    );
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, session.id, "VAR1 is the Zig kernel.");
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "VAR1 is the Zig kernel.", std.time.milliTimestamp());
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Can I continue the conversation?", std.time.milliTimestamp());
    try VAR1.core.session_store.setSessionPrompt(std.testing.allocator, workspace_root, &session, "Can I continue the conversation?", .initialized);

    var context = ResumePromptContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendResumePrompt,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(session.id, result.session_id);

    const payload = context.payload.?;
    try std.testing.expect(std.mem.indexOf(u8, payload, "What is VAR1?") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "VAR1 is the Zig kernel.") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Can I continue the conversation?") != null);

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, messages[3].role);
    try std.testing.expectEqualStrings("3", messages[3].content);
}

test "loop auto-compacts before provider call when policy threshold is crossed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);
    config.context_policy = .{
        .auto_compaction = true,
        .context_window_tokens = 80,
        .compact_at_ratio_milli = 500,
        .reserve_output_tokens = 10,
        .keep_recent_messages = 2,
        .max_entries_per_checkpoint = 0,
        .aggressiveness_milli = 350,
    };

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt with enough words to matter.");
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer with enough words to matter.", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt with enough words to matter.", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer with enough words to matter.", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt with enough words to matter.", 500);

    var context = ResumePromptContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendResumePrompt,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, context.payload.?, "VAR1 context checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payload.?, "Final prompt with enough words") != null);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "auto_threshold") != null);
}

test "loop retries once after provider-declared context overflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);
    config.context_policy = .{
        .auto_compaction = false,
        .retry_on_provider_overflow = true,
        .context_window_tokens = 80,
        .compact_at_ratio_milli = 500,
        .reserve_output_tokens = 10,
        .keep_recent_messages = 2,
        .max_entries_per_checkpoint = 0,
        .aggressiveness_milli = 350,
    };

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt before overflow.");
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer before overflow.", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt before overflow.", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer before overflow.", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt before overflow.", 500);

    var context = OverflowRetryContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendOverflowThenSuccess,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Recovered") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "VAR1 context checkpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "VAR1 context checkpoint") != null);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "provider_overflow") != null);
}

test "loop records a failed session when provider transport fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectError(error.ConnectionRefused, VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "how many r in strawberry", .{
        .context = null,
        .sendFn = mockSendFailure,
    }));

    const sessions = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, sessions[0].status);
    try std.testing.expect(std.mem.eql(u8, sessions[0].failure_reason.?, "ConnectionRefused"));
}

test "loop marks a session cancelled when hooks request cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Cancel me");
    defer session.deinit(std.testing.allocator);

    var cancel_context = CancelContext{};
    try std.testing.expectError(VAR1.core.executor.Error.Cancelled, VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = null,
            .sendFn = mockSendSuccess,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
        .hooks = .{
            .context = &cancel_context,
            .shouldCancelFn = shouldCancelOnFirstCheck,
        },
    }));

    var persisted = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.cancelled, persisted.status);

    const latest_event = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest_event != null);
    try std.testing.expectEqualStrings("session_cancelled", latest_event.?.event_type);
}

test "loop sanitizes leaked internal tool names without false child-wait messaging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "launch three child agents and keep me posted", .{
        .context = null,
        .sendFn = mockSendLeakyOperatorReply,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "agent_status") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "wait_agent") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "child-run status checks") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "child-run wait checks") != null);
    try std.testing.expect(!std.mem.eql(u8, result.output, "I will continue once agents complete; if any fail, I will follow up."));
}

test "loop allows internal tool names when prompt requests tool documentation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Document launch_agent, agent_status, wait_agent, and list_agents usage.", .{
        .context = null,
        .sendFn = mockSendLeakyOperatorReply,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "agent_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "wait_agent") != null);
}

test "loop executes tool calls and exposes descriptors in the provider payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "hello from file\nsecond line\n");

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt and tell me the first line.", .{
        .context = &context,
        .sendFn = mockSendToolLoop,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello from file") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "search_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "todo_slice") == null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "hello from file") != null);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "tool_requested") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_completed") != null);
}

test "loop enforces the step budget when tool use does not conclude in time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "hello from file\n");

    const config = try makeConfig(std.testing.allocator, workspace_root, 1);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    try std.testing.expectError(VAR1.core.executor.Error.StepLimitExceeded, VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt and tell me the first line.", .{
        .context = &context,
        .sendFn = mockSendToolLoop,
    }));
}
