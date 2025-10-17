# Minimal Pixel OS Roadmap

This roadmap describes how we graduate from "Android with a Magisk patched init_boot" to a self-owned, minimal OS stack on Pixel hardware. Each phase produces a working artifact and keeps recovery simple (restore the saved partitions and reboot).

## Guardrails
- Keep the bootloader unlocked until **all** partitions are restored to stock. Relocking on a modified slot soft-bricks Pixels.
- Archive every partition you modify with `fastboot fetch …` before flashing anything new.
- Treat `vendor`, `boot`, `dtbo`, and friends as read-only; we reuse Google's hardware enablement.
- Always keep a recovery path: `fastboot flash init_boot init_boot-stock.img && fastboot flash boot boot-stock.img` (plus any others you touched) returns to stock immediately.

## Phase 1 — Minimal Userspace Without Android
Goal: Replace Android userspace with our own ramdisk that boots, mounts the essentials, and hands us control.

- Build a tiny initramfs (BusyBox or a Rust `init`) that mounts `/dev`, `/proc`, `/sys`, and the dynamic partitions we need (`/vendor`, `/system`).
- Repack Pixel's `init_boot.img` with the new ramdisk.
- Boot with `fastboot boot` first; only `fastboot flash init_boot` when stable.
- Verify we can reach a shell/logging path (USB gadget serial, simple log spam, or start `adbd` manually) with no Android services running.

## Phase 2 — Minimal Daemon + Console
Goal: Replace Android init logic with our own launcher.

- Port the subset of `ueventd` functionality required to populate `/dev` (permissions + coldplug).
- Start our own PID 1 manager (Rust) that supervises child processes, handles signals, and brings up a minimalist console loop.
- Keep logging simple (kmsg ring + optional UART) so we always see boot progress.

## Phase 3 — Input & Display Loop
Goal: Build an interactive compositor-lite.

- Reuse the DRM rect primitives to allocate scanout buffers and control the CRTC.
- Add an async loop around `evdev` to process touchscreen and button events.
- Draw minimal widgets (rectangles, text) directly into dumb buffers and page flip on vsync.

## Phase 4 — Persistence
Goal: Store configuration and user data without Android's data stack.

- Reserve a dedicated ext4 area on userdata. Mount it read/write after boot.
- Provide a simple config loader (TOML/JSON) so we can persist network credentials and UI state.
- Add a host-side script to build and upload new initramfs images safely.

## Phase 5 — Networking & Services
Goal: Bring the device online and expose higher-level features.

- Launch `wpa_supplicant` (or `iwd`) from our daemon, using vendor binaries.
- Stand up minimal Rust services for Nostr, Lightning, etc., communicating via Unix sockets/IPC with the compositor.

## Phase 6 — Polish
Goal: Prepare for daily-driver experimentation.

- Package the system into a reproducible artifact (init_boot + boot + rootfs image).
- Tailor SELinux policy (start permissive; add rules as we go).
- Hook into thermal/battery stats (via vendor HAL or sysfs) for UI indicators.
- Add OTA-like updates: double-buffer the ramdisk and use A/B flashing to roll forward/back.

## Phase 7 (Optional) — Custom Kernel
Goal: When we outgrow Google's GKI, roll our own.

- Import the public kernel source drop matching our device and rebuild with required drivers.
- Build or reuse the vendor's `vendor_boot` to deliver the new kernel.
- Only attempt this once the userland is stable and we understand the hardware requirements.

---

At every phase we can revert to stock with the archived partitions, so experimentation stays low-risk while we iteratively replace Android with our own stack.
