#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST="${WEBOS_REMOTE:-hetzner}"
REMOTE_BASE="${WEBOS_REMOTE_PATH:-webos-remote}"
BRANCH_NAME="${WEBOS_REMOTE_SUFFIX:-$(git rev-parse --abbrev-ref HEAD)}"
if [[ "${BRANCH_NAME}" == "HEAD" ]]; then
  BRANCH_NAME="$(git rev-parse --short HEAD)"
fi
BRANCH_NAME="${BRANCH_NAME//\//-}"
REMOTE_AOSP_ROOT="${WEBOS_REMOTE_AOSP:-/home/justin/aosp}"

if [[ -z "${BRANCH_NAME}" ]]; then
  echo "error: unable to determine branch name for remote build" >&2
  exit 1
fi

REMOTE_DIR="${REMOTE_BASE}/${BRANCH_NAME}"
REMOTE="${REMOTE_HOST}:${REMOTE_DIR}"

ssh "${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR}'"

rsync -av --delete \
  --exclude='.git' \
  --exclude='target' \
  --exclude='out' \
  --exclude='result' \
  --exclude='.direnv' \
  ./ "${REMOTE}/"

ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && env AOSP_ROOT='${REMOTE_AOSP_ROOT}' AOSP_OUT_SUFFIX='${BRANCH_NAME}' nix develop .#aosp --command just aosp-build-webosd"
