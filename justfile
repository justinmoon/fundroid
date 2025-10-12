# choose the target arch to match the emulator image (arm64 for Apple Silicon image; x86_64 for Intel image)
build-webosd-x86:
	cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release

build-webosd-arm64:
	cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release

build-fb-x86:
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --release

build-fb-arm64:
	cargo build --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --release

# emulator lifecycle (mac)
# Note: SDK components are managed by flake.nix, no need to run emu-install

emu-create:
	avdmanager create avd -n webosd -k "system-images;android-34;default;arm64-v8a" --device pixel_6 || true

emu-boot:
	emulator @webosd -no-snapshot -gpu host -no-boot-anim &

emu-root:
	adb wait-for-device
	adb root || true
	adb disable-verity || true
	adb reboot
	adb wait-for-device
	adb root || true
	adb remount

install-service-x86:
	adb push target/x86_64-linux-android/release/webosd /system/bin/webosd
	adb shell chmod 0755 /system/bin/webosd
	adb push init/init.webosd.rc /system/etc/init/init.webosd.rc
	adb reboot

install-service-arm64:
	adb push target/aarch64-linux-android/release/webosd /system/bin/webosd
	adb shell chmod 0755 /system/bin/webosd
	adb push init/init.webosd.rc /system/etc/init/init.webosd.rc
	adb reboot

# Auto-detect architecture and install service
install-service:
	@arch=$$(adb shell uname -m | tr -d '\r'); \
	case "$$arch" in \
		aarch64) just install-service-arm64 ;; \
		x86_64) just install-service-x86 ;; \
		*) echo "Unsupported arch '$$arch' (expected aarch64 or x86_64)" >&2; exit 2 ;; \
	esac

# Auto-detect architecture, build, and deploy
deploy-webosd:
	@arch=$$(adb shell uname -m | tr -d '\r'); \
	case "$$arch" in \
		aarch64) \
			cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release; \
			output="target/aarch64-linux-android/release/webosd" ;; \
		x86_64) \
			cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release; \
			output="target/x86_64-linux-android/release/webosd" ;; \
		*) echo "Unsupported arch '$$arch' (expected aarch64 or x86_64)" >&2; exit 2 ;; \
	esac; \
	adb push "$$output" /system/bin/webosd; \
	adb shell chmod 0755 /system/bin/webosd; \
	adb push init/init.webosd.rc /system/etc/init/init.webosd.rc; \
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

# CI target
ci:
	nix run .#ci
