# AOSP Cuttlefish Host Package Build

This directory contains infrastructure for building custom cuttlefish host tools from AOSP sources.

## Overview

We build our own cuttlefish host package to patch out Bluetooth dependency failures that crash headless CI instances.

**Build**: `aosp_cf_x86_64_only_phone-userdebug` (build 14085914)  
**Patch**: Skip Bluetooth boot failures when `enable_host_bluetooth=false`

## Quick Start

On the Hetzner machine:

```bash
# 1. Enter the FHS build environment
/tmp/result/bin/aosp-fhs

# 2. Build
cd ~/aosp
source build/envsetup.sh
lunch aosp_cf_x86_64_only_phone-userdebug
m run_cvd kernel_log_monitor -j8

# 3. Package
bash /tmp/rebuild-patched.sh
```

## Patch Applied

**File**: `device/google/cuttlefish/host/commands/run_cvd/boot_state_machine.cc`

**Purpose**: When a Bluetooth dependency check fails during boot, don't crash the VM if Bluetooth is intentionally disabled (headless mode).

**Changes**:
1. Inject `CuttlefishConfig` into `CvdBootStateMachine` constructor
2. In `OnBootEvtReceived()`, check if boot failure is Bluetooth-related
3. If `config_.enable_host_bluetooth()` is false AND failure is Bluetooth, log warning and continue
4. Otherwise, fail as normal

See `/tmp/apply-bluetooth-patch-v3.py` on Hetzner for patch application script.

## Artifacts

**Location**: `~/cuttlefish-host-package-patched/` on Hetzner

**Tarball**: `cvd-host_package-aosp-14085914-bluetooth-headless.tar.gz`  
**SHA256**: `2918acb015039a3b2cc455fea6df8cd702d7a3acd7fd24f1b00bed126cb1c4e2`  
**Size**: 42MB

**Contents**:
- `bin/run_cvd` (21MB) - Main launcher (PATCHED)
- `bin/kernel_log_monitor` (2.5MB) - Boot monitor
- `bin/cvd` (86MB) - CLI tool
- `bin/{launch_cvd,stop_cvd,adb_connector,cvd_internal_*}` - Helper tools
- `lib64/libcuttlefish_*.so` - Shared libraries

## Nix Store Integration

After building, add the artifacts to the Nix store:

```bash
# Add tarball to store (gets cached automatically)
nix-store --add-fixed sha256 ~/cuttlefish-host-package-patched/cvd-host_package-aosp-14085914-bluetooth-headless.tar.gz
# => /nix/store/7v59sifrpiac1b0a880rl3pbgxb44dl3-cvd-host_package-aosp-14085914-bluetooth-headless.tar.gz

# Add unpacked binaries to store
nix-store --add ~/cuttlefish-host-package-patched/
# => /nix/store/8y02y8f9namzpvsc0k1cpg84qk8wipfw-cuttlefish-host-package-patched
```

**Benefits**:
- Subsequent builds/deployments use the cached version
- No need to upload to external server
- Nix garbage collection aware
- Can be copied to other Nix machines with `nix copy`

## Using in Configuration

Reference the Nix store path directly:

```nix
# hetzner/configuration.nix  
cuttlefishHost = /nix/store/8y02y8f9namzpvsc0k1cpg84qk8wipfw-cuttlefish-host-package-patched;
```

Or if you need tarball format, reference that path and unpack it in your derivation.

## Workflow for Updates

When you need to rebuild/update the cuttlefish binaries:

### 1. Build on Hetzner

```bash
ssh hetzner
nix develop /tmp/nixos-config#aosp  # Or use aosp-build from system packages

cd ~/aosp
source build/envsetup.sh
lunch aosp_cf_x86_64_only_phone-userdebug
m run_cvd kernel_log_monitor -j8
```

### 2. Package

```bash
bash /tmp/rebuild-patched.sh
```

This creates `/var/lib/aosp/artifacts/cvd-host_package-complete.tar.gz`

### 3. Deploy

```bash
# The builtins.path in configuration.nix will detect content changes
just hetzner  # Rebuilds and deploys
```

The `builtins.path` import is content-addressed, so changing the tarball triggers automatic rebuilds.

### 4. Verify

```bash
ssh hetzner "cuttlefish-fhs run_cvd --help"
cfctl instance create-start --purpose ci --verify-boot
```

## Build Environment

We use `buildFHSEnv` (see `aosp-cuttlefish.nix`) because AOSP's build system expects:
- Tools in `/usr/bin` (coreutils, diffutils, etc.)
- Traditional FHS paths
- Soong/ninja spawn `/bin/sh` with minimal PATH

Without FHS, builds fail with "command not found" for `cmp`, `mv`, `rm`.

## Integration Details

**Key files**:
- `hetzner/configuration.nix` - Imports tarball with `builtins.path`, wraps structure
- `hetzner/aosp-cuttlefish.nix` - Provides FHS build environment
- `pkgs/cuttlefish-fhs.nix` - FHS runtime environment (modified with .bundle-pin)

**How it works**:
1. Tarball imported content-addressed via `builtins.path` (requires `--impure`)
2. Unpacked to Nix store with `runCommand`
3. Wrapped with `/opt/cuttlefish/` structure via `runCommandNoCC`
4. tmpfiles symlinks `/opt/cuttlefish` → Nix store path
5. FHS auto-mount picks up host `/opt` and uses our binaries

## Testing

After deploying the patched package:

```bash
# Create a headless CI instance
cfctl instance create-start \
  --purpose ci \
  --enable-host-bluetooth=false \
  --verify-boot=true

# Should boot successfully without Bluetooth crash
```

## Maintenance

When updating to a new AOSP build:

1. Sync new AOSP tree: `repo sync -c -j8`  
2. Re-apply patch: `python3 /tmp/apply-bluetooth-patch-v3.py`  
3. Rebuild: `m run_cvd kernel_log_monitor`  
4. Test on a scratch instance before deploying  
5. Update configuration with new SHA256

## References

- AOSP Source: `~/aosp` on Hetzner
- Original patch discussion: See thread with oracle
- Robotnix (inspiration): https://github.com/nix-community/robotnix
