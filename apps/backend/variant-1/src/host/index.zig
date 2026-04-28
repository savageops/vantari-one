const std = @import("std");

pub const http_bridge = @import("http_bridge.zig");
pub const stdio_rpc = @import("stdio_rpc.zig");

test "host namespace exposes transport adapters" {
    try std.testing.expect(@hasDecl(@This(), "http_bridge"));
    try std.testing.expect(@hasDecl(@This(), "stdio_rpc"));
}
