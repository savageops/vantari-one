const std = @import("std");

pub const shared = @import("shared/index.zig");
pub const core = @import("core/index.zig");
pub const host = @import("host/index.zig");
pub const clients = @import("clients/index.zig");

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
