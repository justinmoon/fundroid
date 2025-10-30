#!/usr/bin/env bash
# Pack init binary into bootable initramfs.cpio.gz

set -euo pipefail

if [ ! -f "init" ]; then
    echo "Error: init not found. Run ./build.sh first"
    exit 1
fi

if [ ! -f "test_child" ]; then
    echo "Error: test_child not found. Build it first"
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT

cp init "$WORK_DIR/init"
chmod +x "$WORK_DIR/init"

cp test_child "$WORK_DIR/test_child"
chmod +x "$WORK_DIR/test_child"

# Include drm_rect if available
if [ -f "drm_rect" ]; then
    cp drm_rect "$WORK_DIR/drm_rect"
    chmod +x "$WORK_DIR/drm_rect"
    
    # Include required libraries for glibc
    mkdir -p "$WORK_DIR/lib64" "$WORK_DIR/lib"
    if [ -f "ld-linux-x86-64.so.2" ]; then
        cp ld-linux-x86-64.so.2 "$WORK_DIR/lib64/"
    fi
    if [ -f "libc.so.6" ]; then
        cp libc.so.6 "$WORK_DIR/lib/"
    fi
    if [ -f "libpthread.so.0" ]; then
        cp libpthread.so.0 "$WORK_DIR/lib/"
    fi
    if [ -f "libdrm.so.2" ]; then
        cp libdrm.so.2 "$WORK_DIR/lib/"
    fi
    
    echo "Including drm_rect in initramfs (with glibc libs)"
fi

cd "$WORK_DIR"
find . | cpio --create --format=newc --quiet | gzip > "$OLDPWD/initramfs.cpio.gz"
cd "$OLDPWD"

echo "Packed: initramfs.cpio.gz ($(ls -lh initramfs.cpio.gz | awk '{print $5}'))"
