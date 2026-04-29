const std = @import("std");
const types = @import("../../shared/types.zig");

pub const Error = error{
    InvalidValue,
};

const settings_path_parts = [_][]const u8{ ".var", "config", "settings.toml" };

pub fn loadContextPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    defaults: types.ContextPolicy,
) !types.ContextPolicy {
    const settings_path = try std.fs.path.join(allocator, &.{ workspace_root, settings_path_parts[0], settings_path_parts[1], settings_path_parts[2] });
    defer allocator.free(settings_path);

    const content = std.fs.cwd().readFileAlloc(allocator, settings_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return defaults,
        else => return err,
    };
    defer allocator.free(content);

    return parseContextPolicy(content, defaults);
}

pub fn parseContextPolicy(content: []const u8, defaults: types.ContextPolicy) !types.ContextPolicy {
    var policy = defaults;
    var in_context_section = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line_without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') return Error.InvalidValue;
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            in_context_section = std.mem.eql(u8, section, "context");
            continue;
        }

        if (!in_context_section) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse return Error.InvalidValue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t");
        const value = std.mem.trim(u8, line[separator_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return Error.InvalidValue;

        if (std.mem.eql(u8, key, "auto_compaction")) {
            policy.auto_compaction = try parseBool(value);
        } else if (std.mem.eql(u8, key, "manual_compaction")) {
            policy.manual_compaction = try parseBool(value);
        } else if (std.mem.eql(u8, key, "context_window_tokens")) {
            policy.context_window_tokens = try parseUnsigned(u64, value);
        } else if (std.mem.eql(u8, key, "compact_at_ratio_milli")) {
            policy.compact_at_ratio_milli = try parseRatioMilli(value);
        } else if (std.mem.eql(u8, key, "compact_at_ratio")) {
            policy.compact_at_ratio_milli = try parseFloatRatioMilli(value);
        } else if (std.mem.eql(u8, key, "reserve_output_tokens")) {
            policy.reserve_output_tokens = try parseUnsigned(u64, value);
        } else if (std.mem.eql(u8, key, "keep_recent_messages")) {
            policy.keep_recent_messages = try parseUnsigned(usize, value);
        } else if (std.mem.eql(u8, key, "max_entries_per_checkpoint")) {
            policy.max_entries_per_checkpoint = try parseUnsigned(usize, value);
        } else if (std.mem.eql(u8, key, "aggressiveness_milli")) {
            policy.aggressiveness_milli = try parseRatioMilli(value);
        } else if (std.mem.eql(u8, key, "retry_on_provider_overflow")) {
            policy.retry_on_provider_overflow = try parseBool(value);
        }
    }

    try validate(policy);
    return policy;
}

fn stripComment(line: []const u8) []const u8 {
    const comment_index = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..comment_index];
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return Error.InvalidValue;
}

fn parseUnsigned(comptime T: type, value: []const u8) !T {
    return std.fmt.parseUnsigned(T, trimQuotes(value), 10) catch return Error.InvalidValue;
}

fn parseRatioMilli(value: []const u8) !u16 {
    const parsed = try parseUnsigned(u16, value);
    if (parsed > 1000) return Error.InvalidValue;
    return parsed;
}

fn parseFloatRatioMilli(value: []const u8) !u16 {
    const parsed = std.fmt.parseFloat(f64, trimQuotes(value)) catch return Error.InvalidValue;
    if (parsed <= 0 or parsed > 1) return Error.InvalidValue;
    return @intFromFloat(@round(parsed * 1000));
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn validate(policy: types.ContextPolicy) !void {
    if (policy.context_window_tokens == 0) return Error.InvalidValue;
    if (policy.compact_at_ratio_milli == 0 or policy.compact_at_ratio_milli > 1000) return Error.InvalidValue;
    if (policy.reserve_output_tokens >= policy.context_window_tokens) return Error.InvalidValue;
    if (policy.keep_recent_messages == 0) return Error.InvalidValue;
    if (policy.aggressiveness_milli > 1000) return Error.InvalidValue;
}

test "settings parse context policy TOML" {
    const policy = try parseContextPolicy(
        \\[context]
        \\auto_compaction = false
        \\manual_compaction = true
        \\context_window_tokens = 128000
        \\compact_at_ratio = 0.75
        \\reserve_output_tokens = 4096
        \\keep_recent_messages = 6
        \\max_entries_per_checkpoint = 2
        \\aggressiveness_milli = 500
        \\retry_on_provider_overflow = false
        \\
    , .{});

    try std.testing.expect(!policy.auto_compaction);
    try std.testing.expect(policy.manual_compaction);
    try std.testing.expectEqual(@as(u64, 128_000), policy.context_window_tokens);
    try std.testing.expectEqual(@as(u16, 750), policy.compact_at_ratio_milli);
    try std.testing.expectEqual(@as(u64, 4_096), policy.reserve_output_tokens);
    try std.testing.expectEqual(@as(usize, 6), policy.keep_recent_messages);
    try std.testing.expectEqual(@as(usize, 2), policy.max_entries_per_checkpoint);
    try std.testing.expectEqual(@as(u16, 500), policy.aggressiveness_milli);
    try std.testing.expect(!policy.retry_on_provider_overflow);
}
