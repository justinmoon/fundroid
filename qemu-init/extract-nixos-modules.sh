#!/usr/bin/env bash
# Extract kernel modules from NixOS kernel package
# These modules match the bzImage-nixos kernel version

set -euo pipefail

if [ ! -L "qemu-kernel" ]; then
    echo "Error: qemu-kernel symlink not found"
    echo "Run: nix build ..#packages.x86_64-linux.qemu-kernel --out-link qemu-kernel"
    exit 1
fi

KERNEL_MODULES_DIR="qemu-kernel/lib/modules/6.12.7/kernel"
OUTPUT_DIR="kernel-modules-nixos"

echo "Extracting NixOS kernel modules..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Find and extract virtio and DRM modules
MODULES=(
    "drivers/virtio/virtio.ko.xz"
    "drivers/virtio/virtio_ring.ko.xz"
    "drivers/virtio/virtio_pci.ko.xz"
    "drivers/gpu/drm/virtio/virtio-gpu.ko.xz"
)

for mod in "${MODULES[@]}"; do
    MOD_PATH="$KERNEL_MODULES_DIR/$mod"
    if [ -f "$MOD_PATH" ]; then
        BASENAME=$(basename "$mod" .xz)
        echo "  Extracting $BASENAME..."
        xz -d < "$MOD_PATH" > "$OUTPUT_DIR/$BASENAME"
    else
        echo "  Warning: $mod not found"
    fi
done

# Count extracted modules
COUNT=$(ls "$OUTPUT_DIR"/*.ko 2>/dev/null | wc -l)
echo "Extracted $COUNT modules to $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR"/*.ko
