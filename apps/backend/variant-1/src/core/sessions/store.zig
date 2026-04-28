const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

pub const InitSessionOptions = struct {
    status: types.SessionStatus = .initialized,
    parent_session_id: ?[]const u8 = null,
    continued_from_session_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
};

const ParsedSessionRecord = struct {
    id: []const u8,
    prompt: []const u8,
    status: []const u8,
    parent_session_id: ?[]const u8 = null,
    continued_from_session_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
    failure_reason: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const ParsedSessionEvent = struct {
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
};

const ParsedSessionMessage = struct {
    id: []const u8,
    seq: u64,
    role: []const u8,
    content: []const u8,
    timestamp_ms: i64,
};

const ParsedContextCheckpoint = struct {
    id: []const u8,
    type: []const u8 = "summary_checkpoint",
    created_at_ms: i64,
    source_seq_start: u64,
    source_seq_end: u64,
    first_kept_seq: u64,
    tokens_before_estimate: u64 = 0,
    tokens_after_estimate: u64 = 0,
    aggressiveness_milli: u16 = 350,
    compacted_entry_count: u32 = 0,
    trigger: []const u8,
    summary: []const u8,
};

pub fn ensureStoreReady(allocator: std.mem.Allocator, workspace_root: []const u8) !void {
    const sessions_root = try sessionsRootPath(allocator, workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return;

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const session_path = try sessionFilePath(allocator, workspace_root, entry.name);
        defer allocator.free(session_path);
        if (!fsutil.fileExists(session_path)) continue;

        const session = try readSessionRecordRaw(allocator, session_path);
        defer session.deinit(allocator);
        try writeSessionRecord(allocator, workspace_root, session);
    }
}

pub fn initSession(allocator: std.mem.Allocator, workspace_root: []const u8, prompt: []const u8) !types.SessionRecord {
    return initSessionWithOptions(allocator, workspace_root, prompt, .{});
}

pub fn initSessionWithOptions(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt: []const u8,
    options: InitSessionOptions,
) !types.SessionRecord {
    try ensureStoreReady(allocator, workspace_root);

    const now = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    const id = try std.fmt.allocPrint(allocator, "session-{d}-{x}", .{ now, nonce });
    errdefer allocator.free(id);

    const prompt_copy = try allocator.dupe(u8, prompt);
    errdefer allocator.free(prompt_copy);

    const parent_session_id = if (options.parent_session_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (parent_session_id) |value| allocator.free(value);
    const continued_from_session_id = if (options.continued_from_session_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (continued_from_session_id) |value| allocator.free(value);
    const display_name = if (options.display_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_name) |value| allocator.free(value);
    const agent_profile = if (options.agent_profile) |value| try allocator.dupe(u8, value) else null;
    errdefer if (agent_profile) |value| allocator.free(value);

    const session = types.SessionRecord{
        .id = id,
        .prompt = prompt_copy,
        .status = options.status,
        .parent_session_id = parent_session_id,
        .continued_from_session_id = continued_from_session_id,
        .display_name = display_name,
        .agent_profile = agent_profile,
        .created_at_ms = now,
        .updated_at_ms = now,
    };

    try writeSessionRecord(allocator, workspace_root, session);
    try ensureInitialSessionMessage(allocator, workspace_root, session);
    return session;
}

pub fn readSessionRecord(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !types.SessionRecord {
    try ensureStoreReady(allocator, workspace_root);

    const session_path = try sessionFilePath(allocator, workspace_root, session_id);
    defer allocator.free(session_path);

    const content = try fsutil.readTextAlloc(allocator, session_path);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(ParsedSessionRecord, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .id = try allocator.dupe(u8, parsed.value.id),
        .prompt = try allocator.dupe(u8, parsed.value.prompt),
        .status = try types.parseStatusLabel(parsed.value.status),
        .parent_session_id = if (parsed.value.parent_session_id) |value| try allocator.dupe(u8, value) else null,
        .continued_from_session_id = if (parsed.value.continued_from_session_id) |value| try allocator.dupe(u8, value) else null,
        .display_name = if (parsed.value.display_name) |value| try allocator.dupe(u8, value) else null,
        .agent_profile = if (parsed.value.agent_profile) |value| try allocator.dupe(u8, value) else null,
        .failure_reason = if (parsed.value.failure_reason) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = parsed.value.created_at_ms,
        .updated_at_ms = parsed.value.updated_at_ms,
    };
}

pub fn sessionExists(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) !bool {
    try ensureStoreReady(allocator, workspace_root);
    const path = try sessionFilePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    return fsutil.fileExists(path);
}

pub fn writeSessionRecord(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: types.SessionRecord,
) !void {
    const session_path = try sessionFilePath(allocator, workspace_root, session.id);
    defer allocator.free(session_path);

    const payload = .{
        .id = session.id,
        .prompt = session.prompt,
        .status = types.statusLabel(session.status),
        .parent_session_id = session.parent_session_id,
        .continued_from_session_id = session.continued_from_session_id,
        .display_name = session.display_name,
        .agent_profile = session.agent_profile,
        .failure_reason = session.failure_reason,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = session.updated_at_ms,
    };
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(payload, .{ .whitespace = .indent_2 }),
    });
    defer allocator.free(json);

    try fsutil.writeText(session_path, json);
}

pub fn setSessionStatus(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: *types.SessionRecord,
    status: types.SessionStatus,
) !void {
    session.status = status;
    session.updated_at_ms = std.time.milliTimestamp();
    if (status != .failed and session.failure_reason != null) {
        allocator.free(session.failure_reason.?);
        session.failure_reason = null;
    }
    try writeSessionRecord(allocator, workspace_root, session.*);
}

pub fn setSessionPrompt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: *types.SessionRecord,
    prompt: []const u8,
    status: types.SessionStatus,
) !void {
    allocator.free(session.prompt);
    session.prompt = try allocator.dupe(u8, prompt);
    session.status = status;
    session.updated_at_ms = std.time.milliTimestamp();
    if (status != .failed and session.failure_reason != null) {
        allocator.free(session.failure_reason.?);
        session.failure_reason = null;
    }
    try writeSessionRecord(allocator, workspace_root, session.*);
}

pub fn setSessionFailure(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: *types.SessionRecord,
    failure_reason: []const u8,
) !void {
    if (session.failure_reason) |value| allocator.free(value);
    session.failure_reason = try allocator.dupe(u8, failure_reason);
    session.status = .failed;
    session.updated_at_ms = std.time.milliTimestamp();
    try writeSessionRecord(allocator, workspace_root, session.*);
}

pub fn appendEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    event: types.SessionEvent,
) !void {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(event, .{}),
    });
    defer allocator.free(jsonl);

    try fsutil.appendText(events_path, jsonl);
}

pub fn readLatestEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?types.SessionEvent {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);

    if (!fsutil.fileExists(events_path)) return null;

    const content = try fsutil.readTextAlloc(allocator, events_path);
    defer allocator.free(content);

    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        var parsed = std.json.parseFromSlice(ParsedSessionEvent, allocator, content[start..end], .{
            .ignore_unknown_fields = true,
        }) catch {
            end = if (start == 0) 0 else start - 1;
            continue;
        };
        defer parsed.deinit();

        return .{
            .event_type = try allocator.dupe(u8, parsed.value.event_type),
            .message = try allocator.dupe(u8, parsed.value.message),
            .timestamp_ms = parsed.value.timestamp_ms,
        };
    }

    return null;
}

pub fn readEvents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]types.SessionEvent {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);

    if (!fsutil.fileExists(events_path)) return allocator.alloc(types.SessionEvent, 0);

    const content = try fsutil.readTextAlloc(allocator, events_path);
    defer allocator.free(content);

    var events = std.array_list.Managed(types.SessionEvent).init(allocator);
    errdefer {
        for (events.items) |event| event.deinit(allocator);
        events.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(ParsedSessionEvent, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        try events.append(.{
            .event_type = try allocator.dupe(u8, parsed.value.event_type),
            .message = try allocator.dupe(u8, parsed.value.message),
            .timestamp_ms = parsed.value.timestamp_ms,
        });
    }

    return events.toOwnedSlice();
}

pub fn readSessionMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]types.SessionMessage {
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);

    if (!fsutil.fileExists(messages_path)) return allocator.alloc(types.SessionMessage, 0);

    return readSessionMessagesFromPath(allocator, messages_path);
}

pub fn appendSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    role: types.SessionMessageRole,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);

    if (!fsutil.fileExists(messages_path)) {
        try writeSessionMessages(allocator, messages_path, &.{});
    }

    const next_seq = try nextSessionMessageSeq(allocator, messages_path);
    const message_id = try sessionMessageId(allocator, next_seq);
    defer allocator.free(message_id);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .id = message_id,
            .seq = next_seq,
            .role = types.sessionMessageRoleLabel(role),
            .content = content,
            .timestamp_ms = timestamp_ms,
        }, .{}),
    });
    defer allocator.free(jsonl);

    try fsutil.appendText(messages_path, jsonl);
}

pub fn upsertAssistantSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    return appendSessionMessage(allocator, workspace_root, session_id, .assistant, content, timestamp_ms);
}

pub fn appendContextCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    checkpoint: types.ContextCheckpoint,
) !void {
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .id = checkpoint.id,
            .type = checkpoint.entry_type,
            .created_at_ms = checkpoint.created_at_ms,
            .source_seq_start = checkpoint.source_seq_start,
            .source_seq_end = checkpoint.source_seq_end,
            .first_kept_seq = checkpoint.first_kept_seq,
            .tokens_before_estimate = checkpoint.tokens_before_estimate,
            .tokens_after_estimate = checkpoint.tokens_after_estimate,
            .aggressiveness_milli = checkpoint.aggressiveness_milli,
            .compacted_entry_count = checkpoint.compacted_entry_count,
            .trigger = checkpoint.trigger,
            .summary = checkpoint.summary,
        }, .{}),
    });
    defer allocator.free(jsonl);

    try fsutil.appendText(context_path, jsonl);
}

pub fn readLatestContextCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?types.ContextCheckpoint {
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    if (!fsutil.fileExists(context_path)) return null;

    const content = try fsutil.readTextAlloc(allocator, context_path);
    defer allocator.free(content);

    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        const line = std.mem.trim(u8, content[start..end], " \r");
        if (line.len > 0) {
            var parsed = std.json.parseFromSlice(ParsedContextCheckpoint, allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch {
                end = if (start == 0) 0 else start - 1;
                continue;
            };
            defer parsed.deinit();

            return .{
                .id = try allocator.dupe(u8, parsed.value.id),
                .entry_type = try allocator.dupe(u8, parsed.value.type),
                .created_at_ms = parsed.value.created_at_ms,
                .source_seq_start = parsed.value.source_seq_start,
                .source_seq_end = parsed.value.source_seq_end,
                .first_kept_seq = parsed.value.first_kept_seq,
                .tokens_before_estimate = parsed.value.tokens_before_estimate,
                .tokens_after_estimate = parsed.value.tokens_after_estimate,
                .aggressiveness_milli = parsed.value.aggressiveness_milli,
                .compacted_entry_count = parsed.value.compacted_entry_count,
                .trigger = try allocator.dupe(u8, parsed.value.trigger),
                .summary = try allocator.dupe(u8, parsed.value.summary),
            };
        }

        end = if (start == 0) 0 else start - 1;
    }

    return null;
}

pub fn listSessionRecords(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]types.SessionRecord {
    try ensureStoreReady(allocator, workspace_root);

    const sessions_root = try sessionsRootPath(allocator, workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return allocator.alloc(types.SessionRecord, 0);

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var sessions = std.array_list.Managed(types.SessionRecord).init(allocator);
    errdefer {
        for (sessions.items) |session| session.deinit(allocator);
        sessions.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const session = readSessionRecord(allocator, workspace_root, entry.name) catch continue;
        try sessions.append(session);
    }

    std.mem.sortUnstable(types.SessionRecord, sessions.items, {}, struct {
        fn lessThan(_: void, left: types.SessionRecord, right: types.SessionRecord) bool {
            if (left.updated_at_ms == right.updated_at_ms) {
                return left.created_at_ms > right.created_at_ms;
            }
            return left.updated_at_ms > right.updated_at_ms;
        }
    }.lessThan);

    return sessions.toOwnedSlice();
}

pub fn writeOutput(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    output: []const u8,
) !void {
    const output_path = try outputFilePath(allocator, workspace_root, session_id);
    defer allocator.free(output_path);
    try fsutil.writeText(output_path, output);
}

pub fn readOutput(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?[]u8 {
    const output_path = try outputFilePath(allocator, workspace_root, session_id);
    defer allocator.free(output_path);

    if (!fsutil.fileExists(output_path)) return null;
    const output = try fsutil.readTextAlloc(allocator, output_path);
    return output;
}

fn ensureInitialSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: types.SessionRecord,
) !void {
    const messages_path = try messagesFilePath(allocator, workspace_root, session.id);
    defer allocator.free(messages_path);

    if (fsutil.fileExists(messages_path)) return;

    try appendSessionMessage(allocator, workspace_root, session.id, .user, session.prompt, session.created_at_ms);
}

fn readSessionMessagesFromPath(
    allocator: std.mem.Allocator,
    messages_path: []const u8,
) ![]types.SessionMessage {
    const content = try fsutil.readTextAlloc(allocator, messages_path);
    defer allocator.free(content);

    var messages = std.array_list.Managed(types.SessionMessage).init(allocator);
    errdefer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(ParsedSessionMessage, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        try messages.append(.{
            .id = try allocator.dupe(u8, parsed.value.id),
            .seq = parsed.value.seq,
            .role = try types.parseSessionMessageRole(parsed.value.role),
            .content = try allocator.dupe(u8, parsed.value.content),
            .timestamp_ms = parsed.value.timestamp_ms,
        });
    }

    return messages.toOwnedSlice();
}

fn writeSessionMessages(
    allocator: std.mem.Allocator,
    messages_path: []const u8,
    messages: []const types.SessionMessage,
) !void {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    const writer = body.writer();

    for (messages) |message| {
        try writer.print("{f}\n", .{
            std.json.fmt(.{
                .id = message.id,
                .seq = message.seq,
                .role = types.sessionMessageRoleLabel(message.role),
                .content = message.content,
                .timestamp_ms = message.timestamp_ms,
            }, .{}),
        });
    }

    try fsutil.writeText(messages_path, body.items);
}

pub fn sessionsRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions" });
}

pub fn sessionDirPath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", session_id });
}

pub fn sessionFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", session_id, "session.json" });
}

fn eventsFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", session_id, "events.jsonl" });
}

fn messagesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", session_id, "messages.jsonl" });
}

pub fn contextFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", session_id, "context.jsonl" });
}

fn outputFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", session_id, "output.txt" });
}

fn nextSessionMessageSeq(
    allocator: std.mem.Allocator,
    messages_path: []const u8,
) !u64 {
    if (!fsutil.fileExists(messages_path)) return 1;

    const messages = try readSessionMessagesFromPath(allocator, messages_path);
    defer types.deinitSessionMessages(allocator, messages);

    var max_seq: u64 = 0;
    for (messages) |message| {
        if (message.seq > max_seq) max_seq = message.seq;
    }
    return max_seq + 1;
}

fn sessionMessageId(allocator: std.mem.Allocator, seq: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "msg-{d}", .{seq});
}

fn readSessionRecordRaw(
    allocator: std.mem.Allocator,
    session_path: []const u8,
) !types.SessionRecord {
    const content = try fsutil.readTextAlloc(allocator, session_path);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(ParsedSessionRecord, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .id = try allocator.dupe(u8, parsed.value.id),
        .prompt = try allocator.dupe(u8, parsed.value.prompt),
        .status = try types.parseStatusLabel(parsed.value.status),
        .parent_session_id = if (parsed.value.parent_session_id) |value| try allocator.dupe(u8, value) else null,
        .continued_from_session_id = if (parsed.value.continued_from_session_id) |value| try allocator.dupe(u8, value) else null,
        .display_name = if (parsed.value.display_name) |value| try allocator.dupe(u8, value) else null,
        .agent_profile = if (parsed.value.agent_profile) |value| try allocator.dupe(u8, value) else null,
        .failure_reason = if (parsed.value.failure_reason) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = parsed.value.created_at_ms,
        .updated_at_ms = parsed.value.updated_at_ms,
    };
}
