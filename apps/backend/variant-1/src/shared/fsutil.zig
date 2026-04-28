const builtin = @import("builtin");
const std = @import("std");

pub const PathError = error{
    PathOutsideWorkspace,
};

pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn ensureParent(path: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse return;
    if (dir_name.len == 0) return;
    try std.fs.cwd().makePath(dir_name);
}

pub fn writeText(path: []const u8, text: []const u8) !void {
    try ensureParent(path);

    var file = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var buffer: [4096]u8 = undefined;
    var writer_state = file.writer(&buffer);
    const writer = &writer_state.interface;
    try writer.writeAll(text);
    try writer.flush();
}

pub fn appendText(path: []const u8, text: []const u8) !void {
    try ensureParent(path);

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        }),
        else => return err,
    };
    defer file.close();

    const end_position = try file.getEndPos();
    try file.pwriteAll(text, end_position);
}

pub fn readTextAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

pub fn moveFile(old_path: []const u8, new_path: []const u8) !void {
    try ensureParent(new_path);
    try std.fs.cwd().rename(old_path, new_path);
}

pub fn resolveAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn resolveInWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) ![]u8 {
    const root_abs = try resolveAbsolute(allocator, workspace_root);
    defer allocator.free(root_abs);

    const target_abs = if (std.fs.path.isAbsolute(requested_path))
        try resolveAbsolute(allocator, requested_path)
    else
        try std.fs.path.resolve(allocator, &.{ root_abs, requested_path });

    if (!isWithinPath(root_abs, target_abs)) {
        allocator.free(target_abs);
        return PathError.PathOutsideWorkspace;
    }

    return target_abs;
}

fn isWithinPath(root: []const u8, target: []const u8) bool {
    if (target.len < root.len) return false;
    if (!pathPrefixEqual(root, target[0..root.len])) return false;
    if (target.len == root.len) return true;

    return root[root.len - 1] == std.fs.path.sep or target[root.len] == std.fs.path.sep;
}

fn pathPrefixEqual(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}
