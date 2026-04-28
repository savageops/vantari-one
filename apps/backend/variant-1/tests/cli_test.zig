const std = @import("std");
const VAR1 = @import("VAR1");

test "cli resolvePromptInput reads prompt files and trims trailing newlines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "prompt.txt",
        .data = "Count the lowercase letter r in strawberry.\n",
    });

    const prompt_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/prompt.txt",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(prompt_path);

    const prompt = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, null, prompt_path);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("Count the lowercase letter r in strawberry.", prompt);
}

test "cli resolvePromptInput prefers inline prompt when present" {
    const prompt = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, "inline prompt", null);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("inline prompt", prompt);
}

test "cli resolvePromptInput returns empty prompt for resume-only runs" {
    const prompt = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, null, null);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("", prompt);
}

test "cli root help advertises command discovery and tools json export" {
    const help = VAR1.clients.cli.helpText(null).?;

    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 <command> [flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 health") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 tools --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 help <command>") != null);
}

test "cli run help documents prompt-source exclusivity and session resume semantics" {
    const help = VAR1.clients.cli.helpText("run").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "--prompt-file <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session-id <session-id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Exactly one prompt source is allowed") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "reuse its stored prompt") != null);
}

test "cli tools help documents schema fields" {
    const help = VAR1.clients.cli.helpText("tools").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "\"parameters_schema\": { ... }") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "\"contract_example\": { ... }") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Workspace-state tools remain relevance-gated") != null);
}

test "cli health help documents config-only readiness output" {
    const help = VAR1.clients.cli.helpText("health").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "\"base_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "\"auth_provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "does not send a model completion request") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 health --json") != null);
}

test "cli serve help documents canonical bridge routes only" {
    const help = VAR1.clients.cli.helpText("serve").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "POST /rpc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "GET  /events") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "GET  /api/health") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "/api/tasks") == null);
}
