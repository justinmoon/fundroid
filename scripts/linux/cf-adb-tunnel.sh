#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <ssh-user@host> [remote-adb-port]" >&2
  exit 1
fi

REMOTE="$1"
REMOTE_ADB_PORT="${2:-5555}"
LOCAL_PORT="${LOCAL_ADB_PORT:-5555}"

echo "Forwarding localhost:${LOCAL_PORT} -> ${REMOTE}:${REMOTE_ADB_PORT}"
echo "Press Ctrl+C to close the tunnel."

exec ssh -N \
  -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_ADB_PORT}" \
  "${REMOTE}"
