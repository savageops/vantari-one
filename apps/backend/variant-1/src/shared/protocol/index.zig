const std = @import("std");

pub const types = @import("types.zig");

test "protocol namespace exposes wire types" {
    try std.testing.expect(@hasDecl(@This(), "types"));
}
