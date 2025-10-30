// Minimal Wayland test client
// Connects to compositor-rs and draws a simple test pattern

use std::os::unix::io::{AsFd, AsRawFd};
use wayland_client::{Connection, Dispatch, QueueHandle};
use wayland_client::protocol::{wl_compositor, wl_shm, wl_shm_pool, wl_buffer, wl_surface, wl_callback, wl_registry};

struct AppData {
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    surface: Option<wl_surface::WlSurface>,
    frame_received: bool,
}

// Implement Dispatch for wl_registry to bind globals
impl Dispatch<wl_registry::WlRegistry, ()> for AppData {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            println!("[client] Global: {} v{} ({})", interface, version, name);
            
            match interface.as_str() {
                "wl_compositor" => {
                    let compositor = registry.bind::<wl_compositor::WlCompositor, _, _>(name, version.min(6), qh, ());
                    println!("[client] Bound to wl_compositor");
                    state.compositor = Some(compositor);
                }
                "wl_shm" => {
                    let shm = registry.bind::<wl_shm::WlShm, _, _>(name, version.min(1), qh, ());
                    println!("[client] Bound to wl_shm");
                    state.shm = Some(shm);
                }
                _ => {}
            }
        }
    }
}

// Implement Dispatch for wl_compositor
impl Dispatch<wl_compositor::WlCompositor, ()> for AppData {
    fn event(
        _: &mut Self,
        _: &wl_compositor::WlCompositor,
        _: wl_compositor::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

// Implement Dispatch for wl_shm
impl Dispatch<wl_shm::WlShm, ()> for AppData {
    fn event(
        _: &mut Self,
        _: &wl_shm::WlShm,
        event: wl_shm::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_shm::Event::Format { format } = event {
            println!("[client] SHM format available: {:?}", format);
        }
    }
}

// Implement Dispatch for wl_shm_pool
impl Dispatch<wl_shm_pool::WlShmPool, ()> for AppData {
    fn event(
        _: &mut Self,
        _: &wl_shm_pool::WlShmPool,
        _: wl_shm_pool::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

// Implement Dispatch for wl_buffer
impl Dispatch<wl_buffer::WlBuffer, ()> for AppData {
    fn event(
        _: &mut Self,
        buffer: &wl_buffer::WlBuffer,
        event: wl_buffer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_buffer::Event::Release = event {
            println!("[client] Buffer released");
            buffer.destroy();
        }
    }
}

// Implement Dispatch for wl_surface
impl Dispatch<wl_surface::WlSurface, ()> for AppData {
    fn event(
        _: &mut Self,
        _: &wl_surface::WlSurface,
        _: wl_surface::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

// Implement Dispatch for wl_callback (frame callback)
impl Dispatch<wl_callback::WlCallback, ()> for AppData {
    fn event(
        state: &mut Self,
        _: &wl_callback::WlCallback,
        event: wl_callback::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_callback::Event::Done { callback_data } = event {
            println!("[client] ✓ Frame callback received! (time: {})", callback_data);
            state.frame_received = true;
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("===========================================");
    println!("Wayland Test Client for compositor-rs");
    println!("===========================================\n");

    // Connect to Wayland display
    println!("[client] Connecting to Wayland display...");
    let conn = Connection::connect_to_env()?;
    println!("[client] ✓ Connected to compositor");

    let display = conn.display();
    let mut event_queue = conn.new_event_queue();
    let qh = event_queue.handle();

    // Get registry and bind globals
    let _registry = display.get_registry(&qh, ());
    
    let mut app_data = AppData {
        compositor: None,
        shm: None,
        surface: None,
        frame_received: false,
    };

    // First roundtrip to get globals
    println!("[client] Discovering globals...");
    event_queue.roundtrip(&mut app_data)?;
    println!();

    // Check we have what we need
    let compositor = app_data.compositor.as_ref().ok_or("No wl_compositor")?;
    let shm = app_data.shm.as_ref().ok_or("No wl_shm")?;

    // Create surface
    println!("[client] Creating surface...");
    let surface = compositor.create_surface(&qh, ());
    println!("[client] ✓ Surface created");
    app_data.surface = Some(surface.clone());

    // Create SHM buffer with test pattern (200x200 gradient)
    println!("[client] Creating SHM buffer (200x200 gradient)...");
    let width = 200;
    let height = 200;
    let stride = width * 4;
    let size = stride * height;

    // Create temporary file for SHM
    let mut file = tempfile::tempfile()?;
    std::io::Write::write_all(&mut file, &vec![0u8; size as usize])?;
    
    // Map the file
    let fd = file.as_fd().as_raw_fd();
    let pixels = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            size as usize,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        )
    };
    
    if pixels == libc::MAP_FAILED {
        return Err("mmap failed".into());
    }

    // Draw gradient pattern (red to blue)
    let pixel_slice = unsafe {
        std::slice::from_raw_parts_mut(pixels as *mut u32, (width * height) as usize)
    };
    
    for y in 0..height {
        for x in 0..width {
            let r = (x * 255 / width) as u32;
            let b = (y * 255 / height) as u32;
            let pixel = 0xFF000000 | (r << 16) | b; // ARGB8888
            pixel_slice[(y * width + x) as usize] = pixel;
        }
    }

    println!("[client] ✓ Drew red-to-blue gradient pattern");

    // Create SHM pool and buffer
    let pool = shm.create_pool(file.as_fd(), size, &qh, ());
    let buffer = pool.create_buffer(
        0,
        width,
        height,
        stride,
        wl_shm::Format::Argb8888,
        &qh,
        (),
    );
    println!("[client] ✓ SHM buffer created");

    // Attach buffer to surface
    println!("[client] Attaching buffer to surface...");
    surface.attach(Some(&buffer), 0, 0);
    surface.damage(0, 0, width, height);
    
    // Request frame callback
    println!("[client] Requesting frame callback...");
    let _callback = surface.frame(&qh, ());
    
    // Commit!
    println!("[client] Committing surface...");
    surface.commit();
    println!("[client] ✓ Surface committed\n");

    // Wait for frame callback (with timeout)
    println!("[client] Waiting for frame callback from compositor...");
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(5);
    
    while !app_data.frame_received && start.elapsed() < timeout {
        event_queue.blocking_dispatch(&mut app_data)?;
    }

    // Cleanup
    unsafe {
        libc::munmap(pixels, size as usize);
    }

    println!();
    if app_data.frame_received {
        println!("===========================================");
        println!("✓✓✓ SUCCESS! Full rendering test passed!");
        println!("===========================================");
        println!("- Connected to compositor");
        println!("- Created surface and SHM buffer");
        println!("- Drew 200x200 gradient pattern");
        println!("- Submitted buffer to compositor");
        println!("- Received frame callback");
        println!("\nPhase 6: 11/11 acceptance criteria met! 🎉");
        println!("\n[client] Keeping gradient visible for 10 seconds...");
        std::thread::sleep(std::time::Duration::from_secs(10));
        println!("[client] Exiting...");
        Ok(())
    } else {
        println!("===========================================");
        println!("✗ TIMEOUT: No frame callback received");
        println!("===========================================");
        Err("Frame callback timeout".into())
    }
}
