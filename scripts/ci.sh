#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CI_CRATES=(
  "rust/webosd"
  "rust/fb_rect"
  "rust/drm_rect"
  "rust/minios_init"
)
CI_TARGETS=("x86_64-linux-android" "aarch64-linux-android")

log() {
  printf '[ci] %s\n' "$*"
}

targets_for() {
  case "$1" in
    rust/minios_init) echo "aarch64-linux-android" ;;
    *) echo "${CI_TARGETS[@]}" ;;
  esac
}

run_fmt() {
  log "Running cargo fmt checks..."
  for crate in "${CI_CRATES[@]}"; do
    cargo fmt --manifest-path "${crate}/Cargo.toml" -- --check
  done
}

run_clippy() {
  log "Running cargo clippy..."
  for crate in "${CI_CRATES[@]}"; do
    for target in $(targets_for "$crate"); do
      cargo clippy --manifest-path "${crate}/Cargo.toml" --target "$target" -- -D warnings
    done
  done
}

run_check() {
  log "Running cargo check/tests (no-run)..."
  for crate in "${CI_CRATES[@]}"; do
    for target in $(targets_for "$crate"); do
      cargo test --manifest-path "${crate}/Cargo.toml" --target "$target" --no-run
    done
  done
}

run_release_builds() {
  log "Building release artifacts..."
  for crate in "${CI_CRATES[@]}"; do
    for target in $(targets_for "$crate"); do
      cargo build --manifest-path "${crate}/Cargo.toml" --target "$target" --release
    done
  done
}

cuttlefish_cmd() {
  local instance="${CI_CUTTLEFISH_INSTANCE:-ci-cuttlefish}"
  local remote_host="${CI_CUTTLEFISH_REMOTE_HOST:-hetzner}"
  CUTTLEFISH_INSTANCE_OVERRIDE="$instance" \
  CUTTLEFISH_REMOTE_HOST="$remote_host" \
    ./scripts/cuttlefish_instance.sh "$@"
}

run_cuttlefish_smoke() {
  local serial="${CI_CUTTLEFISH_SERIAL:-127.0.0.1:6520}"
  local wait_secs="${CI_CUTTLEFISH_WAIT:-30}"
  local init_img="target/os/phase1/init_boot-phase1.img"
  local boot_img="target/os/phase1/boot-phase1.img"

  log "Preparing Cuttlefish instance for smoke test..."
  cuttlefish_cmd stop >/dev/null 2>&1 || true
  cuttlefish_cmd set-env --clear >/dev/null 2>&1 || true
  cuttlefish_cmd start >/dev/null 2>&1
  sleep 10

  log "Building Phase 1 artifacts from running instance..."
  ANDROID_SERIAL="$serial" ./scripts/build_phase1.sh

  log "Deploying Phase 1 artifacts to cuttlefish instance..."
  cuttlefish_cmd deploy --init "$init_img" --boot "$boot_img"
  cuttlefish_cmd restart

  log "Waiting ${wait_secs}s for guest to boot..."
  sleep "$wait_secs"

  local console_tmp journal_tmp
  console_tmp="$(mktemp)"
  journal_tmp="$(mktemp)"
  cuttlefish_cmd console-log >"$console_tmp" 2>/dev/null || true
  cuttlefish_cmd logs >"$journal_tmp" 2>/dev/null || true

  if [[ -n "${CI_ARTIFACTS_DIR:-}" ]]; then
    mkdir -p "${CI_ARTIFACTS_DIR}/cuttlefish"
    cp "$console_tmp" "${CI_ARTIFACTS_DIR}/cuttlefish/console.log"
    cp "$journal_tmp" "${CI_ARTIFACTS_DIR}/cuttlefish/journal.log"
  fi

  if ! grep -qi "minios heartbeat" "$console_tmp"; then
    log "Cuttlefish smoke FAILED (missing heartbeat)."
    log "Captured console log:";
    tail -n 200 "$console_tmp" >&2
    return 1
  fi

  log "Cuttlefish smoke passed (heartbeat detected)."
  return 0
}

main() {
  run_fmt
  run_clippy
  run_check
  run_release_builds
  run_cuttlefish_smoke
  log "CI completed successfully."
}

main "$@"
