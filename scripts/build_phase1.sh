#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
OUT_DIR="${ROOT}/target/os/phase1"
ROOTFS_DIR="${OUT_DIR}/rootfs"
ABOOT_ROOT="${OUT_DIR}/abootcrafter"
ABOOT="${ABOOT_ROOT}/bin/abootcrafter"
REMOTE_BIN="/data/local/tmp/minios_init_phase1"
INIT_LOCAL="${ROOT}/rust/minios_init/target/aarch64-linux-android/release/minios_init"

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    SERIAL="${ANDROID_SERIAL}"
else
    SERIAL=$(adb devices | awk '$2 == "device" {print $1}' | grep -v '^emulator-' | head -n1)
fi

if [[ -z "${SERIAL}" ]]; then
    echo "No hardware device detected; set ANDROID_SERIAL or disconnect emulators." >&2
    exit 1
fi

ADB=("adb" "-s" "${SERIAL}")

mkdir -p "${OUT_DIR}"

if [[ ! -x "${ABOOT}" ]]; then
    echo "[phase1] installing abootcrafter locally..."
    cargo install --locked --root "${ABOOT_ROOT}" abootcrafter >/dev/null
fi

if [[ ! -f "${OUT_DIR}/boot-stock.img" ]]; then
    echo "[phase1] backing up boot_a partition..."
    "${ADB[@]}" shell 'su -c dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot-stock.img' >/dev/null
    "${ADB[@]}" pull /data/local/tmp/boot-stock.img "${OUT_DIR}/boot-stock.img" >/dev/null
    "${ADB[@]}" shell 'su -c rm /data/local/tmp/boot-stock.img' >/dev/null
fi

if [[ ! -f "${OUT_DIR}/init_boot-stock.img" ]]; then
    echo "[phase1] backing up init_boot_a partition..."
    "${ADB[@]}" shell 'su -c dd if=/dev/block/by-name/init_boot_a of=/data/local/tmp/init_boot-stock.img' >/dev/null
    "${ADB[@]}" pull /data/local/tmp/init_boot-stock.img "${OUT_DIR}/init_boot-stock.img" >/dev/null
    "${ADB[@]}" shell 'su -c rm /data/local/tmp/init_boot-stock.img' >/dev/null
fi

echo "[phase1] building minios_init (aarch64-linux-android)..."
cargo build --manifest-path "${ROOT}/rust/minios_init/Cargo.toml" --target aarch64-linux-android --release >/dev/null

echo "[phase1] discovering dynamic dependencies..."
"${ADB[@]}" push "${INIT_LOCAL}" "${REMOTE_BIN}" >/dev/null
deps_raw="$("${ADB[@]}" shell "/apex/com.android.runtime/bin/linker64 --list ${REMOTE_BIN}")"
"${ADB[@]}" shell "rm ${REMOTE_BIN}" >/dev/null

deps=()
while IFS= read -r line; do
    path="$(echo "${line}" | awk '{print $3}')"
    if [[ "${path}" == "["* ]] || [[ -z "${path}" ]]; then
        continue
    fi
    deps+=("${path}")
done <<<"${deps_raw}"

# Ensure we copy linker64 as the ELF interpreter expects /system/bin/linker64.
deps+=("/apex/com.android.runtime/bin/linker64")

echo "[phase1] unpacking stock ramdisk..."
TMP_EXTRACT="${OUT_DIR}/extract_boot"
# shellcheck disable=SC2034
TMP_EXTRACT="${TMP_EXTRACT}" ROOTFS_DIR="${ROOTFS_DIR}" python3 - <<'PY'
import os
import shutil
for env_key in ('TMP_EXTRACT', 'ROOTFS_DIR'):
    path = os.environ.get(env_key)
    if path and os.path.exists(path):
        shutil.rmtree(path, ignore_errors=True)
PY
mkdir -p "${TMP_EXTRACT}"
"${ABOOT}" extract bootimg \
    --input-boot-file "${OUT_DIR}/boot-stock.img" \
    --output-dir "${TMP_EXTRACT}" >/dev/null
mkdir -p "${ROOTFS_DIR}"
lz4 -d "${TMP_EXTRACT}/ramdisk" "${TMP_EXTRACT}/ramdisk.cpio" >/dev/null
( cd "${ROOTFS_DIR}" && cpio --no-preserve-owner -idm < "${TMP_EXTRACT}/ramdisk.cpio" >/dev/null )
rm -f "${TMP_EXTRACT}/ramdisk.cpio"
chmod -R u+rwX "${ROOTFS_DIR}" >/dev/null 2>&1 || true
ROOTFS="${ROOTFS_DIR}" python3 - <<'PY'
import os
import shutil
root = os.environ.get("ROOTFS")
if not root:
    raise SystemExit
backup = os.path.join(root, ".backup")
if os.path.exists(backup):
    os.chmod(backup, 0o700)
    shutil.rmtree(backup, ignore_errors=True)
PY

# Preserve the stock init for rollback/debug.
if [[ -f "${ROOTFS_DIR}/init" ]]; then
    mv "${ROOTFS_DIR}/init" "${ROOTFS_DIR}/init.stock"
fi

echo "[phase1] staging rootfs..."
if [[ -n "${CUSTOM_INIT:-}" ]]; then
    echo "[phase1] using custom init from ${CUSTOM_INIT}"
    cp "${CUSTOM_INIT}" "${ROOTFS_DIR}/init"
else
    cp "${INIT_LOCAL}" "${ROOTFS_DIR}/init"
fi
chmod 0755 "${ROOTFS_DIR}/init"

mkdir -p "${ROOTFS_DIR}/bin" "${ROOTFS_DIR}/sbin"
shell_candidates=(
    "${ROOTFS_DIR}/system/bin/sh"
    "${ROOTFS_DIR}/apex/com.android.runtime/bin/sh"
    "${ROOTFS_DIR}/system/bin/microsh"
)
for candidate in "${shell_candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
        cp "${candidate}" "${ROOTFS_DIR}/bin/sh"
        chmod 0755 "${ROOTFS_DIR}/bin/sh"
        break
    fi
done
cp "${INIT_LOCAL}" "${ROOTFS_DIR}/sbin/minios_init"
chmod 0755 "${ROOTFS_DIR}/sbin/minios_init"

for dep in "${deps[@]}"; do
    dest="${ROOTFS_DIR}${dep}"
    mkdir -p "$(dirname "${dest}")"
    echo "  pulling ${dep}"
    "${ADB[@]}" pull "${dep}" "${dest}" >/dev/null
done

# The binary expects the interpreter at /system/bin/linker64.
mkdir -p "${ROOTFS_DIR}/system/bin"
cp "${ROOTFS_DIR}/apex/com.android.runtime/bin/linker64" "${ROOTFS_DIR}/system/bin/linker64"

echo "[phase1] generating ramdisk..."
(
    cd "${ROOTFS_DIR}"
    find . -print0 | LC_ALL=C sort -z | cpio --null --create --format=newc >/tmp/phase1_ramdisk.cpio
) >/dev/null
gzip -c /tmp/phase1_ramdisk.cpio >"${OUT_DIR}/phase1_ramdisk.cpio.gz"
rm /tmp/phase1_ramdisk.cpio

echo "[phase1] writing boot image with custom ramdisk..."
cp "${OUT_DIR}/boot-stock.img" "${OUT_DIR}/boot-phase1.img"
"${ABOOT}" update bootimg \
    --input-boot-file "${OUT_DIR}/boot-phase1.img" \
    --ramdisk-file "${OUT_DIR}/phase1_ramdisk.cpio.gz" >/dev/null

echo "[phase1] writing init_boot image with custom ramdisk..."
cp "${OUT_DIR}/init_boot-stock.img" "${OUT_DIR}/init_boot-phase1.img"
"${ABOOT}" update bootimg \
    --input-boot-file "${OUT_DIR}/init_boot-phase1.img" \
    --ramdisk-file "${OUT_DIR}/phase1_ramdisk.cpio.gz" >/dev/null

cat <<EOF

Phase 1 artifacts:
  Ramdisk : ${OUT_DIR}/phase1_ramdisk.cpio.gz
  Boot img: ${OUT_DIR}/boot-phase1.img
  InitBoot: ${OUT_DIR}/init_boot-phase1.img

To test (non-destructive):
  adb reboot bootloader
  fastboot -s ${SERIAL} boot ${OUT_DIR}/boot-phase1.img

To flash first-stage ramdisk (remember to restore init_boot-stock.img afterwards!):
  fastboot -s ${SERIAL} flash init_boot ${OUT_DIR}/init_boot-phase1.img

EOF
