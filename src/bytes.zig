//! bit twiddling shit. mostly wrapping around zig's fantastic std.mem stuff,
//! but standardizing my own api is helpful for thinking about stuff

const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const std = @import("std");

/// extrude an int into an array
pub fn bytesFromInt(comptime T: type, value: T) [@sizeOf(T)]u8 {
    var arr: [@sizeOf(T)]u8 = undefined;
    std.mem.writeIntSliceNative(T, &arr, value);
    return arr;
}

/// get an int from bytes. width must fit inside the int
pub fn intFromBytes(comptime T: type, bytes: []const u8) T {
    const width = @sizeOf(T);
    std.debug.assert(bytes.len <= width);

    var arr: [width]u8 align(width) = undefined;
    @memset(&arr, 0);

    if (native_endian == .Big) {
        @memcpy(arr[width - bytes.len ..], bytes);
    } else if (native_endian == .Little) {
        @memcpy(arr[0..bytes.len], bytes);
    }

    return @as(*const T, @ptrCast(&arr)).*;
}

test "int-bytes-conversion" {
    const types = [_]type{
        u8,
        u16,
        u32,
        u64,
        i8,
        i16,
        i32,
        i64,
        usize,
        isize,
    };

    inline for (types) |T| {
        const cases = [_]T{
            0,
            20,
            std.math.minInt(T),
            std.math.maxInt(T),
        } ++ if (@typeInfo(T).Int.signedness == .signed) .{-20} else .{};

        for (cases) |n| {
            const bytes = bytesFromInt(T, n);
            const back = intFromBytes(T, &bytes);
            try std.testing.expectEqual(n, back);
        }
    }
}
test "uint-bytes-wider-conversion" {
    const types = [_]type{
        u8,
        u16,
        u32,
        u64,
        usize,
    };

    inline for (types) |T| {
        const cases = [_]T{
            0,
            20,
            std.math.maxInt(T),
        };

        for (cases) |n| {
            const bytes = bytesFromInt(usize, n);
            const back = intFromBytes(usize, &bytes);
            try std.testing.expectEqual(@as(usize, n), back);
        }
    }
}
