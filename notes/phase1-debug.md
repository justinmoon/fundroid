# Phase 1 Debug Notes (Pixel 9a)

- Device: Pixel 9a (`tegu`), factory reset to build BD4A.240925.111.
- `fastboot boot` is unreliable on Tensor/Pixel 9a; falls back to bootloader even with stock images.
- Flashing custom `init_boot` causes immediate bootloader return unless AVB signature handled.
- Stock backups kept in `target/os/phase1/` (`boot-stock.img`, `init_boot-stock.img`, `vbmeta*`, `vendor_boot-stock.img`).
- Restoring factory image required: flash-all.sh (wipes data).
- Current plan: rebuild `init_boot-phase1.img`, sign with `avbtool` (`--disable-verity --disable-verification`) so bootloader accepts it.
- Wrapper init must keep `/init.stock` available; include minimal shell (`/bin/sh`) in ramdisk.
- Use `/dev/kmsg`/pmsg for breadcrumbs; no `pstore` logs when boot handoff fails early.

Next actions:
1. Rebuild ramdisk.
2. Sign `init_boot-phase1.img` using `avbtool` with Pixel 9a key (`--key`/`--algorithm` optional if disabling verification).
3. Flash signed image, observe `/dev/kmsg` after reboot.
- Host avbtool (1.3.0) does not accept `--disable-verity/--disable-verification`; new Python copy needed.
- Fastboot loses connection when custom init_boot flashed; device reverts to bootloader immediately.
