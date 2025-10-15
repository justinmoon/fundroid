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
		echo "capsule_hello: no adb devices connected" >&2
		exit 1
	else
		echo "capsule_hello: multiple adb devices detected; set ANDROID_SERIAL" >&2
		exit 1
	fi
fi

export ANDROID_SERIAL

ADB=(adb)
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
	ADB+=(-s "${ANDROID_SERIAL}")
fi

ARTIFACT_DIR="${REPO_ROOT}/artifacts/capsule"
mkdir -p "${ARTIFACT_DIR}"

cleanup() {
	"${SCRIPT_DIR}/run_capsule.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

exec_in_capsule() {
	local cmd="$1"
	local quoted
	quoted=$(printf '%q' "$cmd")
	"${ADB[@]}" shell "CAPSULE_BASE='${CAPSULE_BASE}' '${ENTRY_PATH}' exec /system/bin/sh -c ${quoted}" | tr -d '\r'
}

wait_for_ready() {
	local deadline=$((SECONDS + 60))
	while (( SECONDS < deadline )); do
		if [[ "$("${ADB[@]}" shell getprop sys.capsule.ready | tr -d '\r')" == "1" ]]; then
			return 0
		fi
		sleep 1
	done
	echo "capsule_hello: timeout waiting for sys.capsule.ready" >&2
	return 1
}

echo "capsule_hello: starting capsule..."
"${SCRIPT_DIR}/run_capsule.sh" start >/dev/null

echo "capsule_hello: pushing capsule tools..."
"${SCRIPT_DIR}/push_capsule_tools.sh"

wait_for_ready

echo "capsule_hello: waiting for binder readiness..."
exec_in_capsule "/usr/local/bin/wait_for_binder --device /dev/binder --timeout 5"

echo "capsule_hello: listing services..."
service_output="$(exec_in_capsule "/usr/local/bin/list_services --device /dev/binder --wait 1")"
printf '%s\n' "${service_output}" >"${ARTIFACT_DIR}/services.txt"

if ! grep -q '^manager$' "${ARTIFACT_DIR}/services.txt"; then
	echo "capsule_hello: expected 'manager' service not found" >&2
	exit 1
fi

echo "capsule_hello: capturing logs..."
"${ADB[@]}" pull "${CAPSULE_BASE}/run/init.log" "${ARTIFACT_DIR}/init.log" >/dev/null
"${ADB[@]}" pull "${CAPSULE_BASE}/rootfs/run/capsule/capsule-supervisor.log" "${ARTIFACT_DIR}/capsule-supervisor.log" >/dev/null 2>&1 || true

echo "capsule_hello: capsule services are responding."
