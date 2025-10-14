#!/usr/bin/env bash
set -euo pipefail

API_LEVEL=34
CHANNEL='default'
ABI="${ANDROID_ABI:-arm64-v8a}"
WORKDIR=""
KEEP_TEMP=1

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
  -h, --help           Show this message

Environment:
  ANDROID_SDK_ROOT     Must point at the Android SDK installation.
  ANDROID_SERIAL       Optional; forwarded to adb invocations if present.

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

if ! ensure_cmd debugfs; then
	echo "debugfs not found; install e2fsprogs (enter the Nix dev shell) to continue." >&2
	exit 1
fi

SDKMANAGER_BIN="$(resolve_sdkmanager)"
SIMG2IMG_BIN="$(resolve_simg2img)"

IMAGE_SPEC="system-images;android-${API_LEVEL};${CHANNEL};${ABI}"
echo "Ensuring system image ${IMAGE_SPEC} is installed..." >&2
yes | "$SDKMANAGER_BIN" --sdk_root="$ANDROID_SDK_ROOT" --install "$IMAGE_SPEC" >/dev/null

SYSTEM_IMG="${ANDROID_SDK_ROOT}/system-images/android-${API_LEVEL}/${CHANNEL}/${ABI}/system.img"
if [[ ! -f "$SYSTEM_IMG" ]]; then
	echo "Expected system image not found at ${SYSTEM_IMG}" >&2
	exit 1
fi

RAW_IMG="${WORKDIR}/system_raw.img"
echo "Converting sparse system image to ${RAW_IMG}..." >&2
"$SIMG2IMG_BIN" "$SYSTEM_IMG" "$RAW_IMG"

EXTRACT_DIR="${WORKDIR}/system_root"
mkdir -p "$EXTRACT_DIR"

echo "Extracting filesystem with debugfs into ${EXTRACT_DIR}..." >&2
debugfs -R "rdump / $EXTRACT_DIR" "$RAW_IMG" >/dev/null

echo "System image contents available at: $EXTRACT_DIR"
echo "Raw ext4 image saved at: $RAW_IMG" >&2
if [[ $KEEP_TEMP -ne 0 ]]; then
	echo "Temporary workspace preserved in: $WORKDIR" >&2
else
	echo "Temporary workspace removed." >&2
fi
