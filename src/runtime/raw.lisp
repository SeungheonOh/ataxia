;;;; Direct libwayland, wlroots, and native-glue bindings.
;;;;
;;;; This module mirrors concrete public C functions. Struct-field and signal
;;;; access is restricted to the tiny version-pinned native glue library.

(in-package #:ataxia.runtime.raw)

(defconstant +expected-glue-abi+ 7)
(defparameter +expected-wlroots-version+ "0.20.2")

(define-foreign-library libwayland-server
  (:unix (:or "libwayland-server.so.0" "libwayland-server.so")))

(define-foreign-library libwlroots
  (:unix (:or "libwlroots-0.20.so" "libwlroots-0.20.so.0")))

(define-foreign-library libegl
  (:unix (:or "libEGL.so.1" "libEGL.so")))

(define-foreign-library libxkbcommon
  (:unix (:or "libxkbcommon.so.0" "libxkbcommon.so")))

(defvar *native-libraries-loaded-p* nil)

(defun glue-library-path ()
  (or (uiop:getenv "ATAXIA_WLR_GLUE")
      (namestring
       (asdf:system-relative-pathname
        "ataxia-runtime" "build/libataxia-wlr-glue.so"))))

(defun load-native-libraries ()
  (unless *native-libraries-loaded-p*
    (use-foreign-library libwayland-server)
    (use-foreign-library libwlroots)
    (use-foreign-library libegl)
    (use-foreign-library libxkbcommon)
    (load-foreign-library (glue-library-path))
    (setf *native-libraries-loaded-p* t))
  t)

(defcfun ("ataxia_wlr_glue_abi_version" %glue-abi-version) :uint32)
(defcfun ("ataxia_wlr_glue_wlroots_version" %glue-wlroots-version) :string)

(defun verify-native-abi ()
  (let ((actual-abi (%glue-abi-version))
        (actual-version (%glue-wlroots-version)))
    (unless (= actual-abi +expected-glue-abi+)
      (error 'ataxia.runtime:native-abi-mismatch
             :subject :glue
             :expected +expected-glue-abi+
             :actual actual-abi))
    (unless (string= actual-version +expected-wlroots-version+)
      (error 'ataxia.runtime:native-abi-mismatch
             :subject :wlroots
             :expected +expected-wlroots-version+
             :actual actual-version)))
  t)

(defcfun ("wl_display_create" %wl-display-create) :pointer)
(defcfun ("wl_display_destroy" %wl-display-destroy) :void
  (display :pointer))
(defcfun ("wl_display_destroy_clients" %wl-display-destroy-clients) :void
  (display :pointer))
(defcfun ("wl_display_get_event_loop" %wl-display-get-event-loop) :pointer
  (display :pointer))
(defcfun ("wl_display_add_socket_auto" %wl-display-add-socket-auto) :pointer
  (display :pointer))
(defcfun ("wl_display_flush_clients" %wl-display-flush-clients) :void
  (display :pointer))
(defcfun ("wl_event_loop_dispatch" %wl-event-loop-dispatch) :int
  (event-loop :pointer)
  (timeout-milliseconds :int))

(defcfun ("wlr_log_init" %wlr-log-init) :void
  (verbosity :int)
  (callback :pointer))
(defcfun ("wlr_backend_autocreate" %wlr-backend-autocreate) :pointer
  (event-loop :pointer)
  (session-pointer :pointer))
(defcfun ("wlr_headless_backend_create" %wlr-headless-backend-create) :pointer
  (event-loop :pointer))
(defcfun ("wlr_headless_add_output" %wlr-headless-add-output) :pointer
  (backend :pointer)
  (width :unsigned-int)
  (height :unsigned-int))
(defcfun ("wlr_backend_start" %wlr-backend-start) :boolean
  (backend :pointer))
(defcfun ("wlr_backend_destroy" %wlr-backend-destroy) :void
  (backend :pointer))

(defcfun ("wlr_renderer_autocreate" %wlr-renderer-autocreate) :pointer
  (backend :pointer))
(defcfun ("wlr_renderer_is_gles2" %wlr-renderer-is-gles2) :boolean
  (renderer :pointer))
(defcfun ("wlr_gles2_renderer_get_egl" %wlr-gles2-renderer-get-egl) :pointer
  (renderer :pointer))
(defcfun ("wlr_renderer_init_wl_display" %wlr-renderer-init-wl-display)
    :boolean
  (renderer :pointer)
  (display :pointer))
(defcfun ("wlr_renderer_destroy" %wlr-renderer-destroy) :void
  (renderer :pointer))

(defcfun ("wlr_allocator_autocreate" %wlr-allocator-autocreate) :pointer
  (backend :pointer)
  (renderer :pointer))
(defcfun ("wlr_allocator_destroy" %wlr-allocator-destroy) :void
  (allocator :pointer))

(defcfun ("wlr_compositor_create" %wlr-compositor-create) :pointer
  (display :pointer)
  (version :uint32)
  (renderer :pointer))
(defcfun ("wlr_subcompositor_create" %wlr-subcompositor-create) :pointer
  (display :pointer))

(defcfun ("wlr_seat_create" %wlr-seat-create) :pointer
  (display :pointer)
  (name :string))
(defcfun ("wlr_seat_destroy" %wlr-seat-destroy) :void
  (seat :pointer))
(defcfun ("wlr_seat_set_capabilities" %wlr-seat-set-capabilities) :void
  (seat :pointer)
  (capabilities :uint32))
(defcfun ("wlr_seat_set_name" %wlr-seat-set-name) :void
  (seat :pointer)
  (name :string))
(defcfun ("wlr_data_device_manager_create"
          %wlr-data-device-manager-create)
    :pointer
  (display :pointer))
(defcfun ("wlr_seat_set_keyboard" %wlr-seat-set-keyboard) :void
  (seat :pointer)
  (keyboard :pointer))
(defcfun ("wlr_seat_pointer_notify_enter" %wlr-seat-pointer-notify-enter)
    :void
  (seat :pointer)
  (surface :pointer)
  (surface-x :double)
  (surface-y :double))
(defcfun ("wlr_seat_pointer_notify_clear_focus"
          %wlr-seat-pointer-notify-clear-focus)
    :void
  (seat :pointer))
(defcfun ("wlr_seat_pointer_notify_motion" %wlr-seat-pointer-notify-motion)
    :void
  (seat :pointer)
  (time-msec :uint32)
  (surface-x :double)
  (surface-y :double))
(defcfun ("wlr_seat_pointer_notify_button" %wlr-seat-pointer-notify-button)
    :uint32
  (seat :pointer)
  (time-msec :uint32)
  (button :uint32)
  (state :uint32))
(defcfun ("wlr_seat_pointer_notify_axis" %wlr-seat-pointer-notify-axis) :void
  (seat :pointer)
  (time-msec :uint32)
  (orientation :uint32)
  (value :double)
  (value-discrete :int32)
  (source :uint32)
  (relative-direction :uint32))
(defcfun ("wlr_seat_pointer_notify_frame" %wlr-seat-pointer-notify-frame)
    :void
  (seat :pointer))
(defcfun ("wlr_seat_validate_pointer_grab_serial"
          %wlr-seat-validate-pointer-grab-serial)
    :boolean
  (seat :pointer)
  (origin :pointer)
  (serial :uint32))
(defcfun ("wlr_seat_keyboard_notify_key" %wlr-seat-keyboard-notify-key) :void
  (seat :pointer)
  (time-msec :uint32)
  (keycode :uint32)
  (state :uint32))
(defcfun ("wlr_seat_keyboard_notify_clear_focus"
          %wlr-seat-keyboard-notify-clear-focus)
    :void
  (seat :pointer))

(defcfun ("ataxia_listener_create" %glue-listener-create) :pointer
  (cookie :uintptr)
  (callback :pointer))
(defcfun ("ataxia_listener_attach" %glue-listener-attach) :boolean
  (listener :pointer)
  (signal :pointer))
(defcfun ("ataxia_listener_detach" %glue-listener-detach) :boolean
  (listener :pointer))
(defcfun ("ataxia_listener_destroy" %glue-listener-destroy) :void
  (listener :pointer))

(defmacro define-signal-binding (lisp-name c-name object-name)
  `(defcfun (,c-name ,lisp-name) :pointer (,object-name :pointer)))

(define-signal-binding %backend-event-destroy
  "ataxia_backend_event_destroy" backend)
(define-signal-binding %backend-event-new-input
  "ataxia_backend_event_new_input" backend)
(define-signal-binding %backend-event-new-output
  "ataxia_backend_event_new_output" backend)
(define-signal-binding %renderer-event-destroy
  "ataxia_renderer_event_destroy" renderer)
(define-signal-binding %renderer-event-lost
  "ataxia_renderer_event_lost" renderer)
(define-signal-binding %allocator-event-destroy
  "ataxia_allocator_event_destroy" allocator)
(define-signal-binding %compositor-event-new-surface
  "ataxia_compositor_event_new_surface" compositor)
(define-signal-binding %compositor-event-destroy
  "ataxia_compositor_event_destroy" compositor)
(define-signal-binding %output-event-frame
  "ataxia_output_event_frame" output)
(define-signal-binding %output-event-destroy
  "ataxia_output_event_destroy" output)
(define-signal-binding %input-device-event-destroy
  "ataxia_input_device_event_destroy" device)
(define-signal-binding %seat-event-destroy
  "ataxia_seat_event_destroy" seat)
(define-signal-binding %seat-event-request-set-cursor
  "ataxia_seat_event_request_set_cursor" seat)
(defcfun ("ataxia_seat_cursor_surface" %seat-cursor-surface) :pointer
  (event :pointer))
(defcfun ("ataxia_seat_cursor_serial" %seat-cursor-serial) :uint32
  (event :pointer))
(defcfun ("ataxia_seat_cursor_hotspot_x" %seat-cursor-hotspot-x) :int32
  (event :pointer))
(defcfun ("ataxia_seat_cursor_hotspot_y" %seat-cursor-hotspot-y) :int32
  (event :pointer))
(define-signal-binding %surface-event-commit
  "ataxia_surface_event_commit" surface)
(define-signal-binding %surface-event-map
  "ataxia_surface_event_map" surface)
(define-signal-binding %surface-event-unmap
  "ataxia_surface_event_unmap" surface)
(define-signal-binding %surface-event-new-subsurface
  "ataxia_surface_event_new_subsurface" surface)
(define-signal-binding %surface-event-destroy
  "ataxia_surface_event_destroy" surface)

(defcfun ("ataxia_output_name" %output-name) :pointer
  (output :pointer))
(defcfun ("ataxia_output_description" %output-description) :pointer
  (output :pointer))
(defcfun ("ataxia_output_width" %output-width) :int32
  (output :pointer))
(defcfun ("ataxia_output_height" %output-height) :int32
  (output :pointer))
(defcfun ("ataxia_output_scale" %output-scale) :float
  (output :pointer))
(defcfun ("ataxia_output_enabled" %output-enabled) :boolean
  (output :pointer))
(defcfun ("ataxia_output_frame_pending" %output-frame-pending) :boolean
  (output :pointer))

(defcfun ("ataxia_input_device_name" %input-device-name) :pointer
  (device :pointer))
(defcfun ("ataxia_input_device_type" %input-device-type) :uint32
  (device :pointer))
(defcfun ("ataxia_input_device_pointer" %input-device-pointer) :pointer
  (device :pointer))

(define-signal-binding %pointer-event-motion
  "ataxia_pointer_event_motion" pointer)
(define-signal-binding %pointer-event-motion-absolute
  "ataxia_pointer_event_motion_absolute" pointer)
(define-signal-binding %pointer-event-button
  "ataxia_pointer_event_button" pointer)
(define-signal-binding %pointer-event-axis
  "ataxia_pointer_event_axis" pointer)
(define-signal-binding %pointer-event-frame
  "ataxia_pointer_event_frame" pointer)

(defcfun ("ataxia_pointer_motion_time_msec" %pointer-motion-time-msec)
    :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_motion_delta_x" %pointer-motion-delta-x) :double
  (event :pointer))
(defcfun ("ataxia_pointer_motion_delta_y" %pointer-motion-delta-y) :double
  (event :pointer))
(defcfun ("ataxia_pointer_motion_unaccel_dx" %pointer-motion-unaccel-dx)
    :double
  (event :pointer))
(defcfun ("ataxia_pointer_motion_unaccel_dy" %pointer-motion-unaccel-dy)
    :double
  (event :pointer))
(defcfun ("ataxia_pointer_motion_absolute_time_msec"
          %pointer-motion-absolute-time-msec)
    :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_motion_absolute_x" %pointer-motion-absolute-x)
    :double
  (event :pointer))
(defcfun ("ataxia_pointer_motion_absolute_y" %pointer-motion-absolute-y)
    :double
  (event :pointer))
(defcfun ("ataxia_pointer_button_time_msec" %pointer-button-time-msec)
    :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_button_button" %pointer-button-button) :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_button_state" %pointer-button-state) :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_axis_time_msec" %pointer-axis-time-msec) :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_axis_source" %pointer-axis-source) :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_axis_orientation" %pointer-axis-orientation)
    :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_axis_relative_direction"
          %pointer-axis-relative-direction)
    :uint32
  (event :pointer))
(defcfun ("ataxia_pointer_axis_delta" %pointer-axis-delta) :double
  (event :pointer))
(defcfun ("ataxia_pointer_axis_delta_discrete" %pointer-axis-delta-discrete)
    :int32
  (event :pointer))

(defcfun ("ataxia_input_device_keyboard" %input-device-keyboard) :pointer
  (device :pointer))
(define-signal-binding %keyboard-event-key
  "ataxia_keyboard_event_key" keyboard)
(define-signal-binding %keyboard-event-modifiers
  "ataxia_keyboard_event_modifiers" keyboard)
(define-signal-binding %keyboard-event-keymap
  "ataxia_keyboard_event_keymap" keyboard)
(define-signal-binding %keyboard-event-repeat-info
  "ataxia_keyboard_event_repeat_info" keyboard)
(defcfun ("ataxia_keyboard_key_time_msec" %keyboard-key-time-msec) :uint32
  (event :pointer))
(defcfun ("ataxia_keyboard_key_keycode" %keyboard-key-keycode) :uint32
  (event :pointer))
(defcfun ("ataxia_keyboard_key_update_state" %keyboard-key-update-state)
    :boolean
  (event :pointer))
(defcfun ("ataxia_keyboard_key_state" %keyboard-key-state) :uint32
  (event :pointer))
(defcfun ("ataxia_keyboard_modifiers_depressed"
          %keyboard-modifiers-depressed)
    :uint32
  (keyboard :pointer))
(defcfun ("ataxia_keyboard_modifiers_latched" %keyboard-modifiers-latched)
    :uint32
  (keyboard :pointer))
(defcfun ("ataxia_keyboard_modifiers_locked" %keyboard-modifiers-locked)
    :uint32
  (keyboard :pointer))
(defcfun ("ataxia_keyboard_modifiers_group" %keyboard-modifiers-group)
    :uint32
  (keyboard :pointer))
(defcfun ("ataxia_keyboard_repeat_rate" %keyboard-repeat-rate) :int32
  (keyboard :pointer))
(defcfun ("ataxia_keyboard_repeat_delay" %keyboard-repeat-delay) :int32
  (keyboard :pointer))
(defcfun ("ataxia_seat_keyboard_notify_modifiers_current"
          %seat-keyboard-notify-modifiers-current)
    :void
  (seat :pointer)
  (keyboard :pointer))
(defcfun ("ataxia_seat_keyboard_notify_enter_current"
          %seat-keyboard-notify-enter-current)
    :void
  (seat :pointer)
  (surface :pointer)
  (keyboard :pointer))

(defcfun ("ataxia_surface_current_committed" %surface-current-committed)
    :uint32
  (surface :pointer))
(defcfun ("ataxia_surface_current_sequence" %surface-current-sequence)
    :uint32
  (surface :pointer))
(defcfun ("ataxia_surface_current_width" %surface-current-width) :int32
  (surface :pointer))
(defcfun ("ataxia_surface_current_height" %surface-current-height) :int32
  (surface :pointer))
(defcfun ("ataxia_surface_current_buffer_width"
          %surface-current-buffer-width)
    :int32
  (surface :pointer))
(defcfun ("ataxia_surface_current_buffer_height"
          %surface-current-buffer-height)
    :int32
  (surface :pointer))
(defcfun ("ataxia_surface_effective_damage_rectangles"
          %surface-effective-damage-rectangles)
    :uint32
  (surface :pointer)
  (rectangles :pointer)
  (rectangle-capacity :uint32))
(defcfun ("ataxia_surface_current_transform" %surface-current-transform)
    :uint32
  (surface :pointer))
(defcfun ("ataxia_surface_buffer_source_box" %surface-buffer-source-box)
    :boolean
  (surface :pointer)
  (x :pointer)
  (y :pointer)
  (width :pointer)
  (height :pointer))
(defcfun ("ataxia_surface_mapped" %surface-mapped) :boolean
  (surface :pointer))
