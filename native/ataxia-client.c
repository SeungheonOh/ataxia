/* Exact client access and listener primitives; all identities belong to Lisp. */
#include <stdint.h>
#include <stdlib.h>
#include <wayland-server-core.h>
#include <wlr/version.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_seat.h>
#define EXPORT __attribute__((visibility("default")))

EXPORT const char *ataxia_client_wlroots_version(void) { return WLR_VERSION_STR; }
EXPORT struct wl_client *ataxia_surface_client(struct wlr_surface *surface) {
    return wl_resource_get_client(surface->resource);
}
EXPORT struct wl_client *ataxia_drag_client(struct wlr_drag *drag) {
    return drag->seat_client->client;
}

/* wl_client exposes add_destroy_listener rather than a public wl_signal. */
struct client_listener {
    struct wl_listener listener;
    void (*callback)(uintptr_t, void *);
    uintptr_t cookie;
};
static void client_notify(struct wl_listener *listener, void *data) {
    struct client_listener *cell = wl_container_of(listener, cell, listener);
    cell->callback(cell->cookie, data);
}
EXPORT struct client_listener *ataxia_client_listener_create(struct wl_client *client,
        uintptr_t cookie, void (*callback)(uintptr_t, void *)) {
    struct client_listener *cell = calloc(1, sizeof(*cell));
    if (!cell) return NULL;
    cell->cookie = cookie;
    cell->callback = callback;
    cell->listener.notify = client_notify;
    wl_client_add_destroy_listener(client, &cell->listener);
    return cell;
}
EXPORT void ataxia_client_listener_destroy(struct client_listener *cell) {
    if (!cell) return;
    wl_list_remove(&cell->listener.link);
    free(cell);
}
