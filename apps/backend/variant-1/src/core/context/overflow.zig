const std = @import("std");

const exclusion_patterns = [_][]const u8{
    "rate limit",
    "too many requests",
    "throttl",
    "service unavailable",
};

const overflow_patterns = [_][]const u8{
    "context_length_exceeded",
    "model_context_window_exceeded",
    "request_too_large",
    "prompt is too long",
    "prompt too long",
    "maximum context length",
    "exceeds the context window",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "too many tokens",
    "token limit exceeded",
    "input is too long",
};

pub fn isContextOverflowText(text: []const u8) bool {
    if (text.len == 0) return false;

    for (exclusion_patterns) |pattern| {
        if (std.ascii.indexOfIgnoreCase(text, pattern) != null) return false;
    }

    for (overflow_patterns) |pattern| {
        if (std.ascii.indexOfIgnoreCase(text, pattern) != null) return true;
    }

    return false;
}

test "overflow classifier separates context overflow from rate limiting" {
    try std.testing.expect(isContextOverflowText("This model's maximum context length is 128000 tokens."));
    try std.testing.expect(isContextOverflowText("{\"error\":{\"code\":\"context_length_exceeded\"}}"));
    try std.testing.expect(!isContextOverflowText("Too many requests: rate limit exceeded."));
}
