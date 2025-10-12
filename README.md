# WebOS - A Modern Web Browser OS

A custom Android-based operating system built from AOSP that reimagines web browsing with native Nostr integration, Bitcoin payments, TypeScript support, and embedded SQLite databases.

## Vision

WebOS keeps the best of the dying old web (HTML, CSS, TypeScript) while abandoning centralized dependencies like DNS and certificate authorities. It's Nostr-native, giving every user a private key and making Bitcoin payments first-class citizens.

## Architecture

- **Base**: AOSP (Android Open Source Project) with custom product overlay
- **Runtime**: Rust-based system daemon (`webosd`) that replaces the Android framework
- **Display**: Direct DRM/KMS rendering (no Zygote/SystemServer overhead)
- **Development**: Nix-based reproducible builds with cross-platform support

## Project Structure

```
webos/
├── flake.nix              # Nix development environments (macOS + Linux AOSP)
├── justfile               # Build automation tasks
├── vendor/webos/          # AOSP product overlay
│   ├── AndroidProducts.mk
│   ├── webos_cf.mk       # Product definition for Cuttlefish
│   ├── init.webosd.rc    # Init script (disables framework, starts webosd)
│   └── webosd/           # System daemon (AOSP build)
│       ├── Android.bp
│       └── src/main.rs
├── rust/
│   ├── drm_rect/         # Standalone DRM drawing demo
│   └── webosd/           # Standalone build for testing
└── scripts/
    ├── mac/              # macOS dev scripts (adb tunneling)
    └── linux/            # Linux builder scripts (AOSP build, Cuttlefish)
```

## Getting Started

### Prerequisites

- **macOS**: Nix with flakes enabled (for development)
- **Linux Builder**: Ubuntu 22.04+ with KVM (for AOSP builds and Cuttlefish)

### Development Setup

#### On macOS (for Rust development):

```bash
# Enter dev shell
nix develop

# Build for Android x86_64 (Cuttlefish emulator)
just build-x86

# Build for ARM64 (physical devices)
just build-arm64

# List all available tasks
just --list
```

#### On Linux (for AOSP builds):

```bash
# Enter AOSP build shell
nix develop .#aosp

# Bootstrap AOSP source tree (~100GB download)
just aosp-bootstrap

# Build AOSP with webos overlay
cd ~/aosp
source build/envsetup.sh
lunch webos_cf_x86_64-userdebug
m -j$(nproc)

# Launch Cuttlefish
just cf-launch

# View webosd logs
adb logcat -s webosd:*
```

#### Connecting macOS to Linux Builder:

```bash
# On Linux: find Cuttlefish adb port
just cf-tunnel

# On macOS: tunnel adb connection
./scripts/mac/dev-adb.sh user@linux-builder 6520

# Now adb commands work from your Mac
adb devices
adb logcat -s webosd:*
```

## Development Workflow

### Fast Inner Loop (Rust code changes):

1. Edit Rust code on macOS
2. `just build-x86` to cross-compile
3. `just run-x86` to push and run on Cuttlefish
4. Iterate rapidly without rebuilding AOSP

### Full Rebuild (init.rc or system changes):

1. Make changes to `vendor/webos/` files
2. On Linux: `just aosp-rebuild-image`
3. `just cf-launch` to boot new image

## Milestones

- [x] **Milestone 0**: Repository skeleton with Nix flakes
- [ ] **Milestone 1**: Boot custom AOSP image with `webosd` daemon
- [ ] **Milestone 2**: Draw rectangle from Rust using DRM
- [ ] **Milestone 3**: Input handling (touch/keyboard)
- [ ] **Milestone 4**: SurfaceFlinger integration
- [ ] **Milestone 5**: Binder IPC for system services

## Key Features (Planned)

- **Nostr-Native**: Built-in relay interaction, timeline APIs, E2EE messaging
- **Bitcoin Payments**: First-class wallet and payment integration
- **TypeScript Support**: Native TS execution without transpilation
- **SQLite Embedded**: Proper database support in the browser
- **No Centralized Trust**: P2P web without DNS/CAs

## Related Projects

See `~/code/` for inspiration:
- `blitz` - High-performance web rendering
- `dioxus` - Rust UI framework
- `nsite` - Decentralized site hosting
- `marmot` - E2EE messaging protocol

## Design Principles

1. **No Mocks**: Test against real infrastructure
2. **Real Implementation**: No stubs or "TODO: implement later"
3. **Simple Structure**: Flat directories, minimal abstraction
4. **Fast Feedback**: UI tests with accessibility features
5. **CI Must Pass**: `just ci` is the gate for all changes

## License

TBD
