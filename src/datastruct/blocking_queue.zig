const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();
        pub const Size = u32;
        const bounds: Size = @intCast(capacity);

        pub const Timeout = union(enum) {
            instant: void,
            forever: void,
            ns: u64,
        };

        data: [bounds]T = undefined,
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,
        mutex: std.Thread.Mutex = .{},
        cond_not_full: std.Thread.Condition = .{},
        not_full_waiters: Size = 0,

        pub fn create(alloc: Allocator) !*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);
            ptr.* = .{};
            return ptr;
        }

        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        pub fn push(self: *Self, value: T, timeout: Timeout) Size {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.full()) {
                switch (timeout) {
                    .instant => return 0,
                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.wait(&self.mutex);
                    },
                    .ns => |ns| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.timedWait(&self.mutex, ns) catch return 0;
                    }
                }
                if (self.full()) return 0;
            }

            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.len == 0) return null;

            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            if (self.not_full_waiters > 0) self.cond_not_full.signal();

            return self.data[n];
        }

        inline fn full(self: Self) bool {
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    try testing.expect(q.pop() == null);

    try testing.expectEqual(@as(Q.Size, 1), q.push(1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(5, .{ .instant = {} }));
    
    try testing.expect(q.pop().? == 1);
    try testing.expect(q.pop().? == 2);
    try testing.expect(q.pop().? == 3);
    try testing.expect(q.pop().? == 4);
    try testing.expect(q.pop() == null);
}
