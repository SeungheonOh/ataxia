;;;; CFFI boundary to the World-owned Slint interpreter host.
;;;;
;;;; Rust retains Slint scene objects and CPU pixel buffers. Every returned
;;;; pointer is consumed synchronously by Lisp and is never retained by Kernel.

(in-package #:ataxia.world.slint.raw)

(defconstant +expected-abi+ 1)

(defcstruct damage-rectangle
  (x :int32)
  (y :int32)
  (width :uint32)
  (height :uint32))

(defun library-path ()
  (or (uiop:getenv "ATAXIA_SLINT_NATIVE")
      (namestring
       (asdf:system-relative-pathname
        "ataxia-slint" "build/libataxia-slint-native.so"))))

(defvar *library-loaded-p* nil)

(defun load-library ()
  (unless *library-loaded-p*
    (load-foreign-library (library-path))
    (setf *library-loaded-p* t))
  t)

(defcfun ("ataxia_slint_abi_version" %abi-version) :uint32)
(defcfun ("ataxia_slint_last_error" %last-error) :string)
(defcfun ("ataxia_slint_initialize" %initialize) :boolean)
(defcfun ("ataxia_slint_component_create" %component-create) :pointer
  (source :string) (source-path :string) (component-name :string)
  (width :uint32) (height :uint32) (scale :float))
(defcfun ("ataxia_slint_component_destroy" %component-destroy) :void
  (component :pointer))
(defcfun ("ataxia_slint_component_resize" %component-resize) :boolean
  (component :pointer) (width :uint32) (height :uint32) (scale :float))
(defcfun ("ataxia_slint_component_render" %component-render) :boolean
  (component :pointer))
(defcfun ("ataxia_slint_component_pixels" %component-pixels) :pointer
  (component :pointer))
(defcfun ("ataxia_slint_component_width" %component-width) :uint32
  (component :pointer))
(defcfun ("ataxia_slint_component_height" %component-height) :uint32
  (component :pointer))
(defcfun ("ataxia_slint_component_revision" %component-revision) :uint64
  (component :pointer))
(defcfun ("ataxia_slint_component_damage_count" %component-damage-count) :size
  (component :pointer))
(defcfun ("ataxia_slint_component_damage_rectangle"
          %component-damage-rectangle) :boolean
  (component :pointer) (index :size) (rectangle (:pointer (:struct damage-rectangle))))
(defcfun ("ataxia_slint_component_has_active_animations"
          %component-active-p) :boolean
  (component :pointer))
(defcfun ("ataxia_slint_update_timers" %update-timers) :void)
(defcfun ("ataxia_slint_next_timer_milliseconds" %next-timer-milliseconds)
    :uint64)
(defcfun ("ataxia_slint_component_pointer_motion" %pointer-motion) :boolean
  (component :pointer) (x :float) (y :float))
(defcfun ("ataxia_slint_component_pointer_button" %pointer-button) :boolean
  (component :pointer) (x :float) (y :float) (button :uint32)
  (pressed :boolean))
(defcfun ("ataxia_slint_component_pointer_scroll" %pointer-scroll) :boolean
  (component :pointer) (x :float) (y :float) (delta-x :float) (delta-y :float))
(defcfun ("ataxia_slint_component_pointer_exit" %pointer-exit) :boolean
  (component :pointer))
(defcfun ("ataxia_slint_component_focus" %focus) :boolean
  (component :pointer) (focused :boolean))
(defcfun ("ataxia_slint_component_modifiers" %modifiers) :boolean
  (component :pointer) (depressed :uint32) (latched :uint32)
  (locked :uint32) (group :uint32))
(defcfun ("ataxia_slint_component_key" %key) :boolean
  (component :pointer) (keycode :uint32) (pressed :boolean) (repeated :boolean))
(defcfun ("ataxia_slint_component_set_string" %set-string) :boolean
  (component :pointer) (name :string) (value :string))
(defcfun ("ataxia_slint_component_set_number" %set-number) :boolean
  (component :pointer) (name :string) (value :double))
(defcfun ("ataxia_slint_component_set_boolean" %set-boolean) :boolean
  (component :pointer) (name :string) (value :boolean))

(defun native-error (operation)
  (error "Slint ~A failed: ~A" operation (or (%last-error) "unknown error")))

(defun check-result (result operation)
  (unless result (native-error operation))
  result)

(defun initialize ()
  (load-library)
  (unless (= (%abi-version) +expected-abi+)
    (error "Slint native ABI mismatch: expected ~D, received ~D."
           +expected-abi+ (%abi-version)))
  (check-result (%initialize) :initialize))
