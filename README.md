# fundroid

Android PID1 experiments without the Android framework. The repo hosts our custom init binaries, the `drm_rect`/`compositor-rs` DRM demos, and the `cfctl` tooling that boots Cuttlefish on Hetzner.

## Status Snapshot
- `heartbeat-init/` – tiny C PID1s used for `init_boot.img` overrides; `just heartbeat` runs the remote smoke test via cfctl.
- `qemu-init/` – clean-room initramfs + kernel modules for fast iteration; every graphics binary comes from here first.
- `compositor-rs/` – static DRM/Wayland compositor plus test client destined for Cuttlefish once PID1 is stable.
- `cuttlefish/` – flake, modules, and the `cfctl` CLI that manages Hetzner instances.
- `docs/plans/` – active roadmaps for each parallel track (Cuttlefish PID1 logging, ramdisk packaging, Pixel 4a bring-up).

## Daily Commands
- `nix develop` – shared shell with cross-compilers and Android platform tools.
- `just heartbeat` – rebuilds the latest PID1, repacks `init_boot`, and boots a Hetzner instance while capturing logs.
- `just run-drm-demo` – pushes the `drm_rect` binary to a connected device after stopping SurfaceFlinger.
- `just emu-create|emu-boot|emu-root|emu-stop` – manages the local AVD used when we need a stock Android userspace.

## Documentation
- `docs/cuttlefish.md` – Hetzner image layout, cfctl sanity checks, and how `just heartbeat` interacts with the host.
- `docs/drm_rect.md` – step-by-step Pixel workflow (bootloader unlock, Magisk root, running the DRM demo).
- `docs/plans/*.md` – bite-size task lists with acceptance tests for each major effort.
- `docs/ideas.md` – condensed backlog of references, packaging tricks, and compositor follow-ups.
- `docs/work-log.md` – history of what already works (QEMU init, compositor-rs, init_boot experiments).
- `notes/CONSOLE-OUTPUT-SUMMARY.md` – investigation log for missing PID1 console output; read before debugging logging again.
