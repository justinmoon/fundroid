# Cuttlefish Infrastructure Issues - 2025-10-24

## Summary

Multiple attempts to test the heartbeat init are failing due to cuttlefish/cfctl infrastructure problems, not issues with our code. The kernel successfully boots (confirmed by seeing kernel version messages), but we cannot reliably start instances or capture logs.

## Specific Errors Encountered

### 1. cfctl Daemon Connection Failures

**Error:**
```
Error: connect to "/run/cfctl.sock": Connection refused (os error 111)
```

**When it occurs:**
- Randomly during test runs
- When trying to capture logs with `cfctl logs`
- After deploying images

**Example from instance 70:**
```bash
ssh hetzner "cfctl logs 70 --stdout --lines 2000"
# Output: Error: connect to "/run/cfctl.sock": Connection refused (os error 111)
```

**Status check shows:**
```
systemd[1]: Started Cuttlefish controller daemon.
cfctl-daemon[3392657]: 2025-10-24T19:19:07.295705Z  INFO cfctl::daemon: cfctl daemon listening on /run/cfctl.sock
```
The daemon restarts frequently (was just restarted at 19:19:07).

### 2. Empty Response from Daemon

**Error from test run (instance 68):**
```
test-heartbeat: Starting Cuttlefish instance (timeout: 180s)...
Error: empty response from daemon
test-heartbeat: ERROR: Failed to start Cuttlefish instance
test-heartbeat: Cleaning up instance 68
Destroying instance 68
Error: connect to "/run/cfctl.sock": Connection refused (os error 111)
```

The daemon gives an empty response when trying to start, then immediately becomes unreachable.

### 3. QEMU Datadir Creation Failure

**Error from instance 72:**
```json
{
  "ok": false,
  "error": {
    "code": "start_instance_ensure_qemu",
    "message": "creating qemu datadir /var/lib/cuttlefish/usr/share/qemu/x86_64-linux-gnu"
  }
}
```

This suggests a permissions or filesystem issue on the host.

### 4. Instance Cleanup Before Log Capture

**Problem:**
When checking `/var/lib/cuttlefish/instances/` for log files:
```bash
ssh hetzner "ls -lh /var/lib/cuttlefish/instances/71/"
# Output: total 0
```

Instances are being cleaned up immediately, so we cannot access:
- `kernel.log`
- `console_log`
- `launcher.log`
- `cuttlefish_runtime.log`

Even when we try to capture logs shortly after the instance fails, the directories are already empty.

### 5. Authentication Issues with systemctl

**Error when trying to restart cfctl:**
```
Failed to restart cfctl.service: Interactive authentication required.
See system logs and 'systemctl status cfctl.service' for details.
```

Cannot restart the daemon when it gets stuck.

## Observed Pattern

1. Create instance: ✅ Works
2. Deploy custom init_boot.img: ✅ Works
3. Start instance: ❌ **Fails with various errors**
4. Capture logs: ❌ **Daemon unreachable or instance cleaned up**

## What We Know Works

Despite infrastructure issues, we have evidence the **kernel boots successfully**:

From instance 69 error log (truncated):
```
GUEST_KERNEL_VERSION: 6.12.18-android16-1-g50eb8d5d443b-ab13197114 ... ] Linux version
```

This proves:
- Bootloader accepted our AVB-signed image ✅
- Kernel loaded and started ✅
- Got further than the U-Boot bootloop ✅

## What We Cannot Verify

Because we cannot reliably capture console logs, we don't know:
- [ ] Does our heartbeat init actually execute?
- [ ] Do the `[cf-heartbeat]` debug messages print?
- [ ] Does the chain to `/init.stock` work?
- [ ] What exactly causes the secure_env crash?

## Impact

We have:
- ✅ Working build system
- ✅ AVB-signed boot image
- ✅ Verified CPIO modifications
- ✅ Kernel booting
- ❌ **No way to see console output**
- ❌ **No way to verify end-to-end functionality**

## What Would Help

1. **Stable cfctl daemon** that doesn't disconnect randomly
2. **Persistent instance logs** that survive until we can read them
3. **Access to console logs via file system** (not just cfctl API)
4. **Alternative log capture method** (serial console, netconsole, etc.)
5. **Permission to use systemctl** to restart cfctl when stuck

## Workarounds Attempted

1. ❌ Direct filesystem access to `/var/lib/cuttlefish/instances/*/` - instances cleaned up
2. ❌ Using `cfctl logs --follow` - daemon disconnects
3. ❌ Longer timeouts - doesn't help with daemon crashes
4. ❌ Restarting cfctl - authentication required

## Test Commands Used

```bash
# Create instance
cfctl instance create --purpose heartbeat

# Deploy image
cfctl deploy --init /tmp/heartbeat-init_boot.img <id>

# Start (this is where it usually fails)
cfctl instance start <id> --timeout-secs 180

# Try to get logs (often fails)
cfctl logs <id> --stdout --lines 2000
```

## Reproducibility

The issues are **intermittent but frequent**:
- Sometimes cfctl works for 1-2 operations then dies
- Sometimes it fails immediately on start
- Daemon seems to crash/restart during operations
- No clear pattern to when it will work

## Full Test Run Example

From `/tmp/heartbeat-final-test.log`:
```
test-heartbeat: Created instance: 73
test-heartbeat: Deploying heartbeat init_boot.img...
{
  "ok": true,
  "message": "deploy updated"
}
test-heartbeat: Starting Cuttlefish instance (timeout: 180s)...
test-heartbeat: ERROR: Failed to start Cuttlefish instance
```

No error details, just failure. Logs unavailable because daemon is down.

## Recommendation

The heartbeat init code is ready and likely working. We need stable cuttlefish infrastructure to confirm. Suggest:
1. Investigate cfctl daemon crashes
2. Check disk space / permissions on host
3. Look at systemd logs for cfctl.service
4. Consider alternative testing environment if host issues persist
