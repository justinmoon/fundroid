# Custom Kernel for Phase 7 Testing

## Problem
The current Debian kernel (`download-kernel.sh`) lacks `CONFIG_VIRTIO_INPUT` support, so virtio-input devices don't create `/dev/input/event*` files needed for Phase 7 input testing.

## Solution
Build a custom NixOS kernel with the required config options enabled.

## Building the Kernel (on Linux)

### Option 1: On Hetzner VPS
```bash
ssh hetzner
cd ~/path/to/boom/worktrees/rustcomp
./qemu-init/build-kernel-linux.sh
```

### Option 2: Using Nix Remote Builder
If you have a Linux remote builder configured:
```bash
nix build .#qemu-kernel --accept-flake-config
cp result/bzImage qemu-init/bzImage
```

### Option 3: In a Linux VM/Container
```bash
# On any Linux machine with Nix
git clone <repo>
cd rustcomp
nix build .#qemu-kernel --accept-flake-config
```

## What's Enabled

The custom kernel (`qemu-init/nix/kernel.nix`) enables:

**For Phase 7 Input:**
- `CONFIG_VIRTIO_INPUT=y` - virtio input devices
- `CONFIG_INPUT_EVDEV=y` - evdev interface
- `CONFIG_HID_SUPPORT=y` - HID device support

**For Phase 6 Graphics:**
- `CONFIG_DRM=y` - Direct Rendering Manager
- `CONFIG_DRM_VIRTIO_GPU=y` - virtio-gpu driver

**Basic virtio:**
- `CONFIG_VIRTIO=y`, `CONFIG_VIRTIO_PCI=y` - core virtio support

## Testing After Building

Once you have the custom kernel:

```bash
cd qemu-init
./run.sh --gui gfx=compositor-rs
```

You should see:
```
✓ Opened input device: /dev/input/event0 (virtio_input Keyboard)
✓ Opened input device: /dev/input/event1 (virtio_input Mouse)
```

Press keys in QEMU window → compositor forwards to Wayland client!

## Current Status

- ❌ **Can't build on macOS** - kernel compilation requires Linux
- ✅ **Nix config ready** - `flake.nix` exports `qemu-kernel` package
- ✅ **Phase 7 code ready** - evdev input handling implemented
- ⏳ **Need Linux build** - run `build-kernel-linux.sh` on Hetzner

## Why Not Use Debian Kernel?

The Debian installer kernel is intentionally minimal and doesn't include many virtio device drivers to keep size small. NixOS kernels include more drivers by default and are easy to customize.
