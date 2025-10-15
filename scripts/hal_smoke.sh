#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE="${1:-android.hardware.vibrator.IVibrator/default}"
REMOTE_DIR="/data/local/tmp"

build_hal_tools() {
	( cd "${REPO_ROOT}" && just build-hal-ndk )
}

select_device() {
	if [[ -n "${ANDROID_SERIAL:-}" ]]; then
		return
	fi
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
		echo "hal_smoke: no adb devices available" >&2
		exit 1
	elif (( ${#devices[@]} > 1 )); then
		echo "hal_smoke: multiple devices detected; set ANDROID_SERIAL" >&2
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
			echo "hal_smoke: unsupported device architecture '$arch'" >&2
			exit 2
			;;
	esac
}

require_service() {
	if ! adb_cmd shell service list | tr -d '\r' | grep -Fq "$SERVICE"; then
		echo "hal_smoke: service '$SERVICE' not registered" >&2
		exit 3
	fi
}

push_binary() {
	local path="$1"
	local name
	name="$(basename "$path")"
	adb_cmd push "$path" "${REMOTE_DIR}/${name}" >/dev/null
	adb_cmd shell chmod 0755 "${REMOTE_DIR}/${name}" >/dev/null
}

run_remote() {
	local bin="$1"; shift
	adb_cmd shell "${REMOTE_DIR}/${bin}" "$@"
}

build_hal_tools
select_device
adb_cmd wait-for-device >/dev/null
detect_target="$(detect_triple)"

HAL_PING_BIN="${REPO_ROOT}/rust/hal_ndk/target/${detect_target}/release/hal_ping"
VIB_DEMO_BIN="${REPO_ROOT}/rust/hal_vibrator/target/${detect_target}/release/vib_demo"

for bin in "$HAL_PING_BIN" "$VIB_DEMO_BIN"; do
	if [[ ! -f "$bin" ]]; then
		echo "hal_smoke: expected binary missing: $bin" >&2
		exit 4
	fi
done

require_service

push_binary "$HAL_PING_BIN"
push_binary "$VIB_DEMO_BIN"

echo "[hal_smoke] binder ping ${SERVICE}"
run_remote hal_ping "$SERVICE"

echo "[hal_smoke] querying vibrator capabilities"
run_remote vib_demo "${DURATION_MS:-60}"

echo "[hal_smoke] success"
