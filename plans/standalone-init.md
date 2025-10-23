# Standalone Init Roadmap (Blue Screen Milestone)

Goal: replace `/init.stock` with our own first-stage program that boots far enough to paint the screen a solid colour (e.g. blue). We keep the scope small, rely on simple static Zig/C binaries, and introduce new responsibilities one at a time with clear toggles and acceptance checks.

---

## Phase 0 — Instrument Without Changing Behaviour

1. **Breadcrumbs to /tmp**
   - Extend the current passthrough wrapper to log to `/dev/kmsg` and append lines to `/tmp/cf_init_marker`.
   - Acceptance: after booting the stock system, we can retrieve the marker file via `adb shell cat /tmp/cf_init_marker`, proving the wrapper ran.

2. **Fallback markers under /metadata**
   - Mirror the same breadcrumbs to `/metadata/cf_init/marker.log` (mkdir best-effort; ignore failures).
   - Acceptance: boot still completes; when `/metadata` is writable the log contains our markers.

3. **Snapshot runtime facts**
   - Before execing stock init, dump `/proc/cmdline` and `/proc/mounts` to `/tmp/cf_init_report.txt`.
   - Acceptance: file exists post-boot and matches the values stock init sees.

This phase gives us observability with zero behavioural changes.

---

## Phase 1 — Shadow Stock Init Responsibly

4. **Mount idempotent filesystems**
   - Have the wrapper mount `devtmpfs`, `proc`, and `sysfs` the same way Android does, but never unmount them.
   - Acceptance: logs show “already mounted” at worst; Android still boots normally.

5. **Cold-plug devices**
   - Walk `/sys/class/**/uevent` and `/sys/block/**/uevent`, writing `add` to each so `/dev/dri/card0` and `/dev/input/event0` appear before stock init runs.
   - Acceptance: pausing stock init (sleep) still leaves those device nodes present.

6. **Dry-run fstab parsing**
   - Parse `first_stage_ramdisk/fstab.<device>` and log the mounts we would perform (target, fs type, verity flags) without mounting yet.
   - Acceptance: logged plan matches the mounts stock init performs (compare against `mount` output).

We now understand the boot environment and can prove our code would behave the same.

---

## Phase 2 — Toggleable Replacements

Introduce boot flags (e.g. `androidboot.cf_mounts=1`) so each responsibility can be turned on independently. Default remains “hand off to stock”.

7. **First-stage mounts (flagged)**
   - When the flag is set, perform the fstab mounts ourselves and set a property to tell stock init to skip its mount pass.
   - Acceptance: with the flag, our logs show successful mounts and stock init no longer remounts them; without the flag behaviour matches Phase 1.

8. **Property service stub**
   - Under `androidboot.cf_props=1`, start a minimal property server that serves the handful of keys vendor blobs need; disable the stock property service when the flag is present.
   - Acceptance: `getprop ro.hardware` and other required keys work in both modes.

9. **SELinux bootstrap**
   - With `androidboot.cf_selinux=1`, load the precompiled policy, set permissive, and skip stock init’s policy load.
   - Acceptance: `getenforce` reports `Permissive`, no “failed to load policy” errors appear, and the flag off path still lets stock init load policy itself.

Each capability now works either in “observe” or “replace” mode, gated by a flag.

---

## Phase 3 — No-Stock Experiments

10. **Flagged no-handoff mode**
    - Add `androidboot.cf_no_stock=1` that keeps us from execing `/init.stock`. Instead, launch a debug shell (or a trivial loop) so we can poke around.
    - Acceptance: with the flag, the system stays in our environment and we can access the shell over `adb`; without the flag, Android boots normally.

11. **DRM paint from our init**
    - In no-stock mode, spawn the existing `drm_rect` binary after mounts/cold-plug complete and keep PID 1 running.
    - Acceptance: device/emulator displays a solid colour; kernel log shows `/dev/dri/card0` opened.

This proves we can live without stock init for controlled sessions.

---

## Phase 4 — Default to Standalone Init

12. **Promote replacements to default**
    - Flip the boot flags on by default, keeping opt-out flags for safety while we stabilise.
    - Acceptance: Cuttlefish CI boots our image, finds the boot markers, and confirms the colour fill without needing `/init.stock`.

13. **Clean fallback path**
    - Decide on a final failsafe (e.g. boot arg `androidboot.cf_use_stock=1`) before removing `init.stock` from the ramdisk altogether.
    - Acceptance: default boot path never touches stock init, yet we can re-enable it via the failsafe flag during debugging.

---

## Notes

- All early steps can stay in a tiny Zig/C binary built with `zig cc -static`. We tackle a Rust PID 1 only after the flow is proven.
- Every step should ship with CI smoke tests: boot Cuttlefish, gather `/dev/kmsg`, verify markers, and ensure flags behave as expected.
- Keep generated images and logs out of the repo; use `build/` for local artifacts in `.gitignore`.
