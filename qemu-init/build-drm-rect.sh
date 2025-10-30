#!/usr/bin/env bash
# Build drm_rect.zig with libdrm linking

set -euo pipefail

# We need libdrm headers which aren't available on macOS
# For now, just document the build command for Linux

echo "To build drm_rect.zig on Linux with libdrm installed:"
echo "  zig build-exe -target x86_64-linux-musl drm_rect.zig -lc -ldrm"
echo ""
echo "Or install libdrm-dev first:"
echo "  sudo apt-get install libdrm-dev  # Debian/Ubuntu"
echo "  sudo dnf install libdrm-devel     # Fedora"
echo ""
echo "This will be integrated into the QEMU test environment in Phase 6."
