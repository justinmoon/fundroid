#!/usr/bin/env bash
# Launch Cuttlefish with the built AOSP image
# Run this from AOSP root after building

set -euo pipefail

if [ -z "${ANDROID_BUILD_TOP:-}" ]; then
    echo "Error: ANDROID_BUILD_TOP not set. Did you source build/envsetup.sh?"
    exit 1
fi

cd "$ANDROID_BUILD_TOP"

echo "Launching Cuttlefish..."
launch_cvd --daemon

echo "Waiting for device..."
adb wait-for-device
sleep 2

echo "Setting up root access..."
adb root
sleep 1

echo "Cuttlefish launched successfully!"
echo ""
echo "Useful commands:"
echo "  adb logcat -s webosd:*     # View webosd logs"
echo "  adb shell                   # Shell into device"
echo "  stop_cvd                    # Stop Cuttlefish"
