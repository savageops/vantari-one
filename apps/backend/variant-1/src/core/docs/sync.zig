const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

// TODO: Keep .var process tracking as a hard gate for progress visibility.

pub fn ensureRunStart(allocator: std.mem.Allocator, workspace_root: []const u8) !void {
    const log_path = try runLogPath(allocator, workspace_root);
    defer allocator.free(log_path);
    if (!fsutil.fileExists(log_path)) {
        try fsutil.writeText(log_path, "# VAR1 Changelog Log\n\n");
    }

    const log_contents = try fsutil.readTextAlloc(allocator, log_path);
    allocator.free(log_contents);

    const memories_path = try memoriesFilePath(allocator, workspace_root);
    defer allocator.free(memories_path);
    if (!fsutil.fileExists(memories_path)) {
        try fsutil.writeText(memories_path, "# VAR1 Project Memories\n\n");
    }

    const memory_contents = try fsutil.readTextAlloc(allocator, memories_path);
    allocator.free(memory_contents);
}

pub fn writePending(allocator: std.mem.Allocator, workspace_root: []const u8, snapshot: types.ProgressSnapshot) !void {
    try ensureRunStart(allocator, workspace_root);

    const pending_path = try todoSlicePath(allocator, workspace_root, snapshot.session_id);
    defer allocator.free(pending_path);

    const content = try renderSessionDoc(allocator, snapshot);
    defer allocator.free(content);
    try fsutil.writeText(pending_path, content);
}

pub fn completeSession(allocator: std.mem.Allocator, workspace_root: []const u8, snapshot: types.ProgressSnapshot) !void {
    try ensureRunStart(allocator, workspace_root);

    const pending_path = try todoSlicePath(allocator, workspace_root, snapshot.session_id);
    defer allocator.free(pending_path);

    const changelog_path = try changelogSlicePath(allocator, workspace_root, snapshot.session_id);
    defer allocator.free(changelog_path);

    const content = try renderSessionDoc(allocator, snapshot);
    defer allocator.free(content);

    try fsutil.writeText(pending_path, content);
    try fsutil.moveFile(pending_path, changelog_path);
}

pub fn appendLog(allocator: std.mem.Allocator, workspace_root: []const u8, message: []const u8) !void {
    try ensureRunStart(allocator, workspace_root);

    const log_path = try runLogPath(allocator, workspace_root);
    defer allocator.free(log_path);

    const line = try std.fmt.allocPrint(allocator, "- {d}: {s}\n", .{
        std.time.milliTimestamp(),
        message,
    });
    defer allocator.free(line);
    try fsutil.appendText(log_path, line);
}

pub fn runLogPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", "_log.md" });
}

pub fn memoriesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "memories", "memories.md" });
}

pub fn todoSlicePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "session", session_id, "todo-slice1.md" });
}

pub fn changelogSlicePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", session_id, "todo-slice1.md" });
}

fn renderSessionDoc(allocator: std.mem.Allocator, snapshot: types.ProgressSnapshot) ![]u8 {
    const result = if (snapshot.output.len == 0) "Pending" else snapshot.output;
    const blockers = if (std.mem.eql(u8, snapshot.status, "failed")) snapshot.output else "None";
    return std.fmt.allocPrint(
        allocator,
        \\# Todo Slice 1
        \\
        \\- Session ID: {s}
        \\- Status: {s}
        \\- Updated At (ms): {d}
        \\- Canonical Session Root: `.var/sessions/{s}/`
        \\
        \\## Objective
        \\
        \\{s}
        \\
        \\## Current Result
        \\
        \\{s}
        \\
        \\## Steps Taken
        \\
        \\- Canonical session state is stored under `.var/sessions/{s}/`.
        \\- Session events append to `events.jsonl`.
        \\- This file is the human-readable execution slice for the current run.
        \\
        \\## Blockers
        \\
        \\{s}
        \\
        ,
        .{
            snapshot.session_id,
            snapshot.status,
            snapshot.updated_at_ms,
            snapshot.session_id,
            snapshot.prompt,
            result,
            snapshot.session_id,
            blockers,
        },
    );
}
