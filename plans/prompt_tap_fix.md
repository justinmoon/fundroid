# Droid Prompt – Fix cfctl TAP Permission Regression

You’re working in `/Users/justin/code/boom`. This repo contains the custom `cfctl` CLI + daemon for managing Cuttlefish instances on our Hetzner host. The goal is to undo a regression introduced by commit `487a5d6` (“cfctl: make guest user/group/caps configurable, preserve env, add caps”). After that change, every guest boot now fails with `qemu-system-x86_64: ... could not configure /dev/net/tun ... Operation not permitted`.

## Background
- `cfctl` currently runs as root on Hetzner via `cfctl.service` (systemd). When starting a guest, we drop privileges before launching `launch_cvd`.
- Pre-regression flow: daemon invoked `setpriv --reuid=<uid> --regid=<primary_gid> --groups=<supplementals> --ambient-caps=+net_admin -- ...` directly. Because the process still had `CAP_SETPCAP`, `setpriv` successfully added `CAP_NET_ADMIN` to the ambient set, so QEMU could configure TAP devices.
- Regression: we now shell through `sudo -u <guest_user> -g <primary_group> -- setpriv --ambient-caps +net_admin -- ...`. Once `sudo` switches to the unprivileged user, the process no longer has `CAP_SETPCAP`; the `setpriv --ambient-caps` call silently fails. Result: launched QEMU lacks `CAP_NET_ADMIN` → TAP setup fails → all cuttlefish boots abort.
- Evidence: Hetzner logs (`cfctl-run.log`) show TAP failures; `/proc/<pid>/status` for the guest process has `CapAmb: 0`. Running `sudo -u justin setpriv --ambient-caps=+net_admin true` locally reproduces the missing capabilities.

## Tasks
1. **Fix the privilege-drop sequence** so the spawned guest retains `CAP_NET_ADMIN`.
   - Replace the current `sudo … setpriv` chain with a direct `setpriv` invocation from the root daemon. Construct the full command with `--reuid=<guest_uid> --regid=<guest_primary_gid> --groups=<supplementals> --ambient-caps=<caps>` followed by the FHS wrapper (`cuttlefish_fhs -- launch_cvd …`).
   - Preserve configurability: pull `guest_user`, `guest_primary_group`, `guest_capabilities`, and `guest_supplementary_groups` from `CfctlDaemonConfig`. Default to `justin`, `cvdnetwork`, `["+net_admin"]`, and `["cvdnetwork","kvm"]` respectively, but allow overrides via CLI flags / config file.
   - Ensure env propagation mirrors the existing behavior: either export the known vars (`CUTTLEFISH_*`, `GFXSTREAM_*`) before exec or use `setpriv --env=NAME` if convenient.
2. **Expose config defaults** to maintain new behavior: `guest_user`, `guest_primary_group`, `guest_capabilities`. After the fix, these should still be configurable via the CLI/Daemon config.
3. **Update logging/tests**: adjust `spawn_guest_process` logs to reflect the new execution command; make sure unit/integration tests compile (e.g., `cargo check`). If we have automated tests verifying capability parsing, add/adjust them.
4. **Local verification** (macOS workspace): build cfctl (`cargo build --release`); ensure unit tests pass.
5. **Remote verification plan** (document steps in notes file, but do not execute here unless explicitly asked):
   - Deploy new binary to Hetzner (existing workflow: push branch, update `~/configs/flake.nix`, run `just hetzner`).
   - On Hetzner: create & start a baseline instance (`cfctl instance create-start --purpose baseline --verify-boot true`).
   - Confirm `CapAmb` in the guest process includes `0000000002000000` (CAP_NET_ADMIN) and that QEMU no longer errors on `/dev/net/tun`.
   - Record console logs, `cfctl-run.log`, and confirm `[cf-heartbeat]` outputs if using heartbeat init.
6. **Documentation**: update `notes/experiment-6-baseline.md` or new entry summarizing the regression and fix.

## Deliverables
- Updated Rust sources under `cuttlefish/cfctl/src` with corrected privilege-dropping logic, retaining configurable user/group/caps.
- Relevant tests/build scripts pass locally (`cargo check`, etc.).
- Summary of validation steps & evidence on Hetzner (to be executed later).

Keep edits minimal but robust—don’t reintroduce the old hard-coded user/groups, but ensure capability management works for the default config. When ready, summarize changes and point to the logs/commands used to verify locally.
