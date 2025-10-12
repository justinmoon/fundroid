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

# Multi-agent remote build workflow (macOS)
remote-sync agent=`git branch --show-current`:
	./scripts/mac/remote-sync.sh {{agent}}

remote-build agent=`git branch --show-current`: (remote-sync agent)
	ssh hetzner "cd ~/aosp && nix develop ~/remote-overlays/{{agent}}#aosp --command ~/remote-overlays/{{agent}}/scripts/linux/aosp-build-with-overlay.sh {{agent}}"

remote-launch agent=`git branch --show-current`:
	ssh hetzner "cd ~/aosp && ~/remote-overlays/{{agent}}/scripts/linux/cf-launch.sh {{agent}}"

remote-logs agent=`git branch --show-current`:
	ssh hetzner "adb -s 127.0.0.1:6521 logcat -s webosd:*"

# Linux AOSP (inside `nix develop .#aosp`)
aosp-bootstrap:
	./scripts/linux/aosp-bootstrap.sh

aosp-build-webosd:
	./scripts/linux/aosp-build-webosd.sh

aosp-build-overlay agent:
	./scripts/linux/aosp-build-with-overlay.sh {{agent}}

cf-launch agent="default":
	./scripts/linux/cf-launch.sh {{agent}}

cf-tunnel:
	./scripts/linux/cf-adb-tunnel.sh

aosp-rebuild-image:
	./scripts/linux/aosp-rebuild-image.sh
