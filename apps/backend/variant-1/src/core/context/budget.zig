const std = @import("std");
const types = @import("../../shared/types.zig");

pub fn estimateText(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return (@as(u64, @intCast(text.len)) + 3) / 4;
}

pub fn estimateChatMessages(messages: []const types.ChatMessage) u64 {
    var total: u64 = 0;
    for (messages) |message| {
        total += 4;
        if (message.content) |content| total += estimateText(content);
        if (message.tool_call_id) |tool_call_id| total += estimateText(tool_call_id);
        for (message.tool_calls) |tool_call| {
            total += estimateText(tool_call.id);
            total += estimateText(tool_call.name);
            total += estimateText(tool_call.arguments_json);
        }
    }
    return total;
}

pub fn thresholdTokens(policy: types.ContextPolicy) u64 {
    if (policy.context_window_tokens == 0) return 0;
    if (policy.reserve_output_tokens >= policy.context_window_tokens) return 0;

    const ratio_threshold = (policy.context_window_tokens * policy.compact_at_ratio_milli) / 1000;
    const reserve_threshold = policy.context_window_tokens - policy.reserve_output_tokens;
    return @min(ratio_threshold, reserve_threshold);
}

pub fn shouldCompact(estimated_tokens: u64, policy: types.ContextPolicy) bool {
    if (!policy.auto_compaction) return false;
    const threshold = thresholdTokens(policy);
    return threshold > 0 and estimated_tokens >= threshold;
}

test "context budget threshold respects ratio and reserve" {
    const policy = types.ContextPolicy{
        .context_window_tokens = 1000,
        .compact_at_ratio_milli = 900,
        .reserve_output_tokens = 250,
    };

    try std.testing.expectEqual(@as(u64, 750), thresholdTokens(policy));
    try std.testing.expect(!shouldCompact(749, policy));
    try std.testing.expect(shouldCompact(750, policy));
}
