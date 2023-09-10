const std = @import("std");

/// allows for parser to peek some number of tokens
pub fn BoundedRingBuffer(
    comptime T: type,
    comptime buffer_size: comptime_int,
) type {
    return struct {
        const Self = @This();

        pub const cache_len = buffer_size;
        pub const Index = std.math.IntFittingRange(0, cache_len);

        buf: [cache_len]T = undefined,
        start: Index = 0,
        len: Index = 0,

        pub fn get(self: Self, n: usize) T {
            return self.buf[n];
        }

        /// add an item to the queue
        pub fn push(self: *Self, value: T) void {
            std.debug.assert(self.len < cache_len);

            const buf_index = (self.start + self.len) % cache_len;
            self.buf[buf_index] = value;
            self.len += 1;
        }

        /// consume a buffered token
        pub fn advance(self: *Self) void {
            std.debug.assert(self.len > 0);

            self.start = (self.start + 1) % cache_len;
            self.len -= 1;
        }
    };
}