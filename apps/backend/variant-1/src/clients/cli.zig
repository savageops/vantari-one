const std = @import("std");
const agents = @import("../core/agents/service.zig");
const config = @import("../core/config/resolver.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const stdio_rpc = @import("../host/stdio_rpc.zig");
const web = @import("../host/http_bridge.zig");

const RunCliOptions = struct {
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    json_output: bool = false,
    enable_agent_tools: bool = true,
};

const ServeCliOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4310,
};

const ToolsCliOptions = struct {
    json_output: bool = false,
};

const HealthCliOptions = struct {
    json_output: bool = false,
};

const ParsedRunArguments = struct {
    options: RunCliOptions = .{},
    help_requested: bool = false,
};

const ParsedServeArguments = struct {
    options: ServeCliOptions = .{},
    help_requested: bool = false,
};

const ParsedToolsArguments = struct {
    options: ToolsCliOptions = .{},
    help_requested: bool = false,
};

const ParsedHealthArguments = struct {
    options: HealthCliOptions = .{},
    help_requested: bool = false,
};

const ParsedSessionSummary = struct {
    session_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    output: ?[]const u8 = null,
};

const ParsedSessionCreateResult = struct {
    session: ParsedSessionSummary,
};

const ParsedSessionSendResult = struct {
    session: ParsedSessionSummary,
};

const ParsedHealthResult = struct {
    ok: bool,
    model: []const u8,
    workspace_root: []const u8,
    base_url: []const u8,
    auth_provider: ?[]const u8 = null,
    subscription_plan_label: ?[]const u8 = null,
    subscription_status: ?[]const u8 = null,
};

const ParsedToolsListResult = struct {
    format: []const u8,
    output: []const u8,
};

pub const root_help_text =
    \\VAR1 Zig Kernel
    \\
    \\Usage:
    \\  VAR1 <command> [flags]
    \\
    \\Commands:
    \\  run      Execute a prompt or resume a canonical session through the kernel protocol.
    \\  health   Report local runtime readiness through the kernel protocol.
    \\  serve    Start the HTTP bridge for /rpc, /events, and /api/health.
    \\  tools    Print the built-in tool catalog and schemas through the kernel protocol.
    \\  help     Print help for a command.
    \\
    \\Examples:
    \\  VAR1 run --prompt "Summarize src/cli.zig."
    \\  VAR1 run --prompt-file .\prompt.txt --json
    \\  VAR1 run --session-id session-1776778021956-42e781c4c8b4efb8
    \\  VAR1 health
    \\  VAR1 serve --host 127.0.0.1 --port 4310
    \\  VAR1 tools --json
    \\
    \\Notes:
    \\  zig build run -- <command> ... accepts the same command and flag surface.
    \\  VAR1 reads .env from the current workspace for run, health, serve, and tools execution.
    \\  Use VAR1 help <command> or VAR1 <command> --help for command-specific details.
    \\
;

pub const run_help_text =
    \\Usage:
    \\  VAR1 run --prompt <text> [--json] [--no-agent-tools]
    \\  VAR1 run --prompt-file <path> [--json] [--no-agent-tools]
    \\  VAR1 run --session-id <session-id> [--json] [--no-agent-tools]
    \\
    \\Flags:
    \\  --prompt <text>           Execute an inline prompt as a new session.
    \\  --prompt-file <path>      Read the prompt from a file and trim trailing newlines.
    \\  --session-id <session-id> Resume an existing canonical session and reuse its stored prompt.
    \\  --json                    Emit {"session_id","output"} instead of plain text.
    \\  --no-agent-tools          Hide launch_agent, agent_status, wait_agent, and list_agents from the model.
    \\  -h, --help                Print help for the run command.
    \\
    \\Rules:
    \\  Exactly one prompt source is allowed: --prompt, --prompt-file, or --session-id.
    \\  When --session-id is provided, VAR1 resumes the stored session prompt and does not accept a new prompt source.
    \\
    \\Examples:
    \\  VAR1 run --prompt "List the files under src."
    \\  VAR1 run --prompt-file .\delegated-prompt.txt --json
    \\  VAR1 run --session-id session-1776778021956-42e781c4c8b4efb8
    \\
;

pub const health_help_text =
    \\Usage:
    \\  VAR1 health [--json]
    \\
    \\Flags:
    \\  --json                    Emit {"ok","model","workspace_root","base_url","auth_provider"} instead of plain text.
    \\  -h, --help                Print help for the health command.
    \\
    \\Behavior:
    \\  health is a thin protocol-backed readiness check and does not send a model completion request.
    \\
    \\Examples:
    \\  VAR1 health
    \\  VAR1 health --json
    \\
;

pub const serve_help_text =
    \\Usage:
    \\  VAR1 serve [--host <host>] [--port <port>]
    \\
    \\Flags:
    \\  --host <host>             Bind address for the local bridge. Default: 127.0.0.1
    \\  --port <port>             Bind port for the local bridge. Default: 4310
    \\  -h, --help                Print help for the serve command.
    \\
    \\Routes:
    \\  POST /rpc                 JSON-RPC bridge to the hidden kernel stdio host
    \\  GET  /events              Server-sent events for session notifications
    \\  GET  /api/health          Thin readiness alias for scripts and operators
    \\
    \\Example:
    \\  VAR1 serve --host 127.0.0.1 --port 4310
    \\
;

pub const tools_help_text =
    \\Usage:
    \\  VAR1 tools [--json]
    \\
    \\Flags:
    \\  --json                    Emit machine-readable tool contracts for the current default catalog.
    \\  -h, --help                Print help for the tools command.
    \\
    \\JSON output shape:
    \\  {
    \\    "workspace_root": "<absolute-path>",
    \\    "tools": [
    \\      {
    \\        "name": "...",
    \\        "description": "...",
    \\        "parameters_schema": { ... },
    \\        "contract_example": { ... },
    \\        "usage_hint": "...",
    \\        "availability": {
    \\          "status": "available|unavailable",
    \\          "dependencies": [{ "kind": "external_command", "name": "iex", "available": true }]
    \\        }
    \\      }
    \\    ]
    \\  }
    \\
    \\Notes:
    \\  The default tools catalog shows the same file and agent tools exposed for ordinary coding prompts.
    \\  Workspace-state tools remain relevance-gated and are enabled only for explicitly .var-state-related requests.
    \\
    \\Examples:
    \\  VAR1 tools
    \\  VAR1 tools --json
    \\
;

pub fn main(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter.next();
    const command = iter.next() orelse {
        try writeStdout(root_help_text);
        return;
    };

    if (isHelpFlag(command)) {
        try writeStdout(root_help_text);
        return;
    }

    if (std.mem.eql(u8, command, "help")) {
        const requested_topic = iter.next();
        if (requested_topic) |topic| {
            if (iter.next() != null) {
                try printInvalidArguments("help", root_help_text);
                return error.InvalidArgs;
            }

            const text = helpText(topic) orelse {
                try printUnknownCommand(topic);
                return error.InvalidArgs;
            };
            try writeStdout(text);
            return;
        }

        try writeStdout(root_help_text);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        const parsed = parseRunArguments(iter) catch |err| {
            try printInvalidArguments("run", run_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(run_help_text);
            return;
        }
        try executeRunViaKernel(allocator, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "health")) {
        const parsed = parseHealthArguments(iter) catch |err| {
            try printInvalidArguments("health", health_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(health_help_text);
            return;
        }
        try executeHealthViaKernel(allocator, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "serve")) {
        const parsed = parseServeArguments(iter) catch |err| {
            try printInvalidArguments("serve", serve_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(serve_help_text);
            return;
        }

        const loaded_config = try config.loadDefault(allocator, ".");
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
        };
        try web.serve(allocator, loaded_config, .{
            .host = parsed.options.host,
            .port = parsed.options.port,
            .transport = transport,
        });
        return;
    }

    if (std.mem.eql(u8, command, "kernel-stdio")) {
        const loaded_config = try config.loadDefault(allocator, ".");
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
        };
        var agent_service = agents.Service.init(&loaded_config);
        try stdio_rpc.serveKernel(allocator, &loaded_config, transport, agent_service.handle());
        return;
    }

    if (std.mem.eql(u8, command, "tools")) {
        const parsed = parseToolsArguments(iter) catch |err| {
            try printInvalidArguments("tools", tools_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(tools_help_text);
            return;
        }
        try executeToolsViaKernel(allocator, parsed.options);
        return;
    }

    try printUnknownCommand(command);
    return error.InvalidArgs;
}

fn executeRunViaKernel(allocator: std.mem.Allocator, run_options: RunCliOptions) !void {
    var client = try stdio_rpc.LocalClient.init(allocator);
    defer client.deinit();

    const initialize = try client.call(protocol_types.methods.initialize, "{}");
    defer initialize.deinit(allocator);
    const initialize_result = try expectKernelResult(allocator, initialize);
    defer allocator.free(initialize_result);

    const session_id = if (run_options.session_id) |existing_session_id|
        try allocator.dupe(u8, existing_session_id)
    else blk: {
        const prompt = try resolvePromptInput(allocator, run_options.prompt, run_options.prompt_file);
        defer allocator.free(prompt);

        const create_params = try renderJsonAlloc(allocator, .{
            .prompt = prompt,
            .enable_agent_tools = run_options.enable_agent_tools,
        });
        defer allocator.free(create_params);

        const create_call = try client.call(protocol_types.methods.session_create, create_params);
        defer create_call.deinit(allocator);
        const create_result_json = try expectKernelResult(allocator, create_call);
        defer allocator.free(create_result_json);

        var parsed_create = try std.json.parseFromSlice(ParsedSessionCreateResult, allocator, create_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_create.deinit();

        break :blk try allocator.dupe(u8, parsed_create.value.session.session_id);
    };
    defer allocator.free(session_id);

    const send_params = try renderJsonAlloc(allocator, .{
        .session_id = session_id,
        .enable_agent_tools = run_options.enable_agent_tools,
    });
    defer allocator.free(send_params);

    const send_call = try client.call(protocol_types.methods.session_send, send_params);
    defer send_call.deinit(allocator);
    const send_result_json = try expectKernelResult(allocator, send_call);
    defer allocator.free(send_result_json);

    var parsed_send = try std.json.parseFromSlice(ParsedSessionSendResult, allocator, send_result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_send.deinit();

    const output = parsed_send.value.session.output orelse "";
    const json_payload = try renderRunResultJson(allocator, parsed_send.value.session.session_id, output);
    defer allocator.free(json_payload);

    if (run_options.json_output) {
        try writeStdout(json_payload);
        return;
    }

    try writeStdout(output);
    try writeStdout("\n");
}

fn executeHealthViaKernel(allocator: std.mem.Allocator, options: HealthCliOptions) !void {
    var client = try stdio_rpc.LocalClient.init(allocator);
    defer client.deinit();

    const call = try client.call(protocol_types.methods.health_get, "{}");
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedHealthResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (options.json_output) {
        const json_payload = try std.fmt.allocPrint(allocator, "{f}\n", .{
            std.json.fmt(parsed.value, .{ .whitespace = .indent_2 }),
        });
        defer allocator.free(json_payload);
        try writeStdout(json_payload);
        return;
    }

    const text_payload = try std.fmt.allocPrint(
        allocator,
        "VAR1 health\nstatus: ready\nmodel: {s}\nworkspace_root: {s}\nbase_url: {s}\nauth_provider: {s}\nsubscription_plan: {s}\nsubscription_status: {s}\n",
        .{
            parsed.value.model,
            parsed.value.workspace_root,
            parsed.value.base_url,
            parsed.value.auth_provider orelse "unknown",
            parsed.value.subscription_plan_label orelse "unknown",
            parsed.value.subscription_status orelse "unknown",
        },
    );
    defer allocator.free(text_payload);
    try writeStdout(text_payload);
}

fn executeToolsViaKernel(allocator: std.mem.Allocator, options: ToolsCliOptions) !void {
    var client = try stdio_rpc.LocalClient.init(allocator);
    defer client.deinit();

    const params_json = try renderJsonAlloc(allocator, .{
        .format = if (options.json_output) "json" else "text",
    });
    defer allocator.free(params_json);

    const call = try client.call(protocol_types.methods.tools_list, params_json);
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedToolsListResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writeStdout(parsed.value.output);
    if (options.json_output) try writeStdout("\n");
}

pub fn helpText(command: ?[]const u8) ?[]const u8 {
    const name = command orelse return root_help_text;
    if (std.mem.eql(u8, name, "run")) return run_help_text;
    if (std.mem.eql(u8, name, "health")) return health_help_text;
    if (std.mem.eql(u8, name, "serve")) return serve_help_text;
    if (std.mem.eql(u8, name, "tools")) return tools_help_text;
    if (std.mem.eql(u8, name, "help")) return root_help_text;
    return null;
}

fn parseRunArguments(iter: *std.process.ArgIterator) !ParsedRunArguments {
    var parsed = ParsedRunArguments{};
    var prompt_source_count: u8 = 0;

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt")) {
            parsed.options.prompt = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt-file")) {
            parsed.options.prompt_file = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session-id")) {
            parsed.options.session_id = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-agent-tools")) {
            parsed.options.enable_agent_tools = false;
            continue;
        }
        return error.InvalidArgs;
    }

    if (parsed.help_requested) return parsed;
    if (prompt_source_count != 1) return error.InvalidArgs;
    return parsed;
}

fn parseHealthArguments(iter: *std.process.ArgIterator) !ParsedHealthArguments {
    var parsed = ParsedHealthArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseServeArguments(iter: *std.process.ArgIterator) !ParsedServeArguments {
    var parsed = ParsedServeArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--host")) {
            parsed.options.host = iter.next() orelse return error.InvalidArgs;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            const port_text = iter.next() orelse return error.InvalidArgs;
            parsed.options.port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidArgs;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseToolsArguments(iter: *std.process.ArgIterator) !ParsedToolsArguments {
    var parsed = ParsedToolsArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

pub fn resolvePromptInput(
    allocator: std.mem.Allocator,
    prompt: ?[]const u8,
    prompt_file: ?[]const u8,
) ![]u8 {
    if (prompt) |value| return allocator.dupe(u8, value);

    if (prompt_file) |path| {
        const file_text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        errdefer allocator.free(file_text);

        const trimmed = std.mem.trimRight(u8, file_text, "\r\n");
        if (trimmed.len == file_text.len) return file_text;

        const owned = try allocator.dupe(u8, trimmed);
        allocator.free(file_text);
        return owned;
    }

    return allocator.dupe(u8, "");
}

fn expectKernelResult(allocator: std.mem.Allocator, call: stdio_rpc.RpcCallResult) ![]u8 {
    if (call.error_json) |error_json| {
        const message = try std.fmt.allocPrint(allocator, "kernel rpc error: {s}\n", .{error_json});
        defer allocator.free(message);
        try writeStderr(message);
        return error.RpcRemoteError;
    }

    return allocator.dupe(u8, call.result_json orelse return error.InvalidRpcResponse);
}

fn renderRunResultJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    output: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .session_id = session_id,
            .output = output,
        }, .{ .whitespace = .indent_2 }),
    });
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

fn writeStdout(text: []const u8) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.writeAll(text);
    try stdout_writer.interface.flush();
}

fn writeStderr(text: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(text);
    try stderr_writer.interface.flush();
}

fn printInvalidArguments(command: []const u8, help_text: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "error: invalid arguments for '{s}'.\n\n{s}", .{ command, help_text });
    try writeStderr(message);
}

fn printUnknownCommand(command: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "error: unknown command '{s}'.\n\n{s}", .{ command, root_help_text });
    try writeStderr(message);
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}
