#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CAPSULE_BASE="${CAPSULE_BASE:-/data/local/tmp/capsule}"
ENTRY_PATH="${CAPSULE_BASE}/rootfs/scripts/capsule_entry.sh"

usage() {
	cat <<'EOF'
Usage: capsule_exec.sh [command...]

Run a command inside the capsule rootfs using the same namespace isolation that
the supervisor employs. When no command is supplied an interactive shell is
opened.

Environment:
  ANDROID_SERIAL   Optional adb serial to target.
  CAPSULE_BASE     Capsule deployment base (default: /data/local/tmp/capsule).
EOF
	exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
fi

if [[ $# -eq 0 ]]; then
	set -- /system/bin/sh
fi

if [[ -z "${ANDROID_SERIAL:-}" ]]; then
	devices=()
	while IFS=$'\t' read -r serial state; do
		if [[ -z "$serial" || "$serial" == "List of devices attached" ]]; then
			continue
		fi
		if [[ "$state" == "device" ]]; then
			devices+=("$serial")
		fi
	done < <(adb devices)
	if (( ${#devices[@]} == 1 )); then
		ANDROID_SERIAL="${devices[0]}"
	elif (( ${#devices[@]} == 0 )); then
		echo "capsule_exec: no adb devices connected" >&2
		exit 1
	else
		echo "capsule_exec: multiple adb devices detected; set ANDROID_SERIAL" >&2
		exit 1
	fi
fi

ADB=(adb)
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
	ADB+=(-s "${ANDROID_SERIAL}")
fi

adb_cmd() { "${ADB[@]}" "$@"; }

adb_cmd wait-for-device >/dev/null

if ! adb_cmd root >/dev/null 2>&1; then
	echo "capsule_exec: failed to acquire adb root" >&2
	exit 1
fi

adb_cmd wait-for-device >/dev/null

if ! adb_cmd shell "[ -x '${ENTRY_PATH}' ]" >/dev/null 2>&1; then
	echo "capsule_exec: capsule entry script missing at ${ENTRY_PATH}" >&2
	echo "Run scripts/run_capsule.sh start to deploy the capsule first." >&2
	exit 1
fi

cmd=()
for arg in "$@"; do
	cmd+=("$(printf '%q' "$arg")")
done
joined_cmd="${cmd[*]}"

adb_cmd shell "CAPSULE_BASE='${CAPSULE_BASE}' '${ENTRY_PATH}' execns ${joined_cmd}" || {
	status=$?
	echo "capsule_exec: command failed with status ${status}" >&2
	exit "${status}"
}
