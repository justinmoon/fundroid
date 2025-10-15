#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_FILTERS=(
	"servicemanager:V"
	"hwservicemanager:V"
	"property_service:V"
	"capsule_entry:V"
	"*:S"
)

ADB_ARGS=()
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
	ADB_ARGS+=("-s" "$ANDROID_SERIAL")
fi

usage() {
	cat <<'EOF'
Usage: capsule_logcat.sh [logcat-args...]

Run adb logcat with filters tuned for capsule services. If no arguments are
provided, the script streams verbose logs for servicemanager, hwservicemanager,
property_service, and capsule_entry while silencing other tags. Any arguments
are passed directly to `adb logcat`.
EOF
}

LOGCAT_ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help)
			usage
			exit 0
			;;
		*)
			LOGCAT_ARGS+=("$1")
			;;
	esac
	shift
done

if [[ ${#LOGCAT_ARGS[@]} -eq 0 ]]; then
	LOGCAT_ARGS=("${DEFAULT_FILTERS[@]}")
fi

adb "${ADB_ARGS[@]}" wait-for-device >/dev/null

exec adb "${ADB_ARGS[@]}" logcat "${LOGCAT_ARGS[@]}"
