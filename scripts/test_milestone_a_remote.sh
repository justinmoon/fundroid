#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REMOTE_HOST="${REMOTE_HOST:-hetzner}"
REMOTE_DIR="${REMOTE_DIR:-~/boom-remote/mvp-step-three-codex}"

EXCLUDES=(
  '--exclude=.git'
  '--exclude=.direnv'
  '--exclude=.android'
  '--exclude=.android-sdk'
  '--exclude=target'
  '--exclude=rust/webosd/target'
  '--exclude=rust/fb_rect/target'
  '--exclude=rust/sf_shim/target'
  '--exclude=.cache'
)

echo "=== Ensuring remote directory ${REMOTE_HOST}:${REMOTE_DIR} ==="
ssh "$REMOTE_HOST" "mkdir -p ${REMOTE_DIR}"

echo "=== Syncing code to ${REMOTE_HOST}:${REMOTE_DIR} ==="
rsync -avz --delete "${EXCLUDES[@]}" \
  "$PROJECT_DIR/" "${REMOTE_HOST}:${REMOTE_DIR}/"

echo "\n=== Running Milestone A test on ${REMOTE_HOST} ===\n"
ssh "$REMOTE_HOST" "\
  killall -9 emulator qemu-system-aarch64 qemu-system-x86_64 2>/dev/null || true && \\
  sleep 3 && \\
  cd ${REMOTE_DIR} && \\
  nix develop --accept-flake-config -c ./scripts/test_milestone_a.sh 2>&1\
"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo "\n=== Remote test completed successfully ==="
else
  echo "\n=== Remote test failed with exit code $EXIT_CODE ==="
fi

exit $EXIT_CODE
