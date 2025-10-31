#!/usr/bin/env bash
# Build custom kernel on Linux (run on Hetzner or in Linux VM)
set -euo pipefail

echo "Building custom kernel with virtio-input support..."
nix build .#qemu-kernel --accept-flake-config --print-build-logs

echo ""
echo "Kernel built! Extracting bzImage..."
cp result/bzImage qemu-init/bzImage

echo ""
echo "✓ Custom kernel ready: qemu-init/bzImage"
echo ""
echo "This kernel includes:"
echo "  - CONFIG_VIRTIO_INPUT=y (keyboard/mouse support)"
echo "  - CONFIG_DRM_VIRTIO_GPU=y (graphics support)"
echo ""
ls -lh qemu-init/bzImage
