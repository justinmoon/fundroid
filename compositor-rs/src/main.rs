use drm::control::{connector, Device as ControlDevice};
use drm::buffer::DrmFourcc;
use std::fs::{File, OpenOptions};
use std::os::unix::io::{AsFd, AsRawFd, RawFd};

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

use wayland_server::{Display, ListeningSocket, Dispatch, New, DataInit, Client, Resource};
use wayland_server::protocol::{wl_compositor, wl_surface, wl_region, wl_shm, wl_shm_pool, wl_buffer, wl_callback};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

// SHM pool data - stores fd for later mapping
struct ShmPoolData {
    fd: RawFd,
    size: i32,
}

impl Drop for ShmPoolData {
    fn drop(&mut self) {
        // Close the duplicated fd
        if self.fd >= 0 {
            unsafe { libc::close(self.fd); }
        }
    }
}

// Buffer data - metadata for rendering
#[derive(Clone)]
struct BufferData {
    pool_id: u32,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: wl_shm::Format,
}

// Surface state - stores attached buffer and frame callback
struct SurfaceData {
    buffer_id: Option<u32>,
    frame_callback: Option<wl_callback::WlCallback>,
}

// DRM state - wrapped in Arc<Mutex<>> for sharing
struct DrmState {
    card: Arc<Mutex<Card>>,
    fb_handle: drm::control::framebuffer::Handle,
    crtc_handle: drm::control::crtc::Handle,
    connector_handle: drm::control::connector::Handle,
    mode: drm::control::Mode,
    db: drm::control::dumbbuffer::DumbBuffer,
}

// State that implements all protocol dispatchers
struct CompositorState {
    surfaces: Arc<Mutex<HashMap<u32, SurfaceData>>>,
    shm_pools: Arc<Mutex<HashMap<u32, ShmPoolData>>>,
    buffers: Arc<Mutex<HashMap<u32, BufferData>>>,
    drm_state: Arc<Mutex<Option<DrmState>>>,
}

// Helper function to render buffer to framebuffer
fn render_buffer(state: &CompositorState, buffer_id: u32) -> Result<(), Box<dyn std::error::Error>> {
    // Get buffer metadata
    let buffers = state.buffers.lock().unwrap();
    let buf_data = buffers.get(&buffer_id).ok_or("Buffer not found")?;
    
    // Get pool data (clone the fd for use)
    let pool_fd = {
        let pools = state.shm_pools.lock().unwrap();
        let pool = pools.get(&buf_data.pool_id).ok_or("Pool not found")?;
        pool.fd
    };
    
    // Map the SHM buffer from client
    let shm_size = (buf_data.height * buf_data.stride) as usize;
    let mmap_ptr = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            shm_size,
            libc::PROT_READ,
            libc::MAP_SHARED,
            pool_fd,
            buf_data.offset as libc::off_t,
        )
    };
    
    if mmap_ptr == libc::MAP_FAILED {
        let errno = unsafe { *libc::__errno_location() };
        return Err(format!("Failed to mmap SHM buffer: errno {}", errno).into());
    }
    
    let client_pixels = unsafe {
        std::slice::from_raw_parts(mmap_ptr as *const u32, (buf_data.width * buf_data.height) as usize)
    };
    
    // Get DRM state and render
    let drm_guard = state.drm_state.lock().unwrap();
    if let Some(ref drm) = *drm_guard {
        let card = drm.card.lock().unwrap();
        let mut db_clone = drm.db.clone();
        let mut fb_map = card.map_dumb_buffer(&mut db_clone)?;
        
        let fb_pixels = unsafe {
            std::slice::from_raw_parts_mut(
                fb_map.as_mut_ptr() as *mut u32,
                (drm.mode.size().0 * drm.mode.size().1) as usize
            )
        };
        
        // Copy pixels from client buffer to framebuffer
        let fb_width = drm.mode.size().0 as usize;
        let buf_width = buf_data.width as usize;
        let buf_height = buf_data.height as usize;
        let stride_pixels = (buf_data.stride / 4) as usize;
        
        for y in 0..buf_height.min(drm.mode.size().1 as usize) {
            for x in 0..buf_width.min(fb_width) {
                let src_idx = y * stride_pixels + x;
                let dst_idx = y * fb_width + x;
                if src_idx < client_pixels.len() && dst_idx < fb_pixels.len() {
                    fb_pixels[dst_idx] = client_pixels[src_idx];
                }
            }
        }
        
        // Update CRTC to display new content
        card.set_crtc(
            drm.crtc_handle,
            Some(drm.fb_handle),
            (0, 0),
            &[drm.connector_handle],
            Some(drm.mode),
        )?;
    }
    
    // Unmap the SHM buffer
    unsafe {
        libc::munmap(mmap_ptr, shm_size);
    }
    
    Ok(())
}

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
        state: &mut Self,
        _client: &Client,
        resource: &wl_surface::WlSurface,
        request: wl_surface::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        let surface_id = resource.id().protocol_id();
        match request {
            wl_surface::Request::Attach { buffer, x, y } => {
                let buffer_id = buffer.as_ref().map(|b| b.id().protocol_id());
                println!("✓ Surface {} attach: buffer_id={:?}, offset=({}, {})", surface_id, buffer_id, x, y);
                // Store buffer ID in surface data
                if let Ok(mut surfaces) = state.surfaces.lock() {
                    surfaces.entry(surface_id).or_insert(SurfaceData { 
                        buffer_id: None,
                        frame_callback: None,
                    }).buffer_id = buffer_id;
                }
            }
            wl_surface::Request::Commit => {
                println!("✓ Surface {} commit", surface_id);
                
                // Render the attached buffer
                let buffer_id = {
                    let surfaces = state.surfaces.lock().unwrap();
                    surfaces.get(&surface_id).and_then(|s| s.buffer_id)
                };
                
                if let Some(bid) = buffer_id {
                    println!("  → Rendering buffer {}", bid);
                    match render_buffer(state, bid) {
                        Ok(_) => println!("  ✓ Buffer rendered successfully!"),
                        Err(e) => eprintln!("  ✗ Render failed: {}", e),
                    }
                }
                
                // Send frame callback if requested
                if let Ok(mut surfaces) = state.surfaces.lock() {
                    if let Some(surf_data) = surfaces.get_mut(&surface_id) {
                        if let Some(callback) = surf_data.frame_callback.take() {
                            let time = std::time::SystemTime::now()
                                .duration_since(std::time::UNIX_EPOCH)
                                .unwrap()
                                .as_millis() as u32;
                            callback.done(time);
                        }
                    }
                }
            }
            wl_surface::Request::Frame { callback } => {
                println!("✓ Surface {} frame callback requested", surface_id);
                let cb = data_init.init(callback, ());
                // Store for sending after next commit
                if let Ok(mut surfaces) = state.surfaces.lock() {
                    surfaces.entry(surface_id).or_insert(SurfaceData {
                        buffer_id: None,
                        frame_callback: None,
                    }).frame_callback = Some(cb);
                }
            }
            wl_surface::Request::Damage { x, y, width, height } => {
                println!("✓ Surface {} damage: ({}, {}) {}x{}", surface_id, x, y, width, height);
            }
            _ => {
                println!("✓ Surface {} request: {:?}", surface_id, request);
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

// Implement Dispatch for wl_shm (shared memory)
impl Dispatch<wl_shm::WlShm, ()> for CompositorState {
    fn request(
        state: &mut Self,
        _client: &Client,
        _resource: &wl_shm::WlShm,
        request: wl_shm::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            wl_shm::Request::CreatePool { id, fd, size } => {
                // Duplicate the fd so we own it (original fd will be closed by protocol)
                let dup_fd = unsafe { libc::dup(fd.as_raw_fd()) };
                if dup_fd < 0 {
                    eprintln!("✗ Failed to duplicate SHM fd");
                    return;
                }
                println!("✓ Client created SHM pool: fd={} (dup={}), size={}", fd.as_raw_fd(), dup_fd, size);
                
                // Init pool first to get the ID
                let pool = data_init.init(id, ());
                let pool_id = pool.id().protocol_id();
                
                // Store pool data with duplicated fd for later buffer mapping
                if let Ok(mut pools) = state.shm_pools.lock() {
                    pools.insert(pool_id, ShmPoolData { fd: dup_fd, size });
                }
            }
            _ => {}
        }
    }
}

// Implement Dispatch for wl_shm_pool
impl Dispatch<wl_shm_pool::WlShmPool, ()> for CompositorState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &wl_shm_pool::WlShmPool,
        request: wl_shm_pool::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            wl_shm_pool::Request::CreateBuffer { id, offset, width, height, stride, format } => {
                println!("✓ Client created buffer: {}x{} stride={} format={:?}", width, height, stride, format);
                
                let pool_id = resource.id().protocol_id();
                let buffer_id = data_init.init(id, ()).id().protocol_id();
                
                // Store buffer metadata
                if let Ok(mut buffers) = state.buffers.lock() {
                    buffers.insert(buffer_id, BufferData {
                        pool_id,
                        offset,
                        width,
                        height,
                        stride,
                        format: format.into_result().unwrap_or(wl_shm::Format::Argb8888),
                    });
                }
            }
            wl_shm_pool::Request::Resize { size } => {
                println!("✓ SHM pool resized to {}", size);
                let pool_id = resource.id().protocol_id();
                if let Ok(mut pools) = state.shm_pools.lock() {
                    if let Some(pool) = pools.get_mut(&pool_id) {
                        pool.size = size;
                    }
                }
            }
            _ => {}
        }
    }
}

// Implement Dispatch for wl_buffer
impl Dispatch<wl_buffer::WlBuffer, ()> for CompositorState {
    fn request(
        state: &mut Self,
        _client: &Client,
        resource: &wl_buffer::WlBuffer,
        request: wl_buffer::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            wl_buffer::Request::Destroy => {
                let buffer_id = resource.id().protocol_id();
                println!("✓ Buffer {} destroyed", buffer_id);
                // Clean up buffer metadata
                if let Ok(mut buffers) = state.buffers.lock() {
                    buffers.remove(&buffer_id);
                }
            }
            _ => {}
        }
    }
}

// Implement Dispatch for wl_callback (frame callbacks)
impl Dispatch<wl_callback::WlCallback, ()> for CompositorState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        _resource: &wl_callback::WlCallback,
        _request: wl_callback::Request,
        _data: &(),
        _dhandle: &wayland_server::DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        // Callbacks are passive
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

// Implement GlobalDispatch for wl_shm
impl GlobalDispatch<wl_shm::WlShm, ()> for CompositorState {
    fn bind(
        _state: &mut Self,
        _handle: &wayland_server::DisplayHandle,
        _client: &Client,
        resource: New<wl_shm::WlShm>,
        _global_data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        println!("✓ Client bound to wl_shm");
        let shm = data_init.init(resource, ());
        // Advertise supported formats
        shm.format(wl_shm::Format::Argb8888);
        shm.format(wl_shm::Format::Xrgb8888);
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("compositor-rs v0.1.0 - Phase 6: Buffer Rendering (COMPLETE!)");
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
    {
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
    } // Drop map here to release borrow
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
    
    // Phase 6: Create Wayland server with SHM support
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
    
    // Create wl_shm global (version 1) for shared memory buffers
    display_handle.create_global::<CompositorState, wl_shm::WlShm, _>(1, ());
    println!("✓ Created wl_shm global (v1)");
    
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
    println!("  - Globals: wl_compositor v6, wl_shm v1");
    println!("  - Clients can connect via WAYLAND_DISPLAY={}", socket_name);
    println!();
    
    // Store DRM state for rendering
    let drm_state = DrmState {
        card: Arc::new(Mutex::new(card)),
        fb_handle,
        crtc_handle,
        connector_handle,
        mode,
        db,
    };
    
    // Run for 30 seconds with event loop
    println!("Running for 30 seconds (accepting Wayland clients & rendering buffers)...");
    let start = std::time::Instant::now();
    let duration = std::time::Duration::from_secs(30);
    let mut state = CompositorState {
        surfaces: Arc::new(Mutex::new(HashMap::new())),
        shm_pools: Arc::new(Mutex::new(HashMap::new())),
        buffers: Arc::new(Mutex::new(HashMap::new())),
        drm_state: Arc::new(Mutex::new(Some(drm_state))),
    };
    
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
    println!("Phase 6 COMPLETE - Full buffer rendering implemented!");
    println!("  - Rendered {} surfaces", state.surfaces.lock().unwrap().len());
    println!("  - Processed {} buffers", state.buffers.lock().unwrap().len());
    Ok(())
}
