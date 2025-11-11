#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/cfctl-agent-common.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/cfctl-agent.sh [options] <agent> [-- <cfctl-daemon args>]

Launch a cfctl daemon bound to per-agent sockets and state directories.

Options:
  --binary PATH        Use an existing cfctl-daemon binary instead of cargo run.
  --base-dir PATH      Override the base cache dir (default: ~/.cache/cfctl-<agent>).
  -h, --help           Show this help and exit.

Environment overrides:
  CFCTL_AGENT_BINARY   Same as --binary.
  CFCTL_AGENT_BASE     Override the computed cache dir.
  CFCTL_AGENT_CACHE_ROOT  Parent dir for per-agent cache (default: ~/.cache).
  CFCTL_SOCKET / CFCTL_STATE_DIR / CFCTL_ETC_DIR / CFCTL_CUTTLEFISH_*  Use custom paths.

Any arguments after "--" are passed directly to cfctl-daemon.
USAGE
}

agent=""
base_override=""
binary="${CFCTL_AGENT_BINARY:-}"
extra_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary)
            [[ $# -ge 2 ]] || { echo "--binary requires a path" >&2; exit 1; }
            binary="$2"
            shift 2
            ;;
        --base-dir)
            [[ $# -ge 2 ]] || { echo "--base-dir requires a path" >&2; exit 1; }
            base_override="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            extra_args=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "${agent}" ]]; then
                agent="$1"
                shift
            else
                echo "Unexpected positional argument: $1" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "${agent}" ]]; then
    echo "Missing agent identifier." >&2
    usage >&2
    exit 1
fi

cfctl_agent_init_paths "${agent}" "${base_override}"
cfctl_agent_prepare_dirs
mkdir -p "$(dirname "${CFCTL_SOCKET}")"
rm -f "${CFCTL_SOCKET}"

# Persist the resolved environment for quick sourcing.
cfctl_agent_emit_env export > "${CFCTL_AGENT_BASE}/env"

echo "[cfctl-agent] agent: ${CFCTL_AGENT_NAME}"
cfctl_agent_emit_env plain | sed 's/^/[cfctl-agent] /'
echo "[cfctl-agent] launching cfctl-daemon... (Ctrl+C to stop)"

daemon_args=(
    "--socket" "${CFCTL_SOCKET}"
    "--state-dir" "${CFCTL_STATE_DIR}"
    "--etc-instances-dir" "${CFCTL_ETC_DIR}"
    "--cuttlefish-instances-dir" "${CFCTL_CUTTLEFISH_INSTANCES_DIR}"
    "--cuttlefish-assembly-dir" "${CFCTL_CUTTLEFISH_ASSEMBLY_DIR}"
)

if [[ -n "${CFCTL_CUTTLEFISH_SYSTEM_IMAGE_DIR:-}" ]]; then
    daemon_args+=("--cuttlefish-system-image-dir" "${CFCTL_CUTTLEFISH_SYSTEM_IMAGE_DIR}")
fi

runner=()
if [[ -n "${binary}" ]]; then
    runner=("${binary}")
else
    runner=("cargo" "run" "-p" "cfctl" "--bin" "cfctl-daemon" "--")
fi

cd "${REPO_ROOT}"
exec "${runner[@]}" "${daemon_args[@]}" "${extra_args[@]}"
