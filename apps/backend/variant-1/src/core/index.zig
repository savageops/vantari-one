const std = @import("std");

pub const agent_runtime = @import("agents/service.zig");
pub const auth = @import("auth/index.zig");
pub const auth_resolver = auth.resolver;
pub const auth_store = auth.store;
pub const config = @import("config/resolver.zig");
pub const context = @import("context/index.zig");
pub const docs_sync = @import("docs/sync.zig");
pub const executor = @import("executor/loop.zig");
pub const workspace_runtime = tools.workspace_runtime;
pub const plugins = @import("plugins/index.zig");
pub const protocol_types = @import("../shared/protocol/types.zig");
pub const provider_runtime = @import("providers/openai_compatible.zig");
pub const session_store = @import("sessions/store.zig");
pub const tools = @import("tools/index.zig");
pub const tool_runtime = tools.runtime;

test "core namespace exposes executor and store" {
    try std.testing.expect(@hasDecl(@This(), "executor"));
    try std.testing.expect(@hasDecl(@This(), "session_store"));
    try std.testing.expect(@hasDecl(@This(), "config"));
    try std.testing.expect(@hasDecl(@This(), "auth_store"));
    try std.testing.expect(@hasDecl(@This(), "context"));
    try std.testing.expect(@hasDecl(@This(), "tools"));
    try std.testing.expect(@hasDecl(@This(), "plugins"));
}
