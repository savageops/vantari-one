const std = @import("std");

pub const manifest = @import("manifest.zig");

pub const PluginManifest = manifest.PluginManifest;
pub const PluginSocket = manifest.PluginSocket;
pub const PluginSocketKind = manifest.PluginSocketKind;
pub const validateManifest = manifest.validateManifest;

test "plugins namespace exposes manifest socket contracts" {
    try std.testing.expect(@hasDecl(@This(), "manifest"));
    try std.testing.expect(@hasDecl(@This(), "validateManifest"));
}
