Love it. Here’s an **updated, Nix‑first plan** that keeps the loop _simple and fast on macOS_, but uses a **Linux builder** (local VM or cheap cloud box) for the AOSP+Cuttlefish parts you’ll need to actually “boot your OS.” It’s divided into:

1. **Repo + flake** scaffolding (Mac dev shell for Rust→Android).
2. **Milestone 1:** boot your own AOSP product in Cuttlefish (on Linux) and start a Rust daemon via `init`.
3. **Milestone 2:** draw a rectangle from that Rust daemon using DRM (no APKs).
4. **Tight dev loop** (Mac ⇄ Linux) and acceptance checks.

You can hand these to coding agents as atomic tasks.

---

## 0) Repo skeleton (with Nix flake)

```
webos/
├─ flake.nix
├─ justfile
├─ README.md
├─ scripts/
│  ├─ mac/dev-adb.sh
│  ├─ linux/aosp-bootstrap.sh
│  ├─ linux/cf-launch.sh
│  ├─ linux/cf-adb-tunnel.sh
│  ├─ linux/aosp-build-webosd.sh
│  └─ linux/aosp-rebuild-image.sh
├─ vendor/
│  └─ webos/                      # AOSP overlay dropped into your AOSP tree
│     ├─ AndroidProducts.mk
│     ├─ webos_cf.mk
│     ├─ init.webosd.rc
│     └─ webosd/
│        ├─ Android.bp
│        └─ src/main.rs
└─ rust/
   ├─ drm_rect/
   │  ├─ Cargo.toml
   │  └─ src/main.rs
   └─ webosd/                     # optional standalone build for local runs
      ├─ Cargo.toml
      └─ src/main.rs
```

### `flake.nix` (macOS dev shell + Linux AOSP shell)

> Pinned toolchains, `adb`, and Android NDK. Rust has **Android std targets baked in** (no rustup).

```nix
{
  description = "webos dev env (macOS + Linux)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ]
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          rustToolchain =
            # Rust with Android std targets baked in
            (pkgs.rust-bin.selectLatestStableWith (toolchain: toolchain.default.override {
              targets = [ "aarch64-linux-android" "x86_64-linux-android" ];
              extensions = [ "rust-src" "clippy" "rustfmt" ];
            }));

          common = with pkgs; [
            rustToolchain
            pkg-config cmake ninja git git-lfs jq unzip zip which
            openssl cacert
            android-tools         # adb/fastboot
            android-ndk           # NDK r26 (path exposed below)
            llvmPackages.clang llvmPackages.lld
            just                  # task runner
          ];
        in {
          devShells = {
            # macOS shell: cross-compile Rust → Android; use 'adb' locally.
            default = pkgs.mkShell {
              packages = common;
              ANDROID_NDK_HOME = pkgs.android-ndk;
              ANDROID_NDK_ROOT = pkgs.android-ndk;
              CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "${pkgs.android-ndk}/toolchains/llvm/prebuilt/${pkgs.stdenv.hostPlatform.system}/bin/aarch64-linux-android24-clang";
              CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER  = "${pkgs.android-ndk}/toolchains/llvm/prebuilt/${pkgs.stdenv.hostPlatform.system}/bin/x86_64-linux-android24-clang";
              shellHook = ''
                echo "✅ webos devshell ready"
                echo "Targets: aarch64-linux-android, x86_64-linux-android"
                just --list 2>/dev/null || true
              '';
            };

            # Linux shell for building AOSP + running Cuttlefish
            aosp = pkgs.mkShell {
              packages = with pkgs; [
                git repo python3 openjdk17 bootstrapTools # repo + JDK
                gperf libxml2 zip unzip rsync curl bc bison flex
                ninja cmake gn ccache file
                android-tools qemu
              ];
              shellHook = ''
                echo "✅ AOSP/Cuttlefish build shell"
                echo "Install/enable KVM+libvirt on the host (outside Nix) before running CF."
              '';
            };
          };
        });
}
```

### `justfile` (one‑liners you’ll actually run)

```make
# macOS (local)
adb-dev := "scripts/mac/dev-adb.sh"

# Build Rust for emulator (x86_64) or device (arm64)
build-x86:    cargo build --manifest-path rust/drm_rect/Cargo.toml --target x86_64-linux-android --release
build-arm64:  cargo build --manifest-path rust/drm_rect/Cargo.toml --target aarch64-linux-android --release

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
aosp-bootstrap: scripts/linux/aosp-bootstrap.sh
aosp-build-webosd: scripts/linux/aosp-build-webosd.sh
cf-launch: scripts/linux/cf-launch.sh
cf-tunnel: scripts/linux/cf-adb-tunnel.sh
aosp-rebuild-image: scripts/linux/aosp-rebuild-image.sh
```

---

## 1) Milestone 1 — Boot **your** AOSP image in Cuttlefish and start a Rust daemon

**Goal:** OS boots, `init` launches your Rust **`webosd`** (no Android framework/zygote).
**Where:** Linux builder (physical or cloud VM with KVM).

### 1.1 Spin up the Linux builder

- Ubuntu 22.04+ with KVM. (Cloud: pick a c2-standard‑8/equivalent; enable nested virt if VM‑in‑VM.)
- Install Nix, enable flakes.
- `git clone` your repo → `nix develop .#aosp`.

### 1.2 Fetch AOSP and lay down your overlay

```bash
# inside nix shell: .#aosp
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://android.googlesource.com/platform/manifest -b android-14.0.0_rXX
repo sync -j$(nproc)

# Drop your overlay into AOSP tree
ln -s $PWD/../webos/vendor/webos vendor/webos
```

### 1.3 Overlay files (already in your repo)

**`vendor/webos/AndroidProducts.mk`**

```make
PRODUCT_MAKEFILES := $(LOCAL_DIR)/webos_cf.mk
```

**`vendor/webos/webos_cf.mk`**

```make
$(call inherit-product, device/google/cuttlefish/vsoc_x86_64/phone/device.mk)

PRODUCT_NAME := webos_cf_x86_64
PRODUCT_DEVICE := vsoc_x86_64
PRODUCT_BRAND := webos
PRODUCT_MODEL := WebOS Dev CF

PRODUCT_PACKAGES += webosd
PRODUCT_COPY_FILES += \
    vendor/webos/init.webosd.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/init.webosd.rc

PRODUCT_PROPERTY_OVERRIDES += ro.webos.noframework=1
```

**`vendor/webos/init.webosd.rc`**

```rc
on late-init
    # keep low-level services; no framework
    stop zygote
    stop system_server
    start surfaceflinger
    start inputflinger
    start netd

service webosd /system/bin/webosd
    class main
    user system
    group system graphics input inet wakelock
    oneshot
    seclabel u:r:system_server:s0

on property:sys.boot_completed=1
    start webosd
```

**`vendor/webos/webosd/Android.bp`**

```python
rust_binary {
    name: "webosd",
    crate_name: "webosd",
    srcs: ["src/main.rs"],
    edition: "2021",
    rustlibs: [ "liblog_rust" ],
}
```

**`vendor/webos/webosd/src/main.rs`**

```rust
fn main() {
    android_logger::init_once(android_logger::Config::default());
    log::info!("webosd: hello from init()");
    loop { std::thread::sleep(std::time::Duration::from_secs(60)); }
}
```

### 1.4 Build & launch Cuttlefish

```bash
source build/envsetup.sh
lunch webos_cf_x86_64-userdebug
m -j$(nproc)

# Start CF
launch_cvd --daemon
adb wait-for-device
adb root && adb shell id
adb logcat -s webosd:*
```

**Acceptance:** you see `webosd: hello from init()` in logcat.
_(You’ve just booted “your OS” image and started your system daemon.)_

### 1.5 Connect from your Mac (optional but nice)

On Linux builder:

```bash
# find CF adb port (often 6520)
ss -ltpn | grep adb
```

On your Mac:

```bash
# tunnel the CF adb to your Mac
ssh -N -L 5555:127.0.0.1:<CF_PORT> user@linux-builder
adb connect localhost:5555
adb devices
```

Now your local `adb` talks to the remote CF—use your Mac dev shell for pushes/tests.

---

## 2) Milestone 2 — Draw a rectangle from the Rust daemon (no APKs)

**Goal:** prove “we can draw.” We’ll do it from `webosd` using **DRM dumb buffer** (preferred), with fbdev fallback if present.

### 2.1 Add DRM code (tiny, self‑contained)

`rust/drm_rect/src/main.rs` (standalone for quick iteration; then fold into `webosd`):

```rust
// sketch: uses ioctls to create a DRM dumb FB and set CRTC
// You can inline a minimal subset or pull in a tiny drm-sys binding.

use std::{fs::File, os::fd::AsRawFd, ptr, slice, thread, time::Duration};
use nix::{fcntl::OFlag, sys::stat::Mode};
use libc::{c_void, mmap, munmap, MAP_SHARED, PROT_READ, PROT_WRITE};

// TODO: define needed DRM ioctls + structs (CREATE_DUMB, MAP_DUMB, ADDFB2, GETRESOURCES, GETCONNECTOR, GETENCODER, SETCRTC)

fn main() {
    // 0) open DRM
    let fd = nix::fcntl::open("/dev/dri/card0", OFlag::O_RDWR, Mode::empty()).expect("open drm");

    // 1) choose a connected connector + mode (query resources)
    // 2) create dumb buffer (w,h, 32bpp), map it, fill orange rect
    // 3) add fb, set crtc to scanout our fb
    // 4) sleep 2s, cleanup fb + destroy dumb

    // (Keep this program self-contained; once verified, port the steps into webosd)
}
```

> This stays short if you hardcode the first connected connector and its preferred mode. Your agent can drop in the 8–10 necessary structs & ioctls.

### 2.2 Fold into `webosd` (AOSP‑built)

Replace `webosd/src/main.rs` with:

```rust
fn main() {
    android_logger::init_once(android_logger::Config::default());
    log::info!("webosd: drawing via DRM");
    if let Err(e) = draw_rect_orange("/dev/dri/card0") {
        log::error!("drm draw failed: {e:?}");
    }
    std::thread::sleep(std::time::Duration::from_secs(3));
}
```

And add a `draw_rect_orange()` from your tested `drm_rect`.

### 2.3 Build, launch, verify

```bash
# inside Linux AOSP shell
source build/envsetup.sh
lunch webos_cf_x86_64-userdebug

# fast inner loop: rebuild only webosd, push into running CF
m webosd
adb root && adb remount
adb push out/target/product/vsoc_x86_64/system/bin/webosd /system/bin/
adb shell stop webosd; adb shell start webosd

# verify
adb logcat -s webosd:*
adb exec-out screencap -p > out.png   # snapshot (CF supports this)
```

**Acceptance:** you see an orange rectangle on the CF display (and in `out.png`).

> If SurfaceFlinger is grabbing the primary CRTC, temporarily stop it in `init.webosd.rc` before drawing:
>
> ```
> on late-init
>     stop surfaceflinger
>     start netd
>     start inputflinger
> ```
>
> (Bring SF back when you move to the “render into an SF layer” demo.)

---

## 3) Tight dev loop (Mac ⇄ Linux) you actually run daily

- **Code Rust on Mac** inside `nix develop`.
  - `just build-x86` for emulator/CF x86_64; `just build-arm64` for Pixels later.

- **Push to CF** via SSH‑forwarded `adb`:
  - `just run-x86` (pushes `/data/local/tmp/drm_rect` or restarts `/system/bin/webosd` if you’re testing the AOSP‑built binary).

- **When `init.rc`/sepolicy change**, rebuild image on Linux:
  - `nix develop .#aosp && just aosp-rebuild-image && just cf-launch`.

**Acceptance gates you’ll track in CI:**

1. **Boot**: log shows `webosd` started by `init`.
2. **Draw**: `adb exec-out screencap -p` contains the expected rectangle (simple PNG diff).

---

## 4) What to do next (still tiny, still Nix‑friendly)

1. **Hello‑input**: in `webosd`, read `/dev/input/event*`, log tap coordinates; acceptance: tapping toggles rectangle color.
2. **Hello‑vsync**: add a 60 Hz frame pacer + damage flag so you draw only when changed.
3. **Hello‑surfaceflinger**: instead of owning the CRTC, create a client surface (libgui FFI) and draw into it—this is your real compositor path.
4. **Hello‑binder**: define `IWebOsCtl` (with `binder-rs`) so a tiny test client can ask `webosd` to change the color—proves IPC.

---

## Why this plan works well with Nix

- You get **reproducible shells** on Mac and Linux with pinned Rust + NDK + adb.
- You keep **AOSP heavy lifting** on Linux where it belongs, but operate it smoothly from Mac via `adb` tunnel.
- Your agents can execute each step in isolation (scripts/just targets) and report artifacts (`out.png`, logs) as proofs.

If you want, I can drop in a **filled‑out DRM dumb‑buffer snippet** (the few ioctls and structs all wired up) so your agent can paste it into `rust/drm_rect`.
