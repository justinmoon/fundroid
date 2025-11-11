# Cuttlefish on Hetzner

## Remote Host
- All CI/emulator runs occur on the Hetzner NixOS server reachable as `ssh hetzner`.
- Stock images live under `/var/lib/cuttlefish/images`; the systemd unit `cuttlefish@<id>` uses them unless a custom deploy overrides an image via `cfctl`.

## Stock Boot Sanity Check
```sh
cfctl instance create-start --purpose ci --verify-boot --disable-webrtc
cfctl instance destroy <id>
```
- Expect `VIRTUAL_DEVICE_BOOT_COMPLETED` in the journal within ~30 s and `adb get-state` ⇒ `device`.
- Use this before flashing custom `init_boot` images to prove the host is healthy.

## Image Inventory (`/var/lib/cuttlefish/images`)

| File | Role |
| --- | --- |
| `boot.img` | Linux kernel + default ramdisk used when no custom `init_boot` is supplied. |
| `init_boot.img` | First-stage init ramdisk (Android 13+). Replacing this is how we test our minimal init. |
| `vendor_boot.img` | Vendor additions to the first stage (modules, extra ramdisk bits). |
| `super.img` | Dynamic super partition aggregating `system`, `product`, `vendor`, etc. |
| `system.img` | Read-only system partition contents. |
| `userdata.img` | Writable data partition used by the emulator guest. |
| `vbmeta*.img` | AVB metadata that signs the various boot partitions. |
| `aosp_cf_x86_64_only_phone-img-*.zip` | Upstream archive from Google; unpacked into the images above. |

## Handy Commands
- `just heartbeat` — wraps `scripts/test-heartbeat.sh`, repacks the current PID1, boots an instance, and saves logs under `logs/`.
- `cfctl instance create/start/wait-adb/destroy` — manual lifecycle entry points when debugging or running multiple guests.
- `CUTTLEFISH_REMOTE_HOST=hetzner ./scripts/cuttlefish_instance.sh status` — inspect shared instance state.
- `CI_SKIP_STOCK_SMOKE=1 just ci` — run formatting/tests locally without hitting Hetzner.

See `docs/plans/cf-pid1-logging.md` before attempting new PID1 experiments; it calls out the current acceptance tests and how to capture console output reliably.

## Per-Agent cfctl stacks
- Run `scripts/cfctl-agent.sh <agent>` (for example `alfa`) to start a private daemon bound to `~/.cache/cfctl-<agent>/cfctl.sock` plus isolated state/instances/assembly directories under the same prefix. Pass `--binary /path/to/cfctl-daemon` if you want to skip `cargo run`.
- The launcher writes the resolved paths to `~/.cache/cfctl-<agent>/env`. You can also export them directly via `eval "$(scripts/agent-env.sh <agent>)"` which sets `CFCTL_SOCKET`, `CFCTL_STATE_DIR`, `CFCTL_ETC_DIR`, `CFCTL_CUTTLEFISH_INSTANCES_DIR`, and `CFCTL_CUTTLEFISH_ASSEMBLY_DIR`.
- To run `just heartbeat` (or `scripts/test-heartbeat.sh`) against your per-agent daemon, export the env and set `CUTTLEFISH_REMOTE_HOST=local` so the harness skips SSH:  
  ```sh
  eval "$(scripts/agent-env.sh alfa)"
  CUTTLEFISH_REMOTE_HOST=local nix develop -c just heartbeat
  ```  
  Any CFCTL_* already in the environment will be honored by the script in local mode.
- Everything lives under `~/.cache/cfctl-<agent>/`; delete that directory to reclaim space once you are done with a throwaway stack.
