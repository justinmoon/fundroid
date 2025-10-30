#!/usr/bin/env bash
# Build and boot the minimal init in QEMU

set -euo pipefail

# If not in nix shell, re-exec ourselves inside it FIRST (preserve all args)
if ! command -v qemu-system-x86_64 &> /dev/null; then
    exec nix develop .. --command bash "$0" "$@"
fi

# Parse arguments (after entering nix shell)
GUI_MODE=false
KERNEL_ARGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --gui)
            GUI_MODE=true
            shift
            ;;
        --headless)
            GUI_MODE=false
            shift
            ;;
        *)
            # Treat unknown args as kernel parameters
            KERNEL_ARGS="$KERNEL_ARGS $1"
            shift
            ;;
    esac
done

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
if [ "$GUI_MODE" = true ]; then
    echo "Booting in GUI mode (SDL window)..."
else
    echo "Booting in headless mode (20 seconds)..."
fi
echo

# Build QEMU command
QEMU_CMD="qemu-system-x86_64 -kernel ./bzImage -initrd initramfs.cpio.gz"
QEMU_CMD="$QEMU_CMD -append \"console=ttyS0 quiet init=/init panic=1$KERNEL_ARGS\""

if [ "$GUI_MODE" = true ]; then
    # GUI mode: Use cocoa on macOS, SDL on Linux
    if [[ "$OSTYPE" == "darwin"* ]]; then
        QEMU_CMD="$QEMU_CMD -display cocoa"
    else
        QEMU_CMD="$QEMU_CMD -display sdl,gl=on"
    fi
    QEMU_CMD="$QEMU_CMD -device virtio-gpu-pci"
    QEMU_CMD="$QEMU_CMD -vga none"
    QEMU_CMD="$QEMU_CMD -serial stdio"
    QEMU_CMD="$QEMU_CMD -m 1024M"
    
    echo "Running: $QEMU_CMD"
    eval "$QEMU_CMD"
    exit 0
else
    # Headless mode: capture output for validation
    TMPFILE=$(mktemp)
    trap "rm -f '$TMPFILE'" EXIT
    
    QEMU_CMD="$QEMU_CMD -nographic -serial mon:stdio -m 512M"
    
    # Use script to give QEMU a PTY (fixes buffering issues)
    script -q "$TMPFILE" bash -c "timeout 20 $QEMU_CMD" || true
fi

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
