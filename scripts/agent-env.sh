#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/cfctl-agent-common.sh"

usage() {
    cat <<'USAGE'
Usage: scripts/agent-env.sh [options] <agent>

Emit environment exports for a per-agent cfctl stack.

Options:
  --plain              Print KEY=value pairs instead of export statements.
  --base-dir PATH      Override cache dir (default: ~/.cache/cfctl-<agent>).
  -h, --help           Show this help and exit.

Typical usage:
  eval "$(scripts/agent-env.sh alfa)"
  CFCTL_SOCKET=... nix develop -c just heartbeat
USAGE
}

agent=""
base_override=""
format="export"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plain)
            format="plain"
            shift
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
cfctl_agent_emit_env "${format}"
