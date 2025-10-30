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

### Next Steps

Phase 3 will add framebuffer allocation and rendering to display a solid color on screen.
