# webos bootstrap

This repository contains the initial scaffolding for a Nix-first workflow that targets Android Open Source Project (AOSP) and Cuttlefish. The goal is to ship a Rust-first system daemon (`webosd`) and support utilities that let us bootstrap a browser-like runtime without depending on the legacy web PKI stack.

## Getting started

1. Install [Nix](https://nixos.org) with flakes enabled.
2. Enter the macOS-oriented development shell:

   ```bash
   nix develop
   ```

   This shell provides Rust toolchains with Android targets, the Android NDK, `adb`, and a `just` runner. The first thing to try is:

   ```bash
   just --list
   ```

3. On a Linux builder (bare metal, VM, or cloud), use the AOSP shell instead:

   ```bash
   nix develop .#aosp
   ```

   The helper scripts under `scripts/linux/` expect to run from this shell.

## Repository layout

- `flake.nix` — declarative dev environments for macOS and Linux.
- `justfile` — one-liner workflows for building Rust targets and managing the AOSP image.
- `scripts/` — automation for Android and Cuttlefish tooling.
- `vendor/webos/` — AOSP overlay providing `webosd` and init hooks.
- `rust/` — standalone Rust crates for direct testing on the host before integrating with AOSP.

## Rust crates

- `rust/drm_rect` — experiments for direct DRM rendering.
- `rust/webosd` — the system daemon that will eventually be built through the AOSP tree.

## Milestone 1: boot your AOSP image

1. On the Linux builder, enter the AOSP shell: `nix develop .#aosp`.
2. Sync AOSP and lay down the overlay: `just aosp-bootstrap`.
3. Build the product image: `just aosp-build-webosd` (invokes `lunch webos_cf_x86_64-userdebug`).
4. Launch Cuttlefish: `just cf-launch` and wait for `adb devices` to report the virtual device.
5. Verify the daemon: `adb logcat -s webosd:*` should show `hello from init()` followed by periodic `still alive` messages.

These steps stop the traditional Android framework, keep the low-level services we need, and confirm that `init` starts the Rust daemon from the custom product image.

Run all checks locally with:

```bash
just ci
```

That command is expected to stay green before any change is considered complete.
