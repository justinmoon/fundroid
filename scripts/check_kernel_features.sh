#!/usr/bin/env bash
set -euo pipefail

features=(
	CONFIG_ANDROID_BINDERFS
	CONFIG_USER_NS
	CONFIG_PID_NS
)

serial="${ANDROID_SERIAL:-}"
if [ -n "$serial" ]; then
	adb_args=(-s "$serial")
else
	adb_args=()
fi

adb "${adb_args[@]}" wait-for-device >/dev/null

config_tmp="$(mktemp)"
config_source=""
cleanup() {
	rm -f "$config_tmp"
}
trap cleanup EXIT

if adb "${adb_args[@]}" shell 'if [ -r /proc/config.gz ]; then exit 0; else exit 1; fi' >/dev/null 2>&1; then
	config_source="/proc/config.gz"
	adb "${adb_args[@]}" exec-out zcat /proc/config.gz >"$config_tmp"
elif adb "${adb_args[@]}" shell 'if [ -r /boot/config-$(uname -r) ]; then exit 0; else exit 1; fi' >/dev/null 2>&1; then
	config_source="/boot/config-$(adb "${adb_args[@]}" shell uname -r | tr -d '\r')"
	adb "${adb_args[@]}" exec-out "cat /boot/config-\$(uname -r)" >"$config_tmp"
else
	echo "Unable to locate kernel config (tried /proc/config.gz and /boot/config-\$(uname -r))." >&2
	exit 1
fi

echo "Kernel config fetched from ${config_source}"
echo
printf "%-28s RESULT\n" "CONFIG OPTION"
printf "%-28s %s\n" "----------------------------" "------"

for feature in "${features[@]}"; do
	if grep -Eq "^${feature}=(y|m)" "$config_tmp"; then
		printf "%-28s present\n" "$feature"
	else
		printf "%-28s MISSING\n" "$feature"
	fi
done
