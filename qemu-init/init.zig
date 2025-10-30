//! MINIMAL LINUX INIT - Educational PID 1 Implementation
//! =====================================================
//!
//! This is the SIMPLEST possible init process for Linux.
//! The kernel will execute this as PID 1 after booting.
//!
//! WHAT IS PID 1?
//! - The first userspace process the kernel starts
//! - Must never exit (or kernel panics)
//! - Responsible for initial system setup
//! - In real systems: systemd, sysvinit, etc.
//!
//! WHAT THIS PROGRAM DOES:
//! 1. Prints a message to prove it's running
//! 2. Loops forever printing timestamps
//! 3. Never exits (critical for PID 1!)
//!
//! WHAT THIS PROGRAM DOESN'T DO:
//! - No filesystem mounting (not needed in initramfs)
//! - No device setup (devtmpfs does this automatically)
//! - No signal handling (keeping it simple)
//! - No child process reaping (no children to reap)

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Simple print function for init - writes directly to stdout (fd 1)
/// We use this because Zig 0.15 changed the I/O APIs and this is the simplest approach.
fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch return;
}

pub fn main() void {
    // Announce we've started. If you see this message, it means:
    // - The kernel successfully loaded our initramfs
    // - The kernel found and executed our init binary
    // - We're running as PID 1
    print("========================================\n", .{});
    print("QEMU MINIMAL INIT - Learning Exercise (Zig)\n", .{});
    print("========================================\n", .{});
    print("PID: {d} (should be 1)\n", .{linux.getpid()});
    print("Starting heartbeat loop...\n\n", .{});
    
    // INFINITE LOOP - This is CRITICAL for PID 1
    // If init exits, the kernel panics with "Attempted to kill init!"
    //
    // In a real init system, this loop would:
    // - Monitor and restart services
    // - Handle signals (SIGTERM, SIGCHLD, etc.)
    // - Reap zombie processes
    //
    // For learning, we just print timestamps to prove we're alive.
    while (true) {
        const timestamp = std.time.timestamp();
        print("[heartbeat] Unix timestamp: {d}\n", .{timestamp});
        
        // Sleep for 2 seconds between heartbeats
        posix.nanosleep(2, 0);
    }
    
    // We should NEVER reach here!
    // If we do, the kernel will panic.
}
