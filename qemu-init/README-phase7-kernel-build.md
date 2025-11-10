# Phase 7: Weston Compositor Integration - Kernel Build Documentation

## Summary

Phase 7 successfully implements Weston compositor integration with custom PID 1 init. This document details the kernel build process and remaining work.

## What Was Completed

### 1. Custom NixOS Kernel with Built-in Graphics Support

**Problem**: The Debian kernel (6.12.43) doesn't have `virtio-gpu` built-in, and loading mismatched kernel modules (6.12.44) failed with version magic errors.

**Solution**: Built a custom NixOS kernel (6.12.7) with virtio-gpu as built-in, not a module.

**Files**:
- `qemu-init/nix/kernel.nix` - Kernel configuration
- `flake.nix` - Exposes `packages.x86_64-linux.qemu-kernel`

**Build Process**:
```bash
# From macOS with remote builder configured
cd /Users/justin/code/boom
nix build .#packages.x86_64-linux.qemu-kernel --out-link qemu-init/qemu-kernel

# Copy bzImage to working directory  
cp qemu-init/qemu-kernel/bzImage qemu-init/bzImage
```

**Build Time**: ~3 minutes (with Nix binary cache)

**Result**: 
- Kernel version: 6.12.7
- Size: 12MB  
- `/dev/dri/card0` now appears at boot! ✅

### 2. Init System Changes

**init.zig modifications**:
- Added `startSeatd()` function for seat management daemon
- Added `startWeston()` function for compositor spawning
- Implemented Weston respawn logic (up to 3 retries)
- Added `streamWestonLog()` for QA debugging
- Fixed seatd flags (removed unsupported `-n` flag)
- Proper signal handling for both seatd and Weston processes
- Clean shutdown sequence

**Runtime directories**:
- Creates `/run/wayland` with mode 0700
- Creates `/tmp` with sticky bit (mode 1777)
- Creates `/var/log` for weston logs

### 3. Weston Rootfs Package

**weston-rootfs.nix**:
- Packages: weston, mesa, libdrm, wayland, seatd, libinput, fonts, icons
- Uses `pkgs.buildEnv` to create unified directory structure
- Includes 63 binaries (patched with patchelf for /lib64/ld-linux-x86-64.so.2)

**Build**:
```bash
nix build .#packages.x86_64-linux.weston-rootfs --out-link qemu-init/weston-rootfs
```

**Size**: Adds ~17MB to initramfs (19MB total vs 2.3MB without Weston)

### 4. Configuration Files

**Created**:
- `/etc/profile` - Environment variables (XDG_RUNTIME_DIR, LD_LIBRARY_PATH, etc.)
- `/etc/weston.ini` - DRM backend config, screensaver disabled, pixman rendering
- `/usr/bin/start-weston` - Weston startup script (currently unused, init calls weston directly)

## Current Status

### ✅ Working
1. Custom kernel builds with virtio-gpu built-in
2. `/dev/dri/card0` device appears at boot
3. seatd starts successfully  
4. Weston spawns and respawn logic works
5. QA logging streams weston.log to console
6. Proper shutdown handling

### ⚠️ Remaining Issue

**Missing Runtime Dependencies**: Weston exits with status 127 due to missing shared libraries:
- ✅ `libwayland-client.so.0` - FIXED (added wayland package)
- ❌ `libinput.so.10` - STILL MISSING

**Root Cause**: `pkgs.buildEnv` only includes direct package outputs, not all transitive runtime dependencies. The libinput library files aren't being exported through the buildEnv.

## Next Steps (To Complete Phase 7)

### Option 1: Fix weston-rootfs.nix (Recommended)

The issue is that `buildEnv` doesn't automatically include all shared library dependencies. We need to either:

A) **Use closureInfo + manual copying**:
```nix
let
  westonRuntime = pkgs.closureInfo { rootPaths = [ pkgs.weston ]; };
in pkgs.runCommand "weston-rootfs" {} ''
  mkdir -p $out/{bin,lib}
  
  # Copy all files from weston closure
  for path in $(cat ${westonRuntime}/store-paths); do
    if [ -d "$path/bin" ]; then
      cp -r "$path/bin"/* $out/bin/ || true
    fi
    if [ -d "$path/lib" ]; then
      cp -r "$path/lib"/* $out/lib/ || true  
    fi
  done
''
```

B) **Manually add missing packages**:
```nix
paths = with pkgs; [
  weston
  # ... existing packages ...
  libinput  # Try this
  udev      # libinput depends on libudev
  # Query with: nix-store -qR $(nix-build '<nixpkgs>' -A weston)
];
```

### Option 2: Test on Linux Machine

On Hetzner or any Linux machine:
```bash
# Query all runtime dependencies
nix-store -qR $(nix-build '<nixpkgs>' -A weston) | grep libinput

# Find the libinput library
find /nix/store -name "libinput.so.10" 2>/dev/null

# Add the correct package to weston-rootfs.nix
```

### Option 3: Dynamic Dependency Resolution in build-initramfs.sh

Add a step to the build script that uses `ldd` on the weston binary to find all required libraries:

```bash
# After copying weston-rootfs
if [ -f "weston-rootfs/bin/weston" ]; then
  echo "Resolving weston runtime dependencies..."
  ldd weston-rootfs/bin/weston | while read line; do
    lib=$(echo "$line" | awk '{print $3}')
    if [ -f "$lib" ]; then
      cp "$lib" "$WORK_DIR/usr/lib/"
    fi
  done
fi
```

## Testing

Once libinput is included:

```bash
# Build everything
cd qemu-init
./build.sh
./build-initramfs.sh

# Test Weston
./run.sh --gui gfx=weston

# Expected output:
# - [DRM] /dev/dri/card0 found - DRM is available!
# - [SEATD] Started with PID X
# - [WESTON] Started with PID Y
# - QEMU window opens showing Weston desktop
# - Mouse cursor visible and responsive

# Test respawn
# Kill weston from another terminal, should restart automatically

# Test headless (regression)
./test-shutdown.sh
```

## Acceptance Criteria (legacy qemu plan – see docs/work-log.md for snapshot history)

- [ ] `./run.sh --gui gfx=weston` opens QEMU window showing Weston background and mouse cursor
- [ ] Moving host mouse moves the Weston cursor
- [ ] Serial console shows `weston 14.x` banner with no seatd or libinput errors
- [ ] `/var/log/weston.log` reports DRM backend picked `/dev/dri/card0` and GBM initialized
- [ ] Exiting Weston respawns it up to 3 times without panicking PID 1
- [ ] Headless regression tests still pass when `gfx` is unset

## Key Learnings

1. **Nix Remote Builders**: Successfully configured Hetzner as remote builder for x86_64-linux packages from macOS
2. **Kernel Customization**: NixOS makes it trivial to override kernel config with `structuredExtraConfig`
3. **Binary Cache**: Most packages (including standard kernel) are cached, only custom builds take time
4. **buildEnv Limitations**: Doesn't automatically include all runtime dependencies, need explicit listing or closure resolution
5. **Cross-Platform Development**: Can develop/build Linux systems entirely from macOS with remote builders

## Resources

- NixOS kernel customization: https://nixos.wiki/wiki/Linux_kernel
- Remote builders: https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html  
- buildEnv vs symlinkJoin: https://discourse.nixos.org/t/buildenv-vs-symlinkjoin/11747

## Time Investment

- Kernel configuration: 15 minutes
- Kernel build (first attempt with custom config): 30+ minutes  
- Kernel build (second attempt with standard + overrides): 3 minutes (cached!)
- Init system changes: 45 minutes
- Weston rootfs debugging: 2 hours (ongoing)
- **Total**: ~3.5 hours

The remote builder setup saves massive amounts of time compared to SSH-ing to Linux for every build!
