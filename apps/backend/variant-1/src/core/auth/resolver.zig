const std = @import("std");
const auth_store = @import("store.zig");

pub const AuthBootstrap = auth_store.AuthBootstrap;
pub const ResolvedAuth = auth_store.ResolvedAuth;

pub fn resolveProviderAuth(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    bootstrap: ?AuthBootstrap,
) !ResolvedAuth {
    return auth_store.resolveOrSeed(allocator, workspace_root, bootstrap);
}
