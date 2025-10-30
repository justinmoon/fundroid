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

**Acceptance Criteria:**
- ✅ `./run.sh` boots without kernel panic
- ✅ Output shows "QEMU MINIMAL INIT" banner
- ✅ Output shows `PID: 1`
- ✅ At least 3 heartbeat messages printed with incrementing timestamps
- ✅ System stays running until timeout (doesn't crash or exit)

## Next Steps

### ✅ Phase 2: Filesystem Setup (COMPLETE)
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

**Acceptance Criteria:**
- ✅ Output shows "[OK] Mounted /proc (process information)"
- ✅ Output shows "[OK] Mounted /sys (kernel/device info)"
- ✅ Output shows "[OK] Mounted /dev (device nodes)"
- ✅ Successfully reads `/proc/self/status` and prints "Pid: 1"
- ✅ Counts and prints device count in /dev (should be > 50)
- ✅ Output shows "[SUCCESS] All filesystems mounted and verified!"
- ✅ No mount errors in output
- ✅ Heartbeat continues after filesystem setup

### ✅ Phase 3: Signal Handling (COMPLETE)
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

**Acceptance Criteria:**
- ✅ Output shows "Signal handler installed for SIGTERM"
- ✅ Output shows "Signal handler installed for SIGINT"
- ✅ Output shows "Signal handler installed for SIGCHLD"
- ✅ Signal handlers use correct `.c` calling convention for C ABI
- ✅ SIGCHLD handler reaps zombies with `waitpid(-1, WNOHANG)`
- ✅ SIGTERM/SIGINT set shutdown flag
- ✅ Heartbeat loop checks shutdown_requested flag
- ✅ Shutdown sequence implemented: unmount /dev, /sys, /proc
- ✅ Exit with code 0 via `posix.exit(0)`

**Note:** Full shutdown testing requires child processes (Phase 4) or kernel poweroff mechanism.

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

**Acceptance Criteria:**
- [ ] Create a test binary that prints "Hello from child" and exits
- [ ] Include test binary in initramfs
- [ ] Output shows "Spawning child process: /test_child"
- [ ] Output shows child's output: "Hello from child"
- [ ] Output shows "Child process PID <pid> exited with status 0"
- [ ] Output shows "Respawning child process in 1 second..."
- [ ] Child is respawned at least 3 times
- [ ] Each respawn shows a new PID
- [ ] No zombie processes (verify `/proc/self/status` shows Threads: 1)
- [ ] SIGCHLD handler successfully reaps all children
- [ ] Heartbeat continues between child respawns

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

**Acceptance Criteria:**
- [ ] Create `services.conf` listing 3 test services
- [ ] Include services.conf in initramfs
- [ ] Output shows "Loading service configuration from /services.conf"
- [ ] Output shows "Starting service: service1" (for each service)
- [ ] All 3 services show PID assigned
- [ ] From host, identify one child PID and `kill -9 <pid>`
- [ ] Output shows "Service service1 (PID <pid>) crashed with signal 9"
- [ ] Output shows "Restarting service: service1"
- [ ] Service1 gets a new PID
- [ ] Other services continue running unaffected
- [ ] On SIGTERM, output shows "Stopping services in reverse order..."
- [ ] Each service terminated gracefully before unmounting filesystems
- [ ] Output shows final service count: "All 3 services stopped"

