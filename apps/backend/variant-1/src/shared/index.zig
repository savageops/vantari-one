const std = @import("std");

pub const config = @import("../config.zig");
pub const fsutil = @import("../fsutil.zig");
pub const types = @import("../types.zig");

test "shared namespace exposes config and types" {
    try std.testing.expect(@hasDecl(@This(), "config"));
    try std.testing.expect(@hasDecl(@This(), "types"));
}
