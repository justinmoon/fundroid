#!/usr/bin/env bash
set -euo pipefail

echo "=== Console Snapshot Test ==="
echo ""
echo "This script will:"
echo "1. Create a new cuttlefish instance with boot verification"
echo "2. Check that console_snapshot.log was created"
echo "3. Verify it contains init and SurfaceFlinger messages"
echo "4. Destroy the instance"
echo ""
read -p "Press enter to continue..."

# Create instance with boot verification
echo ""
echo "Creating instance with boot verification..."
INSTANCE_ID=$(cfctl instance create-start --purpose ci --verify-boot 2>&1 | grep -oE 'instance [0-9]+' | grep -oE '[0-9]+' | head -1)

if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: Failed to create instance"
    exit 1
fi

echo "Created instance $INSTANCE_ID"

# Check if console_snapshot.log exists
SNAPSHOT_PATH="/var/lib/cfctl/instances/$INSTANCE_ID/console_snapshot.log"
echo ""
echo "Checking for console snapshot at: $SNAPSHOT_PATH"

if [ ! -f "$SNAPSHOT_PATH" ]; then
    echo "ERROR: Console snapshot not found!"
    echo "Cleaning up instance $INSTANCE_ID..."
    cfctl instance destroy $INSTANCE_ID || true
    exit 1
fi

echo "✓ Console snapshot exists"

# Check for init messages
echo ""
echo "Checking for 'init: starting service' messages..."
INIT_COUNT=$(grep -c "init.*starting service" "$SNAPSHOT_PATH" || echo "0")
echo "  Found $INIT_COUNT init service messages"

if [ "$INIT_COUNT" -eq "0" ]; then
    echo "  WARNING: No init messages found"
else
    echo "  ✓ Sample init messages:"
    grep "init.*starting service" "$SNAPSHOT_PATH" | head -3 | sed 's/^/    /'
fi

# Check for SurfaceFlinger messages
echo ""
echo "Checking for SurfaceFlinger messages..."
SF_COUNT=$(grep -ci "surfaceflinger" "$SNAPSHOT_PATH" || echo "0")
echo "  Found $SF_COUNT SurfaceFlinger messages"

if [ "$SF_COUNT" -eq "0" ]; then
    echo "  WARNING: No SurfaceFlinger messages found"
else
    echo "  ✓ Sample SurfaceFlinger messages:"
    grep -i "surfaceflinger" "$SNAPSHOT_PATH" | head -3 | sed 's/^/    /'
fi

# Summary
echo ""
echo "=== Test Summary ==="
if [ "$INIT_COUNT" -gt "0" ] && [ "$SF_COUNT" -gt "0" ]; then
    echo "✓ SUCCESS: Console snapshot contains both init and SurfaceFlinger messages"
    echo ""
    echo "Console snapshot location: $SNAPSHOT_PATH"
    echo "Total size: $(du -h "$SNAPSHOT_PATH" | cut -f1)"
    RESULT=0
else
    echo "✗ FAILURE: Missing required messages in console snapshot"
    RESULT=1
fi

# Cleanup
echo ""
echo "Cleaning up instance $INSTANCE_ID..."
cfctl instance destroy $INSTANCE_ID --timeout-secs 30 || true

exit $RESULT
