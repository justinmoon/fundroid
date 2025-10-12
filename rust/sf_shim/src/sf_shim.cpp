#include "sf_shim.h"
#include <android/log.h>
#include <gui/ISurfaceComposer.h>
#include <gui/Surface.h>
#include <gui/SurfaceComposerClient.h>
#include <ui/DisplayInfo.h>
#include <ui/DisplayMode.h>

#define LOG_TAG "sf_shim"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

using namespace android;

extern "C" ANativeWindow* sf_create_fullscreen_surface(int width, int height, int* out_format) {
    LOGI("sf_create_fullscreen_surface: starting (requested size: %dx%d)", width, height);

    // Create a connection to SurfaceFlinger
    sp<SurfaceComposerClient> client = new SurfaceComposerClient();
    status_t err = client->initCheck();
    if (err != NO_ERROR) {
        LOGE("SurfaceComposerClient initCheck failed: %d", err);
        return nullptr;
    }
    LOGI("SurfaceComposerClient initialized");

    // Get the default display
    sp<IBinder> display = SurfaceComposerClient::getInternalDisplayToken();
    if (display == nullptr) {
        LOGE("Failed to get internal display token");
        return nullptr;
    }
    LOGI("Got internal display token");

    // Get display info to determine actual screen size
    ui::DisplayMode displayMode;
    err = SurfaceComposerClient::getActiveDisplayMode(display, &displayMode);
    if (err != NO_ERROR) {
        LOGE("Failed to get active display mode: %d", err);
        // Fall back to requested size
    } else {
        width = displayMode.resolution.getWidth();
        height = displayMode.resolution.getHeight();
        LOGI("Display resolution: %dx%d", width, height);
    }

    // Create a surface control
    sp<SurfaceControl> surfaceControl = client->createSurface(
        String8("WebOSSurface"),
        width,
        height,
        PIXEL_FORMAT_RGBX_8888,
        0
    );

    if (surfaceControl == nullptr) {
        LOGE("Failed to create SurfaceControl");
        return nullptr;
    }
    LOGI("SurfaceControl created");

    // Start a transaction to configure the surface
    SurfaceComposerClient::Transaction t;
    t.setLayer(surfaceControl, 0x7FFFFFFF); // Top layer
    t.show(surfaceControl);
    t.apply();
    LOGI("Surface configured and shown");

    // Get the Surface from SurfaceControl
    sp<Surface> surface = surfaceControl->getSurface();
    if (surface == nullptr) {
        LOGE("Failed to get Surface from SurfaceControl");
        return nullptr;
    }
    LOGI("Surface obtained");

    // Get the ANativeWindow interface
    ANativeWindow* window = surface.get();
    if (window == nullptr) {
        LOGE("Failed to get ANativeWindow from Surface");
        return nullptr;
    }

    // Increment reference count since we're returning it
    ANativeWindow_acquire(window);

    if (out_format != nullptr) {
        *out_format = PIXEL_FORMAT_RGBX_8888;
    }

    LOGI("sf_create_fullscreen_surface: success, returning window");
    return window;
}
