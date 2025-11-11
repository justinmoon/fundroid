#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/capture-stock-console.sh [OUTPUT_DIR]

Boots a stock cfctl-lite guest, waits for boot verification, and leaves all
artifacts (cfctl-run.log, console.log, logcat.txt, etc.) in OUTPUT_DIR. If no
directory is provided, logs/stock-console-YYYYmmdd-HHMMSS is used.

Environment variables:
  CFCTL_BIN           Path to the cfctl binary (default: ./cuttlefish/cfctl/target/release/cfctl)
  CFCTL_RUN_AS_ROOT   When set to 1 (default) the command is executed via sudo and
                      --run-as-root is added.
  CFCTL_KEEP_STATE    When set to 1 (default) keep the temporary /tmp/cfctl-run-* dir.
  CFCTL_TIMEOUT_SECS  Override the --timeout-secs flag (default: 300).
  CFCTL_EXTRA_ARGS    Extra flags appended to the cfctl run invocation.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
logs_dir="${1:-logs/stock-console-${timestamp}}"
mkdir -p "${logs_dir}"

cfctl_bin="${CFCTL_BIN:-./cuttlefish/cfctl/target/release/cfctl}"
if [[ ! -x "${cfctl_bin}" ]]; then
  echo "Building cfctl binary at ${cfctl_bin}..." >&2
  cargo build --manifest-path cuttlefish/cfctl/Cargo.toml --bin cfctl --release >/dev/null
fi

timeout_secs="${CFCTL_TIMEOUT_SECS:-300}"
keep_state_flag=()
if [[ "${CFCTL_KEEP_STATE:-1}" == "1" ]]; then
  keep_state_flag=(--keep-state)
fi

run_flags=(
  run
  --logs-dir "${logs_dir}"
  --disable-webrtc
  --verify-boot
  --timeout-secs "${timeout_secs}"
)

if [[ "${CFCTL_RUN_AS_ROOT:-1}" == "1" ]]; then
  run_flags+=(--run-as-root)
  sudo_cmd=(sudo)
else
  sudo_cmd=()
fi

if [[ -n "${CFCTL_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=( ${CFCTL_EXTRA_ARGS} )
else
  extra_args=()
fi

echo "Capturing stock console to ${logs_dir}" >&2
summary_path="${logs_dir}/run-summary.json"
if "${sudo_cmd[@]}" "${cfctl_bin}" \
  "${run_flags[@]}" \
  "${keep_state_flag[@]}" \
  "${extra_args[@]}" \
  | tee "${summary_path}"
then
  echo "cfctl summary saved to ${summary_path}"
else
  echo "cfctl run failed; summary saved to ${summary_path}" >&2
  exit 1
fi

kernel_src=""
if command -v jq >/dev/null 2>&1; then
  kept_state="$(jq -r '.kept_state_dir // ""' "${summary_path}" 2>/dev/null || echo "")"
  if [[ -n "${kept_state}" && -d "${kept_state}" ]]; then
    kernel_src="$(find "${kept_state}" -name kernel.log -print -quit 2>/dev/null || true)"
    if [[ -n "${kernel_src}" && -f "${kernel_src}" ]]; then
      cp "${kernel_src}" "${logs_dir}/kernel.log"
    fi
  fi
else
  kept_state=""
fi

echo "Artifacts:"
echo "  cfctl-run.log : ${logs_dir}/cfctl-run.log"
echo "  console.log   : ${logs_dir}/console.log"
echo "  logcat.txt    : ${logs_dir}/logcat.txt"
if [[ -n "${kept_state}" ]]; then
  echo "  kernel.log    : ${logs_dir}/kernel.log (copied from ${kept_state})"
  echo "  state dir     : ${kept_state}"
else
  echo "  kernel.log    : unavailable (install jq or set CFCTL_KEEP_STATE=1)"
  echo "  state dir     : unknown (install jq to inspect ${summary_path})"
fi
