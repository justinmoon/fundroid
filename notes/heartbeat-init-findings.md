# Heartbeat Init (PID1) Demo – Implementation Findings

**Date:** 2025-10-24  
**Branch:** minimal-pid1  
**Worktree:** /Users/justin/code/boom/worktrees/minimal-pid1

## Summary

We successfully implemented a minimal PID1 heartbeat program and the tooling to build, repack, and deploy it to Cuttlefish. However, testing revealed a fundamental issue with the approach: the VM bootloops because our minimal init doesn't satisfy Android's boot requirements.

## What We Implemented

### 1. Heartbeat Init Binary
**Location:** `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`

A minimal C program that:
- Mounts `/proc`, `/sys`, and `/dev` filesystems
- Opens `/dev/console` (with fallback to `/dev/ttyS0`) and duplicates to stdin/stdout/stderr
- Prints `VIRTUAL_DEVICE_BOOT_COMPLETED` marker
- Prints timestamped heartbeat messages: `[cf-heartbeat] <epoch>`
- Originally designed to loop forever printing heartbeats every 5 seconds
- Later modified to print 3 heartbeats then exec `/init.stock` to chain to the real Android init

**Build:** Statically linked using `zig cc -target x86_64-linux-musl -static`
- Binary size: ~945KB
- Output: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init`

### 2. Build and Repack System
**Location:** `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/Makefile`

Targets:
- `all`: Builds the static heartbeat_init binary
- `repack`: Extracts stock init_boot.img, modifies ramdisk, rebuilds image
- `clean`: Removes build artifacts

**Repack Process:**
1. Extract boot image with `unpack_bootimg`
2. Decompress LZ4-compressed ramdisk
3. Use `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/cpio_edit.py` to:
   - Rename `/init` → `/init.stock` (preserving stock init)
   - Add `heartbeat_init` as new `/init`
4. Recompress ramdisk with `lz4 -l -9`
5. Repack with `mkbootimg --header_version 4`

**Stock Image Source:**  
Downloaded from Hetzner host at `/var/lib/cuttlefish/images/init_boot.img`  
Cached locally at `/Users/justin/code/boom/worktrees/minimal-pid1/init_boot.stock.img`

### 3. End-to-End Test Script
**Location:** `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/test-heartbeat.sh`

Workflow:
1. Build heartbeat_init binary
2. Repack init_boot.img with custom init
3. Upload to Hetzner: `scp ... hetzner:/tmp/heartbeat-init_boot.img`
4. Create Cuttlefish instance: `cfctl instance create --purpose heartbeat`
5. Deploy custom init_boot: `cfctl deploy --init /tmp/heartbeat-init_boot.img <instance>`
6. Start instance: `cfctl instance start <instance> --timeout-secs 180`
7. Poll console logs for heartbeat markers
8. Clean up: `cfctl instance destroy <instance>`

**Justfile Integration:**  
Added `just heartbeat-test` target at `/Users/justin/code/boom/worktrees/minimal-pid1/justfile:139-140`

### 4. Bug Fixes Along the Way

**Fixed in cuttlefish_instance.sh:**  
`/Users/justin/code/boom/worktrees/minimal-pid1/scripts/cuttlefish_instance.sh`
- Lines 321-355: Removed invalid `local` declarations outside function scope in the `deploy` case block
- This was preventing the script from running in bash

## What Worked

✅ **Build Process:** Heartbeat init compiles cleanly as a static x86-64 binary  
✅ **Image Extraction:** Successfully extracts LZ4-compressed ramdisk from boot image header v4  
✅ **CPIO Manipulation:** `cpio_edit.py` correctly renames and adds files to the ramdisk  
✅ **Image Repacking:** Creates valid boot image with `mkbootimg`  
✅ **File Upload:** Successfully uploads to Hetzner  
✅ **Instance Creation:** `cfctl instance create` works  
✅ **Image Deployment:** `cfctl deploy` accepts custom init_boot.img

## What Didn't Work

❌ **VM Boot:** The VM enters a boot loop and never reaches Linux userspace

### Boot Loop Evidence

From console logs (instance 59, 60):
```
GUEST_UBOOT_VERSION: 2024.04-gc8fc3d1d8ce6-ab13197479 (Mar 10 2025 - 22:48:14 +0000)
U-Boot 20
secure_env detected guest reboot, restarting.
```

This pattern repeats continuously. Key observations:

1. **U-Boot loads:** We see the bootloader version message
2. **No kernel messages:** No Linux kernel boot output appears
3. **No init output:** Our `VIRTUAL_DEVICE_BOOT_COMPLETED` marker never appears
4. **Continuous reboot cycle:** VM reboots every ~10-15 seconds
5. **Host-side errors:**
   - "timeout waiting for adb device 127.0.0.1:6579"
   - "secure_env detected guest reboot, restarting"
   - netsimd segfaults occasionally

### What We Don't See

- No kernel boot messages (`Linux version`, `Command line:`, etc.)
- No initramfs messages
- No output from our heartbeat_init program
- No evidence that `/init` (our binary) ever executes

## Root Cause Analysis

### Theory 1: Boot Image Format Mismatch
The repacked init_boot.img might be missing critical boot parameters. When we repack with `mkbootimg --header_version 4 --ramdisk ramdisk_modified`, we only provide:
- Header version
- Ramdisk

We don't preserve from the original:
- Kernel command line
- DTB (device tree blob)
- OS version / patch level
- Other header fields

**Evidence:** The stock init_boot.img likely has metadata that our repack discards.

### Theory 2: Verified Boot / AVB
Android Verified Boot might be rejecting our modified image:
- The bootloader may validate signatures
- Cuttlefish might require signed images even in dev mode
- Our custom init_boot fails verification → bootloader refuses to boot

**Counter-evidence:** Cuttlefish typically disables AVB for development. The docs mention existing work with custom init images.

### Theory 3: Minimal Init Too Minimal
Our init doesn't:
- Set up critical devices that the kernel/bootloader expect
- Respond to any watchdog pings
- Create necessary directories or symlinks
- Handle any expected signals or IPC

**Counter-evidence:** We never even see evidence of the kernel booting, so this would only matter if the kernel itself had started.

### Theory 4: Ramdisk Corruption
The CPIO modification or LZ4 recompression might be corrupting the ramdisk:
- Wrong compression parameters
- Alignment issues in CPIO
- Missing trailing padding

**Evidence for this:** The boot_init.img format for header v4 is complex, and we're using generic `mkbootimg` without all original parameters.

## Diagnostic Commands Used

```bash
# Check what cfctl can do
ssh hetzner "cfctl --help"
ssh hetzner "cfctl instance --help"

# Create test instance
ssh hetzner "cfctl instance create --purpose heartbeat"

# Deploy custom image  
ssh hetzner "cfctl deploy --init /tmp/heartbeat-init_boot.img <instance>"

# Start and watch
ssh hetzner "cfctl instance start <instance> --timeout-secs 180"
ssh hetzner "cfctl logs <instance> --stdout --lines 300"

# Cleanup
ssh hetzner "cfctl instance destroy <instance> --timeout-secs 60"
```

## Files and Artifacts

### Source Code
- Heartbeat init: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`
- Makefile: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/Makefile`
- Test script: `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/test-heartbeat.sh`
- CPIO editor: `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/cpio_edit.py`
- Ramdisk extractor: `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/extract_ramdisk.py` (created but unused)

### Build Artifacts
- Binary: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init`
- Repacked image: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/init_boot.img`
- Stock image (cached): `/Users/justin/code/boom/worktrees/minimal-pid1/init_boot.stock.img`
- Build directory: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/.build/`

### Log Files
- Last test run: `/tmp/heartbeat-test.log`
- Debug run: `/tmp/cf-debug.log`

## Potential Fixes

### Option 1: Preserve Original Boot Parameters
Extract all boot image metadata from stock init_boot.img and pass to mkbootimg:
```bash
unpack_bootimg --boot_img init_boot.stock.img --out metadata/
# Extract: cmdline, os_version, os_patch_level, dtb, etc.
mkbootimg \
  --header_version 4 \
  --ramdisk ramdisk_modified \
  --cmdline "$(cat metadata/cmdline)" \
  --os_version "$(cat metadata/os_version)" \
  --os_patch_level "$(cat metadata/os_patch_level)" \
  ...
```

### Option 2: Use magiskboot Instead
The Makefile has fallback code for magiskboot. On Hetzner:
```bash
# On remote host
magiskboot unpack init_boot.img
# modify ramdisk
magiskboot repack init_boot.img
```
This preserves all original metadata automatically.

### Option 3: Wrapper Init That Chains Immediately
Instead of a minimal init that prints heartbeats forever:
1. Print markers quickly (3 heartbeats in 6 seconds)
2. exec `/init.stock` to hand off to real Android init
3. This proves our init ran while still allowing the system to boot properly

**Status:** This is what we modified the code to do, but didn't test yet.

### Option 4: Test Locally First
Before deploying to Cuttlefish:
```bash
# Extract stock ramdisk locally
unpack_bootimg --boot_img init_boot.stock.img

# Manually verify CPIO operations
lz4 -d ramdisk ramdisk.cpio
cpio -tv < ramdisk.cpio | grep "^-.*init$"  # Should see /init
python3 scripts/cpio_edit.py ...
cpio -tv < ramdisk_modified.cpio | grep init  # Should see /init and /init.stock

# Verify repack doesn't corrupt
lz4 -l -9 ramdisk_modified.cpio ramdisk_modified
mkbootimg --header_version 4 --ramdisk ramdisk_modified --output test.img
unpack_bootimg --boot_img test.img  # Should extract successfully
```

### Option 5: Check What Actually Got Deployed
SSH to Hetzner and inspect the deployed init_boot.img:
```bash
ssh hetzner
cd /home/justin/cuttlefish-instances/*/
ls -lh init_boot.img
unpack_bootimg --boot_img init_boot.img --out /tmp/inspect/
lz4 -d /tmp/inspect/ramdisk /tmp/inspect/ramdisk.cpio
cpio -tv < /tmp/inspect/ramdisk.cpio | grep init
```

### Option 6: Look at Existing Working Custom Init
The docs mention successful custom init work. Search for:
- `/Users/justin/code/boom/worktrees/minimal-pid1/docs/init-wrapper-notes.md`
- Mentions creating `init_boot.custom.img` with binary replacement
- Might have working mkbootimg incantation

## Questions for Further Investigation

1. **Does the stock init_boot.img have a kernel?**  
   Header v4 format can have kernel in init_boot or separate. Our mkbootimg only sets ramdisk.

2. **What does unpack_bootimg actually extract?**  
   Check `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/.build/` after a repack run.

3. **Does cfctl have a way to see kernel console output?**  
   We're looking at `cfctl logs --stdout` but that might be filtered.

4. **Can we deploy just a ramdisk.cpio without repacking?**  
   Some Android boot systems allow loading ramdisk separately from boot image.

5. **Is there a working example in the repo?**  
   Check the `init/` directory: `/Users/justin/code/boom/worktrees/minimal-pid1/init/`

## Update 2025-10-24 19:06 UTC - After Metadata Preservation Fix

### Changes Made
1. **Modified Makefile to preserve boot metadata:**
   - Use `unpack_bootimg --format=mkbootimg` to extract all original boot parameters
   - Capture output to `mkbootimg_args.txt`
   - Use `sed` to replace only the ramdisk path in the args
   - This preserves: `--header_version 4 --os_version 16.0.0 --os_patch_level 2025-06 --kernel ./kernel --ramdisk ./ramdisk --cmdline ''`

2. **Modified heartbeat_init.c to chain to stock init:**
   - Prints 3 heartbeat messages with 2-second delays
   - Calls `execl("/init.stock", "init", NULL)` to hand off to Android init
   - This should allow the system to boot properly after showing our markers

### Current Status
**STILL BOOTLOOPING** with identical symptoms:
- U-Boot loads repeatedly (`GUEST_UBOOT_VERSION: 2024.04...`)
- `secure_env detected guest reboot, restarting`
- No kernel boot messages
- No init execution (our heartbeat never prints)
- Timeout waiting for ADB device

### Hypothesis
The issue may not be metadata - the stock init_boot.img might have a kernel in a separate partition or the bootloader expects something else entirely. The fact that we see U-Boot but never see Linux kernel boot messages suggests:

1. **U-Boot can't find/load the kernel** - but init_boot shouldn't have a kernel (that's in boot.img)
2. **Something about the modified ramdisk causes rejection** - even though CPIO operations succeeded
3. **The compression or format isn't quite right** - despite using `lz4 -l` as recommended

### Need Help With
1. Should we try with stock `init_boot.img` first (no modifications) to see if deployment itself works?
2. Is there a way to get more verbose boot logs from the VM to see exactly where/why it's failing?
3. Could cfctl have a `--launch-arg` or `--no-netsim` flag to work around the netsimd crashes mentioned by the other agent?

## Conclusion

The implementation is **functionally complete** from a build/deploy perspective:
- ✅ C code compiles
- ✅ Boot image repacks
- ✅ Deploys to Cuttlefish
- ❌ VM doesn't actually boot with it

**The fundamental issue:** We're not preserving enough metadata from the stock boot image when repacking. The VM fails to boot before even loading the Linux kernel, suggesting bootloader-level rejection or missing boot parameters.

**Recommended next step:** Use magiskboot for repacking (if available on build host) or carefully extract and preserve all boot image metadata when using mkbootimg. The chain-to-stock-init approach (Option 3) should work once the boot image format issue is resolved.

## Related Documentation

- Original plan: `/Users/justin/code/boom/worktrees/minimal-pid1/plans/` (user provided in initial prompt)
- Boot wrapper notes: `/Users/justin/code/boom/worktrees/minimal-pid1/docs/init-wrapper-notes.md`
- Cuttlefish docs: `/Users/justin/code/boom/worktrees/minimal-pid1/docs/cuttlefish.md`
- AGENTS.md guidance: `/Users/justin/code/boom/worktrees/minimal-pid1/AGENTS.md`
