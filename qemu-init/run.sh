#!/usr/bin/env bash
# Build and boot the minimal init in QEMU

set -euo pipefail

# If not in nix shell, re-exec ourselves inside it
if ! command -v qemu-system-x86_64 &> /dev/null; then
    exec nix develop .. --command bash "$0" "$@"
fi

# Build if needed
if [ ! -f init ] || [ init.zig -nt init ]; then
    echo "Building init..."
    zig build-exe -target x86_64-linux-musl -O ReleaseSafe -fstrip -fsingle-threaded init.zig
fi

# Build initramfs if needed
if [ ! -f initramfs.cpio.gz ] || [ init -nt initramfs.cpio.gz ]; then
    echo "Packing initramfs..."
    ./build-initramfs.sh
fi

# Download kernel if needed
if [ ! -f bzImage ]; then
    echo "Downloading kernel..."
    ./download-kernel.sh
fi

echo
echo "Booting (20 seconds)..."
echo

# Capture output to a temp file
TMPFILE=$(mktemp)
trap "rm -f '$TMPFILE'" EXIT

# Use script to give QEMU a PTY (fixes buffering issues)
script -q "$TMPFILE" bash -c 'timeout 20 qemu-system-x86_64 \
    -kernel ./bzImage \
    -initrd initramfs.cpio.gz \
    -append "console=ttyS0 quiet init=/init panic=1" \
    -nographic \
    -serial mon:stdio \
    -m 512M' || true

echo

# Validate that init actually started and ran
if ! grep -q "QEMU MINIMAL INIT" "$TMPFILE"; then
    echo "❌ FAILED: Init banner not found"
    exit 1
fi

if ! grep -q "PID: 1" "$TMPFILE"; then
    echo "❌ FAILED: PID 1 not confirmed"
    exit 1
fi

# Count heartbeats (should see multiple over 15 seconds)
HEARTBEAT_COUNT=$(grep -c "\[heartbeat\]" "$TMPFILE" || echo "0")
if [ "$HEARTBEAT_COUNT" -lt 5 ]; then
    echo "❌ FAILED: Only saw $HEARTBEAT_COUNT heartbeats (expected at least 5)"
    exit 1
fi

# Check for child spawning and respawning
SPAWN_COUNT=$(grep -c "\[SPAWN\]" "$TMPFILE" || echo "0")
if [ "$SPAWN_COUNT" -lt 3 ]; then
    echo "❌ FAILED: Only saw $SPAWN_COUNT spawns (expected at least 3 with respawns)"
    exit 1
fi

echo "✅ SUCCESS: Init ran as PID 1, printed $HEARTBEAT_COUNT heartbeats, spawned child $SPAWN_COUNT times"
