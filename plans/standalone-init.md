# Standalone Heartbeat PID1 Implementation Plan

**Goal:** Implement a minimal PID1 that runs indefinitely printing heartbeats every 5 seconds, with no Android framework or JVM.

## Implementation Steps

### 1. Fix Console Visibility in Makefile
**Problem:** Current cmdline has `console=ttynull` which discards all output.

**Solution:** Strip existing console/earlycon parameters and add:
- `console=ttyS0`
- `earlycon=uart8250,io,0x3f8,115200`
- `ignore_loglevel` (force all printk through)

**Changes to Makefile:**
- After extracting mkbootimg_args.txt
- Parse original cmdline
- Remove any `console=*` and `earlycon=*`
- Append new console parameters
- Pass modified cmdline to mkbootimg

### 2. Implement Standalone PID1 Loop
**Replace chainloader with:**
```c
- Mount devtmpfs, proc, sysfs
- Setup console (open /dev/console, dup2 to stdio)
- Signal handler for SIGTERM
- Print VIRTUAL_DEVICE_BOOT_COMPLETED
- Infinite loop:
  - Print [cf-heartbeat] <epoch>
  - fsync(STDOUT_FILENO)
  - sleep(5) with EINTR handling
- On SIGTERM: unmount, exit cleanly
```

**Key points:**
- Never exit on errors (no abort)
- No complex device checks
- Rely on devtmpfs for device nodes
- Unbuffered stdio

### 3. Update Test Script
**Changes:**
- Pass launch flags: `--timeout-secs 0 --verify-boot false --launch-arg="--restart_subprocesses=false"`
- Don't expect ADB connection
- Use `cfctl logs --stdout --follow` to tail heartbeats
- Look for multiple `[cf-heartbeat]` messages (not just boot marker)
- Let it run for 20-30 seconds to confirm heartbeat loop
- Verify clean shutdown on destroy

### 4. Testing Strategy
- Start instance (won't timeout since verify-boot=false)
- Tail console logs to see heartbeats
- Confirm messages appear every 5 seconds
- Send SIGTERM via destroy
- Verify clean unmount and exit

## Success Criteria

- [x] Builds static binary
- [x] Repacks with proper AVB signature
- [ ] Console output visible (console=ttyS0)
- [ ] System stays up indefinitely (no reboot loop)
- [ ] Heartbeat messages appear every 5 seconds
- [ ] No Android framework running
- [ ] Clean shutdown on SIGTERM

## Files to Modify

1. `heartbeat-init/heartbeat_init.c` - Implement standalone loop
2. `heartbeat-init/Makefile` - Fix cmdline in repack target
3. `scripts/test-heartbeat.sh` - Update launch flags and verification
