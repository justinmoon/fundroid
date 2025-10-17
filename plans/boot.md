# Mini OS Boot Plan (Pixel 9a)

Goal: boot a lightweight initramfs that paints the screen, first on the emulator (fast iteration) and then on real Pixel 9a hardware.

## Phase A – Emulator Bring-up
1. **Emulator baseline**
   - Launch the Pixel 9a image (SwiftShader headless) from our repo tooling.
   - Confirm `fastboot boot` works with the stock `boot.img` from the emulator’s system image.

2. **Minimal wrapper init**
   - Build a ramdisk that keeps `/init.stock` but runs a shell wrapper first (logging to `/dev/kmsg`, then exec stock).
   - Boot it via `fastboot boot`; while runtime exits back to Android, inspect `/dev/kmsg` inside the emulator for wrapper breadcrumbs.

3. **Bring in `minios_init`**
   - Have the wrapper spawn our Rust `minios_init`, log a few markers, then `reboot -f`.
   - Boot via `fastboot boot`; verify the markers arrive in `/dev/kmsg` (or emulator log) before the forced reboot.

4. **DRM fill on emulator**
   - Enable the DRM color fill inside `minios_init` and keep the forced reboot.
   - Capture the emulator framebuffer (screencap) to confirm the turquoise fill rendered.

## Phase B – Transition to Pixel 9a
5. **Packaging for device**
   - Freeze the working ramdisk/minios bundle from the emulator.
   - Rebuild `init_boot-phase1.img` with the same layout, but sign it with `avbtool add_hash_footer` (no disable flags) and wrap the signature inside a custom vbmeta that chains to init_boot.

6. **Restore Pixel state**
   - Flash stock `boot/init_boot/vendor_boot/vbmeta*` (already scripted).
   - Verify stock Android boots and USB debugging is enabled.

7. **Flash signed demo**
   - Flash the newly signed `init_boot-phase1.img` (and accompanying vbmeta chain if needed).
   - Boot the phone; read `/dev/kmsg`/`pstore` for markers to confirm the wrapper runs.

8. **Final polish**
   - Remove the forced reboot if the turquoise fill persists on device.
   - Document the exact commands (`fastboot` invocations and key signing steps) for reproducibility.
