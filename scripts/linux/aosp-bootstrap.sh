#!/usr/bin/env bash
# Bootstrap AOSP source tree and link in webos vendor overlay
# Run this from inside `nix develop .#aosp` on Linux builder

set -euo pipefail

AOSP_DIR="${HOME}/aosp"
WEBOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Bootstrapping AOSP in $AOSP_DIR"
mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR"

if [ ! -d .repo ]; then
    echo "Initializing AOSP repo (android-14.0.0_r1)..."
    repo init -u https://android.googlesource.com/platform/manifest -b android-14.0.0_r1
    echo "Syncing AOSP sources (this will take a while)..."
    repo sync -c -j$(nproc)
else
    echo "AOSP repo already initialized"
fi

echo "Linking webos vendor overlay..."
ln -sf "$WEBOS_DIR/vendor/webos" "$AOSP_DIR/vendor/webos"

echo "AOSP bootstrap complete!"
echo "Next steps:"
echo "  1. source build/envsetup.sh"
echo "  2. lunch webos_cf_x86_64-userdebug"
echo "  3. m -j\$(nproc)"
