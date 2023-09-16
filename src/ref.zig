const std = @import("std");
const Allocator = std.mem.Allocator;

/// create a unique handle type
pub fn Ref(
    comptime unique_tag: @TypeOf(.enum_literal),
    comptime backing_bits: comptime_int,
) type {
    const BackingInt = std.meta.Int(.unsigned, backing_bits);

    return packed struct(BackingInt) {
        const Self = @This();

        pub const tag = unique_tag;
        pub const Int = BackingInt;

        index: Int,

        fn init(n: Int) Self {
            return Self{ .index = n };
        }

        /// check two refs for id equality
        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index;
        }

        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            if (comptime std.mem.eql(u8, fmt, "")) {
                const fmt_str = comptime s: {
                    const hex_digits =
                        @divFloor(backing_bits, 4) +
                        @as(comptime_int, @intFromBool(backing_bits % 4 > 0));

                    break :s std.fmt.comptimePrint(
                        "<{{s}}@{{x:0{d}}}>",
                        .{hex_digits},
                    );
                };

                try writer.print(fmt_str, .{ @tagName(tag), self.index });
            } else {
                try writer.print("{s}{d}", .{ fmt, self.index });
            }
        }
    };
}

/// a simpler version of RefMap, which just wraps an arraylist and implements
/// a similar interface to RefMap.
///
/// useful for applications where you just need type safety for handles to a
/// bunch of items you're creating in one shot.
pub fn RefList(comptime R: type, comptime T: type) type {
    return struct {
        const Self = @This();

        items: std.ArrayListUnmanaged(T) = .{},

        /// release all memory
        pub fn deinit(self: *Self, ally: Allocator) void {
            self.items.deinit(ally);
        }

        pub fn put(self: *Self, ally: Allocator, item: T) Allocator.Error!R {
            const ref = Ref.init(self.items.items.len);
            try self.items.append(ally, item);
            return ref;
        }

        pub fn get(self: *const Self, ref: Ref) *T {
            return &self.items.items[ref.index];
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .list = self };
        }

        pub const Iterator = struct {
            list: *const Self,
            index: R.Int = 0,

            pub fn next(iter: *Iterator) ?*T {
                if (iter.index >= iter.list.items.len) {
                    return null;
                }

                defer iter.index += 1;
                return iter.list.items.items[iter.index];
            }

            pub const Entry = struct {
                ref: R,
                ptr: *T,
            };

            pub fn nextEntry(iter: *Iterator) ?Entry {
                const ref = Ref.init(iter.index);
                if (iter.next()) |ptr| {
                    return Entry{
                        .ref = ref,
                        .ptr = ptr,
                    };
                }

                return null;
            }
        };
    };
}

/// a non-moving persistent handle table implementation. create with a Ref.
pub fn RefMap(comptime R: type, comptime T: type) type {
    return struct {
        const PAGE_SIZE = 1024;

        const Self = @This();

        const Page = struct {
            mem: [PAGE_SIZE]T = undefined,
            cap: usize = 0,

            fn alloc(self: *Page) Allocator.Error!*T {
                if (self.cap >= PAGE_SIZE) {
                    return Allocator.Error.OutOfMemory;
                }

                defer self.cap += 1;
                return &self.mem[self.cap];
            }
        };

        const PageList = std.SinglyLinkedList(Page);

        /// memory pool for items
        pages: PageList = .{},
        /// maps ref -> item
        items: std.ArrayListUnmanaged(?*T) = .{},
        /// stores deleted refs ready for reuse
        unused: std.ArrayListUnmanaged(R) = .{},

        /// release all memory
        pub fn deinit(self: *Self, ally: Allocator) void {
            // deinit pages
            while (self.pages.popFirst()) |node| {
                ally.destroy(node);
            }

            self.unused.deinit(ally);
            self.items.deinit(ally);
        }

        /// allocate a new T in the memory pool
        fn alloc(self: *Self, ally: Allocator) Allocator.Error!*T {
            // use current page
            const head = self.pages.first;
            if (head) |node| {
                if (node.data.alloc()) |ptr| return ptr else |_| {}
            }

            // make a new page
            const node = try ally.create(PageList.Node);
            node.data = .{};

            self.pages.prepend(node);

            return node.data.alloc() catch unreachable;
        }

        /// creates an unbound ref and ensures that its slot exists
        pub fn new(self: *Self, ally: Allocator) Allocator.Error!R {
            // reuse an old ref if possible
            if (self.unused.popOrNull()) |ref| {
                return ref;
            }

            // create a new ref
            const ref = R.init(@intCast(self.items.items.len));
            try self.items.append(ally, null);

            // ensure that if all refs were freed at once, the unused arraylist
            // could store them
            try self.unused.ensureTotalCapacity(ally, self.items.items.len);

            return ref;
        }

        /// initialize a slot
        pub fn set(
            self: *Self,
            ally: Allocator,
            ref: R,
            item: T,
        ) Allocator.Error!void {
            const slot = try self.alloc(ally);
            slot.* = item;
            self.items.items[ref.index] = slot;
        }

        /// create a new id and initialize a slot
        pub fn put(self: *Self, ally: Allocator, item: T) Allocator.Error!R {
            const ref = try self.new(ally);
            try self.set(ally, ref, item);
            return ref;
        }

        /// free up an id for reusage
        pub fn del(self: *Self, ref: R) void {
            // if this fails, double delete has occurred
            std.debug.assert(self.items.items[ref.index] != null);
            // cap ensured by new() behavior
            self.unused.appendAssumeCapacity(ref);
            self.items.items[ref.index] = null;
        }

        /// retrieve a ref safely
        pub fn getOpt(self: Self, ref: R) ?*T {
            // should never go out of bounds assuming refs are only being
            // created through new()
            return self.items.items[ref.index];
        }

        /// retrieve a ref when it must exist
        pub fn get(self: Self, ref: R) *T {
            return self.getOpt(ref).?;
        }

        /// the number of refs in use
        pub fn count(self: Self) usize {
            return self.items.items.len - self.unused.items.len;
        }

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .map = self };
        }

        pub const Iterator = struct {
            map: *const Self,
            index: R.Int = 0,

            pub fn next(iter: *Iterator) ?*T {
                const items = iter.map.items.items;
                if (iter.index >= items.len) return null;

                // seek next item
                while (iter.index < items.len) {
                    if (items[iter.index] != null) break;
                    iter.index += 1;
                } else {
                    // no items remaininmg
                    return null;
                }

                // return item and iterate
                defer iter.index += 1;
                return items[iter.index];
            }

            pub const Entry = struct {
                ref: R,
                ptr: *T,
            };

            pub fn nextEntry(iter: *Iterator) ?Entry {
                const items = iter.map.items.items;
                if (iter.index >= items.len) return null;

                // seek next item
                while (iter.index < items.len) {
                    if (items[iter.index] != null) break;
                    iter.index += 1;
                } else {
                    // no items remaininmg
                    return null;
                }

                // return item and iterate
                defer iter.index += 1;
                return Entry{
                    .ref = R{ .index = iter.index },
                    .ptr = items[iter.index].?,
                };
            }
        };
    };
}
