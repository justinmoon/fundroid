#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

CAPSULE_ARTIFACT_DIR=""
CAPSULE_WATCHDOG_PID=""
CAPSULE_WATCHDOG_STATE_FILE=""
CAPSULE_CLEANED_UP=0

log() {
	printf '%s\n' "$*"
}

run_rust_checks() {
	log "Running clippy checks..."
	cargo clippy --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android -- -D warnings
	cargo clippy --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android -- -D warnings
	cargo clippy --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android -- -D warnings
	cargo clippy --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android -- -D warnings

	log "Building tests..."
	cargo test --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --no-run
	cargo test --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --no-run
	cargo test --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --no-run
	cargo test --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --no-run

	log "Building release binaries..."
	cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release
	cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --release
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --release
}

capsule_job_enabled() {
	case "${CI_ENABLE_CAPSULE:-0}" in
		1|true|TRUE|True) return 0 ;;
		*) return 1 ;;
	esac
}

capsule_ci_cleanup() {
	if [[ "${CAPSULE_CLEANED_UP:-0}" -eq 1 ]]; then
		return
	fi
	CAPSULE_CLEANED_UP=1
	set +e
	stop_capsule_watchdog
	kill_emulator
	collect_capsule_artifacts
	set -e
}

start_capsule_watchdog() {
	local state_file="$1"
	CAPSULE_WATCHDOG_STATE_FILE="$state_file"
	: >"$CAPSULE_WATCHDOG_STATE_FILE"
	(
		local deadline=$(( $(date +%s) + 90 ))
		local serial="${ANDROID_SERIAL:-}"
		local ready=""
		while (( $(date +%s) < deadline )); do
			if [[ -n "$serial" ]]; then
				ready="$(adb -s "$serial" shell getprop sys.capsule.ready 2>/dev/null | tr -d '\r')" || ready=""
			else
				ready="$(adb shell getprop sys.capsule.ready 2>/dev/null | tr -d '\r')" || ready=""
			fi
			if [[ "$ready" == "1" ]]; then
				echo "ready" >"$CAPSULE_WATCHDOG_STATE_FILE"
				exit 0
			fi
			sleep 3
		done
		echo "timeout" >"$CAPSULE_WATCHDOG_STATE_FILE"
		if [[ -n "$serial" ]]; then
			adb -s "$serial" emu kill >/dev/null 2>&1 || true
		else
			adb emu kill >/dev/null 2>&1 || true
		fi
		exit 1
	) &
	CAPSULE_WATCHDOG_PID=$!
}

stop_capsule_watchdog() {
	if [[ -n "${CAPSULE_WATCHDOG_PID:-}" ]]; then
		if kill -0 "$CAPSULE_WATCHDOG_PID" >/dev/null 2>&1; then
			kill "$CAPSULE_WATCHDOG_PID" >/dev/null 2>&1 || true
		fi
		wait "$CAPSULE_WATCHDOG_PID" >/dev/null 2>&1 || true
		unset CAPSULE_WATCHDOG_PID
	fi
}

kill_emulator() {
	if [[ -n "${ANDROID_SERIAL:-}" ]]; then
		adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
	else
		adb emu kill >/dev/null 2>&1 || true
	fi
	rm -f "${REPO_ROOT}/.emulator-pid" >/dev/null 2>&1 || true
}

collect_capsule_artifacts() {
	if [[ -z "$CAPSULE_ARTIFACT_DIR" || ! -d "$CAPSULE_ARTIFACT_DIR" ]]; then
		return
	fi
	local dest_root="${CI_ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"
	local dest="${dest_root}/capsule"
	mkdir -p "$dest"
	if [[ "$dest" == "$CAPSULE_ARTIFACT_DIR" ]]; then
		return
	fi
	cp -a "${CAPSULE_ARTIFACT_DIR}/." "$dest/" >/dev/null 2>&1 || true
}

run_capsule_ci() {
	log "CI capsule job enabled; starting headless emulator..."
	CAPSULE_CLEANED_UP=0
	CAPSULE_ARTIFACT_DIR="${REPO_ROOT}/artifacts/capsule"
	mkdir -p "$CAPSULE_ARTIFACT_DIR"
	rm -f "${CAPSULE_ARTIFACT_DIR}/watchdog-state.txt"

	trap 'capsule_ci_cleanup' EXIT

	export EMULATOR_LOG="${CAPSULE_ARTIFACT_DIR}/emulator.log"
	export EMULATOR_GPU="${EMULATOR_GPU:-swiftshader_indirect}"
	export EMULATOR_FLAGS="${EMULATOR_FLAGS:-}"

	if [ ! -f "${REPO_ROOT}/.avd-name" ]; then
		log "capsule-ci: no branch AVD detected; creating one..."
		just emu-create
	fi

	just emu-boot

	local serial
	if [[ -f "${REPO_ROOT}/.emulator-serial" ]]; then
		serial="$(tr -d '\r\n' < "${REPO_ROOT}/.emulator-serial")"
	fi
	if [[ -z "$serial" ]]; then
		log "capsule-ci: failed to detect emulator serial (expected ${REPO_ROOT}/.emulator-serial)" >&2
		return 1
	fi
	export ANDROID_SERIAL="$serial"

	start_capsule_watchdog "${CAPSULE_ARTIFACT_DIR}/watchdog-state.txt"

	set +e
	just capsule-hello
	local capsule_status=$?
	set -e

	stop_capsule_watchdog
	local watchdog_state=""
	if [[ -n "$CAPSULE_WATCHDOG_STATE_FILE" && -f "$CAPSULE_WATCHDOG_STATE_FILE" ]]; then
		watchdog_state="$(<"$CAPSULE_WATCHDOG_STATE_FILE")"
	fi

	kill_emulator
	collect_capsule_artifacts

	trap - EXIT
	capsule_ci_cleanup

	if [[ "$watchdog_state" == "timeout" ]]; then
		log "capsule-ci: readiness watchdog triggered (capsule did not report ready within 90s)." >&2
		return 1
	fi

	if [[ $capsule_status -ne 0 ]]; then
		log "capsule-ci: capsule-hello failed with status ${capsule_status}." >&2
		return "$capsule_status"
	fi

	log "capsule-ci: capsule-hello succeeded."
	return 0
}

log "Running CI checks..."
run_rust_checks

if capsule_job_enabled; then
	run_capsule_ci
else
	log "CI capsule job disabled (set CI_ENABLE_CAPSULE=1 to enable)."
fi

log "CI completed successfully."
