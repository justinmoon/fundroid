# DRM display demo and CI

# Build targets for drm_rect
build-drm-x86:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target x86_64-linux-android --release

build-drm-arm64:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target aarch64-linux-android --release

# Build passthrough init_boot image for demos
demo-build:
	@set -euo pipefail; \
	stock_img=""; \
	if [ -f build/images/init_boot.stock.img ]; then \
		stock_img="build/images/init_boot.stock.img"; \
	elif [ -f build/init_boot_stock.img ]; then \
		stock_img="build/init_boot_stock.img"; \
	else \
		echo "Missing stock init_boot image. Place it at build/images/init_boot.stock.img or build/init_boot_stock.img." >&2; \
		exit 1; \
	fi; \
	key_path=""; \
	if [ -f build/images/cvd_avb_testkey_rsa4096.pem ]; then \
		key_path="build/images/cvd_avb_testkey_rsa4096.pem"; \
	elif [ -f build/cvd_avb_testkey_rsa4096.pem ]; then \
		key_path="build/cvd_avb_testkey_rsa4096.pem"; \
	else \
		echo "Missing AVB test key (build/images/cvd_avb_testkey_rsa4096.pem)." >&2; \
		exit 1; \
	fi; \
	mkdir -p build out/demo; \
	zig cc -target x86_64-linux-musl -static -O2 init/init_wrapper.c -o build/init-wrapper-demo; \
	cd out/demo && \
		unpack_bootimg --boot_img ../../$$stock_img --format=mkbootimg > unpack_info.txt && \
		rm -f ramdisk.uncompressed ramdisk.demo.cpio ramdisk.demo.lz4 && \
		lz4 -d out/ramdisk ramdisk.uncompressed && \
		python3 ../../scripts/cpio_edit.py \
			-i ramdisk.uncompressed \
			-o ramdisk.demo.cpio \
			--rename init=init.stock \
			--add init=../../build/init-wrapper-demo && \
		lz4 -l ramdisk.demo.cpio ramdisk.demo.lz4 && \
		mkbootimg --kernel out/kernel --ramdisk ramdisk.demo.lz4 \
			--header_version 4 --os_version 16.0.0 --os_patch_level 2025-06 \
			--cmdline '' --output ../../build/init_boot_passthrough.img; \
	avbtool add_hash_footer \
		--image build/init_boot_passthrough.img \
		--partition_size 8388608 \
		--partition_name init_boot \
		--algorithm SHA256_RSA4096 \
		--key $$key_path \
		--rollback_index 1749081600; \
	echo "Generated build/init_boot_passthrough.img (signed)."

# Run DRM demo on connected device
run-drm-demo:
	@arch=$$(adb shell uname -m | tr -d '\r'); \
	case "$$arch" in \
		aarch64) \
			cargo build --manifest-path rust/drm_rect/Cargo.toml --target aarch64-linux-android --release; \
			bin_path="rust/drm_rect/target/aarch64-linux-android/release/drm_rect" ;; \
		x86_64) \
			cargo build --manifest-path rust/drm_rect/Cargo.toml --target x86_64-linux-android --release; \
			bin_path="rust/drm_rect/target/x86_64-linux-android/release/drm_rect" ;; \
		*) \
			echo "Unsupported arch '$$arch' (expected aarch64 or x86_64)" >&2; \
			exit 2 ;; \
	esac; \
	adb push "$$bin_path" /data/local/tmp/drm_rect >/dev/null; \
	adb shell su -c 'setenforce 0' >/dev/null 2>&1 || true; \
	adb shell su -c 'setprop ctl.stop surfaceflinger'; \
	adb shell su -c 'setprop ctl.stop vendor.hwcomposer-3'; \
	adb shell su -c '/data/local/tmp/drm_rect'; \
	adb shell su -c 'setprop ctl.start vendor.hwcomposer-3'; \
	adb shell su -c 'setprop ctl.start surfaceflinger'; \
	adb shell su -c 'setenforce 1' >/dev/null 2>&1 || true; \
	adb shell rm /data/local/tmp/drm_rect >/dev/null

# Emulator lifecycle
emu-create:
	@branch="$(git rev-parse --abbrev-ref HEAD | tr -c '[:alnum:]-' '-' | sed 's/-*$//')"; \
	if [ -z "${branch}" ]; then branch="default"; fi; \
	ABI="${AVD_ABI:-arm64-v8a}"; \
	name="drm-demo-${branch}"; \
	echo "Creating AVD '${name}' for branch '${branch}' (ABI=${ABI})"; \
	avdmanager --verbose create avd \
		-n "${name}" \
		-k "system-images;android-34;default;${ABI}" \
		--abi "${ABI}" \
		--device pixel_6 \
		--force; \
	echo "${name}" > .avd-name

emu-boot:
	@name="$(cat .avd-name 2>/dev/null || true)"; \
	if [ -z "${name}" ]; then \
		echo "No .avd-name found; run 'just emu-create' first." >&2; \
		exit 1; \
	fi; \
	log_path="${EMULATOR_LOG:-${HOME}/.android/${name}-emulator.log}"; \
	mkdir -p "$(dirname "${log_path}")"; \
	emu_gpu="${EMULATOR_GPU:-swiftshader_indirect}"; \
	emu_flags="${EMULATOR_FLAGS:-}"; \
	echo "Launching emulator '@${name}' (log: ${log_path})" >&2; \
	before="$(adb devices | awk 'NR>1 {print $1}')"; \
	emulator "@${name}" -writable-system -no-snapshot -no-window -gpu "${emu_gpu}" -no-boot-anim ${emu_flags} >"${log_path}" 2>&1 & \
	echo $! > .emulator-pid; \
	sleep 5; \
	after="$(adb devices | awk 'NR>1 {print $1}')"; \
	serial=""; \
	for candidate in ${after}; do \
		if ! printf '%s\n' "${before}" | grep -qx "${candidate}"; then \
			serial="${candidate}"; \
			break; \
		fi; \
	done; \
	if [ -z "${serial}" ]; then \
		serial="$(adb devices | awk 'NR>1 && $1 ~ /^emulator-/' | tail -n 1)"; \
	fi; \
	if [ -n "${serial}" ]; then \
		printf '%s\n' "${serial}" > .emulator-serial; \
		echo "Emulator serial: ${serial}" >&2; \
	else \
		echo "Error: failed to determine emulator serial; see ${log_path} for details." >&2; \
		pid="$(cat .emulator-pid 2>/dev/null || true)"; \
		if [ -n "${pid}" ]; then \
			kill "${pid}" >/dev/null 2>&1 || true; \
			rm -f .emulator-pid; \
		fi; \
		rm -f .emulator-serial; \
		exit 1; \
	fi

emu-root:
	@serial="${ANDROID_SERIAL:-$(cat .emulator-serial 2>/dev/null || true)}"; \
	if [ -n "${serial}" ]; then \
		export ANDROID_SERIAL="${serial}"; \
		echo "Using emulator serial ${serial}"; \
	fi; \
	adb wait-for-device; \
	adb root || true; \
	adb disable-verity || true; \
	adb reboot; \
	adb wait-for-device; \
	adb root || true; \
	adb remount

emu-stop:
	@pid="$(cat .emulator-pid 2>/dev/null || true)"; \
	serial="${ANDROID_SERIAL:-$(cat .emulator-serial 2>/dev/null || true)}"; \
	if [ -n "${pid}" ]; then \
		if kill -0 "${pid}" >/dev/null 2>&1; then \
			echo "Stopping emulator PID ${pid}"; \
			kill "${pid}"; \
			wait "${pid}" >/dev/null 2>&1 || true; \
		else \
			echo "Stale emulator PID file (process ${pid} not running)"; \
		fi; \
		rm -f .emulator-pid; \
	fi; \
	if [ -n "${serial}" ]; then \
		adb -s "${serial}" emu kill >/dev/null 2>&1 || true; \
	fi

detect-arch:
	@adb shell uname -m | tr -d '\r'

# CI target
ci:
	@set -euo pipefail; hostname="$(hostname -s)"; target="${CUTTLEFISH_LOCAL_HOSTNAME:-hetzner}"; \
	if [ "$$hostname" = "$$target" ]; then \
		nix run .#ci; \
	else \
		CUTTLEFISH_REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-hetzner}" nix run .#ci; \
	fi

ci-remote:
	CUTTLEFISH_REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-hetzner}" nix run .#ci

ci-local:
	CI_SKIP_STOCK_SMOKE=1 nix run .#ci

# Heartbeat PID1 demo
heartbeat-test:
	@scripts/test-heartbeat.sh
