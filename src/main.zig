const std = @import("std");
const App = @import("App.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    
    const app = try App.create(alloc);
    defer app.destroy();
    try app.run();
}

test {
    _ = @import("datastruct/main.zig");
    _ = @import("tmux/main.zig");
}
