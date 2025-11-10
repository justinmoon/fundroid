# Cuttlefish Ramdisk Packaging

Goal: turn the working `qemu-init/` artifacts into a repeatable Cuttlefish-ready ramdisk + init_boot image that `cfctl` can boot automatically.

## Step 1 – Snapshot QEMU Artifacts
- Run `./qemu-init/test-phase7.sh` locally to ensure the compositor + test-client still pass.
- Copy the resulting binaries (`compositor-rs`, `test-client`, helpers) plus required libs/modules into `out/cuttlefish-rootfs/`.
- List the directory tree to confirm all assets are present.
**Acceptance test:** `tree out/cuttlefish-rootfs` shows the binaries and kernel modules, and `test-phase7.sh` exits 0.

## Step 2 – Script Ramdisk Assembly
- Write `scripts/build_cuttlefish_ramdisk.sh` that packs `out/cuttlefish-rootfs` into `ramdisk.cpio` then compresses with lz4.
- The script should print the resulting size and fail if required files are missing.
- Store artifacts under `build/cuttlefish-ramdisk/` for downstream steps.
**Acceptance test:** Running the script creates `build/cuttlefish-ramdisk/ramdisk.lz4` and `lsinitramfs` shows `/init`, `/compositor-rs`, `/test-client`.

## Step 3 – Repack `init_boot`
- Automate `mkbootimg` + `avbtool add_hash_footer` using the stock kernel + metadata from `/var/lib/cuttlefish/images/init_boot.img`.
- Emit `build/init_boot_compositor.img` and write its path to `build/latest-init-boot` for scripts to consume.
**Acceptance test:** `unpack_bootimg --boot_img build/init_boot_compositor.img` succeeds and the extracted ramdisk contains the files from Step 2.

## Step 4 – Wire Into cfctl Workflow
- Add a `just cuttlefish-compositor` target that depends on Steps 1–3, synchronizes the new `init_boot` to Hetzner (e.g., `scp` into `~/artifacts/`), and invokes `cfctl instance create-start --purpose ci --verify-boot --disable-webrtc` with the override.
- Capture console logs to `logs/compositor-<timestamp>.log` and destroy the instance on completion.
**Acceptance test:** Running `just cuttlefish-compositor` ends with `VIRTUAL_DEVICE_BOOT_COMPLETED` and records `[cf-compositor] init` markers in the saved log.

## Step 5 – Document and Gate
- Update `docs/plans/cf-pid1-logging.md` (or README) with a short “Run `just cuttlefish-compositor`” paragraph.
- Add a CI check (or local script) that ensures the ramdisk script + repack script are invoked before pushing.
**Acceptance test:** Fresh checkout + `nix develop` + `just cuttlefish-compositor` works end-to-end without editing scripts, and CI refuses to run if artifacts are stale.
