The fastest way to “unlock” HAL work is to standardize **one rock‑solid call path** from Rust → Binder (AIDL/HIDL) with tiny C/C++ shims where needed. Here’s a concrete, small‑step sequence that keeps you unblocked, with minimal moving parts and type‑safe wrappers on the Rust side.

---

## Sequence (bite‑sized PRs)

**8.0 — Pick two “easy” HALs + inventory**

* **Target AIDL first**: `android.hardware.vibrator.IVibrator` (small surface, always present on Pixels).
* **Then a HIDL holdout** (if you want coverage): e.g. `android.hardware.memtrack@1.0::IMemtrack`.
* On a Pixel (or emulator), discover the exact *service names* and *service binaries* you’ll need:

  ```sh
  # AIDL services (framework servicemanager)
  service list | sort
  # HIDL services (hwservicemanager)
  lshal | sed -n '1,120p'   # or: lshal -i
  ```

  (You’ll wire equivalent probes into the repo in 8.1–8.2.)

---

**8.1 — Rust → Binder (NDK) “ping” (no IDLs yet)**

* Add a **generic Binder‑NDK C shim** you can call from Rust to prove the stack:

  ```
  rust/hal_shims/common/binder_ndk_shim.{c,h}
  ```

  ```c
  // binder_ndk_shim.h
  #pragma once
  #include <stdbool.h>
  bool binder_ndk_ping(const char* instance); // e.g. "android.hardware.vibrator.IVibrator/default"
  ```

  ```c
  // binder_ndk_shim.c
  #include <android/binder_ibinder.h>
  #include <android/binder_manager.h>
  #include <android/binder_status.h>
  #include <stdbool.h>

  bool binder_ndk_ping(const char* instance) {
      AIBinder* b = AServiceManager_waitForService(instance);
      if (!b) return false;
      binder_status_t st = AIBinder_ping(b);
      AIBinder_decStrong(b);
      return st == STATUS_OK;
  }
  ```
* CMake it next to `sf_shim`:

  ```cmake
  # rust/hal_shims/common/CMakeLists.txt
  add_library(binder_ndk_shim STATIC binder_ndk_shim.c)
  find_library(binder_ndk NAMES binder_ndk REQUIRED)
  target_link_libraries(binder_ndk_shim PRIVATE ${binder_ndk})
  target_include_directories(binder_ndk_shim PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  ```
* Minimal Rust wrapper (type‑safe, zero unsafe outside the FFI boundary):

  ```rust
  // rust/hal_ndk/src/lib.rs
  use std::ffi::CString;
  extern "C" { fn binder_ndk_ping(instance: *const i8) -> bool; }

  pub fn ping(instance: &str) -> bool {
      let c = CString::new(instance).unwrap();
      unsafe { binder_ndk_ping(c.as_ptr()) }
  }
  ```
* CLI to exercise it on‑device (talking to **host /dev/binder** first, not capsule):

  ```rust
  // rust/hal_ndk/src/bin/hal_ping.rs
  fn main() {
      let inst = std::env::args().nth(1)
          .expect("usage: hal_ping <service>");
      println!("{}: {}", &inst, hal_ndk::ping(&inst));
  }
  ```
* Add to `justfile`:

  ```make
  build-hal-ndk:
  	cmake -S rust/hal_shims/common -B target/hal_shims && cmake --build target/hal_shims
  	cargo build --manifest-path rust/hal_ndk/Cargo.toml --target aarch64-linux-android --release
  	cargo build --manifest-path rust/hal_ndk/Cargo.toml --target x86_64-linux-android --release

  hal-ping:
  	adb push rust/hal_ndk/target/$(just detect-arch)-linux-android/release/hal_ping /data/local/tmp/
  	adb shell /data/local/tmp/hal_ping android.hardware.vibrator.IVibrator/default
  ```

*Why this step?* It validates: cross‑compile, deploy, link `libbinder_ndk`, talk to servicemanager, perform a Binder transaction—**without** touching IDL generators yet.

---

**8.2 — AIDL client (typed) via generated NDK stubs + tiny C++ shim**

* Use the SDK `aidl` you already have in the flake (`build-tools-34.0.0`) to generate **NDK C++ client** for the exact interface(s) you want, and *vendor the generated code* (keeps CI deterministic, no mocks).

  ```
  scripts/aidl_gen_vibrator.sh
  ```

  ```sh
  # scripts/aidl_gen_vibrator.sh
  set -euo pipefail
  OUT=rust/hal_shims/vibrator/aidl
  mkdir -p "$OUT"
  aidl --lang=ndk -Weverything \
       -o "$OUT" \
       --include=$ANDROID_SDK_ROOT/platforms/android-34/aidl \
       android/hardware/vibrator/IVibrator.aidl
  ```

  (If the platform AIDL isn’t packaged, copy the .aidl from a matching AOSP tag once and vendor it in `third_party/aidl/`.)
* Wrap the generated proxy with **two C‑ABI functions** you can call from Rust:

  ```cpp
  // rust/hal_shims/vibrator/vibrator_shim.cpp
  #include <android/binder_manager.h>
  #include <android/binder_process.h>
  #include <aidl/android/hardware/vibrator/IVibrator.h>

  using aidl::android::hardware::vibrator::IVibrator;

  extern "C" int vib_get_capabilities(uint64_t* out_caps) {
      ::ndk::SpAIBinder b(AServiceManager_waitForService(
          "android.hardware.vibrator.IVibrator/default"));
      if (!b) return -1;
      std::shared_ptr<IVibrator> vib = IVibrator::fromBinder(b);
      if (!vib) return -2;
      auto st = vib->getCapabilities(out_caps);
      return st.isOk() ? 0 : -3;
  }

  extern "C" int vib_on_ms(int32_t millis) {
      ::ndk::SpAIBinder b(AServiceManager_waitForService(
          "android.hardware.vibrator.IVibrator/default"));
      if (!b) return -1;
      std::shared_ptr<IVibrator> vib = IVibrator::fromBinder(b);
      if (!vib) return -2;
      auto st = vib->on(millis, nullptr); // effect = null => simple timeout
      return st.isOk() ? 0 : -3;
  }
  ```

  ```c
  // rust/hal_shims/vibrator/vibrator_shim.h
  #pragma once
  #include <stdint.h>
  #ifdef __cplusplus
  extern "C" {
  #endif
  int vib_get_capabilities(uint64_t* out_caps);
  int vib_on_ms(int32_t millis);
  #ifdef __cplusplus
  }
  #endif
  ```
* CMake (same pattern as `sf_shim`):

  ```cmake
  # rust/hal_shims/vibrator/CMakeLists.txt
  add_library(vibrator_shim STATIC vibrator_shim.cpp)
  target_include_directories(vibrator_shim PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_include_directories(vibrator_shim PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/aidl)
  find_library(binder_ndk NAMES binder_ndk REQUIRED)
  target_link_libraries(vibrator_shim PRIVATE ${binder_ndk})
  ```
* Safe Rust wrapper with **bitflags**:

  ```rust
  // rust/hal_vibrator/src/lib.rs
  bitflags::bitflags! {
      pub struct Caps: u64 {
          const ON_OFF             = 1 << 0;
          const AMPLITUDE_CONTROL  = 1 << 1;
          const EXTERNAL_CONTROL   = 1 << 2;
          // keep raw-friendly; you can refine once you confirm the mask on-device
      }
  }
  #[link(name="vibrator_shim")]
  extern "C" {
      fn vib_get_capabilities(out: *mut u64) -> i32;
      fn vib_on_ms(ms: i32) -> i32;
  }
  pub fn capabilities() -> anyhow::Result<Caps> {
      let mut raw: u64 = 0;
      let rc = unsafe { vib_get_capabilities(&mut raw as *mut u64) };
      if rc == 0 { Ok(Caps::from_bits_truncate(raw)) } else { anyhow::bail!("vib rc={}", rc) }
  }
  pub fn vibrate(ms: u32) -> anyhow::Result<()> {
      let rc = unsafe { vib_on_ms(ms as i32) };
      if rc == 0 { Ok(()) } else { anyhow::bail!("vib rc={}", rc) }
  }
  ```
* One‑liner test on the device:

  ```rust
  // rust/hal_vibrator/src/bin/vib_demo.rs
  fn main() -> anyhow::Result<()> {
      println!("caps: {:?}", hal_vibrator::capabilities()?);
      hal_vibrator::vibrate(60)?;
      Ok(())
  }
  ```

*Why this step?* You now have a **repeatable recipe**: (1) generate NDK client stubs, (2) compile to a tiny, stable C++ shim, (3) call from Rust with a type‑safe surface.

---

**8.3 — Run the same client inside the capsule**

* Your capsule currently mounts **a fresh binderfs** (private `/dev/binder`), so it won’t see host HALs. Start a HAL *inside* the capsule and point your client at that namespace:

  * Extend `capsule_supervisor.sh` to launch one HAL binary (pick the vibrator service your Pixel provides, usually under `/vendor/bin/hw/…vibrator-service…`):

    ```sh
    # capsule_supervisor.sh (add alongside servicemanager/hwservicemanager)
    ensure_service_running vibrator /vendor/bin/hw/android.hardware.vibrator-service.pixel
    ```
  * Rebuild + push your shim/library **into the capsule** (bind‑mount `/system` & `/vendor` are already there; you just need your client binary under `/usr/local/bin`):

    ```sh
    just build-hal-ndk
    scripts/push_capsule_tools.sh  # or add a similar push for hal clients
    ```
  * Exec the client **via capsule entry** so it hits the capsule binder device:

    ```sh
    scripts/run_capsule.sh start
    adb shell "CAPSULE_BASE=/data/local/tmp/capsule \
               /data/local/tmp/capsule/rootfs/scripts/capsule_entry.sh exec \
               /usr/local/bin/vib_demo"
    ```
* Add a small smoke test:

  ```sh
  # scripts/capsule_hal_smoke.sh
  # 1) wait sys.capsule.ready  2) run vib_demo inside capsule  3) grep rc/logs
  ```

---

**8.4 — Add a HIDL example (same pattern)**

* Generate a tiny **HIDL client** for something simple (memtrack has read‑only calls) using `hidl-gen`, compile into `libmemtrack_shim.so`, and wrap 1–2 methods behind a C ABI:

  * C++: `android::hardware::memtrack::V1_0::IMemtrack::getMemory()`
  * Rust: `hal_memtrack::get_memory(pid) -> Vec<Entry>`
* Purpose: prove you can talk to both **AIDL (new world)** and **HIDL (old world)** from Rust with the same “shim then safe wrapper” pattern.

---

**8.5 — Turn it into a repeatable template**

* Make a **`hal/` template crate** (build script + FFI bindings + bitflags) that any new HAL can copy:

  * `scripts/aidl_codegen <fqname> <outdir>`
  * `rust/hal_<name>/build.rs` links `lib<name>_shim.a`
  * `just hal-add name=vibrator` (scaffold command)

---

**8.6 — Service lifecycle controlled by the supervisor**

* Teach `capsule_supervisor.sh` about a small **TOML manifest** (you already hinted at one) that lists services to start + their binder kind:

  ```toml
  [[service]]
  name = "vibrator"
  kind = "aidl"                # or "hidl"
  cmd  = "/vendor/bin/hw/android.hardware.vibrator-service.pixel"
  health = "binder_ping:android.hardware.vibrator.IVibrator/default"
  ```
* Supervisor loop reads it, ensures the process is up, and flips `sys.capsule.ready` only when *all* health checks pass.

---

## Why this works (and why agents get stuck without it)

* **Avoid generator dead‑ends in Rust:** the official Rust AIDL generator expects AOSP’s `binder` crate; you’re using `rsbinder` today. The **C++ NDK client route** avoids that mismatch and still gives you a type‑safe surface *in Rust* via tiny FFI shims.
* **Keep your Rust clean & type‑safe:** Rust only sees simple FFI like `vib_on_ms(ms)` and wraps it in `bitflags`/`Result`. No C++ in your Rust trees.
* **Capsule isolation:** running HALs in your private binderfs avoids collisions with host services and gives you reproducible tests.

---

## Minimal diffs you can drop in now

**1) `binder_ndk_shim` + Rust ping:**

```c
// rust/hal_shims/common/binder_ndk_shim.h
#pragma once
#include <stdbool.h>
bool binder_ndk_ping(const char* instance);
```

```c
// rust/hal_shims/common/binder_ndk_shim.c
#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <android/binder_status.h>
bool binder_ndk_ping(const char* s){
  AIBinder* b=AServiceManager_waitForService(s);
  if(!b) return false;
  bool ok = AIBinder_ping(b)==STATUS_OK;
  AIBinder_decStrong(b);
  return ok;
}
```

```rust
// rust/hal_ndk/src/lib.rs
extern "C" { fn binder_ndk_ping(instance:*const i8)->bool; }
pub fn ping(name:&str)->bool {
  let s=std::ffi::CString::new(name).unwrap();
  unsafe{ binder_ndk_ping(s.as_ptr()) }
}
```

**2) `vibrator_shim` + Rust wrapper (typed):** see 8.2 snippets.

**3) Supervisor start for one HAL:**

```sh
# android/capsule/rootfs/scripts/capsule_supervisor.sh (snippet)
ensure_service_running vibrator /vendor/bin/hw/android.hardware.vibrator-service.pixel
```

---

## What to do if your target service name differs

Run:

```sh
service list | grep -i vibrator
lshal | grep -i vibrator
```

Use that exact instance string in `AServiceManager_waitForService("<name>")`. Keep the wrapper generic enough that you can pass the instance string from Rust later if needed.

Short answer: the emulator won’t “buzz,” so don’t use “feel vibration” as the success check. Use **binder-level, log-level, and data-level signals** that are unambiguous and scriptable.

Here’s a dead-simple, repeatable way to know it’s working—first on the **host binder**, then inside your **capsule**.

---

## A. If you stick with **Vibrator (AIDL)**

### Clear success signals (host /dev/binder)

1. **Service exists**

```sh
adb shell service list | grep -i 'android.hardware.vibrator.IVibrator'
```

– must print an instance name like `android.hardware.vibrator.IVibrator/default`.

2. **Binder call succeeds**

```sh
# using your hal_ping from earlier
adb shell /data/local/tmp/hal_ping android.hardware.vibrator.IVibrator/default
# → prints: “… true”
adb shell /data/local/tmp/vib_demo
# → exit status 0, prints caps bitmask + returns OK
```

3. **Transaction actually hit the service**
   Two ways (use both if you want belt+braces):

```sh
# Binder stats (look for increasing call counts)
adb shell dumpsys binder calls | grep -i Vibrator || true

# Service logs (many HALs log verbosely)
adb shell setprop log.tag.VibratorService DEBUG
adb logcat -d | grep -i vibrator
```

> If the emulator doesn’t ship a vibrator service (common), (1) will fail. In that case, don’t waste time here—switch to the “memtrack” path below.

### Inside the **capsule**

If you start a vibrator service **inside** the capsule (via `capsule_supervisor.sh`):

```sh
# wait for capsule readiness
adb shell getprop sys.capsule.ready
# run the demo *inside* the capsule’s namespace (hits /dev/binder inside binderfs)
scripts/run_capsule.sh start
adb shell "CAPSULE_BASE=/data/local/tmp/capsule \
  /data/local/tmp/capsule/rootfs/scripts/capsule_entry.sh exec \
  /usr/local/bin/vib_demo"
# success = exit 0; plus check capsule logs:
adb pull /data/local/tmp/capsule/rootfs/run/capsule/capsule-supervisor.log -
```

---

## B. Prefer this for emulator: **Memtrack (HIDL)** — always gives data

Use **memtrack** because the emulator reliably exposes it and it returns **numbers you can assert**.

### Clear success signals

1. **HIDL service is present**

```sh
adb shell lshal | grep -i memtrack
# Expect something like: android.hardware.memtrack@1.0::IMemtrack/default
```

2. **Call returns structured data** (your tiny shim + Rust wrapper)

```sh
# e.g. memtrack_demo <pid> (pid of surfaceflinger or servicemanager)
adb shell pidof surfaceflinger
adb shell /data/local/tmp/memtrack_demo $(adb shell pidof surfaceflinger)
# success = prints N entries with nonzero sizes, exit 0
```

3. **Numbers correlate with another source** (sanity cross-check)

```sh
# Rough check: meminfo for same pid shouldn’t be wildly off
adb shell dumpsys meminfo $(adb shell pidof surfaceflinger) | head -n 30
```

You can wire that into a one-shot smoke test that fails loudly if:

* service missing,
* binder call non-OK,
* returned vector empty,
* or total bytes == 0.

---

## C. Drop-in smoke tests you can add now

### Host binder (choose vibrator **or** memtrack depending on availability)

```sh
# scripts/hal_smoke.sh
set -euo pipefail

want="${1:-auto}"

have_vib="$(adb shell service list | grep -ci 'android.hardware.vibrator.IVibrator')"

if [ "$want" = "vibrator" ] || { [ "$want" = "auto" ] && [ "$have_vib" -gt 0 ]; }; then
  echo "[SMOKE] Vibrator path"
  adb shell /data/local/tmp/hal_ping android.hardware.vibrator.IVibrator/default | grep -q true
  adb shell /data/local/tmp/vib_demo
  adb shell dumpsys binder calls | grep -i Vibrator || true
  echo "[PASS] Vibrator binder call succeeded."
  exit 0
fi

echo "[SMOKE] Memtrack path"
pid="$(adb shell pidof surfaceflinger | tr -d '\r')"
[ -n "$pid" ]
adb shell /data/local/tmp/memtrack_demo "$pid" | tee /dev/stderr | grep -q 'entries:'
echo "[PASS] Memtrack returned entries."
```

### Capsule binder (same idea, runs *inside* your namespace)

```sh
# scripts/capsule_hal_smoke.sh
set -euo pipefail
scripts/run_capsule.sh start > /dev/null
deadline=$((SECONDS+60))
until [ "$(adb shell getprop sys.capsule.ready | tr -d '\r')" = "1" ]; do
  [ $SECONDS -lt $deadline ] || { echo "capsule not ready"; exit 1; }
  sleep 1
done
adb shell "CAPSULE_BASE=/data/local/tmp/capsule \
  /data/local/tmp/capsule/rootfs/scripts/capsule_entry.sh exec /usr/local/bin/memtrack_demo \
  \$(pidof surfaceflinger || echo 1)"  # pick a known pid in-capsule
echo "[PASS] Capsule memtrack call OK."
```

---

## TL;DR recommendation

* On the **emulator**, use **Memtrack (HIDL)** for a crisp “green light” (non-empty numeric result).
* Keep **Vibrator (AIDL)** as your minimal AIDL pathfinder; assert success via **service presence + binder OK + log/binder-stats**, not physical buzz.
* Make both checks scriptable (`hal_smoke.sh` and `capsule_hal_smoke.sh`) so your CI and local runs have **binary-pass** outcomes.

