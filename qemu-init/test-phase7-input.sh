#!/bin/bash
# Test Phase 7 with virtio-input devices

echo "Testing Phase 7 with virtio-keyboard and virtio-mouse..."

nix develop .. --accept-flake-config --command qemu-system-x86_64 \
  -kernel ./bzImage \
  -initrd initramfs.cpio.gz \
  -append "console=ttyS0 init=/init panic=1 gfx=compositor-rs" \
  -m 1024M \
  -device virtio-gpu-pci \
  -device virtio-keyboard-pci \
  -device virtio-mouse-pci \
  -vga none \
  -display cocoa \
  -serial mon:stdio
