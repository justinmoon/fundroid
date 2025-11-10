# Ideas Backlog

## Cuttlefish + Compositor
- Keep a stock baseline handy: always archive `kernel.log`, `console_log`, and `cfctl logs --stdout` before testing new `init_boot` images so regressions are obvious.
- `cfctl` already understands supplementary groups/capabilities (see commit `ac3259a`); expose a “compositor” profile that exports `CUTTLEFISH_BWRAP_CAPS="--cap-add cap_net_admin"` and joins `cvdnetwork,kvm` when launching guests.
- Package `compositor-rs`, `test-client`, busybox, and helpers into a tarball straight out of `qemu-init`; then reuse the same scripts to assemble both the QEMU initramfs and the Cuttlefish ramdisk.
- Add a `just cuttlefish-compositor` loop that: builds binaries → assembles ramdisk → repacks `init_boot` → uploads to Hetzner → runs `cfctl instance create-start --purpose ci --verify-boot` → greps for `[cf-compositor]` markers before destroying the guest.

## Init & Ramdisk Learnings
- First-stage Android ramdisks ship device nodes but no shell; PID1 overrides must be static binaries that call `execve("/init.stock", ...)`.
- Editing the ramdisk via `scripts/cpio_edit.py` avoids clobbering device nodes; always run `avbtool add_hash_footer` afterward or the bootloader rejects the image.
- `/dev/kmsg` writes are the only reliable way to see PID1 logs on Hetzner—stdout/stderr vanish once the kernel switches consoles.
- Stock `init_boot.img` uses LZ4 + header version 4; reuse its metadata (OS version 16.0.0, patch 2025-06) when rebuilding with `mkbootimg`.

## Weston / Wayland References
- Study these projects for future compositor work: [phoc](https://gitlab.gnome.org/World/Phosh/phoc), [cage](https://github.com/cage-kiosk/cage), [weston](https://gitlab.freedesktop.org/wayland/weston), [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots), [catacomb](https://github.com/catacombing/catacomb).
- Reading list: [Wayland Book](https://wayland-book.com/), Drew DeVault’s [Introduction to Wayland](https://drewdevault.com/2017/06/10/Introduction-to-Wayland.html), and the [Smithay book](https://smithay.github.io/book/intro.html).
- Weston DRM backend needs `seatd`, `libinput`, `pixman`, and `mesa`; a future rootfs should bundle these plus `/etc/weston.ini`, `/run/wayland`, and a startup helper.
