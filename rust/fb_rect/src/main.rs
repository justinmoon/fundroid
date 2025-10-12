use anyhow::{Context, Result};
use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;

fn main() -> Result<()> {
    android_logger::init_once(android_logger::Config::default());
    log::info!("fb_rect: attempting to open framebuffer");

    // Try to open the framebuffer device
    let fb_path = "/dev/graphics/fb0";
    let fb_file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(fb_path)
        .context("Failed to open framebuffer device")?;

    log::info!("fb_rect: opened {}", fb_path);

    // Get framebuffer info
    let fd = fb_file.as_raw_fd();
    let mut vinfo: fb_var_screeninfo = unsafe { std::mem::zeroed() };

    unsafe {
        if libc::ioctl(fd, FBIOGET_VSCREENINFO as i32, &mut vinfo) == -1 {
            anyhow::bail!("Failed to get variable screen info");
        }
    }

    let width = vinfo.xres as usize;
    let height = vinfo.yres as usize;
    let bpp = vinfo.bits_per_pixel as usize;

    log::info!(
        "fb_rect: framebuffer info: {}x{} @ {} bpp",
        width,
        height,
        bpp
    );

    // Calculate buffer size
    let bytes_per_pixel = bpp / 8;
    let buffer_size = width * height * bytes_per_pixel;

    // Map the framebuffer
    let fb_mem = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            buffer_size,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        )
    };

    if fb_mem == libc::MAP_FAILED {
        anyhow::bail!("Failed to mmap framebuffer");
    }

    log::info!("fb_rect: mapped framebuffer memory");

    // Draw an orange rectangle in the center
    let rect_width = width / 2;
    let rect_height = height / 2;
    let rect_x = (width - rect_width) / 2;
    let rect_y = (height - rect_height) / 2;

    let fb_slice = unsafe {
        std::slice::from_raw_parts_mut(fb_mem as *mut u32, width * height)
    };

    // Fill with orange (ARGB: 0xFFFF8800)
    let orange = 0xFFFF8800u32;

    for y in rect_y..(rect_y + rect_height) {
        for x in rect_x..(rect_x + rect_width) {
            fb_slice[y * width + x] = orange;
        }
    }

    log::info!(
        "fb_rect: drew orange rectangle at ({},{}) size {}x{}",
        rect_x,
        rect_y,
        rect_width,
        rect_height
    );

    // Keep the program running so the rectangle stays visible
    log::info!("fb_rect: sleeping to keep rectangle visible...");
    std::thread::sleep(std::time::Duration::from_secs(3600));

    // Cleanup
    unsafe {
        libc::munmap(fb_mem, buffer_size);
    }

    Ok(())
}

// ioctl constants for framebuffer
const FBIOGET_VSCREENINFO: u32 = 0x4600;

// We need to define the fb_var_screeninfo struct since it's not in libc
#[repr(C)]
#[allow(non_camel_case_types)]
struct fb_var_screeninfo {
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
    reserved: [u32; 4],
}

#[repr(C)]
#[allow(non_camel_case_types)]
struct fb_bitfield {
    offset: u32,
    length: u32,
    msb_right: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fb_var_screeninfo_size() {
        // Verify the struct has the correct size for C interop
        // This helps catch alignment issues
        let size = std::mem::size_of::<fb_var_screeninfo>();
        // The struct should be at least this big (160 bytes minimum)
        assert!(size >= 160);
    }

    #[test]
    fn test_fb_bitfield_size() {
        // Verify fb_bitfield struct size
        let size = std::mem::size_of::<fb_bitfield>();
        assert_eq!(size, 12); // 3 u32s = 12 bytes
    }

    #[test]
    fn test_orange_color_constant() {
        // Verify the orange color is in correct ARGB format
        let orange = 0xFFFF8800u32;
        let alpha = (orange >> 24) & 0xFF;
        let red = (orange >> 16) & 0xFF;
        let green = (orange >> 8) & 0xFF;
        let blue = orange & 0xFF;

        assert_eq!(alpha, 0xFF); // Fully opaque
        assert_eq!(red, 0xFF);   // Full red
        assert_eq!(green, 0x88); // Half green
        assert_eq!(blue, 0x00);  // No blue
    }

    #[test]
    fn test_rect_calculations() {
        // Test rectangle calculation logic
        let width = 1080;
        let height = 1920;

        let rect_width = width / 2;
        let rect_height = height / 2;
        let rect_x = (width - rect_width) / 2;
        let rect_y = (height - rect_height) / 2;

        assert_eq!(rect_width, 540);
        assert_eq!(rect_height, 960);
        assert_eq!(rect_x, 270);
        assert_eq!(rect_y, 480);

        // Ensure rectangle is within bounds
        assert!(rect_x + rect_width <= width);
        assert!(rect_y + rect_height <= height);
    }

    #[test]
    fn test_ioctl_constant() {
        // Verify FBIOGET_VSCREENINFO is defined
        assert_eq!(FBIOGET_VSCREENINFO, 0x4600);
    }
}
