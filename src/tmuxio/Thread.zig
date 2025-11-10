const builtin = @import("builtin");
const std = @import("std");
pub const Thread = @This();
const xev = @import("xev");
const tmuxio = @import("main.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const log = std.log.scoped(.io_thread);

const sync_reset_ms = 1000;

alloc: std.mem.Allocator,
loop: xev.Loop,
wakeup_c: xev.Completion = .{},
stop: xev.Async,
stop_c: xev.Completion = .{},

pub fn init(
    alloc: Allocator,
) !Thread {
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    return .{
        .alloc = alloc,
        .loop = loop,
        .stop = stop_h,
    };
}

pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.loop.deinit();
}

pub fn threadMain(self: *Thread, io: *tmuxio.Tmuxio) void {
    self.threadMain_(io) catch |err| {
        log.warn("error in io thread err={}", .{err});
    };

    if (!self.loop.stopped()) {
        log.warn("abrupt io thread exit detected, starting xev to drain mailbox", .{});
        defer log.debug("io thread fully exiting after abnormal failure", .{});
        self.loop.run(.until_done) catch |err| {
            log.err("failed to start xev loop for draining err={}", .{err});
        };
    }
}

fn threadMain_(self: *Thread, io: *tmuxio.Tmuxio) !void {
    defer log.debug("IO thread exited", .{});

    var cb: CallbackData = .{ .self = self };

    try io.threadEnter(self, &cb.data);
    defer cb.data.deinit();
    defer io.threadExit(&cb.data);

    inline for (.{
        "set-window-option -g window-size manual\n",
        "resize-window -x 40 -y 1\n"
    }) |cmd|  io.queueWrite(
        self.alloc,
        &cb.data,
        cmd
    ) catch {};

    self.stop.wait(&self.loop, &self.stop_c, CallbackData, &cb, stopCallback);

    log.debug("starting IO thread", .{});
    defer log.debug("starting IO thread shutdown", .{});
    try self.loop.run(.until_done);
}

const CallbackData = struct {
    self: *Thread,
    data: tmuxio.Tmuxio.ThreadData = undefined,
};

fn drainMailbox(
    self: *Thread,
    cb: *CallbackData,
) !void {
        _ = self; _ = cb;
}

fn wakeupCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const cb = cb_ orelse return .rearm;
    cb.self.drainMailbox(cb) catch |err|
        log.err("error draining mailbox err={}", .{err});

    return .rearm;
}

fn stopCallback(
    cb_: ?*CallbackData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    cb_.?.self.loop.stop();
    return .disarm;
}
