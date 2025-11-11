#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for deriving per-agent cfctl directories and env vars.

cfctl_agent_init_paths() {
    if [[ $# -lt 1 || -z "$1" ]]; then
        echo "cfctl-agent: missing agent identifier" >&2
        return 1
    fi

    local agent="$1"
    local base_override="${2:-}"
    local cache_root="${CFCTL_AGENT_CACHE_ROOT:-"$HOME/.cache"}"

    if [[ -z "${base_override}" ]]; then
        CFCTL_AGENT_BASE="${CFCTL_AGENT_BASE:-"${cache_root}/cfctl-${agent}"}"
    else
        CFCTL_AGENT_BASE="${base_override}"
    fi

    CFCTL_AGENT_NAME="${agent}"
    CFCTL_SOCKET="${CFCTL_SOCKET:-"${CFCTL_AGENT_BASE}/cfctl.sock"}"
    CFCTL_STATE_DIR="${CFCTL_STATE_DIR:-"${CFCTL_AGENT_BASE}/state"}"
    CFCTL_ETC_DIR="${CFCTL_ETC_DIR:-"${CFCTL_AGENT_BASE}/etc/instances"}"
    CFCTL_CUTTLEFISH_INSTANCES_DIR="${CFCTL_CUTTLEFISH_INSTANCES_DIR:-"${CFCTL_AGENT_BASE}/instances"}"
    CFCTL_CUTTLEFISH_ASSEMBLY_DIR="${CFCTL_CUTTLEFISH_ASSEMBLY_DIR:-"${CFCTL_AGENT_BASE}/assembly"}"
}

cfctl_agent_prepare_dirs() {
    mkdir -p \
        "${CFCTL_AGENT_BASE}" \
        "${CFCTL_STATE_DIR}" \
        "${CFCTL_ETC_DIR}" \
        "${CFCTL_CUTTLEFISH_INSTANCES_DIR}" \
        "${CFCTL_CUTTLEFISH_ASSEMBLY_DIR}"
}

cfctl_agent_emit_env() {
    local format="${1:-plain}"
    local -a keys=(
        CFCTL_AGENT_NAME
        CFCTL_AGENT_BASE
        CFCTL_SOCKET
        CFCTL_STATE_DIR
        CFCTL_ETC_DIR
        CFCTL_CUTTLEFISH_INSTANCES_DIR
        CFCTL_CUTTLEFISH_ASSEMBLY_DIR
    )

    for key in "${keys[@]}"; do
        local value="${!key-}"
        [[ -z "${value}" ]] && continue
        case "${format}" in
            export)
                printf 'export %s=%q\n' "${key}" "${value}"
                ;;
            shell)
                printf '%s=%q\n' "${key}" "${value}"
                ;;
            plain|*)
                printf '%s=%s\n' "${key}" "${value}"
                ;;
        esac
    done
}
