;;;; Compositor aggregate and Runtime sink implementation.
;;;;
;;;; The aggregate owns every Layer 2 component. Runtime callbacks enter here
;;;; and immediately call the responsible component on the same owner thread.

(in-package #:ataxia.compositor)

(defclass compositor (ataxia.runtime:runtime-sink)
  ((runtime :reader compositor-runtime)
   (outputs :reader compositor-outputs)
   (surfaces :reader compositor-surfaces)
   (desktop :reader compositor-desktop)
   (interaction :reader compositor-interaction)
   (behavior-policy :accessor compositor-behavior-policy)
   (presentation :reader compositor-presentation)
   (graphics :reader compositor-graphics)
   (extensions :reader compositor-extensions)
   (control :reader compositor-control)
   (owner-thread :reader compositor-owner-thread)
   (state :initform :constructing :accessor compositor-state))
  (:documentation
   "Represents compositor compositor. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defun compositor-components (compositor)
  (remove nil
          (list (and (slot-boundp compositor 'behavior-policy)
                     (compositor-behavior-policy compositor))
                (and (slot-boundp compositor 'graphics)
                     (compositor-graphics compositor))
                (and (slot-boundp compositor 'outputs)
                     (compositor-outputs compositor))
                (and (slot-boundp compositor 'surfaces)
                     (compositor-surfaces compositor))
                (and (slot-boundp compositor 'desktop)
                     (compositor-desktop compositor))
                (and (slot-boundp compositor 'extensions)
                     (compositor-extensions compositor))
                (and (slot-boundp compositor 'presentation)
                     (compositor-presentation compositor))
                (and (slot-boundp compositor 'interaction)
                     (compositor-interaction compositor))
                (and (slot-boundp compositor 'control)
                     (compositor-control compositor)))))

(defgeneric make-compositor-component
    (compositor role &rest initialization-arguments)
  (:documentation
   "Implement MAKE-COMPOSITOR-COMPONENT for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :animation))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'animation-engine
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :presentation))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'presentation-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :behavior-policy))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'planar-behavior-policy
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :graphics))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'direct-gles-renderer
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :outputs))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'output-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :surfaces))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'surface-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :desktop))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'desktop-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :extensions))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'extension-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :interaction))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'interaction-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :control))
     &rest initialization-arguments)
  "Implement MAKE-COMPOSITOR-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (apply #'make-instance 'control-system
         :compositor compositor initialization-arguments))

(defgeneric construct-compositor-components (compositor)
  (:documentation
   "Implement CONSTRUCT-COMPOSITOR-COMPONENTS for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defmethod construct-compositor-components ((compositor compositor))
  "Implement CONSTRUCT-COMPOSITOR-COMPONENTS for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (let* ((animation
           (make-compositor-component compositor :animation))
         (presentation
           (make-compositor-component
            compositor :presentation :animation-engine animation)))
    (setf (slot-value compositor 'behavior-policy)
          (make-compositor-component compositor :behavior-policy)
          (slot-value compositor 'graphics)
          (make-compositor-component compositor :graphics)
          (slot-value compositor 'outputs)
          (make-compositor-component compositor :outputs)
          (slot-value compositor 'surfaces)
          (make-compositor-component compositor :surfaces)
          (slot-value compositor 'desktop)
          (make-compositor-component compositor :desktop)
          (slot-value compositor 'extensions)
          (make-compositor-component compositor :extensions)
          (slot-value compositor 'presentation) presentation
          (slot-value compositor 'interaction)
          (make-compositor-component compositor :interaction)
          (slot-value compositor 'control)
          (make-compositor-component compositor :control))
    (values animation presentation)))

(defun create-compositor
    (&key (backend :auto) (headless-width 1280) (headless-height 720)
          (socket-p t) debug-p damage-debug-p
          (compositor-class 'compositor))
  (unless (subtypep compositor-class 'compositor)
    (error 'invalid-compositor-state
           :operation :create-compositor :state compositor-class))
  (let ((compositor (make-instance compositor-class)))
    #+sb-thread
    (setf (slot-value compositor 'owner-thread) sb-thread:*current-thread*)
    #-sb-thread
    (setf (slot-value compositor 'owner-thread) nil)
    (handler-case
        (progn
          (setf (slot-value compositor 'runtime)
                (ataxia.runtime:create-runtime
                 :sink compositor :backend backend
                 :headless-width headless-width
                 :headless-height headless-height
                 :socket-p socket-p :debug-p debug-p))
          (multiple-value-bind (animation presentation)
              (construct-compositor-components compositor)
            (declare (ignore animation))
            (set-damage-debug-mode presentation damage-debug-p)
            (dolist (component (compositor-components compositor))
              (attach-component component)))
          (ataxia.runtime:create-xdg-shell (compositor-runtime compositor))
          (ataxia.runtime:create-desktop-shell-protocols
           (compositor-runtime compositor))
          (ataxia.runtime:create-pointer-protocols
           (compositor-runtime compositor))
          (ataxia.runtime:create-data-device-manager
           (compositor-runtime compositor))
          (ataxia.runtime:create-presentation-protocols
           (compositor-runtime compositor))
          (create-logical-seat (compositor-interaction compositor) "seat0")
          (setf (compositor-state compositor) :ready)
          compositor)
      (serious-condition (condition)
        (ignore-errors (destroy-compositor compositor :construction-failure))
        (error condition)))))

(defun start-compositor (compositor)
  (assert-compositor-owner compositor :start-compositor)
  (unless (eq (compositor-state compositor) :ready)
    (error 'invalid-compositor-state
           :operation :start-compositor :state (compositor-state compositor)))
  (ataxia.runtime:start-runtime (compositor-runtime compositor))
  compositor)

(defun run-compositor (compositor &key run-for)
  (assert-compositor-owner compositor :run-compositor)
  (when (eq (compositor-state compositor) :ready)
    (start-compositor compositor))
  (ataxia.runtime:run-runtime
   (compositor-runtime compositor) :run-for run-for)
  compositor)

(defun request-compositor-stop (compositor &optional (reason :requested))
  (assert-compositor-owner compositor :request-compositor-stop)
  (ataxia.runtime:request-runtime-stop
   (compositor-runtime compositor) reason)
  compositor)

(defun detach-compositor-components (compositor reason)
  ;; Buffers and output swapchains retire before the GLES context disappears.
  (dolist (component
            (remove nil
                    (list
                     (and (slot-boundp compositor 'control)
                          (compositor-control compositor))
                     (and (slot-boundp compositor 'interaction)
                          (compositor-interaction compositor))
                     (and (slot-boundp compositor 'presentation)
                          (compositor-presentation compositor))
                     (and (slot-boundp compositor 'surfaces)
                          (compositor-surfaces compositor))
                     (and (slot-boundp compositor 'outputs)
                          (compositor-outputs compositor))
                     (and (slot-boundp compositor 'graphics)
                          (compositor-graphics compositor))
                     (and (slot-boundp compositor 'extensions)
                          (compositor-extensions compositor))
                     (and (slot-boundp compositor 'desktop)
                          (compositor-desktop compositor))
                     (and (slot-boundp compositor 'behavior-policy)
                          (compositor-behavior-policy compositor)))))
    (when (eq (component-state component) :attached)
      (detach-component component reason)))
  compositor)

(defun destroy-compositor (compositor &optional (reason :shutdown))
  (when compositor
    (assert-compositor-owner compositor :destroy-compositor)
    (unless (eq (compositor-state compositor) :stopped)
      (setf (compositor-state compositor) :stopping)
      (detach-compositor-components compositor reason)
      (when (and (slot-boundp compositor 'runtime)
                 (compositor-runtime compositor))
        (ataxia.runtime:destroy-runtime
         (compositor-runtime compositor) reason))
      (setf (compositor-state compositor) :stopped)))
  nil)

(defmethod ataxia.runtime:runtime-started
    ((compositor compositor) runtime)
  "Implement ATAXIA.RUNTIME:RUNTIME-STARTED for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (declare (ignore runtime))
  (setf (compositor-state compositor) :running))

(defmethod ataxia.runtime:runtime-stopping
    ((compositor compositor) runtime reason)
  "Implement ATAXIA.RUNTIME:RUNTIME-STOPPING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (declare (ignore runtime reason))
  (unless (eq (compositor-state compositor) :stopped)
    (setf (compositor-state compositor) :stopping)))

(defun apply-xdg-decoration-policy (compositor decoration)
  (let ((view
          (desktop-find-view
           (compositor-desktop compositor)
           (ataxia.runtime:xdg-decoration-toplevel decoration))))
    (when view
      (let ((mode
              (case (ataxia.runtime:xdg-decoration-requested-mode decoration)
                (:server-side :server-side)
                (otherwise :client-side))))
        (setf (view-decoration-mode view) mode)
        (when (view-initialized-p view)
          (ataxia.runtime:xdg-toplevel-decoration-set-mode decoration mode))
        (schedule-presentation (compositor-presentation compositor))
        mode))))

(defun apply-pending-xdg-decoration (compositor view)
  (let ((decoration
          (ataxia.runtime:find-xdg-toplevel-decoration
           (compositor-runtime compositor) (view-native view))))
    (when decoration
      (apply-xdg-decoration-policy compositor decoration))))

(defmethod ataxia.runtime:xdg-new-toplevel-decoration
    ((compositor compositor) runtime decoration)
  "Implement ATAXIA.RUNTIME:XDG-NEW-TOPLEVEL-DECORATION for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (declare (ignore runtime))
  (apply-xdg-decoration-policy compositor decoration))

(defmethod ataxia.runtime:xdg-toplevel-decoration-request-mode
    ((compositor compositor) decoration)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-DECORATION-REQUEST-MODE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (apply-xdg-decoration-policy compositor decoration))

(defmethod ataxia.runtime:xdg-toplevel-decoration-destroying
    ((compositor compositor) decoration)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-DECORATION-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (declare (ignore compositor decoration))
  nil)

(defmethod ataxia.runtime:xdg-activation-requested
    ((compositor compositor) runtime request)
  "Implement ATAXIA.RUNTIME:XDG-ACTIVATION-REQUESTED for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (declare (ignore runtime))
  (let* ((interaction (compositor-interaction compositor))
         (native-seat (ataxia.runtime:xdg-activation-request-seat request))
         (seat
           (or (and native-seat
                    (find native-seat (interaction-seats interaction)
                          :key #'seat-native :test #'eq))
               (interaction-default-seat interaction)))
         (view
           (and (ataxia.runtime:xdg-activation-request-target-surface request)
                (desktop-find-view-by-surface
                 (compositor-desktop compositor)
                 (ataxia.runtime:xdg-activation-request-target-surface
                  request)))))
    (when (and seat view (view-mapped-p view))
      (desktop-raise-view (compositor-desktop compositor) view)
      (focus-view interaction seat view))))

(defmethod ataxia.runtime:pointer-constraint-created
    ((compositor compositor) runtime constraint)
  "Implement ATAXIA.RUNTIME:POINTER-CONSTRAINT-CREATED for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (declare (ignore runtime))
  (interaction-add-pointer-constraint
   (compositor-interaction compositor) constraint))

(defmethod ataxia.runtime:pointer-constraint-region-changed
    ((compositor compositor) constraint)
  "Implement ATAXIA.RUNTIME:POINTER-CONSTRAINT-REGION-CHANGED for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let* ((interaction (compositor-interaction compositor))
         (seat (constraint-logical-seat interaction constraint)))
    (when seat
      (synchronize-seat-pointer-constraint interaction seat))))

(defmethod ataxia.runtime:pointer-constraint-destroying
    ((compositor compositor) constraint)
  "Implement ATAXIA.RUNTIME:POINTER-CONSTRAINT-DESTROYING for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-remove-pointer-constraint
   (compositor-interaction compositor) constraint))

(defmethod ataxia.runtime:backend-new-output
    ((compositor compositor) runtime native-output)
  "Implement ATAXIA.RUNTIME:BACKEND-NEW-OUTPUT for this output specialization. Respect output membership, layout, scale, and hotplug lifetime when updating state."
  (let ((output
          (register-compositor-output
           (compositor-outputs compositor) runtime native-output)))
    (when output
      (behavior-output-added
       (compositor-behavior-policy compositor) output)
      (dolist (seat (interaction-seats (compositor-interaction compositor)))
        (clamp-seat-pointer (compositor-interaction compositor) seat))
      ;; The initial modeset already queues the first frame event. Scheduling
      ;; here can race a pending DRM page flip on physical backends.
      )
    output))

(defmethod ataxia.runtime:output-frame
    ((compositor compositor) native-output)
  "Implement ATAXIA.RUNTIME:OUTPUT-FRAME while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  (let ((output
          (find-compositor-output
           (compositor-outputs compositor) native-output)))
    (when output
      (trace-output
       "[output] frame ~A lisp-pending=~A native-pending=~A redraw=~A requested=~A~%"
       (ataxia.runtime:output-name native-output)
       (output-commit-pending-p output)
       (ataxia.runtime:output-frame-pending-p native-output)
       (output-redraw-pending-p output)
       (output-frame-requested-p output))
      (if (output-scanout-pending-p output)
          (setf (output-redraw-pending-p output) t)
          (cond
            ((or (output-frame-requested-p output)
                 (null (output-last-snapshot output)))
             (setf (output-frame-requested-p output) nil)
             (when (output-redraw-pending-p output)
               (queue-output-presentation
                (compositor-presentation compositor) output)))
            ((output-redraw-pending-p output)
             (arm-output-frame output)))))))

(defmethod ataxia.runtime:output-present
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:OUTPUT-PRESENT while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  (let ((output
          (find-compositor-output
           (compositor-outputs compositor)
           (ataxia.runtime:output-present-output event))))
    (when output
      (trace-output
       "[output] present ~A commit=~D presented=~A lisp-pending=~A native-pending=~A redraw=~A~%"
       (ataxia.runtime:output-name (output-native output))
       (ataxia.runtime:output-present-commit-sequence event)
       (ataxia.runtime:output-present-presented-p event)
       (output-commit-pending-p output)
       (ataxia.runtime:output-frame-pending-p (output-native output))
       (output-redraw-pending-p output))
      (record-output-presentation output event)
      output)))

(defmethod ataxia.runtime:output-needs-frame
    ((compositor compositor) native-output)
  "Implement ATAXIA.RUNTIME:OUTPUT-NEEDS-FRAME while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  ;; NEEDS-FRAME marks work; only FRAME acquires and commits a scanout buffer.
  (let ((output
          (find-compositor-output
           (compositor-outputs compositor) native-output)))
    (when output
      (trace-output "[output] needs-frame ~A~%"
                    (ataxia.runtime:output-name native-output))
      (unless (or (output-full-damage-p output)
                  (output-damage-boxes output))
        (accumulate-output-damage output :full))
      (setf (output-redraw-pending-p output) t)
      (unless (output-scanout-pending-p output)
        (request-output-frame-now output)))))

(defmethod ataxia.runtime:output-damaged
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:OUTPUT-DAMAGED while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."
  (let* ((native (ataxia.runtime:output-damage-output event))
         (output (find-compositor-output (compositor-outputs compositor)
                                         native)))
    (when output
      (trace-output "[output] damage ~A rectangles=~D~%"
                    (ataxia.runtime:output-name native)
                    (length (ataxia.runtime:output-damage-rectangles event)))
      (schedule-presentation
       (compositor-presentation compositor) output
       (mapcar
        (lambda (rectangle)
          (make-damage-box
           (ataxia.runtime:damage-rectangle-x rectangle)
           (ataxia.runtime:damage-rectangle-y rectangle)
           (ataxia.runtime:damage-rectangle-width rectangle)
           (ataxia.runtime:damage-rectangle-height rectangle)))
        (ataxia.runtime:output-damage-rectangles event))))))

(defmethod ataxia.runtime:output-request-state
    ((compositor compositor) output state)
  "Implement ATAXIA.RUNTIME:OUTPUT-REQUEST-STATE for this output specialization. Respect output membership, layout, scale, and hotplug lifetime when updating state."
  (declare (ignore compositor))
  (ataxia.runtime:output-commit-state output state))

(defmethod ataxia.runtime:output-destroying
    ((compositor compositor) native-output)
  "Implement ATAXIA.RUNTIME:OUTPUT-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (let ((output
          (find-compositor-output
           (compositor-outputs compositor) native-output)))
    (when output
      (behavior-output-removing
       (compositor-behavior-policy compositor) output)))
  (let ((output (find-compositor-output
                 (compositor-outputs compositor) native-output)))
    (when output
      (maphash
       (lambda (surface record)
         (declare (ignore surface))
         (surface-leave-output record output))
       (surface-records (compositor-surfaces compositor))))
    (when output
      (ataxia.runtime:with-egl-context
          ((ataxia.runtime:runtime-egl (compositor-runtime compositor)))
        (renderer-release-output-target
         (compositor-graphics compositor) output)))
    (unregister-compositor-output
     (compositor-outputs compositor) native-output)
    (when output
      (dolist (seat (interaction-seats (compositor-interaction compositor)))
        (when (eq output (seat-pointer-output seat))
          (ataxia.runtime:seat-pointer-notify-clear-focus (seat-native seat))
          (setf (seat-pointer-focus-surface seat) nil
                (seat-pointer-focus-view seat) nil))
        (clamp-seat-pointer (compositor-interaction compositor) seat))
      (dolist (view (desktop-views (compositor-desktop compositor)))
        (when (eq output (view-fullscreen-output view))
          (setf (view-fullscreen-output view) nil)
          (when (view-fullscreen-p view)
            (configure-view-for-output
             compositor view :output (preferred-output-for-view compositor view)
             :fullscreen-p t)
            (ataxia.runtime:xdg-toplevel-set-size
             (view-native view) (view-width view) (view-height view))))))))

(defmethod ataxia.runtime:backend-new-input
    ((compositor compositor) runtime device)
  "Implement ATAXIA.RUNTIME:BACKEND-NEW-INPUT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (declare (ignore runtime))
  (interaction-add-input-device (compositor-interaction compositor) device))

(defmethod ataxia.runtime:input-device-destroying
    ((compositor compositor) device)
  "Implement ATAXIA.RUNTIME:INPUT-DEVICE-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (interaction-remove-input-device
   (compositor-interaction compositor) device))

(defmethod ataxia.runtime:pointer-motion
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:POINTER-MOTION for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-pointer-motion
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-motion-absolute
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:POINTER-MOTION-ABSOLUTE for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-pointer-motion-absolute
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-button
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:POINTER-BUTTON for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-pointer-button
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-axis
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:POINTER-AXIS for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-pointer-axis
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-frame
    ((compositor compositor) pointer)
  "Implement ATAXIA.RUNTIME:POINTER-FRAME for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-pointer-frame
   (compositor-interaction compositor) pointer))

(defmethod ataxia.runtime:keyboard-key
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:KEYBOARD-KEY for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-keyboard-key
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:keyboard-modifiers
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:KEYBOARD-MODIFIERS for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-keyboard-modifiers
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:seat-request-set-cursor
    ((compositor compositor) request)
  "Implement ATAXIA.RUNTIME:SEAT-REQUEST-SET-CURSOR for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (interaction-handle-cursor-request
   (compositor-interaction compositor) request))

(defmethod ataxia.runtime:seat-destroying
    ((compositor compositor) native-seat)
  "Implement ATAXIA.RUNTIME:SEAT-DESTROYING for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let* ((interaction (compositor-interaction compositor))
         (seat (interaction-seat-for-native interaction native-seat)))
    (when seat
      (setf (interaction-seats interaction)
            (delete seat (interaction-seats interaction) :test #'eq)))))

(defmethod ataxia.runtime:compositor-new-surface
    ((compositor compositor) runtime surface)
  "Implement ATAXIA.RUNTIME:COMPOSITOR-NEW-SURFACE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (declare (ignore runtime))
  (ensure-surface-record (compositor-surfaces compositor) surface))

(defmethod ataxia.runtime:surface-committed
    ((compositor compositor) surface commit)
  "Implement ATAXIA.RUNTIME:SURFACE-COMMITTED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (refresh-surface-record record commit)
    (schedule-presentation (compositor-presentation compositor))
    record))

(defmethod ataxia.runtime:surface-mapped
    ((compositor compositor) surface)
  "Implement ATAXIA.RUNTIME:SURFACE-MAPPED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (setf (surface-record-mapped-p record) t)
    (schedule-presentation (compositor-presentation compositor))))

(defmethod ataxia.runtime:surface-unmapped
    ((compositor compositor) surface)
  "Implement ATAXIA.RUNTIME:SURFACE-UNMAPPED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (setf (surface-record-mapped-p record) nil)
    (surface-leave-all-outputs record)
    (release-surface-content record)
    (schedule-presentation (compositor-presentation compositor))))

(defmethod ataxia.runtime:surface-destroying
    ((compositor compositor) surface)
  "Implement ATAXIA.RUNTIME:SURFACE-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (dolist (seat (interaction-seats (compositor-interaction compositor)))
    (when (eq surface (seat-pointer-focus-surface seat))
      (ataxia.runtime:seat-pointer-notify-clear-focus (seat-native seat))
      (setf (seat-pointer-focus-surface seat) nil
            (seat-pointer-focus-view seat) nil))
    (when (and (seat-cursor-record seat)
               (eq surface
                   (surface-record-native (seat-cursor-record seat))))
      (setf (seat-cursor-record seat) nil
            (seat-cursor-mode seat) :default)))
  (retire-surface-record (compositor-surfaces compositor) surface)
  (schedule-presentation (compositor-presentation compositor)))

(defmethod ataxia.runtime:surface-new-subsurface
    ((compositor compositor) parent subsurface)
  "Implement ATAXIA.RUNTIME:SURFACE-NEW-SUBSURFACE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (ensure-surface-record
   (compositor-surfaces compositor)
   (ataxia.runtime:subsurface-surface subsurface))
  (register-subsurface (compositor-surfaces compositor) parent subsurface)
  (schedule-presentation (compositor-presentation compositor)))

(defmethod ataxia.runtime:subsurface-state-changed
    ((compositor compositor) subsurface)
  "Implement ATAXIA.RUNTIME:SUBSURFACE-STATE-CHANGED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (declare (ignore subsurface))
  (schedule-presentation (compositor-presentation compositor)))

(defmethod ataxia.runtime:subsurface-destroying
    ((compositor compositor) subsurface)
  "Implement ATAXIA.RUNTIME:SUBSURFACE-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (unregister-subsurface (compositor-surfaces compositor) subsurface)
  (schedule-presentation (compositor-presentation compositor)))

(defun start-view-visibility-transition (compositor view visible-p)
  (let* ((descriptor
           (make-instance 'visibility-transition :subject view
                          :old-state (not visible-p)
                          :new-state visible-p))
         (context
           (make-instance
            'operation-context :subject view :operation descriptor
            :old-state (not visible-p) :new-state visible-p
            :cause :wayland :provenance (make-local-provenance :client)
            :phase :after)))
    (start-transition
     (presentation-animation-engine (compositor-presentation compositor))
     view descriptor context)))

(defmethod ataxia.runtime:xdg-new-toplevel
    ((compositor compositor) toplevel)
  "Implement ATAXIA.RUNTIME:XDG-NEW-TOPLEVEL for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let* ((surface (ataxia.runtime:xdg-toplevel-surface toplevel))
         (record (ensure-surface-record
                  (compositor-surfaces compositor) surface))
         (view
           (desktop-register-view
            (compositor-desktop compositor) toplevel record
            (ataxia.runtime:xdg-toplevel-app-id toplevel)
            (ataxia.runtime:xdg-toplevel-title toplevel))))
    (behavior-view-created (compositor-behavior-policy compositor) view)
    view))

(defmethod ataxia.runtime:xdg-toplevel-committed
    ((compositor compositor) toplevel commit initial-commit-p configured-p)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-COMMITTED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (let ((width (ataxia.runtime:surface-commit-width commit))
            (height (ataxia.runtime:surface-commit-height commit)))
        (when (plusp width)
          (setf (view-width view) width
                (view-height view) height)))
      (behavior-view-committed
       (compositor-behavior-policy compositor)
       view commit initial-commit-p)
      (when (and initial-commit-p (not configured-p))
        (setf (view-initialized-p view) t)
        (apply-pending-xdg-decoration compositor view)
        (multiple-value-bind (width height)
            (behavior-recommend-initial-size
             (compositor-behavior-policy compositor) compositor view)
          (ataxia.runtime:xdg-toplevel-set-wm-capabilities toplevel #x0f)
          (ataxia.runtime:xdg-toplevel-set-bounds
           toplevel width height)
          (cond
            ((view-fullscreen-p view)
             (configure-view-for-output
              compositor view :output (view-fullscreen-output view)
              :fullscreen-p t)
             (ataxia.runtime:xdg-toplevel-set-fullscreen toplevel t))
            ((view-maximized-p view)
             (configure-view-for-output compositor view)
             (ataxia.runtime:xdg-toplevel-set-maximized toplevel t))
            (t
             (apply-view-configuration-decision
              view
              (behavior-set-view-size
               (compositor-behavior-policy compositor)
               view width height
               (make-instance
                'operation-context :subject view
                :operation
                (make-instance
                 'content-transition :subject view
                 :old-state nil :new-state (list width height))
                :old-state nil :new-state (list width height)
                :cause :initial-configure
                :provenance (make-local-provenance :xdg-shell)
                :phase :apply)))))))
      (setf (view-presentable-p view)
            (not (null (surface-record-texture (view-surface view)))))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-toplevel-mapped
    ((compositor compositor) toplevel)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-MAPPED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-mapped-p view) t
            (view-minimized-p view) nil
            (view-presentable-p view)
            (not (null (surface-record-texture (view-surface view)))))
      (behavior-view-mapped (compositor-behavior-policy compositor) view)
      (start-view-visibility-transition compositor view t)
      (let ((seat
              (interaction-default-seat
               (compositor-interaction compositor))))
        (when seat
          (focus-view (compositor-interaction compositor) seat view)))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-toplevel-unmapped
    ((compositor compositor) toplevel)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-UNMAPPED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-mapped-p view) nil
            (view-presentable-p view) nil)
      (cancel-animations-for-subject
       (presentation-animation-engine (compositor-presentation compositor))
       view)
      (behavior-view-unmapped (compositor-behavior-policy compositor) view)
      (dolist (seat (interaction-seats (compositor-interaction compositor)))
        (when (eq view (seat-focused-view seat))
          (focus-view (compositor-interaction compositor) seat nil))
        (when (and (seat-operation seat)
                   (eq view
                       (interactive-operation-view (seat-operation seat))))
          (cancel-interactive-operation
           (compositor-interaction compositor) seat)))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-toplevel-destroying
    ((compositor compositor) toplevel)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (cancel-animations-for-subject
       (presentation-animation-engine (compositor-presentation compositor))
       view)
      (behavior-view-destroying
       (compositor-behavior-policy compositor) view))
    (prog1
        (desktop-remove-view (compositor-desktop compositor) toplevel)
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-toplevel-title-changed
    ((compositor compositor) toplevel title)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-TITLE-CHANGED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (desktop-update-view-identity
       (compositor-desktop compositor) view nil title)
      (behavior-view-identity-changed
       (compositor-behavior-policy compositor) view :title title))))

(defmethod ataxia.runtime:xdg-toplevel-app-id-changed
    ((compositor compositor) toplevel app-id)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-APP-ID-CHANGED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (desktop-update-view-identity
       (compositor-desktop compositor) view app-id nil)
      (behavior-view-identity-changed
       (compositor-behavior-policy compositor) view :app-id app-id))))

(defmethod ataxia.runtime:xdg-toplevel-request-move
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-REQUEST-MOVE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let* ((interaction (compositor-interaction compositor))
         (seat (interaction-seat-for-native
                interaction (ataxia.runtime:xdg-move-seat event)))
         (view (desktop-find-view
                (compositor-desktop compositor)
                (ataxia.runtime:xdg-move-toplevel event))))
    (when (and seat view (eq view (seat-pointer-focus-view seat)))
      (begin-interactive-move
       interaction seat view :serial (ataxia.runtime:xdg-move-serial event)))))

(defmethod ataxia.runtime:xdg-toplevel-request-resize
    ((compositor compositor) event)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-REQUEST-RESIZE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let* ((interaction (compositor-interaction compositor))
         (seat (interaction-seat-for-native
                interaction (ataxia.runtime:xdg-resize-seat event)))
         (view (desktop-find-view
                (compositor-desktop compositor)
                (ataxia.runtime:xdg-resize-toplevel event))))
    (when (and seat view (eq view (seat-pointer-focus-view seat)))
      (begin-interactive-resize
       interaction seat view (ataxia.runtime:xdg-resize-edges event)
       :serial (ataxia.runtime:xdg-resize-serial event)))))

(defun restore-view-placement (compositor view)
  (apply-view-configuration-decision
   view
   (behavior-restore-view
    (compositor-behavior-policy compositor) compositor view)))

(defun preferred-output-for-view (compositor view)
  (or (loop for seat in (interaction-seats (compositor-interaction compositor))
            when (and (eq view (seat-focused-view seat))
                      (seat-pointer-output seat))
              return (seat-pointer-output seat))
      (let ((membership
              (surface-record-entered-outputs (view-surface view))))
        (find-if (lambda (output) (gethash output membership))
                 (compositor-outputs-list (compositor-outputs compositor))))
      (default-compositor-output compositor)))

(defun configure-view-for-output
    (compositor view &key output fullscreen-p)
  (apply-view-configuration-decision
   view
   (behavior-configure-view-for-output
    (compositor-behavior-policy compositor)
    compositor view (or output (preferred-output-for-view compositor view))
    (not (null fullscreen-p)))))

(defmethod ataxia.runtime:xdg-toplevel-request-maximize
    ((compositor compositor) toplevel requested-p)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-REQUEST-MAXIMIZE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-maximized-p view) requested-p)
      (when (view-initialized-p view)
        ;; Fullscreen owns placement while active. Preserve the requested
        ;; maximized state so leaving fullscreen can select the right layout.
        (unless (view-fullscreen-p view)
          (if requested-p
              (configure-view-for-output compositor view)
              (restore-view-placement compositor view)))
        (ataxia.runtime:xdg-toplevel-set-maximized toplevel requested-p)
        (ataxia.runtime:xdg-toplevel-set-size
         toplevel (view-width view) (view-height view)))
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-toplevel-request-minimize
    ((compositor compositor) toplevel requested-p)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-REQUEST-MINIMIZE for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-minimized-p view) requested-p)
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-toplevel-request-fullscreen
    ((compositor compositor) request)
  "Implement ATAXIA.RUNTIME:XDG-TOPLEVEL-REQUEST-FULLSCREEN for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let* ((toplevel (ataxia.runtime:xdg-fullscreen-toplevel request))
         (requested-p (ataxia.runtime:xdg-fullscreen-requested-p request))
         (requested-native-output (ataxia.runtime:xdg-fullscreen-output request))
         (requested-output
           (and requested-native-output
                (find-compositor-output
                 (compositor-outputs compositor) requested-native-output)))
         (view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-fullscreen-p view) requested-p
            (view-fullscreen-output view)
            (and requested-p
                 (or requested-output
                     (preferred-output-for-view compositor view))))
      (when (view-initialized-p view)
        (if requested-p
            (configure-view-for-output
             compositor view :output (view-fullscreen-output view)
             :fullscreen-p t)
            (if (view-maximized-p view)
                (configure-view-for-output compositor view)
                (restore-view-placement compositor view)))
        (ataxia.runtime:xdg-toplevel-set-fullscreen toplevel requested-p)
        (ataxia.runtime:xdg-toplevel-set-size
         toplevel (view-width view) (view-height view)))
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-new-popup
    ((compositor compositor) popup)
  "Implement ATAXIA.RUNTIME:XDG-NEW-POPUP for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let* ((surface (ataxia.runtime:xdg-popup-surface popup))
         (parent-surface (ataxia.runtime:xdg-popup-parent-surface popup))
         (parent-view
           (or (desktop-find-view-by-surface
                (compositor-desktop compositor) parent-surface)
               (desktop-find-popup-by-surface
                (compositor-desktop compositor) parent-surface)))
         (record
           (ensure-surface-record (compositor-surfaces compositor) surface)))
    (desktop-register-popup
     (compositor-desktop compositor) popup record parent-view)))

(defmethod ataxia.runtime:xdg-popup-committed
    ((compositor compositor) popup commit initial-commit-p configured-p)
  "Implement ATAXIA.RUNTIME:XDG-POPUP-COMMITTED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (declare (ignore commit))
  (when (and initial-commit-p (not configured-p))
    (ataxia.runtime:xdg-surface-schedule-configure popup))
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
        (setf (popup-x view) x (popup-y view) y))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-mapped
    ((compositor compositor) popup)
  "Implement ATAXIA.RUNTIME:XDG-POPUP-MAPPED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (setf (popup-mapped-p view) t)
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-unmapped
    ((compositor compositor) popup)
  "Implement ATAXIA.RUNTIME:XDG-POPUP-UNMAPPED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (setf (popup-mapped-p view) nil)
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-repositioned
    ((compositor compositor) popup)
  "Implement ATAXIA.RUNTIME:XDG-POPUP-REPOSITIONED for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
        (setf (popup-x view) x (popup-y view) y))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-destroying
    ((compositor compositor) popup)
  "Implement ATAXIA.RUNTIME:XDG-POPUP-DESTROYING idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (prog1
      (desktop-remove-popup (compositor-desktop compositor) popup)
    (schedule-presentation (compositor-presentation compositor))))

(defgeneric replace-behavior-policy (compositor new-policy)
  (:documentation
   "Implement REPLACE-BEHAVIOR-POLICY for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defun component-replacement-context
    (compositor descriptor phase &optional metadata)
  (make-instance
   'hook-context :subject compositor :operation descriptor
   :old-state (replacement-old-component descriptor)
   :new-state (replacement-new-component descriptor)
   :cause :control :provenance (make-local-provenance :compositor)
   :phase phase :metadata metadata))

(defun install-behavior-state (installation)
  (dolist (entry (installation-view-states installation))
    (setf (view-behavior-state (car entry)) (cdr entry)))
  (dolist (entry (installation-output-states installation))
    (setf (output-behavior-state (car entry)) (cdr entry)))
  installation)

(defun validate-behavior-installation (compositor installation)
  (check-type installation behavior-installation)
  (let ((views (desktop-views (compositor-desktop compositor)))
        (outputs (compositor-outputs-list (compositor-outputs compositor))))
    (unless (and (= (length views)
                    (length (installation-view-states installation)))
                 (= (length outputs)
                    (length (installation-output-states installation)))
                 (null (set-exclusive-or
                        views (mapcar #'car
                                      (installation-view-states installation))
                        :test #'eq))
                 (null (set-exclusive-or
                        outputs (mapcar #'car
                                        (installation-output-states installation))
                        :test #'eq)))
      (error 'invalid-compositor-state
             :operation :replace-behavior-policy
             :state :incomplete-migration)))
  installation)

(defun refresh-policy-pointer-focus (compositor)
  (let ((time-msec
          (mod (floor (* 1000d0 (monotonic-seconds))) (expt 2 32))))
    (dolist (seat (interaction-seats (compositor-interaction compositor)))
      (unless (seat-operation seat)
        (update-pointer-focus
         (compositor-interaction compositor) seat time-msec)))))

(defmethod replace-behavior-policy
    ((compositor compositor) (new-policy behavior-policy))
  "Implement REPLACE-BEHAVIOR-POLICY for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (assert-compositor-owner compositor :replace-behavior-policy)
  (validate-component new-policy compositor)
  (when (eq new-policy (compositor-behavior-policy compositor))
    (return-from replace-behavior-policy new-policy))
  (dolist (seat (interaction-seats (compositor-interaction compositor)))
    (when (seat-operation seat)
      (cancel-interactive-operation (compositor-interaction compositor) seat)))
  (let* ((hooks (extension-hooks (compositor-extensions compositor)))
         (old-policy (compositor-behavior-policy compositor))
         (requested-descriptor
           (make-instance
            'component-replacement :subject compositor :role :behavior-policy
            :old-component old-policy :new-component new-policy))
         (resolution-context
           (run-hook
            hooks 'component-replacement-resolving
            (component-replacement-context
             compositor requested-descriptor :resolve)))
         (descriptor (context-operation resolution-context))
         (effective-policy
           (and (typep descriptor 'component-replacement)
                (replacement-new-component descriptor))))
    (unless (and (typep effective-policy 'behavior-policy)
                 (eq :behavior-policy (replacement-role descriptor))
                 (eq compositor (operation-subject descriptor)))
      (error 'compositor-error))
    (validate-component effective-policy compositor)
    (unless (eq (component-state effective-policy) :detached)
      (error 'invalid-compositor-state
             :operation :replace-behavior-policy
             :state :policy-already-attached))
    (let* ((portable
             (behavior-export-state
              old-policy compositor resolution-context))
           (old-installation
             (make-instance
              'behavior-installation
              :view-states
              (mapcar (lambda (view)
                        (cons view (view-behavior-state view)))
                      (desktop-views (compositor-desktop compositor)))
              :output-states
              (mapcar (lambda (output)
                        (cons output (output-behavior-state output)))
                      (compositor-outputs-list
                       (compositor-outputs compositor)))))
           (old-snapshots
             (mapcar (lambda (output)
                       (cons output (output-last-snapshot output)))
                     (compositor-outputs-list
                      (compositor-outputs compositor))))
           (adopted-p nil))
      (run-hook
       hooks 'before-component-replacement
       (component-replacement-context compositor descriptor :before))
      (attach-component effective-policy)
      (handler-case
          (let ((new-installation
                  (validate-behavior-installation
                   compositor
                   (behavior-import-state
                    effective-policy portable resolution-context))))
            (install-behavior-state new-installation)
            (setf (compositor-behavior-policy compositor) effective-policy
                  adopted-p t)
            (prepare-active-animations-for-policy
             (presentation-animation-engine
              (compositor-presentation compositor))
             effective-policy)
            ;; Build immutable snapshots before retiring the old policy. Any
            ;; migration or scene failure rolls the entire object graph back.
            (let ((snapshots
                    (mapcar
                     (lambda (output)
                       (cons
                        output
                        (build-presentation-snapshot
                         (compositor-presentation compositor)
                         output (monotonic-seconds))))
                     (compositor-outputs-list
                      (compositor-outputs compositor)))))
              (behavior-validate-resources
               effective-policy compositor snapshots resolution-context)
              (dolist (entry snapshots)
                (setf (output-last-snapshot (car entry)) (cdr entry))))
            (refresh-policy-pointer-focus compositor)
            (detach-component old-policy :replaced)
            (schedule-presentation (compositor-presentation compositor))
            (run-hook
             hooks 'after-component-replacement
             (component-replacement-context compositor descriptor :after))
            effective-policy)
        (serious-condition (condition)
          (when adopted-p
            (setf (compositor-behavior-policy compositor) old-policy)
            (install-behavior-state old-installation)
            (dolist (entry old-snapshots)
              (setf (output-last-snapshot (car entry)) (cdr entry))))
          (when (eq (component-state old-policy) :detached)
            (attach-component old-policy))
          (when (eq (component-state effective-policy) :attached)
            (detach-component effective-policy :migration-failed))
          (ignore-errors
            (run-hook
             hooks 'component-replacement-failed
             (component-replacement-context
              compositor descriptor :failed condition)))
          (error condition))))))

(defun launch-application (compositor command)
  (let ((socket
          (ataxia.runtime:runtime-socket-name
           (compositor-runtime compositor))))
    (unless socket
      (error 'invalid-compositor-state
             :operation :launch-application :state :no-wayland-socket))
    (uiop:launch-program
     (append (list "/usr/bin/env"
                   (format nil "WAYLAND_DISPLAY=~A" socket)
                   "XDG_SESSION_TYPE=wayland"
                   "MOZ_ENABLE_WAYLAND=1")
             (if (listp command) command (list command)))
     :input nil :output *standard-output* :error-output *error-output*
     :wait nil)))
