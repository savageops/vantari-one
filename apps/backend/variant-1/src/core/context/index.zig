const std = @import("std");

pub const builder = @import("builder.zig");

pub const appendProviderMessages = builder.appendProviderMessages;

test "context namespace exposes builder" {
    try std.testing.expect(@hasDecl(@This(), "builder"));
}
