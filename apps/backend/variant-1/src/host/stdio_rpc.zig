const std = @import("std");
const context_compactor = @import("../core/context/compactor.zig");
const loop = @import("../core/executor/loop.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const store = @import("../core/sessions/store.zig");
const tools = @import("../core/tools/runtime.zig");
const types = @import("../shared/types.zig");

pub const Error = error{
    InvalidRequest,
    InvalidParams,
    MethodNotFound,
    ManualCompactionDisabled,
    SessionNotFound,
    SessionRunning,
    ExecutionFailed,
    InvalidFrame,
    MissingChildPipes,
    InvalidRpcResponse,
    RpcRemoteError,
};

const max_header_line_bytes = 8 * 1024;
const max_notification_backlog = 512;
const notification_poll_ms: u64 = 50;

const SessionRuntimeState = struct {
    enable_agent_tools: bool = true,
    cancel_requested: bool = false,
    running: bool = false,
};

const Runtime = struct {
    mutex: std.Thread.Mutex = .{},
    sessions: std.StringHashMapUnmanaged(SessionRuntimeState) = .{},

    fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit(allocator);
    }

    fn ensureSession(
        self: *Runtime,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        enable_agent_tools: ?bool,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            if (enable_agent_tools) |value| state.enable_agent_tools = value;
            return;
        }

        try self.sessions.put(allocator, try allocator.dupe(u8, session_id), .{
            .enable_agent_tools = enable_agent_tools orelse true,
        });
    }

    fn setRunning(self: *Runtime, session_id: []const u8, running: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            state.running = running;
            if (running) state.cancel_requested = false;
        }
    }

    fn isRunning(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.running;
        return false;
    }

    fn requestCancel(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            state.cancel_requested = true;
            return true;
        }

        return false;
    }

    fn shouldCancel(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.cancel_requested;
        return false;
    }

    fn enableAgentTools(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.enable_agent_tools;
        return true;
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    agent_service: tools.AgentService,
    stdout_file: std.fs.File,
    write_mutex: std.Thread.Mutex = .{},
    runtime: Runtime = .{},

    fn deinit(self: *Server) void {
        self.runtime.deinit(self.allocator);
    }

    fn emitSessionEvent(
        self: *Server,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        const params_json = try renderJsonAlloc(self.allocator, protocol_types.SessionEventNotification{
            .session_id = session_id,
            .event_type = event_type,
            .message = message,
            .status = status,
            .timestamp_ms = timestamp_ms,
        });
        defer self.allocator.free(params_json);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ protocol_types.notification_methods.session_event, params_json },
        );
        defer self.allocator.free(payload);

        try self.writePayload(payload);
    }

    fn writePayload(self: *Server, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try writeFrame(self.stdout_file, payload);
    }
};

const RequestJob = struct {
    server: *Server,
    request_payload: []u8,
};

pub const RpcCallResult = struct {
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,

    pub fn deinit(self: RpcCallResult, allocator: std.mem.Allocator) void {
        if (self.result_json) |value| allocator.free(value);
        if (self.error_json) |value| allocator.free(value);
    }
};

pub const Notification = struct {
    sequence: u64,
    method: []u8,
    params_json: []u8,

    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.params_json);
    }
};

const ClientState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    responses: std.StringHashMapUnmanaged([]u8) = .{},
    notifications: std.array_list.Managed(Notification),
    next_request_id: usize = 1,
    next_notification_sequence: u64 = 1,
    closed: bool = false,
    read_error: ?anyerror = null,

    fn init(allocator: std.mem.Allocator) ClientState {
        return .{
            .allocator = allocator,
            .notifications = std.array_list.Managed(Notification).init(allocator),
        };
    }

    fn deinit(self: *ClientState) void {
        var iterator = self.responses.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.responses.deinit(self.allocator);

        for (self.notifications.items) |notification| notification.deinit(self.allocator);
        self.notifications.deinit();
    }

    fn recordResponse(self: *ClientState, request_id: []const u8, response_payload: []u8) !void {
        self.mutex.lock();
        defer {
            self.cond.broadcast();
            self.mutex.unlock();
        }

        try self.responses.put(self.allocator, try self.allocator.dupe(u8, request_id), response_payload);
    }

    fn recordNotification(self: *ClientState, method: []const u8, params_json: []const u8) !void {
        self.mutex.lock();
        defer {
            self.cond.broadcast();
            self.mutex.unlock();
        }

        if (self.notifications.items.len >= max_notification_backlog) {
            const dropped = self.notifications.orderedRemove(0);
            dropped.deinit(self.allocator);
        }

        try self.notifications.append(.{
            .sequence = self.next_notification_sequence,
            .method = try self.allocator.dupe(u8, method),
            .params_json = try self.allocator.dupe(u8, params_json),
        });
        self.next_notification_sequence += 1;
    }

    fn recordClosure(self: *ClientState, read_error: ?anyerror) void {
        self.mutex.lock();
        defer {
            self.cond.broadcast();
            self.mutex.unlock();
        }

        self.closed = true;
        self.read_error = read_error;
    }

    fn nextRequestId(self: *ClientState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const request_id = self.next_request_id;
        self.next_request_id += 1;
        return request_id;
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    state: *ClientState,
};

pub fn serveKernel(
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    agent_service: tools.AgentService,
) !void {
    var server = Server{
        .allocator = allocator,
        .config = config,
        .transport = transport,
        .agent_service = agent_service,
        .stdout_file = std.fs.File.stdout(),
    };
    defer server.deinit();

    const stdin_file = std.fs.File.stdin();
    while (true) {
        const request_payload = try readFrame(allocator, stdin_file) orelse break;

        const job = try std.heap.page_allocator.create(RequestJob);
        job.* = .{
            .server = &server,
            .request_payload = request_payload,
        };

        const thread = try std.Thread.spawn(.{}, processRequestWorker, .{job});
        thread.detach();
    }
}

pub const LocalClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    state: *ClientState,
    stdin_mutex: std.Thread.Mutex = .{},
    reader_context: ?*ReaderContext = null,
    reader_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) !LocalClient {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        var argv = [_][]const u8{ exe_path, "kernel-stdio" };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        errdefer {
            if (child.stdin) |*stdin_file| {
                stdin_file.close();
                child.stdin = null;
            }
            if (child.stdout) |*stdout_file| {
                stdout_file.close();
                child.stdout = null;
            }
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        const state = try allocator.create(ClientState);
        errdefer allocator.destroy(state);
        state.* = ClientState.init(allocator);
        errdefer state.deinit();

        const reader_context = try allocator.create(ReaderContext);
        errdefer allocator.destroy(reader_context);
        reader_context.* = .{
            .allocator = allocator,
            .stdout_file = child.stdout orelse return Error.MissingChildPipes,
            .state = state,
        };
        child.stdout = null;
        errdefer reader_context.stdout_file.close();

        var client = LocalClient{
            .allocator = allocator,
            .child = child,
            .state = state,
            .reader_context = reader_context,
        };

        const reader = try std.Thread.spawn(.{}, readerLoop, .{reader_context});
        client.reader_thread = reader;
        return client;
    }

    pub fn deinit(self: *LocalClient) void {
        if (self.child.stdin) |*stdin_file| {
            stdin_file.close();
            self.child.stdin = null;
        }

        _ = self.child.wait() catch {};

        if (self.reader_thread) |thread| thread.join();

        if (self.reader_context) |reader_context| {
            reader_context.stdout_file.close();
            self.allocator.destroy(reader_context);
            self.reader_context = null;
        }

        self.state.deinit();
        self.allocator.destroy(self.state);
    }

    pub fn call(self: *LocalClient, method: []const u8, params_json: []const u8) !RpcCallResult {
        if (self.child.stdin == null) return Error.MissingChildPipes;

        const request_number = self.state.nextRequestId();
        const request_id = try std.fmt.allocPrint(self.allocator, "req-{d}", .{request_number});
        defer self.allocator.free(request_id);

        const request_payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ request_id, method, params_json },
        );
        defer self.allocator.free(request_payload);

        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        try writeFrame(self.child.stdin.?, request_payload);

        const response_payload = try waitForResponse(self, request_id);
        defer self.allocator.free(response_payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_payload, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return Error.InvalidRpcResponse;
        const object = parsed.value.object;

        if (object.get("error")) |error_value| {
            return .{
                .error_json = try renderJsonAlloc(self.allocator, error_value),
            };
        }

        const result_value = object.get("result") orelse return Error.InvalidRpcResponse;
        return .{
            .result_json = try renderJsonAlloc(self.allocator, result_value),
        };
    }

    pub fn waitForNotificationAfter(
        self: *LocalClient,
        after_sequence: u64,
        timeout_ms: usize,
    ) !?Notification {
        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (try takeNotificationAfter(self, after_sequence)) |notification| return notification;
            if (std.time.milliTimestamp() >= deadline_ms) return null;
            std.Thread.sleep(notification_poll_ms * std.time.ns_per_ms);
        }
    }
};

fn processRequestWorker(job: *RequestJob) void {
    defer std.heap.page_allocator.destroy(job);
    defer job.server.allocator.free(job.request_payload);

    const response_payload = processRequest(job.server, job.request_payload) catch return;
    if (response_payload) |payload| {
        defer job.server.allocator.free(payload);
        job.server.writePayload(payload) catch {};
    }
}

fn processRequest(server: *Server, request_payload: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, server.allocator, request_payload, .{}) catch {
        const response = try renderErrorResponse(server.allocator, null, -32700, "Parse error");
        return response;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        const response = try renderErrorResponse(server.allocator, null, -32600, "Invalid Request");
        return response;
    }

    const object = parsed.value.object;
    const id = extractRequestId(object) catch {
        const response = try renderErrorResponse(server.allocator, null, -32600, "Invalid Request");
        return response;
    };

    const jsonrpc_value = object.get("jsonrpc") orelse {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    };
    if (jsonrpc_value != .string or !std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    }

    const method_value = object.get("method") orelse {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    };
    if (method_value != .string) {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    }

    const result_payload = dispatch(server, method_value.string, object.get("params")) catch |err| switch (err) {
        Error.MethodNotFound => return errorResponseOrNull(server.allocator, id, -32601, "Method not found"),
        Error.InvalidParams => return errorResponseOrNull(server.allocator, id, -32602, "Invalid params"),
        Error.ManualCompactionDisabled => return errorResponseOrNull(server.allocator, id, -32003, "Manual compaction disabled"),
        Error.SessionNotFound => return errorResponseOrNull(server.allocator, id, -32001, "Session not found"),
        Error.SessionRunning => return errorResponseOrNull(server.allocator, id, -32002, "Session already running"),
        Error.ExecutionFailed => return errorResponseOrNull(server.allocator, id, -32000, "Execution failed"),
        else => return errorResponseOrNull(server.allocator, id, -32603, "Internal error"),
    };
    defer server.allocator.free(result_payload);

    if (id == null) return null;
    const response = try renderSuccessResponse(server.allocator, id.?, result_payload);
    return response;
}

fn dispatch(
    server: *Server,
    method_name: []const u8,
    params: ?std.json.Value,
) ![]u8 {
    if (std.mem.eql(u8, method_name, protocol_types.methods.initialize)) {
        return handleInitialize(server.allocator);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_create)) {
        return handleSessionCreate(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_resume)) {
        return handleSessionResume(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_send)) {
        return handleSessionSend(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_compact)) {
        return handleSessionCompact(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_cancel)) {
        return handleSessionCancel(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_get)) {
        return handleSessionGet(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_list)) {
        return handleSessionList(server);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.tools_list)) {
        return handleToolsList(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.events_subscribe)) {
        return handleEventsSubscribe(server.allocator);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.health_get)) {
        return handleHealthGet(server.allocator, server.config);
    }

    return Error.MethodNotFound;
}

fn handleInitialize(allocator: std.mem.Allocator) ![]u8 {
    return renderJsonAlloc(allocator, protocol_types.InitializeResult{
        .server_version = "VAR1-kernel-stdio-v2",
        .capabilities = .{},
    });
}

fn handleSessionCreate(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        prompt: []const u8,
        parent_session_id: ?[]const u8 = null,
        continued_from_session_id: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
        agent_profile: ?[]const u8 = null,
        enable_agent_tools: ?bool = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    const prompt = std.mem.trim(u8, parsed.value.prompt, " \t\r\n");
    if (prompt.len == 0) return Error.InvalidParams;

    var session = try store.initSessionWithOptions(server.allocator, server.config.workspace_root, prompt, .{
        .status = .initialized,
        .parent_session_id = parsed.value.parent_session_id,
        .continued_from_session_id = parsed.value.continued_from_session_id,
        .display_name = parsed.value.display_name,
        .agent_profile = parsed.value.agent_profile,
    });
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, parsed.value.enable_agent_tools);

    return renderJsonAlloc(server.allocator, protocol_types.SessionCreateResult{
        .session = makeSessionSummary(session, null),
    });
}

fn handleSessionResume(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
        enable_agent_tools: ?bool = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, parsed.value.enable_agent_tools);

    const output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
    defer if (output) |value| server.allocator.free(value);

    return renderJsonAlloc(server.allocator, protocol_types.SessionResumeResult{
        .session = makeSessionSummary(session, output),
    });
}

fn handleSessionSend(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
        prompt: ?[]const u8 = null,
        enable_agent_tools: ?bool = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, parsed.value.enable_agent_tools);

    if (parsed.value.prompt) |next_prompt_raw| {
        const next_prompt = std.mem.trim(u8, next_prompt_raw, " \t\r\n");
        if (next_prompt.len == 0) return Error.InvalidParams;
        const timestamp_ms = std.time.milliTimestamp();
        try store.appendSessionMessage(server.allocator, server.config.workspace_root, session.id, .user, next_prompt, timestamp_ms);
        try store.setSessionPrompt(server.allocator, server.config.workspace_root, &session, next_prompt, .initialized);
    } else if (session.status == .completed or session.status == .cancelled) {
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }

    if (server.runtime.isRunning(session.id)) {
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }

    server.runtime.setRunning(session.id, true);
    defer server.runtime.setRunning(session.id, false);

    const hooks = loop.Hooks{
        .context = server,
        .onSessionInitializedFn = onLoopSessionInitialized,
        .onSessionEventFn = onLoopSessionEvent,
        .shouldCancelFn = onLoopShouldCancel,
    };

    const result = loop.runPromptWithOptions(server.allocator, server.config.*, "", .{
        .transport = server.transport,
        .execution_context = .{
            .workspace_root = server.config.workspace_root,
            .parent_session_id = session.parent_session_id,
            .agent_service = if (server.runtime.enableAgentTools(session.id)) server.agent_service else null,
        },
        .session_id = session.id,
        .hooks = hooks,
    }) catch |err| switch (err) {
        loop.Error.Cancelled => {
            var cancelled = try store.readSessionRecord(server.allocator, server.config.workspace_root, session.id);
            defer cancelled.deinit(server.allocator);
            const cancelled_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
            defer if (cancelled_output) |value| server.allocator.free(value);
            return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
                .session = makeSessionSummary(cancelled, cancelled_output),
            });
        },
        else => return Error.ExecutionFailed,
    };
    defer result.deinit(server.allocator);

    var completed = try store.readSessionRecord(server.allocator, server.config.workspace_root, result.session_id);
    defer completed.deinit(server.allocator);
    const output = try store.readOutput(server.allocator, server.config.workspace_root, result.session_id);
    defer if (output) |value| server.allocator.free(value);

    return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
        .session = makeSessionSummary(completed, output),
    });
}

fn handleSessionCompact(server: *Server, params: ?std.json.Value) ![]u8 {
    if (!server.config.context_policy.manual_compaction) return Error.ManualCompactionDisabled;

    const Args = struct {
        session_id: []const u8,
        keep_recent_messages: ?u32 = null,
        max_entries_per_checkpoint: ?u32 = null,
        aggressiveness: ?f64 = null,
        trigger: ?[]const u8 = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, null);
    if (server.runtime.isRunning(session.id)) return Error.SessionRunning;

    const trigger = parsed.value.trigger orelse "manual";
    const keep_recent_messages = @as(usize, parsed.value.keep_recent_messages orelse @intCast(server.config.context_policy.keep_recent_messages));
    const max_entries_per_checkpoint = @as(usize, parsed.value.max_entries_per_checkpoint orelse @intCast(server.config.context_policy.max_entries_per_checkpoint));
    const aggressiveness_milli = try compactAggressivenessMilli(parsed.value.aggressiveness, server.config.context_policy.aggressiveness_milli);
    const compact_result = context_compactor.compactSession(server.allocator, server.config.workspace_root, session.id, .{
        .keep_recent_messages = keep_recent_messages,
        .max_entries_per_checkpoint = max_entries_per_checkpoint,
        .aggressiveness_milli = aggressiveness_milli,
        .trigger = trigger,
    }) catch |err| switch (err) {
        context_compactor.Error.InvalidCompactionOptions => return Error.InvalidParams,
        else => return err,
    };
    defer compact_result.deinit(server.allocator);

    return renderJsonAlloc(server.allocator, protocol_types.SessionCompactResult{
        .session_id = session.id,
        .compacted = compact_result.checkpoint != null,
        .checkpoint = compact_result.checkpoint,
        .reason = if (compact_result.checkpoint == null) compact_result.reason else null,
    });
}

fn compactAggressivenessMilli(value: ?f64, default_milli: u16) !u16 {
    const provided = value orelse return default_milli;
    if (!std.math.isFinite(provided) or provided < 0.0 or provided > 1.0) return Error.InvalidParams;
    return @intFromFloat(provided * 1000.0 + 0.5);
}

fn handleSessionCancel(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, null);

    var cancellation_requested = false;
    if (session.status == .initialized) {
        try store.setSessionStatus(server.allocator, server.config.workspace_root, &session, .cancelled);
        cancellation_requested = true;
        try server.emitSessionEvent(
            session.id,
            "session_cancelled",
            "Cancellation requested before execution started.",
            types.statusLabel(session.status),
            session.updated_at_ms,
        );
    } else if (session.status == .running) {
        cancellation_requested = server.runtime.requestCancel(session.id);
    }

    return renderJsonAlloc(server.allocator, protocol_types.SessionCancelResult{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .cancellation_requested = cancellation_requested,
    });
}

fn handleSessionGet(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    const output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
    defer if (output) |value| server.allocator.free(value);

    const latest_event = try store.readLatestEvent(server.allocator, server.config.workspace_root, session.id);
    defer if (latest_event) |value| value.deinit(server.allocator);

    const events = try store.readEvents(server.allocator, server.config.workspace_root, session.id);
    defer types.deinitSessionEvents(server.allocator, events);

    const messages = try store.readSessionMessages(server.allocator, server.config.workspace_root, session.id);
    defer types.deinitSessionMessages(server.allocator, messages);

    return renderJsonAlloc(server.allocator, protocol_types.SessionGetResult{
        .session = makeSessionSummary(session, output),
        .latest_event = latest_event,
        .messages = messages,
        .events = events,
    });
}

fn handleSessionList(server: *Server) ![]u8 {
    const sessions = try store.listSessionRecords(server.allocator, server.config.workspace_root);
    defer types.deinitSessionRecords(server.allocator, sessions);

    var summaries = try server.allocator.alloc(protocol_types.SessionSummary, sessions.len);
    defer server.allocator.free(summaries);

    for (sessions, 0..) |session, index| {
        const output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (output) |value| server.allocator.free(value);
        summaries[index] = makeSessionSummary(session, output);
    }

    return renderJsonAlloc(server.allocator, protocol_types.SessionListResult{
        .sessions = summaries,
    });
}

fn handleToolsList(server: *Server, params: ?std.json.Value) ![]u8 {
    var format: []const u8 = "text";
    if (params) |value| {
        if (value != .object) return Error.InvalidParams;
        if (try optionalStringFromObject(&value.object, "format")) |provided| format = provided;
    }

    if (!std.mem.eql(u8, format, "text") and !std.mem.eql(u8, format, "json")) {
        return Error.InvalidParams;
    }

    const execution_context = tools.ExecutionContext{
        .workspace_root = server.config.workspace_root,
        .agent_service = server.agent_service,
    };
    const output = if (std.mem.eql(u8, format, "json"))
        try tools.renderCatalogJson(server.allocator, execution_context)
    else
        try tools.renderCatalog(server.allocator, execution_context);
    defer server.allocator.free(output);

    return renderJsonAlloc(server.allocator, protocol_types.ToolsListResult{
        .format = format,
        .output = output,
    });
}

fn handleEventsSubscribe(allocator: std.mem.Allocator) ![]u8 {
    return renderJsonAlloc(allocator, protocol_types.EventsSubscribeResult{
        .subscribed = true,
        .notification_method = protocol_types.notification_methods.session_event,
    });
}

fn handleHealthGet(allocator: std.mem.Allocator, config: *const types.Config) ![]u8 {
    return renderJsonAlloc(allocator, protocol_types.HealthGetResult{
        .ok = true,
        .model = config.openai_model,
        .workspace_root = config.workspace_root,
        .base_url = config.openai_base_url,
        .auth_provider = config.auth_provider,
        .subscription_plan_label = config.subscription_plan_label,
        .subscription_status = config.subscription_status,
    });
}

fn onLoopSessionInitialized(ctx: ?*anyopaque, session_id: []const u8) anyerror!void {
    _ = ctx;
    _ = session_id;
}

fn onLoopSessionEvent(
    ctx: ?*anyopaque,
    session_id: []const u8,
    event_type: []const u8,
    message: []const u8,
    status: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    try server.emitSessionEvent(session_id, event_type, message, status, timestamp_ms);
}

fn onLoopShouldCancel(ctx: ?*anyopaque, session_id: []const u8) bool {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    return server.runtime.shouldCancel(session_id);
}

fn makeSessionSummary(session: types.SessionRecord, output: ?[]const u8) protocol_types.SessionSummary {
    return .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = output,
        .parent_session_id = session.parent_session_id,
        .continued_from_session_id = session.continued_from_session_id,
        .display_name = session.display_name,
        .agent_profile = session.agent_profile,
        .failure_reason = session.failure_reason,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = session.updated_at_ms,
    };
}

fn parseParams(comptime T: type, allocator: std.mem.Allocator, params: ?std.json.Value) !std.json.Parsed(T) {
    const value = params orelse return Error.InvalidParams;
    if (value != .object) return Error.InvalidParams;
    return std.json.parseFromValue(T, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch Error.InvalidParams;
}

fn optionalStringFromObject(object: *const std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return Error.InvalidParams;
    return value.string;
}

fn extractRequestId(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("id") orelse return null;
    if (value != .string) return Error.InvalidRequest;
    return value.string;
}

fn waitForResponse(self: *LocalClient, request_id: []const u8) ![]u8 {
    while (true) {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        if (self.state.responses.fetchRemove(request_id)) |entry| {
            self.allocator.free(entry.key);
            return entry.value;
        }

        if (self.state.closed) {
            if (self.state.read_error) |read_error| return read_error;
            return Error.InvalidRpcResponse;
        }

        self.state.cond.wait(&self.state.mutex);
    }
}

fn takeNotificationAfter(self: *LocalClient, after_sequence: u64) !?Notification {
    self.state.mutex.lock();
    defer self.state.mutex.unlock();

    for (self.state.notifications.items) |notification| {
        if (notification.sequence <= after_sequence) continue;
        return .{
            .sequence = notification.sequence,
            .method = try self.allocator.dupe(u8, notification.method),
            .params_json = try self.allocator.dupe(u8, notification.params_json),
        };
    }

    if (self.state.closed) {
        if (self.state.read_error) |read_error| return read_error;
    }
    return null;
}

fn readerLoop(reader_context: *ReaderContext) void {
    const stdout_file = reader_context.stdout_file;

    while (true) {
        const payload = readFrame(reader_context.allocator, stdout_file) catch |err| {
            reader_context.state.recordClosure(err);
            return;
        } orelse {
            reader_context.state.recordClosure(null);
            return;
        };

        processIncomingFrame(reader_context, payload) catch |err| {
            reader_context.allocator.free(payload);
            reader_context.state.recordClosure(err);
            return;
        };
    }
}

fn processIncomingFrame(reader_context: *ReaderContext, payload: []u8) !void {
    errdefer reader_context.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, reader_context.allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidRpcResponse;
    const object = parsed.value.object;

    if (object.get("method")) |method_value| {
        if (method_value != .string) return Error.InvalidRpcResponse;
        const params_json = if (object.get("params")) |params_value|
            try renderJsonAlloc(reader_context.allocator, params_value)
        else
            try reader_context.allocator.dupe(u8, "null");
        errdefer reader_context.allocator.free(params_json);

        try reader_context.state.recordNotification(method_value.string, params_json);
        reader_context.allocator.free(payload);
        return;
    }

    const request_id = (try extractRequestId(object)) orelse return Error.InvalidRpcResponse;
    try reader_context.state.recordResponse(request_id, payload);
}

fn renderSuccessResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    result_payload: []const u8,
) ![]u8 {
    const id_payload = try renderJsonAlloc(allocator, id);
    defer allocator.free(id_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_payload, result_payload },
    );
}

fn renderErrorResponse(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    code: i32,
    message: []const u8,
) ![]u8 {
    const id_payload = if (id) |value|
        try renderJsonAlloc(allocator, value)
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_payload);

    const error_payload = try renderJsonAlloc(allocator, .{
        .code = code,
        .message = message,
    });
    defer allocator.free(error_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}",
        .{ id_payload, error_payload },
    );
}

fn errorResponseOrNull(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    code: i32,
    message: []const u8,
) !?[]u8 {
    if (id) |request_id| {
        const response = try renderErrorResponse(allocator, request_id, code, message);
        return response;
    }

    return null;
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

fn writeFrame(file: std.fs.File, payload: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    try writer.interface.print("Content-Length: {d}\r\n\r\n", .{payload.len});
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try readHeaderLine(allocator, file);
        if (line == null) {
            if (content_length == null) return null;
            return Error.InvalidFrame;
        }
        defer allocator.free(line.?);

        const trimmed = std.mem.trimRight(u8, line.?, "\r\n");
        if (trimmed.len == 0) break;

        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value_text = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value_text, 10) catch return Error.InvalidFrame;
        }
    }

    const expected_len = content_length orelse return Error.InvalidFrame;
    const payload = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(payload);
    try readExactly(file, payload);
    return payload;
}

fn readHeaderLine(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var line = std.array_list.Managed(u8).init(allocator);
    errdefer line.deinit();

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try file.read(&byte);
        if (read_len == 0) {
            if (line.items.len == 0) {
                line.deinit();
                return null;
            }
            return Error.InvalidFrame;
        }

        try line.append(byte[0]);
        if (byte[0] == '\n') return try line.toOwnedSlice();
        if (line.items.len > max_header_line_bytes) return Error.InvalidFrame;
    }
}

fn readExactly(file: std.fs.File, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const read_len = try file.read(buffer[offset..]);
        if (read_len == 0) return Error.InvalidFrame;
        offset += read_len;
    }
}

test "success response includes id and payload" {
    const allocator = std.testing.allocator;
    const response = try renderSuccessResponse(allocator, "abc", "{\"ok\":true}");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\":{\"ok\":true}") != null);
}

test "error response uses json-rpc envelope" {
    const allocator = std.testing.allocator;
    const response = try renderErrorResponse(allocator, "req-1", -32601, "Method not found");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32601") != null);
}

fn noopSend(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopLaunch(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: ?[]const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopAgentStatus(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopWait(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopList(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

const test_config = types.Config{
    .openai_base_url = @constCast("http://127.0.0.1:1234"),
    .openai_api_key = @constCast("test-key"),
    .openai_model = @constCast("test-model"),
    .max_steps = 2,
    .workspace_root = @constCast("."),
};

fn makeTestServer() Server {
    return .{
        .allocator = std.testing.allocator,
        .config = &test_config,
        .transport = .{
            .context = null,
            .sendFn = noopSend,
        },
        .agent_service = .{
            .context = null,
            .launchFn = noopLaunch,
            .statusFn = noopAgentStatus,
            .waitFn = noopWait,
            .listFn = noopList,
        },
        .stdout_file = std.fs.File.stdout(),
    };
}

test "processRequest returns parse errors for malformed json-rpc payloads" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(u8, "{\"jsonrpc\":");
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);
    defer if (response) |value| std.testing.allocator.free(value);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32700") != null);
}

test "processRequest returns method-not-found errors for unknown methods" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"missing/method\",\"params\":{}}",
    );
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);
    defer if (response) |value| std.testing.allocator.free(value);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32601") != null);
}

test "processRequest treats id-less initialize requests as notifications" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{}}",
    );
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);

    try std.testing.expect(response == null);
}
