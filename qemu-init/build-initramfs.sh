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
    
    # Fix dynamic linker paths for Nix-built binaries
    # Nix binaries have interpreter paths like /nix/store/.../ld-linux-x86-64.so.2
    # We need to patch them to use /lib64/ld-linux-x86-64.so.2
    if command -v patchelf >/dev/null 2>&1; then
        echo "  - Patching ELF binaries to use /lib64/ld-linux-x86-64.so.2"
        mkdir -p "$WORK_DIR/lib64"
        
        # Find and copy a working dynamic linker
        # First try from weston-rootfs, then from local drm_rect libs
        INTERP=$(find weston-rootfs -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | head -1)
        if [ -z "$INTERP" ] && [ -f "ld-linux-x86-64.so.2" ]; then
            INTERP="ld-linux-x86-64.so.2"
        fi
        if [ -n "$INTERP" ]; then
            cp "$INTERP" "$WORK_DIR/lib64/ld-linux-x86-64.so.2"
            echo "  - Copied dynamic linker to /lib64"
        else
            echo "  - WARNING: Could not find ld-linux-x86-64.so.2"
        fi
        
        # Patch all binaries in /usr/bin
        if [ -d "$WORK_DIR/usr/bin" ]; then
            PATCHED=0
            for bin in "$WORK_DIR/usr/bin"/*; do
                if [ -f "$bin" ] && [ -x "$bin" ]; then
                    if patchelf --print-interpreter "$bin" >/dev/null 2>&1; then
                        # Make writable in case it's readonly from Nix store
                        chmod +w "$bin"
                        if patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$bin" 2>/dev/null; then
                            PATCHED=$((PATCHED + 1))
                        fi
                    fi
                fi
            done
            echo "  - Successfully patched $PATCHED binaries"
        fi
    else
        echo "  - WARNING: patchelf not found, binaries may not work"
    fi
    
    echo "Weston rootfs included successfully"
    
    # Copy wayland libraries from local-libs directory if available
    if [ -d "local-libs" ]; then
        mkdir -p "$WORK_DIR/usr/lib"
        chmod -R +w "$WORK_DIR/usr/lib" 2>/dev/null || true
        cp local-libs/libwayland-*.so* "$WORK_DIR/usr/lib/" 2>/dev/null && \
            echo "  - Copied wayland libraries from local-libs"
    fi
fi

# Include custom weston.ini configuration
if [ -f "rootfs/etc/weston.ini" ]; then
    mkdir -p "$WORK_DIR/etc"
    cp rootfs/etc/weston.ini "$WORK_DIR/etc/weston.ini"
    echo "Including custom weston.ini configuration"
fi

# Include start-weston script
if [ -f "rootfs/usr/bin/start-weston" ]; then
    mkdir -p "$WORK_DIR/usr/bin"
    chmod -R +w "$WORK_DIR/usr/bin" 2>/dev/null || true  # Make writable if from Nix store
    cp rootfs/usr/bin/start-weston "$WORK_DIR/usr/bin/start-weston"
    chmod +x "$WORK_DIR/usr/bin/start-weston"
    echo "Including start-weston script"
fi

cd "$WORK_DIR"
find . | cpio --create --format=newc --quiet | gzip > "$OLDPWD/initramfs.cpio.gz"
cd "$OLDPWD"

echo "Packed: initramfs.cpio.gz ($(ls -lh initramfs.cpio.gz | awk '{print $5}'))"
