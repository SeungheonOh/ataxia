/*
 * Ataxia wlroots ABI glue.
 *
 * This header exposes listener allocation, exact wl_signal addresses, and
 * read-only field accessors. It contains no compositor policy or event model.
 */

#ifndef ATAXIA_WLR_GLUE_H
#define ATAXIA_WLR_GLUE_H

#include <stdbool.h>
#include <stdint.h>

#define ATAXIA_WLR_GLUE_API __attribute__((visibility("default")))
#define ATAXIA_WLR_GLUE_ABI_VERSION 1u

struct wl_signal;
struct wlr_allocator;
struct wlr_backend;
struct wlr_compositor;
struct wlr_input_device;
struct wlr_output;
struct wlr_renderer;
struct wlr_surface;
struct ataxia_listener;

typedef void (*ataxia_listener_callback)(uintptr_t cookie, void *data);

ATAXIA_WLR_GLUE_API uint32_t ataxia_wlr_glue_abi_version(void);
ATAXIA_WLR_GLUE_API const char *ataxia_wlr_glue_wlroots_version(void);

ATAXIA_WLR_GLUE_API struct ataxia_listener *ataxia_listener_create(
	uintptr_t cookie, ataxia_listener_callback callback);
ATAXIA_WLR_GLUE_API bool ataxia_listener_attach(
	struct ataxia_listener *listener, struct wl_signal *signal);
ATAXIA_WLR_GLUE_API bool ataxia_listener_detach(
	struct ataxia_listener *listener);
ATAXIA_WLR_GLUE_API void ataxia_listener_destroy(
	struct ataxia_listener *listener);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_backend_event_destroy(
	struct wlr_backend *backend);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_backend_event_new_input(
	struct wlr_backend *backend);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_backend_event_new_output(
	struct wlr_backend *backend);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_renderer_event_destroy(
	struct wlr_renderer *renderer);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_renderer_event_lost(
	struct wlr_renderer *renderer);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_allocator_event_destroy(
	struct wlr_allocator *allocator);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_compositor_event_new_surface(
	struct wlr_compositor *compositor);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_compositor_event_destroy(
	struct wlr_compositor *compositor);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_output_event_frame(
	struct wlr_output *output);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_output_event_destroy(
	struct wlr_output *output);
ATAXIA_WLR_GLUE_API const char *ataxia_output_name(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API const char *ataxia_output_description(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API int32_t ataxia_output_width(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API int32_t ataxia_output_height(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API bool ataxia_output_enabled(
	const struct wlr_output *output);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_input_device_event_destroy(
	struct wlr_input_device *device);
ATAXIA_WLR_GLUE_API const char *ataxia_input_device_name(
	const struct wlr_input_device *device);
ATAXIA_WLR_GLUE_API uint32_t ataxia_input_device_type(
	const struct wlr_input_device *device);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_surface_event_commit(
	struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_surface_event_map(
	struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_surface_event_unmap(
	struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_surface_event_new_subsurface(
	struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_surface_event_destroy(
	struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API uint32_t ataxia_surface_current_committed(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API uint32_t ataxia_surface_current_sequence(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API int32_t ataxia_surface_current_width(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API int32_t ataxia_surface_current_height(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API int32_t ataxia_surface_current_buffer_width(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API int32_t ataxia_surface_current_buffer_height(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API bool ataxia_surface_mapped(
	const struct wlr_surface *surface);

#endif
