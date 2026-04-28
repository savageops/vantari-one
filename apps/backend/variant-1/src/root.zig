const std = @import("std");

pub const shared = @import("shared/index.zig");
pub const core = @import("core/index.zig");
pub const host = @import("host/index.zig");
pub const clients = @import("clients/index.zig");

// Layered namespaces are canonical. Flat aliases remain as the one-wave
// compatibility surface while callers converge on shared/core/host/clients.
pub const types = shared.types;
pub const fsutil = shared.fsutil;
pub const config = shared.config;
pub const store = core.session_store;
pub const auth_store = core.auth_store;
pub const auth_resolver = core.auth_resolver;
pub const context = core.context;
pub const docs_sync = @import("docs_sync.zig");
pub const provider = core.provider_runtime;
pub const harness_tools = core.harness_runtime;
pub const tools = core.tool_runtime;
pub const loop = core.executor;
pub const agents = core.agent_runtime;
pub const protocol_types = core.protocol_types;
pub const stdio_rpc = host.stdio_rpc;
pub const web = host.http_bridge;
pub const cli = clients.cli;

test "root exports scaffold" {
    try std.testing.expect(@hasDecl(@This(), "shared"));
    try std.testing.expect(@hasDecl(@This(), "core"));
    try std.testing.expect(@hasDecl(@This(), "host"));
    try std.testing.expect(@hasDecl(@This(), "clients"));
    _ = core.executor;
    _ = host.stdio_rpc;
    _ = clients.cli;
}

test {
    _ = core.provider_runtime;
}
