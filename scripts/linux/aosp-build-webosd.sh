#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AOSP_ROOT="${AOSP_ROOT:-${PROJECT_ROOT}/out/aosp}"
LUNCH_COMBO="${AOSP_LUNCH_COMBO:-webos_cf_x86_64-userdebug}"
BUILD_TARGET="${AOSP_BUILD_TARGET:-webosd}"

if [ ! -d "${AOSP_ROOT}" ]; then
  echo "error: AOSP tree not found at ${AOSP_ROOT}. Run scripts/linux/aosp-bootstrap.sh first." >&2
  exit 1
fi

cd "${AOSP_ROOT}"

if [ ! -f build/envsetup.sh ]; then
  echo "error: build/envsetup.sh missing. Is this an AOSP checkout?" >&2
  exit 1
fi

source build/envsetup.sh
lunch "${LUNCH_COMBO}"
m "${BUILD_TARGET}"
