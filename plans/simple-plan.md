Absolutely—let’s drop the “builder” entirely and run everything **only on your Mac**. We’ll use the **Android Emulator** (prebuilt system images), not Cuttlefish and not AOSP. We still avoid the JVM/app framework: your code is a **native Rust ELF** started by **Android init** and drawing pixels without an APK.

Below is a tight, _Mitchell‑style_ plan: a few small, visible demos culminating in “we draw our own rectangle” — all from your Mac.

---

## 0) What this plan does (and doesn’t)

**Does:**

- Boots a stock **Android Emulator** system image on macOS.
- Gains root & makes `/system` writable (non‑Play, “default” images allow this).
- Drops a **native Rust binary** (`/system/bin/webosd`) and an **init rc** into `/system/etc/init/` to auto‑start it at boot.
- Draws a rectangle **without** APKs/JVM (either via **fbdev** if present or via a small **native SurfaceFlinger client**).

**Doesn’t:**

- No AOSP checkout, no Cuttlefish, no external builder.
- No Kotlin/Java framework use.

---

## 1) Mac-only dev shell (Nix flake)

> Gives you Rust + NDK + adb. (You can skip Nix if you prefer Homebrew; this just pins versions.)

**`flake.nix` (minimal, mac‑only)**

```nix
{
  description = "webos mac-only dev";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ rust-overlay.overlays.default ]; };
        rust = pkgs.rust-bin.selectLatestStableWith (t: t.default.override {
          targets = [ "x86_64-linux-android" "aarch64-linux-android" ];
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        });
        ndk = pkgs.android-ndk;
      in {
        devShells.default = pkgs.mkShell {
          packages = [ rust pkgs.android-tools ndk pkgs.just pkgs.cmake pkgs.ninja pkgs.pkg-config ];
          ANDROID_NDK_HOME = ndk;
          ANDROID_NDK_ROOT = ndk;
          CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER  =
            "${ndk}/toolchains/llvm/prebuilt/${pkgs.stdenv.hostPlatform.system}/bin/x86_64-linux-android24-clang";
          CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER =
            "${ndk}/toolchains/llvm/prebuilt/${pkgs.stdenv.hostPlatform.system}/bin/aarch64-linux-android24-clang";
        };
      });
}
```

---

## 2) Repo layout (small)

```
webos/
├─ flake.nix
├─ justfile
├─ init/init.webosd.rc
└─ rust/
   ├─ webosd/        # your daemon (ELF); starts at boot; later calls draw()
   │  ├─ Cargo.toml
   │  └─ src/main.rs
   ├─ fb_rect/       # fallback demo: fbdev write (if /dev/graphics/fb0 exists)
   │  ├─ Cargo.toml
   │  └─ src/main.rs
   └─ sf_shim/       # tiny C/C++ shim to create a Surface via SurfaceFlinger
      ├─ Android.mk or CMakeLists.txt
      ├─ include/sf_shim.h
      └─ src/sf_shim.cpp
```

**`justfile`**

```make
# choose the target arch to match the emulator image (arm64 for Apple Silicon image; x86_64 for Intel image)
build-webosd-x86:    cargo build --manifest-path rust/webosd/Cargo.toml --target x86_64-linux-android --release
build-webosd-arm64:  cargo build --manifest-path rust/webosd/Cargo.toml --target aarch64-linux-android --release

build-fb-x86:        cargo build --manifest-path rust/fb_rect/Cargo.toml --target x86_64-linux-android --release
build-fb-arm64:      cargo build --manifest-path rust/fb_rect/Cargo.toml --target aarch64-linux-android --release

# emulator lifecycle (mac)
emu-install:
	yes | sdkmanager "platform-tools" "emulator" "platforms;android-34" \
	"system-images;android-34;default;arm64-v8a" || true
	# If you're on Intel Mac, swap arm64-v8a for x86_64.

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

restart-webosd:
	adb shell "stop webosd || true; start webosd"
	adb logcat -s webosd:* -d | tail -n 50
```

---

## 3) Milestone A — Boot emulator, auto‑start our native daemon (no JVM)

**Steps**

1. `nix develop` (enter shell)
2. `just emu-install && just emu-create && just emu-boot`
3. `just emu-root` (root + disable verity + remount)
4. Build webosd for the emulator arch (see step 5)
5. Detect target arch: `adb shell uname -m` → `aarch64` (Apple Silicon image) or `x86_64`
6. `just install-service-arm64` **or** `just install-service-x86`
7. Verify: `adb logcat -s webosd:*` → you should see “hello from init()”

**`init/init.webosd.rc`**

```rc
on late-init
    start surfaceflinger
    start inputflinger
    start netd

service webosd /system/bin/webosd
    class main
    user system
    group system graphics input inet wakelock
    oneshot

on property:sys.boot_completed=1
    # optional: keep it lean
    stop zygote
    stop system_server
    start webosd
```

**`rust/webosd/src/main.rs`**

```rust
fn main() {
    android_logger::init_once(android_logger::Config::default());
    log::info!("webosd: hello from init()");
    loop { std::thread::sleep(std::time::Duration::from_secs(60)); }
}
```

**Acceptance:** log line prints after boot.

---

## 4) Milestone B — Draw a rectangle (two ways, still no APK)

### Path B1 — **fbdev** (quickest if available)

Some emulator images expose `/dev/graphics/fb0`. If present:

- Stop SF so your writes are visible: `adb shell "setprop ctl.stop surfaceflinger; sleep 1"`
- Build and run `rust/fb_rect` (open `/dev/graphics/fb0`, `mmap`, write ARGB).

If `/dev/graphics/fb0` is **absent**, use Path B2.

### Path B2 — **SurfaceFlinger client surface** (robust & closer to “real”)

- Keep SurfaceFlinger **running**.
- From a native ELF (no APK), create a **SurfaceControl + Surface** via **libgui** and **SurfaceComposerClient**. That’s C++ API; expose a tiny **C shim** your Rust can call to get an `ANativeWindow*` to render into (EGL/wgpu).

**C shim header (`sf_shim.h`)**

```c
#pragma once
#include <android/native_window.h>
#ifdef __cplusplus
extern "C" {
#endif
// Creates a fullscreen Surface and returns an ANativeWindow* you can pass to EGL.
// Returns NULL on failure.
ANativeWindow* sf_create_fullscreen_surface(int width, int height, int* out_format);
#ifdef __cplusplus
}
#endif
```

**C++ impl (sketch: `sf_shim.cpp`)**
(Use `SurfaceComposerClient`, `DisplayToken`, `SurfaceControl`, `BufferQueue`, set layer, show; then `ANativeWindow_fromSurface`.)

Compile with NDK (link `libgui`, `libandroid`, `libui`, `libbinder`), produce `libsf_shim.so`. Push it to `/system/lib64/` (or `/system/lib/` on 32‑bit), `chmod 0644`.

**Rust side (sketch)**

```rust
#[link(name="sf_shim")]
extern "C" {
    fn sf_create_fullscreen_surface(w: i32, h: i32, out_fmt: *mut i32) -> *mut std::ffi::c_void;
}
fn draw_rect_egl() -> anyhow::Result<()> {
    let (w, h) = (1080, 1920); // or query from dumpsys/display later
    let mut fmt = 0i32;
    let win = unsafe { sf_create_fullscreen_surface(w, h, &mut fmt) };
    // Create EGLDisplay/EGLContext from win → glClearColor(...); eglSwapBuffers(...)
    Ok(())
}
```

**Acceptance:** see an orange fullscreen; `adb exec-out screencap -p > out.png` shows it.

> **Why the shim?** The SF client API is C++ (Binder + libgui). The shim keeps your Rust clean and “no APK” while still using the supported path on real devices/emulator.

---

## 5) Next tiny demos (all Mac‑only, no AOSP)

- **Hello‑input:** read `/dev/input/event*`, log taps; toggles rectangle color.
- **Frame pacing:** 60 Hz pacer + “damage only” redraws.
- **Networking:** WSS → mock Nostr relay; print badge on screen.
- **Storage:** write/read `/data/webos/…` JSON.
- **Push daemon:** second ELF keeps sockets, wakes `webosd` over a local socket.
- **wgpu/Vello path:** swap EGL fixed‑function for wgpu; draw rect via pipeline you’ll reuse for Vello.

---

## 6) Guardrails & pitfalls (Mac‑only reality)

- **Emulator image choice matters:** use **non‑Play “default”** images so `adb root`/`remount` works.
- **Arch match:**
  - Apple Silicon: `arm64-v8a` system image → build `aarch64-linux-android`.
  - Intel Mac: `x86_64` system image → build `x86_64-linux-android`.

- **SELinux:** if blocked, `adb shell setenforce 0` during early protos.
- **fbdev may not exist:** that’s why Path B2 (SurfaceFlinger client) is included.
- **No AOSP means no early‑boot changes:** you’re limited to `/system/etc/init/*.rc` and existing services, which is fine for these demos.

---

## 7) What changes later (when you outgrow the emulator)

- **Real Pixels** and **signed images** require AOSP + vendor blobs (different milestone).
- Until then, you can accomplish **all early goals**: boot → init‑started native ELF → draw → input → network → push → simple Nostr/LN demos — **entirely on your Mac**.

---

If you want, I can drop a minimal **sf_shim.cpp** that compiles with the NDK and returns an `ANativeWindow*`, plus a tiny Rust EGL clear example.
