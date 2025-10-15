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

mount_fs() {
	src_type="$1"
	target="$2"
	opts="${3:-}"
	if is_mounted "$target"; then
		return
	fi
	if [ -n "$opts" ]; then
		"$TOYBOX" mount -t "$src_type" -o "$opts" "$src_type" "$target"
	else
		"$TOYBOX" mount -t "$src_type" "$src_type" "$target"
	fi
}

bind_mount_dir() {
	src="$1"
	dst="$2"
	if [ ! -d "$src" ]; then
		return
	fi
	ensure_dir "$dst"
	if is_mounted "$dst"; then
		unmount_path "$dst"
	fi
	if ! "$TOYBOX" mount -o rbind "$src" "$dst" 2>/dev/null; then
		"$TOYBOX" mount -o bind "$src" "$dst"
	fi
}

bind_mount_file() {
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
	if is_mounted "$dst"; then
		unmount_path "$dst"
	fi
	if ! "$TOYBOX" mount -o rbind "$src" "$dst" 2>/dev/null; then
		"$TOYBOX" mount -o bind "$src" "$dst"
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

for path in "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/sys/fs" "$ROOTFS/sys/fs/selinux" "$ROOTFS/tmp" "$ROOTFS/run" "$ROOTFS/usr" "$ROOTFS/usr/local" "$ROOTFS/usr/local/bin" "$ROOTFS/mnt" "$ROOTFS/mnt/vendor" "$ROOTFS/mnt/product" "$ROOTFS/debug_ramdisk" "$ROOTFS/second_stage_resources" "$ROOTFS/linkerconfig"; do
		ensure_dir "$path"
	done

	if ! is_mounted "$ROOTFS"; then
		"$TOYBOX" mount -o bind "$ROOTFS" "$ROOTFS"
	fi

	mount_fs tmpfs "$ROOTFS/dev" "mode=0755,dev"
	ensure_dir "$ROOTFS/dev/pts"
	ensure_dir "$ROOTFS/dev/socket"
	ensure_dir "$ROOTFS/dev/dm-user"
	mount_fs devpts "$ROOTFS/dev/pts"

	ensure_dir "$ROOTFS/dev/binderfs"
	if ! is_mounted "$ROOTFS/dev/binderfs"; then
		"$TOYBOX" mount -t binder binderfs "$ROOTFS/dev/binderfs"
	fi
	for node in binder hwbinder vndbinder; do
		if [ -e "$ROOTFS/dev/$node" ]; then
			rm -f "$ROOTFS/dev/$node"
		fi
		if [ -e "$ROOTFS/dev/binderfs/$node" ]; then
			ln -sf binderfs/"$node" "$ROOTFS/dev/$node"
		fi
	done

	# Expose binder device nodes outside the rootfs so host-side processes
	# (webosd bridges) can opt into targeting the capsule explicitly.
	ensure_dir "$CAPSULE_BASE/dev"
	for node in binder hwbinder vndbinder; do
		src="$ROOTFS/dev/$node"
		dst="$CAPSULE_BASE/dev/$node"
		if [ -e "$src" ]; then
			if [ -L "$dst" ] || [ -e "$dst" ]; then
				rm -f "$dst" >/dev/null 2>&1 || true
			fi
			ln -sf "rootfs/dev/$node" "$dst"
		fi
	done

	for mp in system vendor product system_ext odm apex; do
		src="/$mp"
		dst="$ROOTFS/$mp"
		if [ -e "$src" ]; then
			bind_mount_dir "$src" "$dst"
		fi
	done

	bind_mount_dir "/linkerconfig" "$ROOTFS/linkerconfig"

	bind_mount_dir "/dev/log" "$ROOTFS/dev/log"
	bind_mount_dir "/dev/socket" "$ROOTFS/dev/socket"

	ensure_char_device "$ROOTFS/dev/null" 1 3
	ensure_char_device "$ROOTFS/dev/zero" 1 5
	ensure_char_device "$ROOTFS/dev/full" 1 7
	ensure_char_device "$ROOTFS/dev/random" 1 8
	ensure_char_device "$ROOTFS/dev/urandom" 1 9
	ensure_char_device "$ROOTFS/dev/tty" 5 0
	ensure_char_device "$ROOTFS/dev/kmsg" 1 11

	mount_fs proc "$ROOTFS/proc"
	mount_fs sysfs "$ROOTFS/sys"
	mount_fs selinuxfs "$ROOTFS/sys/fs/selinux"
	mount_fs tmpfs "$ROOTFS/tmp"
	mount_fs tmpfs "$ROOTFS/run"
	bind_mount_dir "/dev/__properties__" "$ROOTFS/dev/__properties__"

	if [ ! -e "$ROOTFS/init.rc" ]; then
		ln -sf init/init.capsule.rc "$ROOTFS/init.rc"
	fi
}

teardown_rootfs() {
	cleanup_mounts
	for node in binder hwbinder vndbinder; do
		if [ -L "$ROOTFS/dev/$node" ]; then
			rm -f "$ROOTFS/dev/$node"
		fi
		if [ -L "$CAPSULE_BASE/dev/$node" ]; then
			rm -f "$CAPSULE_BASE/dev/$node"
		fi
	done
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

exec_chroot_ns() {
	if [ $# -eq 0 ]; then
		set -- /system/bin/sh
	fi
	prepare_rootfs
	if "$TOYBOX" which unshare >/dev/null 2>&1; then
		log "entering rootfs with private mount namespace: $*"
		exec "$TOYBOX" unshare -m -- "$TOYBOX" chroot "$ROOTFS" "$@"
	fi
	log "unshare unavailable; entering rootfs without namespace isolation: $*"
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
		"$ROOTFS/run"; do
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
  prepare    Setup mount points inside the capsule rootfs.
  exec CMD   Ensure mounts and execute CMD via chroot (default: /system/bin/sh).
  execns CMD Like 'exec' but isolates mount changes when unshare is available.
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
	execns)
		shift
		exec_chroot_ns "$@"
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
