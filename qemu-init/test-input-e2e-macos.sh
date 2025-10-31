#!/usr/bin/env bash
# E2E input test using macOS automation
# Tests full keyboard event path: macOS → QEMU → kernel → compositor → Wayland client

set -euo pipefail

LOG_FILE="/tmp/qemu-e2e-input-test.log"
rm -f "$LOG_FILE"

echo "=========================================="
echo "E2E Input Test (macOS Automation)"
echo "=========================================="
echo ""

echo "Starting QEMU with compositor..."
./run.sh --gui gfx=compositor-rs > "$LOG_FILE" 2>&1 &
QEMU_PID=$!
echo "QEMU PID: $QEMU_PID"

echo "Waiting for compositor to start (10 seconds)..."
sleep 10

# Verify compositor started
if ! grep -q "✓ Opened input device" "$LOG_FILE"; then
    echo "✗ ERROR: Compositor didn't start properly"
    kill $QEMU_PID 2>/dev/null || true
    tail -50 "$LOG_FILE"
    exit 1
fi

echo "✓ Compositor started and input devices opened"
echo ""
echo "Focusing QEMU window and sending keystrokes (h, e, l, l, o)..."

# Use AppleScript to focus window and send keys
osascript <<'EOF'
tell application "System Events"
    -- Find QEMU process
    set qemuProcess to first process whose name contains "qemu-system"
    
    -- Bring to front
    set frontmost of qemuProcess to true
    delay 1
    
    -- Send test keystrokes with delays
    keystroke "h"
    delay 0.3
    keystroke "e"
    delay 0.3
    keystroke "l"
    delay 0.3
    keystroke "l"
    delay 0.3
    keystroke "o"
    delay 1
end tell
EOF

echo "✓ Keystrokes sent"
echo ""
echo "Waiting for events to be processed (3 seconds)..."
sleep 3

echo "Stopping QEMU..."
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo ""
echo "=========================================="
echo "Test Results"
echo "=========================================="
echo ""

# Check for compositor input events
COMPOSITOR_EVENTS=$(grep "\[INPUT\] Key event:" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
echo "Compositor detected: $COMPOSITOR_EVENTS key events"

# Check for client key events  
CLIENT_EVENTS=$(grep "\[client\] ✓ KEY EVENT:" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
echo "Client received: $CLIENT_EVENTS key events"

echo ""

# Show sample events
if [ "$COMPOSITOR_EVENTS" -gt 0 ]; then
    echo "Sample compositor events:"
    grep "\[INPUT\] Key event:" "$LOG_FILE" | head -5 || true
    echo ""
fi

if [ "$CLIENT_EVENTS" -gt 0 ]; then
    echo "Sample client events:"
    grep "\[client\] ✓ KEY EVENT:" "$LOG_FILE" | head -5 || true
    echo ""
fi

# Determine result
if [ "$CLIENT_EVENTS" -ge 5 ]; then
    echo "=========================================="
    echo "✓✓✓ E2E TEST PASSED ✓✓✓"
    echo "=========================================="
    echo "All 5 keystrokes successfully flowed through:"
    echo "  macOS → QEMU → kernel → compositor → Wayland client"
    echo ""
    exit 0
elif [ "$COMPOSITOR_EVENTS" -ge 5 ]; then
    echo "=========================================="
    echo "⚠ PARTIAL PASS"
    echo "=========================================="
    echo "Compositor saw events but client didn't receive them"
    echo "This suggests an issue in Wayland protocol forwarding"
    echo ""
    echo "Full log: $LOG_FILE"
    exit 1
else
    echo "=========================================="
    echo "✗ E2E TEST FAILED"
    echo "=========================================="
    echo "No key events detected in compositor"
    echo ""
    echo "Possible issues:"
    echo "  - Keystrokes not reaching QEMU window"
    echo "  - Input devices not being polled"
    echo "  - Events not being logged"
    echo ""
    echo "Debugging info:"
    echo ""
    grep "Opened input device" "$LOG_FILE" 2>/dev/null || echo "  ✗ No input devices opened"
    grep "keyboard_resource" "$LOG_FILE" 2>/dev/null | head -3 || echo "  (no keyboard resource info)"
    echo ""
    echo "Full log: $LOG_FILE"
    exit 1
fi
