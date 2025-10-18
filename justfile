# choose the target arch to match the emulator image (arm64 for Apple Silicon image; x86_64 for Intel image)
build-webosd-x86:
	cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release

build-webosd-arm64:
	cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release

build-fb-x86:
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --release

build-fb-arm64:
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --release

build-drm-x86:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target x86_64-linux-android --release

build-drm-arm64:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target aarch64-linux-android --release

build-phase1:
	./scripts/build_phase1.sh

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

build-capsule-tools:
	cargo build --manifest-path rust/capsule_tools/Cargo.toml --target x86_64-linux-android --release
	cargo build --manifest-path rust/capsule_tools/Cargo.toml --target aarch64-linux-android --release

build-hal-ndk:
	@if [ -z "${ANDROID_NDK_HOME:-}" ]; then echo "ANDROID_NDK_HOME must be set (try nix develop)"; exit 1; fi
	@for abi in arm64-v8a x86_64; do \
		case "$$abi" in \
			arm64-v8a) triple="aarch64-linux-android";; \
			x86_64) triple="x86_64-linux-android";; \
		esac; \
		cmake -S rust/hal_shims/common -B target/hal_shims/$$abi/common \
			-DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
			-DANDROID_ABI=$$abi \
			-DANDROID_PLATFORM=android-34 >/dev/null; \
		cmake --build target/hal_shims/$$abi/common --config Release >/dev/null; \
		mkdir -p target/hal_shims/$$abi; \
		cp target/hal_shims/$$abi/common/libbinder_ndk_shim.a target/hal_shims/$$abi/; \
		cmake -S rust/hal_shims/vibrator -B target/hal_shims/$$abi/vibrator \
			-DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
			-DANDROID_ABI=$$abi \
			-DANDROID_PLATFORM=android-34 >/dev/null; \
		cmake --build target/hal_shims/$$abi/vibrator --config Release >/dev/null; \
		cp target/hal_shims/$$abi/vibrator/libvibrator_shim.a target/hal_shims/$$abi/; \
	done
	HAL_SHIM_BUILD_ROOT=target/hal_shims cargo build --manifest-path rust/hal_ndk/Cargo.toml --target aarch64-linux-android --release
	HAL_SHIM_BUILD_ROOT=target/hal_shims cargo build --manifest-path rust/hal_ndk/Cargo.toml --target x86_64-linux-android --release
	HAL_SHIM_BUILD_ROOT=target/hal_shims cargo build --manifest-path rust/hal_vibrator/Cargo.toml --target aarch64-linux-android --release
	HAL_SHIM_BUILD_ROOT=target/hal_shims cargo build --manifest-path rust/hal_vibrator/Cargo.toml --target x86_64-linux-android --release

hal-ping:
	@if [ -z "${ANDROID_SERIAL:-}" ]; then adb wait-for-device; fi
	adb push rust/hal_ndk/target/$$(just detect-arch)-linux-android/release/hal_ping /data/local/tmp/
	adb shell /data/local/tmp/hal_ping android.hardware.vibrator.IVibrator/default

vib-demo:
	@if [ -z "${ANDROID_SERIAL:-}" ]; then adb wait-for-device; fi
	adb push rust/hal_vibrator/target/$$(just detect-arch)-linux-android/release/vib_demo /data/local/tmp/
	adb shell /data/local/tmp/vib_demo "${DURATION_MS:-60}"

capsule-smoke:
	./scripts/capsule_smoke.sh

capsule-hello:
	./scripts/capsule_hello.sh

hal-smoke:
	./scripts/hal_smoke.sh

capsule-hal-smoke:
	./scripts/capsule_hal_smoke.sh

# Build the SurfaceFlinger shim via CMake
build-sf-shim:
	@if [ -z "${ANDROID_NDK_HOME:-}" ]; then echo "ANDROID_NDK_HOME must be set (try nix develop)"; exit 1; fi
	cmake -S rust/sf_shim -B target/sf_shim \
		-DANDROID_PLATFORM_LIB_DIR="${ANDROID_PLATFORM_LIB_DIR:-}" \
		-DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI="${ANDROID_ABI:-arm64-v8a}" \
		-DANDROID_PLATFORM=android-34
	cmake --build target/sf_shim

# emulator lifecycle (mac, per-worktree AVD)

emu-install:
	@if [ -z "${ANDROID_SDK_ROOT:-}" ]; then \
		echo "ANDROID_SDK_ROOT is not set. Enter the dev shell (nix develop) first."; \
		exit 1; \
	fi
	@if [ ! -x "${ANDROID_SDK_ROOT}/emulator/emulator" ]; then \
		echo "emulator binary not found under $${ANDROID_SDK_ROOT}/emulator"; \
		exit 1; \
	fi
	@echo "Android SDK components are provided by Nix; no additional installation required."
	@echo "emulator binary info:"
	@file "${ANDROID_SDK_ROOT}/emulator/emulator"

emu-create:
	@branch="$(git rev-parse --abbrev-ref HEAD | tr -c '[:alnum:]-' '-' | sed 's/-*$//')"; \
	if [ -z "${branch}" ]; then branch="default"; fi; \
	ABI="${AVD_ABI:-arm64-v8a}"; \
	name="webosd-${branch}"; \
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

emu-status:
	@serial="${ANDROID_SERIAL:-$(cat .emulator-serial 2>/dev/null || true)}"; \
	if [ -z "${serial}" ]; then \
		echo "No emulator serial recorded for this worktree (expecting .emulator-serial)."; \
		exit 0; \
	fi; \
	echo "Worktree emulator serial: ${serial}"; \
	if adb -s "${serial}" shell echo ok >/dev/null 2>&1; then \
		echo "Status: RUNNING"; \
	else \
		echo "Status: offline"; \
	fi; \
	adb -s "${serial}" shell getprop ro.build.fingerprint 2>/dev/null || true

emu-list:
	./scripts/list_branch_emulators.sh

cuttlefish-instance:
	./scripts/cuttlefish_instance.sh instance-name

cuttlefish-set-init init_boot:
	./scripts/cuttlefish_instance.sh set-env --init-boot {{init_boot}}

cuttlefish-set-env boot="" init_boot="":
	@if [ -n "{{boot}}" ]; then \
		cmd_boot="--boot {{boot}}"; \
	else \
		cmd_boot=""; \
	fi; \
	if [ -n "{{init_boot}}" ]; then \
		cmd_init="--init-boot {{init_boot}}"; \
	else \
		cmd_init=""; \
	fi; \
	if [ -z "$cmd_boot$cmd_init" ]; then \
		./scripts/cuttlefish_instance.sh set-env --clear; \
	else \
		./scripts/cuttlefish_instance.sh set-env $cmd_boot $cmd_init; \
	fi

cuttlefish-restart:
	./scripts/cuttlefish_instance.sh restart

cuttlefish-start:
	./scripts/cuttlefish_instance.sh start

cuttlefish-stop:
	./scripts/cuttlefish_instance.sh stop

cuttlefish-status:
	./scripts/cuttlefish_instance.sh status

cuttlefish-logs follow="":
	@if [ -n "{{follow}}" ]; then \
		./scripts/cuttlefish_instance.sh logs --follow; \
	else \
		./scripts/cuttlefish_instance.sh logs; \
	fi

cuttlefish-console follow="":
	@if [ -n "{{follow}}" ]; then \
		./scripts/cuttlefish_instance.sh console-log --follow; \
	else \
		./scripts/cuttlefish_instance.sh console-log; \
	fi

capsule-shell:
	@serial="${ANDROID_SERIAL:-$(cat .emulator-serial 2>/dev/null || true)}"; \
	if [ -n "$serial" ]; then \
		adb -s "$serial" wait-for-device; \
	else \
		adb wait-for-device; \
	fi; \
	if ! { \
		if [ -n "$serial" ]; then \
			adb -s "$serial" root >/dev/null 2>&1; \
		else \
			adb root >/dev/null 2>&1; \
		fi; \
	}; then \
		echo "Failed to acquire root shell; run 'just emu-root' first."; \
		exit 1; \
	fi; \
	if [ -n "$serial" ]; then \
		adb -s "$serial" wait-for-device; \
	else \
		adb wait-for-device; \
	fi; \
	echo "Opening root adb shell (ctrl-d to exit)..." >&2; \
	if [ -n "$serial" ]; then \
		adb -s "$serial" shell; \
	else \
		adb shell; \
	fi

detect-arch:
	@adb shell uname -m | tr -d '\r'

install-service-x86:
	adb push rust/webosd/target/x86_64-linux-android/release/webosd /system/bin/webosd
	adb shell chmod 0755 /system/bin/webosd
	adb push init/init.webosd.rc /system/etc/init/init.webosd.rc
	adb reboot

install-service-arm64:
	adb push rust/webosd/target/aarch64-linux-android/release/webosd /system/bin/webosd
	adb shell chmod 0755 /system/bin/webosd
	adb push init/init.webosd.rc /system/etc/init/init.webosd.rc
	adb reboot

# Auto-detect architecture and install service
install-service:
	@arch=$(adb shell uname -m | tr -d '\r'); \
	case "$arch" in \
		aarch64) just install-service-arm64 ;; \
		x86_64) just install-service-x86 ;; \
		*) echo "Unsupported arch '$arch' (expected aarch64 or x86_64)" >&2; exit 2 ;; \
	esac

# Auto-detect architecture, build, and deploy
deploy-webosd:
	@arch=$(adb shell uname -m | tr -d '\r'); \
	case "$arch" in \
		aarch64) \
			cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release; \
			output="rust/webosd/target/aarch64-linux-android/release/webosd" ;; \
		x86_64) \
			cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release; \
			output="rust/webosd/target/x86_64-linux-android/release/webosd" ;; \
		*) echo "Unsupported arch '$arch' (expected aarch64 or x86_64)" >&2; exit 2 ;; \
	esac; \
	adb wait-for-device; \
	adb push "$output" /system/bin/webosd || { \
		echo "Initial push failed, retrying after wait..." >&2; \
		sleep 2; \
		adb wait-for-device; \
		adb push "$output" /system/bin/webosd; \
	}; \
	adb shell chmod 0755 /system/bin/webosd; \
	adb push init/init.webosd.rc /system/etc/init/init.webosd.rc || { \
		echo "Initial rc push failed, retrying after wait..." >&2; \
		sleep 2; \
		adb wait-for-device; \
		adb push init/init.webosd.rc /system/etc/init/init.webosd.rc; \
	}; \
	adb reboot; \
	adb wait-for-device

restart-webosd:
	adb shell "stop webosd || true; start webosd"
	adb logcat -s webosd:* -d | tail -n 50

stop-webosd:
	adb shell "stop webosd || true"

start-webosd:
	adb shell "start webosd"

logs-webosd:
	adb logcat -s webosd:*

verify-milestone-a:
	./scripts/test_milestone_a.sh

verify-milestone-a-remote:
	./scripts/test_milestone_a_remote.sh

# CI target
ci:
	nix run .#ci
