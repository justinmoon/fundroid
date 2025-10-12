// Minimal DRM dumb buffer example for drawing a rectangle
// This will be used to test direct display access on Android/Cuttlefish

use std::fs::File;
use std::os::fd::AsRawFd;
use nix::fcntl::OFlag;
use nix::sys::stat::Mode;

fn main() {
    android_logger::init_once(android_logger::Config::default());
    log::info!("drm_rect: starting");

    // Try to open DRM device
    match nix::fcntl::open("/dev/dri/card0", OFlag::O_RDWR, Mode::empty()) {
        Ok(fd) => {
            log::info!("drm_rect: opened /dev/dri/card0 successfully (fd={})", fd);

            // TODO: Implement DRM operations:
            // 1. Query resources (DRM_IOCTL_MODE_GETRESOURCES)
            // 2. Find connected connector
            // 3. Create dumb buffer (DRM_IOCTL_MODE_CREATE_DUMB)
            // 4. Map buffer (DRM_IOCTL_MODE_MAP_DUMB)
            // 5. Fill with color (orange rectangle)
            // 6. Add framebuffer (DRM_IOCTL_MODE_ADDFB2)
            // 7. Set CRTC to display our buffer (DRM_IOCTL_MODE_SETCRTC)

            log::info!("drm_rect: DRM operations not yet implemented");
            std::thread::sleep(std::time::Duration::from_secs(2));

            // Clean up will be added with full implementation
        }
        Err(e) => {
            log::error!("drm_rect: failed to open /dev/dri/card0: {}", e);
        }
    }

    log::info!("drm_rect: exiting");
}
