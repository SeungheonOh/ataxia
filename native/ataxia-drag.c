/* Additive, version-pinned accessors for wl_data_device drag presentation. */
#include <stdint.h>
#include <wlr/version.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#define EXPORT __attribute__((visibility("default")))
EXPORT const char *ataxia_drag_wlroots_version(void) { return WLR_VERSION_STR; }
EXPORT struct wlr_surface *ataxia_drag_icon_surface(struct wlr_drag *drag) {
    return drag->icon ? drag->icon->surface : NULL;
}
EXPORT void ataxia_surface_commit_offset(struct wlr_surface *surface,
        int32_t *x, int32_t *y) {
    *x = *y = 0;
    if (surface->current.committed & WLR_SURFACE_STATE_OFFSET) {
        *x = surface->current.dx;
        *y = surface->current.dy;
    }
}
