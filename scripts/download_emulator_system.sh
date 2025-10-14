#!/usr/bin/env bash
set -euo pipefail

API_LEVEL=34
CHANNEL='default'
ABI="${ANDROID_ABI:-arm64-v8a}"
WORKDIR=""
KEEP_TEMP=1
SYNC_TO_CAPSULE=1

usage() {
	cat <<'EOF'
Usage: download_emulator_system.sh [options]

Fetches the Android emulator system image via sdkmanager, converts the sparse
system.img to a raw ext4 image, and extracts the filesystem into a temporary
directory for inspection.

Options:
  --abi <abi>          ABI/system image flavor to install (default: arm64-v8a)
  --api-level <level>  Android API level to use (default: 34)
  --channel <name>     System image channel (default: default)
  --workdir <path>     Use an existing empty directory instead of mktemp
  --no-keep            Remove the temporary directory on success
  --no-sync            Skip copying artifacts into android/capsule/system
  -h, --help           Show this message

Environment:
  ANDROID_SDK_ROOT     Must point at the Android SDK installation.
  PYTHON               Optional override for python3 interpreter.

The script prints the extraction directory path on stdout so you can inspect it
manually (e.g. `ls <path>`).
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--abi)
			shift
			[[ $# -gt 0 ]] || { echo "--abi requires an argument" >&2; exit 1; }
			ABI="$1"
			;;
		--api-level)
			shift
			[[ $# -gt 0 ]] || { echo "--api-level requires an argument" >&2; exit 1; }
			API_LEVEL="$1"
			;;
		--channel)
			shift
			[[ $# -gt 0 ]] || { echo "--channel requires an argument" >&2; exit 1; }
			CHANNEL="$1"
			;;
		--workdir)
			shift
			[[ $# -gt 0 ]] || { echo "--workdir requires an argument" >&2; exit 1; }
			WORKDIR="$1"
			;;
		--no-keep)
			KEEP_TEMP=0
			;;
		--no-sync)
			SYNC_TO_CAPSULE=0
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option '$1'" >&2
			usage
			exit 1
			;;
	esac
	shift
done

if [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
	echo "ANDROID_SDK_ROOT must be set (enter the dev shell via 'nix develop')." >&2
	exit 1
fi

if [[ -n "$WORKDIR" ]]; then
	if [[ -e "$WORKDIR" ]]; then
		if [[ ! -d "$WORKDIR" ]]; then
			echo "Specified --workdir '$WORKDIR' exists but is not a directory." >&2
			exit 1
		fi
		if [[ -n "$(ls -A "$WORKDIR" 2>/dev/null)" ]]; then
			echo "Specified --workdir '$WORKDIR' must be empty." >&2
			exit 1
		fi
	else
		mkdir -p "$WORKDIR"
	fi
else
	WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/capsule-system-XXXXXX")"
fi

cleanup() {
	if [[ $KEEP_TEMP -eq 0 ]]; then
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT

ensure_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

resolve_sdkmanager() {
	if ensure_cmd sdkmanager; then
		command -v sdkmanager
		return
	fi
	local candidates=(
		"$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
		"$ANDROID_SDK_ROOT/cmdline-tools/bin/sdkmanager"
		"$ANDROID_SDK_ROOT/tools/bin/sdkmanager"
	)
	for path in "${candidates[@]}"; do
		if [[ -x "$path" ]]; then
			printf '%s\n' "$path"
			return
		fi
	done
	echo "Unable to locate sdkmanager in PATH or under \$ANDROID_SDK_ROOT." >&2
	exit 1
}

resolve_simg2img() {
	if ensure_cmd simg2img; then
		command -v simg2img
		return
	fi
	local candidates=(
		"$ANDROID_SDK_ROOT/emulator/simg2img"
		"$ANDROID_SDK_ROOT/emulator/bin64/simg2img"
		"$ANDROID_SDK_ROOT/emulator/lib64/simg2img"
		"$ANDROID_SDK_ROOT/platform-tools/simg2img"
	)
	for path in "${candidates[@]}"; do
		if [[ -x "$path" ]]; then
			printf '%s\n' "$path"
			return
		fi
	done
	echo "Unable to locate simg2img; ensure the emulator component is installed." >&2
	exit 1
}

PYTHON_BIN="${PYTHON:-python3}"
if ! ensure_cmd "$PYTHON_BIN"; then
	echo "python3 not found (set \$PYTHON to override)." >&2
	exit 1
fi

if ! ensure_cmd debugfs; then
	echo "debugfs not found; install e2fsprogs (enter the Nix dev shell) to continue." >&2
	exit 1
fi

if ! ensure_cmd lpunpack; then
	echo "lpunpack not found; install android-tools (enter the Nix dev shell) to continue." >&2
	exit 1
fi

if ! ensure_cmd fakeroot; then
	echo "fakeroot not found; install fakeroot (enter the Nix dev shell) to continue." >&2
	exit 1
fi

SDKMANAGER_BIN="$(resolve_sdkmanager)"
SIMG2IMG_BIN="$(resolve_simg2img)"

IMAGE_SPEC="system-images;android-${API_LEVEL};${CHANNEL};${ABI}"
echo "Ensuring system image ${IMAGE_SPEC} is installed..." >&2
yes | "$SDKMANAGER_BIN" --sdk_root="$ANDROID_SDK_ROOT" --install "$IMAGE_SPEC" >/dev/null || true

SYSTEM_IMG="${ANDROID_SDK_ROOT}/system-images/android-${API_LEVEL}/${CHANNEL}/${ABI}/system.img"
if [[ ! -f "$SYSTEM_IMG" ]]; then
	echo "Expected system image not found at ${SYSTEM_IMG}" >&2
	exit 1
fi

RAW_IMG="${WORKDIR}/system_raw.img"
magic="$(od -An -tx4 -N4 "$SYSTEM_IMG" 2>/dev/null | tr -d '[:space:]')"
if [[ "$magic" == "ed26ff3a" ]]; then
	echo "Converting sparse system image to ${RAW_IMG}..." >&2
	"$SIMG2IMG_BIN" "$SYSTEM_IMG" "$RAW_IMG"
else
	echo "System image is not sparse (magic=${magic:-unknown}); copying as-is to ${RAW_IMG}..." >&2
	cp "$SYSTEM_IMG" "$RAW_IMG"
fi

SUPER_IMG="${WORKDIR}/super.img"
PARTS_DIR="${WORKDIR}/super_parts"
EXTRACT_DIR="${WORKDIR}/system_root"
mkdir -p "$PARTS_DIR" "$EXTRACT_DIR"

export RAW_IMAGE_PATH="$RAW_IMG"
readarray -t gpt_info < <("$PYTHON_BIN" - <<'PY'
import os
import struct
import sys

SECTOR_SIZE = 512
image_path = os.environ["RAW_IMAGE_PATH"]
target_name = "super"

with open(image_path, "rb") as fh:
    fh.seek(SECTOR_SIZE)
    header = fh.read(92)
    if header[:8] != b"EFI PART":
        raise SystemExit("system image does not contain a GPT header")
    part_entry_lba = struct.unpack_from("<Q", header, 72)[0]
    num_entries = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    fh.seek(part_entry_lba * SECTOR_SIZE)
    for idx in range(num_entries):
        entry = fh.read(entry_size)
        if entry == b"\x00" * entry_size:
            continue
        first_lba = struct.unpack_from("<Q", entry, 32)[0]
        last_lba = struct.unpack_from("<Q", entry, 40)[0]
        name = entry[56:56+72].decode("utf-16-le").rstrip("\x00")
        if name == target_name:
            size_lba = last_lba - first_lba + 1
            print(first_lba)
            print(size_lba)
            break
    else:
        raise SystemExit("unable to locate 'super' partition in system image")
PY
)

if [[ ${#gpt_info[@]} -ne 2 ]]; then
	echo "Failed to parse GPT metadata from system image." >&2
	exit 1
fi

super_start_lba="${gpt_info[0]}"
super_size_lba="${gpt_info[1]}"
unset RAW_IMAGE_PATH
echo "Extracting super partition (start=${super_start_lba} size=${super_size_lba} sectors)..." >&2
dd if="$RAW_IMG" of="$SUPER_IMG" bs=512 skip="$super_start_lba" count="$super_size_lba" status=none

echo "Unpacking dynamic partitions into ${PARTS_DIR}..." >&2
lpunpack "$SUPER_IMG" "$PARTS_DIR" >/dev/null

declare -A PARTITION_MAP=(
	["system"]="system"
	["system_ext"]="system_ext"
	["product"]="product"
	["vendor"]="vendor"
)

for part in "${!PARTITION_MAP[@]}"; do
	part_img="${PARTS_DIR}/${part}.img"
	if [[ -f "$part_img" ]]; then
		dest="${EXTRACT_DIR}/${PARTITION_MAP[$part]}"
		mkdir -p "$dest"
		echo "Extracting ${part}.img into ${dest}..." >&2
		fakeroot -- debugfs -R "rdump / $dest" "$part_img" >/dev/null
	else
		echo "Warning: dynamic partition ${part}.img not found (skipping)..." >&2
	fi
done

if [[ -d "${EXTRACT_DIR}/system/system" ]]; then
	echo "Flattening system partition layout..." >&2
	tmp_dir="${EXTRACT_DIR}/.system_tmp"
	rm -rf "$tmp_dir"
	mv "${EXTRACT_DIR}/system/system" "$tmp_dir"
	rm -rf "${EXTRACT_DIR}/system"
	mv "$tmp_dir" "${EXTRACT_DIR}/system"
fi

if [[ ! -f "${EXTRACT_DIR}/system/bin/servicemanager" ]]; then
	echo "Extraction appears incomplete; servicemanager not found under ${EXTRACT_DIR}/system/bin." >&2
	exit 1
fi

if [[ $SYNC_TO_CAPSULE -ne 0 ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
	CAPSULE_DIR="${REPO_ROOT}/android/capsule"
	CAPSULE_SYSTEM_DIR="${CAPSULE_DIR}/system"
	MANIFEST_PATH="${CAPSULE_DIR}/manifest.toml"
	mkdir -p "$CAPSULE_DIR"
	if [[ -z "$CAPSULE_SYSTEM_DIR" || "$CAPSULE_SYSTEM_DIR" == "/" ]]; then
		echo "Refusing to remove suspicious capsule system directory: '$CAPSULE_SYSTEM_DIR'" >&2
		exit 1
	fi
	rm -rf "$CAPSULE_SYSTEM_DIR"
	mkdir -p "$CAPSULE_SYSTEM_DIR"
	echo "Syncing core Android services into ${CAPSULE_SYSTEM_DIR}..." >&2
	"$PYTHON_BIN" "$SCRIPT_DIR/_capsule_sync.py" "$EXTRACT_DIR" "$CAPSULE_SYSTEM_DIR" "$MANIFEST_PATH"
	echo "Capsule artifacts staged under: $CAPSULE_SYSTEM_DIR" >&2
	echo "Manifest written to: $MANIFEST_PATH" >&2
fi

echo "System image contents available at: $EXTRACT_DIR"
echo "Raw ext4 image saved at: $RAW_IMG" >&2
if [[ $KEEP_TEMP -ne 0 ]]; then
	echo "Temporary workspace preserved in: $WORKDIR" >&2
else
	echo "Temporary workspace removed." >&2
fi
