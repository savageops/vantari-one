const std = @import("std");

pub const agent_runtime = @import("../agents.zig");
pub const auth_resolver = @import("../auth_resolver.zig");
pub const auth_store = @import("../auth_store.zig");
pub const context = @import("context/index.zig");
pub const executor = @import("../loop.zig");
pub const harness_runtime = @import("../harness_tools.zig");
pub const plugins = @import("plugins/index.zig");
pub const protocol_types = @import("../protocol_types.zig");
pub const provider_runtime = @import("../provider.zig");
pub const session_store = @import("../store.zig");
pub const tools = @import("tools/index.zig");
pub const tool_runtime = tools.runtime;

test "core namespace exposes executor and store" {
    try std.testing.expect(@hasDecl(@This(), "executor"));
    try std.testing.expect(@hasDecl(@This(), "session_store"));
    try std.testing.expect(@hasDecl(@This(), "auth_store"));
    try std.testing.expect(@hasDecl(@This(), "context"));
    try std.testing.expect(@hasDecl(@This(), "tools"));
    try std.testing.expect(@hasDecl(@This(), "plugins"));
}
