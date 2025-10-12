#pragma once

#include <android/native_window.h>

#ifdef __cplusplus
extern "C" {
#endif

// Creates (or reuses) a fullscreen Surface managed by SurfaceFlinger and returns
// an ANativeWindow* suitable for EGL interop. Returns NULL on failure.
// If width/height are non-positive the shim will query the active display bounds.
ANativeWindow* sf_create_fullscreen_surface(int width, int height, int* out_format);

#ifdef __cplusplus
}
#endif

