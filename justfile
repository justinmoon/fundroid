# choose the target arch to match the emulator image (arm64 for Apple Silicon image; x86_64 for Intel image)
build-webosd-x86:
	cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release

build-webosd-arm64:
	cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release

build-fb-x86:
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --release

build-fb-arm64:
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --release

build-capsule-tools:
	cargo build --manifest-path rust/capsule_tools/Cargo.toml --target x86_64-linux-android --release
	cargo build --manifest-path rust/capsule_tools/Cargo.toml --target aarch64-linux-android --release

# Build the SurfaceFlinger shim via CMake
build-sf-shim:
	@if [ -z "${ANDROID_NDK_HOME:-}" ]; then echo "ANDROID_NDK_HOME must be set (try nix develop)"; exit 1; fi
	cmake -S rust/sf_shim -B target/sf_shim \
		-DANDROID_PLATFORM_LIB_DIR="${ANDROID_PLATFORM_LIB_DIR:-}" \
		-DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI="${ANDROID_ABI:-arm64-v8a}" \
		-DANDROID_PLATFORM=android-34
	cmake --build target/sf_shim

# emulator lifecycle (mac)

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
	ABI="${AVD_ABI:-arm64-v8a}"; \
	avdmanager --verbose create avd \
		-n webosd \
		-k "system-images;android-34;default;${ABI}" \
		--abi "${ABI}" \
		--device pixel_6 \
		--force

emu-boot:
	@log_path="${EMULATOR_LOG:-$HOME/.android/webosd-emulator.log}"; \
	mkdir -p "$(dirname "$log_path")"; \
	emu_gpu="${EMULATOR_GPU:-swiftshader_indirect}"; \
	emu_flags="${EMULATOR_FLAGS:-}"; \
	echo "Launching emulator (log: $log_path)..." >&2; \
	emulator @webosd -writable-system -no-snapshot -no-window -gpu "$emu_gpu" -no-boot-anim $emu_flags >"$log_path" 2>&1 &

emu-root:
	adb wait-for-device
	adb root || true
	adb disable-verity || true
	adb reboot
	adb wait-for-device
	adb root || true
	adb remount

capsule-shell:
	@serial="${ANDROID_SERIAL:-}"; \
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
