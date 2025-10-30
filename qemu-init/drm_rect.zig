const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
    @cInclude("drm_fourcc.h");
});

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(1, msg) catch return;
}

pub fn main() !void {
    print("drm_rect: starting\n", .{});
    
    // Open DRM device
    const card_path = "/dev/dri/card0";
    print("opening KMS device {s}\n", .{card_path});
    
    const fd = try posix.open(card_path, .{ .ACCMODE = .RDWR }, 0);
    defer posix.close(fd);
    
    print("opened {s} successfully (fd={d})\n", .{ card_path, fd });
    
    // Get DRM resources
    const resources = c.drmModeGetResources(fd);
    if (resources == null) {
        print("ERROR: failed to get DRM resources\n", .{});
        return error.DrmResourcesFailed;
    }
    defer c.drmModeFreeResources(resources);
    
    print("found {d} connectors, {d} encoders, {d} crtcs\n", .{
        resources.*.count_connectors,
        resources.*.count_encoders,
        resources.*.count_crtcs,
    });
    
    // Find connected connector
    var connector: ?*c.drmModeConnector = null;
    var conn_id: u32 = 0;
    var i: usize = 0;
    while (i < resources.*.count_connectors) : (i += 1) {
        const conn_ptr = resources.*.connectors;
        const this_id = conn_ptr[i];
        const conn = c.drmModeGetConnector(fd, this_id);
        if (conn == null) continue;
        
        if (conn.*.connection == c.DRM_MODE_CONNECTED and conn.*.count_modes > 0) {
            connector = conn;
            conn_id = this_id;
            print("using connector {d} (state=connected, modes={d})\n", .{ conn_id, conn.*.count_modes });
            break;
        }
        c.drmModeFreeConnector(conn);
    }
    
    if (connector == null) {
        print("ERROR: no connected connector found\n", .{});
        return error.NoConnector;
    }
    defer c.drmModeFreeConnector(connector);
    
    // Get first mode
    const mode = connector.*.modes[0];
    print("using mode {d}x{d} @ {d}Hz\n", .{ mode.hdisplay, mode.vdisplay, mode.vrefresh });
    
    // Find encoder and CRTC
    const encoder_id = connector.*.encoder_id;
    if (encoder_id == 0) {
        print("ERROR: connector has no encoder\n", .{});
        return error.NoEncoder;
    }
    
    const encoder = c.drmModeGetEncoder(fd, encoder_id);
    if (encoder == null) {
        print("ERROR: failed to get encoder {d}\n", .{encoder_id});
        return error.EncoderFailed;
    }
    defer c.drmModeFreeEncoder(encoder);
    
    const crtc_id = encoder.*.crtc_id;
    if (crtc_id == 0) {
        print("ERROR: encoder has no CRTC\n", .{});
        return error.NoCrtc;
    }
    print("using CRTC {d}\n", .{crtc_id});
    
    // Create dumb buffer
    const width = mode.hdisplay;
    const height = mode.vdisplay;
    print("allocating dumb buffer {d}x{d}\n", .{ width, height });
    
    var create_req = std.mem.zeroes(c.struct_drm_mode_create_dumb);
    create_req.width = width;
    create_req.height = height;
    create_req.bpp = 32;
    
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create_req) != 0) {
        print("ERROR: failed to create dumb buffer\n", .{});
        return error.CreateDumbFailed;
    }
    
    const handle = create_req.handle;
    const pitch = create_req.pitch;
    const size = create_req.size;
    print("created dumb buffer: handle={d}, pitch={d}, size={d}\n", .{ handle, pitch, size });
    
    // Create framebuffer
    var fb_id: u32 = 0;
    if (c.drmModeAddFB(fd, width, height, 24, 32, pitch, handle, &fb_id) != 0) {
        print("ERROR: failed to create framebuffer\n", .{});
        return error.CreateFbFailed;
    }
    print("created framebuffer {d}\n", .{fb_id});
    
    // Map buffer and fill with color (orange: 255, 136, 0)
    var map_req = std.mem.zeroes(c.struct_drm_mode_map_dumb);
    map_req.handle = handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map_req) != 0) {
        print("ERROR: failed to map dumb buffer\n", .{});
        return error.MapDumbFailed;
    }
    
    const map_offset = map_req.offset;
    const map_ptr = posix.mmap(
        null,
        size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        map_offset,
    ) catch {
        print("ERROR: mmap failed\n", .{});
        return error.MmapFailed;
    };
    defer posix.munmap(@alignCast(map_ptr));
    
    // Fill with orange color (B, G, R, A in little-endian XRGB8888)
    print("filling buffer with orange (#FF8800)\n", .{});
    const pixels = @as([*]u32, @ptrCast(@alignCast(map_ptr)))[0 .. size / 4];
    for (pixels) |*px| {
        px.* = 0xFF_00_88_FF; // ARGB in memory = 0xFFFF8800 (orange)
    }
    
    // Set CRTC
    print("setting CRTC {d} to FB {d}\n", .{ crtc_id, fb_id });
    if (c.drmModeSetCrtc(fd, crtc_id, fb_id, 0, 0, &conn_id, 1, &mode) != 0) {
        print("ERROR: failed to set CRTC\n", .{});
        return error.SetCrtcFailed;
    }
    
    print("displaying for 30 seconds...\n", .{});
    posix.nanosleep(30, 0);
    
    // Clean up: clear CRTC
    print("clearing CRTC\n", .{});
    _ = c.drmModeSetCrtc(fd, crtc_id, 0, 0, 0, null, 0, null);
    
    // Destroy framebuffer
    print("destroying framebuffer {d}\n", .{fb_id});
    _ = c.drmModeRmFB(fd, fb_id);
    
    // Destroy dumb buffer
    print("destroying dumb buffer\n", .{});
    var destroy_req = std.mem.zeroes(c.struct_drm_mode_destroy_dumb);
    destroy_req.handle = handle;
    _ = c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_req);
    
    print("drm_rect: complete\n", .{});
}
