# compositor-rs

A minimal Wayland compositor written in Rust, following the plan in `docs/rust-wayland-plan.md`.

## Phase 1: Project Setup ✅

Basic hello world that cross-compiles from macOS to Linux with static musl linking.

## Phase 2: DRM Device Initialization 🚧

Implemented DRM device opening and mode enumeration using `drm` crate v0.12.

### Features

- Opens `/dev/dri/card0`
- Enumerates DRM resources (connectors, encoders, CRTCs, framebuffers)
- Lists available display modes with resolution and refresh rate
- Proper error handling with Rust Result types
- Integrated with qemu-init system (`gfx=compositor-rs`)

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

### Testing Status

**Code complete** but QEMU testing blocked on kernel module version mismatch:
- Debian kernel 6.12.43 requires virtio-gpu module
- Available modules are built for 6.12.44
- Need matching kernel modules or kernel with CONFIG_DRM_VIRTIO_GPU=y built-in

### Next Steps

Phase 3 will add framebuffer allocation and rendering (requires working DRM device).
