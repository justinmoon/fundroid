# WebOS Setup Guide

This guide walks through setting up the Android emulator and deploying the native webosd daemon.

## Step 3: Boot Emulator and Auto-Start Native Daemon

### Prerequisites

Enter the Nix development shell:
```bash
nix develop
```

### 1. Install Android SDK Components

```bash
just emu-install
```

This installs:
- platform-tools (adb)
- emulator
- Android 34 platform
- System image for arm64-v8a (Apple Silicon) or x86_64 (Intel Mac)

### 2. Create AVD (Android Virtual Device)

```bash
just emu-create
```

Creates an AVD named "webosd" using Pixel 6 device profile.

### 3. Boot the Emulator

```bash
just emu-boot
```

Boots the emulator in the background with:
- No snapshot saving
- Host GPU acceleration
- No boot animation (faster startup)

### 4. Root the Emulator

```bash
just emu-root
```

This:
1. Waits for device to be ready
2. Runs `adb root` to gain root access
3. Disables dm-verity (allows system modifications)
4. Reboots
5. Remounts /system as read-write

**Note:** This requires a "default" (non-Play Store) system image.

### 5. Build webosd

Detect your emulator architecture:
```bash
adb shell uname -m
```

Then build for the correct architecture:

For **aarch64** (Apple Silicon Mac):
```bash
just build-webosd-arm64
```

For **x86_64** (Intel Mac):
```bash
just build-webosd-x86
```

### 6. Install the Service

Install webosd daemon and init script:

For **aarch64**:
```bash
just install-service-arm64
```

For **x86_64**:
```bash
just install-service-x86
```

This will:
1. Push the webosd binary to /system/bin/webosd
2. Make it executable (chmod 0755)
3. Push the init script to /system/etc/init/init.webosd.rc
4. Reboot the device

### 7. Verify

After reboot, check the logs:
```bash
adb logcat -s webosd:*
```

You should see:
```
webosd: hello from init()
```

### Managing the Service

Restart the daemon:
```bash
just restart-webosd
```

This will show the last 50 log lines from webosd.

## Architecture Notes

- **Apple Silicon Macs** should use arm64-v8a system images and build for aarch64-linux-android
- **Intel Macs** should use x86_64 system images and build for x86_64-linux-android

## Troubleshooting

### SELinux Denials

If you see SELinux permission denials, you can temporarily disable enforcement:
```bash
adb shell setenforce 0
```

### Service Not Starting

Check if the service is running:
```bash
adb shell ps -A | grep webosd
```

Check Android init logs:
```bash
adb logcat -b all | grep init
```

### System Not Writable

Make sure you're using a "default" system image (not Google Play variant) and have run `just emu-root` successfully.
