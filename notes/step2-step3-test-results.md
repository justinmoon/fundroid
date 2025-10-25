# Step 2 & 3 Test Results - Blockers Found

**Date:** 2025-10-25
**Testing:** Console visibility and launch flags

## Step 2: Console Cmdline Fix

### What We Did
Modified Makefile to change kernel cmdline:
- Strips `console=ttynull` and `earlycon=*`
- Adds `console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel`

### Build Test Result
✅ **Makefile changes work:**
```
Console cmdline:  console=ttyS0 earlycon=uart8250,io,0x3f8,115200 ignore_loglevel
Created init_boot.img
```

### Deployment Test Result  
❌ **Still no console output visible**

Tested instance 93 with new cmdline:
- Deployed init_boot.img with console=ttyS0
- Started instance  
- Checked `cfctl logs --stdout`
- **Result:** No heartbeat messages, no console output

The logs show:
```
10-25 17:52:47.810 842937 842937 I launch_cvd: main.cc:179 Using system_image_dir...
```

This is launch_cvd output, not guest console output.

### Hypothesis
`cfctl logs --stdout` might not be reading the serial console. It may be reading:
- systemd journal (host side)
- launch_cvd logs  
- Not the actual guest ttyS0 console

Need to find where ttyS0 console output actually goes.

## Step 3: Launch Flags

### What We Tried
Based on guidance, attempted to use:
```bash
cfctl instance start $inst \
  --timeout-secs 0 \
  --verify-boot false \
  --launch-arg='--restart_subprocesses=false'
```

### Result
❌ **cfctl doesn't support these flags**

Error:
```
error: unexpected argument 'false' found
```

Actual supported flags (from --help):
```
Options:
      --disable-webrtc
      --timeout-secs <TIMEOUT_SECS>
      --verify-boot
  -h, --help
```

Issues:
1. `--verify-boot` is a boolean flag, not `--verify-boot false`
2. No `--launch-arg` option exists
3. No way to pass `--restart_subprocesses=false` to underlying run_cvd

### What We Need
Either:
1. **cfctl needs enhancement** to support `--launch-arg` or `--no-verify-boot` 
2. **Alternative method** to start instance without ADB timeout
3. **Direct access** to console log files on disk

## Blockers

### Blocker 1: Cannot See Console Output
Even with `console=ttyS0` in cmdline:
- `cfctl logs --stdout` doesn't show it
- Need to know: where does ttyS0 output actually go?
- Possible locations:
  - `/var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/console_log`
  - Some other file?
  - A different cfctl command?

### Blocker 2: Cannot Disable ADB Wait
cfctl always waits for ADB and times out when it doesn't appear:
- Our standalone PID1 doesn't start ADB
- cfctl kills the VM after timeout
- Need way to:
  - Skip ADB wait, OR
  - Keep VM running despite no ADB, OR
  - Access console logs before VM is killed

## What Works

✅ Standalone PID1 compiles  
✅ Makefile cmdline modification works  
✅ AVB signing works  
✅ Image builds successfully

## What Doesn't Work

❌ Cannot see console output  
❌ Cannot keep VM alive without ADB  
❌ cfctl doesn't support needed launch flags

## Questions for Infrastructure Owner

1. **Where does console=ttyS0 output go?**
   - File path on host?
   - Different cfctl command?
   - Need to access VM serial console directly?

2. **How to start instance without ADB requirement?**
   - cfctl doesn't have --launch-arg or --no-verify-boot
   - Need these features added?
   - Alternative startup method?

3. **Can we access console logs while VM is running?**
   - Path to serial console log file?
   - Real-time tail of ttyS0 output?
   - Or do we need cfctl enhancements?

## Next Steps (Blocked)

Cannot proceed with step 4 (testing) until:
- [ ] We can see console output from guest
- [ ] We can keep VM running without ADB
- [ ] cfctl supports needed launch options

**OR** we need a workaround/alternative approach.
