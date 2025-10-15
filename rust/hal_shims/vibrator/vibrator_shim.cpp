#include "vibrator_shim.h"

#include <android/binder_manager.h>
#include <aidl/android/hardware/vibrator/IVibrator.h>
#include <cerrno>
#include <cstdint>
#include <memory>

using aidl::android::hardware::vibrator::IVibrator;

namespace {
constexpr const char* kDefaultInstance =
    "android.hardware.vibrator.IVibrator/default";

std::shared_ptr<IVibrator> get_vibrator() {
  ::ndk::SpAIBinder binder(AServiceManager_waitForService(kDefaultInstance));
  if (!binder) {
    return nullptr;
  }
  return IVibrator::fromBinder(binder);
}
} // namespace

int vib_get_capabilities(uint64_t* out_caps) {
  if (out_caps == nullptr) {
    return -EINVAL;
  }

  const auto vib = get_vibrator();
  if (!vib) {
    return -1;
  }

  int32_t capabilities = 0;
  const ::ndk::ScopedAStatus status = vib->getCapabilities(&capabilities);
  if (!status.isOk()) {
    return -3;
  }

  *out_caps = static_cast<uint64_t>(static_cast<uint32_t>(capabilities));
  return 0;
}

int vib_on_ms(int32_t millis) {
  if (millis < 0) {
    return -EINVAL;
  }

  const auto vib = get_vibrator();
  if (!vib) {
    return -1;
  }

  const ::ndk::ScopedAStatus status = vib->on(millis, nullptr);
  return status.isOk() ? 0 : -3;
}
