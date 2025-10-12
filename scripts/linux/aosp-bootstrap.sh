#!/usr/bin/env bash
set -euo pipefail

if ! command -v repo >/dev/null 2>&1; then
  echo "error: 'repo' command not found. Enter the nix shell (nix develop .#aosp) first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AOSP_ROOT="${AOSP_ROOT:-${PROJECT_ROOT}/out/aosp}"
MANIFEST_URL="${AOSP_MANIFEST_URL:-https://android.googlesource.com/platform/manifest}"
MANIFEST_BRANCH="${AOSP_MANIFEST_BRANCH:-android-14.0.0_r74}"
SYNC_THREADS="${AOSP_SYNC_THREADS:-$(command -v nproc >/dev/null 2>&1 && nproc || echo 8)}"

mkdir -p "${AOSP_ROOT}"
cd "${AOSP_ROOT}"

if [ ! -d .repo ]; then
  repo init -u "${MANIFEST_URL}" -b "${MANIFEST_BRANCH}" --partial-clone --clone-filter=blob:limit=10M
fi

repo sync -c --optimized-fetch --no-tags --prune -j "${SYNC_THREADS}"

OVERLAY_SOURCE="${PROJECT_ROOT}/vendor/webos"
OVERLAY_TARGET="${AOSP_ROOT}/vendor/webos"

mkdir -p "$(dirname "${OVERLAY_TARGET}")"
rsync -a --delete "${OVERLAY_SOURCE}/" "${OVERLAY_TARGET}/"

cat <<EOF
AOSP tree bootstrapped at: ${AOSP_ROOT}
Overlay synced from:       ${OVERLAY_SOURCE}

Next steps:
  1. source build/envsetup.sh
  2. lunch webos_cf_x86_64-userdebug
  3. m -j${SYNC_THREADS} webosd
EOF
