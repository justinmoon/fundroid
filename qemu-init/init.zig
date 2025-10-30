//! MINIMAL LINUX INIT - Educational PID 1 Implementation
//! =====================================================
//!
//! Phase 2: Filesystem Setup
//!
//! This init now mounts the essential filesystems that any real init needs:
//! - /proc: Process information (virtual filesystem)
//! - /sys: Kernel/device information (sysfs)
//! - /dev: Device nodes (devtmpfs)
//!
//! WHAT IS PID 1?
//! - The first userspace process the kernel starts
//! - Must never exit (or kernel panics)
//! - Responsible for initial system setup
//! - In real systems: systemd, sysvinit, etc.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch return;
}

fn mountFilesystem(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, flags: u32) !void {
    const result = linux.mount(source, target, fstype, flags, 0);
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .ACCES => error.AccessDenied,
        .BUSY => error.DeviceBusy,
        .FAULT => error.BadAddress,
        .INVAL => error.InvalidArgument,
        .LOOP => error.LoopDetected,
        .MFILE => error.TooManyLinks,
        .NAMETOOLONG => error.NameTooLong,
        .NODEV => error.NoDevice,
        .NOENT => error.FileNotFound,
        .NOMEM => error.OutOfMemory,
        .NOTBLK => error.NotBlockDevice,
        .NOTDIR => error.NotDir,
        .NXIO => error.NoSuchDeviceOrAddress,
        .PERM => error.OperationNotPermitted,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn createDirectory(path: [*:0]const u8) void {
    _ = linux.mkdir(path, 0o755);
}

pub fn main() void {
    print("========================================\n", .{});
    print("QEMU MINIMAL INIT - Phase 2: Filesystem Setup\n", .{});
    print("========================================\n", .{});
    print("PID: {d} (should be 1)\n", .{linux.getpid()});
    print("\n", .{});
    
    print("[PHASE 2] Mounting essential filesystems...\n", .{});
    
    createDirectory("/proc");
    createDirectory("/sys");
    createDirectory("/dev");
    
    mountFilesystem("proc", "/proc", "proc", linux.MS.NODEV | linux.MS.NOSUID | linux.MS.NOEXEC) catch |err| {
        print("[ERROR] Failed to mount /proc: {s}\n", .{@errorName(err)});
    };
    print("[OK] Mounted /proc (process information)\n", .{});
    
    mountFilesystem("sysfs", "/sys", "sysfs", linux.MS.NODEV | linux.MS.NOSUID | linux.MS.NOEXEC) catch |err| {
        print("[ERROR] Failed to mount /sys: {s}\n", .{@errorName(err)});
    };
    print("[OK] Mounted /sys (kernel/device info)\n", .{});
    
    mountFilesystem("devtmpfs", "/dev", "devtmpfs", linux.MS.NOSUID | linux.MS.NOEXEC) catch |err| {
        print("[ERROR] Failed to mount /dev: {s}\n", .{@errorName(err)});
    };
    print("[OK] Mounted /dev (device nodes)\n", .{});
    
    print("\n[VERIFY] Reading /proc/self/status to confirm PID...\n", .{});
    const status_fd = posix.open("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0) catch {
        print("[ERROR] Failed to open /proc/self/status\n", .{});
        return;
    };
    defer posix.close(status_fd);
    
    var buf: [1024]u8 = undefined;
    const n = posix.read(status_fd, &buf) catch 0;
    if (n > 0) {
        print("[OK] Successfully read /proc/self/status ({d} bytes)\n", .{n});
        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Pid:")) {
                print("  {s}\n", .{line});
                break;
            }
        }
    }
    
    print("\n[VERIFY] Counting devices in /dev...\n", .{});
    const dev_dir = posix.open("/dev", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch {
        print("[ERROR] Failed to open /dev\n", .{});
        return;
    };
    defer posix.close(dev_dir);
    
    var count: usize = 0;
    var dir_buf: [4096]u8 = undefined;
    while (true) {
        const n_read = linux.getdents64(dev_dir, &dir_buf, dir_buf.len);
        if (n_read <= 0) break;
        
        var offset: usize = 0;
        while (offset < @as(usize, @intCast(n_read))) {
            const entry: *linux.dirent64 = @ptrCast(@alignCast(&dir_buf[offset]));
            if (entry.reclen == 0) break;
            count += 1;
            offset += entry.reclen;
        }
    }
    print("[OK] Found {d} entries in /dev\n", .{count});
    
    print("\n[SUCCESS] All filesystems mounted and verified!\n", .{});
    print("Starting heartbeat loop...\n\n", .{});
    
    while (true) {
        const timestamp = std.time.timestamp();
        print("[heartbeat] Unix timestamp: {d}\n", .{timestamp});
        posix.nanosleep(2, 0);
    }
}
