const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");

pub const DependencyKind = enum {
    none,
    external_command,
};

pub const Dependency = struct {
    kind: DependencyKind,
    name: []const u8,
};

pub const AvailabilitySpec = struct {
    dependency: ?Dependency = null,
};

pub const CommandProbe = struct {
    context: ?*anyopaque = null,
    commandExistsFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        command_name: []const u8,
    ) anyerror!bool,

    pub fn commandExists(
        self: CommandProbe,
        allocator: std.mem.Allocator,
        command_name: []const u8,
    ) anyerror!bool {
        return self.commandExistsFn(self.context, allocator, command_name);
    }
};

pub const Error = error{
    AgentServiceUnavailable,
    CommandFailed,
    CommandTerminated,
    InvalidArguments,
    MissingParentSession,
    PatternNotFound,
    ToolUnavailable,
    UnknownTool,
};

pub const CommandOutput = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const CommandRunner = struct {
    context: ?*anyopaque,
    runFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) anyerror!CommandOutput,

    pub fn run(
        self: CommandRunner,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) anyerror!CommandOutput {
        return self.runFn(self.context, allocator, cwd, argv);
    }
};

pub const AgentService = struct {
    context: ?*anyopaque,
    launchFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        prompt: []const u8,
        name: ?[]const u8,
    ) anyerror![]u8,
    statusFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
    ) anyerror![]u8,
    waitFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
        timeout_ms: usize,
    ) anyerror![]u8,
    listFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror![]u8,

    pub fn launch(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        prompt: []const u8,
        name: ?[]const u8,
    ) anyerror![]u8 {
        return self.launchFn(self.context, allocator, parent_session_id, prompt, name);
    }

    pub fn status(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
    ) anyerror![]u8 {
        return self.statusFn(self.context, allocator, parent_session_id, agent_name);
    }

    pub fn wait(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
        timeout_ms: usize,
    ) anyerror![]u8 {
        return self.waitFn(self.context, allocator, parent_session_id, agent_name, timeout_ms);
    }

    pub fn list(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror![]u8 {
        return self.listFn(self.context, allocator, parent_session_id);
    }
};

pub const ExecutionContext = struct {
    workspace_root: []const u8,
    parent_session_id: ?[]const u8 = null,
    agent_service: ?AgentService = null,
    command_probe: ?CommandProbe = null,
    workspace_state_enabled: bool = false,
};

pub fn okEnvelope(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":{f},\"content\":{f}}}",
        .{
            std.json.fmt(tool_name, .{}),
            std.json.fmt(content, .{}),
        },
    );
}

pub fn renderLineRange(
    allocator: std.mem.Allocator,
    content: []const u8,
    start_line: ?usize,
    end_line: ?usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const start = start_line orelse 1;
    const finish = end_line orelse std.math.maxInt(usize);

    var line_number: usize = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| : (line_number += 1) {
        if (line_number < start or line_number > finish) continue;
        try output.writer().print("{d}: {s}\n", .{ line_number, line });
    }

    return output.toOwnedSlice();
}

pub fn replaceText(
    allocator: std.mem.Allocator,
    input: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    replace_all: bool,
) !struct { contents: []u8, replacements: usize } {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var cursor: usize = 0;
    var replacements: usize = 0;

    while (std.mem.indexOfPos(u8, input, cursor, old_text)) |match_index| {
        try output.writer().writeAll(input[cursor..match_index]);
        try output.writer().writeAll(new_text);
        cursor = match_index + old_text.len;
        replacements += 1;

        if (!replace_all) break;
    }

    try output.writer().writeAll(input[cursor..]);

    return .{
        .contents = try output.toOwnedSlice(),
        .replacements = replacements,
    };
}

pub fn collectFiles(
    allocator: std.mem.Allocator,
    search_path: []const u8,
    search_prefix: []const u8,
    max_results: usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var dir = std.fs.openDirAbsolute(search_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const single_path = try normalizeToolPath(
                allocator,
                if (std.mem.eql(u8, search_prefix, ".")) std.fs.path.basename(search_path) else search_prefix,
            );
            defer allocator.free(single_path);

            try output.writer().print("{s}\n", .{single_path});
            return output.toOwnedSlice();
        },
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var line_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (line_count >= max_results) break;

        const display_path = if (std.mem.eql(u8, search_prefix, "."))
            try allocator.dupe(u8, entry.path)
        else
            try fsutil.join(allocator, &.{ search_prefix, entry.path });
        defer allocator.free(display_path);

        const normalized_path = try normalizeToolPath(allocator, display_path);
        defer allocator.free(normalized_path);

        try output.writer().print("{s}\n", .{normalized_path});
        line_count += 1;
    }

    return output.toOwnedSlice();
}

fn normalizeToolPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep == '/') return normalized;

    for (normalized) |*byte| {
        if (byte.* == std.fs.path.sep) byte.* = '/';
    }

    return normalized;
}
