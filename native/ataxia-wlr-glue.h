/*
 * Ataxia wlroots ABI glue.
 *
 * This header exposes listener allocation, exact wl_signal addresses, and
 * read-only field accessors. It contains no compositor policy or event model.
 */

#ifndef ATAXIA_WLR_GLUE_H
#define ATAXIA_WLR_GLUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define ATAXIA_WLR_GLUE_API __attribute__((visibility("default")))
#define ATAXIA_WLR_GLUE_ABI_VERSION 12u

struct wl_signal;
struct wlr_allocator;
struct wlr_backend;
struct wlr_buffer;
struct wlr_compositor;
struct wlr_drag;
struct wlr_input_device;
struct wlr_keyboard;
struct wlr_keyboard_key_event;
struct wlr_output;
struct wlr_output_event_damage;
struct wlr_output_event_present;
struct wlr_output_event_request_state;
struct wlr_output_state;
struct wlr_pointer;
struct wlr_pointer_axis_event;
struct wlr_pointer_button_event;
struct wlr_pointer_motion_absolute_event;
struct wlr_pointer_motion_event;
struct wlr_renderer;
struct wlr_seat;
struct wlr_seat_pointer_request_set_cursor_event;
struct wlr_seat_request_start_drag_event;
struct wlr_subsurface;
struct wlr_surface;
struct wlr_texture;
struct wlr_xdg_popup;
struct wlr_xdg_shell;
struct wlr_xdg_surface;
struct wlr_xdg_toplevel;
struct wlr_xdg_toplevel_move_event;
struct wlr_xdg_toplevel_resize_event;
struct wlr_xdg_toplevel_show_window_menu_event;
struct wlr_xdg_activation_v1;
struct wlr_xdg_activation_token_v1;
struct wlr_xdg_activation_v1_request_activate_event;
struct wlr_xdg_decoration_manager_v1;
struct wlr_xdg_toplevel_decoration_v1;
struct wlr_pointer_constraint_v1;
struct wlr_pointer_constraints_v1;
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
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_output_event_damage(
	struct wlr_output *output);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_output_event_needs_frame(
	struct wlr_output *output);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_output_event_present(
	struct wlr_output *output);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_output_event_request_state(
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
ATAXIA_WLR_GLUE_API float ataxia_output_scale(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API uint32_t ataxia_output_transform(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API bool ataxia_output_enabled(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API bool ataxia_output_frame_pending(
	const struct wlr_output *output);
ATAXIA_WLR_GLUE_API const void *ataxia_output_damage_region(
	const struct wlr_output_event_damage *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_region_rectangle_count(
	const void *region);
ATAXIA_WLR_GLUE_API bool ataxia_region_rectangle_at(
	const void *region, uint32_t index, int32_t *x1, int32_t *y1,
	int32_t *x2, int32_t *y2);
ATAXIA_WLR_GLUE_API void ataxia_output_state_set_damage_rectangles(
	struct wlr_output_state *state, const int32_t *rectangles,
	uint32_t rectangle_count);
ATAXIA_WLR_GLUE_API uint32_t ataxia_output_present_commit_sequence(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API bool ataxia_output_presented(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API int64_t ataxia_output_present_seconds(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API int64_t ataxia_output_present_nanoseconds(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_output_present_sequence(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API int32_t ataxia_output_present_refresh_nanoseconds(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_output_present_flags(
	const struct wlr_output_event_present *event);
ATAXIA_WLR_GLUE_API const struct wlr_output_state *
ataxia_output_requested_state(
	const struct wlr_output_event_request_state *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_output_state_committed(
	const struct wlr_output_state *state);
ATAXIA_WLR_GLUE_API struct wlr_output_state *ataxia_output_state_create(void);
ATAXIA_WLR_GLUE_API void ataxia_output_state_destroy(
	struct wlr_output_state *state);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_input_device_event_destroy(
	struct wlr_input_device *device);
ATAXIA_WLR_GLUE_API const char *ataxia_input_device_name(
	const struct wlr_input_device *device);
ATAXIA_WLR_GLUE_API uint32_t ataxia_input_device_type(
	const struct wlr_input_device *device);

ATAXIA_WLR_GLUE_API struct wlr_pointer *ataxia_input_device_pointer(
	struct wlr_input_device *device);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_event_motion(
	struct wlr_pointer *pointer);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_event_motion_absolute(
	struct wlr_pointer *pointer);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_event_button(
	struct wlr_pointer *pointer);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_event_axis(
	struct wlr_pointer *pointer);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_event_frame(
	struct wlr_pointer *pointer);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_motion_time_msec(
	const struct wlr_pointer_motion_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_motion_delta_x(
	const struct wlr_pointer_motion_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_motion_delta_y(
	const struct wlr_pointer_motion_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_motion_unaccel_dx(
	const struct wlr_pointer_motion_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_motion_unaccel_dy(
	const struct wlr_pointer_motion_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_motion_absolute_time_msec(
	const struct wlr_pointer_motion_absolute_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_motion_absolute_x(
	const struct wlr_pointer_motion_absolute_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_motion_absolute_y(
	const struct wlr_pointer_motion_absolute_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_button_time_msec(
	const struct wlr_pointer_button_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_button_button(
	const struct wlr_pointer_button_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_button_state(
	const struct wlr_pointer_button_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_axis_time_msec(
	const struct wlr_pointer_axis_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_axis_source(
	const struct wlr_pointer_axis_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_axis_orientation(
	const struct wlr_pointer_axis_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_axis_relative_direction(
	const struct wlr_pointer_axis_event *event);
ATAXIA_WLR_GLUE_API double ataxia_pointer_axis_delta(
	const struct wlr_pointer_axis_event *event);
ATAXIA_WLR_GLUE_API int32_t ataxia_pointer_axis_delta_discrete(
	const struct wlr_pointer_axis_event *event);

ATAXIA_WLR_GLUE_API struct wlr_keyboard *ataxia_input_device_keyboard(
	struct wlr_input_device *device);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_keyboard_event_key(
	struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_keyboard_event_modifiers(
	struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_keyboard_event_keymap(
	struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_keyboard_event_repeat_info(
	struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_key_time_msec(
	const struct wlr_keyboard_key_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_key_keycode(
	const struct wlr_keyboard_key_event *event);
ATAXIA_WLR_GLUE_API bool ataxia_keyboard_key_update_state(
	const struct wlr_keyboard_key_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_key_state(
	const struct wlr_keyboard_key_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_modifiers_depressed(
	const struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_modifiers_latched(
	const struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_modifiers_locked(
	const struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_modifiers_group(
	const struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API size_t ataxia_keyboard_keysyms(
	const struct wlr_keyboard *keyboard, uint32_t keycode,
	uint32_t *keysyms, size_t capacity);
ATAXIA_WLR_GLUE_API uint32_t ataxia_keyboard_named_modifiers(
	const struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API int32_t ataxia_keyboard_repeat_rate(
	const struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API int32_t ataxia_keyboard_repeat_delay(
	const struct wlr_keyboard *keyboard);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_seat_event_destroy(
	struct wlr_seat *seat);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_seat_event_request_set_cursor(
	struct wlr_seat *seat);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_seat_event_request_start_drag(
	struct wlr_seat *seat);
ATAXIA_WLR_GLUE_API bool ataxia_seat_pointer_drag_active(
	const struct wlr_seat *seat);
ATAXIA_WLR_GLUE_API uint32_t ataxia_seat_pointer_button_press_count(
	const struct wlr_seat *seat, uint32_t button);
ATAXIA_WLR_GLUE_API struct wlr_drag *ataxia_seat_drag_request_drag(
	const struct wlr_seat_request_start_drag_event *event);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_seat_drag_request_origin(
	const struct wlr_seat_request_start_drag_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_seat_drag_request_serial(
	const struct wlr_seat_request_start_drag_event *event);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_drag_event_destroy(
	struct wlr_drag *drag);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_seat_cursor_surface(
	const struct wlr_seat_pointer_request_set_cursor_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_seat_cursor_serial(
	const struct wlr_seat_pointer_request_set_cursor_event *event);
ATAXIA_WLR_GLUE_API int32_t ataxia_seat_cursor_hotspot_x(
	const struct wlr_seat_pointer_request_set_cursor_event *event);
ATAXIA_WLR_GLUE_API int32_t ataxia_seat_cursor_hotspot_y(
	const struct wlr_seat_pointer_request_set_cursor_event *event);
ATAXIA_WLR_GLUE_API bool ataxia_seat_cursor_request_authorized(
	const struct wlr_seat *seat,
	const struct wlr_seat_pointer_request_set_cursor_event *event);
ATAXIA_WLR_GLUE_API bool ataxia_seat_validate_current_pointer_grab_serial(
	struct wlr_seat *seat, uint32_t serial);
ATAXIA_WLR_GLUE_API void ataxia_seat_keyboard_notify_modifiers_current(
	struct wlr_seat *seat, struct wlr_keyboard *keyboard);
ATAXIA_WLR_GLUE_API void ataxia_seat_keyboard_notify_enter_current(
	struct wlr_seat *seat, struct wlr_surface *surface,
	struct wlr_keyboard *keyboard);

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
ATAXIA_WLR_GLUE_API uint32_t ataxia_surface_effective_damage_rectangles(
	struct wlr_surface *surface, int32_t *rectangles,
	uint32_t rectangle_capacity);
ATAXIA_WLR_GLUE_API uint32_t ataxia_surface_current_transform(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API bool ataxia_surface_buffer_source_box(
	struct wlr_surface *surface, double *x, double *y,
	double *width, double *height);
ATAXIA_WLR_GLUE_API bool ataxia_surface_mapped(
	const struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_subsurface_event_destroy(
	struct wlr_subsurface *subsurface);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_subsurface_surface(
	struct wlr_subsurface *subsurface);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_subsurface_parent(
	struct wlr_subsurface *subsurface);
ATAXIA_WLR_GLUE_API int32_t ataxia_subsurface_x(
	const struct wlr_subsurface *subsurface);
ATAXIA_WLR_GLUE_API int32_t ataxia_subsurface_y(
	const struct wlr_subsurface *subsurface);
ATAXIA_WLR_GLUE_API bool ataxia_subsurface_synchronized(
	const struct wlr_subsurface *subsurface);
ATAXIA_WLR_GLUE_API struct wlr_buffer *ataxia_surface_lock_buffer(
	struct wlr_surface *surface);
ATAXIA_WLR_GLUE_API int32_t ataxia_buffer_width(
	const struct wlr_buffer *buffer);
ATAXIA_WLR_GLUE_API int32_t ataxia_buffer_height(
	const struct wlr_buffer *buffer);
ATAXIA_WLR_GLUE_API struct wlr_texture *ataxia_client_buffer_texture(
	struct wlr_buffer *buffer);
ATAXIA_WLR_GLUE_API uint32_t ataxia_texture_width(
	const struct wlr_texture *texture);
ATAXIA_WLR_GLUE_API uint32_t ataxia_texture_height(
	const struct wlr_texture *texture);
ATAXIA_WLR_GLUE_API uint32_t ataxia_gles2_texture_target(
	struct wlr_texture *texture);
ATAXIA_WLR_GLUE_API uint32_t ataxia_gles2_texture_name(
	struct wlr_texture *texture);
ATAXIA_WLR_GLUE_API bool ataxia_gles2_texture_has_alpha(
	struct wlr_texture *texture);

ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_shell_event_new_toplevel(
	struct wlr_xdg_shell *shell);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_shell_event_new_popup(
	struct wlr_xdg_shell *shell);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_shell_event_destroy(
	struct wlr_xdg_shell *shell);
ATAXIA_WLR_GLUE_API struct wlr_xdg_surface *ataxia_xdg_toplevel_base(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_xdg_surface_surface(
	struct wlr_xdg_surface *surface);
ATAXIA_WLR_GLUE_API bool ataxia_xdg_surface_initial_commit(
	const struct wlr_xdg_surface *surface);
ATAXIA_WLR_GLUE_API bool ataxia_xdg_surface_configured(
	const struct wlr_xdg_surface *surface);
ATAXIA_WLR_GLUE_API bool ataxia_xdg_surface_geometry(
	const struct wlr_xdg_surface *surface, int32_t geometry[4]);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_surface_event_destroy(
	struct wlr_xdg_surface *surface);
ATAXIA_WLR_GLUE_API const char *ataxia_xdg_toplevel_title(
	const struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API const char *ataxia_xdg_toplevel_app_id(
	const struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API bool ataxia_xdg_toplevel_requested_maximized(
	const struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API bool ataxia_xdg_toplevel_requested_minimized(
	const struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API bool ataxia_xdg_toplevel_requested_fullscreen(
	const struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wlr_output *
ataxia_xdg_toplevel_requested_fullscreen_output(
	const struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_toplevel_event_destroy(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_event_request_maximize(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_event_request_fullscreen(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_event_request_minimize(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_toplevel_event_request_move(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_event_request_resize(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_event_request_show_window_menu(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_toplevel_event_set_parent(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_toplevel_event_set_title(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_toplevel_event_set_app_id(
	struct wlr_xdg_toplevel *toplevel);
ATAXIA_WLR_GLUE_API struct wlr_seat *ataxia_xdg_move_seat(
	const struct wlr_xdg_toplevel_move_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_xdg_move_serial(
	const struct wlr_xdg_toplevel_move_event *event);
ATAXIA_WLR_GLUE_API struct wlr_seat *ataxia_xdg_resize_seat(
	const struct wlr_xdg_toplevel_resize_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_xdg_resize_serial(
	const struct wlr_xdg_toplevel_resize_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_xdg_resize_edges(
	const struct wlr_xdg_toplevel_resize_event *event);
ATAXIA_WLR_GLUE_API struct wlr_seat *ataxia_xdg_window_menu_seat(
	const struct wlr_xdg_toplevel_show_window_menu_event *event);
ATAXIA_WLR_GLUE_API uint32_t ataxia_xdg_window_menu_serial(
	const struct wlr_xdg_toplevel_show_window_menu_event *event);
ATAXIA_WLR_GLUE_API int32_t ataxia_xdg_window_menu_x(
	const struct wlr_xdg_toplevel_show_window_menu_event *event);
ATAXIA_WLR_GLUE_API int32_t ataxia_xdg_window_menu_y(
	const struct wlr_xdg_toplevel_show_window_menu_event *event);
ATAXIA_WLR_GLUE_API struct wlr_xdg_surface *ataxia_xdg_popup_base(
	struct wlr_xdg_popup *popup);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_xdg_popup_parent_surface(
	struct wlr_xdg_popup *popup);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_popup_event_destroy(
	struct wlr_xdg_popup *popup);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_popup_event_reposition(
	struct wlr_xdg_popup *popup);

ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_decoration_manager_event_new_toplevel(
	struct wlr_xdg_decoration_manager_v1 *manager);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_decoration_manager_event_destroy(
	struct wlr_xdg_decoration_manager_v1 *manager);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_decoration_event_request_mode(
	struct wlr_xdg_toplevel_decoration_v1 *decoration);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_toplevel_decoration_event_destroy(
	struct wlr_xdg_toplevel_decoration_v1 *decoration);
ATAXIA_WLR_GLUE_API struct wlr_xdg_toplevel *
ataxia_xdg_toplevel_decoration_toplevel(
	struct wlr_xdg_toplevel_decoration_v1 *decoration);
ATAXIA_WLR_GLUE_API uint32_t ataxia_xdg_toplevel_decoration_requested_mode(
	const struct wlr_xdg_toplevel_decoration_v1 *decoration);

ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_xdg_activation_event_request_activate(
	struct wlr_xdg_activation_v1 *activation);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_xdg_activation_event_destroy(
	struct wlr_xdg_activation_v1 *activation);
ATAXIA_WLR_GLUE_API struct wlr_surface *
ataxia_xdg_activation_request_surface(
	const struct wlr_xdg_activation_v1_request_activate_event *event);
ATAXIA_WLR_GLUE_API struct wlr_xdg_activation_token_v1 *
ataxia_xdg_activation_request_token(
	const struct wlr_xdg_activation_v1_request_activate_event *event);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_xdg_activation_token_surface(
	const struct wlr_xdg_activation_token_v1 *token);
ATAXIA_WLR_GLUE_API struct wlr_seat *ataxia_xdg_activation_token_seat(
	const struct wlr_xdg_activation_token_v1 *token);
ATAXIA_WLR_GLUE_API uint32_t ataxia_xdg_activation_token_serial(
	const struct wlr_xdg_activation_token_v1 *token);
ATAXIA_WLR_GLUE_API const char *ataxia_xdg_activation_token_app_id(
	const struct wlr_xdg_activation_token_v1 *token);

ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_pointer_constraints_event_new_constraint(
	struct wlr_pointer_constraints_v1 *manager);
ATAXIA_WLR_GLUE_API struct wl_signal *
ataxia_pointer_constraints_event_destroy(
	struct wlr_pointer_constraints_v1 *manager);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_constraint_event_set_region(
	struct wlr_pointer_constraint_v1 *constraint);
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_constraint_event_destroy(
	struct wlr_pointer_constraint_v1 *constraint);
ATAXIA_WLR_GLUE_API struct wlr_surface *ataxia_pointer_constraint_surface(
	const struct wlr_pointer_constraint_v1 *constraint);
ATAXIA_WLR_GLUE_API struct wlr_seat *ataxia_pointer_constraint_seat(
	const struct wlr_pointer_constraint_v1 *constraint);
ATAXIA_WLR_GLUE_API uint32_t ataxia_pointer_constraint_type(
	const struct wlr_pointer_constraint_v1 *constraint);
ATAXIA_WLR_GLUE_API bool ataxia_pointer_constraint_confine(
	const struct wlr_pointer_constraint_v1 *constraint,
	double x1, double y1, double x2, double y2,
	double *confined_x, double *confined_y);
ATAXIA_WLR_GLUE_API bool ataxia_pointer_constraint_region_empty(
	const struct wlr_pointer_constraint_v1 *constraint);
ATAXIA_WLR_GLUE_API bool ataxia_pointer_constraint_cursor_hint(
	const struct wlr_pointer_constraint_v1 *constraint,
	double *x, double *y);

struct ataxia_gesture_sample {
 uint32_t time_msec, fingers, cancelled;
 double dx, dy, scale, rotation;
};
ATAXIA_WLR_GLUE_API struct wl_signal *ataxia_pointer_gesture_signal(struct wlr_pointer *pointer, uint32_t kind, uint32_t phase);
ATAXIA_WLR_GLUE_API void ataxia_pointer_gesture_read(const void *event, uint32_t kind, uint32_t phase, struct ataxia_gesture_sample *sample);

#endif
