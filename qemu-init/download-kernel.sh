#!/usr/bin/env bash
# Download pre-built Debian kernel

set -euo pipefail

if [ -f "bzImage" ]; then
    echo "Kernel already exists: bzImage"
    exit 0
fi

echo "Downloading Debian kernel..."
curl -L -o bzImage "https://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux"
echo "Downloaded: bzImage ($(ls -lh bzImage | awk '{print $5}'))"
