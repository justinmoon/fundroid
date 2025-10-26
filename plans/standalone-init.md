# Standalone Heartbeat PID1 Implementation Plan

**Goal:** Implement a minimal PID1 that runs indefinitely printing heartbeats every 5 seconds, with no Android framework or JVM.

## Implementation Steps

### 1. Fix Console Visibility in Makefile ✅ COMPLETE
**Problem:** Current cmdline has `console=ttynull` which discards all output.

**Solution:** Strip existing console/earlycon parameters and add:
- `console=ttyS0`
- `earlycon=uart8250,io,0x3f8,115200`
- `ignore_loglevel` (force all printk through)

**Implementation (commit 8904245):**
- Python-based parser extracts cmdline from mkbootimg_args.txt (macOS compatible)
- Properly strips both single and double quotes using `chr(39)`
- Removes existing console/earlycon parameters via sed
- Appends new console parameters: `console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel`
- Fallback includes all required flags: `printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig`
- Added .gitignore entries for build artifacts and editor directories

**Test Results:**
- ✅ Builds successfully on macOS
- ✅ Quotes properly stripped from cmdline
- ✅ Instance boots with VIRTUAL_DEVICE_BOOT_COMPLETED marker visible
- ✅ test-heartbeat.sh passes consistently

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
- [x] Console output visible (console=ttyS0) - **Experiment 1 Complete**
- [ ] System stays up indefinitely (no reboot loop)
- [ ] Heartbeat messages appear every 5 seconds
- [ ] No Android framework running
- [ ] Clean shutdown on SIGTERM

## Files to Modify

1. `heartbeat-init/heartbeat_init.c` - Implement standalone loop
2. `heartbeat-init/Makefile` - Fix cmdline in repack target
3. `scripts/test-heartbeat.sh` - Update launch flags and verification
