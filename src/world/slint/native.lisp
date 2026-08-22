;;;; Direct Common Lisp binding to Slint's native ABI.
;;;;
;;;; Slint 1.16.1 exports the ABI used by its C++ package. This module binds it
;;;; directly: Lisp supplies the platform and window callbacks, owns component
;;;; state and pixel buffers, and forwards rendering and input without a shim.

(in-package #:ataxia.world.slint.raw)

(defparameter +slint-abi-version+ "1.16.1")
(defconstant +window-event-size+ 24)
(defconstant +window-event-pointer-pressed+ 0)
(defconstant +window-event-pointer-released+ 1)
(defconstant +window-event-pointer-moved+ 2)
(defconstant +window-event-pointer-scrolled+ 3)
(defconstant +window-event-pointer-exited+ 4)
(defconstant +window-event-scale-factor-changed+ 8)
(defconstant +window-event-resized+ 9)
(defconstant +window-event-window-active-changed+ 11)
(defconstant +item-tree-drop-offset+ 128)
(defconstant +item-tree-deallocate-offset+ 136)

(defcstruct damage-rectangle
  (x :int32)
  (y :int32)
  (width :uint32)
  (height :uint32))

(defcstruct byte-slice
  (pointer :pointer)
  (length :size))

(defcstruct renderer-pointer
  (data :pointer)
  (vtable :pointer))

(defcstruct integer-size
  (width :uint32)
  (height :uint32))

(defcstruct integer-point
  (x :int32)
  (y :int32))

(defcstruct platform-task
  (data :pointer)
  (vtable :pointer))

(defcstruct short-point
  (x :int16)
  (y :int16))

(defcstruct short-box
  (minimum (:struct short-point))
  (maximum (:struct short-point)))

(defcstruct physical-region
  (rectangle-0 (:struct short-box))
  (rectangle-1 (:struct short-box))
  (rectangle-2 (:struct short-box))
  (count :size))

(defcstruct vtable-reference
  (vtable :pointer)
  (instance :pointer))

(defcstruct allocation-layout
  (size :size)
  (alignment :size))

(defcstruct xkb-rule-names
  (rules :pointer)
  (model :pointer)
  (layout :pointer)
  (variant :pointer)
  (options :pointer))

(defstruct (window-state (:constructor %make-window-state (width height)))
  (id 0 :type integer)
  (renderer (null-pointer))
  (width 1 :type (integer 1))
  (height 1 :type (integer 1))
  (visible-p nil)
  (redraw-p t))

(defstruct (native-component (:constructor %make-native-component))
  instance
  instance-data
  window
  window-state
  pixels
  (width 1 :type (integer 1))
  (height 1 :type (integer 1))
  (scale 1.0f0 :type single-float)
  (revision 0 :type (unsigned-byte 64))
  (damage nil :type list)
  xkb-context
  xkb-keymap
  xkb-state
  (pressed-keys (make-hash-table :test #'eql))
  (destroyed-p nil))

(defstruct (aggregate-callback (:constructor %make-aggregate-callback))
  code
  closure
  cif
  handler-id)

(defvar *library-loaded-p* nil)
(defvar *platform-installed-p* nil)
(defvar *pending-window-state* nil)
(defvar *window-states* (make-hash-table :test #'eql))
(defvar *next-window-id* 0)
(defvar *last-error* "")
(defvar *clipboard-text* (make-hash-table :test #'eql))
(defvar *aggregate-callback-handlers* (make-hash-table :test #'eql))
(defvar *next-aggregate-callback-id* 0)
(defvar *window-renderer-callback* nil)
(defvar *window-size-callback* nil)
(defvar *window-set-size-callback* nil)
(defvar *window-set-position-callback* nil)
(defvar *platform-invoke-callback* nil)

(defcfun ("ffi_get_default_abi" %ffi-default-abi) :uint)
(defcfun ("ffi_get_closure_size" %ffi-closure-size) :size)
(defcfun ("ffi_closure_alloc" %ffi-closure-alloc) :pointer
  (size :size)
  (code :pointer))
(defcfun ("ffi_closure_free" %ffi-closure-free) :void
  (closure :pointer))
(defcfun ("ffi_prep_closure_loc" %ffi-prepare-closure) :int
  (closure :pointer)
  (cif :pointer)
  (callback :pointer)
  (user-data :pointer)
  (code :pointer))

(defcfun ("slint_platform_register" %platform-register) :void
  (user-data :pointer)
  (drop :pointer)
  (window-factory :pointer)
  (duration-since-start :pointer)
  (set-clipboard-text :pointer)
  (clipboard-text :pointer)
  (run-event-loop :pointer)
  (quit-event-loop :pointer)
  (invoke-from-event-loop :pointer))

(defcfun ("slint_window_adapter_new" %window-adapter-new) :void
  (user-data :pointer)
  (drop :pointer)
  (renderer :pointer)
  (set-visible :pointer)
  (request-redraw :pointer)
  (size :pointer)
  (set-size :pointer)
  (update-properties :pointer)
  (position :pointer)
  (set-position :pointer)
  (target :pointer))

(defcfun ("slint_platform_update_timers_and_animations" %update-timers) :void)
(defcfun ("slint_platform_duration_until_next_timer_update"
          %next-timer-milliseconds) :uint64)
(defcfun ("slint_platform_task_run" %platform-task-run) :void
  (task (:struct platform-task)))

(defcfun ("slint_software_renderer_new" %software-renderer-new) :pointer
  (buffer-age :uint32))
(defcfun ("slint_software_renderer_drop" %software-renderer-drop) :void
  (renderer :pointer))
(defcfun ("slint_software_renderer_handle" %software-renderer-handle)
    (:struct renderer-pointer)
  (renderer :pointer))
(defcfun ("slint_software_renderer_render_rgb8" %software-renderer-render)
    (:struct physical-region)
  (renderer :pointer)
  (pixels :pointer)
  (pixel-count :size)
  (pixel-stride :size))

(defcfun ("slint_shared_string_bytes" %shared-string-bytes) :pointer
  (string :pointer))
(defcfun ("slint_shared_string_drop" %shared-string-drop) :void
  (string :pointer))
(defcfun ("slint_shared_string_from_bytes" %shared-string-from-bytes) :void
  (output :pointer)
  (bytes :pointer)
  (length :size))

(defcfun ("slint_interpreter_component_compiler_new" %compiler-new) :void
  (compiler :pointer))
(defcfun ("slint_interpreter_component_compiler_destructor"
          %compiler-destroy) :void
  (compiler :pointer))
(defcfun ("slint_interpreter_component_compiler_build_from_source"
          %compiler-build-from-source) :uint8
  (compiler :pointer)
  (source (:struct byte-slice))
  (path (:struct byte-slice))
  (definition :pointer))
(defcfun ("slint_interpreter_component_definition_destructor"
          %definition-destroy) :void
  (definition :pointer))
(defcfun ("slint_interpreter_component_definition_name"
          %definition-name) :void
  (definition :pointer)
  (name :pointer))
(defcfun ("slint_interpreter_component_instance_create" %instance-create) :void
  (definition :pointer)
  (instance :pointer))
(defcfun ("slint_interpreter_component_instance_window" %instance-window) :void
  (instance-data :pointer)
  (window :pointer))
(defcfun ("slint_interpreter_component_instance_show" %instance-show) :void
  (instance-data :pointer)
  (visible :boolean))
(defcfun ("slint_interpreter_component_instance_set_property"
          %instance-set-property) :uint8
  (instance-data :pointer)
  (name (:struct byte-slice))
  (value :pointer))

(defcfun ("slint_interpreter_value_new_string" %value-new-string) :pointer
  (value :pointer))
(defcfun ("slint_interpreter_value_new_double" %value-new-double) :pointer
  (value :double))
(defcfun ("slint_interpreter_value_new_bool" %value-new-boolean) :pointer
  (value :boolean))
(defcfun ("slint_interpreter_value_destructor" %value-destroy) :void
  (value :pointer))

(defcfun ("slint_windowrc_set_physical_size" %window-set-physical-size) :void
  (window :pointer)
  (size :pointer))
(defcfun ("slint_windowrc_request_redraw" %window-request-redraw) :void
  (window :pointer))
(defcfun ("slint_windowrc_has_active_animations" %window-active-p) :boolean
  (window :pointer))
(defcfun ("slint_windowrc_dispatch_key_event" %window-dispatch-key) :void
  (window :pointer)
  (event-type :uint8)
  (text :pointer)
  (repeated :boolean))
(defcfun ("slint_windowrc_dispatch_event" %window-dispatch-event) :void
  (window :pointer)
  (event :pointer))

(defcfun ("xkb_context_new" %xkb-context-new) :pointer
  (flags :uint32))
(defcfun ("xkb_context_unref" %xkb-context-unref) :void
  (context :pointer))
(defcfun ("xkb_keymap_new_from_names" %xkb-keymap-new-from-names) :pointer
  (context :pointer)
  (names :pointer)
  (flags :uint32))
(defcfun ("xkb_keymap_unref" %xkb-keymap-unref) :void
  (keymap :pointer))
(defcfun ("xkb_state_new" %xkb-state-new) :pointer
  (keymap :pointer))
(defcfun ("xkb_state_unref" %xkb-state-unref) :void
  (state :pointer))
(defcfun ("xkb_state_update_mask" %xkb-state-update-mask) :uint32
  (state :pointer)
  (depressed :uint32)
  (latched :uint32)
  (locked :uint32)
  (depressed-layout :uint32)
  (latched-layout :uint32)
  (locked-layout :uint32))
(defcfun ("xkb_state_key_get_utf8" %xkb-state-key-get-utf8) :int
  (state :pointer)
  (keycode :uint32)
  (buffer :pointer)
  (size :size))
(defcfun ("xkb_state_key_get_one_sym" %xkb-state-key-get-one-symbol) :uint32
  (state :pointer)
  (keycode :uint32))
(defcfun ("xkb_keysym_get_name" %xkb-symbol-name) :int
  (symbol :uint32)
  (buffer :pointer)
  (size :size))

(defun library-path ()
  (or (uiop:getenv "ATAXIA_SLINT_LIBRARY") "libSlint.so"))

(defun load-library ()
  (unless *library-loaded-p*
    (load-foreign-library (library-path))
    (load-foreign-library "libxkbcommon.so.0")
    (setf *library-loaded-p* t))
  t)

(defun %set-error (control &rest arguments)
  (setf *last-error* (apply #'format nil control arguments))
  nil)

(defun %last-error ()
  *last-error*)

(defun native-error (operation)
  (error "Slint ~A failed: ~A" operation
         (if (plusp (length *last-error*)) *last-error* "unknown error")))

(defun check-result (result operation)
  (unless result (native-error operation))
  result)

(defmacro with-byte-slice ((name value) &body body)
  `(with-foreign-string ((pointer length) ,value
                         :encoding :utf-8 :null-terminated-p nil)
     (let ((,name (list 'pointer pointer 'length length)))
       ,@body)))

(defmacro with-shared-string ((name value) &body body)
  `(with-foreign-object (,name :pointer)
     (with-byte-slice (slice ,value)
       (%shared-string-from-bytes
        ,name (getf slice 'pointer) (getf slice 'length)))
     (unwind-protect
          (progn ,@body)
       (%shared-string-drop ,name))))

(defun %shared-string-value (pointer)
  (foreign-string-to-lisp (%shared-string-bytes pointer) :encoding :utf-8))

(defun %window-state-for-user-data (user-data)
  (gethash (pointer-address user-data) *window-states*))

(defun %release-window-state (state)
  (when state
    (unless (null-pointer-p (window-state-renderer state))
      (%software-renderer-drop (window-state-renderer state))
      (setf (window-state-renderer state) (null-pointer)))
    (remhash (window-state-id state) *window-states*))
  nil)

(defcallback %platform-drop :void ((user-data :pointer))
  (declare (ignore user-data)))

(defcallback %window-drop :void ((user-data :pointer))
  (%release-window-state (%window-state-for-user-data user-data)))

(defcallback %aggregate-callback-dispatch :void
    ((cif :pointer) (result :pointer) (arguments :pointer)
     (user-data :pointer))
  (declare (ignore cif))
  (let ((handler (gethash (pointer-address user-data)
                          *aggregate-callback-handlers*)))
    (when handler (funcall handler result arguments))))

;; SBCL callbacks cannot pass C aggregates. libffi closures preserve Slint's
;; native ABI while keeping callback bodies and state entirely in Lisp.
(defun %allocate-aggregate-callback (return-type argument-types handler)
  (let* ((handler-id (incf *next-aggregate-callback-id*))
         (cif (cffi::make-libffi-cif
               nil return-type argument-types (%ffi-default-abi)))
         closure)
    (handler-case
        (with-foreign-object (code :pointer)
          (setf closure (%ffi-closure-alloc (%ffi-closure-size) code))
          (when (null-pointer-p closure)
            (error "libffi could not allocate a callback closure."))
          (setf (gethash handler-id *aggregate-callback-handlers*) handler)
          (unless (zerop (%ffi-prepare-closure
                          closure cif (callback %aggregate-callback-dispatch)
                          (make-pointer handler-id) (mem-ref code :pointer)))
            (error "libffi could not prepare a callback closure."))
          (%make-aggregate-callback
           :code (mem-ref code :pointer)
           :closure closure
           :cif cif
           :handler-id handler-id))
      (error (condition)
        (remhash handler-id *aggregate-callback-handlers*)
        (when closure (%ffi-closure-free closure))
        (cffi::free-libffi-cif cif)
        (error condition)))))

(defun %callback-argument (arguments index)
  (mem-aref arguments :pointer index))

(defun %callback-pointer-argument (arguments index)
  (mem-ref (%callback-argument arguments index) :pointer))

(defun %window-renderer-handler (result arguments)
  (let ((state (%window-state-for-user-data
                (%callback-pointer-argument arguments 0))))
    (if (and state (not (null-pointer-p (window-state-renderer state))))
        (let ((renderer (%software-renderer-handle
                         (window-state-renderer state))))
          (setf (mem-ref result :pointer) (getf renderer 'data)
                (mem-ref result :pointer 8) (getf renderer 'vtable)))
        (setf (mem-ref result :pointer) (null-pointer)
              (mem-ref result :pointer 8) (null-pointer)))))

(defcallback %window-set-visible :void
    ((user-data :pointer) (visible :boolean))
  (let ((state (%window-state-for-user-data user-data)))
    (when state
      (setf (window-state-visible-p state) visible
            (window-state-redraw-p state) t))))

(defcallback %window-request-redraw-callback :void ((user-data :pointer))
  (let ((state (%window-state-for-user-data user-data)))
    (when state (setf (window-state-redraw-p state) t))))

(defun %window-size-handler (result arguments)
  (let ((state (%window-state-for-user-data
                (%callback-pointer-argument arguments 0))))
    (setf (mem-ref result :uint32) (if state (window-state-width state) 1)
          (mem-ref result :uint32 4) (if state (window-state-height state) 1))))

(defun %window-set-size-handler (result arguments)
  (declare (ignore result))
  (let ((state (%window-state-for-user-data
                (%callback-pointer-argument arguments 0)))
        (size (%callback-argument arguments 1)))
    (when state
      (setf (window-state-width state) (max 1 (mem-ref size :uint32))
            (window-state-height state) (max 1 (mem-ref size :uint32 4))
            (window-state-redraw-p state) t))))

(defcallback %window-update-properties :void
    ((user-data :pointer) (properties :pointer))
  (declare (ignore user-data properties)))

(defcallback %window-position :boolean
    ((user-data :pointer) (position :pointer))
  (declare (ignore user-data position))
  nil)

(defun %window-set-position-handler (result arguments)
  (declare (ignore result arguments)))

(defcallback %platform-window-factory :void
    ((user-data :pointer) (target :pointer))
  (declare (ignore user-data))
  (let ((state (or *pending-window-state* (%make-window-state 1 1))))
    (setf (window-state-id state) (incf *next-window-id*)
          (window-state-renderer state) (%software-renderer-new 1))
    (setf (gethash (window-state-id state) *window-states*) state)
    (%window-adapter-new
     (make-pointer (window-state-id state))
     (callback %window-drop)
     (aggregate-callback-code *window-renderer-callback*)
     (callback %window-set-visible)
     (callback %window-request-redraw-callback)
     (aggregate-callback-code *window-size-callback*)
     (aggregate-callback-code *window-set-size-callback*)
     (callback %window-update-properties)
     (callback %window-position)
     (aggregate-callback-code *window-set-position-callback*)
     target)))

(defcallback %platform-duration :uint64 ((user-data :pointer))
  (declare (ignore user-data))
  (round (* 1000 (/ (get-internal-real-time)
                    internal-time-units-per-second))))

(defcallback %platform-set-clipboard :void
    ((user-data :pointer) (text :pointer) (clipboard :uint8))
  (declare (ignore user-data))
  (setf (gethash clipboard *clipboard-text*) (%shared-string-value text)))

(defcallback %platform-clipboard :boolean
    ((user-data :pointer) (output :pointer) (clipboard :uint8))
  (declare (ignore user-data))
  (let ((value (gethash clipboard *clipboard-text*)))
    (when value
      (with-byte-slice (slice value)
        (%shared-string-from-bytes
         output (getf slice 'pointer) (getf slice 'length))))
    (not (null value))))

(defcallback %platform-event-loop :void ((user-data :pointer))
  (declare (ignore user-data)))

(defun %platform-invoke-handler (result arguments)
  (declare (ignore result))
  (let ((task (%callback-argument arguments 1)))
    (%platform-task-run
     (list 'data (mem-ref task :pointer)
           'vtable (mem-ref task :pointer 8)))))

(defun %install-aggregate-callbacks ()
  (unless *window-renderer-callback*
    (setf *window-renderer-callback*
          (%allocate-aggregate-callback
           '(:struct renderer-pointer) '(:pointer)
           #'%window-renderer-handler)
          *window-size-callback*
          (%allocate-aggregate-callback
           '(:struct integer-size) '(:pointer)
           #'%window-size-handler)
          *window-set-size-callback*
          (%allocate-aggregate-callback
           :void '(:pointer (:struct integer-size))
           #'%window-set-size-handler)
          *window-set-position-callback*
          (%allocate-aggregate-callback
           :void '(:pointer (:struct integer-point))
           #'%window-set-position-handler)
          *platform-invoke-callback*
          (%allocate-aggregate-callback
           :void '(:pointer (:struct platform-task))
           #'%platform-invoke-handler))))

(defun %verify-layouts ()
  (dolist (layout `(((:struct renderer-pointer) . 16)
                    ((:struct integer-size) . 8)
                    ((:struct physical-region) . 32)
                    ((:struct vtable-reference) . 16)
                    ((:struct allocation-layout) . 16)))
    (unless (= (foreign-type-size (car layout)) (cdr layout))
      (error "Slint ~A ABI layout mismatch for ~S."
             +slint-abi-version+ (car layout)))))

(defun initialize ()
  (load-library)
  (%verify-layouts)
  (%install-aggregate-callbacks)
  (unless *platform-installed-p*
    (%platform-register
     (null-pointer)
     (callback %platform-drop)
     (callback %platform-window-factory)
     (callback %platform-duration)
     (callback %platform-set-clipboard)
     (callback %platform-clipboard)
     (callback %platform-event-loop)
     (callback %platform-event-loop)
     (aggregate-callback-code *platform-invoke-callback*))
    (setf *platform-installed-p* t))
  t)

(defun %make-xkb-state ()
  (let ((context (%xkb-context-new 0))
        keymap
        state)
    (when (null-pointer-p context)
      (error "xkbcommon could not create a context."))
    (handler-case
        (progn
          (with-foreign-object (names '(:struct xkb-rule-names))
            (dotimes (index 5)
              (setf (mem-aref names :pointer index) (null-pointer)))
            (setf keymap (%xkb-keymap-new-from-names context names 0)))
          (when (null-pointer-p keymap)
            (error "xkbcommon could not create the default keymap."))
          (setf state (%xkb-state-new keymap))
          (when (null-pointer-p state)
            (error "xkbcommon could not create keyboard state."))
          (values context keymap state))
      (error (condition)
        (when (and keymap (not (null-pointer-p keymap)))
          (%xkb-keymap-unref keymap))
        (%xkb-context-unref context)
        (error condition)))))

(defun %release-xkb-state (component)
  (when (native-component-xkb-state component)
    (%xkb-state-unref (native-component-xkb-state component))
    (setf (native-component-xkb-state component) nil))
  (when (native-component-xkb-keymap component)
    (%xkb-keymap-unref (native-component-xkb-keymap component))
    (setf (native-component-xkb-keymap component) nil))
  (when (native-component-xkb-context component)
    (%xkb-context-unref (native-component-xkb-context component))
    (setf (native-component-xkb-context component) nil)))

(defun %instance-data (instance)
  (let* ((inner (mem-ref instance :pointer))
         (offset (mem-ref inner :uint16 16)))
    (inc-pointer inner offset)))

(defun %align-up (value alignment)
  (* (ceiling value alignment) alignment))

(defun %drop-instance (instance)
  (let* ((inner (mem-ref instance :pointer))
         (strong (mem-ref inner :uint32 8)))
    (cond
      ((> strong 1)
       (setf (mem-ref inner :uint32 8) (1- strong)))
      ((= strong 1)
       (setf (mem-ref inner :uint32 8) 0)
       (let* ((vtable (mem-ref inner :pointer))
              (data-offset (mem-ref inner :uint16 16))
              (data (inc-pointer inner data-offset))
              (drop-function
                (mem-ref vtable :pointer +item-tree-drop-offset+))
              (layout
                (foreign-funcall-pointer
                 drop-function ()
                 (:struct vtable-reference)
                 (list 'vtable vtable 'instance data)
                 (:struct allocation-layout)))
              (alignment (max 8 (getf layout 'alignment)))
              (size (%align-up
                     (+ data-offset (max 16 (getf layout 'size)))
                     alignment))
              (complete-layout
                (list 'size size 'alignment alignment))
              (weak (mem-ref inner :uint32 12)))
         (setf (mem-ref inner :uint32 12) (1- weak))
         (if (> weak 1)
             (setf (mem-ref data :size) size
                   (mem-ref data :size (foreign-type-size :size)) alignment)
             (foreign-funcall-pointer
              (mem-ref vtable :pointer +item-tree-deallocate-offset+) ()
              :pointer vtable
              :pointer inner
              (:struct allocation-layout) complete-layout
              :void)))))))

(defun %read-definition-name (definition)
  (with-foreign-object (name :pointer)
    (%definition-name definition name)
    (unwind-protect
         (%shared-string-value name)
      (%shared-string-drop name))))

(defun %dispatch-window-event (component tag &key x y value delta-x delta-y)
  (with-foreign-object (event :uint8 +window-event-size+)
    (dotimes (index +window-event-size+)
      (setf (mem-aref event :uint8 index) 0))
    (setf (mem-ref event :uint32) tag)
    (when x (setf (mem-ref event :float 4) (coerce x 'single-float)))
    (when y (setf (mem-ref event :float 8) (coerce y 'single-float)))
    (when value (setf (mem-ref event :uint32 12) value))
    (when delta-x
      (setf (mem-ref event :float 12) (coerce delta-x 'single-float)))
    (when delta-y
      (setf (mem-ref event :float 16) (coerce delta-y 'single-float)))
    (when (= tag +window-event-window-active-changed+)
      (setf (mem-ref event :boolean 4) (not (null value))))
    (%window-dispatch-event (native-component-window component) event)))

(defun %configure-component-window (component)
  (let ((width (native-component-width component))
        (height (native-component-height component))
        (scale (native-component-scale component)))
    (with-foreign-object (size '(:struct integer-size))
      (setf (foreign-slot-value size '(:struct integer-size) 'width) width
            (foreign-slot-value size '(:struct integer-size) 'height) height)
      (%window-set-physical-size (native-component-window component) size))
    (%dispatch-window-event
     component +window-event-scale-factor-changed+ :x scale)
    (%dispatch-window-event
     component +window-event-resized+
     :x (/ width scale) :y (/ height scale))
    (%window-request-redraw (native-component-window component))))

(defun %cleanup-failed-component (component)
  (when component
    (when (native-component-instance component)
      (%drop-instance (native-component-instance component))
      (foreign-free (native-component-instance component))
      (setf (native-component-instance component) nil))
    (%release-window-state (native-component-window-state component))
    (when (native-component-pixels component)
      (foreign-free (native-component-pixels component))
      (setf (native-component-pixels component) nil))
    (%release-xkb-state component)))

(defun %create-component (source source-path component-name width height scale)
  (initialize)
  (unless (and (plusp width) (plusp height) (plusp scale))
    (error "Slint component size and scale must be positive."))
  (let* ((state (%make-window-state width height))
         (component (%make-native-component
                     :window-state state :width width :height height
                     :scale scale))
         (compiler (foreign-alloc :pointer))
         (definition (foreign-alloc :pointer))
         (instance (foreign-alloc :pointer))
         (compiler-live-p nil)
         (definition-live-p nil)
         (instance-live-p nil))
    (unwind-protect
         (handler-case
             (progn
               (%compiler-new compiler)
               (setf compiler-live-p t)
               (with-byte-slice (source-slice source)
                 (with-byte-slice (path-slice source-path)
                   (when (zerop (%compiler-build-from-source
                                 compiler source-slice path-slice definition))
                     (error "Slint could not compile ~A." source-path))))
               (setf definition-live-p t)
               (let ((selected-name (%read-definition-name definition)))
                 (when (and (plusp (length component-name))
                            (string/= component-name selected-name))
                   (error "Slint's native ABI selected component ~S, not ~S; the source must expose one root component."
                          selected-name component-name)))
               (setf *pending-window-state* state)
               (unwind-protect
                    (%instance-create definition instance)
                 (setf *pending-window-state* nil))
               (setf instance-live-p t
                     (native-component-instance component) instance
                     (native-component-instance-data component) (%instance-data instance))
               (unless (and (plusp (window-state-id state))
                            (not (null-pointer-p (window-state-renderer state))))
                 (error "Slint did not request a World window adapter."))
               (with-foreign-object (window :pointer)
                 (%instance-window (native-component-instance-data component) window)
                 (setf (native-component-window component) (mem-ref window :pointer)))
               (multiple-value-bind (context keymap xkb-state) (%make-xkb-state)
                 (setf (native-component-xkb-context component) context
                       (native-component-xkb-keymap component) keymap
                       (native-component-xkb-state component) xkb-state))
               (setf (native-component-pixels component)
                     (foreign-alloc :uint8 :count (* width height 3)
                                    :initial-element 0))
               (%configure-component-window component)
               (%instance-show (native-component-instance-data component) t)
               (setf *last-error* "")
               component)
           (error (condition)
             (when instance-live-p
               (%cleanup-failed-component component))
             (unless instance-live-p
               (%release-window-state state)
               (foreign-free instance))
             (%set-error "~A" condition)))
      (when definition-live-p (%definition-destroy definition))
      (when compiler-live-p (%compiler-destroy compiler))
      (foreign-free definition)
      (foreign-free compiler))))

(defun %component-create
    (source source-path component-name width height scale)
  (handler-case
      (%create-component source source-path component-name width height scale)
    (error (condition)
      (%set-error "~A" condition))))

(defun %require-component (component)
  (unless (and (native-component-p component)
               (not (native-component-destroyed-p component)))
    (error "Slint component is not live."))
  component)

(defun %component-destroy (component)
  (when (and (native-component-p component)
             (not (native-component-destroyed-p component)))
    (setf (native-component-destroyed-p component) t)
    (%instance-show (native-component-instance-data component) nil)
    (%drop-instance (native-component-instance component))
    (foreign-free (native-component-instance component))
    (setf (native-component-instance component) nil
          (native-component-instance-data component) nil
          (native-component-window component) nil)
    (%release-window-state (native-component-window-state component))
    (foreign-free (native-component-pixels component))
    (setf (native-component-pixels component) nil)
    (%release-xkb-state component))
  nil)

(defun %component-resize (component width height scale)
  (handler-case
      (let ((component (%require-component component)))
        (unless (and (plusp width) (plusp height) (plusp scale))
          (error "Slint component size and scale must be positive."))
        (foreign-free (native-component-pixels component))
        (setf (native-component-pixels component)
              (foreign-alloc :uint8 :count (* width height 3)
                             :initial-element 0)
              (native-component-width component) width
              (native-component-height component) height
              (native-component-scale component) scale
              (window-state-width (native-component-window-state component)) width
              (window-state-height (native-component-window-state component)) height
              (window-state-redraw-p (native-component-window-state component)) t)
        (%configure-component-window component)
        (setf *last-error* "")
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %region-rectangle (region index)
  (let* ((rectangle (getf region (ecase index
                                  (0 'rectangle-0)
                                  (1 'rectangle-1)
                                  (2 'rectangle-2))))
         (minimum (getf rectangle 'minimum))
         (maximum (getf rectangle 'maximum))
         (x (getf minimum 'x))
         (y (getf minimum 'y)))
    (list x y
          (max 0 (- (getf maximum 'x) x))
          (max 0 (- (getf maximum 'y) y)))))

(defun %component-render (component)
  (handler-case
      (let* ((component (%require-component component))
             (state (native-component-window-state component)))
        (setf (native-component-damage component) nil)
        (when (window-state-redraw-p state)
          (setf (window-state-redraw-p state) nil)
          (let* ((region
                   (%software-renderer-render
                    (window-state-renderer state)
                    (native-component-pixels component)
                    (* (native-component-width component)
                       (native-component-height component))
                    (native-component-width component)))
                 (count (min 3 (getf region 'count))))
            (setf (native-component-damage component)
                  (loop for index below count
                        collect (%region-rectangle region index)))
            (when (plusp count)
              (setf (native-component-revision component)
                    (ldb (byte 64 0)
                         (1+ (native-component-revision component)))))))
        (setf *last-error* "")
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %component-pixels (component)
  (native-component-pixels (%require-component component)))

(defun %component-width (component)
  (native-component-width (%require-component component)))

(defun %component-height (component)
  (native-component-height (%require-component component)))

(defun %component-revision (component)
  (native-component-revision (%require-component component)))

(defun %component-damage-count (component)
  (length (native-component-damage (%require-component component))))

(defun %component-damage-rectangle (component index rectangle)
  (let ((damage (nth index (native-component-damage (%require-component component)))))
    (when damage
      (destructuring-bind (x y width height) damage
        (setf (foreign-slot-value rectangle '(:struct damage-rectangle) 'x) x
              (foreign-slot-value rectangle '(:struct damage-rectangle) 'y) y
              (foreign-slot-value rectangle '(:struct damage-rectangle) 'width) width
              (foreign-slot-value rectangle '(:struct damage-rectangle) 'height) height))
      t)))

(defun %component-active-p (component)
  (%window-active-p (native-component-window (%require-component component))))

(defun %pointer-motion (component x y)
  (handler-case
      (progn
        (%dispatch-window-event
         (%require-component component) +window-event-pointer-moved+ :x x :y y)
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %pointer-button (component x y button pressed)
  (handler-case
      (progn
        (%dispatch-window-event
         (%require-component component)
         (if pressed +window-event-pointer-pressed+
             +window-event-pointer-released+)
         :x x :y y :value button)
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %pointer-scroll (component x y delta-x delta-y)
  (handler-case
      (progn
        (%dispatch-window-event
         (%require-component component) +window-event-pointer-scrolled+
         :x x :y y :delta-x delta-x :delta-y delta-y)
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %pointer-exit (component)
  (handler-case
      (progn
        (%dispatch-window-event
         (%require-component component) +window-event-pointer-exited+)
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %dispatch-key-text (component text pressed repeated)
  (unless (zerop (length text))
    (with-shared-string (shared text)
      (%window-dispatch-key
       (native-component-window component)
       (if pressed 0 1) shared repeated))))

(defun %focus (component focused)
  (handler-case
      (let ((component (%require-component component)))
        (unless focused
          (maphash
           (lambda (keycode text)
             (declare (ignore keycode))
             (%dispatch-key-text component text nil nil))
           (native-component-pressed-keys component))
          (clrhash (native-component-pressed-keys component))
          (%xkb-state-update-mask
           (native-component-xkb-state component) 0 0 0 0 0 0))
        (%dispatch-window-event
         component +window-event-window-active-changed+ :value focused)
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %modifiers (component depressed latched locked group)
  (handler-case
      (progn
        (%xkb-state-update-mask
         (native-component-xkb-state (%require-component component))
         depressed latched locked 0 0 group)
        t)
    (error (condition) (%set-error "~A" condition))))

(defparameter +special-keys+
  `(("BackSpace" . ,#x0008) ("Tab" . ,#x0009)
    ("ISO_Left_Tab" . ,#x0019) ("Return" . ,#x000a)
    ("KP_Enter" . ,#x000a) ("Escape" . ,#x001b)
    ("Delete" . ,#x007f) ("KP_Delete" . ,#x007f)
    ("Shift_L" . ,#x0010) ("Shift_R" . ,#x0015)
    ("Control_L" . ,#x0011) ("Control_R" . ,#x0016)
    ("Alt_L" . ,#x0012) ("Alt_R" . ,#x0013)
    ("ISO_Level3_Shift" . ,#x0013) ("Super_L" . ,#x0017)
    ("Meta_L" . ,#x0017) ("Super_R" . ,#x0018)
    ("Meta_R" . ,#x0018) ("Caps_Lock" . ,#x0014)
    ("Up" . ,#xf700) ("KP_Up" . ,#xf700)
    ("Down" . ,#xf701) ("KP_Down" . ,#xf701)
    ("Left" . ,#xf702) ("KP_Left" . ,#xf702)
    ("Right" . ,#xf703) ("KP_Right" . ,#xf703)
    ("Insert" . ,#xf727) ("KP_Insert" . ,#xf727)
    ("Home" . ,#xf729) ("KP_Home" . ,#xf729)
    ("End" . ,#xf72b) ("KP_End" . ,#xf72b)
    ("Page_Up" . ,#xf72c) ("KP_Page_Up" . ,#xf72c)
    ("Page_Down" . ,#xf72d) ("KP_Page_Down" . ,#xf72d)
    ,@(loop for number from 1 to 12
            collect (cons (format nil "F~D" number)
                          (+ #xf703 number)))))

(defun %xkb-key-name (state keycode)
  (let ((symbol (%xkb-state-key-get-one-symbol state keycode)))
    (with-foreign-object (buffer :char 96)
      (let ((length (%xkb-symbol-name symbol buffer 96)))
        (if (plusp length)
            (foreign-string-to-lisp buffer :count length :encoding :ascii)
            "")))))

(defun %key-text (component keycode)
  (let* ((state (native-component-xkb-state component))
         (xkb-keycode (+ keycode 8))
         (length (%xkb-state-key-get-utf8 state xkb-keycode (null-pointer) 0)))
    (if (plusp length)
        (with-foreign-object (buffer :char (1+ length))
          (%xkb-state-key-get-utf8 state xkb-keycode buffer (1+ length))
          (foreign-string-to-lisp buffer :count length :encoding :utf-8))
        (let ((code (cdr (assoc (%xkb-key-name state xkb-keycode)
                                +special-keys+ :test #'string=))))
          (if code (string (code-char code)) "")))))

(defun %key (component keycode pressed repeated)
  (handler-case
      (let* ((component (%require-component component))
             (pressed-keys (native-component-pressed-keys component))
             (text
               (if pressed
                   (setf (gethash keycode pressed-keys)
                         (%key-text component keycode))
                   (or (gethash keycode pressed-keys)
                       (%key-text component keycode)))))
        (unless pressed (remhash keycode pressed-keys))
        (%dispatch-key-text component text pressed repeated)
        t)
    (error (condition) (%set-error "~A" condition))))

(defun %set-property-value (component name value)
  (with-byte-slice (name-slice name)
    (unwind-protect
         (when (zerop (%instance-set-property
                       (native-component-instance-data component)
                       name-slice value))
           (error "Property ~S does not exist or has a different type." name))
      (%value-destroy value)))
  (%window-request-redraw (native-component-window component))
  t)

(defun %set-string (component name value)
  (handler-case
      (let ((component (%require-component component)))
        (with-shared-string (shared value)
          (%set-property-value component name (%value-new-string shared))))
    (error (condition) (%set-error "~A" condition))))

(defun %set-number (component name value)
  (handler-case
      (%set-property-value
       (%require-component component) name (%value-new-double value))
    (error (condition) (%set-error "~A" condition))))

(defun %set-boolean (component name value)
  (handler-case
      (%set-property-value
       (%require-component component) name (%value-new-boolean value))
    (error (condition) (%set-error "~A" condition))))
