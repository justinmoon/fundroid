# cfctl Usage Notes

The `cfctl` CLI talks to the daemon running on the Hetzner host. Recent changes added a few flags that CI can rely on so it no longer needs custom wrappers.

## Instance lifecycle

```bash
# create and immediately start a headless guest, waiting up to 180 seconds and
# failing if ADB or the boot marker never appears
cfctl instance create-start --purpose ci --disable-webrtc --verify-boot --timeout-secs 180

# start an existing guest with the same guarantees
cfctl instance start 12 --disable-webrtc --verify-boot --timeout-secs 180

# start an existing guest using a specific track (uses cfenv)
cfctl instance start 12 --track production

# hold an instance to prevent it from being pruned
cfctl instance hold 12

# destroy an instance and wait until cleanup has finished (or timeout)
cfctl instance destroy 12 --timeout-secs 120

# remove everything cfctl knows about, regardless of timestamps
# note: held instances will not be pruned
cfctl instance prune --all
```

### Flags

- `--disable-webrtc` – skip the WebRTC console so headless boots no longer hit the `ControlLoop` error.
- `--skip-adb-wait` – skip waiting for ADB to become ready. The instance starts immediately without ADB verification. Cannot be used with `--verify-boot` (which requires ADB).
- `--verify-boot` – after ADB connects, poll `VIRTUAL_DEVICE_BOOT_COMPLETED`; the command exits non-zero with structured JSON on timeout/guest exit/marker missing.
- `--timeout-secs` – hard ceiling for `start`, `create-start`, `destroy`, `wait-adb`, and `logs`. Commands fail with `error.code` describing the reason when the limit is hit.
- `--track` – specify which cuttlefish track to use when starting an instance. When provided, cfctl uses `cfenv` to launch the guest with the specified track's environment.

## Logs

```bash
# print the run log tail directly to stdout (useful for CI capture)
cfctl logs 12 --stdout --timeout-secs 30
```

When `--stdout` is omitted the CLI emits the usual JSON payload.
