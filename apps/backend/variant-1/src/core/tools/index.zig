const std = @import("std");

pub const runtime = @import("runtime.zig");
pub const module = @import("module.zig");
pub const registry = @import("registry.zig");
pub const workspace_runtime = @import("workspace_runtime.zig");
pub const sockets = @import("sockets.zig");

pub const ExecutionContext = runtime.ExecutionContext;
pub const CommandProbe = module.CommandProbe;
pub const ToolSocket = sockets.ToolSocket;
pub const ToolSource = sockets.ToolSource;

pub const builtinDefinitions = runtime.builtinDefinitions;
pub const builtinDefinitionsForContext = runtime.builtinDefinitionsForContext;
pub const buildAgentSystemPrompt = runtime.buildAgentSystemPrompt;
pub const renderCatalog = runtime.renderCatalog;
pub const renderCatalogJson = runtime.renderCatalogJson;
pub const validateDefinition = sockets.validateDefinition;

test "tools namespace exposes runtime and socket contracts" {
    try std.testing.expect(@hasDecl(@This(), "runtime"));
    try std.testing.expect(@hasDecl(@This(), "module"));
    try std.testing.expect(@hasDecl(@This(), "registry"));
    try std.testing.expect(@hasDecl(@This(), "workspace_runtime"));
    try std.testing.expect(@hasDecl(@This(), "sockets"));
    try std.testing.expect(@hasDecl(@This(), "validateDefinition"));
}
