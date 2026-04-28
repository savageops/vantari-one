const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    InvalidCompactionOptions,
};

pub const CompactOptions = struct {
    keep_recent_messages: usize = 4,
    trigger: []const u8 = "manual",
    max_message_chars: usize = 600,
    aggressiveness_milli: u16 = 350,
    max_entries_per_checkpoint: usize = 0,
};

pub const CompactResult = struct {
    checkpoint: ?types.ContextCheckpoint = null,
    reason: []const u8 = "compacted",

    pub fn deinit(self: CompactResult, allocator: std.mem.Allocator) void {
        if (self.checkpoint) |checkpoint| checkpoint.deinit(allocator);
    }
};

const CompactionPlan = struct {
    source_start_seq: u64,
    source_end_seq: u64,
    segment_start_seq: u64,
    segment_end_seq: u64,
    first_kept_seq: u64,
    compacted_entry_count: u32,
    recompact: bool,
};

pub fn compactSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    options: CompactOptions,
) !CompactResult {
    if (options.keep_recent_messages == 0 or options.trigger.len == 0 or options.max_message_chars == 0 or options.aggressiveness_milli > 1000) {
        return Error.InvalidCompactionOptions;
    }

    var session = try store.readSessionRecord(allocator, workspace_root, session_id);
    defer session.deinit(allocator);

    const messages = try store.readSessionMessages(allocator, workspace_root, session.id);
    defer types.deinitSessionMessages(allocator, messages);

    if (messages.len <= options.keep_recent_messages) {
        return .{ .reason = "not_enough_messages" };
    }

    const latest = try store.readLatestContextCheckpoint(allocator, workspace_root, session.id);
    defer if (latest) |checkpoint| checkpoint.deinit(allocator);

    const plan = buildPlan(messages, latest, options) orelse return .{ .reason = "checkpoint_already_current" };

    const summary = try renderSummary(
        allocator,
        latest,
        messages,
        plan,
        options.aggressiveness_milli,
        options.max_message_chars,
    );
    errdefer allocator.free(summary);

    const checkpoint_id = try checkpointId(allocator);
    errdefer allocator.free(checkpoint_id);

    const entry_type = try allocator.dupe(u8, "summary_checkpoint");
    errdefer allocator.free(entry_type);

    const trigger = try allocator.dupe(u8, options.trigger);
    errdefer allocator.free(trigger);

    const checkpoint = types.ContextCheckpoint{
        .id = checkpoint_id,
        .entry_type = entry_type,
        .created_at_ms = std.time.milliTimestamp(),
        .source_seq_start = plan.source_start_seq,
        .source_seq_end = plan.source_end_seq,
        .first_kept_seq = plan.first_kept_seq,
        .tokens_before_estimate = estimateMessages(messages, plan.source_start_seq, plan.source_end_seq),
        .tokens_after_estimate = estimateText(summary) + estimateMessages(messages, plan.first_kept_seq, null),
        .aggressiveness_milli = options.aggressiveness_milli,
        .compacted_entry_count = plan.compacted_entry_count,
        .trigger = trigger,
        .summary = summary,
    };

    try store.appendContextCheckpoint(allocator, workspace_root, session.id, checkpoint);
    return .{ .checkpoint = checkpoint };
}

fn buildPlan(
    messages: []const types.SessionMessage,
    latest: ?types.ContextCheckpoint,
    options: CompactOptions,
) ?CompactionPlan {
    const eligible_end_index = messages.len - options.keep_recent_messages - 1;
    const eligible_end_seq = messages[eligible_end_index].seq;
    const recompact = if (latest) |checkpoint| options.aggressiveness_milli > checkpoint.aggressiveness_milli else false;
    const start_seq = if (recompact)
        latest.?.source_seq_start
    else if (latest) |checkpoint|
        checkpoint.first_kept_seq
    else
        messages[0].seq;

    if (!recompact and eligible_end_seq < start_seq) return null;

    const start_index = findFirstMessageIndexAtOrAfter(messages, start_seq) orelse return null;
    if (start_index > eligible_end_index) return null;

    var segment_end_index = eligible_end_index;
    if (!recompact and options.max_entries_per_checkpoint > 0) {
        const bounded_end = start_index + options.max_entries_per_checkpoint - 1;
        segment_end_index = @min(bounded_end, eligible_end_index);
    }
    if (segment_end_index < start_index) return null;

    const segment_start_seq = messages[start_index].seq;
    const segment_end_seq = messages[segment_end_index].seq;
    const source_start_seq = if (latest) |checkpoint| checkpoint.source_seq_start else segment_start_seq;
    const source_end_seq = segment_end_seq;
    const first_kept_seq = messages[segment_end_index + 1].seq;

    if (!recompact and latest != null and first_kept_seq <= latest.?.first_kept_seq) return null;

    return .{
        .source_start_seq = source_start_seq,
        .source_end_seq = source_end_seq,
        .segment_start_seq = segment_start_seq,
        .segment_end_seq = segment_end_seq,
        .first_kept_seq = first_kept_seq,
        .compacted_entry_count = @intCast(countMessages(messages, segment_start_seq, segment_end_seq)),
        .recompact = recompact,
    };
}

fn renderSummary(
    allocator: std.mem.Allocator,
    latest: ?types.ContextCheckpoint,
    messages: []const types.SessionMessage,
    plan: CompactionPlan,
    aggressiveness_milli: u16,
    max_message_chars: usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    try writer.print(
        "VAR1 context checkpoint\nsource_range: {d}..{d}\nsegment_range: {d}..{d}\nfirst_kept_seq: {d}\naggressiveness_milli: {d}\ncompacted_entry_count: {d}\n",
        .{
            plan.source_start_seq,
            plan.source_end_seq,
            plan.segment_start_seq,
            plan.segment_end_seq,
            plan.first_kept_seq,
            aggressiveness_milli,
            plan.compacted_entry_count,
        },
    );

    if (latest) |checkpoint| {
        if (plan.recompact) {
            try writer.print("\nreplaces_checkpoint: {s}\n", .{checkpoint.id});
        } else {
            try writer.print("\nprevious_summary:\n{s}\n", .{checkpoint.summary});
        }
    }

    try writer.writeAll("\ncompacted_messages:\n");
    for (messages) |message| {
        if (message.seq < plan.segment_start_seq or message.seq > plan.segment_end_seq) continue;
        try writer.print(
            "- seq={d} role={s} chars={d}: ",
            .{ message.seq, types.sessionMessageRoleLabel(message.role), message.content.len },
        );
        try appendOneLinePrefix(&output, message.content, max_message_chars);
        try writer.writeByte('\n');
    }

    return output.toOwnedSlice();
}

fn findFirstMessageIndexAtOrAfter(messages: []const types.SessionMessage, seq: u64) ?usize {
    for (messages, 0..) |message, index| {
        if (message.seq >= seq) return index;
    }
    return null;
}

fn countMessages(messages: []const types.SessionMessage, first_seq: u64, last_seq: u64) usize {
    var count: usize = 0;
    for (messages) |message| {
        if (message.seq >= first_seq and message.seq <= last_seq) count += 1;
    }
    return count;
}

fn appendOneLinePrefix(output: *std.array_list.Managed(u8), content: []const u8, max_chars: usize) !void {
    const limit = @min(content.len, max_chars);
    for (content[0..limit]) |byte| {
        switch (byte) {
            '\r', '\n', '\t' => try output.append(' '),
            else => try output.append(byte),
        }
    }
    if (content.len > limit) try output.appendSlice("...");
}

fn estimateMessages(messages: []const types.SessionMessage, first_seq: u64, last_seq: ?u64) u64 {
    var chars: u64 = 0;
    for (messages) |message| {
        if (message.seq < first_seq) continue;
        if (last_seq) |max_seq| {
            if (message.seq > max_seq) continue;
        }
        chars += message.content.len;
    }
    return estimateChars(chars);
}

fn estimateText(text: []const u8) u64 {
    return estimateChars(text.len);
}

fn estimateChars(chars: u64) u64 {
    if (chars == 0) return 0;
    return (chars + 3) / 4;
}

fn checkpointId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "ctx-{d}-{x}", .{ std.time.milliTimestamp(), std.crypto.random.int(u64) });
}
