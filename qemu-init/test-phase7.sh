#!/bin/bash
# Test Phase 7 input with proper QEMU setup

set -e

echo "Testing Phase 7 input enumeration..."
echo ""
echo "QEMU will start with:"
echo "  - virtio-keyboard-pci device"
echo "  - virtio-mouse-pci device"
echo ""
echo "If kernel has CONFIG_VIRTIO_INPUT enabled:"
echo "  - /dev/input/event0 (keyboard) should exist"
echo "  - /dev/input/event1 (mouse) should exist"
echo ""

timeout 15 qemu-system-x86_64 \
  -kernel ./bzImage \
  -initrd initramfs.cpio.gz \
  -append "console=ttyS0 init=/bin/sh" \
  -m 512M \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci \
  -nographic <<'COMMANDS'
echo "=== Checking for /dev/input ==="
ls -la /dev/input 2>&1 || echo "/dev/input directory not found"
echo ""
echo "=== Checking for event devices ==="
ls -la /dev/input/event* 2>&1 || echo "No event devices found"
echo ""
echo "=== Running test-input binary ==="
/test-input
echo ""
echo "=== Test complete ==="
sleep 2
poweroff -f
COMMANDS
