# macOS (local) - Build Rust for Android targets
build-x86:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target x86_64-linux-android --release

build-arm64:
	cargo build --manifest-path rust/drm_rect/Cargo.toml --target aarch64-linux-android --release

# Push & run to whatever adb sees
run-x86:
	adb push target/x86_64-linux-android/release/drm_rect /data/local/tmp/
	adb shell chmod +x /data/local/tmp/drm_rect
	adb shell /data/local/tmp/drm_rect

run-arm64:
	adb push target/aarch64-linux-android/release/drm_rect /data/local/tmp/
	adb shell chmod +x /data/local/tmp/drm_rect
	adb shell /data/local/tmp/drm_rect

# Linux AOSP (inside `nix develop .#aosp`)
aosp-bootstrap:
	./scripts/linux/aosp-bootstrap.sh

aosp-build-webosd:
	./scripts/linux/aosp-build-webosd.sh

cf-launch:
	./scripts/linux/cf-launch.sh

cf-tunnel:
	./scripts/linux/cf-adb-tunnel.sh

aosp-rebuild-image:
	./scripts/linux/aosp-rebuild-image.sh
