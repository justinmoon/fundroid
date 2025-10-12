#!/usr/bin/env bash
# Script to set up adb tunnel from macOS to remote Linux builder running Cuttlefish
# Usage: ./scripts/mac/dev-adb.sh <linux-host> [cf-adb-port]

set -euo pipefail

LINUX_HOST="${1:-}"
CF_PORT="${2:-6520}"

if [ -z "$LINUX_HOST" ]; then
    echo "Usage: $0 <linux-host> [cf-adb-port]"
    echo "Example: $0 user@192.168.1.100 6520"
    exit 1
fi

echo "Setting up adb tunnel to $LINUX_HOST:$CF_PORT -> localhost:5555"
ssh -N -L 5555:127.0.0.1:"$CF_PORT" "$LINUX_HOST" &
SSH_PID=$!

sleep 2

adb connect localhost:5555
adb devices

echo "Tunnel established (PID: $SSH_PID)"
echo "To kill: kill $SSH_PID"
