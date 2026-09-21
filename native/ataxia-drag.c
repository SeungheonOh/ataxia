/* Additive, version-pinned accessors for wl_data_device drag presentation. */
#include <stdint.h>
#include <string.h>
#include <wlr/version.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_seat.h>
#define EXPORT __attribute__((visibility("default")))
EXPORT const char *ataxia_drag_wlroots_version(void) { return WLR_VERSION_STR; }
EXPORT struct wlr_surface *ataxia_drag_icon_surface(struct wlr_drag *drag) {
    return drag->icon ? drag->icon->surface : NULL;
}

EXPORT bool ataxia_drag_has_mime_type(struct wlr_drag *drag, const char *mime) {
    if (!drag->source) return false;
    char **type;
    wl_array_for_each(type, &drag->source->mime_types) {
        if (strcmp(*type, mime) == 0) return true;
    }
    return false;
}
EXPORT uint32_t ataxia_drag_grab_button(struct wlr_drag *drag) {
    return drag->seat->pointer_state.grab_button;
}
EXPORT bool ataxia_drag_drop_accepted(struct wlr_drag *drag) {
    return drag->focus_client && drag->source &&
        drag->source->current_dnd_action && drag->source->accepted;
}
EXPORT void ataxia_surface_commit_offset(struct wlr_surface *surface,
        int32_t *x, int32_t *y) {
    *x = *y = 0;
    if (surface->current.committed & WLR_SURFACE_STATE_OFFSET) {
        *x = surface->current.dx;
        *y = surface->current.dy;
    }
}
