#!/usr/bin/env bash
# Build AOSP with a specific agent's overlay
# Usage: ./scripts/linux/aosp-build-with-overlay.sh <agent-name>

set -euo pipefail

AGENT_NAME="${1:-}"
if [ -z "$AGENT_NAME" ]; then
    echo "Usage: $0 <agent-name>"
    echo "Example: $0 project-init-step-codex"
    exit 1
fi

AOSP_ROOT="${AOSP_ROOT:-${HOME}/aosp}"
OVERLAY_SOURCE="${HOME}/remote-overlays/${AGENT_NAME}"
OUT_DIR="${AOSP_ROOT}/out/${AGENT_NAME}"

if [ ! -d "$AOSP_ROOT" ]; then
    echo "Error: AOSP_ROOT not found: $AOSP_ROOT"
    echo "Run: just aosp-bootstrap first"
    exit 1
fi

if [ ! -d "$OVERLAY_SOURCE" ]; then
    echo "Error: Overlay not found: $OVERLAY_SOURCE"
    echo "Run: just remote-sync $AGENT_NAME first (from Mac)"
    exit 1
fi

echo "🔧 Building AOSP for agent: ${AGENT_NAME}"
echo "   AOSP:    ${AOSP_ROOT}"
echo "   Overlay: ${OVERLAY_SOURCE}"
echo "   Out:     ${OUT_DIR}"
echo ""

cd "$AOSP_ROOT"

# Copy overlay into AOSP tree
echo "📦 Copying overlay..."
rsync -a --delete "${OVERLAY_SOURCE}/vendor/webos/" "${AOSP_ROOT}/vendor/webos/"

# Set up build environment (temporarily disable strict mode for envsetup.sh)
set +u
source build/envsetup.sh
set -u
lunch webos_cf_x86_64-userdebug

# Build with isolated output directory
export OUT_DIR="${OUT_DIR}"
export DIST_DIR="${OUT_DIR}/dist"

echo ""
echo "🏗️  Building (this will take 30-60 minutes)..."
m -j$(nproc)

echo ""
echo "✅ Build complete!"
echo "   Output: ${OUT_DIR}"
echo ""
echo "Next steps:"
echo "  Launch Cuttlefish: ./scripts/linux/cf-launch.sh ${AGENT_NAME}"
