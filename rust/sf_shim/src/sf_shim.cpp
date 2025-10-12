#include "sf_shim.h"

#include <android/native_window.h>
#include <binder/IBinder.h>
#include <binder/ProcessState.h>
#include <gui/DisplayInfo.h>
#include <gui/ISurfaceComposer.h>
#include <gui/ISurfaceComposerClient.h>
#include <gui/Surface.h>
#include <gui/SurfaceComposerClient.h>
#include <gui/SurfaceControl.h>
#include <log/log.h>
#include <system/graphics.h>
#include <ui/Rect.h>
#include <utils/String8.h>
#include <utils/StrongPointer.h>
#include <utils/Errors.h>

#include <cstdint>
#include <limits>
#include <mutex>

using android::ProcessState;
using android::Rect;
using android::sp;
using android::status_t;
using android::Surface;
using android::SurfaceComposerClient;
using android::SurfaceControl;

namespace {
std::mutex g_mutex;
sp<SurfaceComposerClient> g_client;
sp<SurfaceControl> g_surfaceControl;
sp<Surface> g_surface;

struct DisplayMetrics {
    int32_t width;
    int32_t height;
};

DisplayMetrics query_display_metrics() {
    DisplayMetrics metrics{0, 0};
    sp<android::IBinder> display = SurfaceComposerClient::getInternalDisplayToken();
    if (!display) {
        ALOGE("sf_shim: failed to acquire internal display token");
        return metrics;
    }

    android::DisplayInfo info;
    status_t err = SurfaceComposerClient::getDisplayInfo(display, &info);
    if (err != android::NO_ERROR) {
        ALOGE("sf_shim: getDisplayInfo failed: %d", err);
        return metrics;
    }

    metrics.width = info.w;
    metrics.height = info.h;
    return metrics;
}

bool ensure_client() {
    if (g_client) {
        return true;
    }

    ProcessState::self()->startThreadPool();
    g_client = new SurfaceComposerClient();
    if (g_client->initCheck() != android::NO_ERROR) {
        ALOGE("sf_shim: SurfaceComposerClient init failed");
        g_client.clear();
        return false;
    }
    return true;
}
}  // namespace

extern "C" ANativeWindow* sf_create_fullscreen_surface(int width, int height, int* out_format) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (!ensure_client()) {
        return nullptr;
    }

    if (width <= 0 || height <= 0) {
        DisplayMetrics metrics = query_display_metrics();
        width = metrics.width;
        height = metrics.height;
    }

    if (width <= 0 || height <= 0) {
        ALOGE("sf_shim: invalid surface dimensions %dx%d", width, height);
        return nullptr;
    }

    sp<SurfaceControl> control = g_client->createSurface(
        android::String8("webosd-surface"), static_cast<uint32_t>(width),
        static_cast<uint32_t>(height), android::PIXEL_FORMAT_RGBA_8888,
        android::ISurfaceComposerClient::eFXSurfaceBufferState);

    if (!control || !control->isValid()) {
        ALOGE("sf_shim: failed to create SurfaceControl");
        return nullptr;
    }

    SurfaceComposerClient::Transaction txn;
    txn.setLayer(control, std::numeric_limits<int32_t>::max() - 1);
    txn.setBufferSize(control, width, height);
    txn.setCrop(control, Rect(0, 0, width, height));
    txn.show(control);
    txn.apply(true);

    sp<Surface> surface = control->getSurface();
    if (!surface) {
        ALOGE("sf_shim: SurfaceControl->getSurface returned null");
        return nullptr;
    }

    g_surfaceControl = control;
    g_surface = surface;

    if (out_format) {
        *out_format = android::PIXEL_FORMAT_RGBA_8888;
    }

    ANativeWindow* window = surface.get();
    ANativeWindow_acquire(window);
    return window;
}
