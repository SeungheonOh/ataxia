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
   (world :accessor compositor-world)
   (presentation :reader compositor-presentation)
   (graphics :reader compositor-graphics)
   (extensions :reader compositor-extensions)
   (control :reader compositor-control)
   (owner-thread :reader compositor-owner-thread)
   (state :initform :constructing :accessor compositor-state)))

(defun compositor-components (compositor)
  (remove nil
          (list (and (slot-boundp compositor 'world)
                     (compositor-world compositor))
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
    (compositor role &rest initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :animation))
     &rest initialization-arguments)
  (apply #'make-instance 'animation-engine
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :presentation))
     &rest initialization-arguments)
  (apply #'make-instance 'presentation-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :world))
     &rest initialization-arguments)
  (apply #'make-instance 'planar-world
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :graphics))
     &rest initialization-arguments)
  (apply #'make-instance 'direct-gles-renderer
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :outputs))
     &rest initialization-arguments)
  (apply #'make-instance 'output-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :surfaces))
     &rest initialization-arguments)
  (apply #'make-instance 'surface-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :desktop))
     &rest initialization-arguments)
  (apply #'make-instance 'desktop-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :extensions))
     &rest initialization-arguments)
  (apply #'make-instance 'extension-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :interaction))
     &rest initialization-arguments)
  (apply #'make-instance 'interaction-system
         :compositor compositor initialization-arguments))

(defmethod make-compositor-component
    ((compositor compositor) (role (eql :control))
     &rest initialization-arguments)
  (apply #'make-instance 'control-system
         :compositor compositor initialization-arguments))

(defgeneric construct-compositor-components (compositor))

(defmethod construct-compositor-components ((compositor compositor))
  (let* ((animation
           (make-compositor-component compositor :animation))
         (presentation
           (make-compositor-component
            compositor :presentation :animation-engine animation)))
    (setf (slot-value compositor 'world)
          (make-compositor-component compositor :world)
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
          (socket-p t) debug-p (compositor-class 'compositor))
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
            (declare (ignore animation presentation))
            (dolist (component (compositor-components compositor))
              (attach-component component)))
          (ataxia.runtime:create-xdg-shell (compositor-runtime compositor))
          (ataxia.runtime:create-data-device-manager
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
                     (and (slot-boundp compositor 'world)
                          (compositor-world compositor)))))
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
  (declare (ignore runtime))
  (setf (compositor-state compositor) :running))

(defmethod ataxia.runtime:runtime-stopping
    ((compositor compositor) runtime reason)
  (declare (ignore runtime reason))
  (unless (eq (compositor-state compositor) :stopped)
    (setf (compositor-state compositor) :stopping)))

(defun send-surface-enter-all-outputs (compositor surface)
  (dolist (output
            (compositor-outputs-list (compositor-outputs compositor)))
    (ataxia.runtime:surface-send-enter surface (output-native output)))
  surface)

(defmethod ataxia.runtime:backend-new-output
    ((compositor compositor) runtime native-output)
  (let ((output
          (register-compositor-output
           (compositor-outputs compositor) runtime native-output)))
    (when output
      (dolist (record
                (loop for record being the hash-values
                        of (surface-records (compositor-surfaces compositor))
                      when (surface-record-mapped-p record)
                        collect record))
        (ataxia.runtime:surface-send-enter
         (surface-record-native record) native-output))
      ;; The initial modeset already queues the first frame event. Scheduling
      ;; here can race a pending DRM page flip on physical backends.
      )
    output))

(defmethod ataxia.runtime:output-frame
    ((compositor compositor) native-output)
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
  ;; NEEDS-FRAME marks work; only FRAME acquires and commits a scanout buffer.
  (let ((output
          (find-compositor-output
           (compositor-outputs compositor) native-output)))
    (when output
      (trace-output "[output] needs-frame ~A~%"
                    (ataxia.runtime:output-name native-output))
      (setf (output-redraw-pending-p output) t)
      (unless (output-scanout-pending-p output)
        (request-output-frame-now output)))))

(defmethod ataxia.runtime:output-damaged
    ((compositor compositor) event)
  (let* ((native (ataxia.runtime:output-damage-output event))
         (output (find-compositor-output (compositor-outputs compositor)
                                         native)))
    (when output
      (trace-output "[output] damage ~A rectangles=~D~%"
                    (ataxia.runtime:output-name native)
                    (length (ataxia.runtime:output-damage-rectangles event)))
      (schedule-presentation (compositor-presentation compositor) output))))

(defmethod ataxia.runtime:output-request-state
    ((compositor compositor) output state)
  (declare (ignore compositor))
  (ataxia.runtime:output-commit-state output state))

(defmethod ataxia.runtime:output-destroying
    ((compositor compositor) native-output)
  (dolist (record
            (loop for record being the hash-values
                    of (surface-records (compositor-surfaces compositor))
                  when (surface-record-mapped-p record)
                    collect record))
    (ataxia.runtime:surface-send-leave
     (surface-record-native record) native-output))
  (unregister-compositor-output
   (compositor-outputs compositor) native-output))

(defmethod ataxia.runtime:backend-new-input
    ((compositor compositor) runtime device)
  (declare (ignore runtime))
  (interaction-add-input-device (compositor-interaction compositor) device))

(defmethod ataxia.runtime:input-device-destroying
    ((compositor compositor) device)
  (interaction-remove-input-device
   (compositor-interaction compositor) device))

(defmethod ataxia.runtime:pointer-motion
    ((compositor compositor) event)
  (interaction-handle-pointer-motion
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-motion-absolute
    ((compositor compositor) event)
  (interaction-handle-pointer-motion-absolute
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-button
    ((compositor compositor) event)
  (interaction-handle-pointer-button
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-axis
    ((compositor compositor) event)
  (interaction-handle-pointer-axis
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:pointer-frame
    ((compositor compositor) pointer)
  (interaction-handle-pointer-frame
   (compositor-interaction compositor) pointer))

(defmethod ataxia.runtime:keyboard-key
    ((compositor compositor) event)
  (interaction-handle-keyboard-key
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:keyboard-modifiers
    ((compositor compositor) event)
  (interaction-handle-keyboard-modifiers
   (compositor-interaction compositor) event))

(defmethod ataxia.runtime:seat-request-set-cursor
    ((compositor compositor) request)
  (interaction-handle-cursor-request
   (compositor-interaction compositor) request))

(defmethod ataxia.runtime:seat-destroying
    ((compositor compositor) native-seat)
  (let* ((interaction (compositor-interaction compositor))
         (seat (interaction-seat-for-native interaction native-seat)))
    (when seat
      (setf (interaction-seats interaction)
            (delete seat (interaction-seats interaction) :test #'eq)))))

(defmethod ataxia.runtime:compositor-new-surface
    ((compositor compositor) runtime surface)
  (declare (ignore runtime))
  (ensure-surface-record (compositor-surfaces compositor) surface))

(defmethod ataxia.runtime:surface-committed
    ((compositor compositor) surface commit)
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (refresh-surface-record record commit)
    (schedule-presentation (compositor-presentation compositor))
    record))

(defmethod ataxia.runtime:surface-mapped
    ((compositor compositor) surface)
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (setf (surface-record-mapped-p record) t)
    (send-surface-enter-all-outputs compositor surface)
    (schedule-presentation (compositor-presentation compositor))))

(defmethod ataxia.runtime:surface-unmapped
    ((compositor compositor) surface)
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (setf (surface-record-mapped-p record) nil)
    (release-surface-content record)
    (schedule-presentation (compositor-presentation compositor))))

(defmethod ataxia.runtime:surface-destroying
    ((compositor compositor) surface)
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
  (ensure-surface-record
   (compositor-surfaces compositor)
   (ataxia.runtime:subsurface-surface subsurface))
  (register-subsurface (compositor-surfaces compositor) parent subsurface)
  (schedule-presentation (compositor-presentation compositor)))

(defmethod ataxia.runtime:subsurface-state-changed
    ((compositor compositor) subsurface)
  (declare (ignore subsurface))
  (schedule-presentation (compositor-presentation compositor)))

(defmethod ataxia.runtime:subsurface-destroying
    ((compositor compositor) subsurface)
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
  (let* ((surface (ataxia.runtime:xdg-toplevel-surface toplevel))
         (record (ensure-surface-record
                  (compositor-surfaces compositor) surface))
         (view
           (desktop-register-view
            (compositor-desktop compositor) toplevel record
            (ataxia.runtime:xdg-toplevel-app-id toplevel)
            (ataxia.runtime:xdg-toplevel-title toplevel))))
    (world-place-view (compositor-world compositor) view nil)
    view))

(defmethod ataxia.runtime:xdg-toplevel-committed
    ((compositor compositor) toplevel commit initial-commit-p configured-p)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (when (and initial-commit-p (not configured-p))
        (setf (view-initialized-p view) t)
        (let* ((output (primary-output (compositor-interaction compositor)))
               (width (if output
                          (min 900
                               (max 320
                                    (- (ataxia.runtime:output-width
                                        (output-native output)) 96)))
                          900))
               (height (if output
                           (min 650
                                (max 240
                                     (- (ataxia.runtime:output-height
                                         (output-native output)) 128)))
                           650)))
          (ataxia.runtime:xdg-toplevel-set-wm-capabilities toplevel #x0f)
          (ataxia.runtime:xdg-toplevel-set-bounds
           toplevel width height)
          (cond
            ((view-fullscreen-p view)
             (configure-view-for-output compositor view :fullscreen-p t)
             (ataxia.runtime:xdg-toplevel-set-fullscreen toplevel t))
            ((view-maximized-p view)
             (configure-view-for-output compositor view)
             (ataxia.runtime:xdg-toplevel-set-maximized toplevel t))
            (t
             (setf (view-width view) width (view-height view) height
                   (placement-width (view-placement view))
                   (coerce width 'double-float)
                   (placement-height (view-placement view))
                   (coerce height 'double-float))
             (ataxia.runtime:xdg-toplevel-set-size
              toplevel width height)))))
      (when (plusp (ataxia.runtime:surface-commit-width commit))
        (setf (view-width view)
              (ataxia.runtime:surface-commit-width commit)
              (view-height view)
              (ataxia.runtime:surface-commit-height commit)
              (placement-width (view-placement view))
              (coerce (view-width view) 'double-float)
              (placement-height (view-placement view))
              (coerce (view-height view) 'double-float)))
      (setf (view-presentable-p view)
            (not (null (surface-record-texture (view-surface view)))))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-toplevel-mapped
    ((compositor compositor) toplevel)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-mapped-p view) t
            (view-minimized-p view) nil
            (view-presentable-p view)
            (not (null (surface-record-texture (view-surface view)))))
      (send-surface-enter-all-outputs
       compositor (surface-record-native (view-surface view)))
      (desktop-raise-view (compositor-desktop compositor) view)
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
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-mapped-p view) nil
            (view-presentable-p view) nil)
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
  (prog1
      (desktop-remove-view (compositor-desktop compositor) toplevel)
    (schedule-presentation (compositor-presentation compositor))))

(defmethod ataxia.runtime:xdg-toplevel-title-changed
    ((compositor compositor) toplevel title)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (desktop-update-view-identity
       (compositor-desktop compositor) view nil title))))

(defmethod ataxia.runtime:xdg-toplevel-app-id-changed
    ((compositor compositor) toplevel app-id)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (desktop-update-view-identity
       (compositor-desktop compositor) view app-id nil))))

(defmethod ataxia.runtime:xdg-toplevel-request-move
    ((compositor compositor) event)
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

(defun restore-view-placement (view)
  (when (view-restore-placement view)
    (setf (view-placement view) (view-restore-placement view)
          (view-restore-placement view) nil
          (view-width view) (round (placement-width (view-placement view)))
          (view-height view) (round (placement-height (view-placement view)))))
  view)

(defun configure-view-for-output (compositor view &key fullscreen-p)
  (let ((output (primary-output (compositor-interaction compositor))))
    (when output
      (unless (view-restore-placement view)
        (setf (view-restore-placement view)
              (copy-planar-placement (view-placement view))))
      (let* ((native (output-native output))
             (panel (if fullscreen-p
                        0d0
                        (presentation-panel-height
                         (compositor-presentation compositor))))
             (titlebar (if fullscreen-p 0d0 28d0))
             (scale (viewport-scale (output-viewport output)))
             (placement (view-placement view))
             (width (/ (ataxia.runtime:output-width native) scale))
             (height (/ (- (ataxia.runtime:output-height native)
                           panel titlebar)
                        scale)))
        (multiple-value-bind (world-x world-y)
            (world-unproject (compositor-world compositor) output
                             (output-viewport output) 0d0 panel)
          (setf (placement-x placement) world-x
                (placement-y placement) world-y
                (placement-width placement) width
                (placement-height placement) height
                (view-width view) (max 1 (round width))
                (view-height view) (max 1 (round height)))
          (ataxia.runtime:xdg-toplevel-set-size
           (view-native view) (view-width view) (view-height view))))))
  view)

(defmethod ataxia.runtime:xdg-toplevel-request-maximize
    ((compositor compositor) toplevel requested-p)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-maximized-p view) requested-p)
      (when (view-initialized-p view)
        ;; Fullscreen owns placement while active. Preserve the requested
        ;; maximized state so leaving fullscreen can select the right layout.
        (unless (view-fullscreen-p view)
          (if requested-p
              (configure-view-for-output compositor view)
              (restore-view-placement view)))
        (ataxia.runtime:xdg-toplevel-set-maximized toplevel requested-p)
        (ataxia.runtime:xdg-toplevel-set-size
         toplevel (view-width view) (view-height view)))
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-toplevel-request-minimize
    ((compositor compositor) toplevel requested-p)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-minimized-p view) requested-p)
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-toplevel-request-fullscreen
    ((compositor compositor) request)
  (let* ((toplevel (ataxia.runtime:xdg-fullscreen-toplevel request))
         (requested-p (ataxia.runtime:xdg-fullscreen-requested-p request))
         (view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (setf (view-fullscreen-p view) requested-p)
      (when (view-initialized-p view)
        (if requested-p
            (configure-view-for-output compositor view :fullscreen-p t)
            (if (view-maximized-p view)
                (configure-view-for-output compositor view)
                (restore-view-placement view)))
        (ataxia.runtime:xdg-toplevel-set-fullscreen toplevel requested-p)
        (ataxia.runtime:xdg-toplevel-set-size
         toplevel (view-width view) (view-height view)))
      (schedule-presentation (compositor-presentation compositor)))))

(defmethod ataxia.runtime:xdg-new-popup
    ((compositor compositor) popup)
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
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (setf (popup-mapped-p view) t)
      (send-surface-enter-all-outputs
       compositor (surface-record-native (popup-surface view)))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-unmapped
    ((compositor compositor) popup)
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (setf (popup-mapped-p view) nil)
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-repositioned
    ((compositor compositor) popup)
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
        (setf (popup-x view) x (popup-y view) y))
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-popup-destroying
    ((compositor compositor) popup)
  (prog1
      (desktop-remove-popup (compositor-desktop compositor) popup)
    (schedule-presentation (compositor-presentation compositor))))

(defgeneric migrate-world-placement (old-world new-world view placement))
(defgeneric replace-world (compositor new-world))

(defmethod migrate-world-placement
    ((old-world planar-world) (new-world planar-world)
     view (placement planar-placement))
  (declare (ignore old-world new-world view))
  (copy-planar-placement placement))

(defun component-replacement-context
    (compositor descriptor phase &optional metadata)
  (make-instance
   'hook-context :subject compositor :operation descriptor
   :old-state (replacement-old-component descriptor)
   :new-state (replacement-new-component descriptor)
   :cause :control :provenance (make-local-provenance :compositor)
   :phase phase :metadata metadata))

(defmethod replace-world ((compositor compositor) (new-world world))
  (assert-compositor-owner compositor :replace-world)
  (validate-component new-world compositor)
  (when (eq new-world (compositor-world compositor))
    (return-from replace-world new-world))
  (when (find-if #'seat-operation
                 (interaction-seats (compositor-interaction compositor)))
    (error 'invalid-compositor-state
           :operation :replace-world :state :active-interaction))
  (let* ((hooks (extension-hooks (compositor-extensions compositor)))
         (old-world (compositor-world compositor))
         (requested-descriptor
           (make-instance
            'component-replacement :subject compositor :role :world
            :old-component old-world :new-component new-world))
         (resolution-context
           (run-hook
            hooks 'component-replacement-resolving
            (component-replacement-context
             compositor requested-descriptor :resolve)))
         (descriptor (context-operation resolution-context))
         (effective-world
           (and (typep descriptor 'component-replacement)
                (replacement-new-component descriptor))))
    (unless (and (typep effective-world 'world)
                 (eq :world (replacement-role descriptor))
                 (eq compositor (operation-subject descriptor)))
      (error 'compositor-error))
    (validate-component effective-world compositor)
    (let* ((migrations
           (mapcar
            (lambda (view)
              (let ((old-placement (view-placement view)))
                (list view old-placement
                      (migrate-world-placement
                       old-world effective-world view old-placement))))
            (desktop-views (compositor-desktop compositor))))
         (adopted-p nil))
      (run-hook
       hooks 'before-component-replacement
       (component-replacement-context compositor descriptor :before))
      (attach-component effective-world)
      (handler-case
          (progn
            (dolist (migration migrations)
              (setf (view-placement (first migration)) (third migration)))
            (setf (compositor-world compositor) effective-world
                  adopted-p t)
            (detach-component old-world :replaced)
            (schedule-presentation (compositor-presentation compositor))
            (run-hook
             hooks 'after-component-replacement
             (component-replacement-context compositor descriptor :after))
            effective-world)
        (serious-condition (condition)
          ;; Restore one coherent world/placement set before reporting failure.
          (when adopted-p
            (setf (compositor-world compositor) old-world)
            (dolist (migration migrations)
              (setf (view-placement (first migration)) (second migration))))
          (when (eq (component-state old-world) :detached)
            (attach-component old-world))
          (when (eq (component-state effective-world) :attached)
            (detach-component effective-world :migration-failed))
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
