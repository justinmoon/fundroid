# compositor-rs

A minimal Wayland compositor written in Rust, following the plan in `docs/rust-wayland-plan.md`.

## Phase 1: Project Setup ✅

Basic hello world that cross-compiles from macOS to Linux with static musl linking.

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

- **Size**: 377KB (stripped)
- **Type**: ELF 64-bit LSB pie executable, static-pie linked
- **Target**: x86_64-unknown-linux-musl
- **Location**: `target/x86_64-unknown-linux-musl/release/compositor-rs`

### Next Steps

Phase 2 will add DRM device initialization and display mode enumeration.
