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

### Next Steps

Phase 4 will add Wayland server setup to accept client connections.
