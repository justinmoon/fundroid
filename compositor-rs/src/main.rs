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

use wayland_server::{Display, ListeningSocket, Dispatch, New, DataInit, Client};
use wayland_server::protocol::{wl_compositor, wl_surface, wl_region};

// State that implements all protocol dispatchers
struct CompositorState;

// Implement Dispatch for wl_compositor
impl Dispatch<wl_compositor::WlCompositor, ()> for CompositorState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &wl_compositor::WlCompositor,
        request: wl_compositor::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            wl_compositor::Request::CreateSurface { id } => {
                println!("✓ Client requested surface creation");
                let _surface = data_init.init(id, ());
            }
            wl_compositor::Request::CreateRegion { id } => {
                println!("✓ Client requested region creation");
                let _region = data_init.init(id, ());
            }
            _ => {}
        }
    }
}

// Implement Dispatch for wl_surface
impl Dispatch<wl_surface::WlSurface, ()> for CompositorState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &wl_surface::WlSurface,
        request: wl_surface::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            wl_surface::Request::Attach { buffer, x, y } => {
                println!("✓ Surface attach: buffer={:?}, offset=({}, {})", buffer, x, y);
            }
            wl_surface::Request::Commit => {
                println!("✓ Surface commit");
            }
            wl_surface::Request::Damage { x, y, width, height } => {
                println!("✓ Surface damage: ({}, {}) {}x{}", x, y, width, height);
            }
            _ => {
                println!("✓ Surface request: {:?}", request);
            }
        }
    }
}

// Implement Dispatch for wl_region (required by wl_compositor)
impl Dispatch<wl_region::WlRegion, ()> for CompositorState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &wl_region::WlRegion,
        _request: wl_region::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        // We don't use regions yet, just silently accept
    }
}

// Implement GlobalDispatch for wl_compositor
use wayland_server::GlobalDispatch;

impl GlobalDispatch<wl_compositor::WlCompositor, ()> for CompositorState {
    fn bind(
        _state: &mut Self,
        _handle: &wayland_server::DisplayHandle,
        _client: &Client,
        resource: New<wl_compositor::WlCompositor>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        println!("✓ Client bound to wl_compositor");
        data_init.init(resource, ());
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("compositor-rs v0.1.0 - Phase 5: Surface Creation");
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
    
    // Phase 5: Create Wayland server with protocol support
    println!("Creating Wayland server...");
    
    // Set XDG_RUNTIME_DIR to /run/wayland
    std::env::set_var("XDG_RUNTIME_DIR", "/run/wayland");
    std::fs::create_dir_all("/run/wayland").ok();
    
    // Create display with CompositorState
    let mut display: Display<CompositorState> = Display::new()?;
    let mut display_handle = display.handle();
    
    // Create wl_compositor global (version 6)
    display_handle.create_global::<CompositorState, wl_compositor::WlCompositor, _>(6, ());
    println!("✓ Created wl_compositor global (v6)");
    
    // Create listening socket
    let socket = ListeningSocket::bind("wayland-0")?;
    let socket_name = socket.socket_name()
        .and_then(|s| s.to_str())
        .unwrap_or("wayland-0");
    
    println!("✓ Created Wayland socket: /run/wayland/{}", socket_name);
    println!();
    println!("Compositor ready!");
    println!("  - Display: Orange screen at 640x480");
    println!("  - Socket: /run/wayland/{}", socket_name);
    println!("  - Globals: wl_compositor v6");
    println!("  - Clients can connect via WAYLAND_DISPLAY={}", socket_name);
    println!();
    
    // Run for 30 seconds with event loop
    println!("Running for 30 seconds (accepting Wayland clients & surfaces)...");
    let start = std::time::Instant::now();
    let duration = std::time::Duration::from_secs(30);
    let mut state = CompositorState;
    
    while start.elapsed() < duration {
        // Check for new client connections
        if let Ok(Some(stream)) = socket.accept() {
            // Insert client into display
            match display_handle.insert_client(stream, std::sync::Arc::new(())) {
                Ok(client) => {
                    println!("✓ New client connected: {:?}", client.id());
                }
                Err(e) => {
                    eprintln!("Error inserting client: {}", e);
                }
            }
        }
        
        // Dispatch pending client requests
        match display.dispatch_clients(&mut state) {
            Ok(_) => {},
            Err(e) => {
                eprintln!("Error dispatching clients: {}", e);
            }
        }
        
        // Flush client messages
        display.flush_clients()?;
        
        // Small sleep to avoid busy-waiting
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    
    println!();
    println!("Phase 5 complete - Surface protocol handled successfully!");
    Ok(())
}
