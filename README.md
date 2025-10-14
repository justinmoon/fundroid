# boom

## Quick Start

Enter the Nix development shell:
```bash
nix develop
```

Create and boot the emulator:
```bash
just emu-create
just emu-boot
just emu-root  # Enables root access, disables dm-verity, and remounts /system
```

Deploy the webosd daemon (auto-detects architecture):
```bash
just deploy-webosd
```

Check logs:
```bash
just logs-webosd
# Or use adb directly:
adb logcat -s webosd:*
```

### Emulator bootstrap notes

- Always run `just emu-root` on a fresh or reset AVD before pushing binaries. It issues `adb disable-verity` followed by `adb remount`, which requires a reboot but unlocks `/system` for writes.
- If you wipe emulator data or recreate the device, `adb disable-verity` resets and you must run `just emu-root` again.

### Kernel requirements

Binder capsule work needs the emulator kernel to expose:
- `CONFIG_ANDROID_BINDERFS`
- `CONFIG_USER_NS`
- `CONFIG_PID_NS`

With the emulator running, verify these options by executing:

```bash
scripts/check_kernel_features.sh
```

## Architecture

- **Apple Silicon**: Use arm64-v8a system images, builds for aarch64-linux-android
- **Intel**: Use x86_64 system images, builds for x86_64-linux-android

Auto-detection is built into `just deploy-webosd` and `just install-service`.

## Available Commands

Run `just` to see all available commands.
