#!/usr/bin/env bash
set -euo pipefail

if ! command -v adb >/dev/null 2>&1; then
  echo "error: adb not found in PATH. Enter the nix shell or install platform-tools." >&2
  exit 1
fi

adb start-server >/dev/null

if ! adb get-state >/dev/null 2>&1; then
  echo "No device detected. Waiting for a device to appear..."
  adb wait-for-device
fi

adb devices

echo "adb is ready. Use 'just build-x86' followed by 'just run-x86' to push binaries."
