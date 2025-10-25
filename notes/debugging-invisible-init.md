# Debugging the Invisible Init Issue

**Date:** 2025-10-24  
**Status:** Init runs but output not visible, causes bootloop

## What We Know

### ✅ Stock Init Works
```bash
cfctl instance create --purpose stock-test
cfctl instance start <id>
# Result: {"ok": true, "adb": {"port": 6602, ...}}
```
Stock Android init boots successfully and ADB becomes available.

### ❌ Our Init Causes Bootloop
```bash
cfctl instance create --purpose heartbeat
cfctl deploy --init /tmp/heartbeat-init_boot.img <id>
cfctl instance start <id>
# Result: Kernel boots repeatedly, no ADB, timeout
```

### Kernel Boots Successfully
From console_log:
```
[    0.679550] Trying to unpack rootfs image as initramfs...
[    0.728673] Freeing initrd memory: 22148K
```

The kernel:
- ✅ Loads successfully
- ✅ Unpacks our modified initramfs
- ✅ Frees initrd memory (ramdisk processed)
- ❌ **No userspace output visible**
- ❌ System reboots shortly after

### Console Configuration Issue
From kernel command line:
```
console=ttynull ... console=hvc0 earlycon=uart8250,io,0x3f8
```

The `console=ttynull` means:
- Primary console discards all output
- Our init's stdout/stderr go to /dev/null  
- Even /dev/kmsg writes may not appear in visible logs

## Why No Heartbeat Messages Appear

Our init does:
1. `fprintf(stderr, ...)` - goes to ttynull (discarded)
2. `printf(...)` - goes to ttynull (discarded)  
3. `dprintf(kmsg_fd, ...)` - writes to /dev/kmsg

**Problem:** We never see any of these because:
- Console output is nulled
- /dev/kmsg might not be set up yet when we write
- System reboots before logs are flushed
- We're looking at the wrong log source

## What's Likely Happening

### Theory 1: Init Crashes Before Exec
Our init runs but crashes/exits before calling `execl("/init.stock")`:
- Mounts succeed silently
- Console setup fails or redirects to null
- Device checks crash (accessing /dev nodes that don't exist yet)
- System has no PID1, kernel panics, reboot

### Theory 2: Exec Fails
`execl("/init.stock")` fails:
- /init.stock doesn't exist (CPIO edit didn't work)
- /init.stock not executable
- Wrong path or environment
- Returns to main(), exits, kernel panics

### Theory 3: Stock Init Immediately Fails
We successfully exec /init.stock but:
- Stock init expects different environment
- Missing critical mounts or setup
- SELinux blocks execution
- Stock init crashes because we didn't set something up

## Evidence Points

### CPIO Verified Correct
```bash
$ lz4 -d ramdisk_modified ramdisk_verify.cpio
$ cpio -tv < ramdisk_verify.cpio | grep init
-rwxr-x---   1 root     wheel     4113288 Dec 31  1969 init.stock
-rwxr-xr-x   1 root     wheel      969768 Oct 24 15:30 init
```
✅ Our binary is `/init`  
✅ Stock init is `/init.stock`  
✅ Both have execute permissions

### Kernel Loads Ramdisk
```
[    0.679550] Trying to unpack rootfs image as initramfs...
[    0.728673] Freeing initrd memory: 22148K
```
✅ Ramdisk unpacks successfully  
✅ Size is correct (22MB)

### No Kernel Panic Messages
Checking kernel.log and console_log shows:
- ❌ No "Kernel panic" messages
- ❌ No "not syncing" messages  
- ❌ No "Attempted to kill init" messages
- ✅ Just clean boot, then nothing, then reboot

This suggests: **init starts but silently fails/exits**

## Debugging Strategies

###  1: Add Explicit Kernel Panic
Modify our init to cause a kernel panic with a message:
```c
// At start of main()
syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, 
        LINUX_REBOOT_CMD_RESTART, "HEARTBEAT_INIT_STARTED");
```
If we see this in logs, we know init ran.

### 2: Create /dev/kmsg Early
Manually create /dev/kmsg before trying to open it:
```c
// After mounting /dev
mknod("/dev/kmsg", S_IFCHR | 0600, makedev(1, 11));
```

### 3: Write to a File
Write to a file in /dev or /tmp that might survive:
```c
int fd = open("/dev/.heartbeat_ran", O_CREAT | O_WRONLY, 0644);
write(fd, "INIT_STARTED\n", 13);
close(fd);
```
Then check if file exists in next boot.

### 4: Remove All Device Checks
Comment out all the `check_device()` calls:
- They might crash if devices don't exist
- Accessing non-existent /dev nodes can cause issues
- Just mount, print one message, exec stock init

### 5: Exec Immediately
Skip ALL setup, just exec stock init:
```c
int main(void) {
    execl("/init.stock", "init", NULL);
    // If we get here, exec failed
    while(1) sleep(999);  // Hang instead of exit
}
```

If this works, we know the issue is in our setup code.

### 6: Check with strace (if possible)
If we can get serial console or modify kernel cmdline:
- Boot with `init=/bin/sh`
- Manually run `/init` under strace
- See exactly where it fails

### 7: Binary File Test
Create two different binaries:
- `/init` - prints "A" then execs /init.stock
- `/init` - prints "B" then execs /init.stock  

Deploy different versions, see if behavior changes.

## Most Likely Root Cause

Given the evidence, **most likely: our init crashes during device checks or console setup**.

Reasons:
1. Stock init works perfectly
2. Kernel boots and unpacks ramdisk
3. No visible output (not even from /dev/kmsg)
4. No kernel panic (so init must be starting)
5. System reboots (init exited/crashed)

The `check_device()` function does:
```c
int fd = open(path, flags | O_CLOEXEC);
read(fd, buf, sizeof(buf));  // For /dev/urandom
```

If `/dev/urandom` doesn't exist yet or can't be read, this could crash or hang.

## Next Steps

1. **Simplify init to absolute minimum:**
   - Remove all device checks
   - Remove kmsg logging
   - Just exec /init.stock immediately

2. **If that works, add back features one by one:**
   - Add mounts
   - Add console setup
   - Add one print
   - Add device checks
   - Find exactly what breaks

3. **Test each version to isolate the failure point**

## Command to Test

```bash
# On local machine
cd heartbeat-init
# Edit heartbeat_init.c to minimal version
make clean && make repack INIT_BOOT_SRC=../init_boot.stock.img
scp init_boot.img hetzner:/tmp/heartbeat-init_boot.img

# On hetzner via cfctl
ssh hetzner "inst=\$(cfctl instance create --purpose minimal-test | grep -oE '[0-9]+' | head -1) && \
  cfctl deploy --init /tmp/heartbeat-init_boot.img \$inst && \
  cfctl instance start \$inst --timeout-secs 90"
```

If minimal version works, we know the issue is in our code, not the approach.
