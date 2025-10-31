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
    
    # Include required libraries for glibc
    mkdir -p "$WORK_DIR/lib64" "$WORK_DIR/lib" "$WORK_DIR/usr/lib"
    if [ -f "ld-linux-x86-64.so.2" ]; then
        cp ld-linux-x86-64.so.2 "$WORK_DIR/lib64/"
    fi
    if [ -f "libc.so.6" ]; then
        cp libc.so.6 "$WORK_DIR/lib/"
        # Also copy to /usr/lib for weston binaries
        cp libc.so.6 "$WORK_DIR/usr/lib/"
    fi
    if [ -f "libpthread.so.0" ]; then
        cp libpthread.so.0 "$WORK_DIR/lib/"
        cp libpthread.so.0 "$WORK_DIR/usr/lib/"
    fi
    if [ -f "libdrm.so.2" ]; then
        cp libdrm.so.2 "$WORK_DIR/lib/"
    fi
    # Also copy libm for weston binaries
    if [ -f "libm.so.6" ]; then
        cp libm.so.6 "$WORK_DIR/usr/lib/"
    fi
    
    # Copy additional libraries for weston-terminal (full runtime closure)
    if [ -d "weston-deps" ]; then
        chmod -R +w "$WORK_DIR/usr/lib" 2>/dev/null || true
        cp weston-deps/* "$WORK_DIR/usr/lib/" 2>/dev/null || true
        echo "Including weston-terminal dependencies ($(ls weston-deps | wc -l) files)"
    fi
    
    echo "Including drm_rect in initramfs (with glibc libs)"
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
    
    # Copy binaries (follow symlinks with -L to get actual files)
    if [ -d "weston-rootfs/bin" ]; then
        cp -rL weston-rootfs/bin "$WORK_DIR/usr/"
        echo "  - Copied binaries"
    fi
    
    # Copy libraries (follow symlinks with -L to get actual files)
    if [ -d "weston-rootfs/lib" ]; then
        cp -rL weston-rootfs/lib "$WORK_DIR/usr/"
        echo "  - Copied libraries"
    fi
    
    # Also copy dynamic linker to /usr/lib (weston binaries are patched to use this path)
    if [ -f "$WORK_DIR/lib64/ld-linux-x86-64.so.2" ]; then
        chmod -R +w "$WORK_DIR/usr/lib"  # Make writable (files from Nix store are read-only)
        cp "$WORK_DIR/lib64/ld-linux-x86-64.so.2" "$WORK_DIR/usr/lib/"
        echo "  - Copied dynamic linker to /usr/lib"
    elif [ -f "ld-linux-x86-64.so.2" ]; then
        chmod -R +w "$WORK_DIR/usr/lib"  # Make writable
        cp ld-linux-x86-64.so.2 "$WORK_DIR/usr/lib/"
        echo "  - Copied dynamic linker to /usr/lib"
    fi
    
    # Copy shared resources (fonts, icons, etc.)
    if [ -d "weston-rootfs/share" ]; then
        cp -rL weston-rootfs/share "$WORK_DIR/usr/"
        echo "  - Copied shared resources"
    fi
    
    # Copy etc configs
    if [ -d "weston-rootfs/etc" ]; then
        mkdir -p "$WORK_DIR/etc"
        cp -rL weston-rootfs/etc/* "$WORK_DIR/etc/" 2>/dev/null || true
        echo "  - Copied configuration files"
    fi
    
    echo "Weston rootfs included successfully"
    
    # Patch weston binaries to use /usr/lib/ld-linux-x86-64.so.2 and /usr/lib for libraries
    echo "Patching weston binaries for initramfs compatibility..."
    for binary in "$WORK_DIR"/usr/bin/weston*; do
        if [ -f "$binary" ] && file "$binary" | grep -q "ELF.*dynamically linked"; then
            chmod +w "$binary"  # Make writable for patchelf
            nix-shell -p patchelf --run "patchelf --set-interpreter /usr/lib/ld-linux-x86-64.so.2 --set-rpath /usr/lib '$binary'" 2>/dev/null && {
                echo "  ✓ Patched $(basename "$binary")"
            } || {
                echo "  Warning: Failed to patch $(basename "$binary")"
            }
        fi
    done
    echo "  - Patching complete"
fi

# Include custom weston.ini configuration
if [ -f "rootfs/etc/weston.ini" ]; then
    mkdir -p "$WORK_DIR/etc"
    cp rootfs/etc/weston.ini "$WORK_DIR/etc/weston.ini"
    echo "Including custom weston.ini configuration"
fi

cd "$WORK_DIR"
find . | cpio --create --format=newc --quiet | gzip > "$OLDPWD/initramfs.cpio.gz"
cd "$OLDPWD"

echo "Packed: initramfs.cpio.gz ($(ls -lh initramfs.cpio.gz | awk '{print $5}'))"
