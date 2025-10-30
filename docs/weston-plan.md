# Weston Compositor Integration Plan

## Goal
Boot straight into the Weston DRM backend from our custom init and see a real Wayland desktop with mouse cursor inside the QEMU window.

## Why This Matters
- **Real compositor:** Not just colored pixels, but a full Wayland display server
- **Foundation for apps:** Once Weston works, we can run any Wayland application
- **Proves the stack:** Validates that our init → kernel modules → DRM setup is production-ready
- **Stepping stone to Android:** Understanding this makes SurfaceFlinger integration much clearer

## Current State
✅ We have:
- Custom init that boots successfully
- Kernel module loading (virtio-gpu stack)
- DRM device created (/dev/dri/card0)
- Basic framebuffer rendering (drm_rect)
- GUI mode in QEMU

## Architecture Overview

```
┌─────────────────────────────────────────┐
│ QEMU Window (host)                      │
│  ↕ virtio-gpu-pci                       │
├─────────────────────────────────────────┤
│ Guest Linux                             │
│                                         │
│  /dev/dri/card0 ← virtio-gpu driver    │
│         ↕                               │
│  Weston (DRM backend)                   │
│         ↕                               │
│  seatd (seat/input management)          │
│         ↕                               │
│  our init (PID 1)                       │
└─────────────────────────────────────────┘
```

## Dependencies We Need

### Core Weston Stack
- **weston** - The compositor itself
- **mesa** - OpenGL/DRM graphics drivers
- **libdrm** - DRM userspace library (we already have this)
- **wayland** - Wayland protocol library
- **pixman** - Software rendering fallback

### Input/Session Management
- **seatd** - Seat management daemon (handles /dev/input, /dev/dri permissions)
- **libinput** - Input device handling
- **libxkbcommon** - Keyboard layout handling

### Supporting Libraries
- **cairo** - 2D graphics
- **pango** - Text rendering
- **fontconfig** - Font configuration
- **libpng, libjpeg** - Image loading

---

## Phase-by-Phase Plan

### Phase 1: Nix Package Setup
**Goal:** Create a Nix derivation that bundles Weston and all its dependencies.

**Tasks:**
1. Create `qemu-init/nix/weston-rootfs.nix`
2. Use `pkgs.buildEnv` to create a minimal rootfs
3. Include: weston, mesa, seatd, libinput, wayland-utils (for debugging)
4. Expose as `packages.x86_64-linux.weston-rootfs` in flake.nix
5. Test: `nix build .#weston-rootfs` produces a result with `/bin/weston`

**Acceptance Criteria:**
- [ ] `nix build .#weston-rootfs` succeeds
- [ ] `result/bin/weston --version` shows Weston version
- [ ] `result/bin/seatd --version` shows seatd version
- [ ] `nix path-info -r` shows complete dependency closure
- [ ] No missing shared libraries when checking with `ldd result/bin/weston`

**What you'll learn:**
- Nix buildEnv and package bundling
- How to create a minimal rootfs
- Wayland ecosystem dependencies

---

### Phase 2: Integrate Rootfs into Initramfs
**Goal:** Include the Weston rootfs in our initramfs so binaries are available at boot.

**Tasks:**
1. Modify `build-initramfs.sh` to build weston-rootfs if not present
2. Copy rootfs contents to `$WORK_DIR/usr/` in initramfs
3. Use `nix path-info -r` or similar to get full closure with libraries
4. Ensure shared libraries are in `/usr/lib` where the dynamic linker can find them
5. Test that initramfs size is reasonable (< 50MB compressed)

**Acceptance Criteria:**
- [ ] `./build-initramfs.sh` automatically builds weston-rootfs
- [ ] Initramfs contains `/usr/bin/weston`, `/usr/bin/seatd`
- [ ] Shared libraries present in `/usr/lib`
- [ ] Can boot headless and run `ls /usr/bin/weston` from init
- [ ] Initramfs size stays under 50MB

**What you'll learn:**
- How to integrate Nix closures into initramfs
- Shared library path management
- Initramfs size optimization

---

### Phase 3: Runtime Directory Setup
**Goal:** Create necessary runtime directories and environment variables.

**Tasks:**
1. In `init.zig`, create `/run/wayland` directory (mode 0700)
2. Create `/tmp` directory (mode 1777)
3. Set `XDG_RUNTIME_DIR=/run/wayland` environment variable
4. Set `LD_LIBRARY_PATH=/usr/lib` to find shared libraries
5. Test by logging environment in init

**Acceptance Criteria:**
- [ ] Init creates `/run/wayland` successfully
- [ ] Init creates `/tmp` successfully
- [ ] Environment variables logged to console
- [ ] Directories have correct permissions (0700 for /run/wayland)
- [ ] Headless boot still works without errors

**What you'll learn:**
- XDG base directory specification
- Runtime directory requirements for Wayland
- Environment variable management in init

---

### Phase 4: Basic Weston Configuration
**Goal:** Create a minimal weston.ini that forces DRM backend and disables features we don't need.

**Tasks:**
1. Create `qemu-init/rootfs/etc/weston.ini` file
2. Configure `[core]` section with `backend=drm-backend.so`
3. Set `use-pixman=true` (software rendering, more reliable than GL in QEMU)
4. Disable screensaver in `[shell]` section
5. Include weston.ini in initramfs via build-initramfs.sh

**Acceptance Criteria:**
- [ ] weston.ini file created with minimal config
- [ ] File included in initramfs at `/etc/weston.ini`
- [ ] Config specifies DRM backend
- [ ] Config uses pixman (software) renderer
- [ ] Screensaver disabled

**What you'll learn:**
- Weston configuration format
- DRM vs other backends (X11, Wayland, etc.)
- Pixman vs GL rendering

---

### Phase 5: Start seatd First
**Goal:** Get seatd running before Weston, as it manages device permissions.

**Tasks:**
1. In `init.zig`, add function `start_seatd()`
2. Fork and exec `/usr/bin/seatd -n` (non-forking mode)
3. Export `SEATD_VTBOUND=1` environment variable
4. Wait briefly for seatd to initialize (check for socket creation)
5. Log seatd PID and status

**Acceptance Criteria:**
- [ ] Init successfully forks and execs seatd
- [ ] seatd runs in foreground (`-n` flag)
- [ ] Environment variable `SEATD_VTBOUND=1` set
- [ ] seatd socket created (check /run/seatd.sock or similar)
- [ ] No permission errors in logs
- [ ] Can kill seatd without crashing init

**What you'll learn:**
- What seat management is
- Why seatd is needed (device permissions for non-root)
- Socket-based IPC

---

### Phase 6: Weston Startup Script
**Goal:** Create a helper script that launches Weston with correct arguments.

**Tasks:**
1. Create `qemu-init/rootfs/usr/bin/start-weston` shell script
2. Export all needed environment variables (XDG_RUNTIME_DIR, etc.)
3. Set `WAYLAND_DISPLAY=wayland-0`
4. Exec weston with args: `--backend=drm-backend.so --log=/var/log/weston.log`
5. Make script executable and include in initramfs

**Acceptance Criteria:**
- [ ] Script created and executable
- [ ] Exports XDG_RUNTIME_DIR, WAYLAND_DISPLAY, LD_LIBRARY_PATH
- [ ] Specifies DRM backend explicitly
- [ ] Redirects logs to /var/log/weston.log
- [ ] Script included in initramfs at `/usr/bin/start-weston`

**What you'll learn:**
- Weston command-line arguments
- Wayland environment variables
- Logging configuration

---

### Phase 7: Integrate with Init (Parse gfx=weston)
**Goal:** Make init recognize `gfx=weston` and launch the compositor.

**Tasks:**
1. In `init.zig`, after DRM check, parse `gfx` parameter
2. If `gfx=weston`, fork and exec `/usr/bin/start-weston`
3. Track Weston PID and supervise it
4. Log Weston startup to console
5. Keep existing `gfx=drm_rect` working

**Acceptance Criteria:**
- [ ] `gfx=weston` kernel parameter recognized
- [ ] Init forks and execs start-weston script
- [ ] Weston PID tracked by init
- [ ] Console shows "[GFX] Starting Weston compositor..."
- [ ] `gfx=drm_rect` still works (regression test)
- [ ] Headless mode still works without `gfx` parameter

**What you'll learn:**
- Conditional startup based on kernel parameters
- Process supervision patterns
- Maintaining backward compatibility

---

### Phase 8: Logging and Debug Output
**Goal:** Stream Weston logs to serial console for debugging.

**Tasks:**
1. Create `/var/log/` directory in init
2. After Weston exits, read `/var/log/weston.log` and print to console
3. Add timestamps to init logs
4. Log any Weston startup failures clearly
5. Test with intentionally broken config to verify error handling

**Acceptance Criteria:**
- [ ] /var/log directory created by init
- [ ] Weston log file created successfully
- [ ] On Weston exit, log contents printed to serial console
- [ ] Init logs include timestamps
- [ ] Error conditions (missing files, etc.) logged clearly
- [ ] Can diagnose issues from serial console output alone

**What you'll learn:**
- Log file management
- Debugging distributed systems
- Error handling best practices

---

### Phase 9: First Weston Boot Attempt
**Goal:** Try to boot Weston and see what breaks.

**Tasks:**
1. Build everything: `./build.sh && ./build-initramfs.sh`
2. Run: `./run.sh --gui gfx=weston`
3. Collect all error messages from serial console
4. Check Weston log for DRM initialization
5. Note any missing libraries or configuration issues

**Acceptance Criteria:**
- [ ] System boots without kernel panic
- [ ] seatd starts successfully
- [ ] Weston process starts
- [ ] Can see Weston attempting to initialize DRM
- [ ] QEMU window shows something (even if just black screen)
- [ ] All errors clearly logged

**Expected Issues:**
- Missing fonts or icons
- Permission errors
- Missing environment variables
- GL vs Pixman configuration issues

**What you'll learn:**
- How to debug compositor startup
- Reading DRM/Wayland logs
- Troubleshooting missing dependencies

---

### Phase 10: Fix Missing Dependencies
**Goal:** Iterate on Nix package until Weston starts without errors.

**Tasks:**
1. Add missing packages to weston-rootfs.nix based on errors
2. Common additions needed:
   - fontconfig and fonts (dejavu, liberation)
   - hicolor-icon-theme
   - xcursor-themes (for mouse cursor)
   - dbus (if Weston expects it)
3. Rebuild and test after each addition
4. Verify with `ldd` that all shared libraries found

**Acceptance Criteria:**
- [ ] No "cannot open shared object" errors
- [ ] No "failed to load font" errors
- [ ] No "icon theme" warnings
- [ ] Weston log shows successful DRM initialization
- [ ] Weston log shows "Output 'Virtual-1'" or similar
- [ ] No crashes in first 10 seconds

**What you'll learn:**
- Common Wayland/graphics dependencies
- How to trace missing dependencies
- Font and theme configuration

---

### Phase 11: Input Device Configuration
**Goal:** Get keyboard and mouse input working.

**Tasks:**
1. Ensure libinput is in weston-rootfs
2. Verify /dev/input devices exist (created by devtmpfs)
3. Configure Weston to use libinput backend
4. Test mouse movement and clicks
5. Test keyboard input (though may not be visible without apps yet)

**Acceptance Criteria:**
- [ ] Weston log shows libinput backend initialized
- [ ] Mouse cursor visible in QEMU window
- [ ] Host mouse movement moves Weston cursor
- [ ] Mouse clicks registered (visible in Weston debug log)
- [ ] No libinput errors in logs

**What you'll learn:**
- How Wayland handles input
- libinput device discovery
- Input event flow

---

### Phase 12: Visual Confirmation
**Goal:** See actual Weston desktop with background color/pattern.

**Tasks:**
1. Configure Weston shell background color in weston.ini
2. Ensure Pixman renderer working (check logs for "using pixman")
3. Verify DRM mode setting (should see resolution in logs)
4. Watch QEMU window change from "Display output is not active" to Weston background
5. Take screenshot as evidence of success

**Acceptance Criteria:**
- [ ] QEMU window shows Weston background (not black, not "no output")
- [ ] Background color matches weston.ini configuration
- [ ] Weston log shows framebuffer created and scanout configured
- [ ] No DRM errors in kernel log
- [ ] Display remains stable (no flickering or crashes)
- [ ] Can run for 30+ seconds without issues

**What you'll learn:**
- DRM mode setting from user perspective
- How Wayland compositors set up outputs
- Difference between working compositor and failed one

---

### Phase 13: Respawn on Exit
**Goal:** Make Weston restart if it crashes or exits.

**Tasks:**
1. In init.zig, add Weston to supervised child processes
2. Track Weston exit status
3. Implement respawn logic (same as test_child: 3 tries, 1 second wait)
4. Test by killing Weston manually (Ctrl+Alt+Backspace or SIGTERM)
5. Verify respawn counter prevents infinite loops

**Acceptance Criteria:**
- [ ] Weston crash causes init to log exit status
- [ ] Init respawns Weston automatically
- [ ] Respawn count logged to console
- [ ] After 3 failures, init stops respawning
- [ ] Init remains stable (doesn't crash with Weston)
- [ ] Can manually test by sending SIGTERM to Weston PID

**What you'll learn:**
- Process supervision patterns
- Graceful failure handling
- Preventing init from becoming unstable

---

### Phase 14: Weston Terminal (Optional Demo)
**Goal:** Run an actual Wayland application inside Weston.

**Tasks:**
1. Add weston-terminal to weston-rootfs.nix
2. Configure weston.ini to auto-launch terminal on startup
3. See terminal window appear in Weston
4. Verify keyboard input works in terminal
5. Optionally add other demo apps (weston-simple-egl)

**Acceptance Criteria:**
- [ ] weston-terminal binary included in rootfs
- [ ] Terminal window appears automatically on startup
- [ ] Window has title bar and can be moved (if shell supports it)
- [ ] Keyboard input appears in terminal
- [ ] Can type commands (even if they don't exist)

**What you'll learn:**
- Wayland application architecture
- How compositor and clients interact
- Window management basics

---

### Phase 15: Automated Testing
**Goal:** Create test script that validates Weston boot.

**Tasks:**
1. Create `qemu-init/test-weston.sh` script
2. Boot with `gfx=weston` in headless validation mode
3. Parse serial console output for success markers:
   - "Weston started"
   - "DRM backend initialized"
   - "Output configured"
4. Fail test if error keywords found ("failed to", "error:", "cannot")
5. Add to CI or local testing workflow

**Acceptance Criteria:**
- [ ] Test script created and executable
- [ ] Script boots QEMU with timeout
- [ ] Parses logs for success/failure keywords
- [ ] Returns exit code 0 on success, 1 on failure
- [ ] Can run in CI/automated environment
- [ ] Clear output showing what it checked

**What you'll learn:**
- Automated testing of graphical systems
- Log-based validation
- CI/CD for system-level code

---

## Success Metrics

### Minimum Viable Weston (MVP)
- ✅ Weston starts without crashes
- ✅ DRM backend initializes
- ✅ Background color visible in QEMU window
- ✅ Mouse cursor visible and moves

### Stretch Goals
- Terminal application running
- Keyboard input working
- Multiple windows can be opened
- Graceful shutdown and respawn
- Automated test passes

## Common Issues and Solutions

### Issue: "Failed to open DRM device"
- **Cause:** virtio-gpu module not loaded
- **Solution:** Ensure module loading happens before Weston starts

### Issue: "Permission denied on /dev/dri/card0"
- **Cause:** seatd not running or misconfigured
- **Solution:** Start seatd before Weston, check socket exists

### Issue: "Cannot load GL renderer"
- **Cause:** GL not available in QEMU or mesa issue
- **Solution:** Use Pixman renderer (`use-pixman=true`)

### Issue: "No screens found"
- **Cause:** DRM mode setting failed
- **Solution:** Check kernel logs for virtio-gpu errors, verify connector state

### Issue: Black screen but no errors
- **Cause:** Output not configured or background too dark
- **Solution:** Set explicit background color, check output configuration

## Next Steps After Weston Works

1. **Cage compositor** - Simpler kiosk-style alternative
2. **Apply to Cuttlefish** - Port this knowledge to Android
3. **SurfaceFlinger** - Understand Android's compositor
4. **Real apps** - Run Android apps in custom environment

---

## Resources

- Weston documentation: https://wayland.pages.freedesktop.org/weston/
- DRM/KMS guide: https://www.kernel.org/doc/html/latest/gpu/drm-kms.html
- Wayland protocol: https://wayland.freedesktop.org/docs/html/
- seatd: https://git.sr.ht/~kennylevinsen/seatd
