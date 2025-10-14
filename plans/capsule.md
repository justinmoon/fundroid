# Capsule Plan

## Purpose
- Host a minimal Android HAL environment (“capsule”) alongside `webosd` inside the rooted emulator so Rust bridges can talk to real Binder services without the full Android framework.
- Keep the footprint small: only the binder devices, service managers, property service, and the HAL binaries we intend to exercise.
- Deliver an automated acceptance test (`just capsule-hello`) that proves the capsule boots and answers `IServiceManager::listServices`.

## Constraints & Assumptions
- Capsule runs *inside* the emulator/device via `adb root`; macOS host never tries to mount binderfs.
- Emulator image is Android 34 default (arm64 on Apple Silicon, x86_64 on Intel); adjust paths if this changes.
- We have root + `adb remount` capability; SELinux stays permissive for this milestone (`setenforce 0` in the capsule launch wrapper).
- Maintain a flat repo: new code lives under `android/capsule/`, `scripts/`, and `rust/capsule_tools/`.

## Stage 0 — Environment Prep (PR 0)
- **Commit A:** Add `just capsule-shell` (`adb root && adb shell`) for quick access; confirm we can enter a root shell on the emulator.
- **Commit B:** Document required kernel features (`CONFIG_ANDROID_BINDERFS`, `CONFIG_USER_NS`, `CONFIG_PID_NS`) and add a helper script to print them; update bootstrap docs to enforce `adb disable-verity && adb remount`, noting AVD reset caveat.

## Stage 1 — Collect Required Android Binaries (PR 1)
- **Commit A:** Introduce `scripts/download_emulator_system.sh` that runs `sdkmanager` and `simg2img` to unpack the exact Android 34 system image into a temporary directory (manual `ls` verification).
- **Commit B:** Extend the script to copy needed executables (`servicemanager`, `hwservicemanager`, `property_service`), dependent shared libs, and config files into `android/capsule/system/`; emit `android/capsule/manifest.toml` with SHA256 hashes and add `.gitignore` to keep binaries out of git.

## Stage 2 — Assemble Capsule Root (PR 2)
- **Commit A:** Create the directory skeleton `android/capsule/rootfs/{system,vendor,init,scripts}`, add placeholder `init.capsule.rc` / `capsule_entry.sh`, and wire `.gitignore` for generated content.
- **Commit B:** Implement `capsule_entry.sh` to create runtime dirs, mount binderfs, and `chroot` into `rootfs`; update `scripts/run_capsule.sh` to push/pull the tree, start/stop the capsule idempotently, and set SELinux permissive inside the capsule.

## Stage 3 — Capsule Process Supervision (PR 3)
- **Commit A:** Fill `init.capsule.rc` with minimal services (start `servicemanager`, `hwservicemanager`) and basic on-boot ordering.
- **Commit B:** Add `property_service`, log mounts (`/dev/kmsg`, `/dev/log`), readiness property (`capsule.ready`), and `scripts/capsule_logcat.sh` for filtered logging.

## Stage 4 — Rust Tooling (`rust/capsule_tools`) (PR 4)
- **Commit A:** Scaffold the crate, add shared binder helper library, implement `wait_for_binder` binary (binder device path CLI flag, timeout handling), and add `just build-capsule-tools`.
- **Commit B:** Implement `list_services`, add push helper to deploy binaries into the capsule, and include integration tests (run only when `CAPSULE_TESTS=1`) to keep CI predictable.

## Stage 5 — Acceptance Test (`just capsule-hello`) (PR 5)
- **Commit A:** Add shell-based smoke test: start capsule, verify binder device nodes exist, stop capsule; expose as `just capsule-smoke`.
- **Commit B:** Promote to full acceptance: run `wait_for_binder` and `list_services`, assert known entries, collect logs into `artifacts/capsule/`, wrap everything in `just capsule-hello`.

## Stage 6 — Integration Hooks
- Add environment variables in `webosd` (and future bridges) so they can target the capsule binder devices explicitly (`BINDER_DEVICE=/data/local/tmp/capsule/dev/binder` etc.).
- Provide `scripts/capsule_exec.sh` that runs arbitrary commands inside the capsule namespace for quick experiments (`adb shell run-as-capsule <cmd>` equivalent using `nsenter` if available).
- Document in code comments how to switch bridges between “host binder” and “capsule binder” paths.

## Stage 7 — CI Considerations
- `just ci` gains a capsule job guarded by a feature flag (`CI_ENABLE_CAPSULE`). Default off locally; enabled on Linux runners with nested virtualization.
- The CI job boots the emulator headless (existing infra), runs `just capsule-hello`, and uploads logs.
- Add watchdog to kill the emulator if the capsule doesn’t signal readiness within 90 seconds to keep CI runs bounded.

## Stage 8 — Ready for Next Milestones
- Once the acceptance test is green, expand the capsule with specific HAL daemons per milestone (Radio, Camera, Audio). Each addition reuses the same scripts; only the manifest and init rc change.
- Maintain a changelog comment block at the top of `init.capsule.rc` to note new services and why they were added.
- After Stage 1–5, begin generating binder client stubs for the first bridge (likely Audio or Radio) and wire them to `webosd` for real HAL interaction.

## Workstream Parallelism
- Stages 0–2 (kernel verification, system image extraction, rootfs assembly) are strictly sequential; they establish the baseline capsule.
- After Stage 2, split three streams that can proceed in parallel:
  - Capsule runtime (Stage 3) — flesh out `init.capsule.rc`, binder mounts, process supervision, log plumbing.
  - Rust tooling (Stage 4) — implement `wait_for_binder` / `list_services` and related push helpers.
  - Automation wrapper (Stage 5) — script `just capsule-hello`, manage emulator lifecycle, collect logs.
- Once `capsule-hello` is reliable, the next steps also parallelize:
  - Bridge hooks (Stage 6) and CI wiring (Stage 7) can be pursued concurrently.
  - HAL integrations (Stage 8) branch into independent efforts per HAL; coordinate edits to shared manifest/init files but otherwise proceed in parallel.

```
[Stage 0 ➜ Stage 1 ➜ Stage 2]
            ↓
   +---------------------------+
   |                           |
[Stage 3]                 [Stage 4]
   |                           |
   +-----------+---------------+
               |
           [Stage 5]
               |
   +---------------------------+
   |                           |
[Stage 6]                 [Stage 7]
   |                           |
   +-----------+---------------+
               |
           [Stage 8]
        /      |       \
   Audio    Camera    Radio
```
