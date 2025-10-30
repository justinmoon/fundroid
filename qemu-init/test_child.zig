const std = @import("std");
const posix = std.posix;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch return;
}

pub fn main() void {
    print("Hello from child process!\n", .{});
    posix.nanosleep(0, 200_000_000); // Sleep 0.2 seconds
    print("Child exiting...\n", .{});
}
