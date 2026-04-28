const std = @import("std");
const types = @import("../../shared/types.zig");

// TODO: Keep transport details isolated here so the loop stays provider-agnostic.

pub const Error = error{
    BadStatus,
    MissingChoice,
    MissingContent,
};

const max_head_bytes = 64 * 1024;
const max_response_bytes = 4 * 1024 * 1024;
const max_transport_bytes = max_head_bytes + max_response_bytes;
const plain_read_buffer_size = 8 * 1024;
const plain_write_buffer_size = 1024;
const tls_record_buffer_size = std.crypto.tls.Client.min_buffer_len;
const tls_plaintext_write_buffer_size = tls_record_buffer_size;
const tls_read_buffer_size = tls_record_buffer_size + max_head_bytes;

const Scheme = enum {
    http,
    https,
};

const ParsedResponse = struct {
    model: ?[]const u8 = null,
    choices: []const Choice,

    const Choice = struct {
        message: Message,
    };

    const Message = struct {
        content: ?[]const u8 = null,
        tool_calls: ?[]const ParsedToolCall = null,
    };

    const ParsedToolCall = struct {
        id: ?[]const u8 = null,
        function: Function,

        const Function = struct {
            name: []const u8,
            arguments: std.json.Value,
        };
    };
};

pub fn complete(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
) !types.CompletionResponse {
    return completeWithTransport(allocator, config, request, .{
        .context = null,
        .sendFn = httpSend,
    });
}

pub const Transport = struct {
    context: ?*anyopaque,
    sendFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        api_key: []const u8,
        payload: []const u8,
    ) anyerror![]u8,

    pub fn send(
        self: Transport,
        allocator: std.mem.Allocator,
        url: []const u8,
        api_key: []const u8,
        payload: []const u8,
    ) anyerror![]u8 {
        return self.sendFn(self.context, allocator, url, api_key, payload);
    }
};

pub fn completeWithTransport(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: Transport,
) !types.CompletionResponse {
    const url = try completionUrl(allocator, config.openai_base_url);
    defer allocator.free(url);

    const payload = try buildRequestJson(allocator, config.openai_model, request);
    defer allocator.free(payload);

    const response_body = try transport.send(allocator, url, config.openai_api_key, payload);
    defer allocator.free(response_body);

    return parseCompletionResponse(allocator, config.openai_model, response_body);
}

fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: []const u8,
    request: types.CompletionRequest,
) ![]u8 {
    var payload = std.array_list.Managed(u8).init(allocator);
    errdefer payload.deinit();

    const writer = payload.writer();
    try writer.writeAll("{\"model\":");
    try writeJsonValue(writer, model);
    try writer.writeAll(",\"messages\":[");

    for (request.messages, 0..) |message, index| {
        if (index > 0) try writer.writeAll(",");
        try writeMessageJson(writer, message);
    }

    try writer.writeAll("],\"temperature\":0");

    if (request.tool_definitions.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tool_definitions, 0..) |tool_definition, index| {
            if (index > 0) try writer.writeAll(",");
            try writeToolDefinitionJson(writer, tool_definition);
        }
        try writer.writeAll("],\"tool_choice\":\"auto\"");
    }

    try writer.writeAll("}");
    return payload.toOwnedSlice();
}

fn parseCompletionResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    var parsed = try std.json.parseFromSlice(ParsedResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return Error.MissingChoice;

    const parsed_message = parsed.value.choices[0].message;
    const tool_calls = try duplicateToolCalls(allocator, parsed_message.tool_calls orelse &.{});
    errdefer {
        for (tool_calls) |tool_call| tool_call.deinit(allocator);
        if (tool_calls.len > 0) allocator.free(tool_calls);
    }

    return .{
        .model = try allocator.dupe(u8, parsed.value.model orelse configured_model),
        .content = if (parsed_message.content) |value| try allocator.dupe(u8, value) else null,
        .tool_calls = tool_calls,
    };
}

pub fn completionUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    const suffix = if (hasExplicitVersionSegment(trimmed))
        "/chat/completions"
    else
        "/v1/chat/completions";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix });
}

fn hasExplicitVersionSegment(base_url: []const u8) bool {
    const slash_index = std.mem.lastIndexOfScalar(u8, base_url, '/') orelse return false;
    const segment = base_url[slash_index + 1 ..];
    if (segment.len < 2 or segment[0] != 'v') return false;

    for (segment[1..]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }

    return true;
}

pub fn httpSend(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    const uri = try std.Uri.parse(url);
    const scheme = try schemeFromUri(uri.scheme);

    var host_buffer: [std.Uri.host_name_max]u8 = undefined;
    const host = try uri.getHost(&host_buffer);
    const port = uri.port orelse defaultPort(scheme);

    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    defer stream.close();

    return switch (scheme) {
        .http => plainHttpSend(allocator, stream, &uri, api_key, payload),
        .https => tlsHttpSend(allocator, stream, host, &uri, api_key, payload),
    };
}

fn plainHttpSend(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    uri: *const std.Uri,
    api_key: []const u8,
    payload: []const u8,
) ![]u8 {
    var read_buffer: [plain_read_buffer_size]u8 = undefined;
    var write_buffer: [plain_write_buffer_size]u8 = undefined;

    var stream_reader = stream.reader(&read_buffer);
    var stream_writer = stream.writer(&write_buffer);

    try writeRequestHead(&stream_writer.interface, uri, api_key, payload.len);
    try stream_writer.interface.writeAll(payload);
    try stream_writer.interface.flush();

    return readResponse(allocator, stream_reader.interface());
}

fn tlsHttpSend(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    host: []const u8,
    uri: *const std.Uri,
    api_key: []const u8,
    payload: []const u8,
) ![]u8 {
    var encrypted_write_buffer: [tls_record_buffer_size]u8 = undefined;
    var encrypted_read_buffer: [tls_record_buffer_size]u8 = undefined;
    var tls_read_buffer: [tls_read_buffer_size]u8 = undefined;
    var plaintext_write_buffer: [tls_plaintext_write_buffer_size]u8 = undefined;

    var stream_writer = stream.writer(&encrypted_write_buffer);
    var stream_reader = stream.reader(&encrypted_read_buffer);

    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(allocator);
    try ca_bundle.rescan(allocator);

    var tls_client = try std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = tls_read_buffer[0..],
            .write_buffer = plaintext_write_buffer[0..],
            .allow_truncation_attacks = true,
        },
    );

    try writeRequestHead(&tls_client.writer, uri, api_key, payload.len);
    try tls_client.writer.writeAll(payload);
    try tls_client.writer.flush();
    try stream_writer.interface.flush();

    return readResponse(allocator, &tls_client.reader);
}

fn writeRequestHead(
    writer: *std.Io.Writer,
    uri: *const std.Uri,
    api_key: []const u8,
    payload_len: usize,
) !void {
    try writer.writeAll("POST ");
    try uri.writeToStream(writer, .{ .path = true, .query = true });
    try writer.writeAll(" HTTP/1.1\r\n");

    try writer.writeAll("host: ");
    try uri.writeToStream(writer, .{ .authority = true });
    try writer.writeAll("\r\n");

    try writer.writeAll("authorization: Bearer ");
    try writer.writeAll(api_key);
    try writer.writeAll("\r\n");

    try writer.writeAll("content-type: application/json\r\n");
    try writer.writeAll("accept: application/json\r\n");
    try writer.writeAll("accept-encoding: identity\r\n");
    try writer.writeAll("connection: close\r\n");
    try writer.print("content-length: {d}\r\n\r\n", .{payload_len});
}

fn readResponse(allocator: std.mem.Allocator, source_reader: *std.Io.Reader) ![]u8 {
    var raw_response = std.array_list.Managed(u8).init(allocator);
    errdefer raw_response.deinit();

    var response_writer = raw_response.writer();
    var response_writer_buffer: [2048]u8 = undefined;
    var response_writer_adapter = response_writer.adaptToNewApi(&response_writer_buffer);

    _ = source_reader.streamRemaining(&response_writer_adapter.new_interface) catch |err| switch (err) {
        error.WriteFailed => return response_writer_adapter.err orelse err,
        else => return err,
    };
    try response_writer_adapter.new_interface.flush();

    if (raw_response.items.len > max_transport_bytes) {
        return error.StreamTooLong;
    }

    const raw_response_owned = try raw_response.toOwnedSlice();
    defer allocator.free(raw_response_owned);

    return parseRawHttpResponse(allocator, raw_response_owned);
}

fn parseRawHttpResponse(allocator: std.mem.Allocator, raw_response: []const u8) ![]u8 {
    const header_end = std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return error.InvalidHttpResponse;
    const headers = raw_response[0..header_end];
    const body = raw_response[header_end + 4 ..];

    const status_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = headers[0..status_line_end];

    var status_iter = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = status_iter.next() orelse return error.InvalidHttpResponse;
    const status_code_text = status_iter.next() orelse return error.InvalidHttpResponse;
    const status_code = try std.fmt.parseUnsigned(u16, status_code_text, 10);
    if (status_code != 200) return Error.BadStatus;

    var is_chunked = false;
    var content_length: ?usize = null;

    var line_iter = std.mem.splitSequence(u8, headers[status_line_end + 2 ..], "\r\n");
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator_index], " ");
        const value = std.mem.trim(u8, line[separator_index + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            is_chunked = true;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = try std.fmt.parseUnsigned(usize, value, 10);
        }
    }

    if (is_chunked) {
        return decodeChunkedBody(allocator, body);
    }

    if (content_length) |expected_len| {
        if (body.len < expected_len) return error.InvalidHttpResponse;
        return allocator.dupe(u8, body[0..expected_len]);
    }

    return allocator.dupe(u8, body);
}

fn decodeChunkedBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var decoded = std.array_list.Managed(u8).init(allocator);
    errdefer decoded.deinit();

    var cursor: usize = 0;
    while (true) {
        const size_line_end = std.mem.indexOfPos(u8, body, cursor, "\r\n") orelse return error.InvalidHttpResponse;
        const raw_size = body[cursor..size_line_end];
        const extension_index = std.mem.indexOfScalar(u8, raw_size, ';') orelse raw_size.len;
        const size_text = std.mem.trim(u8, raw_size[0..extension_index], " ");
        const chunk_size = try std.fmt.parseUnsigned(usize, size_text, 16);

        cursor = size_line_end + 2;
        if (chunk_size == 0) {
            return decoded.toOwnedSlice();
        }

        if (cursor + chunk_size + 2 > body.len) return error.InvalidHttpResponse;
        try decoded.appendSlice(body[cursor .. cursor + chunk_size]);
        cursor += chunk_size;

        if (!std.mem.eql(u8, body[cursor .. cursor + 2], "\r\n")) return error.InvalidHttpResponse;
        cursor += 2;
    }
}

fn schemeFromUri(scheme: []const u8) !Scheme {
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return .http;
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return .https;
    return error.UnsupportedUriScheme;
}

fn defaultPort(scheme: Scheme) u16 {
    return switch (scheme) {
        .http => 80,
        .https => 443,
    };
}

fn writeMessageJson(writer: anytype, message: types.ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try writeJsonValue(writer, types.roleLabel(message.role));

    if (message.content) |content| {
        try writer.writeAll(",\"content\":");
        try writeJsonValue(writer, content);
    }

    if (message.tool_call_id) |tool_call_id| {
        try writer.writeAll(",\"tool_call_id\":");
        try writeJsonValue(writer, tool_call_id);
    }

    if (message.tool_calls.len > 0) {
        try writer.writeAll(",\"tool_calls\":[");
        for (message.tool_calls, 0..) |tool_call, index| {
            if (index > 0) try writer.writeAll(",");
            try writeToolCallJson(writer, tool_call);
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}");
}

fn writeToolDefinitionJson(writer: anytype, tool_definition: types.ToolDefinition) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonValue(writer, tool_definition.name);
    try writer.writeAll(",\"description\":");
    try writeJsonValue(writer, tool_definition.description);
    try writer.writeAll(",\"parameters\":");
    try writer.writeAll(tool_definition.parameters_json);
    try writer.writeAll("}}");
}

fn writeToolCallJson(writer: anytype, tool_call: types.ToolCall) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonValue(writer, tool_call.id);
    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonValue(writer, tool_call.name);
    try writer.writeAll(",\"arguments\":");
    try writeJsonValue(writer, tool_call.arguments_json);
    try writer.writeAll("}}");
}

fn duplicateToolCalls(
    allocator: std.mem.Allocator,
    parsed_tool_calls: []const ParsedResponse.ParsedToolCall,
) ![]types.ToolCall {
    if (parsed_tool_calls.len == 0) return &.{};

    var tool_calls = try allocator.alloc(types.ToolCall, parsed_tool_calls.len);
    errdefer allocator.free(tool_calls);

    for (parsed_tool_calls, 0..) |parsed_tool_call, index| {
        const arguments_json = switch (parsed_tool_call.function.arguments) {
            .string => |value| try allocator.dupe(u8, value),
            else => try std.fmt.allocPrint(allocator, "{f}", .{
                std.json.fmt(parsed_tool_call.function.arguments, .{}),
            }),
        };
        errdefer allocator.free(arguments_json);

        tool_calls[index] = .{
            .id = try allocator.dupe(u8, parsed_tool_call.id orelse "call-generated"),
            .name = try allocator.dupe(u8, parsed_tool_call.function.name),
            .arguments_json = arguments_json,
        };
    }

    return tool_calls;
}

fn writeJsonValue(writer: anytype, value: anytype) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}
