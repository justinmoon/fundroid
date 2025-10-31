**Cuttlefish Phase-1 Plan**

We previously made some progress getting a PID 1 init running in cuttlefish, but got stuck and tried to simplify by doing it in qemu instead. `compositor-rs` succeeded here. `./run.sh --gui gfx=compositor-rs` from `qemu-init/`  directory succeeded with this. Now we want to get a simliar PID 1 that can boot and run a wayland compositor running in Cuttlefish in these steps:

- **Baseline + Stock Forensics**
  - Run `just heartbeat` to make sure the existing PID1 override still boots; archive the console and kernel logs for baseline comparison.
  - Unpack `/var/lib/cuttlefish/images/init_boot.img` on Hetzner, documenting header version, compression, ramdisk layout, bundled modules, and the stock `/init`.
  - Launch a stock instance with `cfctl instance create-start --purpose ci`, scrape its kernel log for mount order, SELinux mode, virtio-gpu activation, and the point `/dev/dri/card0` appears.

- **Capability + Binary Prep**
  - Integrate the capability plumbing from commit `ac3259a` so `cfctl` can pipe supplementary groups and `--cap-add` flags into bubblewrap, then run `cargo test -p cfctl` to keep coverage.
  - Rebuild `compositor-rs` and `test-client` for `x86_64-unknown-linux-musl`; verify `file`/`ldd` confirm static PIE binaries and record their sizes for ramdisk budgeting.

- **Rootfs Artifact**
  - Generalise the `qemu-init` packaging so it emits a cuttlefish-ready tarball that contains busybox, any needed helpers, `compositor-rs`, `test-client`, and a thin init wrapper, reusing kernel modules when the Android kernel expects them.
  - Script the ramdisk build (cpio plus lz4/gzip) and add a smoke test that lists the final layout, ensuring `/run/wayland`, `/dev`, `/proc`, and `/sys` are present with correct permissions.

- **PID1 Implementation**
  - Add `cuttlefish/init/compositor-init` that logs to `/dev/kmsg` immediately, mounts essentials, loads the virtio GPU stack with graceful fallbacks, waits on `/dev/dri/card0`, sanity-checks DRM ioctls, then launches `compositor-rs` followed by `test-client`, emitting success/failure markers and supervising both.
  - Unit test helper routines where practical and add a lightweight integration harness (e.g., running under a container) to catch regressions outside of full Cuttlefish boots.

- **init_boot Repack**
  - Automate repacking by combining the stock kernel and metadata with the new ramdisk via `mkbootimg`, preserving header, OS version, and patch level.
  - Re-unpack the produced image in CI to confirm `/init`, permissions, and compression match expectations.

- **cfctl Wiring**
  - Add a “compositor” profile (or similar knob) so `cfctl` chooses the new `init_boot`, exports `CUTTLEFISH_BWRAP_CAPS="--cap-add cap_net_admin"`, and applies `cvdnetwork,kvm` supplementary groups for the guest user.
  - Extend `cfctl` tests to cover supplementary group parsing and capability string generation.

- **Local Automation Loop**
  - Implement `just compositor-cuttlefish` that builds binaries, assembles the ramdisk, repacks `init_boot`, syncs to Hetzner, launches `cfctl instance create-start --purpose ci --verify-boot`, tails the console for the compositor and client markers, and destroys the instance on completion.
  - On failure, dump logs, grep for `[cf-compositor]`, `panic`, or DRM errors, and iterate until the automation exits cleanly.

- **Remote Validation + Artifacts**
  - Redeploy the flake on Hetzner (`just hetzner`), rerun the automation there, and store console plus cfctl logs as golden references.
  - Document the workflow, expected log markers, and troubleshooting tips so the next phases (input handling, richer clients) build on a stable base.
