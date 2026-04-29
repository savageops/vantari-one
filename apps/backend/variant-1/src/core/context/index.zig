const std = @import("std");

pub const builder = @import("builder.zig");
pub const budget = @import("budget.zig");
pub const compactor = @import("compactor.zig");
pub const overflow = @import("overflow.zig");

pub const appendProviderMessages = builder.appendProviderMessages;
pub const compactSession = compactor.compactSession;

test "context namespace exposes builder" {
    try std.testing.expect(@hasDecl(@This(), "builder"));
    try std.testing.expect(@hasDecl(@This(), "budget"));
    try std.testing.expect(@hasDecl(@This(), "compactor"));
    try std.testing.expect(@hasDecl(@This(), "overflow"));
}
