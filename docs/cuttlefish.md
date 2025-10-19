# Cuttlefish Stock Emulator Reference

## Remote Host
- All CI/emulator runs occur on the Hetzner NixOS server reachable as `ssh hetzner`.
- Stock images live under `/var/lib/cuttlefish/images`; the systemd template `cuttlefish@<id>` uses them unless a custom deploy overrides an image via `cfctl`.

## Stock Boot Sanity Check
```sh
cfctl instance create        # allocates an ID, e.g. 61
cfctl instance start 61      # launches cuttlefish@61 with stock images
cfctl wait-adb 61 --timeout-secs 180
# ... interact via adb if desired ...
cfctl instance destroy 61
```
- Expect `VIRTUAL_DEVICE_BOOT_COMPLETED` in the journal within ~30 s and `adb get-state` ⇒ `device`.
- No local artifacts or custom ramdisks are required for this baseline check.

## Image Inventory (`/var/lib/cuttlefish/images`)

| File | Role |
| --- | --- |
| `boot.img` | Linux kernel + default ramdisk used when no custom `init_boot` is supplied. |
| `init_boot.img` | First-stage init ramdisk (Android 13+). Replacing this is how we test our minimal init. |
| `vendor_boot.img` | Vendor-provided additions to the first stage (modules, extra ramdisk bits). |
| `super.img` | Dynamic super partition aggregating `system`, `product`, `vendor`, etc. |
| `system.img` | Read-only system partition contents. |
| `userdata.img` | Writable data partition used by the emulator guest. |
| `vbmeta.img`, `vbmeta_system.img`, … | AVB metadata that signs the various boot partitions. |
| `aosp_cf_x86_64_only_phone-img-*.zip` | Upstream archive from Google; unpacked into the images above. |
| `android-info.txt`, `fastboot-info.txt` | Metadata describing the build and fastboot layout. |

## Notes
- `~/configs/hetzner/cfctl` now contains the daemon and packaging; this repo no longer builds cfctl itself.
- When iterating on custom init images, use `scripts/build_phase1.sh` to produce artifacts locally, then `cfctl deploy --init <path>` to override the stock `init_boot.img`. Stock runs require none of that machinery.

## Handy Commands
- `cfctl instance create/start/wait-adb/destroy` — quick stock boot check on the Hetzner host.
- `CUTTLEFISH_REMOTE_HOST=hetzner ./scripts/cuttlefish_instance.sh status` — inspect the shared instance state.
- `just ci` — runs the formatting/linting suite and the stock Cuttlefish smoke test described above.
- Locally, if `cfctl` is not installed you can skip the smoke test with `CI_SKIP_STOCK_SMOKE=1 just ci`.
