/*
 * Ataxia wlroots ABI glue implementation.
 *
 * Every function maps directly to a wlroots/libwayland object field or
 * listener primitive. Higher-level ownership and policy remain in Lisp.
 */

#include "ataxia-wlr-glue.h"

#include <stdlib.h>

#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_output.h>
#include <wlr/version.h>

struct ataxia_listener {
	struct wl_listener listener;
	ataxia_listener_callback callback;
	uintptr_t cookie;
	bool attached;
};

static void listener_notify(struct wl_listener *listener, void *data) {
	struct ataxia_listener *ataxia_listener =
		wl_container_of(listener, ataxia_listener, listener);
	ataxia_listener->callback(ataxia_listener->cookie, data);
}

uint32_t ataxia_wlr_glue_abi_version(void) {
	return ATAXIA_WLR_GLUE_ABI_VERSION;
}

const char *ataxia_wlr_glue_wlroots_version(void) {
	return WLR_VERSION_STR;
}

struct ataxia_listener *ataxia_listener_create(uintptr_t cookie,
		ataxia_listener_callback callback) {
	if (callback == NULL) {
		return NULL;
	}

	struct ataxia_listener *listener = calloc(1, sizeof(*listener));
	if (listener == NULL) {
		return NULL;
	}

	wl_list_init(&listener->listener.link);
	listener->listener.notify = listener_notify;
	listener->callback = callback;
	listener->cookie = cookie;
	return listener;
}

bool ataxia_listener_attach(struct ataxia_listener *listener,
		struct wl_signal *signal) {
	if (listener == NULL || signal == NULL || listener->attached) {
		return false;
	}

	wl_signal_add(signal, &listener->listener);
	listener->attached = true;
	return true;
}

bool ataxia_listener_detach(struct ataxia_listener *listener) {
	if (listener == NULL || !listener->attached) {
		return false;
	}

	wl_list_remove(&listener->listener.link);
	wl_list_init(&listener->listener.link);
	listener->attached = false;
	return true;
}

void ataxia_listener_destroy(struct ataxia_listener *listener) {
	if (listener == NULL) {
		return;
	}
	ataxia_listener_detach(listener);
	listener->callback = NULL;
	free(listener);
}

#define SIGNAL_ACCESSOR(function_name, object_type, member) \
	struct wl_signal *function_name(struct object_type *object) { \
		return object == NULL ? NULL : &object->member; \
	}

SIGNAL_ACCESSOR(ataxia_backend_event_destroy, wlr_backend, events.destroy)
SIGNAL_ACCESSOR(ataxia_backend_event_new_input, wlr_backend, events.new_input)
SIGNAL_ACCESSOR(ataxia_backend_event_new_output, wlr_backend, events.new_output)
SIGNAL_ACCESSOR(ataxia_renderer_event_destroy, wlr_renderer, events.destroy)
SIGNAL_ACCESSOR(ataxia_renderer_event_lost, wlr_renderer, events.lost)
SIGNAL_ACCESSOR(ataxia_allocator_event_destroy, wlr_allocator, events.destroy)
SIGNAL_ACCESSOR(ataxia_compositor_event_new_surface, wlr_compositor,
	events.new_surface)
SIGNAL_ACCESSOR(ataxia_compositor_event_destroy, wlr_compositor, events.destroy)
SIGNAL_ACCESSOR(ataxia_output_event_frame, wlr_output, events.frame)
SIGNAL_ACCESSOR(ataxia_output_event_destroy, wlr_output, events.destroy)
SIGNAL_ACCESSOR(ataxia_input_device_event_destroy, wlr_input_device,
	events.destroy)
SIGNAL_ACCESSOR(ataxia_surface_event_commit, wlr_surface, events.commit)
SIGNAL_ACCESSOR(ataxia_surface_event_map, wlr_surface, events.map)
SIGNAL_ACCESSOR(ataxia_surface_event_unmap, wlr_surface, events.unmap)
SIGNAL_ACCESSOR(ataxia_surface_event_new_subsurface, wlr_surface,
	events.new_subsurface)
SIGNAL_ACCESSOR(ataxia_surface_event_destroy, wlr_surface, events.destroy)

const char *ataxia_output_name(const struct wlr_output *output) {
	return output == NULL ? NULL : output->name;
}

const char *ataxia_output_description(const struct wlr_output *output) {
	return output == NULL ? NULL : output->description;
}

int32_t ataxia_output_width(const struct wlr_output *output) {
	return output == NULL ? 0 : output->width;
}

int32_t ataxia_output_height(const struct wlr_output *output) {
	return output == NULL ? 0 : output->height;
}

bool ataxia_output_enabled(const struct wlr_output *output) {
	return output != NULL && output->enabled;
}

const char *ataxia_input_device_name(const struct wlr_input_device *device) {
	return device == NULL ? NULL : device->name;
}

uint32_t ataxia_input_device_type(const struct wlr_input_device *device) {
	return device == NULL ? UINT32_MAX : (uint32_t)device->type;
}

uint32_t ataxia_surface_current_committed(const struct wlr_surface *surface) {
	return surface == NULL ? 0 : surface->current.committed;
}

uint32_t ataxia_surface_current_sequence(const struct wlr_surface *surface) {
	return surface == NULL ? 0 : surface->current.seq;
}

int32_t ataxia_surface_current_width(const struct wlr_surface *surface) {
	return surface == NULL ? 0 : surface->current.width;
}

int32_t ataxia_surface_current_height(const struct wlr_surface *surface) {
	return surface == NULL ? 0 : surface->current.height;
}

int32_t ataxia_surface_current_buffer_width(const struct wlr_surface *surface) {
	return surface == NULL ? 0 : surface->current.buffer_width;
}

int32_t ataxia_surface_current_buffer_height(const struct wlr_surface *surface) {
	return surface == NULL ? 0 : surface->current.buffer_height;
}

bool ataxia_surface_mapped(const struct wlr_surface *surface) {
	return surface != NULL && surface->mapped;
}
