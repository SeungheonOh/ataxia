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
#include <wlr/render/gles2.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/version.h>
#include <wlr/util/region.h>

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
SIGNAL_ACCESSOR(ataxia_output_event_damage, wlr_output, events.damage)
SIGNAL_ACCESSOR(ataxia_output_event_needs_frame, wlr_output,
	events.needs_frame)
SIGNAL_ACCESSOR(ataxia_output_event_present, wlr_output, events.present)
SIGNAL_ACCESSOR(ataxia_output_event_request_state, wlr_output,
	events.request_state)
SIGNAL_ACCESSOR(ataxia_output_event_destroy, wlr_output, events.destroy)
SIGNAL_ACCESSOR(ataxia_input_device_event_destroy, wlr_input_device,
	events.destroy)
SIGNAL_ACCESSOR(ataxia_seat_event_destroy, wlr_seat, events.destroy)
SIGNAL_ACCESSOR(ataxia_seat_event_request_set_cursor, wlr_seat,
	events.request_set_cursor)
SIGNAL_ACCESSOR(ataxia_seat_event_request_start_drag, wlr_seat,
	events.request_start_drag)
SIGNAL_ACCESSOR(ataxia_drag_event_destroy, wlr_drag, events.destroy)
SIGNAL_ACCESSOR(ataxia_surface_event_commit, wlr_surface, events.commit)
SIGNAL_ACCESSOR(ataxia_surface_event_map, wlr_surface, events.map)
SIGNAL_ACCESSOR(ataxia_surface_event_unmap, wlr_surface, events.unmap)
SIGNAL_ACCESSOR(ataxia_surface_event_new_subsurface, wlr_surface,
	events.new_subsurface)
SIGNAL_ACCESSOR(ataxia_surface_event_destroy, wlr_surface, events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_decoration_manager_event_new_toplevel,
	wlr_xdg_decoration_manager_v1, events.new_toplevel_decoration)
SIGNAL_ACCESSOR(ataxia_xdg_decoration_manager_event_destroy,
	wlr_xdg_decoration_manager_v1, events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_decoration_event_request_mode,
	wlr_xdg_toplevel_decoration_v1, events.request_mode)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_decoration_event_destroy,
	wlr_xdg_toplevel_decoration_v1, events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_activation_event_request_activate,
	wlr_xdg_activation_v1, events.request_activate)
SIGNAL_ACCESSOR(ataxia_xdg_activation_event_destroy,
	wlr_xdg_activation_v1, events.destroy)
SIGNAL_ACCESSOR(ataxia_pointer_constraints_event_new_constraint,
	wlr_pointer_constraints_v1, events.new_constraint)
SIGNAL_ACCESSOR(ataxia_pointer_constraints_event_destroy,
	wlr_pointer_constraints_v1, events.destroy)
SIGNAL_ACCESSOR(ataxia_pointer_constraint_event_set_region,
	wlr_pointer_constraint_v1, events.set_region)
SIGNAL_ACCESSOR(ataxia_pointer_constraint_event_destroy,
	wlr_pointer_constraint_v1, events.destroy)

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

float ataxia_output_scale(const struct wlr_output *output) {
	return output == NULL ? 1.0f : output->scale;
}

uint32_t ataxia_output_transform(const struct wlr_output *output) {
	return output == NULL ? WL_OUTPUT_TRANSFORM_NORMAL : output->transform;
}

bool ataxia_output_enabled(const struct wlr_output *output) {
	return output != NULL && output->enabled;
}

bool ataxia_output_frame_pending(const struct wlr_output *output) {
	return output != NULL && output->frame_pending;
}

const void *ataxia_output_damage_region(
		const struct wlr_output_event_damage *event) {
	return event == NULL ? NULL : event->damage;
}

uint32_t ataxia_region_rectangle_count(const void *region_pointer) {
	if (region_pointer == NULL) {
		return 0;
	}
	int count = 0;
	pixman_region32_rectangles(
		(pixman_region32_t *)region_pointer, &count);
	return count < 0 ? 0 : (uint32_t)count;
}

bool ataxia_region_rectangle_at(const void *region_pointer, uint32_t index,
		int32_t *x1, int32_t *y1, int32_t *x2, int32_t *y2) {
	if (region_pointer == NULL || x1 == NULL || y1 == NULL ||
			x2 == NULL || y2 == NULL) {
		return false;
	}
	int count = 0;
	pixman_box32_t *rectangles = pixman_region32_rectangles(
		(pixman_region32_t *)region_pointer, &count);
	if (index >= (uint32_t)count) {
		return false;
	}
	*x1 = rectangles[index].x1;
	*y1 = rectangles[index].y1;
	*x2 = rectangles[index].x2;
	*y2 = rectangles[index].y2;
	return true;
}

void ataxia_output_state_set_damage_rectangles(struct wlr_output_state *state,
		const int32_t *rectangles, uint32_t rectangle_count) {
	if (state == NULL) {
		return;
	}
	pixman_region32_t damage;
	pixman_region32_init(&damage);
	for (uint32_t index = 0; rectangles != NULL && index < rectangle_count;
			index++) {
		const int32_t *rectangle = &rectangles[index * 4];
		if (rectangle[2] > 0 && rectangle[3] > 0) {
			pixman_region32_union_rect(&damage, &damage, rectangle[0],
				rectangle[1], (uint32_t)rectangle[2],
				(uint32_t)rectangle[3]);
		}
	}
	wlr_output_state_set_damage(state, &damage);
	pixman_region32_fini(&damage);
}

uint32_t ataxia_output_present_commit_sequence(
		const struct wlr_output_event_present *event) {
	return event == NULL ? 0 : event->commit_seq;
}

bool ataxia_output_presented(const struct wlr_output_event_present *event) {
	return event != NULL && event->presented;
}

int64_t ataxia_output_present_seconds(
		const struct wlr_output_event_present *event) {
	return event == NULL ? 0 : event->when.tv_sec;
}

int64_t ataxia_output_present_nanoseconds(
		const struct wlr_output_event_present *event) {
	return event == NULL ? 0 : event->when.tv_nsec;
}

uint32_t ataxia_output_present_sequence(
		const struct wlr_output_event_present *event) {
	return event == NULL ? 0 : event->seq;
}

int32_t ataxia_output_present_refresh_nanoseconds(
		const struct wlr_output_event_present *event) {
	return event == NULL ? 0 : event->refresh;
}

uint32_t ataxia_output_present_flags(
		const struct wlr_output_event_present *event) {
	return event == NULL ? 0 : event->flags;
}

uint32_t ataxia_output_state_committed(const struct wlr_output_state *state) {
	return state == NULL ? 0 : state->committed;
}

const struct wlr_output_state *ataxia_output_requested_state(
		const struct wlr_output_event_request_state *event) {
	return event == NULL ? NULL : event->state;
}

struct wlr_output_state *ataxia_output_state_create(void) {
	struct wlr_output_state *state = calloc(1, sizeof(*state));
	if (state != NULL) {
		wlr_output_state_init(state);
	}
	return state;
}

void ataxia_output_state_destroy(struct wlr_output_state *state) {
	if (state == NULL) {
		return;
	}
	wlr_output_state_finish(state);
	free(state);
}

const char *ataxia_input_device_name(const struct wlr_input_device *device) {
	return device == NULL ? NULL : device->name;
}

uint32_t ataxia_input_device_type(const struct wlr_input_device *device) {
	return device == NULL ? UINT32_MAX : (uint32_t)device->type;
}

struct wlr_pointer *ataxia_input_device_pointer(
		struct wlr_input_device *device) {
	return device == NULL ? NULL : wlr_pointer_from_input_device(device);
}

SIGNAL_ACCESSOR(ataxia_pointer_event_motion, wlr_pointer, events.motion)
SIGNAL_ACCESSOR(ataxia_pointer_event_motion_absolute, wlr_pointer,
	events.motion_absolute)
SIGNAL_ACCESSOR(ataxia_pointer_event_button, wlr_pointer, events.button)
SIGNAL_ACCESSOR(ataxia_pointer_event_axis, wlr_pointer, events.axis)
SIGNAL_ACCESSOR(ataxia_pointer_event_frame, wlr_pointer, events.frame)

uint32_t ataxia_pointer_motion_time_msec(
		const struct wlr_pointer_motion_event *event) {
	return event == NULL ? 0 : event->time_msec;
}

double ataxia_pointer_motion_delta_x(
		const struct wlr_pointer_motion_event *event) {
	return event == NULL ? 0.0 : event->delta_x;
}

double ataxia_pointer_motion_delta_y(
		const struct wlr_pointer_motion_event *event) {
	return event == NULL ? 0.0 : event->delta_y;
}

double ataxia_pointer_motion_unaccel_dx(
		const struct wlr_pointer_motion_event *event) {
	return event == NULL ? 0.0 : event->unaccel_dx;
}

double ataxia_pointer_motion_unaccel_dy(
		const struct wlr_pointer_motion_event *event) {
	return event == NULL ? 0.0 : event->unaccel_dy;
}

uint32_t ataxia_pointer_motion_absolute_time_msec(
		const struct wlr_pointer_motion_absolute_event *event) {
	return event == NULL ? 0 : event->time_msec;
}

double ataxia_pointer_motion_absolute_x(
		const struct wlr_pointer_motion_absolute_event *event) {
	return event == NULL ? 0.0 : event->x;
}

double ataxia_pointer_motion_absolute_y(
		const struct wlr_pointer_motion_absolute_event *event) {
	return event == NULL ? 0.0 : event->y;
}

uint32_t ataxia_pointer_button_time_msec(
		const struct wlr_pointer_button_event *event) {
	return event == NULL ? 0 : event->time_msec;
}

uint32_t ataxia_pointer_button_button(
		const struct wlr_pointer_button_event *event) {
	return event == NULL ? 0 : event->button;
}

uint32_t ataxia_pointer_button_state(
		const struct wlr_pointer_button_event *event) {
	return event == NULL ? 0 : (uint32_t)event->state;
}

uint32_t ataxia_pointer_axis_time_msec(
		const struct wlr_pointer_axis_event *event) {
	return event == NULL ? 0 : event->time_msec;
}

uint32_t ataxia_pointer_axis_source(
		const struct wlr_pointer_axis_event *event) {
	return event == NULL ? 0 : (uint32_t)event->source;
}

uint32_t ataxia_pointer_axis_orientation(
		const struct wlr_pointer_axis_event *event) {
	return event == NULL ? 0 : (uint32_t)event->orientation;
}

uint32_t ataxia_pointer_axis_relative_direction(
		const struct wlr_pointer_axis_event *event) {
	return event == NULL ? 0 : (uint32_t)event->relative_direction;
}

double ataxia_pointer_axis_delta(
		const struct wlr_pointer_axis_event *event) {
	return event == NULL ? 0.0 : event->delta;
}

int32_t ataxia_pointer_axis_delta_discrete(
		const struct wlr_pointer_axis_event *event) {
	return event == NULL ? 0 : event->delta_discrete;
}

struct wlr_keyboard *ataxia_input_device_keyboard(
		struct wlr_input_device *device) {
	return device == NULL ? NULL : wlr_keyboard_from_input_device(device);
}

SIGNAL_ACCESSOR(ataxia_keyboard_event_key, wlr_keyboard, events.key)
SIGNAL_ACCESSOR(ataxia_keyboard_event_modifiers, wlr_keyboard,
	events.modifiers)
SIGNAL_ACCESSOR(ataxia_keyboard_event_keymap, wlr_keyboard, events.keymap)
SIGNAL_ACCESSOR(ataxia_keyboard_event_repeat_info, wlr_keyboard,
	events.repeat_info)

uint32_t ataxia_keyboard_key_time_msec(
		const struct wlr_keyboard_key_event *event) {
	return event == NULL ? 0 : event->time_msec;
}

uint32_t ataxia_keyboard_key_keycode(
		const struct wlr_keyboard_key_event *event) {
	return event == NULL ? 0 : event->keycode;
}

bool ataxia_keyboard_key_update_state(
		const struct wlr_keyboard_key_event *event) {
	return event != NULL && event->update_state;
}

uint32_t ataxia_keyboard_key_state(
		const struct wlr_keyboard_key_event *event) {
	return event == NULL ? 0 : (uint32_t)event->state;
}

uint32_t ataxia_keyboard_modifiers_depressed(
		const struct wlr_keyboard *keyboard) {
	return keyboard == NULL ? 0 : keyboard->modifiers.depressed;
}

uint32_t ataxia_keyboard_modifiers_latched(
		const struct wlr_keyboard *keyboard) {
	return keyboard == NULL ? 0 : keyboard->modifiers.latched;
}

uint32_t ataxia_keyboard_modifiers_locked(
		const struct wlr_keyboard *keyboard) {
	return keyboard == NULL ? 0 : keyboard->modifiers.locked;
}

uint32_t ataxia_keyboard_modifiers_group(
		const struct wlr_keyboard *keyboard) {
	return keyboard == NULL ? 0 : keyboard->modifiers.group;
}

int32_t ataxia_keyboard_repeat_rate(const struct wlr_keyboard *keyboard) {
	return keyboard == NULL ? 0 : keyboard->repeat_info.rate;
}

int32_t ataxia_keyboard_repeat_delay(const struct wlr_keyboard *keyboard) {
	return keyboard == NULL ? 0 : keyboard->repeat_info.delay;
}

void ataxia_seat_keyboard_notify_modifiers_current(struct wlr_seat *seat,
		struct wlr_keyboard *keyboard) {
	if (seat != NULL && keyboard != NULL) {
		wlr_seat_keyboard_notify_modifiers(seat, &keyboard->modifiers);
	}
}

void ataxia_seat_keyboard_notify_enter_current(struct wlr_seat *seat,
		struct wlr_surface *surface, struct wlr_keyboard *keyboard) {
	if (seat != NULL && surface != NULL && keyboard != NULL) {
		wlr_seat_keyboard_notify_enter(seat, surface, keyboard->keycodes,
			keyboard->num_keycodes, &keyboard->modifiers);
	}
}

struct wlr_surface *ataxia_seat_cursor_surface(
		const struct wlr_seat_pointer_request_set_cursor_event *event) {
	return event == NULL ? NULL : event->surface;
}

uint32_t ataxia_seat_cursor_serial(
		const struct wlr_seat_pointer_request_set_cursor_event *event) {
	return event == NULL ? 0 : event->serial;
}

int32_t ataxia_seat_cursor_hotspot_x(
		const struct wlr_seat_pointer_request_set_cursor_event *event) {
	return event == NULL ? 0 : event->hotspot_x;
}

int32_t ataxia_seat_cursor_hotspot_y(
		const struct wlr_seat_pointer_request_set_cursor_event *event) {
	return event == NULL ? 0 : event->hotspot_y;
}

bool ataxia_seat_pointer_drag_active(const struct wlr_seat *seat) {
	return seat != NULL && seat->drag != NULL &&
		seat->drag->grab_type == WLR_DRAG_GRAB_KEYBOARD_POINTER;
}

uint32_t ataxia_seat_pointer_button_press_count(const struct wlr_seat *seat,
		uint32_t button) {
	if (seat == NULL) {
		return 0;
	}
	for (size_t index = 0; index < seat->pointer_state.button_count; index++) {
		const struct wlr_seat_pointer_button *pressed =
			&seat->pointer_state.buttons[index];
		if (pressed->button == button) {
			return pressed->n_pressed > UINT32_MAX
				? UINT32_MAX : (uint32_t)pressed->n_pressed;
		}
	}
	return 0;
}

struct wlr_drag *ataxia_seat_drag_request_drag(
		const struct wlr_seat_request_start_drag_event *event) {
	return event == NULL ? NULL : event->drag;
}

struct wlr_surface *ataxia_seat_drag_request_origin(
		const struct wlr_seat_request_start_drag_event *event) {
	return event == NULL ? NULL : event->origin;
}

uint32_t ataxia_seat_drag_request_serial(
		const struct wlr_seat_request_start_drag_event *event) {
	return event == NULL ? 0 : event->serial;
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

uint32_t ataxia_surface_effective_damage_rectangles(
		struct wlr_surface *surface, int32_t *rectangles,
		uint32_t rectangle_capacity) {
	if (surface == NULL) {
		return 0;
	}

	pixman_region32_t damage;
	pixman_region32_init(&damage);
	wlr_surface_get_effective_damage(surface, &damage);
	int count = 0;
	pixman_box32_t *boxes = pixman_region32_rectangles(&damage, &count);
	uint32_t rectangle_count = count > 0 ? (uint32_t)count : 0;
	uint32_t copy_count = rectangle_count < rectangle_capacity ?
		rectangle_count : rectangle_capacity;
	for (uint32_t index = 0; rectangles != NULL && index < copy_count;
			index++) {
		int32_t *rectangle = &rectangles[index * 4];
		rectangle[0] = boxes[index].x1;
		rectangle[1] = boxes[index].y1;
		rectangle[2] = boxes[index].x2 - boxes[index].x1;
		rectangle[3] = boxes[index].y2 - boxes[index].y1;
	}
	pixman_region32_fini(&damage);
	return rectangle_count;
}

uint32_t ataxia_surface_current_transform(const struct wlr_surface *surface) {
	return surface == NULL ? WL_OUTPUT_TRANSFORM_NORMAL :
		(uint32_t)surface->current.transform;
}

bool ataxia_surface_buffer_source_box(struct wlr_surface *surface,
		double *x, double *y, double *width, double *height) {
	if (surface == NULL || x == NULL || y == NULL ||
			width == NULL || height == NULL) {
		return false;
	}
	struct wlr_fbox box;
	wlr_surface_get_buffer_source_box(surface, &box);
	*x = box.x;
	*y = box.y;
	*width = box.width;
	*height = box.height;
	return box.width > 0.0 && box.height > 0.0;
}

struct wlr_xdg_toplevel *ataxia_xdg_toplevel_decoration_toplevel(
		struct wlr_xdg_toplevel_decoration_v1 *decoration) {
	return decoration == NULL ? NULL : decoration->toplevel;
}

uint32_t ataxia_xdg_toplevel_decoration_requested_mode(
		const struct wlr_xdg_toplevel_decoration_v1 *decoration) {
	return decoration == NULL ? WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_NONE :
		(uint32_t)decoration->requested_mode;
}

struct wlr_surface *ataxia_xdg_activation_request_surface(
		const struct wlr_xdg_activation_v1_request_activate_event *event) {
	return event == NULL ? NULL : event->surface;
}

struct wlr_xdg_activation_token_v1 *ataxia_xdg_activation_request_token(
		const struct wlr_xdg_activation_v1_request_activate_event *event) {
	return event == NULL ? NULL : event->token;
}

struct wlr_surface *ataxia_xdg_activation_token_surface(
		const struct wlr_xdg_activation_token_v1 *token) {
	return token == NULL ? NULL : token->surface;
}

struct wlr_seat *ataxia_xdg_activation_token_seat(
		const struct wlr_xdg_activation_token_v1 *token) {
	return token == NULL ? NULL : token->seat;
}

uint32_t ataxia_xdg_activation_token_serial(
		const struct wlr_xdg_activation_token_v1 *token) {
	return token == NULL ? 0 : token->serial;
}

const char *ataxia_xdg_activation_token_app_id(
		const struct wlr_xdg_activation_token_v1 *token) {
	return token == NULL ? NULL : token->app_id;
}

struct wlr_surface *ataxia_pointer_constraint_surface(
		const struct wlr_pointer_constraint_v1 *constraint) {
	return constraint == NULL ? NULL : constraint->surface;
}

struct wlr_seat *ataxia_pointer_constraint_seat(
		const struct wlr_pointer_constraint_v1 *constraint) {
	return constraint == NULL ? NULL : constraint->seat;
}

uint32_t ataxia_pointer_constraint_type(
		const struct wlr_pointer_constraint_v1 *constraint) {
	return constraint == NULL ? WLR_POINTER_CONSTRAINT_V1_LOCKED :
		(uint32_t)constraint->type;
}

bool ataxia_pointer_constraint_confine(
		const struct wlr_pointer_constraint_v1 *constraint,
		double x1, double y1, double x2, double y2,
		double *confined_x, double *confined_y) {
	if (constraint == NULL || confined_x == NULL || confined_y == NULL) {
		return false;
	}
	return wlr_region_confine(&constraint->region, x1, y1, x2, y2,
		confined_x, confined_y);
}

bool ataxia_pointer_constraint_region_empty(
		const struct wlr_pointer_constraint_v1 *constraint) {
	return constraint == NULL || pixman_region32_empty(&constraint->region);
}

bool ataxia_pointer_constraint_cursor_hint(
		const struct wlr_pointer_constraint_v1 *constraint,
		double *x, double *y) {
	if (constraint == NULL || x == NULL || y == NULL ||
			!constraint->current.cursor_hint.enabled) {
		return false;
	}
	*x = constraint->current.cursor_hint.x;
	*y = constraint->current.cursor_hint.y;
	return true;
}

bool ataxia_surface_mapped(const struct wlr_surface *surface) {
	return surface != NULL && surface->mapped;
}

SIGNAL_ACCESSOR(ataxia_subsurface_event_destroy, wlr_subsurface,
	events.destroy)

struct wlr_surface *ataxia_subsurface_surface(
		struct wlr_subsurface *subsurface) {
	return subsurface == NULL ? NULL : subsurface->surface;
}

struct wlr_surface *ataxia_subsurface_parent(
		struct wlr_subsurface *subsurface) {
	return subsurface == NULL ? NULL : subsurface->parent;
}

int32_t ataxia_subsurface_x(const struct wlr_subsurface *subsurface) {
	return subsurface == NULL ? 0 : subsurface->current.x;
}

int32_t ataxia_subsurface_y(const struct wlr_subsurface *subsurface) {
	return subsurface == NULL ? 0 : subsurface->current.y;
}

bool ataxia_subsurface_synchronized(const struct wlr_subsurface *subsurface) {
	return subsurface != NULL && subsurface->synchronized;
}

struct wlr_buffer *ataxia_surface_lock_buffer(struct wlr_surface *surface) {
	if (surface == NULL || surface->buffer == NULL) {
		return NULL;
	}
	return wlr_buffer_lock(&surface->buffer->base);
}

int32_t ataxia_buffer_width(const struct wlr_buffer *buffer) {
	return buffer == NULL ? 0 : buffer->width;
}

int32_t ataxia_buffer_height(const struct wlr_buffer *buffer) {
	return buffer == NULL ? 0 : buffer->height;
}

struct wlr_texture *ataxia_client_buffer_texture(struct wlr_buffer *buffer) {
	struct wlr_client_buffer *client_buffer = wlr_client_buffer_get(buffer);
	return client_buffer == NULL ? NULL : client_buffer->texture;
}

uint32_t ataxia_texture_width(const struct wlr_texture *texture) {
	return texture == NULL ? 0 : texture->width;
}

uint32_t ataxia_texture_height(const struct wlr_texture *texture) {
	return texture == NULL ? 0 : texture->height;
}

uint32_t ataxia_gles2_texture_target(struct wlr_texture *texture) {
	if (texture == NULL || !wlr_texture_is_gles2(texture)) {
		return 0;
	}
	struct wlr_gles2_texture_attribs attributes;
	wlr_gles2_texture_get_attribs(texture, &attributes);
	return attributes.target;
}

uint32_t ataxia_gles2_texture_name(struct wlr_texture *texture) {
	if (texture == NULL || !wlr_texture_is_gles2(texture)) {
		return 0;
	}
	struct wlr_gles2_texture_attribs attributes;
	wlr_gles2_texture_get_attribs(texture, &attributes);
	return attributes.tex;
}

bool ataxia_gles2_texture_has_alpha(struct wlr_texture *texture) {
	if (texture == NULL || !wlr_texture_is_gles2(texture)) {
		return false;
	}
	struct wlr_gles2_texture_attribs attributes;
	wlr_gles2_texture_get_attribs(texture, &attributes);
	return attributes.has_alpha;
}

SIGNAL_ACCESSOR(ataxia_xdg_shell_event_new_toplevel, wlr_xdg_shell,
	events.new_toplevel)
SIGNAL_ACCESSOR(ataxia_xdg_shell_event_new_popup, wlr_xdg_shell,
	events.new_popup)
SIGNAL_ACCESSOR(ataxia_xdg_shell_event_destroy, wlr_xdg_shell, events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_surface_event_destroy, wlr_xdg_surface,
	events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_destroy, wlr_xdg_toplevel,
	events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_request_maximize, wlr_xdg_toplevel,
	events.request_maximize)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_request_fullscreen, wlr_xdg_toplevel,
	events.request_fullscreen)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_request_minimize, wlr_xdg_toplevel,
	events.request_minimize)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_request_move, wlr_xdg_toplevel,
	events.request_move)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_request_resize, wlr_xdg_toplevel,
	events.request_resize)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_request_show_window_menu,
	wlr_xdg_toplevel, events.request_show_window_menu)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_set_parent, wlr_xdg_toplevel,
	events.set_parent)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_set_title, wlr_xdg_toplevel,
	events.set_title)
SIGNAL_ACCESSOR(ataxia_xdg_toplevel_event_set_app_id, wlr_xdg_toplevel,
	events.set_app_id)
SIGNAL_ACCESSOR(ataxia_xdg_popup_event_destroy, wlr_xdg_popup, events.destroy)
SIGNAL_ACCESSOR(ataxia_xdg_popup_event_reposition, wlr_xdg_popup,
	events.reposition)

struct wlr_xdg_surface *ataxia_xdg_toplevel_base(
		struct wlr_xdg_toplevel *toplevel) {
	return toplevel == NULL ? NULL : toplevel->base;
}

struct wlr_surface *ataxia_xdg_surface_surface(
		struct wlr_xdg_surface *surface) {
	return surface == NULL ? NULL : surface->surface;
}

bool ataxia_xdg_surface_initial_commit(
		const struct wlr_xdg_surface *surface) {
	return surface != NULL && surface->initial_commit;
}

bool ataxia_xdg_surface_configured(const struct wlr_xdg_surface *surface) {
	return surface != NULL && surface->configured;
}

const char *ataxia_xdg_toplevel_title(
		const struct wlr_xdg_toplevel *toplevel) {
	return toplevel == NULL ? NULL : toplevel->title;
}

const char *ataxia_xdg_toplevel_app_id(
		const struct wlr_xdg_toplevel *toplevel) {
	return toplevel == NULL ? NULL : toplevel->app_id;
}

bool ataxia_xdg_toplevel_requested_maximized(
		const struct wlr_xdg_toplevel *toplevel) {
	return toplevel != NULL && toplevel->requested.maximized;
}

bool ataxia_xdg_toplevel_requested_minimized(
		const struct wlr_xdg_toplevel *toplevel) {
	return toplevel != NULL && toplevel->requested.minimized;
}

bool ataxia_xdg_toplevel_requested_fullscreen(
		const struct wlr_xdg_toplevel *toplevel) {
	return toplevel != NULL && toplevel->requested.fullscreen;
}

struct wlr_output *ataxia_xdg_toplevel_requested_fullscreen_output(
		const struct wlr_xdg_toplevel *toplevel) {
	return toplevel == NULL ? NULL : toplevel->requested.fullscreen_output;
}

struct wlr_seat *ataxia_xdg_move_seat(
		const struct wlr_xdg_toplevel_move_event *event) {
	return event == NULL || event->seat == NULL ? NULL : event->seat->seat;
}

uint32_t ataxia_xdg_move_serial(
		const struct wlr_xdg_toplevel_move_event *event) {
	return event == NULL ? 0 : event->serial;
}

struct wlr_seat *ataxia_xdg_resize_seat(
		const struct wlr_xdg_toplevel_resize_event *event) {
	return event == NULL || event->seat == NULL ? NULL : event->seat->seat;
}

uint32_t ataxia_xdg_resize_serial(
		const struct wlr_xdg_toplevel_resize_event *event) {
	return event == NULL ? 0 : event->serial;
}

uint32_t ataxia_xdg_resize_edges(
		const struct wlr_xdg_toplevel_resize_event *event) {
	return event == NULL ? 0 : event->edges;
}

struct wlr_seat *ataxia_xdg_window_menu_seat(
		const struct wlr_xdg_toplevel_show_window_menu_event *event) {
	return event == NULL || event->seat == NULL ? NULL : event->seat->seat;
}

uint32_t ataxia_xdg_window_menu_serial(
		const struct wlr_xdg_toplevel_show_window_menu_event *event) {
	return event == NULL ? 0 : event->serial;
}

int32_t ataxia_xdg_window_menu_x(
		const struct wlr_xdg_toplevel_show_window_menu_event *event) {
	return event == NULL ? 0 : event->x;
}

int32_t ataxia_xdg_window_menu_y(
		const struct wlr_xdg_toplevel_show_window_menu_event *event) {
	return event == NULL ? 0 : event->y;
}

struct wlr_xdg_surface *ataxia_xdg_popup_base(struct wlr_xdg_popup *popup) {
	return popup == NULL ? NULL : popup->base;
}

struct wlr_surface *ataxia_xdg_popup_parent_surface(
		struct wlr_xdg_popup *popup) {
	return popup == NULL ? NULL : popup->parent;
}
