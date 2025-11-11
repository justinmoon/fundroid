#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEARTBEAT_DIR="$REPO_ROOT/heartbeat-init"
CUTTLEFISH_SCRIPT="$SCRIPT_DIR/cuttlefish_instance.sh"

REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-hetzner}"
REMOTE_CFCTL="${REMOTE_CFCTL:-cfctl}"
INIT_BOOT_SRC="${INIT_BOOT_SRC:-}"
TIMEOUT_BOOT="${TIMEOUT_BOOT:-180}"
TIMEOUT_DESTROY="${TIMEOUT_DESTROY:-60}"
HEARTBEAT_WAIT="${HEARTBEAT_WAIT:-120}"

die() {
    echo "test-heartbeat: ERROR: $*" >&2
    exit 1
}

log() {
    echo "test-heartbeat: $*"
}

cfctl_env_prefix() {
    local prefix=""
    local vars=(
        CFCTL_SOCKET
        CFCTL_STATE_DIR
        CFCTL_ETC_DIR
        CFCTL_CUTTLEFISH_INSTANCES_DIR
        CFCTL_CUTTLEFISH_ASSEMBLY_DIR
        CFCTL_CUTTLEFISH_SYSTEM_IMAGE_DIR
        CFCTL_DEFAULT_BOOT
        CFCTL_DEFAULT_INIT_BOOT
        CFCTL_CUTTLEFISH_FHS
        CFCTL_GUEST_USER
        CFCTL_GUEST_PRIMARY_GROUP
        CFCTL_GUEST_CAPABILITIES
    )
    for key in "${vars[@]}"; do
        local value="${!key:-}"
        [[ -z "$value" ]] && continue
        prefix+=$(printf '%s=%q ' "$key" "$value")
    done
    printf '%s' "$prefix"
}

is_local_host() {
    [[ -z "$REMOTE_HOST" || "$REMOTE_HOST" == "local" || "$REMOTE_HOST" == "localhost" ]]
}

copy_to_host() {
    local src="$1"
    local dst="$2"
    if is_local_host; then
        cp "$src" "$dst"
    else
        scp "$src" "${REMOTE_HOST}:${dst}"
    fi
}

copy_from_host() {
    local src="$1"
    local dst="$2"
    if is_local_host; then
        cp "$src" "$dst"
    else
        scp "${REMOTE_HOST}:${src}" "$dst"
    fi
}

remote_cfctl() {
    local env_prefix cmd args=""
    env_prefix="$(cfctl_env_prefix)"
    cmd="${REMOTE_CFCTL}"
    if [[ -n "$env_prefix" ]]; then
        cmd="${env_prefix}${cmd}"
    fi
    for arg in "$@"; do
        args+=" $(printf '%q' "$arg")"
    done
    if is_local_host; then
        bash -lc "$cmd$args"
    else
        ssh "$REMOTE_HOST" "$cmd$args"
    fi
}

cleanup_instance() {
    local instance="$1"
    if [[ -n "$instance" ]]; then
        log "Cleaning up instance $instance"
        remote_cfctl instance destroy "$instance" --timeout-secs "${TIMEOUT_DESTROY}" || true
    fi
}

main() {
    log "Building heartbeat_init binary..."
    make -C "$HEARTBEAT_DIR" clean all || die "Failed to build heartbeat_init"

    if [[ -z "$INIT_BOOT_SRC" ]]; then
        if [[ -f "$REPO_ROOT/init_boot.stock.img" ]]; then
            INIT_BOOT_SRC="$REPO_ROOT/init_boot.stock.img"
            log "Using existing init_boot.stock.img from repo root"
        elif [[ -f "$REPO_ROOT/init_boot.img" ]]; then
            INIT_BOOT_SRC="$REPO_ROOT/init_boot.img"
            log "Using existing init_boot.img from repo root"
        else
            log "No local init_boot.img found, downloading from Hetzner host..."
            INIT_BOOT_SRC="$REPO_ROOT/init_boot.stock.img"
            copy_from_host "/var/lib/cuttlefish/images/init_boot.img" "$INIT_BOOT_SRC" || \
                die "Failed to obtain stock init_boot.img"
            log "Downloaded stock init_boot.img"
        fi
    fi

    if [[ ! -f "$INIT_BOOT_SRC" ]]; then
        die "Init boot source image not found: $INIT_BOOT_SRC"
    fi

    log "Repacking init_boot.img with heartbeat_init as PID 1..."
    make -C "$HEARTBEAT_DIR" repack \
        INIT_BOOT_SRC="$INIT_BOOT_SRC" \
        INIT_BOOT_OUT="$HEARTBEAT_DIR/init_boot.img" || die "Failed to repack init_boot.img"

    log "Uploading init_boot.img to $REMOTE_HOST..."
    copy_to_host "$HEARTBEAT_DIR/init_boot.img" "/tmp/heartbeat-init_boot.img" || \
        die "Failed to stage init_boot.img on target"

    log "Creating Cuttlefish instance..."
    local instance_name
    instance_name=$(remote_cfctl instance create --purpose heartbeat | grep -oE '[0-9]+' | head -1)
    if [[ -z "$instance_name" ]]; then
        die "Failed to create Cuttlefish instance"
    fi
    log "Created instance: $instance_name"

    trap "cleanup_instance '$instance_name'" EXIT

    log "Deploying heartbeat init_boot.img..."
    remote_cfctl deploy --init /tmp/heartbeat-init_boot.img "$instance_name" || die "Failed to deploy init_boot.img"

    log "Starting Cuttlefish instance (timeout: ${TIMEOUT_BOOT}s)..."
    remote_cfctl instance start "$instance_name" --timeout-secs "${TIMEOUT_BOOT}" || die "Failed to start Cuttlefish instance"

    log "Waiting for boot completion marker (timeout: ${HEARTBEAT_WAIT}s)..."
    local deadline=$(($(date +%s) + HEARTBEAT_WAIT))
    local found=false

    while (( $(date +%s) < deadline )); do
        if remote_cfctl logs "$instance_name" --stdout --lines 200 2>/dev/null | grep -q "VIRTUAL_DEVICE_BOOT_COMPLETED"; then
            log "✓ Found VIRTUAL_DEVICE_BOOT_COMPLETED - system booted successfully"
            found=true
            break
        fi
        sleep 2
    done

    if ! $found; then
        log "Console log contents:"
        remote_cfctl logs "$instance_name" --stdout --lines 200 2>/dev/null || true
        die "Boot completion marker not found within ${HEARTBEAT_WAIT}s"
    fi

    log "Displaying recent console output:"
    remote_cfctl logs "$instance_name" --stdout --lines 30 2>/dev/null || true

    log "✓ SUCCESS: Heartbeat PID1 is running correctly"
    log "Stopping instance..."
    remote_cfctl instance destroy "$instance_name" --timeout-secs "${TIMEOUT_DESTROY}" || true

    log "Test completed successfully!"
}

main "$@"
