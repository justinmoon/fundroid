#!/usr/bin/env bash
# Full rebuild of AOSP image when init.rc or system-level changes are made
# Run this from AOSP root after sourcing build/envsetup.sh and lunch

set -euo pipefail

if [ -z "${ANDROID_BUILD_TOP:-}" ]; then
    echo "Error: ANDROID_BUILD_TOP not set. Did you source build/envsetup.sh?"
    exit 1
fi

cd "$ANDROID_BUILD_TOP"

echo "Rebuilding full AOSP image..."
echo "This may take 15-30 minutes depending on changes..."
m -j$(nproc)

echo "Build complete!"
echo ""
echo "To deploy:"
echo "  stop_cvd                    # Stop current instance"
echo "  launch_cvd --daemon         # Launch with new image"
echo "  adb wait-for-device && adb root"
