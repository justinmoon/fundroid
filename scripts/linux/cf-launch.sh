#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
AOSP_ROOT="${AOSP_ROOT:-${PROJECT_ROOT}/out/aosp}"
PRODUCT_NAME="${AOSP_PRODUCT_NAME:-webos_cf_x86_64}"
HOST_ARCH="${HOST_ARCH:-linux-x86}"

OUT_DIR="${AOSP_ROOT}/out"
PRODUCT_OUT="${OUT_DIR}/target/product/vsoc_x86_64"
HOST_OUT="${OUT_DIR}/host/${HOST_ARCH}"

LAUNCH_CVD="${CF_LAUNCH_CVD:-${HOST_OUT}/bin/launch_cvd}"
STOP_CVD="${HOST_OUT}/bin/stop_cvd"

if [ ! -x "${LAUNCH_CVD}" ]; then
  echo "error: launch_cvd not found at ${LAUNCH_CVD}. Build the host tools with 'm host-linux-x86-cvd' first." >&2
  exit 1
fi

export ANDROID_PRODUCT_OUT="${PRODUCT_OUT}"
export ANDROID_HOST_OUT="${HOST_OUT}"

if [ -x "${STOP_CVD}" ]; then
  "${STOP_CVD}" || true
fi

SYSTEM_IMG="${PRODUCT_OUT}/system.img"
VENDOR_IMG="${PRODUCT_OUT}/vendor.img"
BOOT_IMG="${PRODUCT_OUT}/boot.img"
KERNEL_IMG="${PRODUCT_OUT}/kernel"
INITRD_IMG="${PRODUCT_OUT}/ramdisk.img"

for img in "${SYSTEM_IMG}" "${VENDOR_IMG}" "${BOOT_IMG}" "${KERNEL_IMG}" "${INITRD_IMG}"; do
  if [ ! -f "${img}" ]; then
    echo "error: expected image not found: ${img}" >&2
    exit 1
  fi
done

exec "${LAUNCH_CVD}" \
  --daemon \
  --system_image="${SYSTEM_IMG}" \
  --vendor_image="${VENDOR_IMG}" \
  --boot_image="${BOOT_IMG}" \
  --kernel="${KERNEL_IMG}" \
  --initrd="${INITRD_IMG}" \
  --enable_webrtc
