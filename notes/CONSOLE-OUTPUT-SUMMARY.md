# Console Output Investigation Summary

**Date:** 2025-11-11  
**Branch:** cf-console  
**Problem:** Cannot see ANY output from custom PID1, even after implementing recommended console setup  
**Repository:** /home/justin/code/fundroid/worktrees/cf-console

## Goal

Implement a standalone PID1 that prints heartbeat messages every 5 seconds, visible in console logs.

## Current Status

### 2025-11-11 – Cfctl console capture
- Instance **43** (created with `cfctl instance create-start --purpose ci --verify-boot --disable-webrtc`) has its artifacts checked into `notes/cf-pid1-logging/step1-instance43/` (console_log/kernel/logcat/cfctl dumps).
  - `init: starting service 'ueventd'...` appears in `notes/cf-pid1-logging/step1-instance43/console_log.txt:1147`.
  - SurfaceFlinger chatter is visible in the same file at lines 3424–3543 (search for `surfaceflinger`); the exact snippets are captured in git so they can be reviewed offline.
- This works because cfctl now passes `--extra_kernel_cmdline=console=ttyS0,115200` to `launch_cvd` (`cuttlefish/cfctl/src/daemon/manager.rs:2115`), so the saved `console_log` plus the committed logcat/kernel dumps satisfy the Step 1 acceptance test without needing access to `/var/lib/cuttlefish`.

✅ **What Works:**
- Static musl binary compiles successfully
- init_boot.img repacks with our binary
- AVB signing successful (bootloader accepts image)
- Kernel boots and starts our /init as PID1
- Simple chainloader that execs to stock init works perfectly

❌ **What Doesn't Work:**
- **ZERO output from our init appears in any log file**
- Even simplest possible `write()` calls produce no visible output
- Standalone init (without exec to stock) has invisible output

## Environment

**Platform:** Cuttlefish on Hetzner host  
**Kernel:** 6.12.18-android16-1-g50eb8d5d443b-ab13257114  
**Architecture:** x86_64  
**Compiler:** zig cc targeting x86_64-linux-musl (static)

## What We've Tried

### Attempt 1: Simple Write to FDs 1 & 2

**File:** `test_print_only.c`  
**Code:**
```c
int main(void) {
    const char *msg = "INIT_STARTED\n";
    write(2, msg, 13);  // stderr
    write(1, msg, 13);  // stdout
    while(1) sleep(999);
}
```

**Result:**
- Kernel.log shows: `[    0.962518] Run /init as init process`
- Then nothing - no "INIT_STARTED" message
- Process appears to run (no kernel panic)
- System bootloops after ~60 seconds (timeout)

### Attempt 2: Console Setup with TIOCSCTTY

**File:** `test_console_setup.c`  
**Code:**
```c
int main(void) {
    // Mount devtmpfs first
    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, NULL);
    
    // Create /dev/console
    mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    
    // Open with retries
    int fd = -1;
    for (int tries = 50; tries-- && (fd = open("/dev/console", O_RDWR)) < 0; ) {
        usleep(100000);  // 100ms between retries
    }
    
    // Set as controlling terminal
    if (fd >= 0) {
        ioctl(fd, TIOCSCTTY, 0);
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
    
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("CONSOLE_TEST: printf works\n");
    fprintf(stderr, "CONSOLE_TEST: fprintf stderr works\n");
    write(1, "CONSOLE_TEST: raw write works\n", 30);
    
    execl("/init.stock", "init", NULL);
    while(1) sleep(999);
}
```

**Result:**
- Kernel.log shows: `[    0.969526] Run /init as init process`
- Then nothing - no "CONSOLE_TEST" messages
- System bootloops (kernel version appears multiple times)
- Instance eventually times out waiting for ADB

### Attempt 3: Full Standalone Implementation

**File:** `heartbeat_init.c` (current)  
**Code:**
```c
int main(void) {
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGHUP, on_term);
    signal(SIGPIPE, SIG_IGN);

    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC);
    mount_fs("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV);
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID|MS_NOEXEC|MS_NODEV);

    // Same TIOCSCTTY console setup as attempt 2
    mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    int fd = open(...);  // with retries
    ioctl(fd, TIOCSCTTY, 0);
    dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
    setvbuf unbuffered...

    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    
    // Write to kmsg too
    int k = open("/dev/kmsg", O_WRONLY|O_CLOEXEC);
    if (k >= 0) {
        dprintf(k, "<6>[heartbeat] init %ld\n", (long)time(NULL));
        close(k);
    }

    while (running) {
        printf("[cf-heartbeat] %ld\n", (long)time(NULL));
        sleep(5);
    }
    
    // unmount on SIGTERM...
}
```

**Result:**
- Same as attempt 2 - no output visible
- Bootloop pattern continues

### Attempt 4: Working Chainloader (for comparison)

**File:** `heartbeat_init_v2.c`  
**Code:**
```c
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    fprintf(stderr, "[cf-heartbeat] PID1 starting, chaining to /init.stock\n");
    
    execl("/init.stock", "init", NULL);
    
    fprintf(stderr, "[cf-heartbeat] exec failed, hanging\n");
    while(1) sleep(999);
}
```

**Result:**
- ✅ **THIS WORKS!**
- System boots successfully
- ADB connects
- We see "VIRTUAL_DEVICE_BOOT_COMPLETED" in logs (from stock init after chain)
- Test passes

## Kernel Cmdline Configuration

### Original (Stock)
```
console=ttynull console=hvc0 earlycon=uart8250,io,0x3f8
```

### Modified (Our Repacks)
```
console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel
```

**Implementation:** Modified in Makefile to strip old console/earlycon and add new ones.

**Verification:** Extracted repacked image and confirmed cmdline is correct.

## Log Files Checked

For each test instance, we've checked:

1. **kernel.log**
   - Location: `/var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/kernel.log`
   - Content: Kernel boot messages up to "Run /init as init process"
   - Then: NOTHING (file ends)

2. **console_log**
   - Location: `/var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/console_log`
   - Content: Same as kernel.log (599 lines, ends at "Run /init")

3. **cfctl logs --stdout**
   - Shows: Host-side process logs (launch_cvd, netsimd, KeyMint, etc.)
   - Shows: U-Boot messages, kernel version (when bootlooping)
   - Does NOT show: Any userspace init output

## Observed Behavior

### Pattern for All Non-Working Tests
1. Kernel boots successfully
2. Kernel message: `Run /init as init process`
3. Complete silence (no more kernel or init messages)
4. After ~30-60 seconds: system reboots (see GUEST_UBOOT_VERSION again)
5. Pattern repeats

### Pattern for Working Chainloader
1. Kernel boots successfully
2. Our init runs (invisibly)
3. Calls execl("/init.stock")
4. Stock Android init takes over
5. Android boot messages appear
6. System boots fully, ADB connects
7. Success

## Key Difference

The ONLY difference between working and non-working:
- **Working:** Calls `execl("/init.stock", "init", NULL)` immediately after printf
- **Non-working:** Does anything else (sleep, loop, just exist)

This suggests:
- Maybe our output IS being generated
- But it's buffered/queued somewhere
- Only when we exec to stock init does it get flushed/visible
- If we don't exec, the output never appears in logs

OR:
- Stock init does additional console setup
- Our setup is incomplete
- Console doesn't actually work until stock init runs

## Questions for Research

### Q1: Is console setup incomplete?
What else does Android's first_stage_console.cpp do that we're not doing?

Reference: Android source `system/core/init/first_stage_console.cpp`

Are we missing:
- ioctl calls beyond TIOCSCTTY?
- Specific termios settings?
- Serial port configuration?
- Something with hvc0 vs ttyS0?

### Q2: Does console=ttyS0 actually work on Cuttlefish?
Should we be using:
- `console=hvc0` (virtio console) instead?
- Different UART address?
- Different device node?

The stock cmdline has `console=hvc0` - maybe ttyS0 doesn't exist or isn't connected?

### Q3: Are we checking the right log files?
Where does ttyS0 output actually go?
- kernel.log? (we checked - nothing there)
- console_log? (we checked - nothing there)
- Some other file?
- Serial port file in /dev?

### Q4: Is there a timing issue?
Does console only become active after:
- Certain kernel initialization completes?
- Some daemon starts?
- Stock init sets something up?

### Q5: Can we see kernel panic messages?
If our init crashes, we should see:
- "Kernel panic - not syncing"
- "Attempted to kill init!"
- Stack trace

But we see NOTHING. Does this mean:
- Init isn't crashing (just produces no output)?
- Panic messages also go to invisible console?
- System reboots too fast to log panic?

## Evidence Init Actually Runs

From kernel.log:
```
[    0.969526] Run /init as init process
```

- No "init not found" error
- No "failed to execute /init" error
- Kernel successfully found and executed our binary

From working chainloader:
- We know our binary CAN be executed
- We know execl("/init.stock") works when we call it
- This proves /init and /init.stock both exist in ramdisk

## CPIO Verification

Double-checked the ramdisk contents:
```bash
$ lz4 -d ramdisk_modified ramdisk.cpio
$ cpio -tv < ramdisk.cpio | grep " init"

-rwxr-x---   1 root     wheel     4113288 Dec 31  1969 init.stock
-rwxr-xr-x   1 root     wheel      969768 Oct 25 15:30 init
```

✅ Our binary is `/init` (969KB)  
✅ Stock init is `/init.stock` (4MB)  
✅ Both have execute permissions

## Test Instance Examples

- **Instance 1** (test_console_setup): Bootloop, no output
- **Instance 96** (test_mounts): Kernel starts init, no output
- **Instance 97, 98** (test_print_only): Kernel starts init, no output
- **Instance 85, 87, 88** (chainloader v2): ✅ **Work perfectly**

## Comparison: Stock Init vs Our Init

### Stock Init Boot
When using stock init_boot.img:
- Kernel starts /init
- We see tons of Android init messages in logs
- System boots fully
- Console clearly works

### Our Init Boot
When using our init (even with same console setup):
- Kernel starts /init
- We see NOTHING
- No init messages at all
- Console appears broken

### Our Chainloader → Stock Init
When our init immediately execs to stock:
- Kernel starts our /init
- Our init runs (invisibly)
- Calls execl to stock init
- Stock init's messages appear
- System boots fully

## System Specifications

### Build Command
```bash
zig cc -target x86_64-linux-musl -static -O2 -Wall -Wextra -o heartbeat_init heartbeat_init.c
```

### Binary Details
```
Size: ~950KB
Type: ELF 64-bit LSB executable, x86-64, statically linked
```

### Deployment
```bash
# Repack
make repack INIT_BOOT_SRC=init_boot.stock.img

# Deploy
cfctl instance create --purpose test
cfctl deploy --init init_boot.img <id>
cfctl instance start <id> --timeout-secs 60
```

### Log Access
```bash
# What we've tried:
cfctl logs <id> --stdout --lines 500
tail /var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/kernel.log
tail /var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/console_log
```

## Files Reference

All code in: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/`

**Test programs created:**
- `test_print_only.c` - Bare write() to stdout/stderr
- `test_mounts.c` - Test mount calls with prints
- `test_console_setup.c` - Full TIOCSCTTY setup then exec

**Implementations:**
- `heartbeat_init.c` - Current standalone with TIOCSCTTY (doesn't work)
- `heartbeat_init_v2.c` - Working chainloader (works perfectly)

**Build system:**
- `Makefile` - Includes cmdline modification for console=ttyS0

## Kernel Boot Evidence

Every test shows:
```
[    0.679550] Trying to unpack rootfs image as initramfs...
[    0.728673] Freeing initrd memory: 22148K
[    0.951524] Freeing unused kernel image (initmem) memory: 3096K
[    0.952772] Write protecting the kernel read-only data: 38912k
[    0.954202] Freeing unused kernel image (rodata/data gap) memory: 888K
[    0.962518] Run /init as init process
```

Then kernel.log **ends**. File has 599 lines total, ends at "Run /init".

## Critical Observations

### 1. No Kernel Panic
If init crashed, we'd expect:
```
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000009
```

We see NOTHING. This means either:
- Init is running without crashing (just no output)
- Panic messages are also going to invisible console
- System reboots before panic can be logged

### 2. Bootloop Pattern
With standalone versions:
- GUEST_UBOOT_VERSION appears multiple times in cfctl logs
- System reboots every 30-60 seconds
- This suggests cfctl or watchdog reboots when ADB doesn't come up

### 3. Working Chainloader Proves Execution
Since the chainloader works, we know:
- Our binary CAN execute on this system
- /init.stock exists and is executable
- execl() works correctly
- The problem is specific to staying as PID1 without exec

## What Guidance Recommended

### Console Setup (Attempted in test_console_setup.c)
```c
1. mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, NULL);
2. mknod("/dev/console", S_IFCHR | 0600, makedev(5,1));
3. fd = open("/dev/console", O_RDWR) with retries
4. ioctl(fd, TIOCSCTTY, 0);
5. dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
6. setvbuf(stdout, NULL, _IONBF, 0);
```

**We implemented this exactly.** Still no output.

### Kernel Cmdline (Implemented in Makefile)
```
console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel
```

**We implemented this.** Still no output.

### Launch Flags (NOT YET TESTED - cfctl doesn't support)
```bash
--verify-boot false
--launch-arg="--restart_subprocesses=false"
```

**Cannot test:** cfctl doesn't have these flags yet.

## Specific Technical Questions

### Q1: Console Device
Is `/dev/console` with `makedev(5, 1)` correct for Cuttlefish?

Should we use:
- Different major/minor numbers?
- `/dev/ttyS0` directly instead of `/dev/console`?
- `/dev/hvc0` (virtio-console)?

### Q2: Console Cmdline
Stock uses `console=hvc0`. We changed to `console=ttyS0`.

Should we:
- Use `console=hvc0` instead?
- Keep both `console=hvc0 console=ttyS0`?
- Use different UART parameters?

### Q3: Initialization Order
Does something need to happen before console works?

Do we need to:
- Mount something else first?
- Initialize something in /sys or /proc?
- Set up TTY/termios in a specific way?
- Wait for something before opening console?

### Q4: Output Routing
Where does console=ttyS0 output actually go on Cuttlefish?

Is it:
- kernel.log? (we checked - nothing)
- console_log? (we checked - nothing)
- A different file we haven't found?
- Truly lost/discarded somewhere?

### Q5: Why Does Chaining Work?
The chainloader works perfectly. What does stock init do that makes output visible?

Does stock init:
- Set up console differently?
- Redirect output somewhere?
- Initialize something we're missing?

Can we study stock init's console setup code?

## Comparison Table

| Aspect | Working Chainloader | Non-Working Standalone |
|--------|-------------------|----------------------|
| Compile | ✅ Yes | ✅ Yes |
| Deploy | ✅ Yes | ✅ Yes |
| Kernel starts /init | ✅ Yes | ✅ Yes |
| Output visible | ✅ Yes (stock's) | ❌ No |
| System boots | ✅ Yes | ❌ Bootloop |
| ADB connects | ✅ Yes | ❌ No |

## What We Need Help With

### Priority 1: Make Output Visible
**How do we see stdout/stderr/kmsg from our init?**

Even the simplest `write(1, "test", 4)` produces nothing. What are we missing?

### Priority 2: Prevent Bootloop
**Why does system reboot when we don't exec to stock init?**

Is there:
- A watchdog we need to disable?
- A specific process cfctl expects?
- Something init must do to prevent reboot?

### Priority 3: Console Setup
**Is our TIOCSCTTY setup correct for Cuttlefish?**

Should we:
- Use different device nodes?
- Use different cmdline parameters?
- Add additional ioctl calls?
- Reference Android source code for exact implementation?

## Next Steps (Blocked)

Cannot proceed until we solve console visibility:
1. ❌ Can't see if our code runs correctly
2. ❌ Can't debug why standalone version bootloops
3. ❌ Can't verify heartbeat messages
4. ❌ Can't test SIGTERM handling

## Request for Research

Please investigate:

1. **Where does console output from early PID1 actually appear on Cuttlefish?**
   - File paths?
   - Different log sources?
   - Special access methods?

2. **What does Android's first_stage_console.cpp actually do?**
   - Exact console setup sequence
   - Any missing steps in our implementation?
   - Reference code we can copy?

3. **Why does output only appear after exec to stock init?**
   - What does stock init enable/configure?
   - Can we do the same without stock init?

4. **Alternative debugging methods?**
   - Direct serial console access?
   - QEMU monitor access?
   - Network-based logging?
   - File-based logging to persistent storage?

## Reproducibility

Any agent can reproduce this:

```bash
cd /Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init

# Build test version
zig cc -target x86_64-linux-musl -static -O2 test_console_setup.c -o heartbeat_init

# Repack
make clean && make repack INIT_BOOT_SRC=../init_boot.stock.img

# Deploy and test
scp init_boot.img hetzner:/tmp/test.img
ssh hetzner 'inst=$(cfctl instance create --purpose test | grep -oE "[0-9]+" | head -1) && \
  cfctl deploy --init /tmp/test.img $inst && \
  cfctl instance start $inst --timeout-secs 60 && \
  tail /var/lib/cuttlefish/instances/$inst/instances/cvd-$inst/kernel.log'
```

Expected: See "CONSOLE_TEST" messages  
Actual: See nothing after "Run /init as init process"

## Summary

We have:
- ✅ Working build system
- ✅ Working AVB signing
- ✅ Kernel that boots our init
- ✅ Proof that our binaries can execute
- ❌ **Completely invisible console output from non-chainloader init**

The console visibility problem blocks everything. Once solved, the rest should work.
