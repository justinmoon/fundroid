# Pure Rust Wayland Compositor Plan

## Prerequisites
✅ Complete Weston integration (phases 1-9 of weston-plan.md)
✅ Understand compositor fundamentals from running Weston
✅ Have working DRM stack (kernel modules, virtio-gpu)

## Goal
Build a minimal Wayland compositor in Rust using Smithay that:
- Renders directly to DRM (no Weston, no X11)
- Accepts one Wayland client
- Handles keyboard and mouse input
- Proves Rust can do what C does

## Why This Matters
- **Learn Smithay:** Used by real compositors (cosmic, niri)
- **Compare approaches:** C (Weston) vs Rust (Smithay) side-by-side
- **Modern patterns:** See how Rust's type system helps with Wayland
- **Foundation for future:** Could add Vello/Parley later

## Non-Goals (For Now)
❌ Replace Weston (it works, keep it)
❌ Window management (tiling, floating, etc.)
❌ Multiple outputs or complex configurations
❌ Vello or Parley integration (phase 2)
❌ Production-ready compositor

## Architecture

```
┌─────────────────────────────────────┐
│ weston-terminal (Wayland client)    │
│         ↓ Wayland protocol           │
├─────────────────────────────────────┤
│ compositor-rs (our Rust code)       │
│   - Smithay compositor toolkit      │
│   - drm-rs (DRM bindings)           │
│   - input-rs (libinput bindings)    │
│         ↓                            │
├─────────────────────────────────────┤
│ /dev/dri/card0 (virtio-gpu)         │
│ /dev/input/* (keyboard, mouse)      │
└─────────────────────────────────────┘
```

---

## Phase-by-Phase Plan

### Phase 1: Project Setup ✅
**Goal:** Create Rust project that compiles to static Linux binary.

**Tasks:**
1. ✅ Create `compositor-rs/` directory (top-level, not in qemu-init)
2. ✅ Initialize cargo project: `cargo init --name compositor-rs`
3. ✅ Configure for static linking (musl target)
4. ✅ Add musl target to flake.nix rust configuration
5. ✅ Create hello world that prints and exits
6. ✅ Test cross-compilation from macOS to Linux with rust-lld

**Dependencies:**
```toml
[dependencies]
# Phase 1: No dependencies yet - just hello world
# Will add smithay, drm, gbm, input, wayland-server in Phase 2+
```

**Build command:**
```bash
cargo build --release --target x86_64-unknown-linux-musl
```

**Acceptance Criteria:**
- [x] Cargo project created and builds successfully
- [x] Binary is statically linked (static-pie, check with `file` command)
- [x] Binary size: 377KB (well under 5MB target!)
- [x] Cross-compilation works from macOS using rust-lld
- [ ] Can copy binary to initramfs and execute from init (deferred to Phase 2)
- [ ] Basic logging works (will test in Phase 2 when running in QEMU)

**What you learned:**
- Rust cross-compilation setup with nix flake
- Static linking with musl using rust-lld
- Cargo project structure
- Nix rust-overlay target configuration

---

### Phase 2: DRM Device Initialization
**Goal:** Open `/dev/dri/card0` and enumerate display modes.

**Tasks:**
1. Use `drm` crate to open device
2. Get DRM resources (connectors, encoders, CRTCs)
3. Find connected connector and available modes
4. Print mode information to console
5. Clean shutdown (close device)

**Key code:**
```rust
use drm::Device;
use drm::control::Device as ControlDevice;

fn main() -> Result<(), Box<dyn Error>> {
    // Open DRM device
    let drm = drm::Device::open("/dev/dri/card0")?;
    
    // Get resources
    let res = drm.resource_handles()?;
    
    // Find connector
    for conn_handle in res.connectors() {
        let conn = drm.get_connector(*conn_handle)?;
        if conn.state() == ConnectorState::Connected {
            println!("Found connector: {:?}", conn);
            println!("Available modes: {:?}", conn.modes());
        }
    }
    
    Ok(())
}
```

**Acceptance Criteria:**
- [ ] Successfully opens `/dev/dri/card0`
- [ ] Enumerates connectors and finds Virtual-1
- [ ] Lists available display modes
- [ ] Logs match what we saw in Weston (640x480, etc.)
- [ ] No memory leaks or panics
- [ ] Can run multiple times without errors

**What you'll learn:**
- drm-rs API vs raw C libdrm
- Rust error handling with Result
- DRM resource discovery

---

### Phase 3: Framebuffer Allocation
**Goal:** Create a DRM framebuffer we can render into.

**Tasks:**
1. Use `gbm` crate to create buffer manager
2. Allocate a dumb buffer (CPU-accessible)
3. Create DRM framebuffer object
4. Map buffer to memory
5. Fill with solid color (like drm_rect did)
6. Set CRTC to display framebuffer

**Key code:**
```rust
use gbm::{Device as GbmDevice, BufferObjectFlags};

// Create GBM device
let gbm = GbmDevice::new(drm)?;

// Allocate buffer
let bo = gbm.create_buffer_object::<()>(
    width, height,
    gbm::Format::Xrgb8888,
    BufferObjectFlags::RENDERING | BufferObjectFlags::SCANOUT
)?;

// Map and fill with color
let map = bo.map(...)?;
for pixel in map.as_mut_slice() {
    *pixel = 0xFF0000; // Red
}

// Create framebuffer and display
let fb = drm.add_framebuffer(&bo, ...)?;
drm.set_crtc(crtc, fb, ...)?;
```

**Acceptance Criteria:**
- [ ] GBM device created successfully
- [ ] Buffer allocated at screen resolution
- [ ] Memory mapping works
- [ ] Solid color fills buffer
- [ ] QEMU window shows colored screen
- [ ] Color persists (no flickering)

**What you'll learn:**
- GBM buffer management
- Memory mapping in Rust
- DRM framebuffer creation

---

### Phase 4: Wayland Server Setup
**Goal:** Create Wayland socket and accept client connections.

**Tasks:**
1. Create Wayland display object
2. Bind to socket (usually `wayland-0`)
3. Implement compositor global
4. Handle client connections
5. Log when client connects
6. Don't render anything yet, just accept connection

**Key code:**
```rust
use wayland_server::{Display, Global};
use smithay::wayland::compositor::CompositorHandler;

struct State {
    // Will hold compositor state
}

impl CompositorHandler for State {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor_state
    }
    
    fn client_compositor_state<'a>(&self, client: &'a Client) 
        -> &'a CompositorClientState {
        // ...
    }
}

fn main() {
    let mut display = Display::new().unwrap();
    
    // Create socket at /run/wayland/wayland-0
    let socket = display.add_socket_auto().unwrap();
    println!("Listening on: {}", socket);
    
    // Event loop
    loop {
        display.dispatch_clients(&mut state).unwrap();
    }
}
```

**Acceptance Criteria:**
- [ ] Socket created at `/run/wayland/wayland-0`
- [ ] Can connect with `WAYLAND_DISPLAY=wayland-0 weston-info`
- [ ] Compositor global advertised to clients
- [ ] Client connection logged to console
- [ ] No crashes when client connects/disconnects
- [ ] Multiple connect/disconnect cycles work

**What you'll learn:**
- Wayland server setup
- Socket-based IPC
- Smithay compositor abstractions
- Event loop basics

---

### Phase 5: Surface Creation
**Goal:** Accept wl_surface objects from clients.

**Tasks:**
1. Implement wl_compositor interface
2. Handle wl_surface.create requests
3. Store surface in state
4. Handle wl_surface.attach (buffer attachment)
5. Handle wl_surface.commit
6. Log surface lifecycle events

**Key code:**
```rust
impl CompositorHandler for State {
    fn new_surface(&mut self, surface: &WlSurface) {
        println!("Client created surface: {:?}", surface);
    }
    
    fn commit(&mut self, surface: &WlSurface) {
        println!("Client committed surface: {:?}", surface);
        
        // Get attached buffer
        if let Some(buffer) = compositor::get_buffer(surface) {
            println!("Buffer attached: {:?}", buffer);
            // Will render this in next phase
        }
    }
}
```

**Acceptance Criteria:**
- [ ] wl_compositor global advertised
- [ ] Client can create wl_surface
- [ ] Surface stored in compositor state
- [ ] attach/commit sequence logged
- [ ] Buffer metadata accessible (size, format)
- [ ] No crashes with invalid client requests

**What you'll learn:**
- Wayland protocol object lifecycle
- Surface/buffer relationship
- Commit/attach semantics

---

### Phase 6: Buffer Rendering
**Goal:** Copy client buffer to framebuffer and display it.

**Tasks:**
1. Get client buffer data (SHM or DMA-BUF)
2. Convert to XRGB8888 if needed
3. Copy to our framebuffer
4. Page flip to display
5. Send frame callbacks to client
6. Handle buffer release

**Key code:**
```rust
fn render_surface(&mut self, surface: &WlSurface) {
    // Get client buffer
    let buffer = compositor::get_buffer(surface).unwrap();
    
    // Lock buffer for reading
    let data = buffer.data().unwrap();
    
    // Copy to our framebuffer
    let fb_map = self.framebuffer.map().unwrap();
    fb_map.copy_from_slice(data);
    
    // Page flip
    self.drm.page_flip(self.crtc, self.fb).unwrap();
    
    // Send frame callback
    surface.send_frame(timestamp);
    
    // Release buffer
    buffer.release();
}
```

**Acceptance Criteria:**
- [ ] Client buffer data accessible
- [ ] Pixels copied to framebuffer
- [ ] QEMU window shows client content (not just solid color)
- [ ] Frame callbacks sent (client keeps rendering)
- [ ] No tearing or corruption
- [ ] Can run weston-simple-shm successfully

**What you'll learn:**
- Wayland buffer protocol
- SHM (shared memory) buffer handling
- Frame callbacks and timing
- Buffer lifecycle management

---

### Phase 7: Input Event Handling
**Goal:** Forward keyboard and mouse events to focused client.

**Tasks:**
1. Initialize libinput
2. Open input devices via seatd or direct
3. Read input events in event loop
4. Convert to Wayland events
5. Send to focused surface
6. Handle focus changes

**Key code:**
```rust
use input::{Libinput, LibinputInterface};

// Initialize libinput
let mut libinput = Libinput::new_with_udev(interface);
libinput.udev_assign_seat("seat0").unwrap();

// Event loop
loop {
    libinput.dispatch().unwrap();
    
    while let Some(event) = libinput.next() {
        match event {
            Event::Pointer(PointerEvent::Motion(e)) => {
                let dx = e.dx();
                let dy = e.dy();
                // Send to focused surface
                pointer.motion(surface, dx, dy);
            }
            Event::Keyboard(KeyboardEvent::Key(e)) => {
                let key = e.key();
                let state = e.key_state();
                keyboard.key(surface, key, state);
            }
            _ => {}
        }
    }
}
```

**Acceptance Criteria:**
- [ ] libinput initializes successfully
- [ ] Mouse movement events received
- [ ] Keyboard key events received
- [ ] Events forwarded to client surface
- [ ] Mouse cursor moves in client (if client draws cursor)
- [ ] Keyboard input appears in weston-terminal

**What you'll learn:**
- libinput integration
- Input event translation
- Wayland seat/pointer/keyboard protocol
- Focus management

---

### Phase 8: Integration with Init
**Goal:** Launch compositor from init via `gfx=compositor-rs`.

**Tasks:**
1. Add compositor-rs binary to initramfs
2. Parse `gfx=compositor-rs` in init.zig
3. Fork and exec compositor
4. Set environment variables (XDG_RUNTIME_DIR, etc.)
5. Log compositor startup/shutdown
6. Add respawn logic (like Weston)

**Acceptance Criteria:**
- [ ] `./run.sh --gui gfx=compositor-rs` boots compositor
- [ ] Init spawns compositor correctly
- [ ] Environment variables set properly
- [ ] Compositor output visible in serial console
- [ ] Can kill compositor and init respawns it
- [ ] Weston mode still works (regression test)

**What you'll learn:**
- Multi-compositor init support
- Process supervision patterns
- Environment management

---

### Phase 9: Run Demo Application
**Goal:** Successfully run weston-terminal in our compositor.

**Tasks:**
1. Include weston-terminal in weston-rootfs
2. Auto-launch terminal from compositor
3. See terminal window rendered
4. Type in terminal, verify keyboard works
5. Move mouse, verify cursor/focus works
6. Take screenshot as proof

**Acceptance Criteria:**
- [ ] weston-terminal starts automatically
- [ ] Terminal window visible in QEMU
- [ ] Can type characters in terminal
- [ ] Shell prompt appears (even if commands don't work)
- [ ] Mouse events work (if terminal supports them)
- [ ] Terminal can be closed and respawned

**What you'll learn:**
- Full Wayland client/compositor interaction
- Terminal protocol requirements
- Real-world compositor testing

---

### Phase 10: Comparison and Documentation
**Goal:** Compare Rust vs C approach and document learnings.

**Tasks:**
1. Create comparison doc: Weston vs compositor-rs
2. Measure binary sizes
3. Compare code complexity (lines of code)
4. Note pain points in each approach
5. Document performance observations
6. Write blog post or notes on learnings

**Metrics to collect:**
- Binary size (stripped)
- Memory usage at runtime
- Startup time
- Code lines (excluding dependencies)
- Compile time
- Ease of debugging

**Acceptance Criteria:**
- [ ] Side-by-side feature comparison documented
- [ ] Performance metrics collected
- [ ] Pros/cons of each approach listed
- [ ] Learnings written up
- [ ] Code committed with clear README

**What you'll learn:**
- Rust vs C trade-offs in systems programming
- Ecosystem maturity comparison
- When to choose each approach

---

## Success Metrics

### Minimum Viable Compositor (MVP)
- Opens DRM device and creates framebuffer
- Accepts Wayland client connections
- Renders one client window
- Forwards keyboard/mouse input
- Runs weston-terminal successfully

### Stretch Goals
- Multiple windows (basic stacking)
- Clean shutdown without memory leaks
- Error handling (graceful failures)
- Performance profiling
- Integration tests

---

## Expected Timeline

**Conservative estimate:**
- Phase 1: 2-3 hours (setup)
- Phase 2: 2-3 hours (DRM)
- Phase 3: 2-4 hours (framebuffer)
- Phase 4: 3-4 hours (Wayland server)
- Phase 5: 2-3 hours (surfaces)
- Phase 6: 4-6 hours (rendering - hardest part)
- Phase 7: 3-4 hours (input)
- Phase 8: 1-2 hours (init integration)
- Phase 9: 1-2 hours (demo app)
- Phase 10: 2-3 hours (docs)

**Total: ~2-3 focused days**

---

## Common Issues

### Issue: "Cannot open /dev/dri/card0"
- Run after virtio-gpu modules loaded
- Check permissions (may need seatd)

### Issue: "Failed to create GBM device"
- Ensure mesa-dri installed
- Check for GBM support in drm crate

### Issue: "Client connects but nothing renders"
- Check buffer format conversion
- Verify page flip happening
- Send frame callbacks to client

### Issue: "Input events not working"
- Start seatd before compositor
- Check /dev/input permissions
- Verify libinput udev integration

---

## Future Phases (Not in Scope Yet)

### Vello Integration
- Render decorations with Vello
- Composite Vello output + client buffers
- Window shadows and effects

### Parley Text
- Window titles using Parley
- Font rendering
- Text layout for UI

### Advanced Features
- Multiple outputs
- Window management (tiling, floating)
- Shell protocol (panels, backgrounds)
- Screensharing

---

## Why This Order

1. **DRM first** - Proves hardware access works
2. **Rendering** - Visual feedback loop
3. **Wayland** - Protocol is complex, needs working display
4. **Input** - Easier to debug with visible output
5. **Integration** - Once it works standalone
6. **Comparison** - After both C and Rust working

This mirrors how we built drm_rect → Weston, applying learnings from C to Rust.

---

## Resources

- **Smithay docs:** https://smithay.github.io/
- **Smithay examples:** https://github.com/Smithay/smithay/tree/master/smallvil
- **Wayland book:** https://wayland-book.com/
- **drm-rs docs:** https://docs.rs/drm/
- **input-rs docs:** https://docs.rs/input/

## Success Definition

**This experiment succeeds if:**
- You understand Smithay architecture
- Can compare Rust vs C compositor approaches
- See path to modern Rust graphics (Vello/Parley)
- Have foundation to evaluate Rust for real projects

**This experiment fails if:**
- Gets stuck on basic issues (DRM, Wayland)
- Takes more than 5 days (scope creep)
- Doesn't teach anything new vs Weston
- Blocks progress on real goals (Cuttlefish)

Keep scope tight, move fast, learn deeply!
