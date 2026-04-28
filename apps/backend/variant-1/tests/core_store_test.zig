const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeConfig(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    harness_max_steps: usize,
) !VAR1.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "gemma-4-e2b-it"),
        .harness_max_steps = harness_max_steps,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn makeContextCheckpoint(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_seq_end: u64,
    first_kept_seq: u64,
    summary: []const u8,
) !VAR1.types.ContextCheckpoint {
    return .{
        .id = try allocator.dupe(u8, id),
        .entry_type = try allocator.dupe(u8, "summary_checkpoint"),
        .created_at_ms = std.time.milliTimestamp(),
        .source_seq_start = 1,
        .source_seq_end = source_seq_end,
        .first_kept_seq = first_kept_seq,
        .tokens_before_estimate = 100,
        .tokens_after_estimate = 25,
        .trigger = try allocator.dupe(u8, "manual"),
        .summary = try allocator.dupe(u8, summary),
    };
}

test "config loader reads variant env values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.fsutil.writeText(env_path,
        \\OPENAI_BASE_URL=http://127.0.0.1:1234
        \\OPENAI_API_KEY=test-key
        \\OPENAI_MODEL=test-model
        \\HARNESS_MAX_STEPS=4
        \\HARNESS_WORKSPACE=.
        \\
    );

    const config = try VAR1.config.loadFromEnvFile(std.testing.allocator, env_path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("http://127.0.0.1:1234", config.openai_base_url);
    try std.testing.expectEqualStrings("test-key", config.openai_api_key);
    try std.testing.expectEqualStrings("test-model", config.openai_model);
    try std.testing.expectEqual(@as(usize, 4), config.harness_max_steps);
}

test "config loader rejects missing required keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.fsutil.writeText(env_path,
        \\OPENAI_BASE_URL=http://127.0.0.1:1234
        \\OPENAI_MODEL=test-model
        \\
    );

    try std.testing.expectError(VAR1.config.Error.MissingKey, VAR1.config.loadFromEnvFile(std.testing.allocator, env_path));
}

test "config loader ignores commented backup provider entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.fsutil.writeText(env_path,
        \\# Backup local provider
        \\# OPENAI_BASE_URL=http://127.0.0.1:1234
        \\# OPENAI_API_KEY=local-key
        \\# OPENAI_MODEL=local-model
        \\OPENAI_BASE_URL=https://api.z.ai/api/coding/paas/v4
        \\OPENAI_API_KEY=active-key
        \\OPENAI_MODEL=GLM-5.1
        \\HARNESS_MAX_STEPS=10
        \\HARNESS_WORKSPACE=.
        \\
    );

    const config = try VAR1.config.loadFromEnvFile(std.testing.allocator, env_path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://api.z.ai/api/coding/paas/v4", config.openai_base_url);
    try std.testing.expectEqualStrings("active-key", config.openai_api_key);
    try std.testing.expectEqualStrings("GLM-5.1", config.openai_model);
    try std.testing.expectEqual(@as(usize, 10), config.harness_max_steps);
}

test "loadDefault canonicalizes relative workspace root to an absolute current directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.fsutil.writeText(env_path,
        \\OPENAI_BASE_URL=http://127.0.0.1:1234
        \\OPENAI_API_KEY=test-key
        \\OPENAI_MODEL=test-model
        \\HARNESS_MAX_STEPS=4
        \\HARNESS_WORKSPACE=.
        \\
    );

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const expected_root = try std.fs.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(expected_root);

    const config = try VAR1.config.loadDefault(std.testing.allocator, ".");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(expected_root, config.workspace_root);
}

test "loadDefault seeds canonical auth state from env and then prefers auth ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.fsutil.writeText(env_path,
        \\OPENAI_BASE_URL=https://api.z.ai/api/coding/paas/v4
        \\OPENAI_API_KEY=env-key
        \\OPENAI_MODEL=GLM-5.1
        \\HARNESS_MAX_STEPS=4
        \\HARNESS_WORKSPACE=.
        \\
    );

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const seeded_config = try VAR1.config.loadDefault(std.testing.allocator, ".");
    defer seeded_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("env-key", seeded_config.openai_api_key);
    try std.testing.expectEqualStrings("zai", seeded_config.auth_provider.?);
    try std.testing.expectEqualStrings("GLM-5.1", seeded_config.subscription_plan_label.?);

    const auth_path = try VAR1.auth_store.authFilePath(std.testing.allocator, seeded_config.workspace_root);
    defer std.testing.allocator.free(auth_path);
    try std.testing.expect(VAR1.fsutil.fileExists(auth_path));

    try VAR1.fsutil.writeText(auth_path,
        \\{
        \\  "version": 1,
        \\  "active_provider": "zai",
        \\  "providers": {
        \\    "zai": {
        \\      "auth_type": "api_key",
        \\      "api_key": "ledger-key",
        \\      "base_url": "https://api.z.ai/api/coding/paas/v4",
        \\      "model": "GLM-5.1",
        \\      "subscription": {
        \\        "plan_id": "zai-coding-plan",
        \\        "plan_label": "GLM-5.1",
        \\        "status": "active",
        \\        "source": "manual",
        \\        "last_verified_at_ms": 100
        \\      },
        \\      "updated_at_ms": 100
        \\    }
        \\  }
        \\}
        \\
    );

    const ledger_config = try VAR1.config.loadDefault(std.testing.allocator, ".");
    defer ledger_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ledger-key", ledger_config.openai_api_key);
    try std.testing.expectEqualStrings("zai", ledger_config.auth_provider.?);
    try std.testing.expectEqualStrings("active", ledger_config.subscription_status.?);
}

test "resolveInWorkspace anchors dot workspace roots against cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const expected_root = try std.fs.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(expected_root);

    const expected_path = try VAR1.fsutil.join(std.testing.allocator, &.{ expected_root, "playground", "hero-page-exercise", "index.html" });
    defer std.testing.allocator.free(expected_path);

    const resolved_path = try VAR1.fsutil.resolveInWorkspace(
        std.testing.allocator,
        ".",
        "playground/hero-page-exercise/index.html",
    );
    defer std.testing.allocator.free(resolved_path);

    try std.testing.expectEqualStrings(expected_path, resolved_path);
    try std.testing.expectError(
        VAR1.fsutil.PathError.PathOutsideWorkspace,
        VAR1.fsutil.resolveInWorkspace(std.testing.allocator, ".", "../escape.txt"),
    );
}

test "store writes session json and event entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSession(std.testing.allocator, workspace_root, "Count the letters.");
    defer session.deinit(std.testing.allocator);

    const session_dir = try VAR1.store.sessionDirPath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(session_dir);

    const session_json = try VAR1.fsutil.join(std.testing.allocator, &.{ session_dir, "session.json" });
    defer std.testing.allocator.free(session_json);
    try std.testing.expect(VAR1.fsutil.fileExists(session_json));

    try VAR1.store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "Session initialized.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    const events_path = try VAR1.fsutil.join(std.testing.allocator, &.{ session_dir, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "session_started") != null);
}

test "store can list sessions newest first and read full event history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var first = try VAR1.store.initSession(std.testing.allocator, workspace_root, "first prompt");
    defer first.deinit(std.testing.allocator);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    var second = try VAR1.store.initSession(std.testing.allocator, workspace_root, "second prompt");
    defer second.deinit(std.testing.allocator);

    try VAR1.store.appendEvent(std.testing.allocator, workspace_root, second.id, .{
        .event_type = "session_started",
        .message = "Session initialized.",
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try VAR1.store.appendEvent(std.testing.allocator, workspace_root, second.id, .{
        .event_type = "assistant_response",
        .message = "Done.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    const sessions = try VAR1.store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.types.deinitSessionRecords(std.testing.allocator, sessions);

    try std.testing.expect(sessions.len >= 2);
    try std.testing.expectEqualStrings(second.id, sessions[0].id);

    const events = try VAR1.store.readEvents(std.testing.allocator, workspace_root, second.id);
    defer VAR1.types.deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("assistant_response", events[1].event_type);
}

test "event readers skip corrupted legacy lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSession(std.testing.allocator, workspace_root, "legacy prompt");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    try VAR1.fsutil.writeText(
        events_path,
        "2133419}\n" ++
            "{\"event_type\":\"assistant_response\",\"message\":\"3\",\"timestamp_ms\":123}\n",
    );

    const latest = try VAR1.store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("assistant_response", latest.?.event_type);

    const events = try VAR1.store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("assistant_response", events[0].event_type);
}

test "initSession produces unique ids for adjacent sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var first = try VAR1.store.initSession(std.testing.allocator, workspace_root, "first");
    defer first.deinit(std.testing.allocator);

    var second = try VAR1.store.initSession(std.testing.allocator, workspace_root, "second");
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(!std.mem.eql(u8, first.id, second.id));
}

test "store round-trips canonical child delegation metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "how many r in strawberry",
        .{
            .status = .initialized,
            .parent_session_id = "task-parent",
            .display_name = "berry-child",
            .agent_profile = "subagent",
        },
    );
    defer session.deinit(std.testing.allocator);

    var loaded = try VAR1.store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.types.SessionStatus.initialized, loaded.status);
    try std.testing.expectEqualStrings("task-parent", loaded.parent_session_id.?);
    try std.testing.expectEqualStrings("berry-child", loaded.display_name.?);
    try std.testing.expectEqualStrings("subagent", loaded.agent_profile.?);
}

test "store round-trips canonical continuation lineage metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "follow-up prompt",
        .{
            .status = .initialized,
            .continued_from_session_id = "task-prior",
        },
    );
    defer session.deinit(std.testing.allocator);

    var loaded = try VAR1.store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.types.SessionStatus.initialized, loaded.status);
    try std.testing.expectEqualStrings("task-prior", loaded.continued_from_session_id.?);
}

test "store seeds and appends canonical session messages on the same session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);

    const messages = try VAR1.store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.types.deinitSessionMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("msg-1", messages[0].id);
    try std.testing.expectEqual(@as(u64, 1), messages[0].seq);
    try std.testing.expectEqual(VAR1.types.SessionMessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Initial prompt", messages[0].content);
    try std.testing.expectEqualStrings("msg-2", messages[1].id);
    try std.testing.expectEqual(@as(u64, 2), messages[1].seq);
    try std.testing.expectEqual(VAR1.types.SessionMessageRole.assistant, messages[1].role);
    try std.testing.expectEqualStrings("Initial answer", messages[1].content);
    try std.testing.expectEqualStrings("msg-3", messages[2].id);
    try std.testing.expectEqual(@as(u64, 3), messages[2].seq);
    try std.testing.expectEqual(VAR1.types.SessionMessageRole.user, messages[2].role);
    try std.testing.expectEqualStrings("Follow-up prompt", messages[2].content);
    try std.testing.expectEqualStrings("msg-4", messages[3].id);
    try std.testing.expectEqual(@as(u64, 4), messages[3].seq);
    try std.testing.expectEqual(VAR1.types.SessionMessageRole.assistant, messages[3].role);
    try std.testing.expectEqualStrings("Follow-up answer", messages[3].content);
}

test "store reads legacy message rows by assigning stable ids and sequence numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    const messages_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);
    try VAR1.fsutil.writeText(
        messages_path,
        "{\"role\":\"user\",\"content\":\"old user\",\"timestamp_ms\":100}\n" ++
            "{\"role\":\"assistant\",\"content\":\"old assistant\",\"timestamp_ms\":200}\n",
    );

    const messages = try VAR1.store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.types.deinitSessionMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("msg-1", messages[0].id);
    try std.testing.expectEqual(@as(u64, 1), messages[0].seq);
    try std.testing.expectEqualStrings("old user", messages[0].content);
    try std.testing.expectEqualStrings("msg-2", messages[1].id);
    try std.testing.expectEqual(@as(u64, 2), messages[1].seq);
    try std.testing.expectEqualStrings("old assistant", messages[1].content);
}

test "store appends context checkpoints and reads the latest valid entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    var first = try makeContextCheckpoint(std.testing.allocator, "ctx-1", 2, 3, "Older summary.");
    defer first.deinit(std.testing.allocator);
    try VAR1.store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, first);

    var second = try makeContextCheckpoint(std.testing.allocator, "ctx-2", 4, 5, "Latest summary.");
    defer second.deinit(std.testing.allocator);
    try VAR1.store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, second);

    const context_path = try VAR1.store.contextFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(context_path);
    try VAR1.fsutil.appendText(context_path, "not valid json\n");

    const latest = try VAR1.store.readLatestContextCheckpoint(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |value| value.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("ctx-2", latest.?.id);
    try std.testing.expectEqual(@as(u64, 5), latest.?.first_kept_seq);
    try std.testing.expectEqualStrings("Latest summary.", latest.?.summary);
}

test "context builder emits latest summary plus recent raw transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);

    var checkpoint = try makeContextCheckpoint(std.testing.allocator, "ctx-1", 2, 3, "Initial prompt was answered.");
    defer checkpoint.deinit(std.testing.allocator);
    try VAR1.store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, checkpoint);

    var provider_messages = std.array_list.Managed(VAR1.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    try VAR1.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);

    try std.testing.expectEqual(@as(usize, 3), provider_messages.items.len);
    try std.testing.expectEqual(VAR1.types.MessageRole.user, provider_messages.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Initial prompt was answered.") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Initial prompt\n") == null);
    try std.testing.expectEqualStrings("Follow-up prompt", provider_messages.items[1].content.?);
    try std.testing.expectEqualStrings("Follow-up answer", provider_messages.items[2].content.?);
}

test "store falls back to legacy continuation lineage when messages are absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var first = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "First prompt",
        .{
            .status = .completed,
        },
    );
    defer first.deinit(std.testing.allocator);
    try VAR1.store.writeOutput(std.testing.allocator, workspace_root, first.id, "First answer");

    var second = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "Second prompt",
        .{
            .status = .completed,
            .continued_from_session_id = first.id,
        },
    );
    defer second.deinit(std.testing.allocator);
    try VAR1.store.writeOutput(std.testing.allocator, workspace_root, second.id, "Second answer");

    const messages = try VAR1.store.readSessionMessages(std.testing.allocator, workspace_root, second.id);
    defer VAR1.types.deinitSessionMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("First prompt", messages[0].content);
    try std.testing.expectEqualStrings("First answer", messages[1].content);
    try std.testing.expectEqualStrings("Second prompt", messages[2].content);
    try std.testing.expectEqualStrings("Second answer", messages[3].content);
}

test "store migrates legacy task layout into the canonical session contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const legacy_dir = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".harness", "tasks", "task-legacy" });
    defer std.testing.allocator.free(legacy_dir);

    const legacy_task_json = try VAR1.fsutil.join(std.testing.allocator, &.{ legacy_dir, "task.json" });
    defer std.testing.allocator.free(legacy_task_json);
    const legacy_turns = try VAR1.fsutil.join(std.testing.allocator, &.{ legacy_dir, "turns.jsonl" });
    defer std.testing.allocator.free(legacy_turns);
    const legacy_journal = try VAR1.fsutil.join(std.testing.allocator, &.{ legacy_dir, "journal.jsonl" });
    defer std.testing.allocator.free(legacy_journal);
    const legacy_answer = try VAR1.fsutil.join(std.testing.allocator, &.{ legacy_dir, "answer.txt" });
    defer std.testing.allocator.free(legacy_answer);

    try VAR1.fsutil.writeText(legacy_task_json,
        \\{
        \\  "id": "task-legacy",
        \\  "prompt": "What changed?",
        \\  "status": "completed",
        \\  "parent_task_id": "task-parent",
        \\  "display_name": "legacy-child",
        \\  "agent_profile": "subagent",
        \\  "created_at_ms": 100,
        \\  "updated_at_ms": 200
        \\}
        \\
    );
    try VAR1.fsutil.writeText(
        legacy_turns,
        "{\"role\":\"user\",\"content\":\"What changed?\",\"timestamp_ms\":100}\n" ++
            "{\"role\":\"assistant\",\"content\":\"The store migrated.\",\"timestamp_ms\":200}\n",
    );
    try VAR1.fsutil.writeText(
        legacy_journal,
        "{\"event_type\":\"assistant_response\",\"message\":\"The store migrated.\",\"timestamp_ms\":200}\n",
    );
    try VAR1.fsutil.writeText(legacy_answer, "The store migrated.");

    try VAR1.store.ensureStoreReady(std.testing.allocator, workspace_root);

    const canonical_session_json = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", "task-legacy", "session.json" });
    defer std.testing.allocator.free(canonical_session_json);
    const canonical_messages = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", "task-legacy", "messages.jsonl" });
    defer std.testing.allocator.free(canonical_messages);
    const canonical_events = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", "task-legacy", "events.jsonl" });
    defer std.testing.allocator.free(canonical_events);
    const canonical_output = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", "task-legacy", "output.txt" });
    defer std.testing.allocator.free(canonical_output);
    const old_tasks_root = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".harness", "tasks" });
    defer std.testing.allocator.free(old_tasks_root);

    try std.testing.expect(VAR1.fsutil.fileExists(canonical_session_json));
    try std.testing.expect(VAR1.fsutil.fileExists(canonical_messages));
    try std.testing.expect(VAR1.fsutil.fileExists(canonical_events));
    try std.testing.expect(VAR1.fsutil.fileExists(canonical_output));
    try std.testing.expect(!VAR1.fsutil.fileExists(old_tasks_root));

    var session = try VAR1.store.readSessionRecord(std.testing.allocator, workspace_root, "task-legacy");
    defer session.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("task-parent", session.parent_session_id.?);
    try std.testing.expectEqualStrings("legacy-child", session.display_name.?);

    const messages = try VAR1.store.readSessionMessages(std.testing.allocator, workspace_root, "task-legacy");
    defer VAR1.types.deinitSessionMessages(std.testing.allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("The store migrated.", messages[1].content);

    const events = try VAR1.store.readEvents(std.testing.allocator, workspace_root, "task-legacy");
    defer VAR1.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("assistant_response", events[0].event_type);

    const output = try VAR1.store.readOutput(std.testing.allocator, workspace_root, "task-legacy");
    defer if (output) |value| std.testing.allocator.free(value);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("The store migrated.", output.?);
}

test "agent service resolves child session status from the canonical session store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var completed = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "how many r in strawberry",
        .{
            .status = .completed,
            .parent_session_id = "task-parent",
            .display_name = "berry-child",
            .agent_profile = "subagent",
        },
    );
    defer completed.deinit(std.testing.allocator);
    try VAR1.store.writeOutput(std.testing.allocator, workspace_root, completed.id, "There are 3 r's in strawberry.");
    try VAR1.store.appendEvent(std.testing.allocator, workspace_root, completed.id, .{
        .event_type = "assistant_response",
        .message = "There are 3 r's in strawberry.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    var running = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "Refine the hero page",
        .{
            .status = .running,
            .parent_session_id = "task-parent",
            .display_name = "hero-child",
            .agent_profile = "subagent",
        },
    );
    defer running.deinit(std.testing.allocator);
    try VAR1.store.appendEvent(std.testing.allocator, workspace_root, running.id, .{
        .event_type = "tool_completed",
        .message = "tool completed: write_file",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    var unrelated = try VAR1.store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "ignore me",
        .{
            .status = .running,
            .parent_session_id = "other-parent",
            .display_name = "other-child",
            .agent_profile = "subagent",
        },
    );
    defer unrelated.deinit(std.testing.allocator);

    var service = VAR1.agents.Service.init(&config);
    const handle = service.handle();

    const status_output = try handle.status(std.testing.allocator, "task-parent", "berry-child");
    defer std.testing.allocator.free(status_output);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "SESSION_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "PARENT_SESSION_ID task-parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "OUTPUT There are 3 r's in strawberry.") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "LATEST_EVENT_TYPE assistant_response") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "TERMINAL true") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "LIFECYCLE_STATE completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "NEXT_PARENT_ACTION collect_result") != null);

    const wait_output = try handle.wait(std.testing.allocator, "task-parent", "berry-child", 10);
    defer std.testing.allocator.free(wait_output);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "STATUS completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "WAIT_STATE terminal") != null);

    const running_status_output = try handle.status(std.testing.allocator, "task-parent", "hero-child");
    defer std.testing.allocator.free(running_status_output);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "LATEST_EVENT_MESSAGE tool completed: write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "TERMINAL false") != null);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "LIFECYCLE_STATE processing") != null);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "HEARTBEAT_AGE_MS") != null);

    const timeout_output = try handle.wait(std.testing.allocator, "task-parent", "hero-child", 1);
    defer std.testing.allocator.free(timeout_output);
    try std.testing.expect(std.mem.indexOf(u8, timeout_output, "STATUS running") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeout_output, "WAIT_STATE timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeout_output, "WAIT_TIMEOUT_MS 1") != null);

    const list_output = try handle.list(std.testing.allocator, "task-parent");
    defer std.testing.allocator.free(list_output);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "berry-child") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "hero-child") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "other-child") == null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "SESSION_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "UPDATED_AT_MS") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "LIFECYCLE_STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "NEXT_PARENT_ACTION") != null);
}

test "docs sync writes pending sessions and archives completed sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const snapshot = VAR1.types.ProgressSnapshot{
        .session_id = "task-123",
        .status = "running",
        .prompt = "how many r in strawberry",
        .output = "",
        .updated_at_ms = std.time.milliTimestamp(),
    };

    try VAR1.docs_sync.writePending(std.testing.allocator, workspace_root, snapshot);
    try VAR1.docs_sync.appendLog(std.testing.allocator, workspace_root, "started task-123");

    const pending_path = try VAR1.docs_sync.todoSlicePath(std.testing.allocator, workspace_root, "task-123");
    defer std.testing.allocator.free(pending_path);
    try std.testing.expect(VAR1.fsutil.fileExists(pending_path));

    try VAR1.docs_sync.completeSession(std.testing.allocator, workspace_root, .{
        .session_id = "task-123",
        .status = "completed",
        .prompt = "how many r in strawberry",
        .output = "There are 3 r's in strawberry.",
        .updated_at_ms = std.time.milliTimestamp(),
    });

    const changelog_path = try VAR1.docs_sync.changelogSlicePath(std.testing.allocator, workspace_root, "task-123");
    defer std.testing.allocator.free(changelog_path);

    try std.testing.expect(!VAR1.fsutil.fileExists(pending_path));
    try std.testing.expect(VAR1.fsutil.fileExists(changelog_path));
}

test "docs sync appends human-readable log entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try VAR1.docs_sync.appendLog(std.testing.allocator, workspace_root, "example log event");

    const log_path = try VAR1.docs_sync.runLogPath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(log_path);

    const log_contents = try VAR1.fsutil.readTextAlloc(std.testing.allocator, log_path);
    defer std.testing.allocator.free(log_contents);

    try std.testing.expect(std.mem.indexOf(u8, log_contents, "example log event") != null);
}

test "docs sync reads the run log first and seeds memories when missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try VAR1.docs_sync.ensureRunStart(std.testing.allocator, workspace_root);

    const log_path = try VAR1.docs_sync.runLogPath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(log_path);
    try std.testing.expect(VAR1.fsutil.fileExists(log_path));

    const memories_path = try VAR1.docs_sync.memoriesFilePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(memories_path);
    try std.testing.expect(VAR1.fsutil.fileExists(memories_path));
}
