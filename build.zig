const std = @import("std");

pub fn build(b: *std.Build) void {
    const wcwidth = b.dependency("zig-wcwidth", .{}).module("wcwidth");

    _ = b.addModule("common", .{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &.{
            .{ .name = "wcwidth", .module = wcwidth },
        },
    });
}
