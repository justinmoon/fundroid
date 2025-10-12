// DRM dumb buffer implementation for drawing a rectangle directly to the display
// This uses the Linux DRM (Direct Rendering Manager) subsystem

use std::os::fd::{AsRawFd, RawFd};
use nix::fcntl::OFlag;
use nix::sys::stat::Mode;
use libc::{c_void, mmap, munmap, MAP_SHARED, MAP_FAILED, PROT_READ, PROT_WRITE};

// DRM ioctl numbers and structures
const DRM_IOCTL_BASE: u8 = b'd';

// DRM mode ioctls
const DRM_IOCTL_MODE_GETRESOURCES: u64 = 0xC04064A0;
const DRM_IOCTL_MODE_GETCONNECTOR: u64 = 0xC05064A7;
const DRM_IOCTL_MODE_GETENCODER: u64 = 0xC01464A6;
const DRM_IOCTL_MODE_CREATE_DUMB: u64 = 0xC02064B2;
const DRM_IOCTL_MODE_MAP_DUMB: u64 = 0xC01064B3;
const DRM_IOCTL_MODE_ADDFB2: u64 = 0xC10464B8;
const DRM_IOCTL_MODE_SETCRTC: u64 = 0xC06864A2;
const DRM_IOCTL_MODE_DESTROY_DUMB: u64 = 0xC00464B4;

// DRM connector status
const DRM_MODE_CONNECTED: u32 = 1;

// DRM pixel format (XRGB8888)
const DRM_FORMAT_XRGB8888: u32 = 0x34325258;

#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct DrmModeCardRes {
    fb_id_ptr: u64,
    crtc_id_ptr: u64,
    connector_id_ptr: u64,
    encoder_id_ptr: u64,
    count_fbs: u32,
    count_crtcs: u32,
    count_connectors: u32,
    count_encoders: u32,
    min_width: u32,
    max_width: u32,
    min_height: u32,
    max_height: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct DrmModeModeInfo {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type_: u32,
    name: [u8; 32],
}

#[repr(C)]
struct DrmModeGetConnector {
    encoders_ptr: u64,
    modes_ptr: u64,
    props_ptr: u64,
    prop_values_ptr: u64,
    count_modes: u32,
    count_props: u32,
    count_encoders: u32,
    encoder_id: u32,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    connection: u32,
    mm_width: u32,
    mm_height: u32,
    subpixel: u32,
    pad: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
struct DrmModeGetEncoder {
    encoder_id: u32,
    encoder_type: u32,
    crtc_id: u32,
    possible_crtcs: u32,
    possible_clones: u32,
}

#[repr(C)]
#[derive(Debug)]
struct DrmModeCreateDumb {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32,
    handle: u32,
    pitch: u32,
    size: u64,
}

#[repr(C)]
#[derive(Debug)]
struct DrmModeMapDumb {
    handle: u32,
    pad: u32,
    offset: u64,
}

#[repr(C)]
#[derive(Debug)]
struct DrmModeFB2 {
    fb_id: u32,
    width: u32,
    height: u32,
    pixel_format: u32,
    flags: u32,
    handles: [u32; 4],
    pitches: [u32; 4],
    offsets: [u32; 4],
    modifier: [u64; 4],
}

#[repr(C)]
#[derive(Debug)]
struct DrmModeCrtc {
    set_connectors_ptr: u64,
    count_connectors: u32,
    crtc_id: u32,
    fb_id: u32,
    x: u32,
    y: u32,
    gamma_size: u32,
    mode_valid: u32,
    mode: DrmModeModeInfo,
}

#[repr(C)]
struct DrmModeDestroyDumb {
    handle: u32,
}

fn ioctl_get_resources(fd: RawFd, res: &mut DrmModeCardRes) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, res as *mut _) };
    if ret < 0 {
        Err(format!("GETRESOURCES failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_get_connector(fd: RawFd, conn: &mut DrmModeGetConnector) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, conn as *mut _) };
    if ret < 0 {
        Err(format!("GETCONNECTOR failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_get_encoder(fd: RawFd, enc: &mut DrmModeGetEncoder) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_GETENCODER, enc as *mut _) };
    if ret < 0 {
        Err(format!("GETENCODER failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_create_dumb(fd: RawFd, create: &mut DrmModeCreateDumb) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, create as *mut _) };
    if ret < 0 {
        Err(format!("CREATE_DUMB failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_map_dumb(fd: RawFd, map: &mut DrmModeMapDumb) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, map as *mut _) };
    if ret < 0 {
        Err(format!("MAP_DUMB failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_addfb2(fd: RawFd, fb: &mut DrmModeFB2) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_ADDFB2, fb as *mut _) };
    if ret < 0 {
        Err(format!("ADDFB2 failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_setcrtc(fd: RawFd, crtc: &mut DrmModeCrtc) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_SETCRTC, crtc as *mut _) };
    if ret < 0 {
        Err(format!("SETCRTC failed: {}", ret))
    } else {
        Ok(())
    }
}

fn ioctl_destroy_dumb(fd: RawFd, destroy: &mut DrmModeDestroyDumb) -> Result<(), String> {
    let ret = unsafe { libc::ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, destroy as *mut _) };
    if ret < 0 {
        Err(format!("DESTROY_DUMB failed: {}", ret))
    } else {
        Ok(())
    }
}

fn main() {
    android_logger::init_once(android_logger::Config::default());
    log::info!("drm_rect: starting DRM rectangle demo");

    match draw_orange_rectangle() {
        Ok(_) => log::info!("drm_rect: success!"),
        Err(e) => log::error!("drm_rect: error: {}", e),
    }
}

fn draw_orange_rectangle() -> Result<(), String> {
    // Step 1: Open DRM device
    log::info!("Opening /dev/dri/card0");
    let fd = nix::fcntl::open("/dev/dri/card0", OFlag::O_RDWR, Mode::empty())
        .map_err(|e| format!("Failed to open DRM device: {}", e))?;

    // Step 2: Get DRM resources
    log::info!("Getting DRM resources");
    let mut res = DrmModeCardRes {
        fb_id_ptr: 0,
        crtc_id_ptr: 0,
        connector_id_ptr: 0,
        encoder_id_ptr: 0,
        count_fbs: 0,
        count_crtcs: 0,
        count_connectors: 0,
        count_encoders: 0,
        min_width: 0,
        max_width: 0,
        min_height: 0,
        max_height: 0,
    };

    // First call to get counts
    ioctl_get_resources(fd, &mut res)?;
    log::info!("Found {} connectors, {} crtcs", res.count_connectors, res.count_crtcs);

    // Allocate space for connector IDs
    let mut connector_ids = vec![0u32; res.count_connectors as usize];
    let mut crtc_ids = vec![0u32; res.count_crtcs as usize];

    res.connector_id_ptr = connector_ids.as_mut_ptr() as u64;
    res.crtc_id_ptr = crtc_ids.as_mut_ptr() as u64;

    // Second call to get actual IDs
    ioctl_get_resources(fd, &mut res)?;

    // Step 3: Find a connected connector with a valid mode
    log::info!("Searching for connected connector");
    let mut connector_id = 0u32;
    let mut mode = None;
    let mut encoder_id = 0u32;

    for &conn_id in &connector_ids {
        let mut conn = DrmModeGetConnector {
            encoders_ptr: 0,
            modes_ptr: 0,
            props_ptr: 0,
            prop_values_ptr: 0,
            count_modes: 0,
            count_props: 0,
            count_encoders: 0,
            encoder_id: 0,
            connector_id: conn_id,
            connector_type: 0,
            connector_type_id: 0,
            connection: 0,
            mm_width: 0,
            mm_height: 0,
            subpixel: 0,
            pad: 0,
        };

        // First call to get counts
        ioctl_get_connector(fd, &mut conn)?;

        if conn.connection == DRM_MODE_CONNECTED && conn.count_modes > 0 {
            log::info!("Found connected connector {} with {} modes", conn_id, conn.count_modes);

            // Allocate space for modes
            let mut modes = vec![unsafe { std::mem::zeroed::<DrmModeModeInfo>() }; conn.count_modes as usize];
            conn.modes_ptr = modes.as_mut_ptr() as u64;

            // Second call to get modes
            ioctl_get_connector(fd, &mut conn)?;

            // Use the first (preferred) mode
            mode = Some(modes[0]);
            connector_id = conn_id;
            encoder_id = conn.encoder_id;

            log::info!("Using mode: {}x{} @{}Hz",
                modes[0].hdisplay, modes[0].vdisplay, modes[0].vrefresh);
            break;
        }
    }

    let mode = mode.ok_or("No connected display found")?;
    let width = mode.hdisplay as u32;
    let height = mode.vdisplay as u32;

    // Step 4: Get encoder to find CRTC
    log::info!("Getting encoder {}", encoder_id);
    let mut encoder = DrmModeGetEncoder {
        encoder_id,
        encoder_type: 0,
        crtc_id: 0,
        possible_crtcs: 0,
        possible_clones: 0,
    };
    ioctl_get_encoder(fd, &mut encoder)?;
    let crtc_id = encoder.crtc_id;
    log::info!("Using CRTC {}", crtc_id);

    // Step 5: Create dumb buffer
    log::info!("Creating dumb buffer {}x{}", width, height);
    let mut create = DrmModeCreateDumb {
        height,
        width,
        bpp: 32,
        flags: 0,
        handle: 0,
        pitch: 0,
        size: 0,
    };
    ioctl_create_dumb(fd, &mut create)?;
    log::info!("Created buffer: handle={}, pitch={}, size={}",
        create.handle, create.pitch, create.size);

    // Step 6: Map the dumb buffer
    log::info!("Mapping buffer");
    let mut map = DrmModeMapDumb {
        handle: create.handle,
        pad: 0,
        offset: 0,
    };
    ioctl_map_dumb(fd, &mut map)?;

    let map_ptr = unsafe {
        mmap(
            std::ptr::null_mut(),
            create.size as usize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            map.offset as i64,
        )
    };

    if map_ptr == MAP_FAILED {
        return Err("mmap failed".to_string());
    }

    log::info!("Buffer mapped successfully");

    // Step 7: Fill buffer with orange rectangle
    log::info!("Drawing orange rectangle");
    let pixels = unsafe {
        std::slice::from_raw_parts_mut(map_ptr as *mut u32, (create.size / 4) as usize)
    };

    // Orange color in XRGB8888 format (0xFFFF8800)
    let orange = 0x00FF8800u32;
    let black = 0x00000000u32;

    // Draw a centered orange rectangle (80% of screen size)
    let rect_width = (width * 8 / 10) as usize;
    let rect_height = (height * 8 / 10) as usize;
    let rect_x = (width as usize - rect_width) / 2;
    let rect_y = (height as usize - rect_height) / 2;

    for y in 0..height as usize {
        for x in 0..width as usize {
            let idx = y * (create.pitch as usize / 4) + x;
            if x >= rect_x && x < rect_x + rect_width &&
               y >= rect_y && y < rect_y + rect_height {
                pixels[idx] = orange;
            } else {
                pixels[idx] = black;
            }
        }
    }

    log::info!("Rectangle drawn");

    // Step 8: Create framebuffer
    log::info!("Creating framebuffer");
    let mut fb = DrmModeFB2 {
        fb_id: 0,
        width,
        height,
        pixel_format: DRM_FORMAT_XRGB8888,
        flags: 0,
        handles: [create.handle, 0, 0, 0],
        pitches: [create.pitch, 0, 0, 0],
        offsets: [0, 0, 0, 0],
        modifier: [0, 0, 0, 0],
    };
    ioctl_addfb2(fd, &mut fb)?;
    log::info!("Framebuffer created: fb_id={}", fb.fb_id);

    // Step 9: Set CRTC to display our framebuffer
    log::info!("Setting CRTC");
    let connectors = [connector_id];
    let mut crtc = DrmModeCrtc {
        set_connectors_ptr: connectors.as_ptr() as u64,
        count_connectors: 1,
        crtc_id,
        fb_id: fb.fb_id,
        x: 0,
        y: 0,
        gamma_size: 0,
        mode_valid: 1,
        mode,
    };
    ioctl_setcrtc(fd, &mut crtc)?;

    log::info!("CRTC configured - orange rectangle should be visible!");

    // Step 10: Wait a bit to see the result
    log::info!("Sleeping for 3 seconds");
    std::thread::sleep(std::time::Duration::from_secs(3));

    // Step 11: Cleanup
    log::info!("Cleaning up");
    unsafe {
        munmap(map_ptr, create.size as usize);
    }

    let mut destroy = DrmModeDestroyDumb {
        handle: create.handle,
    };
    ioctl_destroy_dumb(fd, &mut destroy)?;

    log::info!("Cleanup complete");
    Ok(())
}
