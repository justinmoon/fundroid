#!/usr/bin/env bash
# Pack init binary into bootable initramfs.cpio.gz

set -euo pipefail

copy_lib() {
    local dest_dir=$1
    local name=$2
    shift 2
    for candidate in "$@"; do
        if [ -n "${candidate:-}" ] && [ -f "$candidate" ]; then
            cp "$candidate" "$dest_dir/"
            return 0
        fi
    done
    echo "Warning: missing $name (provide it manually or ensure nix is available)" >&2
    return 1
}

if command -v nix >/dev/null 2>&1; then
    NIX_GLIBC=$(nix path-info nixpkgs#glibc 2>/dev/null || true)
    NIX_LIBDRM=$(nix path-info nixpkgs#libdrm 2>/dev/null || true)
else
    NIX_GLIBC=""
    NIX_LIBDRM=""
fi

if [ ! -f "init" ]; then
    echo "Error: init not found. Run ./build.sh first"
    exit 1
fi

if [ ! -f "test_child" ]; then
    echo "Error: test_child not found. Run ./build.sh first"
    exit 1
fi

# Build weston-rootfs if not already built
if [ ! -L "weston-rootfs" ]; then
    echo "Building weston-rootfs package..."
    nix build ..#weston-rootfs --out-link weston-rootfs
else
    echo "Using existing weston-rootfs"
fi

WORK_DIR=$(mktemp -d)
trap "rm -rf '$WORK_DIR'" EXIT

cp init "$WORK_DIR/init"
chmod +x "$WORK_DIR/init"

cp test_child "$WORK_DIR/test_child"
chmod +x "$WORK_DIR/test_child"

if [ -f "load_modules" ]; then
    cp load_modules "$WORK_DIR/load_modules"
    chmod +x "$WORK_DIR/load_modules"
fi

# Include drm_rect if available
if [ -f "drm_rect" ]; then
    cp drm_rect "$WORK_DIR/drm_rect"
    chmod +x "$WORK_DIR/drm_rect"
    echo "Including drm_rect in initramfs (with glibc libs)"
    
    mkdir -p "$WORK_DIR/lib64" "$WORK_DIR/lib" "$WORK_DIR/usr/lib"
    copy_lib "$WORK_DIR/lib64" "ld-linux-x86-64.so.2" \
        "$PWD/ld-linux-x86-64.so.2" \
        "${NIX_GLIBC:+$NIX_GLIBC/lib/ld-linux-x86-64.so.2}"
    copy_lib "$WORK_DIR/lib" "libc.so.6" \
        "$PWD/libc.so.6" \
        "${NIX_GLIBC:+$NIX_GLIBC/lib/libc.so.6}"
    copy_lib "$WORK_DIR/usr/lib" "libc.so.6" \
        "$PWD/libc.so.6" \
        "${NIX_GLIBC:+$NIX_GLIBC/lib/libc.so.6}"
    copy_lib "$WORK_DIR/lib" "libpthread.so.0" \
        "$PWD/libpthread.so.0" \
        "${NIX_GLIBC:+$NIX_GLIBC/lib/libpthread.so.0}"
    copy_lib "$WORK_DIR/usr/lib" "libpthread.so.0" \
        "$PWD/libpthread.so.0" \
        "${NIX_GLIBC:+$NIX_GLIBC/lib/libpthread.so.0}"
    copy_lib "$WORK_DIR/lib" "libdrm.so.2" \
        "$PWD/libdrm.so.2" \
        "${NIX_LIBDRM:+$NIX_LIBDRM/lib/libdrm.so.2}"
    copy_lib "$WORK_DIR/usr/lib" "libm.so.6" \
        "$PWD/libm.so.6" \
        "${NIX_GLIBC:+$NIX_GLIBC/lib/libm.so.6}"

    if [ -d "weston-deps" ]; then
        chmod -R +w "$WORK_DIR/usr/lib" 2>/dev/null || true
        cp weston-deps/* "$WORK_DIR/usr/lib/" 2>/dev/null || true
        echo "Including weston-terminal dependencies ($(ls weston-deps | wc -l) files)"
    fi
fi

# Include compositor-rs if available (statically linked, no libs needed)
if [ -f "compositor-rs" ]; then
    cp compositor-rs "$WORK_DIR/compositor-rs"
    chmod +x "$WORK_DIR/compositor-rs"
    echo "Including compositor-rs in initramfs (statically linked)"
fi

# Include test-client if available (statically linked, no libs needed)
if [ -f "test-client" ]; then
    cp test-client "$WORK_DIR/test-client"
    chmod +x "$WORK_DIR/test-client"
    echo "Including test-client in initramfs (statically linked)"
fi

# Include kernel modules if available
if [ -d "kernel-modules" ]; then
    mkdir -p "$WORK_DIR/lib/modules"
    cp kernel-modules/*.ko "$WORK_DIR/lib/modules/" 2>/dev/null || true
    echo "Including kernel modules"
fi

# Include weston-rootfs if available
if [ -L "weston-rootfs" ]; then
    echo "Including weston-rootfs in initramfs..."
    mkdir -p "$WORK_DIR/usr"
    
    if [ -d "weston-rootfs/bin" ]; then
        cp -rL weston-rootfs/bin "$WORK_DIR/usr/"
        echo "  - Copied binaries"
    fi
    if [ -d "weston-rootfs/lib" ]; then
        cp -rL weston-rootfs/lib "$WORK_DIR/usr/"
        echo "  - Copied libraries"
    fi
    if [ -f "$WORK_DIR/lib64/ld-linux-x86-64.so.2" ]; then
        chmod -R +w "$WORK_DIR/usr/lib"
        cp "$WORK_DIR/lib64/ld-linux-x86-64.so.2" "$WORK_DIR/usr/lib/"
        echo "  - Copied dynamic linker to /usr/lib"
    fi
    if [ -d "weston-rootfs/share" ]; then
        cp -rL weston-rootfs/share "$WORK_DIR/usr/"
        echo "  - Copied shared resources"
    fi
    if [ -d "weston-rootfs/etc" ]; then
        mkdir -p "$WORK_DIR/etc"
        cp -rL weston-rootfs/etc/* "$WORK_DIR/etc/" 2>/dev/null || true
        echo "  - Copied configuration files"
    fi

    echo "Patching weston binaries for initramfs compatibility..."
    for binary in "$WORK_DIR"/usr/bin/weston*; do
        if [ -f "$binary" ] && file "$binary" | grep -q "ELF.*dynamically linked"; then
            chmod +w "$binary"
            nix-shell -p patchelf --run "patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 --set-rpath /usr/lib '$binary'" 2>/dev/null || echo "  Warning: Failed to patch $(basename "$binary")"
        fi
    done
fi

# Include custom overlay files
if [ -d "rootfs" ]; then
    rsync -a --exclude '.DS_Store' rootfs/ "$WORK_DIR/"
    echo "Including rootfs overlay (qemu-init/rootfs)"
fi

cd "$WORK_DIR"
find . | cpio --create --format=newc --quiet | gzip > "$OLDPWD/initramfs.cpio.gz"
cd "$OLDPWD"

echo "Packed: initramfs.cpio.gz ($(ls -lh initramfs.cpio.gz | awk '{print $5}'))"
