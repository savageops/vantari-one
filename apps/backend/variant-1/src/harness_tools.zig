const builtin = @import("builtin");
const std = @import("std");
const fsutil = @import("fsutil.zig");
const types = @import("types.zig");

pub const definitions = [_]types.ToolDefinition{
    .{
        .name = "init_harness",
        .description = "Scaffold the canonical .var structure for the current workspace without overwriting existing populated files unless explicitly forced.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "force_overwrite": { "type": "boolean", "description": "When true, overwrite the scaffold files owned by init_harness." }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_memories",
        .description = "Read or append the canonical .var memories ledger.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "append"] },
        \\    "content": { "type": "string", "description": "Markdown to append when action is append." }
        \\  },
        \\  "required": ["action"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_changelog",
        .description = "Read or append the canonical .var changelog log, or archive a completed todo slice into .var/changelog/<task-name>/.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "append", "archive_todo"] },
        \\    "content": { "type": "string", "description": "Markdown to append when action is append." },
        \\    "category": { "type": "string", "description": "Todo category when action is archive_todo." },
        \\    "task_name": { "type": "string", "description": "Task slug when action is archive_todo." },
        \\    "slice_name": { "type": "string", "description": "Todo filename when action is archive_todo. Defaults to todo-slice1.md." },
        \\    "log_entry": { "type": "string", "description": "Optional changelog bullet to append after archive_todo succeeds." }
        \\  },
        \\  "required": ["action"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_todo",
        .description = "Read or upsert a canonical .var todo slice under .var/todos/<category>/<task-name>/. The runtime already manages the current run's own todo slice, so use this only for explicit repo-level execution slices.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "upsert"] },
        \\    "category": { "type": "string" },
        \\    "task_name": { "type": "string" },
        \\    "slice_name": { "type": "string", "description": "Todo filename. Defaults to todo-slice1.md." },
        \\    "status": { "type": "string" },
        \\    "objective": { "type": "string" },
        \\    "dependencies": { "type": "array", "items": { "type": "string" } },
        \\    "steps_taken": { "type": "array", "items": { "type": "string" } },
        \\    "blockers": { "type": "array", "items": { "type": "string" } },
        \\    "evidence": { "type": "array", "items": { "type": "string" } }
        \\  },
        \\  "required": ["action", "category", "task_name"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_task",
        .description = "Read or upsert a canonical .var session record under .var/sessions/<task-name>/session.md.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "upsert"] },
        \\    "task_name": { "type": "string" },
        \\    "status": { "type": "string" },
        \\    "objective": { "type": "string" },
        \\    "scope": { "type": "array", "items": { "type": "string" } },
        \\    "evidence_roots": { "type": "array", "items": { "type": "string" } }
        \\  },
        \\  "required": ["action", "task_name"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_research",
        .description = "Read or write research artifacts under .var/research/.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "write"] },
        \\    "path": { "type": "string", "description": "Path relative to .var/research/." },
        \\    "title": { "type": "string", "description": "Optional title used when action is write and content has no markdown heading." },
        \\    "content": { "type": "string", "description": "Markdown body to write when action is write." }
        \\  },
        \\  "required": ["action", "path"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_docs",
        .description = "Read or write canonical harness contract docs under .var/docs/.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["read", "write"] },
        \\    "path": { "type": "string", "description": "Path relative to .var/docs/." },
        \\    "content": { "type": "string", "description": "Markdown body to write when action is write." }
        \\  },
        \\  "required": ["action", "path"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_worktree",
        .description = "Inspect or manage Git worktrees rooted under .var/worktrees/ when the workspace is a real Git checkout.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["status", "list", "add", "remove", "lock", "prune"] },
        \\    "name": { "type": "string", "description": "Worktree directory name under .var/worktrees/ for add, remove, or lock." },
        \\    "ref": { "type": "string", "description": "Optional Git ref for add." },
        \\    "force": { "type": "boolean", "description": "Force remove when action is remove." },
        \\    "reason": { "type": "string", "description": "Optional lock reason when action is lock." }
        \\  },
        \\  "required": ["action"],
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "harness_backup",
        .description = "Create a timestamped workspace backup archive under .var/backup/.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "label": { "type": "string", "description": "Optional suffix to include in the backup filename." }
        \\  },
        \\  "additionalProperties": false
        \\}
        ,
    },
    .{
        .name = "instruction_ingestion",
        .description = "Discover applicable AGENTS.md instructions within the workspace according to the canonical ingestion modes.",
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "mode": { "type": "string", "enum": ["session-start", "on-demand-subtree", "always", "never"] },
        \\    "target_path": { "type": "string", "description": "Optional path inside the workspace whose instruction context should be resolved." }
        \\  },
        \\  "required": ["mode"],
        \\  "additionalProperties": false
        \\}
        ,
    },
};

pub fn handles(tool_name: []const u8) bool {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, tool_name)) return true;
    }
    return false;
}

pub fn execute(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
    runner: anytype,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "init_harness")) {
        return executeInitHarness(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_memories")) {
        return executeHarnessMemories(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_changelog")) {
        return executeHarnessChangelog(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_todo")) {
        return executeHarnessTodo(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_task")) {
        return executeHarnessTask(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_research")) {
        return executeHarnessResearch(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_docs")) {
        return executeHarnessDocs(allocator, workspace_root, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "harness_worktree")) {
        return executeHarnessWorktree(allocator, workspace_root, arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_name, "harness_backup")) {
        return executeHarnessBackup(allocator, workspace_root, arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_name, "instruction_ingestion")) {
        return executeInstructionIngestion(allocator, workspace_root, arguments_json);
    }

    return error.UnknownTool;
}

fn harnessRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var" });
}

fn memoriesPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "memories", "memories.md" });
}

fn changelogLogPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", "_log.md" });
}

fn docsIndexPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "docs", "_index.md" });
}

fn docsArchitecturePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "docs", "architecture.md" });
}

fn docsToolContractsPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "docs", "tool-contracts.md" });
}

fn readmePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "README.md" });
}

fn todoPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    category: []const u8,
    task_name: []const u8,
    slice_name: []const u8,
) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "todos", category, task_name, slice_name });
}

fn changelogSlicePath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_name: []const u8,
    slice_name: []const u8,
) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", task_name, slice_name });
}

fn taskPath(allocator: std.mem.Allocator, workspace_root: []const u8, task_name: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", task_name, "session.md" });
}

fn researchPath(allocator: std.mem.Allocator, workspace_root: []const u8, relative_path: []const u8) ![]u8 {
    const relative = try fsutil.join(allocator, &.{ ".var", "research", relative_path });
    defer allocator.free(relative);
    return fsutil.resolveInWorkspace(allocator, workspace_root, relative);
}

fn docsPath(allocator: std.mem.Allocator, workspace_root: []const u8, relative_path: []const u8) ![]u8 {
    const relative = try fsutil.join(allocator, &.{ ".var", "docs", relative_path });
    defer allocator.free(relative);
    return fsutil.resolveInWorkspace(allocator, workspace_root, relative);
}

fn worktreesRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "worktrees" });
}

fn backupRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "backup" });
}

fn okEnvelope(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":{f},\"content\":{f}}}",
        .{
            std.json.fmt(tool_name, .{}),
            std.json.fmt(content, .{}),
        },
    );
}

fn appendMarkdownBlock(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();
    try line.writer().writeAll(content);
    if (content.len == 0 or content[content.len - 1] != '\n') try line.writer().writeByte('\n');
    try line.writer().writeByte('\n');
    try fsutil.appendText(path, line.items);
}

fn isSafeSegment(segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (std.mem.indexOf(u8, segment, "..") != null) return false;
    for (segment) |byte| {
        if (byte == '/' or byte == '\\') return false;
    }
    return true;
}

const ScaffoldStats = struct {
    directories_created: usize = 0,
    files_written: usize = 0,
    files_skipped: usize = 0,
};

fn ensureDir(path: []const u8, stats: *ScaffoldStats) !void {
    if (fsutil.fileExists(path)) return;
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    stats.directories_created += 1;
}

fn writeTemplateFile(path: []const u8, content: []const u8, force_overwrite: bool, stats: *ScaffoldStats) !void {
    if (fsutil.fileExists(path) and !force_overwrite) {
        stats.files_skipped += 1;
        return;
    }
    try fsutil.writeText(path, content);
    stats.files_written += 1;
}

fn defaultHarnessReadme() []const u8 {
    const content =
        \\# .var
        \\
        \\`.var/` is the canonical runtime-owned and process-owned root for this workspace.
        \\
        \\## Ownership
        \\
        \\- `.var/` owns live task, todo, changelog, memory, research, docs, backup, and worktree state for the harness.
        \\- `.docs/` remains readable repo documentation or preserved historical material when present.
        \\- `init_harness` owns the default scaffold. Other harness tools operate inside that canonical tree and do not create a parallel system.
    ;
    return content;
}

fn defaultMemoriesFile() []const u8 {
    const content =
        \\# Project Memories
        \\
        \\## Durable Context
        \\
        \\- Record stable learnings here after reading `.var/changelog/_log.md`.
    ;
    return content;
}

fn defaultChangelogFile() []const u8 {
    const content =
        \\# Harness Changelog Log
        \\
    ;
    return content;
}

fn defaultDocsIndex() []const u8 {
    const content =
        \\# .var Docs Index
        \\
        \\- [architecture.md](./architecture.md)
        \\  Canonical directory hierarchy, process flow, and runtime ownership boundary.
        \\- [tool-contracts.md](./tool-contracts.md)
        \\  Canonical tool contracts for the root harness runtime.
        \\
        \\## Current Rule
        \\
        \\Use `.var/` for live harness/process state. Use `.docs/` for readable repo documentation and preserved legacy artifacts.
    ;
    return content;
}

fn defaultDocsArchitecture() []const u8 {
    const content =
        \\# .var Architecture
        \\
        \\## Runtime Boundary
        \\
        \\The active workspace root is the default mutation boundary. The harness must not create a second live runtime or a second state ledger outside `.var/`.
        \\
        \\## Canonical Tree
        \\
        \\```text
        \\<project-root>/
        \\  .var/
        \\    memories/
        \\      memories.md
        \\    changelog/
        \\      _log.md
        \\      <task-name>/
        \\        todo-slice*.md
        \\    todos/
        \\      <category>/
        \\        <task-name>/
        \\          todo-slice*.md
        \\    sessions/
        \\      <task-name>/
        \\        session.md
        \\    auth/
        \\      auth.json
        \\    research/
        \\    docs/
        \\      _index.md
        \\      architecture.md
        \\      tool-contracts.md
        \\    worktrees/
        \\    backup/
        \\```
        \\
        \\## Tool Runtime
        \\
        \\- `init_harness` scaffolds the canonical structure.
        \\- Harness-domain tools operate inside `.var/` only.
        \\- Consumer runtimes such as `VAR1` must project through the root contract instead of inventing a parallel system.
    ;
    return content;
}

fn defaultToolContracts() []const u8 {
    const content =
        \\# Tool Contracts
        \\
        \\## Init Tool
        \\
        \\Purpose:
        \\- scaffold the canonical `.var/` tree
        \\- create missing default docs and ledgers without inventing a second system
        \\
        \\## Required Domain Tools
        \\
        \\- `harness_memories`
        \\- `harness_changelog`
        \\- `harness_todo`
        \\- `harness_task`
        \\- `harness_research`
        \\- `harness_docs`
        \\- `harness_worktree`
        \\- `harness_backup`
        \\- `instruction_ingestion`
        \\
        \\Rule:
        \\- every harness-domain tool operates inside `.var/`
        \\- tools may be used only when relevant to the task
        \\- no tool may create a parallel state system
    ;
    return content;
}

fn defaultWorktreesReadme() []const u8 {
    const content =
        \\# .var Worktrees
        \\
        \\Use `harness_worktree` to manage Git worktrees under this directory when the workspace is a real Git checkout.
    ;
    return content;
}

fn defaultBackupReadme() []const u8 {
    const content =
        \\# .var Backup
        \\
        \\Use `harness_backup` to create timestamped workspace archives before destructive operations or large migrations.
    ;
    return content;
}

fn defaultResearchReadme() []const u8 {
    const content =
        \\# .var Research
        \\
        \\Store decision rationale, source summaries, and implementation snapshots here.
    ;
    return content;
}

fn scaffoldHarness(allocator: std.mem.Allocator, workspace_root: []const u8, force_overwrite: bool) !ScaffoldStats {
    var stats = ScaffoldStats{};

    const directories = [_][]const u8{
        try harnessRootPath(allocator, workspace_root),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "memories" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "changelog" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "docs" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "sessions" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "auth" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "research" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "worktrees" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "backup" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "todos" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "feature" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "chore" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "fix" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "refactor" }),
        try fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "task" }),
    };
    defer for (directories) |path| allocator.free(path);

    for (directories) |path| try ensureDir(path, &stats);

    const worktrees_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "worktrees", "README.md" });
    defer allocator.free(worktrees_readme);
    const backup_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "backup", "README.md" });
    defer allocator.free(backup_readme);
    const research_readme = try fsutil.join(allocator, &.{ workspace_root, ".var", "research", "README.md" });
    defer allocator.free(research_readme);

    const readme = try readmePath(allocator, workspace_root);
    defer allocator.free(readme);
    const memories = try memoriesPath(allocator, workspace_root);
    defer allocator.free(memories);
    const changelog = try changelogLogPath(allocator, workspace_root);
    defer allocator.free(changelog);
    const docs_index = try docsIndexPath(allocator, workspace_root);
    defer allocator.free(docs_index);
    const docs_architecture = try docsArchitecturePath(allocator, workspace_root);
    defer allocator.free(docs_architecture);
    const docs_contracts = try docsToolContractsPath(allocator, workspace_root);
    defer allocator.free(docs_contracts);

    try writeTemplateFile(readme, defaultHarnessReadme(), force_overwrite, &stats);
    try writeTemplateFile(memories, defaultMemoriesFile(), force_overwrite, &stats);
    try writeTemplateFile(changelog, defaultChangelogFile(), force_overwrite, &stats);
    try writeTemplateFile(docs_index, defaultDocsIndex(), force_overwrite, &stats);
    try writeTemplateFile(docs_architecture, defaultDocsArchitecture(), force_overwrite, &stats);
    try writeTemplateFile(docs_contracts, defaultToolContracts(), force_overwrite, &stats);
    try writeTemplateFile(worktrees_readme, defaultWorktreesReadme(), force_overwrite, &stats);
    try writeTemplateFile(backup_readme, defaultBackupReadme(), force_overwrite, &stats);
    try writeTemplateFile(research_readme, defaultResearchReadme(), force_overwrite, &stats);

    return stats;
}

fn renderMarkdownList(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    empty_line: []const u8,
) ![]u8 {
    if (items.len == 0) return allocator.dupe(u8, empty_line);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    for (items) |item| {
        try output.writer().print("- {s}\n", .{item});
    }
    return output.toOwnedSlice();
}

fn renderTaskRecord(
    allocator: std.mem.Allocator,
    task_name: []const u8,
    status: []const u8,
    objective: []const u8,
    scope: []const []const u8,
    evidence_roots: []const []const u8,
) ![]u8 {
    const scope_text = try renderMarkdownList(allocator, scope, "- none\n");
    defer allocator.free(scope_text);
    const evidence_text = try renderMarkdownList(allocator, evidence_roots, "- none\n");
    defer allocator.free(evidence_text);

    return std.fmt.allocPrint(
        allocator,
        \\# {s}
        \\
        \\## Status
        \\
        \\`{s}`
        \\
        \\## Objective
        \\
        \\{s}
        \\
        \\## Scope
        \\
        \\{s}
        \\## Evidence Roots
        \\
        \\{s}
    ,
        .{
            task_name,
            status,
            objective,
            scope_text,
            evidence_text,
        },
    );
}

fn renderTodoSlice(
    allocator: std.mem.Allocator,
    status: []const u8,
    category: []const u8,
    objective: []const u8,
    dependencies: []const []const u8,
    steps_taken: []const []const u8,
    blockers: []const []const u8,
    evidence: []const []const u8,
) ![]u8 {
    const dependencies_text = try renderMarkdownList(allocator, dependencies, "none\n");
    defer allocator.free(dependencies_text);
    const steps_text = try renderMarkdownList(allocator, steps_taken, "- none\n");
    defer allocator.free(steps_text);
    const blockers_text = try renderMarkdownList(allocator, blockers, "none\n");
    defer allocator.free(blockers_text);
    const evidence_text = try renderMarkdownList(allocator, evidence, "- none\n");
    defer allocator.free(evidence_text);

    return std.fmt.allocPrint(
        allocator,
        \\# Todo Slice 1
        \\
        \\- Status: `{s}`
        \\- Category: `{s}`
        \\- Objective: {s}
        \\- Dependencies: {s}
        \\- Steps Taken:
        \\{s}
        \\## Evidence
        \\
        \\{s}
        \\## Blockers
        \\
        \\{s}
    ,
        .{
            status,
            category,
            objective,
            std.mem.trimRight(u8, dependencies_text, "\n"),
            steps_text,
            evidence_text,
            blockers_text,
        },
    );
}

fn executeInitHarness(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        force_overwrite: bool = false,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const stats = try scaffoldHarness(allocator, workspace_root, parsed.value.force_overwrite);
    const content = try std.fmt.allocPrint(
        allocator,
        "HARNESS_ROOT {s}\nDIRECTORIES_ENSURED {d}\nFILES_WRITTEN {d}\nFILES_SKIPPED {d}",
        .{ ".var", stats.directories_created, stats.files_written, stats.files_skipped },
    );
    defer allocator.free(content);

    return okEnvelope(allocator, "init_harness", content);
}

fn executeHarnessMemories(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        content: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try memoriesPath(allocator, workspace_root);
    defer allocator.free(file_path);
    try fsutil.ensureParent(file_path);
    if (!fsutil.fileExists(file_path)) try fsutil.writeText(file_path, defaultMemoriesFile());

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_memories", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "append")) {
        const content = parsed.value.content orelse return error.InvalidArguments;
        try appendMarkdownBlock(allocator, file_path, content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nAPPENDED_BYTES {d}", .{ file_path, content.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_memories", payload);
    }

    return error.InvalidArguments;
}

fn executeHarnessChangelog(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        content: ?[]const u8 = null,
        category: ?[]const u8 = null,
        task_name: ?[]const u8 = null,
        slice_name: ?[]const u8 = "todo-slice1.md",
        log_entry: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try changelogLogPath(allocator, workspace_root);
    defer allocator.free(file_path);
    try fsutil.ensureParent(file_path);
    if (!fsutil.fileExists(file_path)) try fsutil.writeText(file_path, defaultChangelogFile());

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_changelog", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "append")) {
        const content = parsed.value.content orelse return error.InvalidArguments;
        try appendMarkdownBlock(allocator, file_path, content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nAPPENDED_BYTES {d}", .{ file_path, content.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_changelog", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "archive_todo")) {
        const category = parsed.value.category orelse return error.InvalidArguments;
        const task_name = parsed.value.task_name orelse return error.InvalidArguments;
        const slice_name = parsed.value.slice_name orelse "todo-slice1.md";
        if (!isSafeSegment(category) or !isSafeSegment(task_name) or !isSafeSegment(slice_name)) return error.InvalidArguments;

        const source_path = try todoPath(allocator, workspace_root, category, task_name, slice_name);
        defer allocator.free(source_path);
        const destination_path = try changelogSlicePath(allocator, workspace_root, task_name, slice_name);
        defer allocator.free(destination_path);

        const todo_contents = try fsutil.readTextAlloc(allocator, source_path);
        defer allocator.free(todo_contents);
        if (std.mem.indexOf(u8, todo_contents, "PLACEHOLDER") != null) return error.InvalidArguments;

        try fsutil.moveFile(source_path, destination_path);
        if (parsed.value.log_entry) |line| try appendMarkdownBlock(allocator, file_path, line);

        const payload = try std.fmt.allocPrint(
            allocator,
            "ARCHIVED_FROM {s}\nARCHIVED_TO {s}",
            .{ source_path, destination_path },
        );
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_changelog", payload);
    }

    return error.InvalidArguments;
}

fn executeHarnessTodo(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        category: []const u8,
        task_name: []const u8,
        slice_name: []const u8 = "todo-slice1.md",
        status: ?[]const u8 = null,
        objective: ?[]const u8 = null,
        dependencies: []const []const u8 = &.{},
        steps_taken: []const []const u8 = &.{},
        blockers: []const []const u8 = &.{},
        evidence: []const []const u8 = &.{},
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!isSafeSegment(parsed.value.category) or !isSafeSegment(parsed.value.task_name) or !isSafeSegment(parsed.value.slice_name)) {
        return error.InvalidArguments;
    }

    const file_path = try todoPath(allocator, workspace_root, parsed.value.category, parsed.value.task_name, parsed.value.slice_name);
    defer allocator.free(file_path);

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_todo", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "upsert")) {
        const rendered = try renderTodoSlice(
            allocator,
            parsed.value.status orelse return error.InvalidArguments,
            parsed.value.category,
            parsed.value.objective orelse return error.InvalidArguments,
            parsed.value.dependencies,
            parsed.value.steps_taken,
            parsed.value.blockers,
            parsed.value.evidence,
        );
        defer allocator.free(rendered);

        try fsutil.writeText(file_path, rendered);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nBYTES {d}", .{ file_path, rendered.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_todo", payload);
    }

    return error.InvalidArguments;
}

fn executeHarnessTask(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        task_name: []const u8,
        status: ?[]const u8 = null,
        objective: ?[]const u8 = null,
        scope: []const []const u8 = &.{},
        evidence_roots: []const []const u8 = &.{},
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!isSafeSegment(parsed.value.task_name)) return error.InvalidArguments;

    const file_path = try taskPath(allocator, workspace_root, parsed.value.task_name);
    defer allocator.free(file_path);

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_task", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "upsert")) {
        const rendered = try renderTaskRecord(
            allocator,
            parsed.value.task_name,
            parsed.value.status orelse return error.InvalidArguments,
            parsed.value.objective orelse return error.InvalidArguments,
            parsed.value.scope,
            parsed.value.evidence_roots,
        );
        defer allocator.free(rendered);

        try fsutil.writeText(file_path, rendered);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nBYTES {d}", .{ file_path, rendered.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_task", payload);
    }

    return error.InvalidArguments;
}

fn executeHarnessResearch(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    return executeHarnessBodyFileTool(allocator, workspace_root, arguments_json, "harness_research", researchPath);
}

fn executeHarnessDocs(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    return executeHarnessBodyFileTool(allocator, workspace_root, arguments_json, "harness_docs", docsPath);
}

fn executeHarnessBodyFileTool(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    tool_name: []const u8,
    path_resolver: *const fn (std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        path: []const u8,
        title: ?[]const u8 = null,
        content: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try path_resolver(allocator, workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    if (std.mem.eql(u8, parsed.value.action, "read")) {
        const content = try fsutil.readTextAlloc(allocator, file_path);
        defer allocator.free(content);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ file_path, content });
        defer allocator.free(payload);
        return okEnvelope(allocator, tool_name, payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "write")) {
        const content_body = parsed.value.content orelse return error.InvalidArguments;
        const rendered = try if (parsed.value.title) |title|
            if (std.mem.startsWith(u8, content_body, "# ")) allocator.dupe(u8, content_body) else std.fmt.allocPrint(allocator, "# {s}\n\n{s}", .{ title, content_body })
        else
            allocator.dupe(u8, content_body);
        defer allocator.free(rendered);

        try fsutil.writeText(file_path, rendered);
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\nBYTES {d}", .{ file_path, rendered.len });
        defer allocator.free(payload);
        return okEnvelope(allocator, tool_name, payload);
    }

    return error.InvalidArguments;
}

fn executeHarnessWorktree(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    runner: anytype,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        name: ?[]const u8 = null,
        ref: ?[]const u8 = null,
        force: bool = false,
        reason: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!try workspaceIsGitCheckout(allocator, workspace_root, runner)) {
        const payload = try allocator.dupe(u8, "WORKTREE_STATUS disabled\nREASON workspace is not a Git checkout");
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_worktree", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "status")) {
        const list_output = try runner.run(allocator, workspace_root, &.{ "git", "worktree", "list", "--porcelain" });
        defer list_output.deinit(allocator);
        if (list_output.exit_code != 0) return error.CommandFailed;
        const payload = try std.fmt.allocPrint(allocator, "WORKTREE_STATUS ready\n{s}", .{list_output.stdout});
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_worktree", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "list")) {
        const list_output = try runner.run(allocator, workspace_root, &.{ "git", "worktree", "list", "--porcelain" });
        defer list_output.deinit(allocator);
        if (list_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "harness_worktree", list_output.stdout);
    }

    if (std.mem.eql(u8, parsed.value.action, "prune")) {
        const prune_output = try runner.run(allocator, workspace_root, &.{ "git", "worktree", "prune", "-v" });
        defer prune_output.deinit(allocator);
        if (prune_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "harness_worktree", prune_output.stdout);
    }

    const name = parsed.value.name orelse return error.InvalidArguments;
    if (!isSafeSegment(name)) return error.InvalidArguments;

    const worktrees_root = try worktreesRootPath(allocator, workspace_root);
    defer allocator.free(worktrees_root);
    var worktree_stats = ScaffoldStats{};
    try ensureDir(worktrees_root, &worktree_stats);

    const worktree_path = try fsutil.join(allocator, &.{ worktrees_root, name });
    defer allocator.free(worktree_path);

    if (std.mem.eql(u8, parsed.value.action, "add")) {
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("git");
        try argv.append("worktree");
        try argv.append("add");
        try argv.append(worktree_path);
        if (parsed.value.ref) |ref_value| try argv.append(ref_value);

        const add_output = try runner.run(allocator, workspace_root, argv.items);
        defer add_output.deinit(allocator);
        if (add_output.exit_code != 0) return error.CommandFailed;
        const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ worktree_path, add_output.stdout });
        defer allocator.free(payload);
        return okEnvelope(allocator, "harness_worktree", payload);
    }

    if (std.mem.eql(u8, parsed.value.action, "remove")) {
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("git");
        try argv.append("worktree");
        try argv.append("remove");
        if (parsed.value.force) try argv.append("-f");
        try argv.append(worktree_path);

        const remove_output = try runner.run(allocator, workspace_root, argv.items);
        defer remove_output.deinit(allocator);
        if (remove_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "harness_worktree", remove_output.stdout);
    }

    if (std.mem.eql(u8, parsed.value.action, "lock")) {
        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("git");
        try argv.append("worktree");
        try argv.append("lock");
        if (parsed.value.reason) |reason| {
            try argv.append("--reason");
            try argv.append(reason);
        }
        try argv.append(worktree_path);

        const lock_output = try runner.run(allocator, workspace_root, argv.items);
        defer lock_output.deinit(allocator);
        if (lock_output.exit_code != 0) return error.CommandFailed;
        return okEnvelope(allocator, "harness_worktree", lock_output.stdout);
    }

    return error.InvalidArguments;
}

fn executeHarnessBackup(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
    runner: anytype,
) ![]u8 {
    const Args = struct {
        label: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.label) |label| {
        if (!isSafeSegment(label)) return error.InvalidArguments;
    }

    const backup_root = try backupRootPath(allocator, workspace_root);
    defer allocator.free(backup_root);
    var backup_stats = ScaffoldStats{};
    try ensureDir(backup_root, &backup_stats);

    const timestamp_ms = std.time.milliTimestamp();
    const filename = if (parsed.value.label) |label|
        try std.fmt.allocPrint(allocator, "backup-{d}-{s}.zip", .{ timestamp_ms, label })
    else
        try std.fmt.allocPrint(allocator, "backup-{d}.zip", .{timestamp_ms});
    defer allocator.free(filename);

    const destination = try fsutil.join(allocator, &.{ backup_root, filename });
    defer allocator.free(destination);

    const result = if (builtin.os.tag == .windows) blk: {
        const script = try std.fmt.allocPrint(
            allocator,
            "Compress-Archive -Path * -DestinationPath '{s}' -Force -CompressionLevel Optimal -Exclude '.var/backup/*','.zig-cache/*','zig-out/*'",
            .{destination},
        );
        defer allocator.free(script);
        break :blk try runner.run(allocator, workspace_root, &.{ "powershell", "-NoProfile", "-Command", script });
    } else blk: {
        break :blk try runner.run(allocator, workspace_root, &.{ "zip", "-r", destination, ".", "-x", ".var/backup/*", ".zig-cache/*", "zig-out/*" });
    };
    defer result.deinit(allocator);

    if (result.exit_code != 0) return error.CommandFailed;

    const payload = try std.fmt.allocPrint(allocator, "PATH {s}\n{s}", .{ destination, result.stdout });
    defer allocator.free(payload);
    return okEnvelope(allocator, "harness_backup", payload);
}

fn executeInstructionIngestion(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        mode: []const u8,
        target_path: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.mode, "never")) {
        return okEnvelope(allocator, "instruction_ingestion", "MODE never\nFILES 0");
    }

    const target_root = try fsutil.resolveInWorkspace(allocator, workspace_root, parsed.value.target_path orelse ".");
    defer allocator.free(target_root);

    var paths = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (paths.items) |item| allocator.free(item);
        paths.deinit();
    }

    if (std.mem.eql(u8, parsed.value.mode, "always")) {
        try collectAgentsFilesRecursive(allocator, workspace_root, workspace_root, &paths);
    } else {
        try collectAgentsFilesUpward(allocator, workspace_root, target_root, &paths);
    }

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.writer().print("MODE {s}\nFILES {d}\n", .{ parsed.value.mode, paths.items.len });

    for (paths.items) |path| {
        const content = try fsutil.readTextAlloc(allocator, path);
        defer allocator.free(content);
        const relative = try std.fs.path.relative(allocator, workspace_root, path);
        defer allocator.free(relative);
        try output.writer().print("PATH {s}\n{s}\n", .{ relative, content });
    }

    const rendered = try output.toOwnedSlice();
    defer allocator.free(rendered);
    return okEnvelope(allocator, "instruction_ingestion", rendered);
}

fn workspaceIsGitCheckout(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    runner: anytype,
) !bool {
    const result = try runner.run(allocator, workspace_root, &.{ "git", "rev-parse", "--is-inside-work-tree" });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return false;
    return std.mem.indexOf(u8, result.stdout, "true") != null;
}

fn collectAgentsFilesUpward(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    target_root: []const u8,
    output: *std.array_list.Managed([]u8),
) !void {
    const workspace_abs = try fsutil.resolveAbsolute(allocator, workspace_root);
    defer allocator.free(workspace_abs);

    var current = try allocator.dupe(u8, target_root);
    defer allocator.free(current);

    while (true) {
        const agents_path = try std.fs.path.join(allocator, &.{ current, "AGENTS.md" });
        defer allocator.free(agents_path);
        if (fsutil.fileExists(agents_path) and !containsOwnedPath(output.items, agents_path)) {
            try output.append(try allocator.dupe(u8, agents_path));
        }
        if (std.ascii.eqlIgnoreCase(current, workspace_abs)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn collectAgentsFilesRecursive(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    search_root: []const u8,
    output: *std.array_list.Managed([]u8),
) !void {
    var dir = try std.fs.openDirAbsolute(search_root, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "AGENTS.md")) continue;

        const absolute = try std.fs.path.join(allocator, &.{ search_root, entry.path });
        defer allocator.free(absolute);
        const resolved = try fsutil.resolveInWorkspace(allocator, workspace_root, absolute);
        defer allocator.free(resolved);
        if (!containsOwnedPath(output.items, resolved)) {
            try output.append(try allocator.dupe(u8, resolved));
        }
    }
}

fn containsOwnedPath(items: []const []u8, candidate: []const u8) bool {
    for (items) |item| {
        if (pathEqual(item, candidate)) return true;
    }
    return false;
}

fn pathEqual(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}
