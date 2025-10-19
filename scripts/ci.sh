#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CI_CRATES=(
  "rust/drm_rect"
)
CI_TARGETS=("x86_64-linux-android" "aarch64-linux-android")

CFCTL_REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-}" # empty means run locally
CFCTL_INSTANCE_ID=""
SKIP_STOCK_SMOKE=0

if [[ -z "$CFCTL_REMOTE_HOST" ]]; then
  CFCTL_BIN="${CFCTL_BIN:-}"
  if [[ -z "$CFCTL_BIN" ]]; then
    declare -a candidates=()
    if command -v cfctl >/dev/null 2>&1; then
      candidates+=("$(command -v cfctl)")
    fi
    candidates+=(
      "/run/current-system/sw/bin/cfctl"
      "$HOME/.nix-profile/bin/cfctl"
      "/usr/bin/cfctl"
      "$HOME/configs/hetzner/cfctl/target/release/cfctl"
    )
    for candidate in "${candidates[@]}"; do
      if [[ -n "$candidate" && -x "$candidate" ]]; then
        CFCTL_BIN="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$CFCTL_BIN" ]]; then
    if [[ "${CI_SKIP_STOCK_SMOKE:-}" == "1" ]]; then
      SKIP_STOCK_SMOKE=1
      echo "[ci] cfctl not found locally; stock smoke test will be skipped." >&2
    else
      echo "[ci] cfctl binary not found (set CFCTL_BIN, CUTTLEFISH_REMOTE_HOST, or CI_SKIP_STOCK_SMOKE=1)" >&2
      exit 1
    fi
  fi
fi

log() {
  printf '[ci] %s\n' "$*"
}

cleanup() {
  if [[ -n "${CFCTL_INSTANCE_ID:-}" ]]; then
    remote_cfctl instance destroy "$CFCTL_INSTANCE_ID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

remote_cfctl() {
  if [[ -n "$CFCTL_REMOTE_HOST" ]]; then
    ssh "$CFCTL_REMOTE_HOST" cfctl "$@"
  else
    "$CFCTL_BIN" "$@"
  fi
}

copy_to_local() {
  local src="$1" dest="$2"
  if [[ -n "$CFCTL_REMOTE_HOST" ]]; then
    ssh "$CFCTL_REMOTE_HOST" cat "$src" >"$dest" || true
  else
    cat "$src" >"$dest" || true
  fi
}

file_exists() {
  local path="$1"
  if [[ -n "$CFCTL_REMOTE_HOST" ]]; then
    ssh "$CFCTL_REMOTE_HOST" test -f "$path"
  else
    test -f "$path"
  fi
}

targets_for() {
  echo "${CI_TARGETS[@]}"
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

extract_json_field() {
  local json="$1" expression="$2"
  python3 - <<'PY' "$json" "$expression"
import json
import sys

data = json.loads(sys.argv[1] or "null")
expression = sys.argv[2]
value = data
for part in expression.split('.'):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        try:
            idx = int(part)
            value = value[idx]
        except (ValueError, TypeError, IndexError):
            value = None
    if value is None:
        break

if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is None:
    print("")
else:
    print(value)
PY
}

fetch_cfctl_logs() {
  local id="$1"
  local logs_json
  logs_json="$(remote_cfctl logs "$id" --lines 400 2>/dev/null || true)"
  [[ -z "$logs_json" ]] && return

  local journal console_path
  journal="$(extract_json_field "$logs_json" "logs.journal")"
  console_path="$(extract_json_field "$logs_json" "logs.console_log_path")"

  if [[ -n "${CI_ARTIFACTS_DIR:-}" ]]; then
    mkdir -p "${CI_ARTIFACTS_DIR}/cuttlefish"
    [[ -n "$journal" ]] && printf '%s\n' "$journal" > "${CI_ARTIFACTS_DIR}/cuttlefish/journal.log"
    if [[ -n "$console_path" ]] && file_exists "$console_path"; then
      local tmp_console
      tmp_console="$(mktemp)"
      copy_to_local "$console_path" "$tmp_console"
      cp "$tmp_console" "${CI_ARTIFACTS_DIR}/cuttlefish/console.log"
      rm -f "$tmp_console"
    fi
  fi
}

run_cuttlefish_stock_smoke() {
  log "Requesting new cuttlefish instance via cfctl (stock images)..."
  local create_json
  if ! create_json="$(remote_cfctl instance create)"; then
    log "Cuttlefish stock smoke FAILED (instance create)"
    return 1
  fi

  CFCTL_INSTANCE_ID="$(extract_json_field "$create_json" "create.summary.id")"
  local adb_port
  adb_port="$(extract_json_field "$create_json" "create.summary.adb.port")"
  if [[ -z "$CFCTL_INSTANCE_ID" || -z "$adb_port" ]]; then
    log "Cuttlefish stock smoke FAILED (invalid create response)"
    return 1
  fi

  log "Starting cuttlefish @ ${CFCTL_INSTANCE_ID}..."
  if ! remote_cfctl instance start "$CFCTL_INSTANCE_ID"; then
    log "Cuttlefish stock smoke FAILED (start)"
    fetch_cfctl_logs "$CFCTL_INSTANCE_ID"
    return 1
  fi

  log "Waiting for adb on port ${adb_port}..."
  if ! remote_cfctl wait-adb "$CFCTL_INSTANCE_ID" --timeout-secs 180; then
    log "Cuttlefish stock smoke FAILED (wait-adb)"
    fetch_cfctl_logs "$CFCTL_INSTANCE_ID"
    return 1
  fi

  log "Inspecting journal for boot completion..."
  local logs_json journal
  logs_json="$(remote_cfctl logs "$CFCTL_INSTANCE_ID" --lines 400 || true)"
  journal="$(extract_json_field "$logs_json" "logs.journal")"
  if [[ "$journal" != *"VIRTUAL_DEVICE_BOOT_COMPLETED"* ]]; then
    log "Cuttlefish stock smoke FAILED (missing boot completion marker)"
    fetch_cfctl_logs "$CFCTL_INSTANCE_ID"
    return 1
  fi

  fetch_cfctl_logs "$CFCTL_INSTANCE_ID"

  log "Cuttlefish stock smoke passed."
  remote_cfctl instance destroy "$CFCTL_INSTANCE_ID" >/dev/null 2>&1 || true
  CFCTL_INSTANCE_ID=""
  return 0
}

main() {
  run_fmt
  run_clippy
  run_check
  run_release_builds
  if (( SKIP_STOCK_SMOKE )); then
    log "Skipping stock cuttlefish smoke test."
  else
    run_cuttlefish_stock_smoke
  fi
  log "CI completed successfully."
}

main "$@"
