const std = @import("std");

/// get timestamp since epoch in seconds, with nanosecond precision
pub fn now() f64 {
    return @as(f64, @floatFromInt(std.time.nanoTimestamp())) * 1e-9;
}
