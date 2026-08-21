;;;; Output initialization and atomic state operations.
;;;;
;;;; This module exposes wlroots output render initialization, mode handles,
;;;; scoped output states, explicit global publication, and test/commit calls.
;;;; It does not select layout, damage, presentation, or display policy.

(in-package #:ataxia.runtime.raw)

(defcfun ("wlr_output_init_render" %wlr-output-init-render) :boolean
  (output :pointer)
  (allocator :pointer)
  (renderer :pointer))
(defcfun ("wlr_output_preferred_mode" %wlr-output-preferred-mode) :pointer
  (output :pointer))
(defcfun ("wlr_output_create_global" %wlr-output-create-global) :void
  (output :pointer)
  (display :pointer))
(defcfun ("wlr_output_destroy_global" %wlr-output-destroy-global) :void
  (output :pointer))
(defcfun ("wlr_output_state_set_enabled" %wlr-output-state-set-enabled)
    :void
  (state :pointer)
  (enabled :boolean))
(defcfun ("wlr_output_state_set_mode" %wlr-output-state-set-mode) :void
  (state :pointer)
  (mode :pointer))
(defcfun ("wlr_output_state_set_custom_mode"
          %wlr-output-state-set-custom-mode)
    :void
  (state :pointer)
  (width :int32)
  (height :int32)
  (refresh-millihertz :int32))
(defcfun ("wlr_output_test_state" %wlr-output-test-state) :boolean
  (output :pointer)
  (state :pointer))
(defcfun ("wlr_output_commit_state" %wlr-output-commit-state) :boolean
  (output :pointer)
  (state :pointer))
(defcfun ("wlr_output_schedule_frame" %wlr-output-schedule-frame) :void
  (output :pointer))
(defcfun ("wlr_output_configure_primary_swapchain"
          %wlr-output-configure-primary-swapchain)
    :boolean
  (output :pointer)
  (state :pointer)
  (swapchain :pointer))
(defcfun ("wlr_swapchain_acquire" %wlr-swapchain-acquire) :pointer
  (swapchain :pointer))
(defcfun ("wlr_swapchain_destroy" %wlr-swapchain-destroy) :void
  (swapchain :pointer))
(defcfun ("wlr_output_state_set_buffer" %wlr-output-state-set-buffer) :void
  (state :pointer)
  (buffer :pointer))
(defcfun ("wlr_gles2_renderer_get_buffer_fbo"
          %wlr-gles2-renderer-get-buffer-fbo)
    :uint32
  (renderer :pointer)
  (buffer :pointer))
(defcfun ("ataxia_output_state_create" %output-state-create) :pointer)
(defcfun ("ataxia_output_state_destroy" %output-state-destroy) :void
  (state :pointer))
(define-signal-binding %output-event-damage
  "ataxia_output_event_damage" output)
(define-signal-binding %output-event-needs-frame
  "ataxia_output_event_needs_frame" output)
(define-signal-binding %output-event-present
  "ataxia_output_event_present" output)
(define-signal-binding %output-event-request-state
  "ataxia_output_event_request_state" output)
(defcfun ("ataxia_output_damage_region" %output-damage-region) :pointer
  (event :pointer))
(defcfun ("ataxia_region_rectangle_count" %region-rectangle-count) :uint32
  (region :pointer))
(defcfun ("ataxia_region_rectangle_at" %region-rectangle-at) :boolean
  (region :pointer)
  (index :uint32)
  (x1 :pointer)
  (y1 :pointer)
  (x2 :pointer)
  (y2 :pointer))
(defcfun ("ataxia_output_state_set_damage_rectangles"
          %output-state-set-damage-rectangles)
    :void
  (state :pointer)
  (rectangles :pointer)
  (rectangle-count :uint32))
(defcfun ("ataxia_output_present_commit_sequence"
          %output-present-commit-sequence)
    :uint32
  (event :pointer))
(defcfun ("ataxia_output_presented" %output-presented) :boolean
  (event :pointer))
(defcfun ("ataxia_output_present_seconds" %output-present-seconds) :int64
  (event :pointer))
(defcfun ("ataxia_output_present_nanoseconds" %output-present-nanoseconds)
    :int64
  (event :pointer))
(defcfun ("ataxia_output_present_sequence" %output-present-sequence) :uint32
  (event :pointer))
(defcfun ("ataxia_output_present_refresh_nanoseconds"
          %output-present-refresh-nanoseconds)
    :int32
  (event :pointer))
(defcfun ("ataxia_output_present_flags" %output-present-flags) :uint32
  (event :pointer))
(defcfun ("ataxia_output_requested_state" %output-requested-state) :pointer
  (event :pointer))

(in-package #:ataxia.runtime)

(defclass wlr-output-mode (native-object)
  ((output :initarg :output :reader %output-mode-output))
  (:documentation
   "Wraps the native wlr output mode object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))

(defclass wlr-output-state (native-object)
  ((output :initarg :output :reader %output-state-output)
   (borrowed-p :initarg :borrowed-p :initform nil
               :reader %output-state-borrowed-p))
  (:documentation
   "Wraps the native wlr output state object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))

(defclass wlr-output-swapchain (native-object)
  ((output :initarg :output :reader output-swapchain-output))
  (:documentation
   "Wraps the native wlr output swapchain object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))

(defstruct (output-damage-event
             (:constructor %make-output-damage-event
                 (&key output rectangles))
             (:conc-name output-damage-))
  (output nil :type wlr-output :read-only t)
  (rectangles nil :type list :read-only t))

(defstruct (output-present-event
             (:constructor %make-output-present-event
                 (&key output commit-sequence presented-p seconds nanoseconds
                       sequence refresh-nanoseconds flags))
             (:conc-name output-present-))
  (output nil :type wlr-output :read-only t)
  (commit-sequence 0 :type (unsigned-byte 32) :read-only t)
  (presented-p nil :type boolean :read-only t)
  (seconds 0 :type (signed-byte 64) :read-only t)
  (nanoseconds 0 :type (signed-byte 64) :read-only t)
  (sequence 0 :type (unsigned-byte 32) :read-only t)
  (refresh-nanoseconds 0 :type (signed-byte 32) :read-only t)
  (flags 0 :type (unsigned-byte 32) :read-only t))

(defgeneric output-damaged (sink event)
  (:documentation
   "Implement OUTPUT-DAMAGED while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."))
(defgeneric output-needs-frame (sink output)
  (:documentation
   "Implement OUTPUT-NEEDS-FRAME while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."))
(defgeneric output-present (sink event)
  (:documentation
   "Implement OUTPUT-PRESENT while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."))
(defgeneric output-request-state (sink output state)
  (:documentation
   "Implement OUTPUT-REQUEST-STATE for this output specialization. Respect output membership, layout, scale, and hotplug lifetime when updating state."))

(defmethod output-damaged ((sink runtime-sink) event)
  "Implement OUTPUT-DAMAGED while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  (declare (ignore sink event)))
(defmethod output-needs-frame ((sink runtime-sink) output)
  "Implement OUTPUT-NEEDS-FRAME while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  (declare (ignore sink output)))
(defmethod output-present ((sink runtime-sink) event)
  "Implement OUTPUT-PRESENT while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  (declare (ignore sink event)))
(defmethod output-request-state ((sink runtime-sink) output state)
  "Implement OUTPUT-REQUEST-STATE for this output specialization. Respect output membership, layout, scale, and hotplug lifetime when updating state."
  (declare (ignore sink output state)))

(defun %damage-rectangles (region)
  (loop for index below
        (ataxia.runtime.raw:%region-rectangle-count region)
        collect
        (cffi:with-foreign-objects ((x1 :int32) (y1 :int32)
                                    (x2 :int32) (y2 :int32))
          (unless (ataxia.runtime.raw:%region-rectangle-at
                   region index x1 y1 x2 y2)
            (error 'native-call-failed
                   :name :region-rectangle-at :detail index))
          (let ((left (cffi:mem-ref x1 :int32))
                (top (cffi:mem-ref y1 :int32))
                (right (cffi:mem-ref x2 :int32))
                (bottom (cffi:mem-ref y2 :int32)))
            (%make-damage-rectangle
             :x left :y top
             :width (- right left) :height (- bottom top))))))

(defun %output-damage-snapshot (output event-pointer)
  (let ((region
          (%require-pointer
           (ataxia.runtime.raw:%output-damage-region event-pointer)
           :output-damage-region)))
    (%make-output-damage-event
     :output output :rectangles (%damage-rectangles region))))

(defun %output-present-snapshot (output event-pointer)
  (%make-output-present-event
   :output output
   :commit-sequence
   (ataxia.runtime.raw:%output-present-commit-sequence event-pointer)
   :presented-p (ataxia.runtime.raw:%output-presented event-pointer)
   :seconds (ataxia.runtime.raw:%output-present-seconds event-pointer)
   :nanoseconds (ataxia.runtime.raw:%output-present-nanoseconds event-pointer)
   :sequence (ataxia.runtime.raw:%output-present-sequence event-pointer)
   :refresh-nanoseconds
   (ataxia.runtime.raw:%output-present-refresh-nanoseconds event-pointer)
   :flags (ataxia.runtime.raw:%output-present-flags event-pointer)))

(defun %install-output-extended-signals (output)
  (let ((pointer (%object-pointer output))
        (runtime (%native-runtime output)))
    (%attach-object-signal
     output :output-damage
     (ataxia.runtime.raw:%output-event-damage pointer)
     (lambda (event-pointer)
       (output-damaged
        (%runtime-sink runtime)
        (%output-damage-snapshot output event-pointer))))
    (%attach-object-signal
     output :output-needs-frame
     (ataxia.runtime.raw:%output-event-needs-frame pointer)
     (lambda (data)
       (declare (ignore data))
       (output-needs-frame (%runtime-sink runtime) output)))
    (%attach-object-signal
     output :output-present
     (ataxia.runtime.raw:%output-event-present pointer)
     (lambda (event-pointer)
       (output-present
        (%runtime-sink runtime)
        (%output-present-snapshot output event-pointer))))
    (%attach-object-signal
     output :output-request-state
     (ataxia.runtime.raw:%output-event-request-state pointer)
     (lambda (event-pointer)
       (let ((state
               (%wrap-pointer
                'wlr-output-state
                (%require-pointer
                 (ataxia.runtime.raw:%output-requested-state event-pointer)
                 :output-requested-state)
                runtime :output output :borrowed-p t)))
         (unwind-protect
              (output-request-state (%runtime-sink runtime) output state)
           (%invalidate-native-object state))))))
  output)

(defun initialize-output-render (output allocator renderer)
  (check-type output wlr-output)
  (check-type allocator wlr-allocator)
  (check-type renderer wlr-renderer)
  (let ((runtime (%native-runtime output)))
    (%assert-runtime-live runtime :initialize-output-render)
    (%assert-object-runtime runtime allocator :initialize-output-render)
    (%assert-object-runtime runtime renderer :initialize-output-render)
    (unless (ataxia.runtime.raw:%wlr-output-init-render
             (%object-pointer output)
             (%object-pointer allocator)
             (%object-pointer renderer))
      (error 'native-call-failed
             :name :wlr-output-init-render
             :detail (output-name output))))
  output)

(defun output-preferred-mode (output)
  (check-type output wlr-output)
  (%assert-runtime-live (%native-runtime output) :output-preferred-mode)
  (let ((pointer
          (ataxia.runtime.raw:%wlr-output-preferred-mode
           (%object-pointer output))))
    (unless (ataxia.runtime.raw:null-pointer-p pointer)
      (let ((mode (%wrap-pointer 'wlr-output-mode pointer
                                 (%native-runtime output)
                                 :output output)))
        (push mode (%output-modes output))
        mode))))

(defun create-output-global (output)
  (check-type output wlr-output)
  (let ((runtime (%native-runtime output)))
    (%assert-runtime-live runtime :create-output-global)
    (unless (output-global-p output)
      (ataxia.runtime.raw:%wlr-output-create-global
       (%object-pointer output)
       (%object-pointer (%runtime-display runtime)))
      (setf (output-global-p output) t)))
  output)

(defun destroy-output-global (output)
  (check-type output wlr-output)
  (when (and (native-object-live-p output) (output-global-p output))
    (%assert-runtime-live (%native-runtime output) :destroy-output-global)
    (ataxia.runtime.raw:%wlr-output-destroy-global (%object-pointer output))
    (setf (output-global-p output) nil))
  output)

(defun create-output-state (output)
  (check-type output wlr-output)
  (%assert-runtime-live (%native-runtime output) :create-output-state)
  (%wrap-pointer
   'wlr-output-state
   (%require-pointer (ataxia.runtime.raw:%output-state-create)
                     :output-state-create)
   (%native-runtime output)
   :output output :borrowed-p nil))

(defun output-state-set-enabled (state enabled-p)
  (check-type state wlr-output-state)
  (%assert-runtime-live (%native-runtime state) :output-state-set-enabled)
  (ataxia.runtime.raw:%wlr-output-state-set-enabled
   (%object-pointer state) (not (null enabled-p)))
  state)

(defun output-state-set-mode (state mode)
  (check-type state wlr-output-state)
  (check-type mode wlr-output-mode)
  (let ((runtime (%native-runtime state)))
    (%assert-runtime-live runtime :output-state-set-mode)
    (%assert-object-runtime runtime mode :output-state-set-mode)
    (unless (eq (%output-state-output state) (%output-mode-output mode))
      (error 'native-call-failed
             :name :output-state-set-mode
             :detail "mode belongs to a different output"))
    (ataxia.runtime.raw:%wlr-output-state-set-mode
     (%object-pointer state) (%object-pointer mode)))
  state)

(defun output-state-set-custom-mode
    (state width height &optional (refresh-millihertz 0))
  (check-type state wlr-output-state)
  (check-type width (signed-byte 32))
  (check-type height (signed-byte 32))
  (check-type refresh-millihertz (signed-byte 32))
  (%assert-runtime-live
   (%native-runtime state) :output-state-set-custom-mode)
  (ataxia.runtime.raw:%wlr-output-state-set-custom-mode
   (%object-pointer state) width height refresh-millihertz)
  state)

(defun output-state-set-damage (state rectangles)
  (check-type state wlr-output-state)
  (%assert-runtime-live (%native-runtime state) :output-state-set-damage)
  (let ((rectangles (remove-if-not
                     (lambda (rectangle)
                       (and (plusp (damage-rectangle-width rectangle))
                            (plusp (damage-rectangle-height rectangle))))
                     rectangles)))
    (if rectangles
        (cffi:with-foreign-object (native :int32 (* 4 (length rectangles)))
          (loop for rectangle in rectangles
                for offset from 0 by 4
                do (setf (cffi:mem-aref native :int32 offset)
                         (damage-rectangle-x rectangle)
                         (cffi:mem-aref native :int32 (+ offset 1))
                         (damage-rectangle-y rectangle)
                         (cffi:mem-aref native :int32 (+ offset 2))
                         (damage-rectangle-width rectangle)
                         (cffi:mem-aref native :int32 (+ offset 3))
                         (damage-rectangle-height rectangle)))
          (ataxia.runtime.raw:%output-state-set-damage-rectangles
           (%object-pointer state) native (length rectangles)))
        (ataxia.runtime.raw:%output-state-set-damage-rectangles
         (%object-pointer state) (cffi:null-pointer) 0)))
  state)

(defun %assert-output-state-pair (output state operation)
  (check-type output wlr-output)
  (check-type state wlr-output-state)
  (let ((runtime (%native-runtime output)))
    (%assert-runtime-live runtime operation)
    (%assert-object-runtime runtime state operation)
    (unless (eq output (%output-state-output state))
      (error 'native-call-failed
             :name operation :detail "state belongs to a different output")))
  state)

(defun output-test-state (output state)
  (%assert-output-state-pair output state :output-test-state)
  (ataxia.runtime.raw:%wlr-output-test-state
   (%object-pointer output) (%object-pointer state)))

(defun output-commit-state (output state)
  (%assert-output-state-pair output state :output-commit-state)
  (prog1
      (ataxia.runtime.raw:%wlr-output-commit-state
       (%object-pointer output) (%object-pointer state))
    (%refresh-output output)))

(defun output-schedule-frame (output)
  (check-type output wlr-output)
  (%assert-runtime-live (%native-runtime output) :output-schedule-frame)
  (ataxia.runtime.raw:%wlr-output-schedule-frame (%object-pointer output))
  output)

(defun output-frame-pending-p (output)
  (check-type output wlr-output)
  (%assert-runtime-live (%native-runtime output) :output-frame-pending-p)
  (ataxia.runtime.raw:%output-frame-pending (%object-pointer output)))

(defun configure-output-swapchain (output &optional swapchain state)
  (check-type output wlr-output)
  (when swapchain
    (check-type swapchain wlr-output-swapchain))
  (when state
    (%assert-output-state-pair output state :configure-output-swapchain))
  (let ((runtime (%native-runtime output)))
    (%assert-runtime-live runtime :configure-output-swapchain)
    (when swapchain
      (%assert-object-runtime runtime swapchain :configure-output-swapchain)
      (unless (eq output (output-swapchain-output swapchain))
        (error 'native-call-failed
               :name :configure-output-swapchain
               :detail "swapchain belongs to a different output")))
    (cffi:with-foreign-object (swapchain-cell :pointer)
      (setf (cffi:mem-ref swapchain-cell :pointer)
            (if swapchain
                (%object-pointer swapchain)
                (ataxia.runtime.raw:null-pointer)))
      (unless
          (ataxia.runtime.raw:%wlr-output-configure-primary-swapchain
           (%object-pointer output)
           (if state
               (%object-pointer state)
               (ataxia.runtime.raw:null-pointer))
           swapchain-cell)
        (error 'native-call-failed
               :name :wlr-output-configure-primary-swapchain
               :detail (output-name output)))
      (let ((pointer (cffi:mem-ref swapchain-cell :pointer)))
        (if swapchain
            (progn
              (setf (%native-pointer swapchain) pointer)
              swapchain)
            (%wrap-pointer 'wlr-output-swapchain pointer runtime
                           :output output))))))

(defun acquire-output-buffer (swapchain)
  (check-type swapchain wlr-output-swapchain)
  (let* ((runtime (%native-runtime swapchain))
         (pointer
           (progn
             (%assert-runtime-live runtime :acquire-output-buffer)
             (%require-pointer
              (ataxia.runtime.raw:%wlr-swapchain-acquire
               (%object-pointer swapchain))
              :wlr-swapchain-acquire))))
    (%wrap-pointer
     'wlr-buffer pointer runtime
     :width (ataxia.runtime.raw:%buffer-width pointer)
     :height (ataxia.runtime.raw:%buffer-height pointer))))

(defun output-state-set-buffer (state buffer)
  (check-type state wlr-output-state)
  (check-type buffer wlr-buffer)
  (let ((runtime (%native-runtime state)))
    (%assert-runtime-live runtime :output-state-set-buffer)
    (%assert-object-runtime runtime buffer :output-state-set-buffer)
    (ataxia.runtime.raw:%wlr-output-state-set-buffer
     (%object-pointer state) (%object-pointer buffer)))
  state)

(defun output-buffer-framebuffer (renderer buffer)
  (check-type renderer wlr-renderer)
  (check-type buffer wlr-buffer)
  (let ((runtime (%native-runtime renderer)))
    (%assert-runtime-live runtime :output-buffer-framebuffer)
    (%assert-object-runtime runtime buffer :output-buffer-framebuffer)
    (let ((framebuffer
            (ataxia.runtime.raw:%wlr-gles2-renderer-get-buffer-fbo
             (%object-pointer renderer) (%object-pointer buffer))))
      (when (zerop framebuffer)
        (error 'native-call-failed
               :name :wlr-gles2-renderer-get-buffer-fbo))
      framebuffer)))

(defun destroy-output-swapchain (swapchain)
  (check-type swapchain wlr-output-swapchain)
  (when (native-object-live-p swapchain)
    (%assert-owner-thread (%native-runtime swapchain)
                          :destroy-output-swapchain)
    (ataxia.runtime.raw:%wlr-swapchain-destroy
     (%object-pointer swapchain))
    (%invalidate-native-object swapchain))
  nil)

(defun destroy-output-state (state)
  (check-type state wlr-output-state)
  (when (native-object-live-p state)
    (when (%output-state-borrowed-p state)
      (error 'native-call-failed
             :name :destroy-output-state
             :detail "borrowed output states are callback-scoped"))
    (%assert-owner-thread (%native-runtime state) :destroy-output-state)
    (ataxia.runtime.raw:%output-state-destroy (%object-pointer state))
    (%invalidate-native-object state))
  nil)

(defmethod backend-new-output
    ((sink diagnostic-sink) runtime (output wlr-output))
  "Implement BACKEND-NEW-OUTPUT for this output specialization. Respect output membership, layout, scale, and hotplug lifetime when updating state."
  (handler-case
      (progn
        (initialize-output-render output
                                  (runtime-allocator runtime)
                                  (runtime-renderer runtime))
        (let ((state (create-output-state output)))
          (unwind-protect
               (progn
                 (output-state-set-enabled state t)
                 (let ((mode (output-preferred-mode output)))
                   (when mode
                     (output-state-set-mode state mode)))
                 (unless (output-test-state output state)
                   (error 'native-call-failed
                          :name :wlr-output-test-state
                          :detail (output-name output)))
                 (unless (output-commit-state output state)
                   (error 'native-call-failed
                          :name :wlr-output-commit-state
                          :detail (output-name output))))
            (destroy-output-state state)))
        (create-output-global output)
        (%diagnostic-line
         sink "[runtime] new-output name=~A description=~A size=~Dx~D enabled=~A"
         (or (output-name output) "unknown")
         (or (output-description output) "none")
         (output-width output) (output-height output)
         (output-enabled-p output)))
    (native-call-failed (condition)
      (%diagnostic-line
       sink "[runtime] output-unavailable name=~A reason=~A"
       (or (output-name output) "unknown") condition))))
