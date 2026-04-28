const builtin = @import("builtin");
const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeToolCall(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments_json: []const u8,
) !VAR1.types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, "call-1"),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
    };
}

fn execCtx(workspace_root: []const u8) VAR1.tools.ExecutionContext {
    return .{
        .workspace_root = workspace_root,
    };
}

const MockCommandContext = struct {
    allocator: std.mem.Allocator,
    last_command: ?[]u8 = null,

    fn deinit(self: *MockCommandContext) void {
        if (self.last_command) |value| self.allocator.free(value);
    }
};

fn mockCommandRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) anyerror!VAR1.tools.CommandOutput {
    var ctx: *MockCommandContext = @ptrCast(@alignCast(ctx_ptr.?));

    var joined = std.array_list.Managed(u8).init(ctx.allocator);
    errdefer joined.deinit();
    for (argv, 0..) |arg, index| {
        if (index > 0) try joined.writer().writeAll(" ");
        try joined.writer().writeAll(arg);
    }

    if (ctx.last_command) |value| ctx.allocator.free(value);
    ctx.last_command = try joined.toOwnedSlice();

    const stdout = if (std.mem.eql(u8, argv[1], "--files"))
        try allocator.dupe(u8, "src/main.zig\nsrc/tools.zig\n")
    else if (std.mem.eql(u8, argv[1], "search")) blk: {
        const main_path = try std.fmt.allocPrint(allocator, "{s}{c}src{c}main.zig", .{ cwd, std.fs.path.sep, std.fs.path.sep });
        defer allocator.free(main_path);
        const tools_path = try std.fmt.allocPrint(allocator, "{s}{c}src{c}tools.zig", .{ cwd, std.fs.path.sep, std.fs.path.sep });
        defer allocator.free(tools_path);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"hits\":[{{\"path\":{f},\"line\":12,\"column\":1,\"preview\":\"read_file\"}},{{\"path\":{f},\"line\":9,\"column\":1,\"preview\":\"search_files\"}}]}}",
            .{ std.json.fmt(main_path, .{}), std.json.fmt(tools_path, .{}) },
        );
    } else try allocator.dupe(u8, "");

    return .{
        .exit_code = 0,
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, ""),
    };
}

const RecorderCommandContext = struct {
    allocator: std.mem.Allocator,
    last_command: ?[]u8 = null,

    fn deinit(self: *RecorderCommandContext) void {
        if (self.last_command) |value| self.allocator.free(value);
    }
};

fn recordCommand(ctx: *RecorderCommandContext, argv: []const []const u8) !void {
    var joined = std.array_list.Managed(u8).init(ctx.allocator);
    errdefer joined.deinit();
    for (argv, 0..) |arg, index| {
        if (index > 0) try joined.writer().writeAll(" ");
        try joined.writer().writeAll(arg);
    }

    if (ctx.last_command) |value| ctx.allocator.free(value);
    ctx.last_command = try joined.toOwnedSlice();
}

fn mockBackupRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    argv: []const []const u8,
) anyerror!VAR1.tools.CommandOutput {
    const ctx: *RecorderCommandContext = @ptrCast(@alignCast(ctx_ptr.?));
    try recordCommand(ctx, argv);

    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, "backup created"),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn mockNonGitRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    argv: []const []const u8,
) anyerror!VAR1.tools.CommandOutput {
    const ctx: *RecorderCommandContext = @ptrCast(@alignCast(ctx_ptr.?));
    try recordCommand(ctx, argv);

    return .{
        .exit_code = 128,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "fatal: not a git repository"),
    };
}

const MockAgentContext = struct {
    allocator: std.mem.Allocator,
    last_prompt: ?[]u8 = null,

    fn deinit(self: *MockAgentContext) void {
        if (self.last_prompt) |value| self.allocator.free(value);
    }
};

fn mockLaunchAgent(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    prompt: []const u8,
    _: ?[]const u8,
) anyerror![]u8 {
    var ctx: *MockAgentContext = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.last_prompt) |value| ctx.allocator.free(value);
    ctx.last_prompt = try ctx.allocator.dupe(u8, prompt);
    return allocator.dupe(u8, "AGENT_NAME berry-child\nSTATUS running\nPROMPT how many r in strawberry");
}

fn mockAgentStatus(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8, "AGENT_NAME berry-child\nSTATUS running\nSESSION_ID task-child\nPARENT_SESSION_ID task-parent\nTERMINAL false\nLATEST_EVENT_TYPE tool_completed\nLATEST_EVENT_MESSAGE tool completed: write_file");
}

fn mockWaitAgent(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
) anyerror![]u8 {
    return allocator.dupe(u8, "AGENT_NAME berry-child\nSTATUS completed\nSESSION_ID task-child\nPARENT_SESSION_ID task-parent\nWAIT_STATE terminal\nOUTPUT There are 3 r's in strawberry.");
}

fn mockListAgents(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8, "AGENT_NAME berry-child STATUS completed SESSION_ID task-child\n");
}

test "tool socket validates tool definitions through core namespace" {
    try VAR1.core.tools.validateDefinition(std.testing.allocator, .{
        .name = "lookup_ticket",
        .description = "Look up a ticket.",
        .parameters_json = "{\"type\":\"object\",\"additionalProperties\":false}",
    });

    try std.testing.expectError(VAR1.core.tools.sockets.Error.InvalidToolName, VAR1.core.tools.sockets.validateName("lookup-ticket"));
    try std.testing.expectError(VAR1.core.tools.sockets.Error.InvalidParametersSchema, VAR1.core.tools.validateDefinition(std.testing.allocator, .{
        .name = "bad_schema",
        .description = "Bad schema.",
        .parameters_json = "[]",
    }));
}

test "plugin manifest validates declared sockets without loading plugins" {
    const sockets = [_]VAR1.core.plugins.PluginSocket{.{
        .kind = .tool,
        .name = "lookup_ticket",
        .entry = "tools/lookup_ticket",
    }};

    try VAR1.core.plugins.validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = sockets[0..],
    });

    try std.testing.expectError(VAR1.core.plugins.manifest.Error.InvalidPluginId, VAR1.core.plugins.validateManifest(.{
        .id = "Tickets",
        .version = "0.1.0",
    }));

    try std.testing.expectError(VAR1.core.plugins.manifest.Error.InvalidSocketName, VAR1.core.plugins.validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = &.{.{
            .kind = .tool,
            .name = "lookup-ticket",
            .entry = "tools/lookup_ticket",
        }},
    }));
}

test "file tools can create append replace and read within the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"notes/example.txt\",\"content\":\"alpha\\n\"}");
    defer write_call.deinit(std.testing.allocator);
    const write_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), write_call);
    defer std.testing.allocator.free(write_output);

    var append_call = try makeToolCall(std.testing.allocator, "append_file", "{\"path\":\"notes/example.txt\",\"content\":\"beta\\n\"}");
    defer append_call.deinit(std.testing.allocator);
    const append_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), append_call);
    defer std.testing.allocator.free(append_output);

    var replace_call = try makeToolCall(std.testing.allocator, "replace_in_file", "{\"path\":\"notes/example.txt\",\"old_text\":\"beta\",\"new_text\":\"gamma\"}");
    defer replace_call.deinit(std.testing.allocator);
    const replace_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), replace_call);
    defer std.testing.allocator.free(replace_output);

    var read_call = try makeToolCall(std.testing.allocator, "read_file", "{\"path\":\"notes/example.txt\",\"start_line\":1,\"end_line\":2}");
    defer read_call.deinit(std.testing.allocator);
    const read_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), read_call);
    defer std.testing.allocator.free(read_output);

    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "APPENDED_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, replace_output, "REPLACEMENTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_output, "1: alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_output, "2: gamma") != null);
}

test "append primitive preserves existing file content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, "journal.txt" });
    defer std.testing.allocator.free(file_path);

    try VAR1.fsutil.writeText(file_path, "alpha\n");
    try VAR1.fsutil.appendText(file_path, "beta\n");

    const contents = try VAR1.fsutil.readTextAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(contents);

    try std.testing.expectEqualStrings("alpha\nbeta\n", contents);
}

test "file tools reject paths outside the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"../escape.txt\",\"content\":\"blocked\"}");
    defer write_call.deinit(std.testing.allocator);

    try std.testing.expectError(VAR1.fsutil.PathError.PathOutsideWorkspace, VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), write_call));
}

test "list_files defaults to the workspace root and returns relative paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const std = @import(\"std\");\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/view.zig", .data = "pub fn render() void {}\n" });

    var list_call = try makeToolCall(std.testing.allocator, "list_files", "{\"max_results\":10}");
    defer list_call.deinit(std.testing.allocator);
    const list_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), list_call);
    defer std.testing.allocator.free(list_output);

    try std.testing.expect(std.mem.indexOf(u8, list_output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "src/nested/view.zig") != null);
}

test "search_files uses the command runner contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = MockCommandContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    var search_call = try makeToolCall(std.testing.allocator, "search_files", "{\"pattern\":\"read_file\",\"path\":\"src\",\"max_results\":5}");
    defer search_call.deinit(std.testing.allocator);
    const search_output = try VAR1.tools.executeWithRunner(std.testing.allocator, execCtx(workspace_root), search_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    });
    defer std.testing.allocator.free(search_output);

    try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "iex search --json --max-hits 5 read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_output, "src/main.zig:12:read_file") != null);
}

test "legacy rg_search remains a compatibility alias for search_files execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = MockCommandContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    var search_call = try makeToolCall(std.testing.allocator, "rg_search", "{\"pattern\":\"read_file\",\"path\":\"src\",\"max_results\":5}");
    defer search_call.deinit(std.testing.allocator);
    const search_output = try VAR1.tools.executeWithRunner(std.testing.allocator, execCtx(workspace_root), search_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    });
    defer std.testing.allocator.free(search_output);

    try std.testing.expect(std.mem.indexOf(u8, search_output, "\"tool\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_output, "src/tools.zig:9:search_files") != null);
}

test "agent tools use the agent service contract and surface agent tool catalog" {
    var context = MockAgentContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const execution_context = VAR1.tools.ExecutionContext{
        .workspace_root = ".",
        .parent_session_id = "task-parent",
        .agent_service = .{
            .context = &context,
            .launchFn = mockLaunchAgent,
            .statusFn = mockAgentStatus,
            .waitFn = mockWaitAgent,
            .listFn = mockListAgents,
        },
    };

    const catalog = try VAR1.tools.renderCatalog(std.testing.allocator, execution_context);
    defer std.testing.allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "launch_agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "wait_agent") != null);

    var launch_call = try makeToolCall(std.testing.allocator, "launch_agent", "{\"prompt\":\"how many r in strawberry\",\"name\":\"berry-child\"}");
    defer launch_call.deinit(std.testing.allocator);
    const launch_output = try VAR1.tools.execute(std.testing.allocator, execution_context, launch_call);
    defer std.testing.allocator.free(launch_output);
    try std.testing.expect(std.mem.indexOf(u8, launch_output, "berry-child") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.last_prompt.?, "strawberry") != null);

    var status_call = try makeToolCall(std.testing.allocator, "agent_status", "{\"name\":\"berry-child\"}");
    defer status_call.deinit(std.testing.allocator);
    const status_output = try VAR1.tools.execute(std.testing.allocator, execution_context, status_call);
    defer std.testing.allocator.free(status_output);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "LATEST_EVENT_TYPE tool_completed") != null);

    var wait_call = try makeToolCall(std.testing.allocator, "wait_agent", "{\"name\":\"berry-child\",\"timeout_ms\":500}");
    defer wait_call.deinit(std.testing.allocator);
    const wait_output = try VAR1.tools.execute(std.testing.allocator, execution_context, wait_call);
    defer std.testing.allocator.free(wait_output);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "There are 3 r's") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "WAIT_STATE terminal") != null);

    var list_call = try makeToolCall(std.testing.allocator, "list_agents", "{}");
    defer list_call.deinit(std.testing.allocator);
    const list_output = try VAR1.tools.execute(std.testing.allocator, execution_context, list_call);
    defer std.testing.allocator.free(list_output);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "AGENT_NAME berry-child") != null);
}

test "harness tools scaffold and manage canonical root artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var init_call = try makeToolCall(std.testing.allocator, "init_harness", "{}");
    defer init_call.deinit(std.testing.allocator);
    const init_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), init_call);
    defer std.testing.allocator.free(init_output);
    try std.testing.expect(std.mem.indexOf(u8, init_output, "FILES_WRITTEN") != null);

    const harness_readme = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "README.md" });
    defer std.testing.allocator.free(harness_readme);
    try std.testing.expect(VAR1.fsutil.fileExists(harness_readme));

    var task_call = try makeToolCall(
        std.testing.allocator,
        "harness_task",
        "{\"action\":\"upsert\",\"task_name\":\"demo-task\",\"status\":\"in_progress\",\"objective\":\"Finalize the root tool runtime.\",\"scope\":[\"add missing tools\"],\"evidence_roots\":[\"variant-1/src\",\"variant-1/tests\"]}",
    );
    defer task_call.deinit(std.testing.allocator);
    const task_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), task_call);
    defer std.testing.allocator.free(task_output);
    try std.testing.expect(std.mem.indexOf(u8, task_output, "demo-task") != null);

    var todo_call = try makeToolCall(
        std.testing.allocator,
        "harness_todo",
        "{\"action\":\"upsert\",\"category\":\"feature\",\"task_name\":\"demo-task\",\"status\":\"done\",\"objective\":\"Ship the harness tools.\",\"dependencies\":[\"none\"],\"steps_taken\":[\"wired the runtime\"],\"blockers\":[],\"evidence\":[\"tests green\"]}",
    );
    defer todo_call.deinit(std.testing.allocator);
    const todo_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), todo_call);
    defer std.testing.allocator.free(todo_output);
    try std.testing.expect(std.mem.indexOf(u8, todo_output, "todo-slice1.md") != null);

    var changelog_call = try makeToolCall(
        std.testing.allocator,
        "harness_changelog",
        "{\"action\":\"archive_todo\",\"category\":\"feature\",\"task_name\":\"demo-task\",\"slice_name\":\"todo-slice1.md\",\"log_entry\":\"- Completed demo-task tool finalization.\"}",
    );
    defer changelog_call.deinit(std.testing.allocator);
    const changelog_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), changelog_call);
    defer std.testing.allocator.free(changelog_output);
    try std.testing.expect(std.mem.indexOf(u8, changelog_output, "ARCHIVED_TO") != null);

    const archived_todo = try VAR1.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "changelog", "demo-task", "todo-slice1.md" });
    defer std.testing.allocator.free(archived_todo);
    try std.testing.expect(VAR1.fsutil.fileExists(archived_todo));

    var memories_append = try makeToolCall(
        std.testing.allocator,
        "harness_memories",
        "{\"action\":\"append\",\"content\":\"- Learned that the root harness tools must stay inside .var/.\"}",
    );
    defer memories_append.deinit(std.testing.allocator);
    const memories_append_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), memories_append);
    defer std.testing.allocator.free(memories_append_output);
    try std.testing.expect(std.mem.indexOf(u8, memories_append_output, "APPENDED_BYTES") != null);

    var memories_read = try makeToolCall(std.testing.allocator, "harness_memories", "{\"action\":\"read\"}");
    defer memories_read.deinit(std.testing.allocator);
    const memories_read_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), memories_read);
    defer std.testing.allocator.free(memories_read_output);
    try std.testing.expect(std.mem.indexOf(u8, memories_read_output, "root harness tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, memories_read_output, ".var/") != null);

    var research_write = try makeToolCall(
        std.testing.allocator,
        "harness_research",
        "{\"action\":\"write\",\"path\":\"snapshot.md\",\"title\":\"Snapshot\",\"content\":\"U1 runtime snapshot\"}",
    );
    defer research_write.deinit(std.testing.allocator);
    const research_write_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), research_write);
    defer std.testing.allocator.free(research_write_output);
    try std.testing.expect(std.mem.indexOf(u8, research_write_output, "snapshot.md") != null);

    var docs_write = try makeToolCall(
        std.testing.allocator,
        "harness_docs",
        "{\"action\":\"write\",\"path\":\"extra.md\",\"content\":\"# Extra\\n\\nContract note.\"}",
    );
    defer docs_write.deinit(std.testing.allocator);
    const docs_write_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), docs_write);
    defer std.testing.allocator.free(docs_write_output);
    try std.testing.expect(std.mem.indexOf(u8, docs_write_output, "extra.md") != null);
}

test "instruction_ingestion resolves the applicable AGENTS chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try tmp.dir.makePath("apps/feature");
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "root agents\n" });
    try tmp.dir.writeFile(.{ .sub_path = "apps/feature/AGENTS.md", .data = "feature agents\n" });

    var ingest_call = try makeToolCall(
        std.testing.allocator,
        "instruction_ingestion",
        "{\"mode\":\"session-start\",\"target_path\":\"apps/feature\"}",
    );
    defer ingest_call.deinit(std.testing.allocator);
    const ingest_output = try VAR1.tools.execute(std.testing.allocator, execCtx(workspace_root), ingest_call);
    defer std.testing.allocator.free(ingest_output);

    try std.testing.expect(std.mem.indexOf(u8, ingest_output, "MODE session-start") != null);
    try std.testing.expect(std.mem.indexOf(u8, ingest_output, "root agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, ingest_output, "feature agents") != null);
}

test "backup and worktree harness tools use the command runner contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var backup_context = RecorderCommandContext{ .allocator = std.testing.allocator };
    defer backup_context.deinit();

    var backup_call = try makeToolCall(std.testing.allocator, "harness_backup", "{\"label\":\"checkpoint\"}");
    defer backup_call.deinit(std.testing.allocator);
    const backup_output = try VAR1.tools.executeWithRunner(std.testing.allocator, execCtx(workspace_root), backup_call, .{
        .context = &backup_context,
        .runFn = mockBackupRunner,
    });
    defer std.testing.allocator.free(backup_output);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, backup_context.last_command.?, "Compress-Archive") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, backup_context.last_command.?, "zip -r") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, backup_output, "checkpoint") != null);

    var worktree_context = RecorderCommandContext{ .allocator = std.testing.allocator };
    defer worktree_context.deinit();

    var worktree_call = try makeToolCall(std.testing.allocator, "harness_worktree", "{\"action\":\"status\"}");
    defer worktree_call.deinit(std.testing.allocator);
    const worktree_output = try VAR1.tools.executeWithRunner(std.testing.allocator, execCtx(workspace_root), worktree_call, .{
        .context = &worktree_context,
        .runFn = mockNonGitRunner,
    });
    defer std.testing.allocator.free(worktree_output);

    try std.testing.expect(std.mem.indexOf(u8, worktree_context.last_command.?, "rev-parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, worktree_output, "WORKTREE_STATUS disabled") != null);
}

test "tool execution errors include schema guidance for harness todo calls" {
    const error_payload = try VAR1.tools.renderExecutionError(
        std.testing.allocator,
        "harness_todo",
        "InvalidArguments",
        "{\"action\":\"upsert\"}",
    );
    defer std.testing.allocator.free(error_payload);

    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"arguments_json\":\"{\\\"action\\\":\\\"upsert\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"parameters_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "runtime-managed todo slice") != null);
}

test "tool execution errors include search_files contract details for file-not-found loops" {
    const error_payload = try VAR1.tools.renderExecutionError(
        std.testing.allocator,
        "search_files",
        "FileNotFound",
        "{\"pattern\":\"read_file\",\"path\":\"missing\"}",
    );
    defer std.testing.allocator.free(error_payload);

    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"parameters_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"contract_example\":\"{\\\"pattern\\\":\\\"read_file\\\",\\\"path\\\":\\\"src\\\",\\\"glob\\\":\\\"*.zig\\\",\\\"max_results\\\":20}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "Use list_files first when unsure") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "iex executable") != null);
}

test "catalog keeps harness tools out of normal coding contexts" {
    const catalog = try VAR1.tools.renderCatalog(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "harness_todo") == null);
}

test "catalog enables harness tools only for harness-relevant contexts" {
    const catalog = try VAR1.tools.renderCatalog(std.testing.allocator, .{
        .workspace_root = ".",
        .harness_tools_enabled = true,
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "harness_todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "init_harness") != null);
}

test "catalog json exposes schema and example objects for default coding tools" {
    const catalog = try VAR1.tools.renderCatalogJson(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"workspace_root\":\".\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"parameters_schema\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"type\": \"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"contract_example\":{\"path\":\"src/tools.zig\",\"start_line\":1,\"end_line\":80}") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"usage_hint\":\"Pass a file path, not a directory.") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"harness_todo\"") == null);
}

test "agent system prompt teaches schema repair and file-tool roles" {
    const prompt = try VAR1.tools.buildAgentSystemPrompt(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Tool arguments must be valid JSON objects") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "repair the call instead of repeating the same failing arguments") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use list_files first when you do not know the path") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Example JSON: {\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "search_files to search contents") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Keep internal tool mechanics private") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "I will continue once agents complete; if any fail, I will follow up.") != null);
}

test "tool call summary masks child supervision tool names in logs" {
    var calls = [_]VAR1.types.ToolCall{
        try makeToolCall(std.testing.allocator, "launch_agent", "{}"),
        try makeToolCall(std.testing.allocator, "wait_agent", "{}"),
        try makeToolCall(std.testing.allocator, "read_file", "{}"),
    };
    defer for (calls) |call| call.deinit(std.testing.allocator);

    const summary = try VAR1.tools.renderToolCallSummary(std.testing.allocator, calls[0..]);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "child_run_dispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "child_run_wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "launch_agent") == null);
}
