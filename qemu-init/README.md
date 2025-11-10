# QEMU Minimal Init - Linux Boot Learning

Learn how Linux boot works from first principles using the simplest possible setup.

## Quick Start

```bash
cd qemu-init
nix develop ..     # Enter dev shell
./run.sh           # Build + boot + validate
```

The script validates that init actually runs by checking for:
- Init banner appears
- Running as PID 1
- At least 3 heartbeats over 10 seconds

**Exit codes:** 0 = success, 1 = init failed to boot properly

## What You'll Learn

1. **What PID 1 actually is** - The first userspace process
2. **How kernels find and start init** - The `/init` lookup process
3. **What initramfs is** - Initial RAM filesystem format
4. **Minimal requirements for boot** - Almost nothing!
5. **Console/TTY basics** - How output reaches you

## Why This is Simpler Than Cuttlefish

**Cuttlefish complexity:**
- AVB signing and verification
- TAP device networking
- ADB infrastructure
- Multiple partitions (system, vendor, boot)
- Android-specific init configuration
- SELinux policies

**This setup:**
- ✅ Just a kernel + one binary
- ✅ Boots in seconds locally
- ✅ Direct console output
- ✅ No signing, no devices, no network
- ✅ Works on macOS via Nix (no remote host needed)

## What This Demonstrates

This is a **real Linux boot**. The same kernel mechanisms that boot Android, Ubuntu, or any Linux system:

1. Kernel decompresses initramfs into RAM
2. Kernel mounts it as root filesystem
3. Kernel executes `/init` as PID 1
4. Init sets up the system and runs forever

## Architecture

```
┌─────────────────────────────────────┐
│   Your Mac / Linux Machine          │
│                                     │
│  ┌───────────────────────────────┐ │
│  │        QEMU VM                │ │
│  │                               │ │
│  │  ┌──────────────────────┐    │ │
│  │  │   Linux Kernel       │    │ │
│  │  │  (from Nix)          │    │ │
│  │  └──────────┬───────────┘    │ │
│  │             │ unpacks         │ │
│  │             ↓                 │ │
│  │  ┌──────────────────────┐    │ │
│  │  │   initramfs.cpio.gz  │    │ │
│  │  │   (just /init)       │    │ │
│  │  └──────────┬───────────┘    │ │
│  │             │ executes        │ │
│  │             ↓                 │ │
│  │  ┌──────────────────────┐    │ │
│  │  │   PID 1: /init       │    │ │
│  │  │   (Zig binary)       │    │ │
│  │  │   - prints heartbeat │    │ │
│  │  │   - loops forever    │    │ │
│  │  └──────────────────────┘    │ │
│  │                               │ │
│  │  Console output → stdio       │ │
│  └───────────────────────────────┘ │
│                                     │
│  You see: heartbeat messages        │
└─────────────────────────────────────┘
```

## Quick Start

1. **Enter Nix environment** (provides zig, qemu, kernel):
   ```bash
   cd /Users/justin/code/boom
   nix develop
   ```

2. **Build everything and boot**:
   ```bash
   cd qemu-init
   ./build.sh              # Compile init.zig → Linux binary
   ./build-initramfs.sh    # Pack init into cpio archive
   ./run-qemu.sh           # Boot in QEMU
   ```

3. **Watch it boot**:
   - You'll see kernel boot messages
   - Then our init announces itself
   - Then heartbeat messages every 2 seconds
   - **Exit:** Press `Ctrl+A`, release, then press `X`

## Files

- **`init.zig`** – the PID 1 implementation (heavily commented).
- **`test_child.zig`** – helper program PID 1 supervises during tests.
- **`test_input.zig`** – tiny `/dev/input` explorer used by `test-phase7.sh`.
- **`build.sh`** – compiles all Zig helpers (init/test_child/test-input) into the repo root.
- **`build-initramfs.sh`** – assembles `initramfs.cpio.gz`, pulling optional extras (drm_rect, compositor-rs, libs) if present.
- **`run.sh`** – launches QEMU with kernel + initramfs and validates the output.
- **`rootfs/`** – overlay copied into the initramfs (e.g., `/etc/profile`, `/usr/bin/start-weston`).
- **`nix/`** – helper Nix expressions for kernels and the Weston rootfs.

### Generated / Ignored Artifacts

Everything below is ignored by git and recreated on demand:

- `bzImage` – built via `./build-kernel-linux.sh` or `./download-kernel.sh`.
- `weston-rootfs` – symlink produced by `nix build ..#weston-rootfs`.
- `kernel-modules/` – optional `.ko` blobs copied into the initramfs.
- `drm_rect`, `compositor-rs`, `test-client` – optional demos you can copy in before running `build-initramfs.sh`.
- glibc/libdrm shared objects – fetched automatically from Nix when `drm_rect` is present (or copy them manually if you build outside of Nix).

If you rebuild any of the optional binaries, drop them beside `init` before running `./build-initramfs.sh`; they will be detected automatically.

## What to Try


### 1. Understand What's Happening
- Read through `init.zig` - see how simple PID 1 can be
- Look at the comments in each script
- Boot it and watch the output

### 2. Modify the Init
Try changing `init.zig`:
```zig
// Change the heartbeat message
try stdout.print("[CUSTOM] I'm alive! {d}\n", .{timestamp});

// Change the sleep duration
std.time.sleep(5 * std.time.ns_per_s);  // 5 seconds

// Add more info
try stdout.print("Free memory: TODO\n", .{});
```

Then rebuild and reboot:
```bash
./build.sh && ./build-initramfs.sh && ./run-qemu.sh
```

### 3. Add Filesystem Operations
Next level: try mounting filesystems:
```zig
// Add to init.zig (need to import more from std.os)
const ret = linux.mount("proc", "/proc", "proc", 0, 0);
```

### 4. Read Kernel Command Line
See what the kernel passed to init:
```zig
// Read /proc/cmdline to see boot parameters
const file = try std.fs.openFileAbsolute("/proc/cmdline", .{});
defer file.close();
// ... read and print
```

## Troubleshooting

**"Error: zig: command not found"**
- Make sure you ran `nix develop` first
- Zig is provided by the Nix environment

**"Error: Could not find Linux kernel"**
- You need to be in the Nix shell
- The kernel is at `/nix/store/*/linux-*/bzImage`

**"QEMU won't exit"**
- Press `Ctrl+A`, release it, then press `X`
- Or `Ctrl+C` to force quit

**"Kernel panic: not syncing"**
- Likely your init exited or crashed
- Check the error message right before panic
- Make sure init loops forever (never returns)

## Next Steps

Once you understand this:

1. **Add signal handling** - Handle SIGTERM to shutdown gracefully
2. **Mount filesystems** - proc, sys, dev
3. **Spawn a shell** - fork() + exec() /bin/sh
4. **Reap zombies** - Handle SIGCHLD
5. **Then** apply this knowledge to Android/Cuttlefish!

## Educational Value

This setup eliminates all the complexity that was blocking your understanding:

- ❌ No AVB signing headaches
- ❌ No TAP device permissions
- ❌ No remote host infrastructure
- ❌ No "why can't I see console output?"
- ❌ No 90-second boot cycles

You get:

- ✅ Instant feedback (boots in 2 seconds)
- ✅ Clear cause and effect
- ✅ Direct kernel→init interaction
- ✅ Foundation for understanding real systems

**This is how init systems actually work.** Once you master this, Cuttlefish/Android will make much more sense.
