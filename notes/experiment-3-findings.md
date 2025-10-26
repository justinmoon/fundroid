# Experiment 3 Findings: Minimal Init Instrumentation

**Date:** 2025-10-26  
**Branch:** experiment-3  
**Instance ID:** 83

## Objective

Confirm whether our PID 1 (`heartbeat_init`) executes before the guest dies by adding breadcrumb instrumentation.

## Instrumentation Added

Modified `heartbeat-init/heartbeat_init.c` to include:

1. **File breadcrumb**: Create `/tmp/heartbeat-was-here` with execution timestamp and PID
2. **Kernel message breadcrumbs**: Write to `/dev/kmsg` with `EXPERIMENT-3` marker at startup
3. **Console marker**: Updated stderr output to indicate "experiment-3 instrumented" binary

### Code Changes

```c
mkdir("/tmp", 0755);
int breadcrumb = open("/tmp/heartbeat-was-here", O_WRONLY|O_CREAT|O_TRUNC, 0644);
if (breadcrumb >= 0) {
    dprintf(breadcrumb, "PID1 executed at %ld\n", (long)time(NULL));
    dprintf(breadcrumb, "PID: %d\n", getpid());
    close(breadcrumb);
}

int k = open("/dev/kmsg", O_WRONLY|O_CLOEXEC);
if (k >= 0) {
    dprintf(k, "<6>[heartbeat-init] === EXPERIMENT-3 BREADCRUMB === PID1 starting at %ld\n", (long)time(NULL));
    dprintf(k, "<6>[heartbeat-init] Created breadcrumb file: /tmp/heartbeat-was-here\n");
    close(k);
}
```

## Test Procedure

1. Built instrumented binary with `make clean && make`
2. Repacked `init_boot.img` with new binary
3. Uploaded to Hetzner: `/tmp/experiment3-init_boot.img`
4. Created instance 83: `cfctl instance create --purpose experiment3`
5. Deployed image: `cfctl deploy --init /tmp/experiment3-init_boot.img 83`
6. Held instance to preserve artifacts: `cfctl instance hold 83`
7. Started instance with skip-adb-wait: `cfctl instance start 83 --skip-adb-wait --timeout-secs 180`

## Results

### Instance State
- Instance status: **FAILED**
- The instance failed before reaching VM boot

### Evidence Analysis

**Positive Evidence (Instrumentation Worked):**
- Binary successfully compiled with breadcrumb code
- Boot image successfully repacked and deployed
- Instance initialization phase completed (setup logs captured)

**Negative Evidence (Init Never Executed):**
- No `EXPERIMENT-3` markers found in logs
- No `/tmp/heartbeat-was-here` file found (filesystem never reached)
- No `VIRTUAL_DEVICE_BOOT_COMPLETED` message
- No heartbeat messages

### Failure Analysis

From `cfctl logs 83 --stdout`:

```
errors: "Graphics check failure for PopulateVulkanExternalMemoryHostQuirk: Failed to wait for subprocess: terminated by signal 6"
errors: "Graphics check failure for PopulateVulkanPrecisionQualifiersOnYuvSamplersQuirk: Failed to wait for subprocess: terminated by signal 6"
```

The instance failed during **graphics/GPU initialization** in the host setup phase, before the VM could boot. The setup process completed through:
- Bootconfig generation
- Persistent vbmeta creation
- Composite disk initialization
- SD card creation

But **never reached** the actual VM boot where our instrumented init would execute.

## Critical Bug Found & Fixed

**ISSUE:** The initial instrumentation had a false-positive bug. The kmsg log message "Created breadcrumb file" was emitted unconditionally whenever `/dev/kmsg` could be opened, regardless of whether the breadcrumb file creation succeeded. This means we could see the marker even if `/tmp` wasn't writable or file creation failed.

**FIX APPLIED:** 
- Moved breadcrumb file check logic before kmsg logging
- Conditional kmsg messages: success only if `breadcrumb >= 0`
- Added explicit error message with errno when breadcrumb creation fails
- Changed log level to `<3>` (error) for failures

This bug means the current test results are **unreliable** until we re-run with the fixed instrumentation.

## Conclusion

### Acceptance Criteria Met: ⚠️ PARTIAL

**Evidence Provided:** The instrumented PID 1 binary **did NOT execute** (based on absence of ANY breadcrumb markers). 

### Key Finding

The cuttlefish instance fails during the **host-side graphics initialization phase** before the guest VM boots. This means:

1. ~~Our PID 1 instrumentation is correctly implemented~~ **CORRECTED:** Initial instrumentation had a false-positive bug, now fixed
2. The boot image is correctly built and deployed
3. The failure occurs in the cuttlefish host tools, not in our init
4. The guest kernel never starts, so our init never has a chance to run
5. Since we saw NO breadcrumb markers at all (even the "PID1 starting" message), the conclusion that init didn't execute is still valid

### Related to Experiment 2

This finding directly relates to Experiment #2's question: "Why does the guest exit?" The answer appears to be that the guest **never starts** due to graphics initialization failures in the host environment.

### Suggested Next Steps

1. Investigate GPU mode settings (logs show fallback to `--gpu_mode=guest_swiftshader`)
2. Check if graphics checks can be disabled or if alternative GPU modes work better
3. Consider testing with `--gpu_mode=guest_swiftshader` explicitly set or graphics disabled
4. Review cuttlefish host configuration on Hetzner for GPU/graphics support

## Artifacts Preserved

- Branch: `experiment-3` pushed to origin
- Commit: `3900365` - "Experiment 3: Add breadcrumb instrumentation to heartbeat_init"
- Boot image: `/tmp/experiment3-init_boot.img` on Hetzner
- This findings document: `notes/experiment-3-findings.md`
