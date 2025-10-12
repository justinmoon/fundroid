#!/usr/bin/env bash
# Sync local overlay to remote builder (per-agent)
# Usage: ./scripts/mac/remote-sync.sh [agent-name]

set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-hetzner}"
AGENT_NAME="${1:-$(git branch --show-current)}"
LOCAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE_OVERLAY_DIR="~/remote-overlays/${AGENT_NAME}"

echo "🔄 Syncing overlay for agent: ${AGENT_NAME}"
echo "   Local:  ${LOCAL_ROOT}"
echo "   Remote: ${REMOTE_HOST}:${REMOTE_OVERLAY_DIR}"

# Create remote directory
ssh "${REMOTE_HOST}" "mkdir -p ${REMOTE_OVERLAY_DIR}"

# Sync overlay files (vendor/, rust/, scripts/)
rsync -avz --delete \
  --exclude='.git' \
  --exclude='target/' \
  --exclude='rust/*/target/' \
  --exclude='*.lock' \
  --exclude='flake.lock' \
  "${LOCAL_ROOT}/vendor/" \
  "${REMOTE_HOST}:${REMOTE_OVERLAY_DIR}/vendor/"

rsync -avz --delete \
  --exclude='target/' \
  "${LOCAL_ROOT}/rust/" \
  "${REMOTE_HOST}:${REMOTE_OVERLAY_DIR}/rust/"

rsync -avz --delete \
  "${LOCAL_ROOT}/scripts/" \
  "${REMOTE_HOST}:${REMOTE_OVERLAY_DIR}/scripts/"

# Sync build config
rsync -avz \
  "${LOCAL_ROOT}/flake.nix" \
  "${LOCAL_ROOT}/justfile" \
  "${REMOTE_HOST}:${REMOTE_OVERLAY_DIR}/"

echo "✅ Sync complete!"
echo ""
echo "Next steps:"
echo "  just remote-build ${AGENT_NAME}"
echo "  just remote-launch ${AGENT_NAME}"
