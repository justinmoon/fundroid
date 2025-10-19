# Mini OS Boot Plan (Pixel 9a)

Goal: boot a lightweight initramfs that paints the screen, first on the emulator (fast iteration) and then on real Pixel 9a hardware.

### Progress (Oct 18, 2025)
- Automated `scripts/build_phase1.sh` to detect device arch, rebuild `minios_init`, bundle runtime deps, and produce signed `boot/init_boot` artifacts ready for Cuttlefish+hardware.
- `minios_init` now force-creates `/dev/{console,null,tty,kmsg,urandom}`, emits short heartbeat logs, writes a phase marker under `/metadata`, and attempts a direct `SYS_reboot`.
- Signed `init_boot-phase1.img` can be shipped with `just cuttlefish-deploy-phase1`, which uploads to a per-instance workspace (`~/cuttlefish-instances/<instance>/`) and wires the service env automatically. The Cuttlefish stack boots it, though our logging markers are still missing in the host logs.
- Remaining gaps: confirm our markers reach an observable sink (console/kmsg), understand why the hard reboot is a no-op, and wire up a per-worktree Cuttlefish workflow so multiple agents can iterate safely.

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
   - Use `just cuttlefish-deploy-phase1` (or manually copy) to ship the freshly signed images per instance, then flash the Pixel with `fastboot flash init_boot ...` (include vbmeta chain if needed).
   - Boot the phone; read `/dev/kmsg`/`pstore` for markers to confirm the wrapper runs.
    - If kmsg is locked down, fall back to `/dev/console`, `logcat`, or a persistent scratch file under `/metadata`.

8. **Final polish**
   - Fix the reboot path (either via the kernel syscall or by chaining back into `init.stock`) once the turquoise fill is visible.
   - Document the exact commands (`fastboot` invocations, signing steps, remote deployment helpers) for reproducibility.

## Next Actions
1. **Capture minios markers** – redirect logging to `/dev/console` (and mirror to `/metadata/minios_phase1/last_run`) so we can prove the Rust init ran inside Cuttlefish; add explicit error handling around the reboot syscall.
2. **Per-worktree Cuttlefish orchestration** – design the equivalent of `.emulator-serial` for Cuttlefish:
   - assign a deterministic instance name per worktree (e.g. `cvd-{worktree}`),
   - store per-instance `CUTTLEFISH_*` overrides in `/etc/cuttlefish/instances/<name>.env`,
   - provide local helpers (`scripts/cuttlefish_instance.sh`, `just cuttlefish-*`) to set images, (re)start, and tail logs without clobbering other agents.
   - add a weekly GC timer on the Hetzner host to remove stale instances/assemblies/env files. ✅
3. **CI integration** ✅ – `CI_ENABLE_CUTTLEFISH=1 just ci` now builds the Phase 1 artifacts, deploys them to a dedicated `ci-cuttlefish` instance, restarts the service, and fails the job if the console log lacks the `minios heartbeat` markers.
4. **Re-verify Phase 1 loop** – now that automation exists, tighten the spec (better logging sink, reliable reboot) and expand coverage beyond the heartbeat smoke test.
