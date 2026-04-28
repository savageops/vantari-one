const std = @import("std");
const VAR1 = @import("VAR1");

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    VAR1.clients.cli.main(std.heap.page_allocator, &args) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(2),
        else => return err,
    };
}
