# Step 2 Deep Dive: Console Output Investigation

**Finding:** Our init starts but produces NO output before crashing/hanging.

## Evidence

### Kernel Successfully Starts Our Init
From kernel.log (instance 95):
```
[    0.957084] Run /init as init process
```

Then **complete silence** - no more kernel messages, no init output, nothing.

### What This Means
1. ✅ Kernel unpacks initramfs successfully
2. ✅ Kernel finds `/init` (our binary)
3. ✅ Kernel executes `/init` as PID1
4. ❌ **Our init immediately crashes/hangs before any output**
5. ❌ No printf, no fprintf, no puts - nothing appears

### Console Files Checked
- `kernel.log`: Shows kernel boot up to "Run /init", then stops
- `console_log`: Shows kernel boot messages, then stops at same point
- No output from our init in either file

### cmdline Verification
From instance 95's boot:
```
console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel
```
✅ Console is correctly set to ttyS0 (not ttynull)

## Current heartbeat_init.c Code

```c
int main(void) {
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGHUP, on_term);
    signal(SIGPIPE, SIG_IGN);

    mount_fs("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV, "");
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID|MS_NOEXEC|MS_NODEV, "");
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, "mode=0755");

    bind_stdio_to_console();

    puts("VIRTUAL_DEVICE_BOOT_COMPLETED");
    fprintf(stderr, "[cf-heartbeat] standalone PID1 running\n");
    
    // heartbeat loop...
}
```

## Hypothesis: Init Crashes During Setup

### Possible Crash Points

1. **signal() calls fail?**
   - Unlikely, but possible if musl has issues

2. **mount_fs() crashes:**
   - `/proc` might not be mountable yet
   - `/sys` might not exist
   - `/dev` might already be mounted
   - mount() could segfault if kernel doesn't support it

3. **bind_stdio_to_console() crashes:**
   - `setsid()` might fail (could return error but we don't check)
   - `/dev/console` might not exist yet
   - open() could fail and we try to dup2(-1)
   - `/dev/kmsg` fallback could crash

4. **puts() crashes:**
   - If stdio isn't set up correctly
   - If stdout is invalid

### Why No Output At All

Even if we crash, we'd expect:
- Kernel panic message
- "Attempted to kill init!" message
- Some error from the kernel

But we see nothing. This suggests:
- Init starts
- Crashes/exits immediately (before first print)
- Kernel might reboot so fast the panic doesn't get logged

## Comparison with Working Chainloader (v2)

The v2 chainloader that WORKS:
```c
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    fprintf(stderr, "[cf-heartbeat] PID1 starting, chaining to /init.stock\n");
    
    execl("/init.stock", "init", NULL);
    
    while(1) sleep(999);
}
```

**Differences:**
- ❌ No signal handlers
- ❌ No mount calls  
- ❌ No setsid or console manipulation
- ✅ Just setvbuf + prints + exec

**And it works!**

## Root Cause Theory

The mount calls or console setup are crashing before we can print anything.

Specifically suspect:
1. `setsid()` in bind_stdio_to_console()
2. `mount()` system calls
3. Something about how we set up signals

## Test Plan for Step 2

Need to test incrementally by adding ONE thing at a time to the working chainloader:

**Test A: Just add mounts**
```c
int main(void) {
    mount("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV, "");
    
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("After mount\n");
    execl("/init.stock", "init", NULL);
    while(1) sleep(999);
}
```

**Test B: Just add console setup**
```c
int main(void) {
    bind_stdio_to_console();  // with setsid
    
    puts("After console setup\n");
    execl("/init.stock", "init", NULL);
    while(1) sleep(999);
}
```

**Test C: Just add signals**
```c  
int main(void) {
    signal(SIGTERM, on_term);
    
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("After signal\n");
    execl("/init.stock", "init", NULL);
    while(1) sleep(999);
}
```

One of these will fail, showing us exactly what breaks.

## Files
- Current code: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`
- Working v2: Can recreate from heartbeat_init_v2.c
- Test instances: 93, 94, 95 (all show same behavior - kernel starts init, then silence)
