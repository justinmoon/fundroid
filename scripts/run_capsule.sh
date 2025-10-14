#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOTFS_LOCAL="$REPO_ROOT/android/capsule/rootfs"

CAPSULE_BASE="${CAPSULE_BASE:-/data/local/tmp/capsule}"
ENTRY_REL="rootfs/scripts/capsule_entry.sh"
ENTRY_REMOTE="$CAPSULE_BASE/$ENTRY_REL"
PID_FILE="$CAPSULE_BASE/run/capsule.pid"
LOG_FILE="$CAPSULE_BASE/run/init.log"

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

adb_wait() {
	adb_cmd wait-for-device >/dev/null
}

adb_root() {
	if ! adb_cmd root >/dev/null 2>&1; then
		echo "Error: failed to acquire adb root" >&2
		exit 1
	fi
	adb_wait
}

push_rootfs() {
	if [[ ! -d "$ROOTFS_LOCAL" ]]; then
		echo "Error: local rootfs missing at $ROOTFS_LOCAL" >&2
		exit 1
	fi
	adb_shell "mkdir -p '$CAPSULE_BASE'"
	adb_cmd push "$ROOTFS_LOCAL" "$CAPSULE_BASE" >/dev/null
	adb_shell "chmod 0755 '$ENTRY_REMOTE'"
}

prepare_capsule() {
	adb_shell "CAPSULE_BASE='$CAPSULE_BASE' '$ENTRY_REMOTE' prepare"
}

teardown_capsule() {
	adb_shell "CAPSULE_BASE='$CAPSULE_BASE' '$ENTRY_REMOTE' teardown"
}

set_permissive() {
	if ! adb_shell "setenforce 0" >/dev/null 2>&1; then
		echo "Warning: failed to switch SELinux to permissive; capsule services may be denied." >&2
	fi
}

start_capsule() {
	adb_wait
	adb_root
	push_rootfs
	set_permissive
	prepare_capsule

	read -r -d '' remote <<EOF || true
CAPSULE_BASE='$CAPSULE_BASE'
PID_FILE='$PID_FILE'
LOG_FILE='$LOG_FILE'
ENTRY='$ENTRY_REMOTE'
if [ -f "\$PID_FILE" ]; then
	pid=\$(cat "\$PID_FILE" 2>/dev/null)
	if [ -n "\$pid" ] && kill -0 "\$pid" >/dev/null 2>&1; then
		exit 0
	fi
fi
mkdir -p "\$(dirname "\$PID_FILE")"
/system/bin/toybox nohup sh -c "CAPSULE_BASE='$CAPSULE_BASE' \$ENTRY exec /system/bin/init" >"\$LOG_FILE" 2>&1 &
echo \$! > "\$PID_FILE"
EOF

	adb_shell "$remote"
	echo "Capsule start command issued. Logs: $LOG_FILE"
}

stop_capsule() {
read -r -d '' remote <<EOF || true
CAPSULE_BASE='$CAPSULE_BASE'
PID_FILE='$PID_FILE'
ENTRY='$ENTRY_REMOTE'
if [ -f "\$PID_FILE" ]; then
	pid=\$(cat "\$PID_FILE" 2>/dev/null)
	if [ -n "\$pid" ] && kill -0 "\$pid" >/dev/null 2>&1; then
		kill "\$pid" >/dev/null 2>&1 || true
		for _ in 1 2 3 4 5; do
			if ! kill -0 "\$pid" >/dev/null 2>&1; then
				break
			fi
			sleep 1
		done
		if kill -0 "\$pid" >/dev/null 2>&1; then
			kill -9 "\$pid" >/dev/null 2>&1 || true
		fi
fi
rm -f "\$PID_FILE"
fi
if [ -f "\$ENTRY" ]; then
	CAPSULE_BASE='$CAPSULE_BASE' "\$ENTRY" teardown
fi
EOF

	adb_shell "$remote"
	echo "Capsule stopped."
}

capsule_status() {
read -r -d '' remote <<EOF || true
CAPSULE_BASE='$CAPSULE_BASE'
PID_FILE='$PID_FILE'
ENTRY='$ENTRY_REMOTE'
if [ -f "\$PID_FILE" ]; then
	pid=\$(cat "\$PID_FILE" 2>/dev/null)
	if [ -n "\$pid" ] && kill -0 "\$pid" >/dev/null 2>&1; then
		echo "capsule: running (pid \$pid)"
	else
		echo "capsule: pid file stale"
	fi
else
	echo "capsule: not running"
fi
if [ -f "\$ENTRY" ]; then
	CAPSULE_BASE='$CAPSULE_BASE' "\$ENTRY" status
else
	echo "capsule_entry.sh not deployed (run start first)"
fi
ready=\$(getprop capsule.ready 2>/dev/null)
if [ -n "\$ready" ]; then
	echo "capsule.ready=\$ready"
else
	echo "capsule.ready=<unset>"
fi
EOF

	adb_shell "$remote"
}

capsule_shell() {
	adb_shell "CAPSULE_BASE='$CAPSULE_BASE' '$ENTRY_REMOTE' exec /system/bin/sh"
}

usage() {
	cat <<EOF
Usage: run_capsule.sh <start|stop|status|shell>
  start   Push rootfs, prepare environment, and launch capsule init.
  stop    Stop capsule process and unmount resources.
  status  Report capsule mount and process information.
  shell   Execute an interactive shell inside the capsule rootfs.

Environment:
  ANDROID_SERIAL   Target device/emulator serial (optional).
  CAPSULE_BASE     Remote base path (default: /data/local/tmp/capsule).
EOF
}

cmd="${1:-}"
case "$cmd" in
	start)
		start_capsule
		;;
	stop)
		stop_capsule
		;;
	status)
		capsule_status
		;;
	shell)
		capsule_shell
		;;
	*)
		usage
		exit 1
		;;
esac
