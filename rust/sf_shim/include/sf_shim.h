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
