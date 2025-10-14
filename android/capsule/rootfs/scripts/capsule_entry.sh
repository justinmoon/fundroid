#!/system/bin/sh
set -euo pipefail

TOYBOX=${TOYBOX:-/system/bin/toybox}
CAPSULE_BASE=${CAPSULE_BASE:-/data/local/tmp/capsule}
ROOTFS="${CAPSULE_BASE}/rootfs"
RUNTIME_DIR="${CAPSULE_BASE}/run"

log() {
	echo "capsule_entry: $*" >&2
}

ensure_dir() {
	if [ ! -d "$1" ]; then
		mkdir -p "$1"
	fi
}

is_mounted() {
	grep -F " $1 " /proc/mounts >/dev/null 2>&1
}

bind_mount_dir() {
	src="$1"
	dst="$2"
	if [ ! -d "$src" ]; then
		return
	fi
	ensure_dir "$dst"
	if ! is_mounted "$dst"; then
		"$TOYBOX" mount --bind "$src" "$dst"
	fi
}

bind_mount_path() {
	src="$1"
	dst="$2"
	if [ -d "$src" ]; then
		bind_mount_dir "$src" "$dst"
		return
	fi
	if [ ! -e "$src" ]; then
		return
	fi
	ensure_dir "$(dirname "$dst")"
	if [ ! -e "$dst" ]; then
		rm -f "$dst" >/dev/null 2>&1 || true
		"$TOYBOX" touch "$dst"
	fi
	if ! is_mounted "$dst"; then
		"$TOYBOX" mount --bind "$src" "$dst"
	fi
}

mount_tmpfs() {
	target="$1"
	type="$2"
	if ! is_mounted "$target"; then
		"$TOYBOX" mount -t "$type" "$type" "$target"
	fi
}

ensure_char_device() {
	path="$1"
	major="$2"
	minor="$3"
	ensure_dir "$(dirname "$path")"
	if [ -b "$path" ]; then
		return
	fi
	rm -f "$path" >/dev/null 2>&1 || true
	"$TOYBOX" mknod "$path" c "$major" "$minor"
	chmod 0666 "$path"
}

unmount_path() {
	target="$1"
	if ! is_mounted "$target"; then
		return
	fi
	"$TOYBOX" umount "$target" >/dev/null 2>&1 ||
		umount "$target" >/dev/null 2>&1 ||
		"$TOYBOX" umount -l "$target" >/dev/null 2>&1 ||
		umount -l "$target" >/dev/null 2>&1 ||
		true
}

cleanup_mounts() {
	"$TOYBOX" cat /proc/mounts |
	while IFS=' ' read -r _ target _ _; do
		case "$target" in
			"$ROOTFS"*) echo "$target" ;;
		esac
	done |
	sort -r |
	while IFS= read -r path; do
		unmount_path "$path"
	done
}

prepare_rootfs() {
	ensure_dir "$ROOTFS"
	ensure_dir "$RUNTIME_DIR"

	for path in "$ROOTFS/dev" "$ROOTFS/dev/binderfs" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/tmp" "$ROOTFS/run" "$ROOTFS/usr" "$ROOTFS/usr/local" "$ROOTFS/usr/local/bin"; do
		ensure_dir "$path"
	done

	if ! is_mounted "$ROOTFS/dev/binderfs"; then
		"$TOYBOX" mount -t binder binderfs "$ROOTFS/dev/binderfs"
	fi

	for node in binder hwbinder vndbinder; do
		if [ -e "$ROOTFS/dev/binderfs/$node" ]; then
			ln -sf binderfs/$node "$ROOTFS/dev/$node"
		fi
	done

	for mp in system vendor product system_ext odm apex; do
		src="/$mp"
		dst="$ROOTFS/$mp"
		if [ -e "$src" ]; then
			bind_mount_dir "$src" "$dst"
		fi
	done

	bind_mount_path "/dev/kmsg" "$ROOTFS/dev/kmsg"
	bind_mount_dir "/dev/log" "$ROOTFS/dev/log"

	ensure_char_device "$ROOTFS/dev/null" 1 3
	ensure_char_device "$ROOTFS/dev/zero" 1 5
	ensure_char_device "$ROOTFS/dev/full" 1 7
	ensure_char_device "$ROOTFS/dev/random" 1 8
	ensure_char_device "$ROOTFS/dev/urandom" 1 9
	ensure_char_device "$ROOTFS/dev/tty" 5 0

	mount_tmpfs "$ROOTFS/proc" proc
	mount_tmpfs "$ROOTFS/sys" sysfs
	mount_tmpfs "$ROOTFS/tmp" tmpfs
	mount_tmpfs "$ROOTFS/run" tmpfs

	if [ ! -e "$ROOTFS/init.rc" ]; then
		ln -sf init/init.capsule.rc "$ROOTFS/init.rc"
	fi
}

teardown_rootfs() {
	cleanup_mounts
	unmount_path "$ROOTFS/dev/binderfs"
	for node in binder hwbinder vndbinder; do
		if [ -L "$ROOTFS/dev/$node" ]; then
			rm -f "$ROOTFS/dev/$node"
		fi
	done
	rm -f "$ROOTFS/dev/kmsg"
	rm -rf "$ROOTFS/dev/log"
}

exec_chroot() {
	if [ $# -eq 0 ]; then
		set -- /system/bin/sh
	fi
	prepare_rootfs
	log "entering rootfs with command: $*"
	exec "$TOYBOX" chroot "$ROOTFS" "$@"
}

print_status() {
	echo "CAPSULE_BASE=$CAPSULE_BASE"
	echo "ROOTFS=$ROOTFS"
	for path in \
		"$ROOTFS/system" \
		"$ROOTFS/vendor" \
		"$ROOTFS/apex" \
		"$ROOTFS/dev/log" \
		"$ROOTFS/dev/kmsg" \
		"$ROOTFS/proc" \
		"$ROOTFS/sys" \
		"$ROOTFS/tmp" \
		"$ROOTFS/run" \
		"$ROOTFS/dev/binderfs"; do
		if is_mounted "$path"; then
			echo "mounted: $path"
		else
			echo "unmounted: $path"
		fi
	done
}

usage() {
	cat <<EOF
Usage: capsule_entry.sh <prepare|exec|teardown|status> [command...]
  prepare    Setup mount points and binderfs inside the capsule rootfs.
  exec CMD   Ensure mounts and execute CMD via chroot (default: /system/bin/sh).
  teardown   Unmount capsule resources.
  status     Print mount status for capsule resources.
EOF
	exit 1
}

if [ ! -x "$TOYBOX" ]; then
	log "toybox binary not found at $TOYBOX"
	exit 1
fi

action="${1:-}"
case "$action" in
	prepare)
		shift
		prepare_rootfs
		;;
	exec)
		shift
		exec_chroot "$@"
		;;
	teardown)
		shift
		teardown_rootfs
		;;
	status)
		shift
		print_status
		;;
	*)
		usage
		;;
esac
