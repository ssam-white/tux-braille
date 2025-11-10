const std = @import("std");
const App = @import ("../App.zig");
const tmux = @import("../tmux/main.zig");

const log = std.log.scoped(.stream_handler);

pub const StreamHandler = struct {
    app_mailbox: App.Mailbox,
    
    pub fn init(app_mailbox: App.Mailbox) StreamHandler {
        return .{
            .app_mailbox = app_mailbox,
        };
    }

    pub fn deinit(self: *StreamHandler) void {
        _ = self;
    }

    fn sendMessage(self: StreamHandler, message: App.Message) void {
        _ = self.app_mailbox.push(message, .instant);
    }

    pub fn handleNotification(self: StreamHandler, notification: tmux.Notification) !void {
        switch (notification) {
            .block_end => self.sendMessage(.render),
            .exit => self.sendMessage(.quit),
            else => {}
        }
    }
};
