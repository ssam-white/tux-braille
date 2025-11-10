const std = @import("std");
const tmux = @import("main.zig");

const log = std.log.scoped(.tmux_stream);
const Allocator = std.mem.Allocator;

pub fn Stream(comptime Handler: type) type {
    return struct {
        const Self = @This();
        
        handler: Handler,
        tmux_client: tmux.Client,

        pub fn init(alloc: Allocator, handler: Handler) Self {
            return .{
                .handler = handler,
                .tmux_client = .{ .buffer = .init(alloc) },
            };
        }

        pub fn deinit(self: *Self) void {
            self.tmux_client.deinit();
        }

        pub fn next(self: *Self, byte: u8) !void {
            if (try self.tmux_client.put(byte)) |notification| {
                self.handler.handleNotification(notification) catch {};
            }
        }
    };
}
