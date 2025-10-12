#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AOSP_ROOT="${AOSP_ROOT:-${PROJECT_ROOT}/out/aosp}"
LUNCH_COMBO="${AOSP_LUNCH_COMBO:-webos_cf_x86_64-userdebug}"
BUILD_TARGET="${AOSP_BUILD_TARGET:-webosd}"
OVERLAY_SOURCE="${AOSP_OVERLAY_SRC:-${PROJECT_ROOT}/vendor/webos}"
OVERLAY_TARGET="${AOSP_OVERLAY_DST:-${AOSP_ROOT}/vendor/webos}"

if [ ! -d "${AOSP_ROOT}" ]; then
  echo "error: AOSP tree not found at ${AOSP_ROOT}. Run scripts/linux/aosp-bootstrap.sh first." >&2
  exit 1
fi

cd "${AOSP_ROOT}"

if [ ! -f build/envsetup.sh ]; then
  echo "error: build/envsetup.sh missing. Is this an AOSP checkout?" >&2
  exit 1
fi

if [ ! -d "${OVERLAY_SOURCE}" ]; then
  echo "error: overlay source not found at ${OVERLAY_SOURCE}" >&2
  exit 1
fi

echo "Syncing overlay from ${OVERLAY_SOURCE} -> ${OVERLAY_TARGET}" >&2
rsync -a --delete "${OVERLAY_SOURCE}/" "${OVERLAY_TARGET}/"

if [ -n "${AOSP_OUT_SUFFIX:-}" ]; then
  export OUT_DIR="${AOSP_ROOT}/out/${AOSP_OUT_SUFFIX}"
elif [ -n "${AOSP_OUT_DIR:-}" ]; then
  export OUT_DIR="${AOSP_OUT_DIR}"
fi

if [ -n "${OUT_DIR:-}" ]; then
  mkdir -p "${OUT_DIR}"
  export OUT_DIR_COMMON_BASE="$(dirname "${OUT_DIR}")"
fi

source build/envsetup.sh
lunch "${LUNCH_COMBO}"
m "${BUILD_TARGET}"
