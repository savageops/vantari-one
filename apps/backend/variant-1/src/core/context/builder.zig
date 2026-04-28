const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");

const summary_prefix =
    "The conversation history before this point was compacted into the following summary:\n\n";

pub fn appendProviderMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session: types.SessionRecord,
) !void {
    const checkpoint = try store.readLatestContextCheckpoint(allocator, workspace_root, session.id);
    if (checkpoint) |value| {
        defer value.deinit(allocator);
        try appendCompactedMessages(allocator, workspace_root, messages, session.id, value);
        return;
    }

    try appendRawMessages(allocator, workspace_root, messages, session.id, 0);
}

fn appendCompactedMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session_id: []const u8,
    checkpoint: types.ContextCheckpoint,
) !void {
    const summary_message = try std.fmt.allocPrint(allocator, "{s}{s}", .{ summary_prefix, checkpoint.summary });
    defer allocator.free(summary_message);

    try messages.append(try types.initTextMessage(allocator, .user, summary_message));
    try appendRawMessages(allocator, workspace_root, messages, session_id, checkpoint.first_kept_seq);
}

fn appendRawMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session_id: []const u8,
    first_kept_seq: u64,
) !void {
    const turns = try store.readSessionMessages(allocator, workspace_root, session_id);
    defer types.deinitSessionMessages(allocator, turns);

    for (turns) |turn| {
        if (first_kept_seq > 0 and turn.seq < first_kept_seq) continue;
        switch (turn.role) {
            .user => try messages.append(try types.initTextMessage(allocator, .user, turn.content)),
            .assistant => try messages.append(try types.initTextMessage(allocator, .assistant, turn.content)),
        }
    }
}
