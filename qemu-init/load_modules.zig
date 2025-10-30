const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub fn main() !void {
    const modules = [_][]const u8{
        "/lib/modules/virtio.ko",
        "/lib/modules/virtio_ring.ko",
        "/lib/modules/virtio_pci_modern_dev.ko",
        "/lib/modules/virtio_pci_legacy_dev.ko",
        "/lib/modules/virtio_pci.ko",
        "/lib/modules/virtio_dma_buf.ko",
        "/lib/modules/virtio-gpu.ko",
    };

    for (modules) |module_path| {
        std.debug.print("Loading {s}...\n", .{module_path});
        
        const fd = posix.open(module_path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            std.debug.print("  ERROR: Can't open: {s}\n", .{@errorName(err)});
            continue;
        };
        defer posix.close(fd);

        const stat = posix.fstat(fd) catch continue;
        const size = @as(usize, @intCast(stat.size));
        
        const buf = posix.mmap(
            null,
            size,
            posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch |err| {
            std.debug.print("  ERROR: Can't mmap: {s}\n", .{@errorName(err)});
            continue;
        };
        defer posix.munmap(buf);

        const result = linux.syscall3(.init_module, @intFromPtr(buf.ptr), size, @intFromPtr(""));
        if (result != 0) {
            std.debug.print("  ERROR: init_module failed: {d}\n", .{result});
        } else {
            std.debug.print("  OK\n", .{});
        }
    }
}
