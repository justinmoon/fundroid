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
just emu-root  # Enables root access and system modifications
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

## Architecture

- **Apple Silicon**: Use arm64-v8a system images, builds for aarch64-linux-android
- **Intel**: Use x86_64 system images, builds for x86_64-linux-android

Auto-detection is built into `just deploy-webosd` and `just install-service`.

## Available Commands

Run `just` to see all available commands.
