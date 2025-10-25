#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEARTBEAT_DIR="$REPO_ROOT/heartbeat-init"
CUTTLEFISH_SCRIPT="$SCRIPT_DIR/cuttlefish_instance.sh"

REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-hetzner}"
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

cleanup_instance() {
    local instance="$1"
    if [[ -n "$instance" ]]; then
        log "Cleaning up instance $instance"
        ssh "$REMOTE_HOST" "cfctl instance destroy $instance --timeout-secs ${TIMEOUT_DESTROY}" || true
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
            scp "${REMOTE_HOST}:/var/lib/cuttlefish/images/init_boot.img" "$INIT_BOOT_SRC" || \
                die "Failed to download stock init_boot.img from ${REMOTE_HOST}"
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
    scp "$HEARTBEAT_DIR/init_boot.img" "${REMOTE_HOST}:/tmp/heartbeat-init_boot.img" || die "Failed to upload init_boot.img"

    log "Creating Cuttlefish instance..."
    local instance_name
    instance_name=$(ssh "$REMOTE_HOST" "cfctl instance create --purpose heartbeat" | grep -oE '[0-9]+' | head -1)
    if [[ -z "$instance_name" ]]; then
        die "Failed to create Cuttlefish instance"
    fi
    log "Created instance: $instance_name"

    trap "cleanup_instance '$instance_name'" EXIT

    log "Deploying heartbeat init_boot.img..."
    ssh "$REMOTE_HOST" "cfctl deploy --init /tmp/heartbeat-init_boot.img $instance_name" || die "Failed to deploy init_boot.img"

    log "Starting Cuttlefish instance (timeout: ${TIMEOUT_BOOT}s)..."
    ssh "$REMOTE_HOST" "cfctl instance start $instance_name --timeout-secs ${TIMEOUT_BOOT}" || die "Failed to start Cuttlefish instance"

    log "Waiting for boot completion marker (timeout: ${HEARTBEAT_WAIT}s)..."
    local deadline=$(($(date +%s) + HEARTBEAT_WAIT))
    local found=false

    while (( $(date +%s) < deadline )); do
        if ssh "$REMOTE_HOST" "cfctl logs $instance_name --stdout --lines 200" 2>/dev/null | grep -q "VIRTUAL_DEVICE_BOOT_COMPLETED"; then
            log "✓ Found VIRTUAL_DEVICE_BOOT_COMPLETED - system booted successfully"
            found=true
            break
        fi
        sleep 2
    done

    if ! $found; then
        log "Console log contents:"
        ssh "$REMOTE_HOST" "cfctl logs $instance_name --stdout --lines 200" 2>/dev/null || true
        die "Boot completion marker not found within ${HEARTBEAT_WAIT}s"
    fi

    log "Displaying recent console output:"
    ssh "$REMOTE_HOST" "cfctl logs $instance_name --stdout --lines 30" 2>/dev/null || true

    log "✓ SUCCESS: Heartbeat PID1 is running correctly"
    log "Stopping instance..."
    ssh "$REMOTE_HOST" "cfctl instance destroy $instance_name --timeout-secs ${TIMEOUT_DESTROY}" || true

    log "Test completed successfully!"
}

main "$@"
