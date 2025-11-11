# Work Log

## QEMU Init Program (2024)
- Built a Zig-based PID 1 that learned mounts, signal handling, respawn logic, and module loading through six phases (`qemu-init/README.md` tracks scripts/tests).
- Added virtio-gpu kernel modules and a DRM init path so `./run.sh --gui gfx=drm_rect` and `gfx=compositor-rs` both boot and paint inside QEMU.
- Ported `drm_rect` to Zig (`drm_rect.zig`) and proved framebuffer creation, orange-screen rendering, and teardown under our init.
- Produced self-tests (`test-phase7.sh`, `test-input.sh`, etc.) that gate every change before we copy binaries into other environments.

## Rust Wayland Compositor (2024→2025)
- Spun up `compositor-rs/` as a standalone cargo project targeting `x86_64-unknown-linux-musl`; binaries are static PIEs around 600 KB.
- Milestones achieved: DRM enumeration, dumb-buffer allocation, Wayland socket/server, wl_compositor + wl_shm implementations, buffer rendering, and a gradient test client.
- Integrated into `qemu-init` via the `gfx=compositor-rs` switch so the compositor auto-starts, accepts the test client, and displays rendered buffers inside the QEMU window.

## Init-Boot Experiments on Cuttlefish (Oct 2025)
- Proved the stock first-stage ramdisk ships **no shell**, so PID1 overrides must be static binaries (`init-wrapper.c`).
- Learned we must preserve embedded device nodes while editing the ramdisk; `scripts/cpio_edit.py` lets us swap `/init` without rewriting everything.
- Repacking alone can break Verified Boot—always add the AVB hash footer (`avbtool add_hash_footer --partition_name init_boot ...`) and reuse header metadata from `unpack_bootimg`.
- Detected early boot logs vanish unless we write to `/dev/kmsg`; console output alone is unreliable on Hetzner.

## cfctl / Hetzner State
- `cfctl instance create-start --purpose ci --verify-boot --disable-webrtc` is the canonical smoke test; `just heartbeat` wraps it with PID1 repacks and log capture.
- The Hetzner host keeps stock images in `/var/lib/cuttlefish/images`; modifying them requires updating `~/configs/flake.nix` and redeploying via `just hetzner`.
- After the daemon refactor (Oct 2025), lifecycle commands return quickly and emit structured errors; lean on them instead of bespoke scripts when iterating.
- Added `scripts/capture-stock-console.sh`/`just capture-stock-console` so anyone can regenerate the Step 1 console baseline locally without checking multi-megabyte logs into git.

### Oct 2025 – PID1 logging experiments (Experiments 2–5)
- **Guest exits (Exp 2):** confirmed bubblewrap was dropping supplementary groups, so the daemon/launcher now re-enters `launch_cvd` with the configured user/group and ambient caps preserved. This stopped the “Failed → cleanup removed state” loop.
- **Init breadcrumbs (Exp 3):** instrumented `heartbeat_init` to create `/tmp/heartbeat-was-here` and emit an `EXPERIMENT-3` marker into `/dev/kmsg`, proving PID1 runs even if console output disappears.
- **Host tooling (Exp 5):** extended cfctl with `instance describe` (run-log tail + console snapshot path) and automatic console snapshots whenever an instance hits `Failed`, so we no longer need direct access to `/var/lib/cuttlefish` to see early boot logs.
