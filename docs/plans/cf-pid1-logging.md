# Cuttlefish PID1 Logging + `drm_rect`

Goal: prove we control PID 1 on Hetzner, see its logs in the captured console, and run `drm_rect` under that init before touching the full compositor.

## Step 1 – Capture a Stock Console Baseline
- Run `just capture-stock-console` (or call `scripts/capture-stock-console.sh <dir>`). It builds cfctl-lite (if needed), boots a stock guest with `--verify-boot`, and writes everything under `logs/stock-console-YYYYmmdd-HHMMSS/`.
- Inspect `${run}/console.log` and `${run}/logcat.txt` for `init:` and `surfaceflinger` lines; `${run}/kernel.log` is copied from the kept state dir for completeness.
- The command also drops `${run}/run-summary.json` so you can see the exact cfctl-lite output later.
**Acceptance test:** The generated `console.log` shows Android’s PID1 (`init: starting service …`) and SurfaceFlinger boot chatter without checking anything into git.

## Step 2 – Add an Early `/dev/kmsg` Marker
- Modify `init/init_wrapper.c` (or the smallest heartbeat variant) to mount `devtmpfs`, open `/dev/kmsg`, and write `[cf-pid1] wrapper starting`.
- Repack `init_boot` the way `just heartbeat` expects.
- Boot a test guest with `just heartbeat` and download the resulting `logs/heartbeat-*.log`.
**Acceptance test:** The saved heartbeat log contains `[cf-pid1] wrapper starting` **before** any stock Android log lines.

## Step 3 – Fail Fast When the Marker Is Missing
- Teach `scripts/test-heartbeat.sh` to grep the captured console for `[cf-pid1] wrapper starting`.
- On failure, emit a helpful message and exit non-zero so CI cannot silently regress logging.
- Re-run `just heartbeat` to confirm the new check passes.
**Acceptance test:** Breaking the marker string (e.g., editing it locally) causes `just heartbeat` to fail with “PID1 marker missing”; reverting restores a green run.

## Step 4 – Run `drm_rect` from the Ramdisk
- Copy the statically linked `rust/drm_rect` binary into the ramdisk used by `just heartbeat`.
- Inside PID1: stop SurfaceFlinger/hwcomposer (`setprop ctl.stop …`), exec `/bin/drm_rect`, wait for exit, then restart the Android services before chaining to `/init.stock`.
- Extend the heartbeat log parsing to look for `[cf-drm] success`.
**Acceptance test:** `just heartbeat` finishes with stock Android boot complete while the console log shows both `[cf-drm] launching` and `[cf-drm] success` around the long orange-screen window.

## Step 5 – Check Everything into Version Control
- Commit the wrapper changes, heartbeat script changes, and any helper tooling.
- Document the workflow in `docs/cuttlefish.md` (one paragraph) so future agents know how to rerun it.
**Acceptance test:** Fresh clone, `nix develop`, `just heartbeat` succeeds without additional manual steps and produces a log containing both the PID1 marker and `[cf-drm] success`.
