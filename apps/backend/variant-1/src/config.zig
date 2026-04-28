const std = @import("std");
const auth_resolver = @import("auth_resolver.zig");
const fsutil = @import("fsutil.zig");
const types = @import("types.zig");

// TODO: Replace the manual env parsing with a fuller parser only if the simple `.env` contract becomes insufficient.

pub const Error = error{
    MissingKey,
    InvalidValue,
};

pub fn loadFromEnvFile(allocator: std.mem.Allocator, env_path: []const u8) !types.Config {
    const content = try std.fs.cwd().readFileAlloc(allocator, env_path, 1024 * 1024);
    defer allocator.free(content);

    var openai_base_url: ?[]u8 = null;
    var openai_api_key: ?[]u8 = null;
    var openai_model: ?[]u8 = null;
    var workspace_root: ?[]u8 = null;
    var harness_max_steps: usize = 1;

    errdefer if (openai_base_url) |value| allocator.free(value);
    errdefer if (openai_api_key) |value| allocator.free(value);
    errdefer if (openai_model) |value| allocator.free(value);
    errdefer if (workspace_root) |value| allocator.free(value);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t");
        var value = std.mem.trim(u8, line[separator_index + 1 ..], " \t");
        value = trimQuotes(value);

        if (std.mem.eql(u8, key, "OPENAI_BASE_URL")) {
            openai_base_url = try dupeReplacing(allocator, openai_base_url, value);
        } else if (std.mem.eql(u8, key, "OPENAI_API_KEY")) {
            openai_api_key = try dupeReplacing(allocator, openai_api_key, value);
        } else if (std.mem.eql(u8, key, "OPENAI_MODEL")) {
            openai_model = try dupeReplacing(allocator, openai_model, value);
        } else if (std.mem.eql(u8, key, "HARNESS_WORKSPACE")) {
            workspace_root = try dupeReplacing(allocator, workspace_root, value);
        } else if (std.mem.eql(u8, key, "HARNESS_MAX_STEPS")) {
            harness_max_steps = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidValue;
        }
    }

    const resolved_base_url = openai_base_url orelse return Error.MissingKey;
    const resolved_api_key = openai_api_key orelse return Error.MissingKey;
    const resolved_model = openai_model orelse return Error.MissingKey;
    const provider_id = inferProviderId(resolved_base_url, resolved_model);

    return .{
        .openai_base_url = resolved_base_url,
        .openai_api_key = resolved_api_key,
        .openai_model = resolved_model,
        .auth_provider = try allocator.dupe(u8, provider_id),
        .subscription_plan_label = if (isZaiProvider(provider_id)) try allocator.dupe(u8, resolved_model) else null,
        .subscription_status = if (isZaiProvider(provider_id)) try allocator.dupe(u8, "active") else null,
        .harness_max_steps = harness_max_steps,
        .workspace_root = workspace_root orelse try allocator.dupe(u8, "."),
    };
}

pub fn loadDefault(allocator: std.mem.Allocator, workspace_root: []const u8) !types.Config {
    const env_path = try std.fs.path.join(allocator, &.{ workspace_root, ".env" });
    defer allocator.free(env_path);

    var config = loadFromEnvFile(allocator, env_path) catch |err| switch (err) {
        error.FileNotFound, Error.MissingKey => return loadDefaultFromAuthOnly(allocator, workspace_root),
        else => return err,
    };

    const canonical_workspace_root = try canonicalizeWorkspaceRoot(
        allocator,
        workspace_root,
        config.workspace_root,
    );
    allocator.free(config.workspace_root);
    config.workspace_root = canonical_workspace_root;

    var resolved_auth = try auth_resolver.resolveProviderAuth(allocator, config.workspace_root, .{
        .provider_id = config.auth_provider orelse inferProviderId(config.openai_base_url, config.openai_model),
        .base_url = config.openai_base_url,
        .api_key = config.openai_api_key,
        .model = config.openai_model,
        .subscription_plan_id = if (isZaiProvider(config.auth_provider orelse "")) "zai-coding-plan" else null,
        .subscription_plan_label = config.subscription_plan_label,
        .subscription_status = config.subscription_status,
        .subscription_source = "manual",
    });
    defer resolved_auth.deinit(allocator);

    try applyResolvedAuth(allocator, &config, resolved_auth);
    return config;
}

fn loadDefaultFromAuthOnly(allocator: std.mem.Allocator, workspace_root: []const u8) !types.Config {
    const canonical_workspace_root = try canonicalizeWorkspaceRoot(allocator, workspace_root, ".");
    errdefer allocator.free(canonical_workspace_root);

    var resolved_auth = try auth_resolver.resolveProviderAuth(allocator, canonical_workspace_root, null);
    defer resolved_auth.deinit(allocator);

    return .{
        .openai_base_url = try allocator.dupe(u8, resolved_auth.base_url),
        .openai_api_key = try allocator.dupe(u8, resolved_auth.api_key),
        .openai_model = try allocator.dupe(u8, resolved_auth.model),
        .auth_provider = try allocator.dupe(u8, resolved_auth.provider_id),
        .subscription_plan_label = if (resolved_auth.subscription_plan_label) |value| try allocator.dupe(u8, value) else null,
        .subscription_status = if (resolved_auth.subscription_status) |value| try allocator.dupe(u8, value) else null,
        .harness_max_steps = 1,
        .workspace_root = canonical_workspace_root,
    };
}

fn applyResolvedAuth(allocator: std.mem.Allocator, config: *types.Config, resolved_auth: auth_resolver.ResolvedAuth) !void {
    const next_base_url = try allocator.dupe(u8, resolved_auth.base_url);
    errdefer allocator.free(next_base_url);
    const next_api_key = try allocator.dupe(u8, resolved_auth.api_key);
    errdefer allocator.free(next_api_key);
    const next_model = try allocator.dupe(u8, resolved_auth.model);
    errdefer allocator.free(next_model);
    const next_auth_provider = try allocator.dupe(u8, resolved_auth.provider_id);
    errdefer allocator.free(next_auth_provider);
    const next_subscription_plan_label = if (resolved_auth.subscription_plan_label) |value| try allocator.dupe(u8, value) else null;
    errdefer if (next_subscription_plan_label) |value| allocator.free(value);
    const next_subscription_status = if (resolved_auth.subscription_status) |value| try allocator.dupe(u8, value) else null;
    errdefer if (next_subscription_status) |value| allocator.free(value);

    allocator.free(config.openai_base_url);
    allocator.free(config.openai_api_key);
    allocator.free(config.openai_model);
    if (config.auth_provider) |value| allocator.free(value);
    if (config.subscription_plan_label) |value| allocator.free(value);
    if (config.subscription_status) |value| allocator.free(value);

    config.openai_base_url = next_base_url;
    config.openai_api_key = next_api_key;
    config.openai_model = next_model;
    config.auth_provider = next_auth_provider;
    config.subscription_plan_label = next_subscription_plan_label;
    config.subscription_status = next_subscription_status;
}

fn canonicalizeWorkspaceRoot(
    allocator: std.mem.Allocator,
    invocation_root: []const u8,
    configured_root: []const u8,
) ![]u8 {
    const invocation_abs = try fsutil.resolveAbsolute(allocator, invocation_root);
    defer allocator.free(invocation_abs);

    const anchored_root = if (std.fs.path.isAbsolute(configured_root))
        try allocator.dupe(u8, configured_root)
    else
        try std.fs.path.resolve(allocator, &.{ invocation_abs, configured_root });
    defer allocator.free(anchored_root);

    return std.fs.realpathAlloc(allocator, anchored_root);
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn dupeReplacing(allocator: std.mem.Allocator, existing: ?[]u8, value: []const u8) ![]u8 {
    if (existing) |previous| allocator.free(previous);
    return allocator.dupe(u8, value);
}

fn inferProviderId(base_url: []const u8, model: []const u8) []const u8 {
    if (std.mem.indexOf(u8, base_url, "z.ai") != null) return "zai";
    if (std.mem.indexOf(u8, model, "GLM") != null or std.mem.indexOf(u8, model, "glm") != null) return "zai";
    return "openai-compatible";
}

fn isZaiProvider(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "zai");
}
