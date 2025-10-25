# HELP NEEDED: Console Output Not Visible Despite console=ttyS0

**Status:** Kernel starts our init, but NO output from init appears anywhere

## What We've Tested

### Test 1: Complex Standalone Init
**Code:** mounts + console setup + device checks + heartbeat loop  
**Result:** Kernel starts init, then silence

### Test 2: Mounts Test  
**Code:** Print before/after mount() calls, then exec stock init  
**Result:** Kernel starts init, then silence

### Test 3: Print Only (Absolute Minimum)
**Code:**
```c
int main(void) {
    const char *msg = "INIT_STARTED\n";
    write(2, msg, 13);  // stderr
    write(1, msg, 13);  // stdout
    while(1) sleep(999);
}
```
**Result:** Kernel starts init, then silence

## What Kernel.log Shows

Every test shows identical pattern:
```
[    0.951524] Freeing unused kernel image (initmem) memory: 3096K
[    0.952772] Write protecting the kernel read-only data: 38912k
[    0.954202] Freeing unused kernel image (rodata/data gap) memory: 888K
[    0.955524] Run /init as init process
```

Then **NOTHING**. No more kernel messages. No init output.

## Files Checked

**Instance 98 (test_print_only):**
- `kernel.log`: 599 lines, stops at "Run /init"
- `console_log`: 599 lines, stops at "Run /init"
- Both files show kernel boot but zero init output

## Kernel Cmdline

✅ Correctly set to:
```
console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel
```

Verified this is in the repacked init_boot.img.

## What Works

✅ Stock init_boot.img boots fine and we see all its output  
✅ Our chainloader (v2) that does printf + exec works  
✅ Kernel starts our custom /init binary

## What Doesn't Work

❌ ANY output from our init appears in logs  
❌ Even `write(1, "test", 4)` produces nothing  
❌ Even `write(2, "test", 4)` produces nothing

## Comparison: Working Chainloader v2

This version WORKS and we DO see its output:
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

We see "VIRTUAL_DEVICE_BOOT_COMPLETED" in the logs (from stock init after we chain).

But if we change it to NOT exec and just sleep, would we see the output?

## Critical Question

**Does console output from PID1 only become visible AFTER we exec to stock init?**

Maybe:
- Our init runs and prints
- But output is buffered somewhere
- Only when we exec to stock init does it flush to the console files
- If we don't exec, the output never appears

## Test We Need

Modify the working chainloader to print, wait a bit, then exec:
```c
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    
    write(2, "BEFORE_EXEC\n", 12);
    sleep(10);
    write(2, "AFTER_SLEEP\n", 12);
    
    execl("/init.stock", "init", NULL);
    while(1) sleep(999);
}
```

If we see "BEFORE_EXEC" and "AFTER_SLEEP" in logs, then the console IS working and something about the standalone loop version breaks it.

If we DON'T see them, then console output only appears after exec to stock init.

## Files
- Test programs: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/test_*.c`
- Current standalone: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init.c`
- Working v2: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/heartbeat_init_v2.c`
- Makefile: `/Users/justin/code/boom/worktrees/minimal-pid1/heartbeat-init/Makefile`

##  Question for Oracle/Infrastructure Expert

**Why is there ZERO output from our init in kernel.log or console_log, even from the simplest possible write() call?**

Is there:
1. A console initialization that only happens when stock init runs?
2. Output buffering that only flushes on exec?
3. Some kernel configuration that prevents early init output?
4. A different log file we should be checking?
5. Something fundamentally broken with our approach?
