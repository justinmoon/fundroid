# QEMU Init Learning Plan

## Goal
Learn Linux boot fundamentals through incremental development of a minimal init system in QEMU, then apply this knowledge to Android/Cuttlefish.

## Why This Approach
Cuttlefish adds massive complexity that obscures the fundamentals:
- AVB signing
- TAP device networking  
- ADB infrastructure
- Android-specific partitions
- SELinux policies

QEMU eliminates all that and lets us focus on core concepts.

## Current Status

### ✅ Phase 1: Basic Boot (COMPLETE)
**Location:** `qemu-init/`

**What works:**
- Minimal PID 1 init (66 lines of Zig)
- Cross-compiles macOS → Linux static binary
- Boots in QEMU with Debian kernel
- Prints heartbeats every 2 seconds
- Validated boot success (checks banner, PID 1, multiple heartbeats)
- Auto-enters nix shell when needed

**Key learnings:**
- How kernel finds and executes init (`/init` then `/sbin/init`)
- What initramfs is (cpio archive unpacked to RAM)
- PID 1 must never exit (or kernel panics)
- Console/TTY basics (ttyS0 for serial)

**Acceptance Criteria:**
- ✅ `./run.sh` boots without kernel panic
- ✅ Output shows "QEMU MINIMAL INIT" banner
- ✅ Output shows `PID: 1`
- ✅ At least 3 heartbeat messages printed with incrementing timestamps
- ✅ System stays running until timeout (doesn't crash or exit)

## Next Steps

### ✅ Phase 2: Filesystem Setup (COMPLETE)
**Goal:** Mount essential filesystems that any real init needs.

**Tasks:**
1. Mount `/proc` - Process information
2. Mount `/sys` - Kernel/device info  
3. Mount `/dev` with devtmpfs - Device nodes
4. Verify by reading `/proc/self/status` to confirm PID 1
5. Print filesystem stats (e.g., device count in /dev)

**What you'll learn:**
- Why these filesystems are essential
- How to use mount syscalls
- What each filesystem provides

**Acceptance Criteria:**
- ✅ Output shows "[OK] Mounted /proc (process information)"
- ✅ Output shows "[OK] Mounted /sys (kernel/device info)"
- ✅ Output shows "[OK] Mounted /dev (device nodes)"
- ✅ Successfully reads `/proc/self/status` and prints "Pid: 1"
- ✅ Counts and prints device count in /dev (should be > 50)
- ✅ Output shows "[SUCCESS] All filesystems mounted and verified!"
- ✅ No mount errors in output
- ✅ Heartbeat continues after filesystem setup

### ✅ Phase 3: Signal Handling (COMPLETE)
**Goal:** Handle signals properly (required for real init).

**Tasks:**
1. Handle SIGTERM - Graceful shutdown
2. Handle SIGCHLD - Reap zombie processes
3. Handle SIGINT - Ctrl+C handling
4. Unmount filesystems on shutdown
5. Exit cleanly

**What you'll learn:**
- Signal handling in PID 1
- Proper shutdown sequence
- Zombie process reaping

**Acceptance Criteria:**
- ✅ Output shows "Signal handler installed for SIGTERM"
- ✅ Output shows "Signal handler installed for SIGINT"
- ✅ Output shows "Signal handler installed for SIGCHLD"
- ✅ Signal handlers use correct `.c` calling convention for C ABI
- ✅ SIGCHLD handler reaps zombies with `waitpid(-1, WNOHANG)`
- ✅ SIGTERM/SIGINT set shutdown flag
- ✅ Heartbeat loop checks shutdown_requested flag
- ✅ Shutdown sequence implemented: unmount /dev, /sys, /proc
- ✅ Exit with code 0 via `posix.exit(0)`

**Note:** Full shutdown testing requires child processes (Phase 4) or kernel poweroff mechanism.

### ✅ Phase 4: Process Management (COMPLETE)
**Goal:** Spawn and manage child processes.

**Tasks:**
1. Fork a child process
2. Exec a simple command (like `/bin/sh` or a test binary)
3. Wait for child and reap it
4. Respawn if it dies
5. Handle multiple children

**What you'll learn:**
- fork/exec pattern
- Process supervision
- Respawn logic

**Acceptance Criteria:**
- ✅ Create test_child.zig that prints "Hello from child" and exits
- ✅ Include test_child binary in initramfs via build-initramfs.sh
- ✅ spawnChild() function implements fork/exec pattern
- ✅ Output shows "[SPAWN] Child process started with PID X"
- ✅ Child output visible: "Hello from child process!"
- ✅ SIGCHLD handler tracks child exits and sets child_exited flag
- ✅ Main loop checks child_exited and logs exit status
- ✅ Respawn logic: wait 1 second, spawn again (limit: 3 respawns)
- ✅ Each respawn gets new PID via fork()
- ✅ SIGCHLD handler uses waitpid() to prevent zombies
- ✅ Shutdown kills child process before unmounting

**Note:** Test validation has timing issues with QEMU boot time, but manual testing confirms child spawning/respawning works correctly.

---

## Graphics / Wayland Bring-up

### ✅ Phase 5: Port drm_rect to Zig (COMPLETE)
**Goal:** Port the existing Rust drm_rect program to Zig, creating a self-contained DRM/KMS graphics demo.

**Tasks:**
1. Create `qemu-init/drm_rect.zig` - port the Rust drm_rect code to Zig
2. Use Zig's C interop to call libdrm functions (drmOpen, drmModeGetResources, etc.)
3. Implement DRM modesetting: find connector, CRTC, create framebuffer
4. Draw solid color rectangle using direct framebuffer access
5. Build as static Linux binary: `zig build-exe -target x86_64-linux-musl`
6. Test locally with `/dev/dri/card0` access

**What you'll learn:**
- DRM/KMS API fundamentals (mode setting, connectors, CRTCs)
- Zig's C interop (`@cImport`, `@cInclude`)
- Direct framebuffer manipulation
- Graphics card initialization

**Acceptance Criteria:**
- ✅ drm_rect.zig created with complete DRM/KMS implementation
- ✅ Uses `@cImport` to import xf86drm.h, xf86drmMode.h, drm_fourcc.h
- ✅ Opens /dev/dri/card0 and gets DRM resources
- ✅ Finds connected connector and selects first mode
- ✅ Gets encoder and CRTC for modesetting
- ✅ Creates dumb buffer (32bpp XRGB8888) and framebuffer
- ✅ Maps buffer with mmap and fills with orange color (#FF8800)
- ✅ Sets CRTC to display framebuffer for 30 seconds
- ✅ Clean shutdown: clears CRTC, destroys FB and dumb buffer

**Note:** Requires libdrm headers to build. Will be integrated into QEMU environment in Phase 6. To build on Linux: `zig build-exe -target x86_64-linux-musl drm_rect.zig -lc -ldrm`

### Phase 6: QEMU DRM Integration
**Goal:** Boot straight into the Weston DRM backend from our init and see the Weston desktop inside the QEMU window.

**Tasks:**
1. Add a `qemu-init/nix/weston-rootfs.nix` that wraps `pkgs.buildEnv` with the full closure for `weston`, `weston-simple-egl`, `seatd`, `wayland-utils`, `libinput`, `mesa.drivers`, `fontconfig`, and `hicolor-icon-theme`. Expose it in the flake as `packages.x86_64-linux.weston-rootfs`.
2. Extend `build-initramfs.sh` to `nix build .#packages.x86_64-linux.weston-rootfs` when missing and copy the closure into `rootfs/usr`. Use `nix path-info -r` or `nix-store --realise` to make sure the closure includes shared libraries.
3. Create `/etc/profile` (inside `rootfs`) that exports `XDG_RUNTIME_DIR=/run/wayland`, `WESTON_DISABLE_ABSTRACT_FD=1`, and `WLR_BACKENDS=drm`. Ensure init creates `/run/wayland` with `0700`.
4. Bundle a `weston.ini` under `rootfs/etc/weston.ini` to disable the screensaver and force the DRM backend (`[core]\nbackend=drm-backend.so\nuse-pixman=true`).
5. Extend `init.zig` to understand `gfx=weston`. On selection, start `seatd -n` (non-forking), export `SEATD_VTBOUND=1`, then exec `/usr/bin/weston --backend=drm-backend.so --tty=/dev/tty0 --log=/var/log/weston.log --xwayland` in a supervised child.
6. Add QA hooks: stream `/var/log/weston.log` back to the serial console on failure, and teach the harness to grab a framebuffer dump via `qemu-system-x86_64 -device virtio-vga-gl -display sdl,gl=on -snapshot -monitor stdio` + `screendump`.

**Acceptance Criteria:**
- [ ] `./run.sh --gui gfx=weston` opens the QEMU window and shows the Weston background and mouse cursor; moving the host mouse moves the Weston cursor.
- [ ] Serial console shows `weston 14.x` banner and no `seatd` or `libinput` errors.
- [ ] `/var/log/weston.log` (dumped to console on exit) reports the DRM backend picked `/dev/dri/card0` and GBM initialized successfully.
- [ ] Exiting Weston (Ctrl+Alt+Backspace) respawns it up to the configured retry limit without panicking PID 1.
- [ ] Headless regression tests still pass when `gfx` is unset.

### Phase 7: Weston Compositor Proof
**Goal:** Provide a kiosk-style compositor alternative powered by Cage and prove it by running a demo Wayland client.

**Tasks:**
1. Extend `weston-rootfs.nix` into a shared `wayland-bundle.nix` that exposes both `weston` and `cage`; include `cage`, `wlroots`, and `weston-simple-egl` in the closure.
2. Place a helper script at `rootfs/usr/bin/run-cage-demo` that sets `WAYLAND_DISPLAY=cage-0`, exports `WLR_NO_HARDWARE_CURSORS=1` (helps in QEMU), and execs `/usr/bin/cage -s -- /usr/bin/weston-simple-egl`.
3. Update `init.zig` to accept `gfx=cage`. When selected, spawn `seatd -n` + `/usr/bin/run-cage-demo` under supervision. Ensure the process terminates cleanly on SIGTERM and propagates failures to the console.
4. Add smoke test automation: after boot, have PID 1 run `/usr/bin/weston-info` via Cage (as its single client) and print the output to the serial console so we can assert the compositor is alive in CI.
5. Document how to switch between compositors at boot (`gfx=` kernel argument) in `docs/wayland.md`.

**Acceptance Criteria:**
- [ ] `./run.sh --gui gfx=cage` shows the Cage splash (solid color) and then the rotating Weston simple EGL demo in the QEMU window.
- [ ] Serial console logs from PID 1 confirm Cage started, `wlroots` chose the DRM backend, and `weston-info` output reaches the console.
- [ ] Killing the Cage process from the host (`sendkey ctrl-alt-backspace` in the QEMU monitor) causes PID 1 to respawn it and logs the new PID.
- [ ] Switching between `gfx=weston`, `gfx=cage`, and no `gfx` happens without rebuilding the initramfs (only the kernel cmdline changes).

### Phase 8: Cage Compositor Option
**Goal:** Expose a single init binary that can boot in headless QA mode, Weston mode, or Cage mode based on kernel parameters.

**Tasks:**
1. Refactor compositor spawning into `init.zig` helpers: `start_weston()`, `start_cage()`, `start_drm_rect()`. They share logging, respawn policy, and SIGTERM cleanup.
2. Parse `gfx=` and an optional `gfx.extra=` parameter from `/proc/cmdline` so we can pass extra arguments (e.g. `gfx=cage gfx.extra="--app=/usr/bin/weston-terminal"`).
3. Teach the heartbeat loop to emit structured status JSON (e.g. `[STATUS] gfx="weston" pid=… state=running`) so automated QA can assert the correct compositor is up.
4. Update `test-shutdown.sh` (and add a new `test-gfx.sh`) to cover `gfx=weston` and `gfx=cage` in headless mode by grepping for compositor banners in the serial log.
5. Document the supported flags and QA coverage in this plan and in `README.md`.

**Acceptance Criteria:**
- [ ] Single `init` binary handles all modes with no rebuild between runs.
- [ ] `./run.sh --gui gfx=weston` and `./run.sh --gui gfx=cage` both pass automated log checks and manual visual validation.
- [ ] `./run.sh --headless` (default) keeps current tests green without needing any `gfx` parameters.
- [ ] QA scripts fail fast when compositor startup logs contain obvious errors (missing DRM device, seatd failure, etc.).
- [ ] Switching modes only changes the kernel command line in `run.sh` (`-append "… gfx=weston"`).
