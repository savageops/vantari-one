const std = @import("std");
const docs_sync = @import("docs_sync.zig");
const fsutil = @import("fsutil.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

pub const Error = error{
    AgentNameTaken,
    SpawnFailed,
    UnknownAgent,
};

pub const Service = struct {
    config: *const types.Config,

    pub fn init(config: *const types.Config) Service {
        return .{
            .config = config,
        };
    }

    pub fn handle(self: *Service) tools.AgentService {
        return .{
            .context = self,
            .launchFn = launchFromHandle,
            .statusFn = statusFromHandle,
            .waitFn = waitFromHandle,
            .listFn = listFromHandle,
        };
    }
};

const WatchJob = struct {
    workspace_root: []u8,
    session_id: []u8,
    child: std.process.Child,

    fn deinit(self: *WatchJob) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.workspace_root);
        allocator.free(self.session_id);
        allocator.destroy(self);
    }
};

const heartbeat_stale_ms: i64 = 20_000;

const ChildLifecycle = struct {
    state: []const u8,
    next_parent_action: []const u8,
    heartbeat_event_type: []const u8,
    heartbeat_at_ms: i64,
    heartbeat_age_ms: i64,
};

fn launchFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    prompt: []const u8,
    requested_name: ?[]const u8,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return launch(service, allocator, parent_session_id, prompt, requested_name);
}

fn statusFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return status(service, allocator, parent_session_id, agent_name);
}

fn waitFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
    timeout_ms: usize,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return wait(service, allocator, parent_session_id, agent_name, timeout_ms);
}

fn listFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return list(service, allocator, parent_session_id);
}

fn launch(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    prompt: []const u8,
    requested_name: ?[]const u8,
) ![]u8 {
    try docs_sync.ensureRunStart(allocator, service.config.workspace_root);

    const agent_name = if (requested_name) |value|
        try allocator.dupe(u8, value)
    else
        try newAgentName(allocator);
    defer allocator.free(agent_name);

    if (try childNameExists(allocator, service.config.workspace_root, parent_session_id, agent_name)) {
        return Error.AgentNameTaken;
    }

    var child_session = try store.initSessionWithOptions(allocator, service.config.workspace_root, prompt, .{
        .status = .initialized,
        .parent_session_id = parent_session_id,
        .display_name = agent_name,
        .agent_profile = "subagent",
    });
    defer child_session.deinit(allocator);

    try store.appendEvent(allocator, service.config.workspace_root, child_session.id, .{
        .event_type = "session_delegated",
        .message = "Child session delegated by parent session.",
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try docs_sync.writePending(allocator, service.config.workspace_root, .{
        .session_id = child_session.id,
        .status = types.statusLabel(child_session.status),
        .prompt = child_session.prompt,
        .output = "",
        .updated_at_ms = child_session.updated_at_ms,
    });

    const delegation_log = try std.fmt.allocPrint(allocator, "child session delegated: {s} -> {s}", .{
        agent_name,
        child_session.id,
    });
    defer allocator.free(delegation_log);
    try docs_sync.appendLog(allocator, service.config.workspace_root, delegation_log);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(exe_path);
    try argv.append("run");
    try argv.append("--json");
    try argv.append("--no-agent-tools");
    try argv.append("--session-id");
    try argv.append(child_session.id);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = service.config.workspace_root;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const job = try std.heap.page_allocator.create(WatchJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .workspace_root = try std.heap.page_allocator.dupe(u8, service.config.workspace_root),
        .session_id = try std.heap.page_allocator.dupe(u8, child_session.id),
        .child = child,
    };

    const thread = try std.Thread.spawn(.{}, watchChildProcess, .{job});
    thread.detach();

    return std.fmt.allocPrint(
        allocator,
        "AGENT_NAME {s}\nSTATUS {s}\nSESSION_ID {s}\nPARENT_SESSION_ID {s}\nPROMPT {s}",
        .{
            agent_name,
            types.statusLabel(child_session.status),
            child_session.id,
            parent_session_id,
            prompt,
        },
    );
}

fn status(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
) ![]u8 {
    var session = try findChildSessionByName(allocator, service.config.workspace_root, parent_session_id, agent_name);
    defer session.deinit(allocator);
    return renderChildSession(allocator, service.config.workspace_root, session, .{});
}

fn wait(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
    timeout_ms: usize,
) ![]u8 {
    const started_at = std.time.milliTimestamp();

    while (true) {
        var session = try findChildSessionByName(allocator, service.config.workspace_root, parent_session_id, agent_name);
        defer session.deinit(allocator);

        if (isTerminal(session.status)) {
            return renderChildSession(allocator, service.config.workspace_root, session, .{
                .wait_state = "terminal",
            });
        }

        if (timeout_ms > 0 and std.time.milliTimestamp() - started_at >= @as(i64, @intCast(timeout_ms))) {
            return renderChildSession(allocator, service.config.workspace_root, session, .{
                .wait_state = "timeout",
                .wait_timeout_ms = timeout_ms,
            });
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn list(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) ![]u8 {
    const sessions_root = try store.sessionsRootPath(allocator, service.config.workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return allocator.dupe(u8, "No child agents.");

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const now_ms = std.time.milliTimestamp();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        var session = store.readSessionRecord(allocator, service.config.workspace_root, entry.name) catch continue;
        defer session.deinit(allocator);

        if (!matchesChildSession(session, parent_session_id, null)) continue;

        const latest_event = try store.readLatestEvent(allocator, service.config.workspace_root, session.id);
        defer if (latest_event) |event| event.deinit(allocator);
        const lifecycle = lifecycleForSession(session, latest_event, now_ms);

        try output.writer().print(
            "AGENT_NAME {s} STATUS {s} SESSION_ID {s} LIFECYCLE_STATE {s} HEARTBEAT_AT_MS {d} HEARTBEAT_AGE_MS {d} NEXT_PARENT_ACTION {s} UPDATED_AT_MS {d}\n",
            .{
                session.display_name orelse session.id,
                types.statusLabel(session.status),
                session.id,
                lifecycle.state,
                lifecycle.heartbeat_at_ms,
                lifecycle.heartbeat_age_ms,
                lifecycle.next_parent_action,
                session.updated_at_ms,
            },
        );
        count += 1;
    }

    if (count == 0) return allocator.dupe(u8, "No child agents.");
    return output.toOwnedSlice();
}

fn watchChildProcess(job: *WatchJob) void {
    defer job.deinit();

    const allocator = std.heap.page_allocator;
    const term = job.child.wait() catch {
        finalizeAbnormalExit(allocator, job.workspace_root, job.session_id, "ChildWaitFailed", null) catch {};
        return;
    };

    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        .Signal => |signal| @as(i32, @intCast(signal)),
        .Stopped => |signal| @as(i32, @intCast(signal)),
        .Unknown => |code| @as(i32, @intCast(code)),
    };

    if (exit_code != 0) {
        finalizeAbnormalExit(allocator, job.workspace_root, job.session_id, "ChildExitNonZero", exit_code) catch {};
        return;
    }

    var session = store.readSessionRecord(allocator, job.workspace_root, job.session_id) catch return;
    defer session.deinit(allocator);

    if (isTerminal(session.status)) return;
    finalizeAbnormalExit(allocator, job.workspace_root, job.session_id, "ChildExitWithoutTerminalState", exit_code) catch {};
}

fn finalizeAbnormalExit(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    reason: []const u8,
    exit_code: ?i32,
) !void {
    var session = store.readSessionRecord(allocator, workspace_root, session_id) catch return;
    defer session.deinit(allocator);

    if (isTerminal(session.status)) return;

    const failure_reason = if (exit_code) |value|
        try std.fmt.allocPrint(allocator, "{s} (exit code {d})", .{ reason, value })
    else
        try allocator.dupe(u8, reason);
    defer allocator.free(failure_reason);

    try store.appendEvent(allocator, workspace_root, session.id, .{
        .event_type = "session_failed",
        .message = failure_reason,
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try store.setSessionFailure(allocator, workspace_root, &session, failure_reason);
    try docs_sync.writePending(allocator, workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = failure_reason,
        .updated_at_ms = session.updated_at_ms,
    });

    const log_line = try std.fmt.allocPrint(allocator, "child session failed: {s} ({s})", .{
        session.display_name orelse session.id,
        failure_reason,
    });
    defer allocator.free(log_line);
    try docs_sync.appendLog(allocator, workspace_root, log_line);
}

fn findChildSessionByName(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    parent_session_id: []const u8,
    agent_name: []const u8,
) !types.SessionRecord {
    const sessions_root = try store.sessionsRootPath(allocator, workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return Error.UnknownAgent;

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        var session = store.readSessionRecord(allocator, workspace_root, entry.name) catch continue;
        if (matchesChildSession(session, parent_session_id, agent_name)) {
            return session;
        }
        session.deinit(allocator);
    }

    return Error.UnknownAgent;
}

fn childNameExists(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    parent_session_id: []const u8,
    agent_name: []const u8,
) !bool {
    _ = findChildSessionByName(allocator, workspace_root, parent_session_id, agent_name) catch |err| switch (err) {
        Error.UnknownAgent => return false,
        else => return err,
    };
    return true;
}

fn matchesChildSession(session: types.SessionRecord, parent_session_id: []const u8, agent_name: ?[]const u8) bool {
    const session_parent = session.parent_session_id orelse return false;
    if (!std.mem.eql(u8, session_parent, parent_session_id)) return false;

    if (agent_name) |value| {
        const session_name = session.display_name orelse return false;
        return std.mem.eql(u8, session_name, value);
    }

    return true;
}

fn renderChildSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: types.SessionRecord,
    options: RenderOptions,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const latest_event = try store.readLatestEvent(allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(allocator);
    const lifecycle = lifecycleForSession(session, latest_event, std.time.milliTimestamp());

    try output.writer().print(
        "AGENT_NAME {s}\nSTATUS {s}\nSESSION_ID {s}\n",
        .{
            session.display_name orelse session.id,
            types.statusLabel(session.status),
            session.id,
        },
    );

    if (session.parent_session_id) |value| try output.writer().print("PARENT_SESSION_ID {s}\n", .{value});
    if (session.agent_profile) |value| try output.writer().print("AGENT_PROFILE {s}\n", .{value});
    try output.writer().print("CREATED_AT_MS {d}\n", .{session.created_at_ms});
    try output.writer().print("UPDATED_AT_MS {d}\n", .{session.updated_at_ms});
    try output.writer().print("TERMINAL {s}\n", .{if (isTerminal(session.status)) "true" else "false"});
    try output.writer().print("LIFECYCLE_STATE {s}\n", .{lifecycle.state});
    try output.writer().print("NEXT_PARENT_ACTION {s}\n", .{lifecycle.next_parent_action});
    try output.writer().print("HEARTBEAT_EVENT_TYPE {s}\n", .{lifecycle.heartbeat_event_type});
    try output.writer().print("HEARTBEAT_AT_MS {d}\n", .{lifecycle.heartbeat_at_ms});
    try output.writer().print("HEARTBEAT_AGE_MS {d}\n", .{lifecycle.heartbeat_age_ms});
    if (options.wait_state) |value| try output.writer().print("WAIT_STATE {s}\n", .{value});
    if (options.wait_timeout_ms) |value| try output.writer().print("WAIT_TIMEOUT_MS {d}\n", .{value});
    try output.writer().print("PROMPT {s}\n", .{session.prompt});
    if (latest_event) |event| {
        try output.writer().print("LATEST_EVENT_TYPE {s}\n", .{event.event_type});
        try output.writer().print("LATEST_EVENT_AT_MS {d}\n", .{event.timestamp_ms});
        try output.writer().print("LATEST_EVENT_MESSAGE {s}\n", .{event.message});
    }

    if (session.status == .completed) {
        if (try store.readOutput(allocator, workspace_root, session.id)) |result| {
            defer allocator.free(result);
            try output.writer().print("OUTPUT {s}\n", .{result});
        }
    }

    if (session.failure_reason) |value| try output.writer().print("FAILURE_REASON {s}\n", .{value});

    return output.toOwnedSlice();
}

fn lifecycleForSession(session: types.SessionRecord, latest_event: ?types.SessionEvent, now_ms: i64) ChildLifecycle {
    const heartbeat_at_ms = if (latest_event) |event| event.timestamp_ms else session.updated_at_ms;
    const heartbeat_age_ms = if (now_ms > heartbeat_at_ms) now_ms - heartbeat_at_ms else 0;
    const heartbeat_event_type = if (latest_event) |event| event.event_type else "none";

    if (session.status == .completed) {
        return .{
            .state = "completed",
            .next_parent_action = "collect_result",
            .heartbeat_event_type = heartbeat_event_type,
            .heartbeat_at_ms = heartbeat_at_ms,
            .heartbeat_age_ms = heartbeat_age_ms,
        };
    }

    if (session.status == .failed or session.status == .cancelled) {
        return .{
            .state = "errored",
            .next_parent_action = "follow_up",
            .heartbeat_event_type = heartbeat_event_type,
            .heartbeat_at_ms = heartbeat_at_ms,
            .heartbeat_age_ms = heartbeat_age_ms,
        };
    }

    if (session.status == .initialized or heartbeat_age_ms >= heartbeat_stale_ms) {
        return .{
            .state = "waiting_for_input",
            .next_parent_action = "follow_up",
            .heartbeat_event_type = heartbeat_event_type,
            .heartbeat_at_ms = heartbeat_at_ms,
            .heartbeat_age_ms = heartbeat_age_ms,
        };
    }

    return .{
        .state = "processing",
        .next_parent_action = "monitor",
        .heartbeat_event_type = heartbeat_event_type,
        .heartbeat_at_ms = heartbeat_at_ms,
        .heartbeat_age_ms = heartbeat_age_ms,
    };
}

const RenderOptions = struct {
    wait_state: ?[]const u8 = null,
    wait_timeout_ms: ?usize = null,
};

fn newAgentName(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "agent-{d}-{x}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    });
}

fn isTerminal(status_value: types.SessionStatus) bool {
    return status_value == .completed or status_value == .failed or status_value == .cancelled;
}
