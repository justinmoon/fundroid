#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int vib_get_capabilities(uint64_t *out_caps);
int vib_on_ms(int32_t millis);

#ifdef __cplusplus
}
#endif
