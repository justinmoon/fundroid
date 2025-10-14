#!/usr/bin/env bash

set -euo pipefail

DEFAULT_EMULATOR_LOG="${HOME}/.android/webosd-emulator.log"

log() {
  printf '[milestone-a] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd=$1
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command '$cmd' not found in PATH"
}

tail_emulator_log() {
  local log_path="${EMULATOR_LOG:-$DEFAULT_EMULATOR_LOG}"
  if [[ -f "$log_path" ]]; then
    log "---- emulator log (tail, $log_path) ----"
    tail -n 120 "$log_path" >&2 || true
    log "---- end emulator log ----"
  else
    log "No emulator log found at $log_path"
  fi
}

wait_for_property() {
  local prop=$1
  local expected=$2
  local timeout=${3:-180}

  log "Waiting for $prop to become '$expected' (timeout ${timeout}s)..."
  local elapsed=0
  while (( elapsed < timeout )); do
    local value
    value="$(adb shell getprop "$prop" 2>/dev/null | tr -d '\r')"
    if [[ "$value" == "$expected" ]]; then
      log "$prop is '$value'"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  fail "Timed out waiting for $prop='$expected'"
}

wait_for_emulator_serial() {
  local timeout=${1:-120}
  local elapsed=0
  while (( elapsed < timeout )); do
    local serial
    serial="$(adb devices | awk '/^emulator-[0-9]+\s+(device|offline)$/ { print $1; exit }')"
    if [[ -n "$serial" ]]; then
      echo "$serial"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

require_environment() {
  for var in ANDROID_SDK_ROOT ANDROID_NDK_HOME JAVA_HOME; do
    if [[ -z "${!var:-}" ]]; then
      fail "Environment variable $var is not set. Run 'nix develop' (or otherwise export it) first."
    fi
  done
}

detect_avd_abi() {
  local emulator_path
  emulator_path="$(command -v emulator || true)"
  if [[ -n "$emulator_path" ]]; then
    local file_info
    file_info="$(file "$emulator_path" 2>/dev/null || true)"
    if [[ "$file_info" == *"x86_64"* ]]; then
      echo "x86_64"
      return
    fi
    if [[ "$file_info" == *"arm64"* || "$file_info" == *"aarch64"* ]]; then
      echo "arm64-v8a"
      return
    fi
  fi

  local host_arch
  host_arch="$(uname -m)"
  case "$host_arch" in
    arm64|aarch64)
      echo "arm64-v8a"
      ;;
    x86_64|amd64)
      echo "x86_64"
      ;;
    *)
      log "Warning: unknown host arch '$host_arch', defaulting to arm64-v8a"
      echo "arm64-v8a"
      ;;
  esac
}

ensure_packages_installed() {
  if [[ "${FORCE_SDKMANAGER:-0}" != "0" ]]; then
    log "FORCE_SDKMANAGER set; running just emu-install..."
    just emu-install >/dev/null
    return
  fi

  local expected=(
    "$ANDROID_SDK_ROOT/platform-tools"
    "$ANDROID_SDK_ROOT/platforms/android-34"
    "$ANDROID_SDK_ROOT/system-images/android-34/default/${AVD_ABI:-arm64-v8a}"
  )

  local missing=0
  for path in "${expected[@]}"; do
    if [[ ! -d "$path" ]]; then
      missing=1
      break
    fi
  done

  if (( missing )); then
    log "SDK components missing; running just emu-install..."
    just emu-install >/dev/null
  else
    log "Required SDK components already present; skipping just emu-install."
  fi
}

ensure_avd_exists() {
  local avd_dir="${HOME}/.android/avd/webosd.avd"
  local avd_ini="${HOME}/.android/avd/webosd.ini"
  local target_abi="${AVD_ABI:-arm64-v8a}"
  local needs_create=0
  mkdir -p "${HOME}/.android/avd"

  if [[ -d "$avd_dir" ]]; then
    local config_file="$avd_dir/config.ini"
    local current_abi=""
    if [[ -f "$config_file" ]]; then
      current_abi="$(awk -F= '/^[[:space:]]*abi.type[[:space:]]*=/{
        gsub(/\r/, "", $2);
        gsub(/^[[:space:]]+/, "", $2);
        gsub(/[[:space:]]+$/, "", $2);
        print $2;
        exit
      }' "$config_file" 2>/dev/null)"
    fi
    if [[ "$current_abi" != "$target_abi" ]]; then
      log "Existing AVD uses abi '$current_abi' but '$target_abi' is required; recreating..."
      rm -rf "$avd_dir"
      rm -f "$avd_ini"
      needs_create=1
    else
      log "AVD 'webosd' already exists with expected ABI ($current_abi)"
      return
    fi
  else
    needs_create=1
  fi

  if (( needs_create )); then
    log "Creating AVD 'webosd' with ABI ${target_abi}..."
    just emu-create >/dev/null
    local config_file="$avd_dir/config.ini"
    if [[ ! -f "$config_file" ]]; then
      fail "AVD creation failed; config file not found at $config_file"
    fi
  fi
}

ensure_emulator_running() {
  local started_emulator=0

  if [[ -z "${EMULATOR_GPU:-}" ]]; then
    case "$(uname -s)" in
      Darwin) export EMULATOR_GPU="swiftshader_indirect" ;;
      *) export EMULATOR_GPU="swiftshader_indirect" ;;
    esac
  fi

  if [[ -z "${EMULATOR_FLAGS:-}" ]]; then
    case "$(uname -s)" in
      Linux) export EMULATOR_FLAGS="-no-audio" ;;
      *) export EMULATOR_FLAGS="" ;;
    esac
  fi

  if [[ -z "${EMULATOR_LOG:-}" ]]; then
    export EMULATOR_LOG="$DEFAULT_EMULATOR_LOG"
  fi
  mkdir -p "$(dirname "$EMULATOR_LOG")"

  if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    local existing
    existing="$(adb devices | awk '/^emulator-[0-9]+\s+device$/ { print $1; exit }')"
    if [[ -z "$existing" ]]; then
      log "No running emulator detected. Launching AVD 'webosd'..."
      just emu-boot >&2
      started_emulator=1
    else
      log "Reusing running emulator $existing"
      export ANDROID_SERIAL="$existing"
    fi
  else
    log "Using emulator specified by ANDROID_SERIAL=$ANDROID_SERIAL"
  fi

  if [[ -z "${ANDROID_SERIAL:-}" ]]; then
    local serial
    if ! serial="$(wait_for_emulator_serial 240)"; then
      tail_emulator_log
      local log_path="${EMULATOR_LOG:-$DEFAULT_EMULATOR_LOG}"
      if [[ -f "$log_path" ]]; then
        if grep -q "failed to initialize HVF" "$log_path"; then
          fail "Emulator could not initialize HVF (hardware virtualization). Enable it in macOS Security & Privacy."
        fi
        if grep -q "No accelerator found" "$log_path" || grep -q "failed to initialize HAX" "$log_path"; then
          fail "Emulator reports missing hardware acceleration (KVM/HAX/HVF). Ensure virtualization is available."
        fi
      fi
      fail "Timed out waiting for emulator to appear"
    fi
    export ANDROID_SERIAL="$serial"
    log "Detected emulator $ANDROID_SERIAL"
  fi

  log "Waiting for emulator $ANDROID_SERIAL to become ready..."
  adb -s "$ANDROID_SERIAL" wait-for-device >/dev/null
  wait_for_property "sys.boot_completed" "1" 240

  echo "$started_emulator"
}

verify_service_running() {
  log "Checking that webosd process is running..."
  if ! adb shell ps -A | tr -d '\r' | grep -F "webosd" >/dev/null; then
    fail "webosd process not found via 'ps -A'"
  fi
  log "webosd process is running"
}

verify_log_output() {
  log "Clearing existing webosd logs..."
  adb logcat -c >/dev/null 2>&1 || true

  log "Restarting webosd service to capture fresh logs..."
  adb shell "stop webosd || true" >/dev/null 2>&1 || true
  adb shell "start webosd" >/dev/null

  sleep 2

  log "Collecting log output..."
  local logs
  logs="$(adb logcat -s webosd:* -d)"
  if [[ -z "$logs" ]]; then
    fail "No log output captured from tag 'webosd'"
  fi
  echo "$logs" | tr -d '\r' | grep -E "webosd v[0-9]+\.[0-9]+\.[0-9]+ started \(pid=" >/dev/null || {
    printf '%s\n' "$logs" >&2
    fail "Expected startup log line not found"
  }
  log "Verified expected startup log line:"
  echo "$logs" | tr -d '\r' | grep -E "webosd v[0-9]+\.[0-9]+\.[0-9]+ started \(pid=" >&2
}

main() {
  require_environment

  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    declare -a sdk_tool_dirs=(
      "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin"
      "$ANDROID_SDK_ROOT/cmdline-tools/bin"
      "$ANDROID_SDK_ROOT/emulator"
      "$ANDROID_SDK_ROOT/platform-tools"
      "$ANDROID_SDK_ROOT/tools/bin"
      "$JAVA_HOME/bin"
    )

    if [[ -d "$ANDROID_SDK_ROOT/cmdline-tools" ]]; then
      while IFS= read -r -d '' dir; do
        sdk_tool_dirs+=("$dir/bin")
      done < <(find "$ANDROID_SDK_ROOT/cmdline-tools" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    for tool_dir in "${sdk_tool_dirs[@]}"; do
      if [[ -d "$tool_dir" && ":$PATH:" != *":$tool_dir:"* ]]; then
        export PATH="$tool_dir:$PATH"
      fi
    done
  fi

  require_cmd adb
  require_cmd just
  require_cmd cargo
  require_cmd emulator
  require_cmd avdmanager
  require_cmd sdkmanager

  adb start-server >/dev/null

  local avd_abi
  avd_abi="$(detect_avd_abi)"
  export AVD_ABI="$avd_abi"
  export ANDROID_ABI="$avd_abi"
  log "Using AVD ABI: $avd_abi"

  ensure_packages_installed
  ensure_avd_exists

  local started_emulator
  started_emulator="$(ensure_emulator_running)"

  log "Gaining root access and remounting /system..."
  if ! just emu-root >/dev/null; then
    log "emu-root failed, retrying..."
    sleep 5
    just emu-root >/dev/null || fail "emu-root failed after retry"
  fi
  wait_for_property "sys.boot_completed" "1" 240

  log "Deploying webosd via init service..."
  if ! just deploy-webosd >/dev/null; then
    log "deploy-webosd failed, retrying..."
    sleep 5
    just deploy-webosd >/dev/null || fail "deploy-webosd failed after retry"
  fi
  adb wait-for-device >/dev/null 2>&1 || true
  wait_for_property "sys.boot_completed" "1" 240

  log "Ensuring adb root for post-deploy checks..."
  adb root >/dev/null 2>&1 || true
  adb wait-for-device >/dev/null

  verify_service_running
  verify_log_output

  log "Milestone A verification succeeded."

  if [[ "$started_emulator" == "1" ]]; then
    log "Stopping emulator..."
    if [[ -n "${ANDROID_SERIAL:-}" ]]; then
      adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
    else
      adb emu kill >/dev/null 2>&1 || true
    fi
  fi
}

main "$@"
