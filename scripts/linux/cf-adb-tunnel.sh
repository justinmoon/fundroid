#!/usr/bin/env bash
# Display information about connecting to Cuttlefish via adb
# This script helps find the CF adb port for tunneling

set -euo pipefail

echo "Checking for Cuttlefish adb ports..."
ss -ltpn 2>/dev/null | grep adb || {
    echo "No adb ports found. Is Cuttlefish running?"
    exit 1
}

echo ""
echo "To connect from your Mac:"
echo "  ssh -N -L 5555:127.0.0.1:<CF_PORT> user@this-host"
echo "  adb connect localhost:5555"
echo ""
echo "Or use: ./scripts/mac/dev-adb.sh user@this-host <CF_PORT>"
