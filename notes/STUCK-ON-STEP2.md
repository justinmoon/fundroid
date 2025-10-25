# STUCK ON STEP 2: Console Output Completely Invisible

## Summary

**We cannot see ANY output from our custom PID1, even after implementing the TIOCSCTTY console setup as recommended.**

## What We've Implemented

### Code (test_console_setup.c)
```c
mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, NULL);
mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));

int fd = -1;
for (int tries = 50; tries-- && (fd = open("/dev/console", O_RDWR)) < 0; ) {
    usleep(100000);
}

if (fd >= 0) {
    ioctl(fd, TIOCSCTTY, 0);
    dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
    if (fd > 2) close(fd);
}

setvbuf(stdout, NULL, _IONBF, 0);
setvbuf(stderr, NULL, _IONBF, 0);

printf("CONSOLE_TEST: printf works\n");
fprintf(stderr, "CONSOLE_TEST: fprintf stderr works\n");
write(1, "CONSOLE_TEST: raw write works\n", 30);

execl("/init.stock", "init", NULL);
```

This is exactly what was recommended - mount devtmpfs, mknod console, TIOCSCTTY, dup2, unbuffered.

### Kernel Cmdline
✅ Successfully modified to:
```
console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel
```

### Build & Deploy
✅ Compiles successfully  
✅ Repacks with AVB signing  
✅ Deploys to Cuttlefish

## Result

**ZERO output visible anywhere.**

### kernel.log
```
[    0.969526] Run /init as init process
```
Then nothing. File ends.

### console_log
Same - ends at "Run /init as init process"

### cfctl logs --stdout
Only shows host-side logs (launch_cvd, webrtc, etc.). No guest console output.

## Tests Performed

1. **test_print_only.c** - Just `write()` to fd 1 and 2, then sleep
   - Result: No output

2. **test_mounts.c** - Mount filesystems, print after each, then exec
   - Result: No output

3. **test_console_setup.c** - Full console setup with TIOCSCTTY, then exec
   - Result: No output (bootloops)

4. **heartbeat_init_v2.c** (WORKING) - Just setvbuf + printf + exec immediately
   - Result: System boots, but we only see stock init's output

## The Mystery

**Question:** Why does the working chainloader (v2) succeed when it execs to stock init?

Maybe:
- Console setup happens INSIDE stock init
- Our output before exec goes nowhere
- Only after stock init runs does console become visible
- Stock init does something we're not doing

## What We Need

**Can you help us understand:**

1. **Why is output invisible even with TIOCSCTTY + console=ttyS0?**
   - Is there some other setup needed?
   - Does something need to happen in a specific order?
   - Are we checking the wrong log files?

2. **Where SHOULD console output appear?**
   - We've checked kernel.log
   - We've checked console_log
   - We've checked cfctl logs --stdout
   - All show kernel boot but no init output

3. **How does stock init make its output visible?**
   - What does it do that we're not doing?
   - Is there source we can reference?

4. **Alternative: Can we test without cfctl?**
   - Direct QEMU/KVM access?
   - Serial console access?
   - Some other method to see what's happening?

## Files

- Test programs: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/test_*.c`
- Current impl: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`
- Makefile: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/Makefile`
- All documented in git commits on branch minimal-pid1

## We're Stuck

Cannot proceed with standalone PID1 until we can see console output. Everything else works - build, deploy, kernel boots - but we're blind to what our init is doing.
