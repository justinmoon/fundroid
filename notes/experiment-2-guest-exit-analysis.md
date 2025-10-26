# Experiment #2: Why Does the Guest Exit?

**Date:** 2025-10-26  
**Goal:** Understand why cuttlefish instances flip to `failed` state even when held.  
**Status:** ✅ ROOT CAUSE IDENTIFIED

---

## Summary

Investigated why cuttlefish instances were failing immediately after start. Traced through multiple failure modes and identified the primary root cause: **the cuttlefish FHS wrapper (using bubblewrap) doesn't preserve supplementary group memberships**, causing permission failures when launch_cvd tries to change group ownership of directories.

---

## Investigation Steps

### 1. Initial Observations

- Most instances on hetzner were in `failed` state
- Instance 73 was held but its logs/directories were already cleaned up
- Need to create fresh instance to capture logs

### 2. Created Test Instance (ID: 82)

```bash
cfctl instance create --purpose experiment2  # Created instance 82
cfctl instance hold 82
cfctl deploy --init /tmp/init_boot_experiment2.img 82
cfctl instance start 82 --skip-adb-wait --timeout-secs 180
```

**Result:** Instance transitioned from `running` to `failed` in ~11 seconds

### 3. Log Analysis - cfctl-run.log

The log from instance 82 (`/var/lib/cfctl/instances/82/cfctl-run.log`) showed:
- Setup phase completed successfully
- Graphics detector failures (expected - no GPU):
  ```
  GPU auto mode: did not detect prerequisites for accelerated rendering support,
  enabling --gpu_mode=guest_swiftshader.
  ```
- Log ended after setup, no VM boot messages

### 4. Journal Analysis

From systemd journal for instance 82:
```
Oct 26 14:57:36 hetzner cfctl-daemon[2573297]: handle_guest_exit: instance 82 exited with signal 9
```

**Key Finding:** Process was SIGKILL'd (signal 9) after ~11 seconds.

### 5. Manual launch_cvd Execution

Ran launch_cvd manually to see full error output:

```bash
cd /var/lib/cuttlefish/instances && \
env CUTTLEFISH_INSTANCE=85 CUTTLEFISH_INSTANCE_NUM=85 ... \
/nix/store/.../cuttlefish-fhs -- launch_cvd ...
```

**Critical Error Found:**
```
assemble_cvd failed: 
Failed to set group for path: /var/lib/cuttlefish/instances/85/environments,
cvdnetwork, Invalid argument
```

### 6. Root Cause Discovery

Checked group membership inside vs outside FHS wrapper:

**Outside FHS:**
```bash
$ id
uid=1000(justin) gid=100(users) groups=100(users),1(wheel),302(kvm),983(cvdnetwork)
```

**Inside FHS wrapper:**
```bash
$ /nix/store/.../cuttlefish-fhs -- id
uid=1000(justin) gid=100(users) groups=100(users),65534(nogroup)
```

**Root Cause:** The `cvdnetwork` group (983) is lost when entering the FHS environment created by bubblewrap! This causes `chgrp cvdnetwork` operations to fail with "Invalid argument" because the user is not a member of the target group.

---

## Root Cause Analysis

### Why Does This Happen?

1. cfctl-daemon runs as root
2. When spawning launch_cvd, it uses: `Command::new(&self.config.cuttlefish_fhs)`
3. The cuttlefish-fhs wrapper uses `buildFHSEnvBubblewrap` (from nixpkgs)
4. Bubblewrap creates a new namespace and doesn't preserve supplementary groups
5. launch_cvd's `assemble_cvd` tries to `chgrp cvdnetwork` on directories
6. Operation fails because user is not in cvdnetwork group inside the FHS environment
7. launch_cvd exits with error, cfctl detects exit and marks instance as failed

### Code Evidence

From `cuttlefish/packages/cuttlefish-fhs.nix`:
```nix
pkgs.buildFHSEnvBubblewrap {
  name = fhsName;
  # ... no group preservation options
}
```

From `cuttlefish/cfctl/src/daemon/manager.rs`:
```rust
let child = cmd.spawn().with_context(|| {
    format!(
        "spawning cuttlefish guest {} via {}",
        id,
        self.config.cuttlefish_fhs.display()
    )
})?;
```

No user/group manipulation before spawn.

---

## Solution & Verification

### Verified Fix

Using `sudo` to preserve group membership:
```bash
$ sudo -u justin -g cvdnetwork -- /nix/store/.../cuttlefish-fhs -- id
uid=1000(justin) gid=983(cvdnetwork) groups=983(cvdnetwork),65534(nogroup)
```

✅ Group is now preserved! The gid is set to cvdnetwork.

### Tested with launch_cvd

Ran launch_cvd with the fixed command:
```bash
sudo -u justin -g cvdnetwork -- \
env CUTTLEFISH_INSTANCE=85 ... \
/nix/store/.../cuttlefish-fhs -- launch_cvd ...
```

**Result:** Setup completed successfully! VM started launching, but hit a different error (TAP device permissions - secondary issue).

---

## Additional Findings

### Secondary Issue: TAP Device Permissions

After fixing the group issue, encountered:
```
qemu-system-x86_64: could not configure /dev/net/tun (cvd-mtap-85): Operation not permitted
```

This is a separate issue - the justin user doesn't have permission to create TAP network devices. This requires either:
1. Running qemu as root (not recommended)
2. Setting proper capabilities on qemu binary
3. Pre-creating network devices with proper permissions

**Note:** This is not the primary failure cause - instances fail earlier due to the group issue.

---

## Implementation Recommendations

### For cfctl

Modify `spawn_guest_process` in `cfctl/src/daemon/manager.rs` to use one of:

**Option 1: Use sg (set group) command**
```rust
let mut cmd = if let Some(t) = track {
    let mut c = Command::new("sg");
    c.arg("cvdnetwork")
      .arg("-c")
      .arg(format!("cfenv -t {} --", t));
    c
} else {
    let mut c = Command::new("sg");
    c.arg("cvdnetwork")
      .arg(&self.config.cuttlefish_fhs);
    c
};
```

**Option 2: Use sudo with explicit user/group**
```rust
let mut c = Command::new("sudo");
c.arg("-u").arg("justin")
 .arg("-g").arg("cvdnetwork")
 .arg("--")
 .arg(&self.config.cuttlefish_fhs);
```

**Option 3: Fix buildFHSEnvBubblewrap**

Investigate if there's a way to make bubblewrap preserve supplementary groups, or use a different sandboxing approach.

---

## Testing Commands

### Verify group membership issue
```bash
# Outside FHS - shows cvdnetwork
ssh hetzner "id"

# Inside FHS - missing cvdnetwork
ssh hetzner "/nix/store/.../cuttlefish-fhs -- id"

# With sudo - preserves cvdnetwork
ssh hetzner "sudo -u justin -g cvdnetwork -- /nix/store/.../cuttlefish-fhs -- id"
```

### Test launch_cvd manually
```bash
ssh hetzner "cd /var/lib/cuttlefish/instances && \
  sudo -u justin -g cvdnetwork -- \
  env CUTTLEFISH_INSTANCE=85 CUTTLEFISH_INSTANCE_NUM=85 ... \
  /nix/store/.../cuttlefish-fhs -- launch_cvd ..."
```

---

## Acceptance Criteria Status

✅ **Notes outlining the failure cause with log snippets** - Documented above  
✅ **Identified root cause** - FHS wrapper drops cvdnetwork group  
✅ **Suggested mitigation** - Use sudo/sg to preserve group  
⚠️ **Tested mitigation** - Partially (fixes primary issue, reveals secondary TAP device issue)  

---

## Related Files

- `/var/lib/cfctl/instances/82/cfctl-run.log` - Shows setup completion but no error
- `cuttlefish/packages/cuttlefish-fhs.nix` - FHS wrapper definition
- `cuttlefish/cfctl/src/daemon/manager.rs` - Process spawning logic
- `cuttlefish/cfctl/src/daemon/manager.rs:reset_cuttlefish_permissions()` - Shows awareness of cvdnetwork group

---

## Next Steps

1. Implement group preservation in cfctl process spawning
2. Address TAP device permissions (separate issue)
3. Test full boot cycle with both fixes applied
4. Consider if other supplementary groups need preservation
