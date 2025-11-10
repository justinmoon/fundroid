# Pixel 4a Bring-up

Goal: use the Pixel 4a (sunfish) as the first physical device for our custom PID1 and DRM demo before attempting newer hardware.

## Step 1 – Stock Baseline + Backups
- Unlock bootloader (if not already) and capture stock partitions: `fastboot fetch init_boot init_boot-stock.img`, `fastboot fetch boot boot-stock.img`.
- Boot the stock OS, enable USB debugging, and confirm `adb devices` lists the phone.
- Store the pulled images under `devices/pixel4a/stock/`.
**Acceptance test:** Files `devices/pixel4a/stock/init_boot-stock.img` and `boot-stock.img` exist and match the SHA256 checksums recorded in a README within that directory.

## Step 2 – Root Access for Iteration
- Install Magisk, patch `init_boot-stock.img`, and flash the patched image (`fastboot flash init_boot magisk_patched.img`).
- Verify `adb shell su -c id` returns `uid=0(root)` after approving the prompt.
**Acceptance test:** Running `adb shell su -c id` prints `uid=0(root)`; failure to obtain root blocks further steps.

## Step 3 – Deploy Logging PID1
- Reuse the PID1 binary from `docs/plans/cf-pid1-logging.md` (the one that logs to `/dev/kmsg`).
- Repack `init_boot` locally, flash with `fastboot flash init_boot build/init_boot_pixel4a_logging.img`, and boot the device.
- Collect `adb logcat` + `adb shell cat /proc/kmsg | grep cf-pid1` to ensure logs appear.
**Acceptance test:** Within 30 seconds of boot, `adb logcat` contains `[cf-pid1] wrapper starting` and the device reaches the Android lock screen.

## Step 4 – Run `drm_rect`
- With the logging PID1 still in place, push the `rust/drm_rect` binary via `adb push` and run the same sequence used in `just run-drm-demo` (stop SurfaceFlinger, run binary, restart services).
- Capture a screenshot using `adb exec-out screencap` to verify the solid color render.
**Acceptance test:** The captured screenshot shows the solid turquoise screen, and `drm_rect` exits 0 without rebooting the phone.

## Step 5 – Iterate Toward Standalone PID1
- Modify the PID1 to stop SurfaceFlinger itself and launch `drm_rect` automatically (mirroring the Cuttlefish plan).
- Flash the updated `init_boot` and verify the phone boots, displays the color fill for the expected duration, then returns to Android.
**Acceptance test:** Boot completes with `[cf-drm] success` logs in `adb logcat`, and the device is usable afterward without reflashing stock images.
