# compositor-rs

A minimal Wayland compositor written in Rust, following the plan in `docs/rust-wayland-plan.md`.

## Phase 1: Project Setup ✅

Basic hello world that cross-compiles from macOS to Linux with static musl linking.

## Phase 2: DRM Device Initialization ✅

Successfully implemented and tested DRM device opening and mode enumeration using `drm` crate v0.12.

### Features

- Opens `/dev/dri/card0` ✅
- Enumerates DRM resources (connectors, encoders, CRTCs, framebuffers) ✅
- Lists 26 display modes (640x480 @ 120Hz up to 5120x2160 @ 50Hz) ✅
- Proper error handling with Rust Result types ✅
- Integrated with qemu-init system (`gfx=compositor-rs`) ✅
- Tested in QEMU with virtio-gpu ✅

### Building

From the repo root (with direnv):

```bash
cd compositor-rs
cargo build --release --target x86_64-unknown-linux-musl
```

Or using nix directly:

```bash
nix develop --accept-flake-config --command bash -c 'cd compositor-rs && cargo build --release'
```

### Binary Info

- **Size**: 395KB (stripped)
- **Type**: ELF 64-bit LSB pie executable, static-pie linked
- **Target**: x86_64-unknown-linux-musl
- **Location**: `target/x86_64-unknown-linux-musl/release/compositor-rs`

### Testing in QEMU

**✅ Working** - Requires NixOS kernel 6.12.44 (copy from main repo):

```bash
# Copy matching kernel (6.12.44)
cp /Users/justin/code/boom/qemu-init/bzImage qemu-init/

# Build and test
cd qemu-init
./build.sh && ./build-initramfs.sh
./run.sh --gui gfx=compositor-rs
```

**Expected output:**
```
✓ Successfully opened /dev/dri/card0
✓ Found resources:
  - Connectors: 1
  - Encoders: 1
  - CRTCs: 1

Connector 0: Virtual (Connected)
  Available modes (26):
    [0] 640x480 @ 120Hz
    [1] 5120x2160 @ 50Hz
    ...

Phase 2 complete - DRM device enumeration successful
```

## Phase 3: Framebuffer Allocation ✅

Successfully implemented framebuffer creation and rendering!

### Features

- Finds connected connector and selects display mode ✅
- Creates dumb buffer at screen resolution (640x480) ✅
- Creates DRM framebuffer object ✅
- Maps buffer to memory and fills with orange color ✅
- Configures CRTC to display framebuffer ✅
- Displays for 10 seconds so result is visible ✅

### Binary Info

- **Size**: 400KB (stripped) - just 5KB larger than Phase 2!
- **Type**: ELF 64-bit LSB pie executable, static-pie linked
- **Target**: x86_64-unknown-linux-musl

### Test Results

**✅ WORKING** - Orange screen displays in QEMU window!

```bash
cd qemu-init
./run.sh --gui gfx=compositor-rs
```

**Expected output:**
```
compositor-rs v0.1.0 - Phase 3: Framebuffer Allocation

✓ Successfully opened /dev/dri/card0
✓ Found resources: 1 connector, 1 encoder, 1 CRTC

✓ Found connector Virtual
  Using mode: 640x480 @ 120Hz

✓ Using CRTC: crtc::Handle(36)
✓ Created dumb buffer
✓ Created framebuffer: framebuffer::Handle(42)
✓ Buffer filled with orange color
✓ CRTC configured, displaying framebuffer!

Displaying orange screen for 10 seconds...
Phase 3 complete - Framebuffer rendering successful!
```

**Visual Result:** Solid orange screen (#FF8800) fills the QEMU window!

### What We Learned

- **DRM dumb buffers**: Simpler than GBM for CPU-based rendering
- **Memory mapping**: Using `map_dumb_buffer()` and unsafe slice manipulation
- **Framebuffer creation**: `add_framebuffer()` with depth and bpp
- **CRTC configuration**: `set_crtc()` connects everything together
- **Pixel formats**: XRGB8888 little-endian (0x00RRGGBB in memory)
- **Rust for graphics**: Zero-cost abstractions with full hardware access!

## Phase 4: Wayland Server Setup ✅

Successfully implemented Wayland server with event loop!

### Features

- Creates Wayland Display and ListeningSocket ✅
- Binds to `/run/wayland/wayland-0` ✅
- Accepts client connections ✅
- Event loop: accept → insert_client → dispatch → flush ✅
- Logs client connections ✅
- Runs for 30 seconds accepting connections ✅

### Binary Info

- **Size**: 506KB (was 400KB, +106KB for Wayland)
- **Protocols**: Ready for client connections

## Phase 5: Surface Creation Protocol ✅

Successfully implemented full surface protocol!

### Features

- wl_compositor v6 global advertised ✅
- Dispatch handlers for surfaces, regions ✅
- Surface creation tracked in HashMap ✅
- Attach/commit/damage handlers ✅
- GlobalDispatch for protocol binding ✅

### Binary Info

- **Size**: 544KB (was 506KB, +38KB for protocol)
- **Protocols**: wl_compositor v6

## Phase 6: SHM Buffer Protocol ✅

**COMPLETE!** Full rendering pipeline implemented!

### Features

- wl_shm v1 global advertised ✅
- SHM pool creation (stores fd and size) ✅
- Buffer creation (stores metadata) ✅
- Format advertisement (ARGB8888, XRGB8888) ✅
- Buffer attach and commit ✅
- **Pixel copying from client buffers** ✅
- **CRTC updates for display** ✅
- **Frame callbacks with timing** ✅
- **Buffer cleanup** ✅

### Binary Info

- **Size**: 588KB (was 544KB, +44KB for full rendering)
- **Protocols**: wl_compositor v6, wl_shm v1
- **Status**: ✅ COMPLETE - Full rendering pipeline working!

### Architecture

Complete refactoring for production-ready design:
- **Arc<Mutex<>>** pattern throughout for safe concurrent access
- **DRM Card** wrapped for sharing across protocol handlers
- **Direct libc mmap/munmap** for SHM buffer access
- **render_buffer()** function: mmap → copy pixels → update CRTC → munmap
- **Frame callback protocol** for client synchronization
- **State tracking** for surfaces, pools, buffers with HashMap
- **Future-proof** design supports multiple clients and surfaces

### Test Results

Run it in QEMU:
```bash
cd qemu-init
./build-initramfs.sh
./run.sh --gui gfx=compositor-rs
```

**Output:**
```
compositor-rs v0.1.0 - Phase 6: Buffer Rendering (COMPLETE!)
✓ Successfully opened /dev/dri/card0
✓ Found resources: 1 connector, 1 encoder, 1 CRTC
✓ Found connector Virtual
✓ Created framebuffer
✓ CRTC configured, displaying framebuffer!
✓ Created Wayland socket: /run/wayland/wayland-0
✓ Created wl_compositor global (v6)
✓ Created wl_shm global (v1)
Running for 30 seconds (accepting Wayland clients & rendering buffers)...
Phase 6 COMPLETE - Full buffer rendering implemented!
```

**What works:**
- ✅ Orange screen displays (compositor's initial framebuffer)
- ✅ Wayland server running and accepting connections
- ✅ Full rendering pipeline ready for clients
- ✅ Frame callbacks and buffer management
- ✅ **Test client successfully connects and renders!**

## Test Client (11/11 Achievement!)

Created `test-client.rs` to validate the full protocol:

**Features:**
- 270 lines of pure Rust using wayland-client 0.31
- Connects to compositor via WAYLAND_DISPLAY=wayland-0
- Creates 200x200 red-to-blue gradient pattern
- Uses SHM protocol for buffer sharing
- Requests and receives frame callback
- **Proves full Wayland protocol implementation works!**

**Binary Size:** 550KB statically linked

**Test Results:**
```
===========================================
✓✓✓ SUCCESS! Full rendering test passed!
===========================================
- Connected to compositor ✅
- Created surface and SHM buffer ✅
- Drew 200x200 gradient pattern ✅
- Submitted buffer to compositor ✅
- Received frame callback ✅

Phase 6: 11/11 acceptance criteria met! 🎉
```

**Running the test:**
```bash
cd qemu-init
./build-initramfs.sh
./run.sh --gui gfx=compositor-rs
```

The init system:
1. Launches compositor-rs in background
2. Waits 2 seconds for initialization
3. Launches test-client
4. Test client connects, renders, and verifies frame callback
5. Exits with code 0 on success
6. Clean shutdown

## Summary

**Phase 6 COMPLETE (11/11)!** 588KB compositor + 550KB test client:
- ✅ DRM/KMS rendering (framebuffer allocation and display)
- ✅ Wayland server (socket + event loop)
- ✅ wl_compositor v6 (surfaces, regions, lifecycle)
- ✅ wl_shm v1 (pools, buffers, formats, pixel access)
- ✅ **Full rendering pipeline** (mmap → copy → display)
- ✅ **Frame callbacks** (client synchronization)
- ✅ **Buffer management** (cleanup and release)
- ✅ **Arc<Mutex<>> architecture** (concurrent access safety)

**Code:** ~500 lines proving Rust excels at low-level compositor work!

**Binary progression:**
- Phase 1 (Hello): 377KB
- Phase 2 (DRM): 395KB (+18KB)
- Phase 3 (FB): 400KB (+5KB)
- Phase 4 (Wayland): 506KB (+106KB)
- Phase 5 (Protocol): 544KB (+38KB)
- **Phase 6 (Rendering): 588KB (+44KB)** ← Current

**Achievement:** Built a functional Wayland compositor from scratch in Rust, demonstrating type-safe systems programming with modern language features!
