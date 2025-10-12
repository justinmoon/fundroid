#!/usr/bin/env bash
# Launch Cuttlefish with the built AOSP image (per-agent)
# Usage: ./scripts/linux/cf-launch.sh [agent-name]

set -euo pipefail

AGENT_NAME="${1:-default}"
AOSP_ROOT="${AOSP_ROOT:-${HOME}/aosp}"
OUT_DIR="${AOSP_ROOT}/out/${AGENT_NAME}"
INSTANCE_NUM="${CF_INSTANCE_NUM:-1}"

if [ ! -d "$OUT_DIR" ]; then
    echo "Error: Build output not found: $OUT_DIR"
    echo "Run: ./scripts/linux/aosp-build-with-overlay.sh ${AGENT_NAME} first"
    exit 1
fi

cd "$AOSP_ROOT"

echo "🚀 Launching Cuttlefish for agent: ${AGENT_NAME}"
echo "   Instance: ${INSTANCE_NUM}"
echo "   Out dir:  ${OUT_DIR}"

# Stop any existing instance for this agent
"${OUT_DIR}/host/linux-x86/bin/stop_cvd" 2>/dev/null || true

# Launch with agent-specific settings
export ANDROID_PRODUCT_OUT="${OUT_DIR}/target/product/vsoc_x86_64"
export HOME="${OUT_DIR}/cvd-home-${INSTANCE_NUM}"
mkdir -p "$HOME"

"${OUT_DIR}/host/linux-x86/bin/launch_cvd" \
  --daemon \
  --instance_num="${INSTANCE_NUM}" \
  --report_anonymous_usage_stats=n

echo "Waiting for device..."
adb -s "127.0.0.1:$((6520 + INSTANCE_NUM))" wait-for-device
sleep 2

echo "Setting up root access..."
adb -s "127.0.0.1:$((6520 + INSTANCE_NUM))" root
sleep 1

echo ""
echo "✅ Cuttlefish launched!"
echo "   ADB: 127.0.0.1:$((6520 + INSTANCE_NUM))"
echo ""
echo "Useful commands:"
echo "  adb -s 127.0.0.1:$((6520 + INSTANCE_NUM)) logcat -s webosd:*"
echo "  adb -s 127.0.0.1:$((6520 + INSTANCE_NUM)) shell"
echo "  ${OUT_DIR}/host/linux-x86/bin/stop_cvd"
