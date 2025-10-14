#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPSULE_BASE="${CAPSULE_BASE:-/data/local/tmp/capsule}"
REMOTE_BIN_DIR="$CAPSULE_BASE/rootfs/usr/local/bin"

TARGET_TRIPLE=""

usage() {
	cat <<'EOF'
Usage: push_capsule_tools.sh [--target <triple>]

Push the capsule tooling binaries (wait_for_binder, list_services) into the
capsule rootfs under /usr/local/bin. By default the target triple is detected
from the device architecture (aarch64 -> aarch64-linux-android, x86_64 -> x86_64-linux-android).
EOF
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--target)
			shift
			[[ $# -gt 0 ]] || usage
			TARGET_TRIPLE="$1"
			;;
		-h|--help)
			usage
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage
			;;
	esac
	shift
done

ADB_ARGS=()
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
	ADB_ARGS+=("-s" "$ANDROID_SERIAL")
fi

adb_cmd() {
	adb "${ADB_ARGS[@]}" "$@"
}

adb_shell() {
	adb_cmd shell "$@"
}

adb_root() {
	if ! adb_cmd root >/dev/null 2>&1; then
		echo "Warning: unable to acquire adb root (continuing)." >&2
	fi
	adb_cmd wait-for-device >/dev/null
}

detect_target() {
	local arch
	arch="$(adb_shell uname -m | tr -d '\r')"
	case "$arch" in
		aarch64) echo "aarch64-linux-android" ;;
		x86_64) echo "x86_64-linux-android" ;;
		*)
			echo "Unsupported device architecture '$arch'. Specify --target explicitly." >&2
			exit 2
			;;
	esac
}

if [[ -z "$TARGET_TRIPLE" ]]; then
	adb_cmd wait-for-device >/dev/null
	TARGET_TRIPLE="$(detect_target)"
fi

LOCAL_TARGET_DIR="$REPO_ROOT/rust/capsule_tools/target/$TARGET_TRIPLE/release"
TOOLS=(wait_for_binder list_services)

for tool in "${TOOLS[@]}"; do
	if [[ ! -f "$LOCAL_TARGET_DIR/$tool" ]]; then
		echo "Missing $tool binary at $LOCAL_TARGET_DIR/$tool. Run 'just build-capsule-tools' first." >&2
		exit 3
	fi
done

adb_root
adb_shell "mkdir -p '$REMOTE_BIN_DIR'"

for tool in "${TOOLS[@]}"; do
	adb_cmd push "$LOCAL_TARGET_DIR/$tool" "$REMOTE_BIN_DIR/$tool" >/dev/null
	adb_shell "chmod 0755 '$REMOTE_BIN_DIR/$tool'"
	echo "Pushed $tool to $REMOTE_BIN_DIR/$tool"
done
