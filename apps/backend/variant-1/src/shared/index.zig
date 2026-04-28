const std = @import("std");

pub const fsutil = @import("fsutil.zig");
pub const protocol = @import("protocol/index.zig");
pub const types = @import("types.zig");

test "shared namespace exposes config and types" {
    try std.testing.expect(@hasDecl(@This(), "fsutil"));
    try std.testing.expect(@hasDecl(@This(), "protocol"));
    try std.testing.expect(@hasDecl(@This(), "types"));
}
