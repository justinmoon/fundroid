#!/usr/bin/env bash
# Pack init binary into bootable initramfs.cpio.gz

set -euo pipefail

if [ ! -f "init" ]; then
    echo "Error: init not found. Run ./build.sh first"
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT

cp init "$WORK_DIR/init"
chmod +x "$WORK_DIR/init"

cd "$WORK_DIR"
find . | cpio --create --format=newc --quiet | gzip > "$OLDPWD/initramfs.cpio.gz"
cd "$OLDPWD"

echo "Packed: initramfs.cpio.gz ($(ls -lh initramfs.cpio.gz | awk '{print $5}'))"
