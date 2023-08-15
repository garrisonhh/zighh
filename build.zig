const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule(.{
        .name = "common",
        .root_source_file = .{ .path = "src/lib.zig" },
    });
}
