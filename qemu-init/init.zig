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

fn startSeatd() i32 {
    print("[SEATD] Starting seat management daemon...\n", .{});
    
    const pid = linux.fork();
    if (pid < 0) {
        print("[ERROR] Failed to fork for seatd\n", .{});
        return -1;
    }

    if (pid == 0) {
        // Child process - exec seatd
        const argv = [_:null]?[*:0]const u8{ 
            "/usr/bin/seatd",
            "-n",  // Non-forking mode (stay in foreground)
            null 
        };
        const envp = [_:null]?[*:0]const u8{
            "LD_LIBRARY_PATH=/usr/lib",  // Find shared libraries
            "SEATD_VTBOUND=1",  // Tell seatd we're bound to a VT
            "PATH=/usr/bin:/bin",
            null
        };
        const result = linux.execve("/usr/bin/seatd", &argv, &envp);
        // If we get here, exec failed
        const err = linux.E.init(result);
        print("[ERROR] Failed to exec seatd: error code {d}\n", .{@intFromEnum(err)});
        posix.exit(1);
    }

    // Parent process - seatd started
    print("[SEATD] Started with PID {d}\n", .{pid});
    
    // Give seatd a moment to initialize and create its socket
    posix.nanosleep(0, 100_000_000); // 100ms
    
    return @intCast(pid);
}

fn loadKernelModules() void {
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
        print("Loading {s}...\n", .{module_path});
        
        const fd = posix.open(module_path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
            print("  ERROR: Can't open: {s}\n", .{@errorName(err)});
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
            print("  ERROR: Can't mmap: {s}\n", .{@errorName(err)});
            continue;
        };
        defer posix.munmap(buf);

        const result = linux.syscall3(.init_module, @intFromPtr(buf.ptr), size, @intFromPtr(""));
        if (result != 0) {
            print("  ERROR: init_module failed: {d}\n", .{result});
        } else {
            print("  OK\n", .{});
        }
    }
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

    // Parse kernel command line for gfx= parameter (AFTER mounting /proc)
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

    mountFilesystem("sysfs", "/sys", "sysfs", linux.MS.NODEV | linux.MS.NOSUID | linux.MS.NOEXEC) catch |err| {
        print("[ERROR] Failed to mount /sys: {s}\n", .{@errorName(err)});
    };
    print("[OK] Mounted /sys (kernel/device info)\n", .{});

    mountFilesystem("devtmpfs", "/dev", "devtmpfs", linux.MS.NOSUID | linux.MS.NOEXEC) catch |err| {
        print("[ERROR] Failed to mount /dev: {s}\n", .{@errorName(err)});
    };
    print("[OK] Mounted /dev (device nodes)\n", .{});

    // Load kernel modules for DRM support inline (no fork to avoid signal handler issues)
    print("[DRM] Loading kernel modules...\n", .{});
    loadKernelModules();

    // Check if DRM device exists
    print("[DRM] Checking for /dev/dri/card0...\n", .{});
    const drm_test = posix.open("/dev/dri/card0", .{ .ACCMODE = .RDONLY }, 0) catch |err| blk: {
        print("[DRM] /dev/dri/card0 not found: {s}\n", .{@errorName(err)});
        print("[DRM] Kernel likely doesn't have virtio_gpu driver\n", .{});
        print("[DRM] Need kernel with CONFIG_DRM_VIRTIO_GPU=y built-in\n", .{});
        break :blk null;
    };
    if (drm_test) |fd| {
        posix.close(fd);
        print("[DRM] /dev/dri/card0 found - DRM is available!\n", .{});
    }

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
    
    // [PHASE 3] Runtime Directory Setup for Wayland/Weston
    print("\n[PHASE 3] Setting up runtime directories for Wayland...\n", .{});
    
    // Create /run directory first
    createDirectory("/run");
    
    // Create /run/wayland with mode 0700 (owner only)
    const run_wayland_result = linux.mkdir("/run/wayland", 0o700);
    if (linux.E.init(run_wayland_result) == .SUCCESS) {
        print("[OK] Created /run/wayland (mode 0700)\n", .{});
    } else {
        print("[WARNING] Failed to create /run/wayland\n", .{});
    }
    
    // Create /tmp with mode 1777 (sticky bit + world writable)
    const tmp_result = linux.mkdir("/tmp", 0o1777);
    if (linux.E.init(tmp_result) == .SUCCESS) {
        print("[OK] Created /tmp (mode 1777 - sticky bit)\n", .{});
    } else {
        print("[WARNING] Failed to create /tmp\n", .{});
    }
    
    // Verify directories were created with correct permissions
    const run_wayland_stat = posix.open("/run/wayland", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |err| blk: {
        print("[ERROR] /run/wayland not accessible: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (run_wayland_stat) |fd| {
        posix.close(fd);
        print("[VERIFY] /run/wayland exists and is accessible\n", .{});
    }
    
    const tmp_stat = posix.open("/tmp", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |err| blk: {
        print("[ERROR] /tmp not accessible: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (tmp_stat) |fd| {
        posix.close(fd);
        print("[VERIFY] /tmp exists and is accessible\n", .{});
    }
    
    print("\n[PHASE 3] Runtime environment variables:\n", .{});
    print("  XDG_RUNTIME_DIR=/run/wayland\n", .{});
    print("  LD_LIBRARY_PATH=/usr/lib\n", .{});
    print("  (These will be set when launching Weston)\n", .{});
    
    // [PHASE 2 TEST] Verify Weston rootfs is accessible
    print("\n[PHASE 2 TEST] Verifying Weston rootfs...\n", .{});
    const weston_test = posix.open("/usr/bin/weston", .{ .ACCMODE = .RDONLY }, 0) catch |err| blk: {
        print("[PHASE 2 TEST] FAILED: /usr/bin/weston not found: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (weston_test) |fd| {
        posix.close(fd);
        print("[PHASE 2 TEST] SUCCESS: /usr/bin/weston exists!\n", .{});
    }
    
    const seatd_test = posix.open("/usr/bin/seatd", .{ .ACCMODE = .RDONLY }, 0) catch |err| blk: {
        print("[PHASE 2 TEST] FAILED: /usr/bin/seatd not found: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (seatd_test) |fd| {
        posix.close(fd);
        print("[PHASE 2 TEST] SUCCESS: /usr/bin/seatd exists!\n", .{});
    }
    
    // [PHASE 4 TEST] Verify Weston configuration is accessible
    print("\n[PHASE 4 TEST] Verifying Weston configuration...\n", .{});
    const weston_ini_test = posix.open("/etc/weston.ini", .{ .ACCMODE = .RDONLY }, 0) catch |err| blk: {
        print("[PHASE 4 TEST] FAILED: /etc/weston.ini not found: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (weston_ini_test) |fd| {
        posix.close(fd);
        print("[PHASE 4 TEST] SUCCESS: /etc/weston.ini exists!\n", .{});
    }
    
    // [PHASE 6 TEST] Verify Weston startup script is accessible
    print("\n[PHASE 6 TEST] Verifying Weston startup script...\n", .{});
    const start_weston_test = posix.open("/usr/bin/start-weston", .{ .ACCMODE = .RDONLY }, 0) catch |err| blk: {
        print("[PHASE 6 TEST] FAILED: /usr/bin/start-weston not found: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    if (start_weston_test) |fd| {
        posix.close(fd);
        print("[PHASE 6 TEST] SUCCESS: /usr/bin/start-weston exists!\n", .{});
    }
    
    // [PHASE 5] Start seatd (seat management daemon)
    // This must be started BEFORE Weston, as it manages device permissions
    print("\n[PHASE 5] Starting seatd for device access management...\n", .{});
    const seatd_pid = startSeatd();
    if (seatd_pid > 0) {
        print("[PHASE 5] seatd is running, Weston will be able to access devices\n", .{});
    } else {
        print("[PHASE 5] WARNING: seatd failed to start, Weston may not work\n", .{});
    }
    
    // Check if gfx mode requested
    if (gfx_mode) |mode| {
        if (std.mem.eql(u8, mode, "drm_rect")) {
            print("\n[GFX] Launching drm_rect...\n", .{});
            const pid = linux.fork();
            if (pid == 0) {
                const argv = [_:null]?[*:0]const u8{ "/drm_rect", null };
                const envp = [_:null]?[*:0]const u8{ "LD_LIBRARY_PATH=/lib:/lib64", null };
                _ = linux.execve("/drm_rect", &argv, &envp);
                print("[ERROR] Failed to exec drm_rect\n", .{});
                posix.exit(1);
            } else if (pid > 0) {
                print("[GFX] drm_rect started with PID {d}\n", .{pid});
                // Wait for it to finish
                var status: u32 = 0;
                _ = linux.waitpid(@intCast(pid), &status, 0);
                print("[GFX] drm_rect exited\n", .{});
            }
        }
    }
    
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
