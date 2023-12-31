const std = @import("std");
const unicode = std.unicode;
const in_debug = @import("builtin").mode == .Debug;
const wcwidth = @import("wcwidth");

pub const Block = @import("utf8_blocks.zig").Utf8Block;

const CodepointInt = u21;

pub const Codepoint = packed struct(CodepointInt) {
    const Self = @This();

    pub const ParseError = error{InvalidUtf8};

    c: CodepointInt,

    pub fn ct(comptime str: []const u8) Self {
        return Self{ .c = comptime try unicode.utf8Decode(str) };
    }

    fn ctSliceLen(comptime str: []const u8) comptime_int {
        comptime {
            return try std.unicode.utf8CountCodepoints(str);
        }
    }

    pub fn ctString(comptime str: []const u8) [ctSliceLen(str)]Self {
        comptime {
            var buf: [ctSliceLen(str)]Self = undefined;
            var i = 0;

            var iter = parse(str);
            while (try iter.next()) |c| {
                buf[i] = c;
                i += 1;
            }

            return buf;
        }
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.c == other.c;
    }

    /// c <: "\0 \t\r\n"
    pub fn isSpace(self: Self) bool {
        return switch (self.c) {
            0, ' ', '\t', '\r', '\n' => true,
            else => false,
        };
    }

    /// works for bases up to 36
    pub fn isDigit(self: Self, comptime base: comptime_int) bool {
        return switch (base) {
            2...10 => switch (self.c) {
                '0'...'0' + base - 1 => true,
                else => false,
            },
            11...36 => switch (self.c) {
                '0'...'9',
                'a'...'a' + base - 11,
                'A'...'A' + base - 11,
                => true,
                else => false,
            },
            else => @compileError("bases 2-36 are allowed."),
        };
    }

    /// matches regex /[a-zA-Z]/
    pub fn isAlpha(self: Self) bool {
        return switch (self.c) {
            'a'...'z', 'A'...'Z' => true,
            else => false,
        };
    }

    pub fn getUnicodeBlock(self: Self) Block {
        return Block.categorize(self) catch {
            // there shouldn't be any way to acquire a codepoint that results
            // in invalid utf8
            unreachable;
        };
    }

    /// how many bytes it takes to store this character as a sequence
    pub fn byteLength(self: Self) u3 {
        return std.unicode.utf8CodepointSequenceLength(self.c) catch {
            unreachable;
        };
    }

    /// write this codepoint to a buffer.
    pub fn toBytes(self: Self, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= self.byteLength());
        const len = std.unicode.utf8Encode(self.c, buf) catch unreachable;
        return buf[0..len];
    }

    /// use this to parse bytes into unicode
    pub fn parse(text: []const u8) Iterator {
        return Iterator.init(text);
    }

    /// iterator for unicode codepoints. I could also use std.unicode.Utf8View
    /// but it would require wrapping in another struct anyways
    pub const Iterator = struct {
        /// bytes being parsed
        text: []const u8,
        /// index of current tracked byte
        byte_index: usize = 0,
        /// index of current byte relative to previous codepoints
        cp_index: usize = 0,

        fn init(text: []const u8) Iterator {
            return .{ .text = text };
        }

        /// number of bytes for the first `cp_count` codepoints in the string
        fn codepointBytes(text: []const u8, cp_count: usize) ParseError!usize {
            var nbytes: usize = 0;
            for (0..cp_count) |_| {
                const cp_bytes =
                    unicode.utf8ByteSequenceLength(text[nbytes]) catch {
                    return ParseError.InvalidUtf8;
                };

                nbytes += cp_bytes;
            }

            return nbytes;
        }

        /// peek at the next codepoint
        pub fn peek(iter: *Iterator) ParseError!?Codepoint {
            var buf: [1]Codepoint = undefined;
            const slice = try iter.peekSlice(&buf, 1);
            return if (slice.len > 0) slice[0] else null;
        }

        /// peek a slice of codepoints
        pub fn peekSlice(
            iter: *Iterator,
            buf: []Codepoint,
            len: usize,
        ) ParseError![]const Codepoint {
            var byte_index = iter.byte_index;

            for (0..len) |i| {
                if (byte_index == iter.text.len) return buf[0..i];

                const remaining = iter.text[byte_index..];
                const cp_bytes = try codepointBytes(remaining, 1);
                const cp_slice = remaining[0..cp_bytes];

                buf[i].c = unicode.utf8Decode(cp_slice) catch {
                    return ParseError.InvalidUtf8;
                };

                byte_index += cp_bytes;
            }

            return buf[0..len];
        }

        /// iterate past a codepoint parsed by peek()
        pub fn accept(iter: *Iterator, c: Codepoint) void {
            if (in_debug) {
                const pk = iter.peek() catch {
                    @panic("bad accepted codepoint; found invalid utf8");
                } orelse {
                    @panic("bad accepted codepoint; found empty iterator");
                };

                std.debug.assert(pk.eql(c));
            }

            iter.byte_index += c.byteLength();
            iter.cp_index += 1;
        }

        /// iterate past codepoints parsed by peekSlice()
        pub fn acceptSlice(iter: *Iterator, slice: []const Codepoint) void {
            for (slice) |c| iter.accept(c);
        }

        /// parse the next codepoint and accept it
        pub fn next(iter: *Iterator) ParseError!?Codepoint {
            if (try iter.peek()) |c| {
                iter.accept(c);
                return c;
            }

            return null;
        }
    };

    /// formatting options:
    /// {d} - format as number
    /// {}  - format as codepoint
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        if (comptime std.mem.eql(u8, fmt, "d")) {
            try std.fmt.formatIntValue(self.c, fmt, options, writer);
        } else if (comptime std.mem.eql(u8, fmt, "")) {
            try std.fmt.formatUnicodeCodepoint(self.c, options, writer);
        } else {
            @compileError(std.fmt.comptimePrint(
                "invalid codepoint format `{{{s}}}``",
                .{fmt},
            ));
        }
    }

    /// how wide this codepoint is in terms of terminal cells
    pub fn printedWidth(self: Self) u2 {
        return wcwidth.wcWidth(self.c);
    }
};
