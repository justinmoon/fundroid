set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
	@just --list

ci:
	just fmt-check
	just check

fmt-check:
	cargo fmt --manifest-path rust/drm_rect/Cargo.toml --check
	cargo fmt --manifest-path rust/webosd/Cargo.toml --check

check:
	cargo check --manifest-path rust/drm_rect/Cargo.toml
	cargo check --manifest-path rust/webosd/Cargo.toml

build-x86:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target x86_64-linux-android --release

build-arm64:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target aarch64-linux-android --release

run-x86:
	BIN="target/x86_64-linux-android/release/drm_rect"
	if [ ! -f "$BIN" ]; then
		just build-x86
	fi
	adb push "$BIN" /data/local/tmp/drm_rect
	adb shell chmod +x /data/local/tmp/drm_rect
	adb shell /data/local/tmp/drm_rect

run-arm64:
	BIN="target/aarch64-linux-android/release/drm_rect"
	if [ ! -f "$BIN" ]; then
		just build-arm64
	fi
	adb push "$BIN" /data/local/tmp/drm_rect
	adb shell chmod +x /data/local/tmp/drm_rect
	adb shell /data/local/tmp/drm_rect

aosp-bootstrap:
	./scripts/linux/aosp-bootstrap.sh

cf-launch:
	./scripts/linux/cf-launch.sh

cf-adb-tunnel:
	./scripts/linux/cf-adb-tunnel.sh

aosp-build-webosd:
	./scripts/linux/aosp-build-webosd.sh

aosp-rebuild-image:
	./scripts/linux/aosp-rebuild-image.sh

adb-dev:
	./scripts/mac/dev-adb.sh
