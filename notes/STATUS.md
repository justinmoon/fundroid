# Heartbeat Init Status - 2025-10-24

## ✅ MAJOR MILESTONE ACHIEVED

**The kernel is now booting!** This is a huge breakthrough from the U-Boot bootloop.

### What Works

1. **✅ Build System Complete**
   - Static musl binary builds correctly
   - Boot image extraction and modification works
   - AVB signing with AOSP test key successful
   - Public key SHA1 matches stock: `2597c218aae470a130f61162feaae70afd97f011`

2. **✅ Bootloader Accepts Image**
   - U-Boot no longer bootloops
   - Bootloader accepts AVB-signed init_boot.img
   - Kernel loads and boots

3. **✅ Kernel Boot Confirmed**
   - First time seeing: `GUEST_KERNEL_VERSION: 6.12.18-android16-1-g50eb8d5d443b-ab13257114`
   - `Linux version` message appears in logs
   - This proves our modified init_boot.img is bootable

### Current Issue

**secure_env crash during init:**
```
Exec failed, secure_env is out of sync with the guest: 2(No such file or directory)
Detected unexpected exit of monitored subprocess /var/lib/cuttlefish/bin/secure_env
Subprocess /var/lib/cuttlefish/bin/secure_env (3394395) was interrupted by a signal 'Aborted' (6)
```

This happens after kernel boot but before full userspace initialization. The VM doesn't reach the point where ADB becomes available.

### Unknown Status

**Heartbeat messages:** We haven't confirmed yet whether our init actually runs and prints the heartbeat messages. The console logs via cfctl may not be capturing early boot output, or our init might be crashing before printing.

### Next Steps

1. **Verify init execution:**
   - Access console logs directly (not via cfctl which seems unstable)
   - Check if VIRTUAL_DEVICE_BOOT_COMPLETED and cf-heartbeat messages appear
   - Confirm our init runs before secure_env crash

2. **Fix secure_env crash:**
   - Investigate what secure_env expects from init
   - May need to set up additional environment/mounts before chaining to stock init
   - Or may need to chain to stock init immediately without delays

3. **Alternative approaches if needed:**
   - Print heartbeat from a different stage (early in stock init?)
   - Use kernel command line to add debug output
   - Modify stock init instead of replacing it entirely

## Files

- Source: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`
- Makefile: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/Makefile`  
- Test script: `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/test-heartbeat.sh`
- AVB key: `/Users/justin/code/boom/worktrees/minimal-pid1/third_party/avb/testkey_rsa4096.pem`

## Key Technical Details

**Boot image parameters (from stock):**
- Image size: 8388608 bytes (8MB)
- Algorithm: SHA256_RSA4096
- Rollback Index: 1749081600
- Rollback Index Location: 0
- Partition: init_boot

**Our modifications:**
- Ramdisk size increased from 3325952 to 3633152 bytes (still well under 8MB limit)
- `/init` renamed to `/init.stock`
- Custom `heartbeat_init` binary added as `/init`
- AVB hash footer recalculated and signed with test key

**The breakthrough:** Adding AVB signature was the key. Without it, bootloader rejected the image causing immediate U-Boot bootloop. With proper signature, bootloader accepts and loads the kernel.
