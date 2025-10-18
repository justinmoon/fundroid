#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
OUT_DIR="${ROOT}/target/os/phase1"
ROOTFS_DIR="${OUT_DIR}/rootfs"
ABOOT_ROOT="${OUT_DIR}/abootcrafter"
ABOOT="${ABOOT_ROOT}/bin/abootcrafter"
REMOTE_BIN="/data/local/tmp/minios_init_phase1"
TARGET_TRIPLE=""
AVB_KEY="${OUT_DIR}/testkey_rsa4096.pem"
AVBTOOL="$(command -v avbtool || true)"

ensure_avb_key() {
    if [[ -f "${AVB_KEY}" ]]; then
        return
    fi
    echo "[phase1] fetching AVB test key..."
    python3 - "$AVB_KEY" <<'PY'
import base64
import pathlib
import sys
import urllib.request

url = "https://android.googlesource.com/platform/external/avb/+/refs/heads/main/test/data/testkey_rsa4096.pem?format=TEXT"
target = pathlib.Path(sys.argv[1])
with urllib.request.urlopen(url, timeout=30) as response:
    data = response.read()
target.write_bytes(base64.b64decode(data))
PY
    chmod 600 "${AVB_KEY}"
}

sign_with_avb() {
    local image="$1"
    local partition_name="$2"
    local partition_size="$3"
    ensure_avb_key
    if [[ -z "${AVBTOOL}" ]]; then
        echo "[phase1] avbtool not found; install android-tools in the develop shell." >&2
        exit 1
    fi
    "${AVBTOOL}" erase_footer --image "${image}" >/dev/null 2>&1 || true
    "${AVBTOOL}" add_hash_footer \
        --image "${image}" \
        --partition_name "${partition_name}" \
        --partition_size "${partition_size}" \
        --algorithm SHA256_RSA4096 \
        --key "${AVB_KEY}" >/dev/null
}


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

echo "[phase1] waiting for device ${SERIAL}..."
"${ADB[@]}" wait-for-device >/dev/null
"${ADB[@]}" root >/dev/null 2>&1 || true
"${ADB[@]}" wait-for-device >/dev/null

adb_shell_root() {
    local cmd="$1"
    if ! "${ADB[@]}" shell "${cmd}" >/dev/null 2>&1; then
        "${ADB[@]}" shell "su -c '${cmd}'" >/dev/null
    fi
}

device_arch=$("${ADB[@]}" shell uname -m | tr -d '\r')
case "${device_arch}" in
    aarch64|arm64)
        TARGET_TRIPLE="aarch64-linux-android"
        ;;
    x86_64)
        TARGET_TRIPLE="x86_64-linux-android"
        ;;
    *)
        echo "Unsupported device architecture '${device_arch}'" >&2
        exit 1
        ;;
esac

INIT_LOCAL="${ROOT}/rust/minios_init/target/${TARGET_TRIPLE}/release/minios_init"

if [[ ! -x "${ABOOT}" ]]; then
    echo "[phase1] installing abootcrafter locally..."
    cargo install --locked --root "${ABOOT_ROOT}" abootcrafter >/dev/null
fi

if [[ ! -f "${OUT_DIR}/boot-stock.img" ]]; then
    echo "[phase1] backing up boot_a partition..."
    adb_shell_root "dd if=/dev/block/by-name/boot_a of=/data/local/tmp/boot-stock.img"
    "${ADB[@]}" pull /data/local/tmp/boot-stock.img "${OUT_DIR}/boot-stock.img" >/dev/null
    adb_shell_root "rm /data/local/tmp/boot-stock.img"
fi

if [[ ! -f "${OUT_DIR}/init_boot-stock.img" ]]; then
    echo "[phase1] backing up init_boot_a partition..."
    adb_shell_root "dd if=/dev/block/by-name/init_boot_a of=/data/local/tmp/init_boot-stock.img"
    "${ADB[@]}" pull /data/local/tmp/init_boot-stock.img "${OUT_DIR}/init_boot-stock.img" >/dev/null
    adb_shell_root "rm /data/local/tmp/init_boot-stock.img"
fi

BOOT_PARTITION_SIZE="$(python3 - <<PY
import os
print(os.path.getsize(r"""${OUT_DIR}/boot-stock.img"""))
PY
)"
INIT_BOOT_PARTITION_SIZE="$(python3 - <<PY
import os
print(os.path.getsize(r"""${OUT_DIR}/init_boot-stock.img"""))
PY
)"

echo "[phase1] building minios_init (${TARGET_TRIPLE})..."
cargo build --manifest-path "${ROOT}/rust/minios_init/Cargo.toml" --target "${TARGET_TRIPLE}" --release >/dev/null

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
OUT_DIR="${OUT_DIR}" ROOTFS_DIR="${ROOTFS_DIR}" python3 - <<'PY'
import os
import shutil
for path in [
    os.environ.get("ROOTFS_DIR"),
    os.path.join(os.environ.get("OUT_DIR"), "extract_boot"),
    os.path.join(os.environ.get("OUT_DIR"), "extract_init_boot"),
]:
    if path and os.path.exists(path):
        shutil.rmtree(path, ignore_errors=True)
PY

extract_tmp="${OUT_DIR}/extract_boot"
mkdir -p "${ROOTFS_DIR}"
mkdir -p "${extract_tmp}"

extract_ramdisk_from() {
    local image="$1"
    local tmp_dir="$2"
    rm -rf "${tmp_dir}"
    mkdir -p "${tmp_dir}"
    "${ABOOT}" extract bootimg --input-boot-file "${image}" --output-dir "${tmp_dir}" >/dev/null

    local ramdisk_cpio=""
    if [[ -f "${tmp_dir}/ramdisk" ]]; then
        lz4 -d "${tmp_dir}/ramdisk" "${tmp_dir}/ramdisk.cpio" >/dev/null
        ramdisk_cpio="${tmp_dir}/ramdisk.cpio"
    elif [[ -f "${tmp_dir}/ramdisk.lz4" ]]; then
        lz4 -d "${tmp_dir}/ramdisk.lz4" "${tmp_dir}/ramdisk.cpio" >/dev/null
        ramdisk_cpio="${tmp_dir}/ramdisk.cpio"
    elif [[ -f "${tmp_dir}/ramdisk.gz" ]]; then
        gzip -dc "${tmp_dir}/ramdisk.gz" > "${tmp_dir}/ramdisk.cpio"
        ramdisk_cpio="${tmp_dir}/ramdisk.cpio"
    elif [[ -f "${tmp_dir}/ramdisk.cpio.gz" ]]; then
        gzip -dc "${tmp_dir}/ramdisk.cpio.gz" > "${tmp_dir}/ramdisk.cpio"
        ramdisk_cpio="${tmp_dir}/ramdisk.cpio"
    elif [[ -f "${tmp_dir}/ramdisk.cpio" ]]; then
        ramdisk_cpio="${tmp_dir}/ramdisk.cpio"
    else
        return 1
    fi

if ! ( cd "${ROOTFS_DIR}" && cpio --no-preserve-owner -idm < "${ramdisk_cpio}" >/dev/null ); then
    echo "[phase1] warning: cpio reported errors (likely device nodes); continuing" >&2
fi
    rm -f "${ramdisk_cpio}"
    return 0
}

if ! extract_ramdisk_from "${OUT_DIR}/boot-stock.img" "${extract_tmp}"; then
    echo "[phase1] boot image has no ramdisk; using init_boot" >&2
    extract_tmp="${OUT_DIR}/extract_init_boot"
    if ! extract_ramdisk_from "${OUT_DIR}/init_boot-stock.img" "${extract_tmp}"; then
        echo "Failed to extract ramdisk from boot or init_boot" >&2
        exit 1
    fi
fi
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

echo "[phase1] pulling dependencies bundle..."
dep_list="${OUT_DIR}/dep-list.txt"
rm -f "${dep_list}"
printf '%s\n' "${deps[@]}" > "${dep_list}"
remote_dep_list="/data/local/tmp/minios_dep_list"
"${ADB[@]}" push "${dep_list}" "${remote_dep_list}" >/dev/null
rm -f "${dep_list}"
deps_tar="${OUT_DIR}/deps.tar"
"${ADB[@]}" exec-out "tar -cf - --files-from ${remote_dep_list} 2>/dev/null" > "${deps_tar}"
"${ADB[@]}" shell "rm ${remote_dep_list}" >/dev/null
tar -xf "${deps_tar}" -C "${ROOTFS_DIR}"
rm -f "${deps_tar}"

# The binary expects the interpreter at /system/bin/linker64 (ensure present after tar extraction).
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

echo "[phase1] signing images with AVB..."
sign_with_avb "${OUT_DIR}/boot-phase1.img" "boot" "${BOOT_PARTITION_SIZE}"
sign_with_avb "${OUT_DIR}/init_boot-phase1.img" "init_boot" "${INIT_BOOT_PARTITION_SIZE}"

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
