# boom - DRM Display Demo

A minimal repository demonstrating low-level DRM (Direct Rendering Manager) screen drawing on Android. This project focuses on the core functionality of drawing to the display using DRM, with a clean and simple codebase.

## Quick Start

Enter the Nix development shell:
```bash
nix develop
```

Create and boot the emulator:
```bash
just emu-create
just emu-boot
just emu-root  # Enables root access, disables dm-verity, and remounts /system
```

Run the DRM demo (fills screen with orange):
```bash
just run-drm-demo
```



## Components

### Core Display Components

- **`drm_rect`** - DRM-based screen drawing implementation
  - Uses the `drm` crate for KMS (Kernel Mode Setting)
  - Fills the entire display with a solid RGB color
  - Properly handles DRM connectors, encoders, and CRTCs
  - Clean, well-tested implementation

## Architecture

- **Apple Silicon**: Use arm64-v8a system images, builds for aarch64-linux-android
- **Intel**: Use x86_64 system images, builds for x86_64-linux-android

Auto-detection is built into all demo commands.

## Available Commands

Run `just` to see all available commands:

- `just build-drm-x86` / `just build-drm-arm64` - Build DRM demo
- `just run-drm-demo` - Run DRM demo on connected device
- `just emu-create` / `just emu-boot` / `just emu-root` / `just emu-stop` - Emulator management
- `just ci` - Run CI pipeline

## CI/CD

The project includes a robust CI pipeline that:
- Builds the DRM component for both architectures (x86_64 and aarch64)
- Runs formatting and linting checks
- Executes Cuttlefish boot tests (when cfctl is available)
- Validates that the core DRM functionality works

## Kernel Requirements

For DRM functionality, the emulator kernel needs:
- DRM/KMS support
- `/dev/dri/card0` device access

With the emulator running, verify DRM availability:
```bash
ls -la /dev/dri/
```

## Development Notes

### Emulator Bootstrap
- Always run `just emu-root` on a fresh or reset AVD before pushing binaries
- This issues `adb disable-verity` followed by `adb remount`, which requires a reboot
- If you wipe emulator data or recreate the device, `adb disable-verity` resets

### Display Management
The demo scripts properly handle Android's display system:
1. Stop SurfaceFlinger and hardware composer
2. Run the demo (DRM or framebuffer)
3. Restart display services
4. Handle SELinux permissions

### Error Handling
All components include comprehensive error handling:
- DRM device access failures
- Display mode detection
- Memory mapping errors
- Permission issues

## Testing

Run the full test suite:
```bash
just ci
```

Individual component testing:
```bash
cargo test --manifest-path rust/drm_rect/Cargo.toml
```

## Project Structure

```
├── rust/
│   └── drm_rect/          # DRM implementation
├── scripts/
│   ├── ci.sh              # CI pipeline
│   ├── check_kernel_features.sh
│   ├── cuttlefish_instance.sh
│   └── download_emulator_system.sh
├── plans/                 # Design documents
├── docs/                  # Documentation
└── justfile              # Build commands
```

This is a focused, minimal repository that demonstrates working DRM screen drawing without unnecessary complexity.