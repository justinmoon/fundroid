# DRM Rect Demo (Direct DRM/KMS Bring-up)

This document captures the exact steps we used to light up a Pixel device with the `drm_rect` demo. The flow assumes you are comfortable unlocking the bootloader and temporarily running Magisk for root access.

## Requirements
- Pixel device (tested on Pixel 9 Pro, codename `tegu`) with an unlocked bootloader.
- USB debugging enabled on the device.
- `adb`/`fastboot` from the Android SDK on your host.
- This repository checked out on your host machine.

> ⚠️ Unlocking the bootloader wipes user data and shows an unlock warning on boot. Do **not** relock the bootloader until you have restored the stock images.

## One-time Bootloader & Root Setup
1. Enable **Developer options** on the phone, then toggle **OEM unlocking** and **USB debugging**.
2. Unlock the bootloader:
   ```sh
   adb reboot bootloader
   fastboot flashing unlock
   ```
   Confirm on the device. It will erase /data and reboot.
3. Install Magisk 29.0 (or newer) on the phone:
   ```sh
   curl -L -o Magisk.apk https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk
   adb install -r Magisk.apk
   ```
4. Capture and patch the `init_boot` partition:
   ```sh
   adb reboot bootloader
   fastboot fetch init_boot init_boot-stock.img     # keep this safe for rollback
   fastboot reboot
   adb wait-for-device
   adb push init_boot-stock.img /sdcard/Download/
   ```
   On the device, open Magisk → **Install** → **Select and Patch a File** and choose `Download/init_boot-stock.img`. Note the output name (e.g. `magisk_patched-29000_wAgP7.img`).
5. Flash the patched image:
   ```sh
   adb reboot bootloader
   adb pull /sdcard/Download/magisk_patched-*.img magisk_patched_init_boot.img
   fastboot flash init_boot magisk_patched_init_boot.img
   fastboot reboot
   adb wait-for-device
   ```
6. Grant root:
   ```sh
   adb shell su -c id
   ```
   Approve the Magisk prompt on the phone; the command should print `uid=0(root)`.

## Running the DRM Rect Demo
With the device rooted, a single Just command performs the end-to-end demo:
```sh
just run-drm-demo
```
The recipe will:
- Build the correct `drm_rect` binary for the connected device.
- Push it to `/data/local/tmp/drm_rect`.
- Set SELinux to permissive (best-effort).
- Stop `surfaceflinger` and `vendor.hwcomposer-3` to release the DRM master.
- Execute the demo, which paints the screen for ~30 seconds.
- Restart the display stack and revert SELinux to enforcing.
- Remove the temporary binary.

You should see a solid turquoise screen during execution. Capture a screenshot if needed:
```sh
adb exec-out screencap -p > ~/Desktop/drm_rect.png
```

## Cleaning Up / Restoring Stock
When you are finished, restore the original `init_boot`:
```sh
adb reboot bootloader
fastboot flash init_boot init_boot-stock.img
fastboot reboot
```
Optionally restore `boot-stock.img` if you modified it, then relock the bootloader **only after** flashing the stock images:
```sh
fastboot flashing lock
```
Relocking wipes /data again, so make sure you have already backed up anything important.

---

If you need to re-run the demo later, you only have to repeat `just run-drm-demo`; the bootloader/Magisk steps are one-time unless you reflash the stock `init_boot`.
