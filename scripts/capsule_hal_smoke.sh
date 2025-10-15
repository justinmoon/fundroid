#!/usr/bin/env bash
set -euo pipefail

# Runs the vibrator HAL smoke test inside the capsule. If `adb root` is not
# available (e.g. production Pixel builds), we fall back to the host smoke test
# so the command still produces meaningful signal without superuser access.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAPSULE_BASE="${CAPSULE_BASE:-/data/local/tmp/capsule}"
ENTRY_PATH="${CAPSULE_BASE}/rootfs/scripts/capsule_entry.sh"
REMOTE_BIN_DIR="${CAPSULE_BASE}/rootfs/usr/local/bin"
SERVICE="${CAPSULE_VIBRATOR_INSTANCE:-android.hardware.vibrator.IVibrator/default}"

select_device() {
	if [[ -n "${ANDROID_SERIAL:-}" ]]; then
		return
	}
	local devices=()
	while IFS=$'\t' read -r serial state; do
		if [[ -z "$serial" || "$serial" == "List of devices attached" ]]; then
			continue
		fi
		if [[ "$state" == "device" ]]; then
			devices+=("$serial")
		fi
	done < <(adb devices)
	if (( ${#devices[@]} == 0 )); then
		echo "capsule_hal_smoke: no adb devices available" >&2
		exit 1
	elif (( ${#devices[@]} > 1 )); then
		echo "capsule_hal_smoke: multiple adb devices detected; set ANDROID_SERIAL" >&2
		echo "  ${devices[*]}" >&2
		exit 1
	fi
	export ANDROID_SERIAL="${devices[0]}"
}

adb_cmd() {
	if [[ -n "${ANDROID_SERIAL:-}" ]]; then
		adb -s "${ANDROID_SERIAL}" "$@"
	else
		adb "$@"
	fi
}

detect_triple() {
	local arch
	arch="$(adb_cmd shell uname -m | tr -d '\r')"
	case "$arch" in
		aarch64) echo "aarch64-linux-android" ;;
		x86_64) echo "x86_64-linux-android" ;;
		*)
			echo "capsule_hal_smoke: unsupported device architecture '$arch'" >&2
			exit 2
			;;
	esac
}

try_enable_root() {
	if adb_cmd root >/dev/null 2>&1; then
		adb_cmd wait-for-device >/dev/null
		return 0
	fi
	return 1
}

push_capsule_binary() {
	local local_path="$1"
	local name
	name="$(basename "$local_path")"
	adb_cmd shell "mkdir -p '${REMOTE_BIN_DIR}'"
	adb_cmd push "$local_path" "${REMOTE_BIN_DIR}/${name}" >/dev/null
	adb_cmd shell "chmod 0755 '${REMOTE_BIN_DIR}/${name}'" >/dev/null
}

exec_in_capsule() {
	local cmd="$1"
	local quoted
	quoted=$(printf '%q' "$cmd")
	adb_cmd shell "CAPSULE_BASE='${CAPSULE_BASE}' '${ENTRY_PATH}' exec /system/bin/sh -c ${quoted}"
}

wait_for_capsule_ready() {
	local deadline=$((SECONDS + 60))
	while (( SECONDS < deadline )); do
		local ready
		ready="$(adb_cmd shell getprop sys.capsule.ready | tr -d '\r')"
		if [[ "$ready" == "1" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "capsule_hal_smoke: capsule did not become ready" >&2
	return 4
}

build_hal_tools() {
	( cd "${REPO_ROOT}" && just build-hal-ndk )
}

cleanup() {
	"${SCRIPT_DIR}/run_capsule.sh" stop >/dev/null 2>&1 || true
}

select_device
adb_cmd wait-for-device >/dev/null

if ! try_enable_root; then
	echo "capsule_hal_smoke: device does not support adb root; falling back to host HAL smoke" >&2
	exec "${SCRIPT_DIR}/hal_smoke.sh" "$SERVICE"
fi

trap cleanup EXIT

build_hal_tools

target_triple="$(detect_triple)"
HAL_VIB_BIN="${REPO_ROOT}/rust/hal_vibrator/target/${target_triple}/release/vib_demo"

if [[ ! -f "${HAL_VIB_BIN}" ]]; then
	echo "capsule_hal_smoke: missing vib_demo binary for ${target_triple}" >&2
	exit 5
fi

push_capsule_binary "${HAL_VIB_BIN}"

echo "[capsule_hal_smoke] starting capsule"
"${SCRIPT_DIR}/run_capsule.sh" start >/dev/null
wait_for_capsule_ready

echo "[capsule_hal_smoke] running vib_demo inside capsule"
exec_in_capsule "/usr/local/bin/vib_demo ${DURATION_MS:-60}"

echo "[capsule_hal_smoke] success"
