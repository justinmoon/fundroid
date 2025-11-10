const std = @import("std");
const fs = std.fs;
const mem = std.mem;

pub fn main() !void {
    std.debug.print("[test-input] Enumerating /dev/input\n", .{});

    const devices = try listDevices();
    if (devices == 0) {
        std.debug.print("No input devices found; ensure CONFIG_VIRTIO_INPUT is enabled.\n", .{});
        return;
    }

    try sampleFirstDevice();
}

fn listDevices() !usize {
    var count: usize = 0;
    var dir = fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch {
        std.debug.print("/dev/input missing\n", .{});
        return 0;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and mem.startsWith(u8, entry.name, "event")) {
            count += 1;
            std.debug.print("  - {s}\n", .{entry.name});
        }
    }

    std.debug.print("Total devices: {d}\n", .{count});
    return count;
}

fn sampleFirstDevice() !void {
    var dir = fs.openDirAbsolute("/dev/input", .{ .iterate = true }) catch {
        std.debug.print("Unable to reopen /dev/input for sampling\n", .{});
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !mem.startsWith(u8, entry.name, "event")) continue;

        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/dev/input/{s}", .{entry.name});
        try readSample(path);
        return;
    }
}

fn readSample(path: []const u8) !void {
    const file = fs.openFileAbsolute(path, .{ .mode = .read_only }) catch {
        std.debug.print("Could not open {s}\n", .{path});
        return;
    };
    defer file.close();

    var buf: [64]u8 = undefined;
    const read_bytes = try file.read(&buf);
    std.debug.print("Read {d} bytes from {s}\n", .{ read_bytes, path });
    if (read_bytes == 0) {
        std.debug.print("(no events yet, but device is accessible)\n", .{});
    }
}
