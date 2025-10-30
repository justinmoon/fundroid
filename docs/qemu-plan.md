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

## Next Steps

### Phase 2: Filesystem Setup
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

**Test:** Init should mount all three and print proof it worked.

### Phase 3: Signal Handling
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

**Test:** Send SIGTERM, verify clean unmount and exit.

### Phase 4: Process Management
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

**Test:** Init spawns a child that prints and exits, init reaps it and respawns.

### Phase 5: Service Management (Optional)
**Goal:** Basic service supervision.

**Tasks:**
1. Read a simple config file (list of services to run)
2. Start multiple services
3. Monitor and restart them if they crash
4. Shutdown in order

**What you'll learn:**
- Service dependency (startup order)
- Health checking
- Graceful shutdown

**Test:** Start 2-3 dummy services, kill one, watch it respawn.

## Phase 6: Apply to Cuttlefish

**Goal:** Take everything learned and fix the original Android init problem.

**Tasks:**
1. Review `heartbeat-init/heartbeat_init.c` with new understanding
2. Identify what's missing or broken
3. Apply fixes based on what we learned in QEMU
4. Test on Cuttlefish
5. Iterate until it works

**Key differences to handle:**
- Android expects specific mounts
- SELinux contexts
- Property service
- May need to chain to stock init eventually

## Decision Points

At each phase, you can:
- **Continue learning:** Move to next phase in QEMU
- **Apply now:** Jump to Cuttlefish and use current knowledge
- **Iterate:** Go back and improve earlier phases

The QEMU environment stays simple and fast for experimentation. Once you understand the concepts, applying them to Android becomes much clearer.

## Current Question

**Where do you want to go next?**
1. Phase 2: Add filesystem mounts in QEMU
2. Jump to Cuttlefish now and apply current knowledge
3. Something else?

The incremental approach means you can learn at your own pace and always have a working system to refer back to.
