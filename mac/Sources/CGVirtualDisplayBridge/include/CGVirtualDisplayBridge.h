#ifndef CGVirtualDisplayBridge_h
#define CGVirtualDisplayBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle. Returns NULL when the private API is unavailable or apply fails.
typedef void *MiraVirtualDisplayRef;

MiraVirtualDisplayRef mira_virtual_display_create(
    uint32_t pointWidth,
    uint32_t pointHeight,
    double refreshRate,
    int hiDPI,
    const char *name
);

uint32_t mira_virtual_display_display_id(MiraVirtualDisplayRef display);

void mira_virtual_display_destroy(MiraVirtualDisplayRef display);

#ifdef __cplusplus
}
#endif

#endif /* CGVirtualDisplayBridge_h */