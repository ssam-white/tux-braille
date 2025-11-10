const std = @import("std");
const App = @import ("../App.zig");
const tmux = @import("../tmux/main.zig");
const tmuxio = @import("../tmuxio/main.zig");

const log = std.log.scoped(.stream_handler);
const Tmuxio = tmuxio.Tmuxio;

pub const StreamHandler = struct {
    app_mailbox: App.Mailbox,
    io_mailbox: Tmuxio.Mailbox,
    cursor_line_requested: bool = false,
    
    pub fn init(app_mailbox: App.Mailbox, io_mailbox: Tmuxio.Mailbox) StreamHandler {
        return .{
            .app_mailbox = app_mailbox,
            .io_mailbox = io_mailbox
        };
    }

    pub fn deinit(self: *StreamHandler) void {
        _ = self;
    }

    fn sendMessage(self: StreamHandler, message: App.Message) void {
        _ = self.app_mailbox.push(message, .instant);
    }

    fn ioMessage(self: StreamHandler, message: Tmuxio.Message) !void {
        _ = try self.io_mailbox.push(message, .instant);
    }

    pub fn requestCursorLine(self: *StreamHandler) !void {
        try self.ioMessage(.request_cursor_line);
        self.cursor_line_requested = true;
    }

    pub fn handleNotification(self: *StreamHandler, notification: tmux.Notification) !void {
        switch (notification) {
            .output => try self.requestCursorLine(),
            .exit => self.sendMessage(.quit),
            .block_end => |cursor_line| if (self.cursor_line_requested) {
                self.cursor_line_requested = false;
                log.info("{s}", .{ cursor_line });
            },
            else => {}
        }
    }
};
