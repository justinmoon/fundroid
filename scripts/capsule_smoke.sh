#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CAPSULE_BASE="${CAPSULE_BASE:-/data/local/tmp/capsule}"
ENTRY_PATH="${CAPSULE_BASE}/rootfs/scripts/capsule_entry.sh"

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
	_capsule_devices=()
	while IFS=$'\t' read -r serial state; do
		if [[ -z "$serial" || "$serial" == "List of devices attached" ]]; then
			continue
		fi
		if [[ "$state" == "device" ]]; then
			_capsule_devices+=("$serial")
		fi
	done < <(adb devices)
	if (( ${#_capsule_devices[@]} == 1 )); then
		ANDROID_SERIAL="${_capsule_devices[0]}"
	elif (( ${#_capsule_devices[@]} == 0 )); then
		echo "capsule_smoke: no adb devices connected" >&2
		exit 1
	else
		echo "capsule_smoke: multiple adb devices detected; set ANDROID_SERIAL" >&2
		exit 1
	fi
fi

export ANDROID_SERIAL

ADB=(adb)
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
	ADB+=(-s "${ANDROID_SERIAL}")
fi

cleanup() {
	"${SCRIPT_DIR}/run_capsule.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_ready() {
	local deadline=$((SECONDS + 30))
	while (( SECONDS < deadline )); do
		if [[ "$("${ADB[@]}" shell getprop sys.capsule.ready | tr -d '\r')" == "1" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "capsule_smoke: timeout waiting for sys.capsule.ready" >&2
	return 1
}

exec_in_capsule() {
    local cmd="$1"
    local quoted
    quoted=$(printf '%q' "$cmd")
    "${ADB[@]}" shell "CAPSULE_BASE='${CAPSULE_BASE}' '${ENTRY_PATH}' exec /system/bin/sh -c ${quoted}" | tr -d '\r'
}

assert_char_device() {
    local path="$1"
    if [[ "$(exec_in_capsule "[ -c '${path}' ] && echo ok || echo fail")" != "ok" ]]; then
        echo "capsule_smoke: ${path} is not a character device" >&2
        return 1
    fi
}

echo "capsule_smoke: starting capsule..."
"${SCRIPT_DIR}/run_capsule.sh" start >/dev/null

wait_for_ready

echo "capsule_smoke: verifying binder device nodes..."
assert_char_device "/dev/binder"
assert_char_device "/dev/hwbinder"
assert_char_device "/dev/vndbinder"

echo "capsule_smoke: capsule ready and binder devices present."
