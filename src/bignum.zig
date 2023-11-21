//! a big number implementation designed for parsing focused on being simple and
//! readable, but is probably incredibly slow.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

pub const Sign = enum {
    negative,
    positive,

    fn from(positive: bool) Sign {
        return if (positive) .positive else .negative;
    }

    fn char(sign: Sign) u8 {
        return switch (sign) {
            .negative => '-',
            .positive => '+',
        };
    }
};

/// allows safe access to float components
pub fn FloatBits(comptime F: type) type {
    return packed struct(std.meta.Int(.unsigned, @bitSizeOf(F))) {
        pub const exponent_bits = std.math.floatExponentBits(F);
        pub const mantissa_bits = std.math.floatFractionalBits(F);

        pub const BiasExponent = std.meta.Int(.signed, exponent_bits + 1);
        pub const bias: BiasExponent = (1 << exponent_bits - 1) - 1;

        pub const Mantissa = std.meta.Int(.unsigned, mantissa_bits);
        pub const Exponent = std.meta.Int(.unsigned, exponent_bits);

        mantissa: Mantissa,
        _: if (F == f80) u1 else u0 = if (F == f80) 1 else undefined,
        exponent: Exponent,
        sign: u1,

        pub fn biasedExponent(self: @This()) BiasExponent {
            const WiderExponent = std.meta.Int(.signed, exponent_bits + 2);
            const e: WiderExponent = @intCast(self.exponent);
            const b: WiderExponent = @intCast(bias);

            return @intCast(e - b);
        }

        /// debug print to stderr
        pub fn format(
            self: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            try writer.print("{b} ", .{self.sign});
            try std.fmt.formatInt(
                self.exponent,
                2,
                .upper,
                .{
                    .width = exponent_bits,
                    .fill = '0',
                },
                writer,
            );
            try writer.writeByte(' ');
            try std.fmt.formatInt(
                self.mantissa,
                2,
                .upper,
                .{
                    .width = mantissa_bits,
                    .fill = '0',
                },
                writer,
            );
        }
    };
}

pub fn floatBits(comptime F: type, n: F) FloatBits(F) {
    return @bitCast(n);
}

sign: Sign = .positive,
bytes: []u8,
/// byte index of dot
dot: usize = 0,

/// for internal use
fn initZeroed(ally: Allocator, nbytes: usize) Allocator.Error!Self {
    const bytes = try ally.alloc(u8, nbytes);
    @memset(bytes, 0);

    return Self{ .bytes = bytes };
}

pub fn deinit(self: Self, ally: Allocator) void {
    ally.free(self.bytes);
}

/// create a number zero
pub fn zero(ally: Allocator) Allocator.Error!Self {
    return try initZeroed(ally, 0);
}

pub fn clone(self: Self, ally: Allocator) Allocator.Error!Self {
    return Self{
        .sign = self.sign,
        .bytes = try ally.dupe(u8, self.bytes),
        .dot = self.dot,
    };
}

/// create a bignum from a machine number type
pub fn from(ally: Allocator, comptime T: type, n: T) Allocator.Error!Self {
    return switch (@typeInfo(T)) {
        .Int => self: {
            var self = try initZeroed(ally, @sizeOf(T));
            self.sign = Sign.from(n >= 0);

            var u = std.math.absCast(n);
            var i: usize = self.dot;
            while (u > 0) {
                self.bytes[i] = @truncate(u);
                u >>= 8;
                i += 1;
            }

            break :self self;
        },
        .Float => self: {
            const f = floatBits(T, n);

            const hi_bit: isize = @intCast(f.biasedExponent());
            const mantissa_req_bits =
                @TypeOf(f).mantissa_bits - @ctz(f.mantissa);
            const lo_bit = hi_bit - mantissa_req_bits;

            var self = try zero(ally);
            self.sign = Sign.from(f.sign == 0);

            try self.ensureBit(ally, hi_bit);
            try self.ensureBit(ally, lo_bit);

            self.writeBitAssumeExists(hi_bit, 1);

            if (f.mantissa != 0) {
                var bits = f.mantissa >> @ctz(f.mantissa);
                var i = lo_bit;
                while (i < hi_bit) : ({
                    bits >>= 1;
                    i += 1;
                }) {
                    self.writeBitAssumeExists(i, @intCast(bits & 1));
                }
            }

            break :self self;
        },
        else => @compileError("can't create a bignum from " ++ @typeName(T)),
    };
}

pub const IntoError = error { Unrepresentable };

/// helpful for determining representability
fn ensureBitRangeZeroed(self: Self, start: isize, stop: isize) IntoError!void {
    var i = start;
    while (i < stop) : (i += 1) {
        if (self.getBit(i) != 0) {
            return IntoError.Unrepresentable;
        }
    }
}

/// cast a bignum into a machine number type
pub fn into(self: Self, comptime T: type) IntoError!T {
    return switch (@typeInfo(T)) {
        .Int => |meta| switch (meta.signedness) {
            .unsigned => uint: {
                if (self.sign == .negative) {
                    return IntoError.Unrepresentable;
                }

                const max_bit: isize =
                    @intCast((self.bytes.len - self.dot) * 8);
                const start: isize = @intCast(self.dot * 8);
                const stop: isize = @min(start + @bitSizeOf(T), max_bit);

                try self.ensureBitRangeZeroed(0, start);
                try self.ensureBitRangeZeroed(stop, max_bit);

                var i = stop - 1;
                var n: T = 0;
                while (i >= start) : (i -= 1) {
                    n = (n << 1) | self.getBit(i);
                }

                break :uint n;
            },
            .signed => sint: {
                const max_bit: isize =
                    @intCast((self.bytes.len - self.dot) * 8);
                const start: isize = @intCast(self.dot * 8);
                const stop: isize = @min(start + @bitSizeOf(T), max_bit);

                try self.ensureBitRangeZeroed(0, start);
                try self.ensureBitRangeZeroed(stop, max_bit);

                var n: T = 0;
                switch (self.sign) {
                    .positive => {
                        var i = stop - 1;
                        while (i >= start) : (i -= 1) {
                            n = (n << 1) | self.getBit(i);
                        }
                    },
                    .negative => {
                        var i = stop - 1;
                        while (i >= start) : (i -= 1) {
                            n = (n << 1) - self.getBit(i);
                        }
                    },
                }

                break :sint n;
            },
        },
        .Float => float: {
            const Bits = FloatBits(T);

            const max_bit: isize = @intCast((self.bytes.len - self.dot) * 8);
            const min_bit = 8 * -@as(isize, @intCast(self.dot));

            var first_bit: isize = max_bit - 1;
            while (first_bit > min_bit) {
                if (self.getBit(first_bit) != 0) break;
                first_bit -= 1;
            } else {
                // value is zero
                break :float 0;
            }

            const mantissa_stop = first_bit - Bits.mantissa_bits - 1;

            try self.ensureBitRangeZeroed(min_bit, mantissa_stop);
            try self.ensureBitRangeZeroed(first_bit + 1, max_bit);

            const exponent = std.math.cast(
                Bits.Exponent,
                @as(isize, @intCast(Bits.bias)) + first_bit,
            ) orelse {
                return IntoError.Unrepresentable;
            };

            var mantissa: Bits.Mantissa = 0;
            for (0..Bits.mantissa_bits) |i| {
                const bit_index = first_bit - @as(isize, @intCast(i)) - 1;
                const bit: Bits.Mantissa = self.getBit(bit_index);

                mantissa |= bit << @intCast(Bits.mantissa_bits - i - 1);
            }

            const bits = Bits{
                .sign = switch (self.sign) {
                    .positive => 0,
                    .negative => 1,
                },
                .exponent = exponent,
                .mantissa = mantissa,
            };

            break :float @bitCast(bits);
        },
        else => @compileError("can't convert a bignum into " ++ @typeName(T)),
    };
}

fn ensureByte(self: *Self, ally: Allocator, index: isize) Allocator.Error!void {
    if (index < 0) {
        // expand to the left?
        const req: usize = @intCast(-index);
        if (req <= self.dot) return;

        const offset = req - self.dot;
        const new_nbytes = self.bytes.len + offset;
        const next = try ally.alloc(u8, new_nbytes);

        @memcpy(next[offset..], self.bytes);
        @memset(next[0..offset], 0);

        ally.free(self.bytes);
        self.dot = req;
        self.bytes = next;
    } else {
        // expand to the right?
        const req = @as(usize, @intCast(index)) + self.dot + 1;
        const cur = self.bytes.len;
        if (req <= cur) return;

        self.bytes = try ally.realloc(self.bytes, req);
        @memset(self.bytes[cur..], 0);
    }
}

/// ensure a bit is accessible
pub fn ensureBit(
    self: *Self,
    ally: Allocator,
    index: isize,
) Allocator.Error!void {
    try self.ensureByte(ally, @divFloor(index, 8));
}

fn getBytePtr(self: Self, index: isize) ?*u8 {
    const offset: isize = @intCast(self.dot);
    const array_index = index + offset;

    if (array_index < 0 or array_index >= self.bytes.len) {
        return null;
    }

    return &self.bytes[@intCast(array_index)];
}

/// retrieve the value of bit by index
fn getBit(self: Self, index: isize) u1 {
    const byte_index = @divFloor(index, 8);
    const bit_index: u3 = @intCast(@mod(index, 8));
    const byte = self.getBytePtr(byte_index) orelse {
        return 0;
    };
    return @intCast((byte.* >> bit_index) & 1);
}

/// write to a bit
pub fn writeBitAssumeExists(self: *Self, index: isize, bit: u1) void {
    const byte_index = @divFloor(index, 8);
    const bit_index: u3 = @intCast(@mod(index, 8));
    const byte = self.getBytePtr(byte_index).?;

    switch (bit) {
        0 => {
            byte.* &= ~(@as(u8, bit) << bit_index);
        },
        1 => {
            byte.* |= @as(u8, bit) << bit_index;
        },
    }
}

/// write to a bit, allocating if needed
pub fn writeBit(
    self: *Self,
    ally: Allocator,
    index: isize,
    bit: u1,
) Allocator.Error!void {
    try self.ensureBit(ally, index);
    self.writeBitAssumeExists(index, bit);
}

pub fn format(
    self: Self,
    comptime fmt: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) @TypeOf(writer).Error!void {
    if (std.mem.eql(u8, fmt, "debug")) {
        try writer.print("{c}", .{self.sign.char()});

        var bytes = std.mem.reverseIterator(self.bytes);
        var i: usize = self.bytes.len;

        if (i == self.dot) {
            try writer.writeAll("0.");
        }

        while (bytes.next()) |x| {
            i -= 1;

            try writer.print("{b:0>8}", .{x});

            if (i == self.dot) {
                try writer.writeByte('.');
            } else if (i > 0) {
                try writer.writeByte('_');
            }
        }
    } else {
        @panic("TODO format bignum in decimal");
    }
}

// tests =======================================================================

test {
    const ally = std.testing.allocator;

    const NumTest = union(enum) {
        int: struct {
            type: type,
            value: comptime_int,
        },
        float: struct {
            type: type,
            value: comptime_float,
        },
    };

    const case = struct {
        fn f(comptime T: type, comptime v: anytype) NumTest {
            return comptime switch (@typeInfo(T)) {
                .Int => .{ .int = .{ .type = T, .value = v } },
                .Float => .{ .float = .{ .type = T, .value = v } },
                else => @compileError("invalid type"),
            };
        }
    }.f;

    const nums = comptime [_]NumTest{
        case(i16, std.math.maxInt(i16)),
        case(i16, std.math.minInt(i16)),
        case(i64, std.math.maxInt(i64)),
        case(i64, std.math.minInt(i64)),
        case(f16, 5),
        case(f32, 5),
        case(f64, 5),
        case(f64, std.math.floatMin(f64)),
        case(f64, -std.math.floatMin(f64)),
        case(f64, std.math.floatMax(f64)),
        case(f64, -std.math.floatMax(f64)),
        case(f64, -27.625),
    };

    inline for (nums) |num_test| {
        switch (num_test) {
            .int => |int| {
                const num = try Self.from(ally, int.type, int.value);
                defer num.deinit(ally);

                try std.testing.expectEqual(
                    @as(int.type, int.value),
                    try num.into(int.type),
                );
            },
            .float => |float| {
                const num = try Self.from(ally, float.type, float.value);
                defer num.deinit(ally);

                try std.testing.expectEqual(
                    @as(float.type, float.value),
                    try num.into(float.type),
                );
            },
        }
    }
}
