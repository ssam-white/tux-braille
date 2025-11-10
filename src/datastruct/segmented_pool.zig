const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

pub fn SegmentedPool(comptime T: type, comptime prealloc: usize) type {
    return struct {
        const Self = @This();

        i: usize = 0,
        available: usize = prealloc,
        list: std.SegmentedList(T, prealloc) = .{ .len = prealloc },

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.list.deinit(alloc);
            self.* = undefined;
        }

        pub fn get(self: *Self) !*T {
            if (self.available == 0) return error.OutOfValues;

            const i = @mod(self.i, self.list.len);
            self.i +%= 1;
            self.available -= 1;
            return self.list.at(i);
        }

        pub fn getGrow(self: *Self, alloc: Allocator) !*T {
            if (self.available == 0) try self.grow(alloc);
            return self.get();
        }

        fn grow(self: *Self, alloc: Allocator) !void {
            try self.list.growCapacity(alloc, self.list.len * 2);
            self.i = self.list.len;
            self.available = self.list.len;
            self.list.len *= 2;
        }

        pub fn put(self: *Self) void {
            self.available += 1;
            assert(self.available <= self.list.len);
        }
    };
}

test "SegmentedPool" {
    var list: SegmentedPool(u8, 2) = .{};
    defer list.deinit(testing.allocator);
    try testing.expectEqual(2, list.available);

    const v1 = try list.get();
    const v2 = try list.get();
    try testing.expect(v1 != v2);
    try testing.expectError(error.OutOfValues, list.get());

    // test writing for later
    v1.* = 42;

    list.put();
    const temp = try list.get();
    try testing.expect(v1 == temp);
    try testing.expectEqual(temp.*, 42);
    try testing.expectError(error.OutOfValues, list.get());

    const v3 = try list.getGrow(testing.allocator);
    try testing.expect(v1 != v3 and v2 != v3);
    _ = try list.get();
    try testing.expectError(error.OutOfValues, list.get());

    list.put();
    try testing.expect(v1 == try list.get());
    try testing.expectError(error.OutOfValues, list.get());
}
