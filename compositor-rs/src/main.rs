use drm::control::{connector, Device as ControlDevice};
use drm::buffer::DrmFourcc;
use std::fs::{File, OpenOptions};
use std::os::unix::io::{AsFd, AsRawFd};

struct Card(File);

impl AsFd for Card {
    fn as_fd(&self) -> std::os::unix::io::BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl AsRawFd for Card {
    fn as_raw_fd(&self) -> std::os::unix::io::RawFd {
        self.0.as_raw_fd()
    }
}

impl drm::Device for Card {}
impl ControlDevice for Card {}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("compositor-rs v0.1.0 - Phase 3: Framebuffer Allocation");
    println!();

    let card_path = "/dev/dri/card0";
    println!("Opening DRM device: {}", card_path);
    
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(card_path)?;
    let card = Card(file);
    
    println!("✓ Successfully opened {}", card_path);
    println!();

    println!("Getting DRM resources...");
    let res = card.resource_handles()?;
    
    println!("✓ Found resources:");
    println!("  - Connectors: {}", res.connectors().len());
    println!("  - Encoders: {}", res.encoders().len());
    println!("  - CRTCs: {}", res.crtcs().len());
    println!("  - Framebuffers: {}", res.framebuffers().len());
    println!();

    // Find first connected connector
    println!("Finding connected connector...");
    let mut connector_handle = None;
    let mut mode = None;
    
    for conn_h in res.connectors() {
        let conn = card.get_connector(*conn_h, false)?;
        if conn.state() == connector::State::Connected {
            let modes = conn.modes();
            if !modes.is_empty() {
                connector_handle = Some(*conn_h);
                mode = Some(modes[0]);
                println!("✓ Found connector {:?}: {:?}", conn_h, conn.interface());
                println!("  Using mode: {}x{} @ {}Hz", 
                    modes[0].size().0, modes[0].size().1, modes[0].vrefresh());
                break;
            }
        }
    }
    
    let connector_handle = connector_handle.ok_or("No connected connector found")?;
    let mode = mode.ok_or("No mode available")?;
    let (width, height) = mode.size();
    println!();
    
    // Get encoder and CRTC
    println!("Getting encoder and CRTC...");
    let conn = card.get_connector(connector_handle, false)?;
    let encoder_handle = conn.current_encoder().ok_or("No encoder")?;
    let encoder = card.get_encoder(encoder_handle)?;
    let crtc_handle = encoder.crtc().ok_or("No CRTC")?;
    println!("✓ Using CRTC: {:?}", crtc_handle);
    println!();
    
    // Create dumb buffer
    println!("Creating dumb buffer {}x{}...", width, height);
    let mut db = card.create_dumb_buffer(
        (width as u32, height as u32),
        DrmFourcc::Xrgb8888,
        32
    )?;
    println!("✓ Created dumb buffer");
    println!();
    
    // Create framebuffer
    println!("Creating framebuffer...");
    let fb_handle = card.add_framebuffer(&db, 24, 32)?;
    println!("✓ Created framebuffer: {:?}", fb_handle);
    println!();
    
    // Map buffer and fill with orange color
    println!("Mapping buffer and filling with orange (#FF8800)...");
    let mut map = card.map_dumb_buffer(&mut db)?;
    let pixels = unsafe {
        std::slice::from_raw_parts_mut(
            map.as_mut_ptr() as *mut u32,
            (width * height) as usize
        )
    };
    
    // Fill with orange (XRGB8888 format: 0x00RRGGBB)
    for pixel in pixels.iter_mut() {
        *pixel = 0x00FF8800; // Orange
    }
    println!("✓ Buffer filled with orange color");
    println!();
    
    // Set CRTC to display framebuffer
    println!("Setting CRTC to display framebuffer...");
    card.set_crtc(
        crtc_handle,
        Some(fb_handle),
        (0, 0),
        &[connector_handle],
        Some(mode),
    )?;
    println!("✓ CRTC configured, displaying framebuffer!");
    println!();
    
    println!("Displaying orange screen for 10 seconds...");
    std::thread::sleep(std::time::Duration::from_secs(10));
    
    println!();
    println!("Phase 3 complete - Framebuffer rendering successful!");
    Ok(())
}
