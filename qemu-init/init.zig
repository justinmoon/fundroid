const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

var shutdown_requested: bool = false;
var child_pid: i32 = 0;
var child_exit_status: u32 = 0;
var child_exited: bool = false;

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

fn unmountFilesystem(target: [*:0]const u8) void {
    const result = linux.umount2(target, 0);
    if (linux.E.init(result) != .SUCCESS) {
        print("[ERROR] Failed to unmount {s}\n", .{target});
    }
}

fn handleSignal(sig: i32) callconv(.c) void {
    switch (sig) {
        linux.SIG.TERM, linux.SIG.INT => {
            shutdown_requested = true;
        },
        linux.SIG.CHLD => {
            var status: u32 = 0;
            while (true) {
                const pid = linux.waitpid(-1, &status, linux.W.NOHANG);
                if (pid <= 0) break;
                if (pid == child_pid) {
                    child_exit_status = status;
                    child_exited = true;
                    child_pid = 0;
                }
            }
        },
        else => {},
    }
}

fn spawnChild() void {
    const pid = linux.fork();
    if (pid < 0) {
        print("[ERROR] Fork failed\n", .{});
        return;
    }

    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/test_child", null };
        const envp = [_:null]?[*:0]const u8{null};
        _ = linux.execve("/test_child", &argv, &envp);
        print("[ERROR] Exec failed\n", .{});
        posix.exit(1);
    }

    child_pid = @intCast(pid);
    child_exited = false;
    print("[SPAWN] Child process started with PID {d}\n", .{pid});
}

fn installSignalHandlers() void {
    var sa = linux.Sigaction{
        .handler = .{ .handler = &handleSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = linux.SA.RESTART,
    };

    _ = linux.sigaction(linux.SIG.TERM, &sa, null);
    print("[OK] Signal handler installed for SIGTERM\n", .{});

    _ = linux.sigaction(linux.SIG.INT, &sa, null);
    print("[OK] Signal handler installed for SIGINT\n", .{});

    _ = linux.sigaction(linux.SIG.CHLD, &sa, null);
    print("[OK] Signal handler installed for SIGCHLD\n", .{});
}

pub fn main() void {
    print("========================================\n", .{});
    print("QEMU MINIMAL INIT - Phase 4: Process Management\n", .{});
    print("========================================\n", .{});
    print("PID: {d} (should be 1)\n", .{linux.getpid()});
    print("\n", .{});

    // Parse kernel command line for gfx= parameter
    var gfx_mode: ?[]const u8 = null;
    const cmdline_fd = posix.open("/proc/cmdline", .{ .ACCMODE = .RDONLY }, 0) catch null;
    if (cmdline_fd) |fd| {
        defer posix.close(fd);
        var buf: [4096]u8 = undefined;
        const n = posix.read(fd, &buf) catch 0;
        if (n > 0) {
            var args = std.mem.splitScalar(u8, buf[0..n], ' ');
            while (args.next()) |arg| {
                if (std.mem.startsWith(u8, arg, "gfx=")) {
                    gfx_mode = std.mem.trim(u8, arg[4..], &std.ascii.whitespace);
                    print("[INIT] Graphics mode requested: {s}\n", .{gfx_mode.?});
                }
            }
        }
    }

    installSignalHandlers();
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
    print("\n[PHASE 4] Starting process management...\n", .{});

    spawnChild();
    var respawn_count: u32 = 0;

    print("\nStarting heartbeat loop...\n\n", .{});

    while (!shutdown_requested) {
        // Check for child exit first (before sleeping)
        if (child_exited) {
            const exit_code = if ((child_exit_status & 0x7f) == 0)
                (child_exit_status >> 8) & 0xff
            else
                child_exit_status & 0x7f;

            print("\n[CHILD] Process exited with status {d}\n", .{exit_code});
            child_exited = false;

            if (respawn_count < 3) {
                respawn_count += 1;
                print("[RESPAWN] Waiting 1 second before respawn (count: {d})...\n", .{respawn_count});
                posix.nanosleep(1, 0);
                print("[RESPAWN] Spawning child...\n", .{});
                spawnChild();
            } else {
                print("[RESPAWN] Reached respawn limit, continuing without child\n", .{});
            }
        }

        const timestamp = std.time.timestamp();
        print("[heartbeat] Unix timestamp: {d}\n", .{timestamp});
        posix.nanosleep(0, 500_000_000); // 0.5 seconds
    }

    print("\n[SHUTDOWN] Received SIGTERM, shutting down...\n", .{});

    if (child_pid > 0) {
        print("[SHUTDOWN] Terminating child process PID {d}...\n", .{child_pid});
        _ = linux.kill(child_pid, linux.SIG.TERM);
        posix.nanosleep(0, 500_000_000); // Wait 0.5 seconds for graceful exit
        if (child_pid > 0) {
            _ = linux.kill(child_pid, linux.SIG.KILL);
        }
    }

    print("[SHUTDOWN] Unmounting /dev...\n", .{});
    unmountFilesystem("/dev");

    print("[SHUTDOWN] Unmounting /sys...\n", .{});
    unmountFilesystem("/sys");

    print("[SHUTDOWN] Unmounting /proc...\n", .{});
    unmountFilesystem("/proc");

    print("[SHUTDOWN] Shutdown complete\n", .{});
    posix.exit(0);
}
