#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
	echo "ANDROID_SDK_ROOT must be set (enter 'nix develop' first?)" >&2
	exit 1
fi

AIDL_BIN="${AIDL_BIN:-}"
if [[ -z "${AIDL_BIN}" ]]; then
	if command -v aidl >/dev/null 2>&1; then
		AIDL_BIN="$(command -v aidl)"
	elif [[ -x "${ANDROID_SDK_ROOT}/build-tools/34.0.0/aidl" ]]; then
		AIDL_BIN="${ANDROID_SDK_ROOT}/build-tools/34.0.0/aidl"
	else
		echo "aidl tool not found; set AIDL_BIN or ensure it is on PATH" >&2
		exit 1
	fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/rust/hal_shims/vibrator/aidl"
SRC="${ROOT}/third_party/aidl"

rm -rf "${OUT}"
mkdir -p "${OUT}"

"${AIDL_BIN}" \
	--lang=ndk \
	--structured \
	--stability=vintf \
	-Weverything \
	-I"${SRC}" \
	-h "${OUT}" \
	-o "${OUT}" \
	"${SRC}/android/hardware/vibrator/IVibrator.aidl"
