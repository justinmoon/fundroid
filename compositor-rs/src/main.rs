use drm::control::{connector, Device as ControlDevice};
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
    println!("compositor-rs v0.1.0 - Phase 2: DRM Device Initialization");
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

    println!("Enumerating connectors...");
    for (i, conn_handle) in res.connectors().iter().enumerate() {
        let conn = card.get_connector(*conn_handle, false)?;
        let state = conn.state();
        
        println!("  Connector {}: {:?}", i, conn_handle);
        println!("    Type: {:?}", conn.interface());
        println!("    State: {:?}", state);
        
        if state == connector::State::Connected {
            println!("    ✓ CONNECTED");
            let modes = conn.modes();
            println!("    Available modes ({}):", modes.len());
            for (j, mode) in modes.iter().enumerate() {
                println!("      [{}] {}x{} @ {}Hz", 
                    j, 
                    mode.size().0, 
                    mode.size().1,
                    mode.vrefresh());
            }
        }
        println!();
    }

    println!("Phase 2 complete - DRM device enumeration successful");
    Ok(())
}
