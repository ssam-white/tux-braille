const std = @import("std");
const App = @import("../App.zig");
const Tmuxio = @This();
const xev = @import("xev").Dynamic;
const tmuxio = @import("main.zig");
const tmux = @import("../tmux/main.zig");
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Tmuxio);
const posix = std.posix;
const Stream = tmux.Stream;
const StreamHandler = tmuxio.StreamHandler;

subprocess: SubProcess,
stream: Stream(StreamHandler),

pub fn init(alloc: Allocator, app_mailbox: App.Mailbox) Tmuxio {
    var subprocess = SubProcess.init(alloc);
    errdefer subprocess.deinit();

    var handler: StreamHandler = .init(app_mailbox);
    errdefer handler.deinit();
    
    var stream: Stream(StreamHandler) = .init(alloc, handler);
    errdefer stream.deinit();
    
    return .{ .subprocess = subprocess, .stream = stream };
}

pub fn deinit(self: *Tmuxio) void {
    self.subprocess.deinit();
    self.stream.deinit();
}

pub fn threadEnter(
    self: *Tmuxio,
    thread: *tmuxio.Thread,
    td: *ThreadData,
) !void {
    const fds = try self.subprocess.start();
    errdefer self.subprocess.stop();

    var process: xev.Process = try .init(self.subprocess.process.id);
    errdefer process.deinit();

    const process_start = try std.time.Instant.now();

   const pipe = try posix.pipe2(.{ .CLOEXEC = true });
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    var stream = xev.Stream.initFd(fds.write);
    errdefer stream.deinit();

    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMain,
        .{ self, fds.read, pipe[0] }
    );
    read_thread.setName("io-reader") catch {};

    td.* = .{
        .alloc = thread.alloc,
        .loop = &thread.loop,
        .start = process_start,
        .write_stream = stream,
        .process = process,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
        .read_thread_fd = fds.read
        
    };
    
    process.wait(
        td.loop,
        &td.process_wait_c,
        ThreadData,
        td,
        processExit
    );
}

pub fn threadExit(self: *Tmuxio, td: *ThreadData) void {
    self.subprocess.stop();
    _ = posix.write(td.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => {
            log.warn(
                "error writing to read thread quit pipe error={}",
                .{err}
            );
        }
    };
    td.read_thread.join();
}

fn processExitCommon(td: *ThreadData, exit_code: u32) void {
    td.exited = true;

    const runtime_ms: ?u64 = runtime: {
        const process_end = std.time.Instant.now() catch break :runtime null;
        const runtime_ns = process_end.since(td.start);
        const runtime_ms = runtime_ns / std.time.ns_per_ms;
        break :runtime runtime_ms;
    };
    log.debug(
        "child process exited status={} runtime={}ms",
        .{ exit_code, runtime_ms orelse 0 },
    );
}

fn processExit(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Process.WaitError!u32,
) xev.CallbackAction {
    const exit_code = r catch unreachable;
    processExitCommon(td_.?, exit_code);
    return .disarm;
}

pub fn queueWrite(
    self: *Tmuxio,
    alloc: Allocator,
    td: *ThreadData,
    data: []const u8,
) !void {
    _ = self;
    if (td.exited) return;

    var i: usize = 0;
    while (i < data.len) {
        const req = try td.write_req_pool.getGrow(alloc);
        const buf = try td.write_buf_pool.getGrow(alloc);
        const slice = slice: {
            const max = @min(data.len, i + buf.len);
            const source = data[i..max];
            @memcpy(buf[0..source.len], source);
            const len = max - i;
            i = max;
            break :slice buf[0..len];
        };

        td.write_stream.queueWrite(
            td.loop,
            &td.write_queue,
            req,
            .{ .slice = slice },
            ThreadData,
            td,
            ttyWrite,
        );
    }
}

fn ttyWrite(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    const d = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };
    log.info("WROTE: {d}", .{d});

    return .disarm;
}

pub fn processOutput(self: *Tmuxio, buf: []const u8) void {
    for (buf) |byte| self.stream.next(byte) catch {};
}

pub const ThreadData = struct {
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);
    
    alloc: Allocator,
    loop: *xev.Loop,
    start: std.time.Instant,
    exited: bool = false,
    write_stream: xev.Stream,
    process: xev.Process,
    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},
    write_queue: xev.WriteQueue = .{},
    process_wait_c: xev.Completion = .{},
    // reader thread
    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,
    read_thread_fd: posix.fd_t,

    pub fn deinit(self: *ThreadData) void {
        posix.close(self.read_thread_pipe);
        self.write_req_pool.deinit(self.alloc);
        self.write_buf_pool.deinit(self.alloc);
        self.process.deinit();
        self.write_stream.deinit();
    }
};
    
const SubProcess = struct {
    process: std.process.Child,

    pub fn init(alloc: Allocator) SubProcess {
        const cmd =
            \\tmux -L braille has-session -t braille \
            \\  || tmux -L braille new-session -d -s braille "$SHELL";
            \\exec tmux -L braille -C attach-session -t braille
        ;
        
        var process = std.process.Child.init(&.{
            "/bin/sh", "-lc", cmd,
        }, alloc);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Inherit;
    
        return .{
            .process = process
        };
 
    }

    pub fn deinit(self: *SubProcess) void {
        _ = self;
    }

    pub fn start(self: *SubProcess) !struct {
        read: std.fs.File.Handle,
        write: std.fs.File.Handle,
    } {
        try self.process.spawn();
        
        return .{
            .read = self.process.stdout.?.handle,
            .write = self.process.stdin.?.handle,
        };
    }

    pub fn stop(self: *SubProcess) void {
        _ = self;
    }
};

const ReadThread = struct {
    pub fn threadMain(io: *Tmuxio, fd: posix.fd_t, quit: posix.fd_t) void {
        defer posix.close(quit);

        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch |err| {
                log.warn("read thread failed to set flags err={}", .{err});
                log.warn("this isn't a fatal error, but may cause performance issues", .{});
            };
        } else |err| {
            log.warn("read thread failed to get flags err={}", .{err});
            log.warn("this isn't a fatal error, but may cause performance issues", .{});
        }

        // Build up the list of fds we're going to poll. We are looking
        // for data on the pty and our quit notification.
        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [1024]u8 = undefined;
        while (true) {
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("io reader exiting", .{});
                            return;
                        },
                        
                        error.WouldBlock => break,

                        else => {
                            log.err("io reader error err={}", .{err});
                            unreachable;
                        },
                    }
                };

                // This happens on macOS instead of WouldBlock when the
                if (n == 0) break;

                io.processOutput(buf[0..n]);
            }

            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on read thread, exiting early err={}", .{err});
                return;
            };
            
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("read thread got quit signal", .{});
                return;
            }

            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("tmux fd closed, read thread exiting", .{});
                return;
            }
        }
    }
};
