const std = @import("std");
const App = @This();
const tmuxio = @import("tmuxio/main.zig");
const datastruct = @import("datastruct/main.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.App);
const BlockingQueue = datastruct.BlockingQueue;

alloc: Allocator,
running: bool = true,
mailbox: Mailbox.Queue,
io: tmuxio.Tmuxio,
io_thread: tmuxio.Thread,
io_thr: std.Thread,
sleep_mutex: std.Thread.Mutex = .{},
sleep_cond: std.Thread.Condition = .{},

pub fn create(alloc: Allocator) !*App {
    const app_ptr = try alloc.create(App);
    errdefer alloc.destroy(app_ptr);

    app_ptr.* = .{
        .alloc = alloc,
        .mailbox = .{},
        .io = undefined,
        .io_thread = undefined,
        .io_thr = undefined,
    };

    const app_mailbox: Mailbox = .{ .app = app_ptr, .mailbox = &app_ptr.mailbox };

    app_ptr.io = try .init(alloc, app_mailbox);
    errdefer app_ptr.io.deinit(alloc);
    
    app_ptr.io_thread = try .init(alloc);
    app_ptr.io_thr = try std.Thread.spawn(
        .{},
        tmuxio.Thread.threadMain,
        .{ &app_ptr.io_thread, &app_ptr.io }
    );
    app_ptr.io_thr.setName("io-thread") catch {};
    
    return app_ptr;
}

pub fn destroy(self: *App) void {
    log.info("destroying app", .{});
    {
        self.io_thread.stop.notify() catch
            log.err("error in notifying the io thread to stop", .{});
        self.io_thr.join();
        self.io_thread.deinit();
        self.io.deinit(self.alloc);

    }
    self.alloc.destroy(self);
}

pub fn run(self: *App) !void {
    while (self.running) {
        self.sleep();
        try self.drainMailbox();
    }
}

pub const Message = union(enum) {
    render,
    quit,
};

pub const Mailbox = struct {
     pub const Queue = BlockingQueue(Message, 64);

     app: *App,
     mailbox: *Queue,

     pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
         const result = self.mailbox.push(msg, timeout);
         self.app.wakeup();
         return result;
     }
};

fn drainMailbox(self: *App) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .render => try self.render(),
            .quit => {
                log.info("quit message recieved", .{});
                self.quit();
                return;
            }
        }
    }
}

pub fn quit(self: *App) void {
    self.running = false;
}

pub fn render(self: *App) !void {
    _ = self;
}

fn sleep(self: *App) void {
    self.sleep_mutex.lock();
    defer self.sleep_mutex.unlock();
    self.sleep_cond.wait(&self.sleep_mutex);
}

pub fn wakeup(self: *App) void {
    self.sleep_mutex.lock();
    defer self.sleep_mutex.unlock();
    self.sleep_cond.signal();
}
