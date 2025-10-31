const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// Framebuffer ioctls
const FBIOGET_VSCREENINFO = 0x4600;
const FBIOGET_FSCREENINFO = 0x4602;

const fb_var_screeninfo = extern struct {
    xres: u32,
    yres: u32,
    xres_virtual: u32,
    yres_virtual: u32,
    xoffset: u32,
    yoffset: u32,
    bits_per_pixel: u32,
    grayscale: u32,
    red: fb_bitfield,
    green: fb_bitfield,
    blue: fb_bitfield,
    transp: fb_bitfield,
    nonstd: u32,
    activate: u32,
    height: u32,
    width: u32,
    accel_flags: u32,
    pixclock: u32,
    left_margin: u32,
    right_margin: u32,
    upper_margin: u32,
    lower_margin: u32,
    hsync_len: u32,
    vsync_len: u32,
    sync: u32,
    vmode: u32,
    rotate: u32,
    colorspace: u32,
    reserved: [4]u32,
};

const fb_bitfield = extern struct {
    offset: u32,
    length: u32,
    msb_right: u32,
};

const fb_fix_screeninfo = extern struct {
    id: [16]u8,
    smem_start: u64,
    smem_len: u32,
    type: u32,
    type_aux: u32,
    visual: u32,
    xpanstep: u16,
    ypanstep: u16,
    ywrapstep: u16,
    line_length: u32,
    mmio_start: u64,
    mmio_len: u32,
    accel: u32,
    capabilities: u16,
    reserved: [2]u16,
};

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch return;
}

pub fn main() !void {
    print("fb_rect: using framebuffer directly (no DRM!)\n", .{});
    
    const fb_path = "/dev/fb0";
    const fd = try posix.open(fb_path, .{ .ACCMODE = .RDWR }, 0);
    defer posix.close(fd);
    
    print("opened {s} (fd={d})\n", .{ fb_path, fd });
    
    // Get variable screen info
    var vinfo = std.mem.zeroes(fb_var_screeninfo);
    _ = linux.ioctl(fd, FBIOGET_VSCREENINFO, @intFromPtr(&vinfo));
    
    print("screen: {d}x{d}, {d}bpp\n", .{ vinfo.xres, vinfo.yres, vinfo.bits_per_pixel });
    
    // Get fixed screen info  
    var finfo = std.mem.zeroes(fb_fix_screeninfo);
    _ = linux.ioctl(fd, FBIOGET_FSCREENINFO, @intFromPtr(&finfo));
    
    print("framebuffer: {d} bytes, line_length={d}\n", .{ finfo.smem_len, finfo.line_length });
    
    // Map framebuffer
    const size = finfo.smem_len;
    const map_ptr = try posix.mmap(
        null,
        size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer posix.munmap(@alignCast(map_ptr));
    
    print("mapped framebuffer at {*}\n", .{map_ptr});
    
    // Fill with orange
    print("filling screen with orange...\n", .{});
    const pixels = @as([*]u32, @ptrCast(@alignCast(map_ptr)))[0 .. size / 4];
    for (pixels) |*px| {
        px.* = 0xFF8800FF; // RGBA orange
    }
    
    print("displaying for 30 seconds...\n", .{});
    posix.nanosleep(30, 0);
    
    print("fb_rect: complete\n", .{});
}
