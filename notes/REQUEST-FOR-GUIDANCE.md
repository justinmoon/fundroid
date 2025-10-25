# Request for Guidance: Standalone Heartbeat PID1 Implementation

**Date:** 2025-10-25  
**Branch:** minimal-pid1  
**Worktree:** `/Users/justin/code/boom/worktrees/minimal-pid1`

## Context

We successfully implemented a **chainloader** version of heartbeat init that:
- ✅ Builds and deploys correctly
- ✅ Kernel boots with our custom PID1
- ✅ Prints initial markers
- ✅ Chains to stock Android init via `execl("/init.stock")`
- ✅ Android boots fully with ART/JVM
- ✅ Test passes end-to-end

**However, this deviates from the original requirements.**

## Original Requirements (From Initial Prompt)

Build a minimal PID 1 program that:

1. **Mounts filesystems:**
   - `proc`, `sysfs`, `devtmpfs`

2. **Console setup:**
   - Opens `/dev/console`
   - Emits a single `VIRTUAL_DEVICE_BOOT_COMPLETED` marker

3. **Heartbeat loop:**
   - Prints timestamped heartbeat every 5 seconds
   - Format: `[cf-heartbeat] <epoch>`
   - **Runs indefinitely as PID 1**

4. **Signal handling:**
   - Cleanly handles SIGTERM
   - Unmounts filesystems before exit

5. **No Android framework:**
   - Stays as PID1 (doesn't exec stock init)
   - **Zero JVM code**
   - Just the minimal C program running forever

## What We Currently Have

**File:** `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`

```c
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    fprintf(stderr, "[cf-heartbeat] PID1 starting, chaining to /init.stock\n");
    
    execl("/init.stock", "init", NULL);  // ← PROBLEM: We exec instead of loop
    
    fprintf(stderr, "[cf-heartbeat] exec failed, hanging\n");
    while(1) sleep(999);
}
```

This is a **chainloader**, not a standalone init.

## Why We Deviated

Every attempt at a standalone PID1 with the original requirements caused bootloops:

### Complex Version (Commit 4d1ba9e)
**File:** Previous version with full implementation

Had:
- Filesystem mounts
- Console setup via dup2
- Device checks (/dev/null, /dev/urandom, /dev/kmsg)
- Dual logging (stderr + kmsg)
- Attempted chain to stock init

**Result:** Kernel booted but system immediately rebooted. No visible output. Suspect the device checks or complex logging crashed before exec.

### Simple Chainloader (Current, Commit d51de89)
Removed everything except:
- Two print statements
- Immediate exec to stock init

**Result:** ✅ Works perfectly. Android boots, ADB connects, system runs.

### The Problem
We never successfully tested a version that:
- Does the mounts
- Sets up console
- **Stays as PID1 in an infinite loop**
- Doesn't exec stock init

Because every complex version crashed and we couldn't see console output (due to `console=ttynull` in kernel cmdline).

## Core Questions for Guidance

### 1. Console Output Visibility
**Problem:** Kernel command line has `console=ttynull` which discards all output.

**Question:** How do we see output from our PID1 when the console is nulled?

Options tried:
- ❌ stdout/stderr - goes to ttynull
- ❌ /dev/kmsg writes - not visible in logs we can access
- ❌ Console setup with dup2 - caused crashes

What's the correct way to get visible output for debugging?

### 2. Minimal Infrastructure Required
**Problem:** When we added mounts and device checks, the system crashed.

**Question:** What's the absolute minimum our PID1 must do to keep the system alive without Android?

Our attempts:
- ❌ Mount proc/sys/dev + device checks → crashed
- ❌ Console setup + logging → crashed  
- ✅ Just exec → works but defeats purpose

What infrastructure does a standalone PID1 need for Cuttlefish to not reboot?

### 3. Watchdog or Reboot Mechanism
**Problem:** The VM reboots every ~15-30 seconds when our init doesn't call exec.

**Question:** Is there a watchdog timer or reboot mechanism we need to handle?

Evidence:
- Stock init: system stays up
- Our chainloader: system stays up (because it hands off to stock)
- Our standalone attempts: system reboots after <30s

What's triggering the reboot? How do we prevent it?

### 4. ADB Dependency
**Problem:** cfctl waits for ADB to come up, times out if it doesn't.

**Question:** Does our standalone PID1 need to provide ADB infrastructure?

If we're running indefinitely as PID1 without Android framework:
- No adbd will start (it's an Android service)
- cfctl will timeout waiting for ADB
- But that's okay if the VM is actually running?

How do we verify the system is running without ADB?

### 5. Secure Environment (secure_env)
**Problem:** Logs show `secure_env detected guest reboot` and crashes.

**Question:** Does secure_env depend on specific setup from init?

When we stay as PID1:
- Does secure_env expect certain devices/mounts?
- Does it communicate with init somehow?
- Can we disable secure_env for this minimal use case?

### 6. Device Node Creation
**Problem:** Unsure if devtmpfs provides all needed devices automatically.

**Question:** Do we need to manually create device nodes with mknod?

Should we create:
- `/dev/null`
- `/dev/console`
- `/dev/urandom`
- `/dev/kmsg`
- Others?

Or does the kernel/devtmpfs handle this?

## Files to Review

### Current Working Chainloader
- `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c` (current simple version)
- `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/Makefile` (build system with AVB)
- `/Users/justin/code/boom/worktrees/minimal-pid1/scripts/test-heartbeat.sh` (E2E test)

### Previous Complex Attempts
Look in git history:
- Commit 12a8ed9: Version with mounts, console setup, device checks, dual logging
- That version has all the infrastructure code but crashes

### Documentation
- `/Users/justin/code/boom/worktrees/minimal-pid1/notes/heartbeat-init-findings.md`
- `/Users/justin/code/boom/worktrees/minimal-pid1/notes/STATUS.md`
- `/Users/justin/code/boom/worktrees/minimal-pid1/notes/debugging-invisible-init.md`

## What We Need

**Step-by-step guidance on building a standalone PID1 that:**

1. **Boots successfully** (doesn't cause immediate reboot/crash)
2. **Has visible output** (we can see the heartbeat messages)
3. **Runs indefinitely** (infinite loop with 5-second heartbeat)
4. **Handles required infrastructure** (minimum mounts/devices to stay alive)
5. **No Android framework** (no exec to stock init, zero JVM)
6. **Responds to SIGTERM** (clean shutdown with unmount)

## Specific Technical Guidance Needed

### Code Structure
Should it be:
```c
int main(void) {
    // 1. Mount what? (proc/sys/dev? others?)
    
    // 2. Console setup how? (dup2? open? skip?)
    
    // 3. Create devices? (mknod? rely on devtmpfs?)
    
    // 4. Signal handlers for what? (SIGTERM? SIGCHLD? others?)
    
    // 5. Infinite loop:
    while (running) {
        print_heartbeat();
        sleep(5);
    }
    
    // 6. Cleanup on SIGTERM
}
```

What goes in each section?

### Debugging Strategy
How do we see output when `console=ttynull`?
- Change kernel cmdline?
- Use different console device?
- Write to a file that persists?
- Use serial console somehow?

### Preventing Reboot
What keeps the system from rebooting when init is just looping?
- Does something expect init to spawn processes?
- Is there a watchdog checking for activity?
- Does Cuttlefish have specific requirements?

### Verification Without ADB
How do we know it's working if there's no ADB?
- File creation tests?
- Network ping?
- Serial console access?
- Some other signal?

## Success Criteria

We'll know we succeeded when:
1. **Test passes:** `just heartbeat-test` completes without errors
2. **System stays up:** No reboot loop, runs for minutes/hours
3. **Heartbeats visible:** We can see `[cf-heartbeat] <timestamp>` messages
4. **No Android:** System doesn't have ART/Zygote/framework running
5. **Clean shutdown:** SIGTERM causes unmount and graceful exit

## Current Build System

All the infrastructure is ready:
- ✅ Static musl builds work
- ✅ Init_boot.img repacking works  
- ✅ AVB signing works
- ✅ Deployment to Cuttlefish works
- ✅ Kernel boots with our code

We just need the **correct C implementation** that meets the spec.

## Request

Please provide either:

**Option A:** Detailed code review and fixes for commit 12a8ed9's complex version  
**Option B:** New implementation from scratch with explanations  
**Option C:** Step-by-step debug approach to incrementally build from working chainloader

Focus on:
- Why the complex version crashed
- What minimum setup is actually needed
- How to keep the system alive without Android
- How to make output visible for testing

Thank you!
