;;;; Relative pointer and pointer-constraint protocols.
;;;;
;;;; Runtime mirrors wlroots constraint objects and forwards exact lifecycle
;;;; callbacks. Logical focus, geometry mapping, activation, and confinement
;;;; policy remain in the compositor interaction system.

(in-package #:ataxia.runtime.raw)

(defcfun ("wlr_relative_pointer_manager_v1_create"
          %wlr-relative-pointer-manager-v1-create) :pointer
  (display :pointer))
(defcfun ("wlr_relative_pointer_manager_v1_send_relative_motion"
          %wlr-relative-pointer-manager-v1-send-relative-motion) :void
  (manager :pointer)
  (seat :pointer)
  (time-usec :uint64)
  (delta-x :double)
  (delta-y :double)
  (unaccelerated-delta-x :double)
  (unaccelerated-delta-y :double))
(defcfun ("wlr_pointer_constraints_v1_create"
          %wlr-pointer-constraints-v1-create) :pointer
  (display :pointer))
(defcfun ("wlr_pointer_constraint_v1_send_activated"
          %wlr-pointer-constraint-v1-send-activated) :void
  (constraint :pointer))
(defcfun ("wlr_pointer_constraint_v1_send_deactivated"
          %wlr-pointer-constraint-v1-send-deactivated) :void
  (constraint :pointer))

(define-signal-binding %pointer-constraints-event-new-constraint
  "ataxia_pointer_constraints_event_new_constraint" manager)
(define-signal-binding %pointer-constraints-event-destroy
  "ataxia_pointer_constraints_event_destroy" manager)
(define-signal-binding %pointer-constraint-event-set-region
  "ataxia_pointer_constraint_event_set_region" constraint)
(define-signal-binding %pointer-constraint-event-destroy
  "ataxia_pointer_constraint_event_destroy" constraint)
(defcfun ("ataxia_pointer_constraint_surface" %pointer-constraint-surface)
    :pointer
  (constraint :pointer))
(defcfun ("ataxia_pointer_constraint_seat" %pointer-constraint-seat) :pointer
  (constraint :pointer))
(defcfun ("ataxia_pointer_constraint_type" %pointer-constraint-type) :uint32
  (constraint :pointer))
(defcfun ("ataxia_pointer_constraint_confine" %pointer-constraint-confine)
    :boolean
  (constraint :pointer)
  (x1 :double) (y1 :double) (x2 :double) (y2 :double)
  (confined-x :pointer) (confined-y :pointer))
(defcfun ("ataxia_pointer_constraint_region_empty"
          %pointer-constraint-region-empty) :boolean
  (constraint :pointer))
(defcfun ("ataxia_pointer_constraint_cursor_hint"
          %pointer-constraint-cursor-hint) :boolean
  (constraint :pointer)
  (x :pointer) (y :pointer))

(in-package #:ataxia.runtime)

(defclass wlr-relative-pointer-manager-v1 (native-object) ())
(defclass wlr-pointer-constraints-v1 (native-object) ())
(defclass wlr-pointer-constraint-v1 (native-object)
  ((surface :initarg :surface :reader pointer-constraint-surface)
   (seat :initarg :seat :reader pointer-constraint-seat)
   (type :initarg :type :reader pointer-constraint-type)))

(defgeneric pointer-constraint-created (sink runtime constraint))
(defgeneric pointer-constraint-region-changed (sink constraint))
(defgeneric pointer-constraint-destroying (sink constraint))

(defmethod pointer-constraint-created
    ((sink runtime-sink) runtime constraint)
  (declare (ignore runtime constraint))
  nil)
(defmethod pointer-constraint-region-changed
    ((sink runtime-sink) constraint)
  (declare (ignore constraint))
  nil)
(defmethod pointer-constraint-destroying
    ((sink runtime-sink) constraint)
  (declare (ignore constraint))
  nil)

(defun runtime-relative-pointer-manager (runtime)
  (%runtime-relative-pointer-manager runtime))

(defun runtime-pointer-constraints-manager (runtime)
  (%runtime-pointer-constraints-manager runtime))

(defun runtime-pointer-constraints (runtime)
  (%hash-values (%runtime-pointer-constraint-table runtime)))

(defun pointer-constraint-type-keyword (value)
  (case value (0 :locked) (1 :confined) (otherwise :unknown)))

(defun retire-pointer-constraint (runtime constraint)
  (%retire-object-listeners constraint :immediate-p t)
  (remhash (native-object-address constraint)
           (%runtime-pointer-constraint-table runtime))
  (%invalidate-native-object constraint)
  constraint)

(defun handle-new-pointer-constraint (runtime pointer)
  (let* ((surface-pointer
           (ataxia.runtime.raw:%pointer-constraint-surface pointer))
         (seat-pointer
           (ataxia.runtime.raw:%pointer-constraint-seat pointer))
         (surface (%adopt-core-surface runtime surface-pointer))
         (seat
           (or (gethash (%pointer-key seat-pointer) (%runtime-seat-table runtime))
               (error 'native-call-failed
                      :name :pointer-constraint-seat
                      :detail "unknown seat")))
         (constraint
           (%wrap-pointer
            'wlr-pointer-constraint-v1 pointer runtime
            :surface surface :seat seat
            :type
            (pointer-constraint-type-keyword
             (ataxia.runtime.raw:%pointer-constraint-type pointer)))))
    (setf (gethash (%pointer-key pointer)
                   (%runtime-pointer-constraint-table runtime))
          constraint)
    (%attach-object-signal
     constraint :pointer-constraint-set-region
     (ataxia.runtime.raw:%pointer-constraint-event-set-region pointer)
     (lambda (data)
       (declare (ignore data))
       (pointer-constraint-region-changed
        (%runtime-sink runtime) constraint)))
    (%attach-object-signal
     constraint :pointer-constraint-destroy
     (ataxia.runtime.raw:%pointer-constraint-event-destroy pointer)
     (lambda (data)
       (declare (ignore data))
       (unwind-protect
            (pointer-constraint-destroying
             (%runtime-sink runtime) constraint)
         (retire-pointer-constraint runtime constraint))))
    (pointer-constraint-created (%runtime-sink runtime) runtime constraint)
    constraint))

(defun create-pointer-protocols (runtime)
  (%assert-runtime-live runtime :create-pointer-protocols)
  (when (or (%runtime-relative-pointer-manager runtime)
            (%runtime-pointer-constraints-manager runtime))
    (error 'native-call-failed
           :name :create-pointer-protocols
           :detail "pointer protocols already exist"))
  (let* ((display (%object-pointer (%runtime-display runtime)))
         (relative-pointer
           (%wrap-pointer
            'wlr-relative-pointer-manager-v1
            (%require-pointer
             (ataxia.runtime.raw:%wlr-relative-pointer-manager-v1-create
              display)
             :wlr-relative-pointer-manager-v1-create)
            runtime))
         (constraints-pointer
           (%require-pointer
            (ataxia.runtime.raw:%wlr-pointer-constraints-v1-create display)
            :wlr-pointer-constraints-v1-create))
         (constraints
           (%wrap-pointer 'wlr-pointer-constraints-v1
                          constraints-pointer runtime)))
    (setf (%runtime-relative-pointer-manager runtime) relative-pointer
          (%runtime-pointer-constraints-manager runtime) constraints)
    (%attach-object-signal
     constraints :pointer-constraints-new-constraint
     (ataxia.runtime.raw:%pointer-constraints-event-new-constraint
      constraints-pointer)
     (lambda (constraint-pointer)
       (handle-new-pointer-constraint runtime constraint-pointer)))
    (values relative-pointer constraints)))

(defun relative-pointer-send-motion
    (manager seat time-usec delta-x delta-y
     unaccelerated-delta-x unaccelerated-delta-y)
  (%assert-object-runtime (%native-runtime manager) seat
                          :relative-pointer-send-motion)
  (ataxia.runtime.raw:%wlr-relative-pointer-manager-v1-send-relative-motion
   (%object-pointer manager) (%object-pointer seat) time-usec
   (coerce delta-x 'double-float) (coerce delta-y 'double-float)
   (coerce unaccelerated-delta-x 'double-float)
   (coerce unaccelerated-delta-y 'double-float))
  seat)

(defun pointer-constraint-send-activated (constraint)
  (ataxia.runtime.raw:%wlr-pointer-constraint-v1-send-activated
   (%object-pointer constraint))
  constraint)

(defun pointer-constraint-send-deactivated (constraint)
  (ataxia.runtime.raw:%wlr-pointer-constraint-v1-send-deactivated
   (%object-pointer constraint))
  constraint)

(defun pointer-constraint-confine (constraint x1 y1 x2 y2)
  (%ensure-live constraint)
  (cffi:with-foreign-objects ((confined-x :double) (confined-y :double))
    (if (ataxia.runtime.raw:%pointer-constraint-confine
         (%object-pointer constraint)
         (coerce x1 'double-float) (coerce y1 'double-float)
         (coerce x2 'double-float) (coerce y2 'double-float)
         confined-x confined-y)
        (values t (cffi:mem-ref confined-x :double)
                (cffi:mem-ref confined-y :double))
        (values nil x1 y1))))

(defun pointer-constraint-region-empty-p (constraint)
  (%ensure-live constraint)
  (ataxia.runtime.raw:%pointer-constraint-region-empty
   (%object-pointer constraint)))

(defun pointer-constraint-cursor-hint (constraint)
  (%ensure-live constraint)
  (cffi:with-foreign-objects ((x :double) (y :double))
    (if (ataxia.runtime.raw:%pointer-constraint-cursor-hint
         (%object-pointer constraint) x y)
        (values t (cffi:mem-ref x :double) (cffi:mem-ref y :double))
        (values nil 0d0 0d0))))
