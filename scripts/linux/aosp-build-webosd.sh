#!/usr/bin/env bash
# Build just the webosd binary (fast iteration)
# Run this from AOSP root after sourcing build/envsetup.sh and lunch

set -euo pipefail

if [ -z "${ANDROID_BUILD_TOP:-}" ]; then
    echo "Error: ANDROID_BUILD_TOP not set. Did you source build/envsetup.sh?"
    exit 1
fi

cd "$ANDROID_BUILD_TOP"

echo "Building webosd binary..."
m webosd

echo "webosd built successfully!"
echo "Binary location: out/target/product/vsoc_x86_64/system/bin/webosd"
echo ""
echo "To push to running device:"
echo "  adb root && adb remount"
echo "  adb push out/target/product/vsoc_x86_64/system/bin/webosd /system/bin/"
echo "  adb shell stop webosd; adb shell start webosd"
