#!/usr/bin/env bash
# List branch/worktree specific emulator mappings to help avoid conflicts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMON_GIT_DIR="$(cd "$WORKTREE_ROOT" && git rev-parse --git-common-dir)"
REPO_ROOT="$(cd "$COMMON_GIT_DIR/.." && pwd)"
WORKTREES_DIR="${REPO_ROOT}/worktrees"

printf '=== Branch / Worktree Emulators ===\n\n'

current_serial=""
if [ -f "${WORKTREE_ROOT}/.emulator-serial" ]; then
	current_serial="$(tr -d '\r\n' < "${WORKTREE_ROOT}/.emulator-serial")"
fi

list_entry() {
	local location="$1"
	local root="$2"
	local marker=""
	local serial_file="${root}/.emulator-serial"
	local avd_file="${root}/.avd-name"

	if [ ! -f "$serial_file" ]; then
		return
	fi

	local serial
	serial="$(tr -d '\r\n' < "$serial_file")"
	if [ -z "$serial" ]; then
		return
	fi

	if [ "$serial" = "$current_serial" ] && [ -n "$serial" ]; then
		marker=" ← current worktree"
	fi

	local status="offline"
	if adb -s "$serial" shell echo ok >/dev/null 2>&1; then
		status="RUNNING"
	fi

	local avd="unknown"
	if [ -f "$avd_file" ]; then
		avd="$(tr -d '\r\n' < "$avd_file")"
	fi

	printf '%-20s  %-35s  %-12s  %s%s\n' "$serial" "$location" "[$status]" "$avd" "$marker"
}

# Main checkout (if any tracking files exist)
list_entry "main" "$REPO_ROOT"

# All named worktrees
if [ -d "$WORKTREES_DIR" ]; then
	for worktree in "$WORKTREES_DIR"/*; do
		[ -d "$worktree" ] || continue
		list_entry "$(basename "$worktree")" "$worktree"
	done
fi

printf '\nRaw adb devices:\n'
adb devices
