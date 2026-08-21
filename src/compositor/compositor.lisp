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
   (state :initform :constructing :accessor compositor-state)))

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
    ((compositor compositor) (role (eql :behavior-policy))
     &rest initialization-arguments)
  (apply #'make-instance 'planar-behavior-policy
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
  (declare (ignore runtime))
  (setf (compositor-state compositor) :running))

(defmethod ataxia.runtime:runtime-stopping
    ((compositor compositor) runtime reason)
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
  (declare (ignore runtime))
  (apply-xdg-decoration-policy compositor decoration))

(defmethod ataxia.runtime:xdg-toplevel-decoration-request-mode
    ((compositor compositor) decoration)
  (apply-xdg-decoration-policy compositor decoration))

(defmethod ataxia.runtime:xdg-toplevel-decoration-destroying
    ((compositor compositor) decoration)
  (declare (ignore compositor decoration))
  nil)

(defmethod ataxia.runtime:xdg-activation-requested
    ((compositor compositor) runtime request)
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
  (declare (ignore runtime))
  (interaction-add-pointer-constraint
   (compositor-interaction compositor) constraint))

(defmethod ataxia.runtime:pointer-constraint-region-changed
    ((compositor compositor) constraint)
  (let* ((interaction (compositor-interaction compositor))
         (seat (constraint-logical-seat interaction constraint)))
    (when seat
      (synchronize-seat-pointer-constraint interaction seat))))

(defmethod ataxia.runtime:pointer-constraint-destroying
    ((compositor compositor) constraint)
  (interaction-remove-pointer-constraint
   (compositor-interaction compositor) constraint))

(defmethod ataxia.runtime:backend-new-output
    ((compositor compositor) runtime native-output)
  (let ((output
          (register-compositor-output
           (compositor-outputs compositor) runtime native-output)))
    (when output
      (behavior-output-added
       (compositor-behavior-policy compositor) output)
      (behavior-outputs-changed
       (compositor-behavior-policy compositor)
       (compositor-interaction compositor))
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
      (unless (or (output-full-damage-p output)
                  (output-damage-boxes output)
                  (output-damage-subjects output))
        (accumulate-output-damage output :full))
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
  (declare (ignore compositor))
  (ataxia.runtime:output-commit-state output state))

(defmethod ataxia.runtime:output-destroying
    ((compositor compositor) native-output)
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
        (when (eq output
                  (behavior-cursor-output
                   (compositor-behavior-policy compositor) seat))
          (ataxia.runtime:seat-pointer-notify-clear-focus (seat-native seat))
          (setf (seat-pointer-focus-surface seat) nil
                (seat-pointer-focus-view seat) nil)))
      (behavior-outputs-changed
       (compositor-behavior-policy compositor)
       (compositor-interaction compositor))
      (dolist (view (desktop-views (compositor-desktop compositor)))
        (when (eq output (view-fullscreen-output view))
          (setf (view-fullscreen-output view) nil)
          (when (view-fullscreen-p view)
            (configure-view-for-output
             compositor view :output (preferred-output-for-view compositor view)
             :fullscreen-p t)))))))

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
  (let* ((record
           (ensure-surface-record (compositor-surfaces compositor) surface))
         (old-width (surface-record-width record))
         (old-height (surface-record-height record))
         (old-mapped-p (surface-record-mapped-p record))
         (presentation (compositor-presentation compositor)))
    (refresh-surface-record record commit)
    (if (and (eq old-mapped-p (surface-record-mapped-p record))
             (= old-width (surface-record-width record))
             (= old-height (surface-record-height record)))
        (schedule-surface-damage
         presentation surface
         (ataxia.runtime:surface-commit-damage-rectangles commit))
        (schedule-presentation presentation))
    record))

(defmethod ataxia.runtime:surface-mapped
    ((compositor compositor) surface)
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (setf (surface-record-mapped-p record) t)
    (schedule-presentation (compositor-presentation compositor))))

(defmethod ataxia.runtime:surface-unmapped
    ((compositor compositor) surface)
  (let ((record
          (ensure-surface-record (compositor-surfaces compositor) surface)))
    (setf (surface-record-mapped-p record) nil)
    (surface-leave-all-outputs record)
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
    (behavior-view-created (compositor-behavior-policy compositor) view)
    view))

(defmethod ataxia.runtime:xdg-toplevel-committed
    ((compositor compositor) toplevel commit initial-commit-p configured-p)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (let ((width (ataxia.runtime:surface-commit-width commit))
            (height (ataxia.runtime:surface-commit-height commit))
            (old-width (view-width view))
            (old-height (view-height view)))
        (when (plusp width)
          (setf (view-width view) width
                (view-height view) height))
        (behavior-view-committed
         (compositor-behavior-policy compositor)
         view commit initial-commit-p)
        (when (and initial-commit-p (not configured-p))
          (setf (view-initialized-p view) t)
          (apply-pending-xdg-decoration compositor view)
          (multiple-value-bind (recommended-width recommended-height)
              (behavior-recommend-initial-size
               (compositor-behavior-policy compositor) compositor view)
            (ataxia.runtime:xdg-toplevel-set-wm-capabilities toplevel #x0f)
            (ataxia.runtime:xdg-toplevel-set-bounds
             toplevel recommended-width recommended-height)
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
                 view recommended-width recommended-height
                 (make-instance
                  'operation-context :subject view
                  :operation
                  (make-instance
                   'content-transition :subject view
                   :old-state nil
                   :new-state (list recommended-width recommended-height))
                  :old-state nil
                  :new-state (list recommended-width recommended-height)
                  :cause :initial-configure
                  :provenance (make-local-provenance :xdg-shell)
                  :phase :apply)))))))
        (setf (view-presentable-p view)
              (not (null (surface-record-texture (view-surface view)))))
        (when (or initial-commit-p
                  (/= old-width (view-width view))
                  (/= old-height (view-height view)))
          (schedule-presentation (compositor-presentation compositor)))))
    view))

(defmethod ataxia.runtime:xdg-toplevel-mapped
    ((compositor compositor) toplevel)
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
          (focus-view (compositor-interaction compositor) seat nil)))
      (behavior-cancel-view-operations
       (compositor-behavior-policy compositor)
       (compositor-interaction compositor) view)
      (schedule-presentation (compositor-presentation compositor)))
    view))

(defmethod ataxia.runtime:xdg-toplevel-destroying
    ((compositor compositor) toplevel)
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
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (desktop-update-view-identity
       (compositor-desktop compositor) view nil title)
      (behavior-view-identity-changed
       (compositor-behavior-policy compositor) view :title title))))

(defmethod ataxia.runtime:xdg-toplevel-app-id-changed
    ((compositor compositor) toplevel app-id)
  (let ((view (desktop-find-view (compositor-desktop compositor) toplevel)))
    (when view
      (desktop-update-view-identity
       (compositor-desktop compositor) view app-id nil)
      (behavior-view-identity-changed
       (compositor-behavior-policy compositor) view :app-id app-id))))

(defmethod ataxia.runtime:xdg-toplevel-request-move
    ((compositor compositor) event)
  (let* ((interaction (compositor-interaction compositor))
         (seat (interaction-seat-for-native
                interaction (ataxia.runtime:xdg-move-seat event)))
         (view (desktop-find-view
                (compositor-desktop compositor)
                (ataxia.runtime:xdg-move-toplevel event))))
    (when (and seat view (eq view (seat-pointer-focus-view seat)))
      (behavior-request-move
       (compositor-behavior-policy compositor)
       interaction seat view
       :serial (ataxia.runtime:xdg-move-serial event)))))

(defmethod ataxia.runtime:xdg-toplevel-request-resize
    ((compositor compositor) event)
  (let* ((interaction (compositor-interaction compositor))
         (seat (interaction-seat-for-native
                interaction (ataxia.runtime:xdg-resize-seat event)))
         (view (desktop-find-view
                (compositor-desktop compositor)
                (ataxia.runtime:xdg-resize-toplevel event))))
    (when (and seat view (eq view (seat-pointer-focus-view seat)))
      (behavior-request-resize
       (compositor-behavior-policy compositor)
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
                      (behavior-cursor-output
                       (compositor-behavior-policy compositor) seat))
              return (behavior-cursor-output
                      (compositor-behavior-policy compositor) seat))
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
        (ataxia.runtime:xdg-toplevel-set-maximized toplevel requested-p))
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
        (ataxia.runtime:xdg-toplevel-set-fullscreen toplevel requested-p))
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
      (let ((old-x (popup-x view))
            (old-y (popup-y view)))
        (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
          (setf (popup-x view) x (popup-y view) y))
        (when (or initial-commit-p
                  (/= old-x (popup-x view))
                  (/= old-y (popup-y view)))
          (schedule-presentation (compositor-presentation compositor)))))
    view))

(defmethod ataxia.runtime:xdg-popup-mapped
    ((compositor compositor) popup)
  (let ((view (desktop-find-popup (compositor-desktop compositor) popup)))
    (when view
      (setf (popup-mapped-p view) t)
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

(defgeneric replace-behavior-policy (compositor new-policy))

(defun component-replacement-context
    (compositor descriptor phase &optional metadata)
  (make-instance
   'hook-context :subject compositor :operation descriptor
   :old-state (replacement-old-component descriptor)
   :new-state (replacement-new-component descriptor)
   :cause :control :provenance (make-local-provenance :compositor)
   :phase phase :metadata metadata))

(defun install-behavior-state (policy installation)
  (dolist (entry (installation-view-states installation))
    (setf (view-behavior-state (car entry)) (cdr entry)))
  (dolist (entry (installation-output-states installation))
    (setf (output-behavior-state (car entry)) (cdr entry)))
  (dolist (entry (installation-seat-states installation))
    (behavior-install-seat-state policy (car entry) (cdr entry)))
  installation)

(defun validate-behavior-installation (compositor installation)
  (check-type installation behavior-installation)
  (let ((views (desktop-views (compositor-desktop compositor)))
        (outputs (compositor-outputs-list (compositor-outputs compositor)))
        (seats (interaction-seats (compositor-interaction compositor))))
    (unless (and (= (length views)
                    (length (installation-view-states installation)))
                 (= (length outputs)
                    (length (installation-output-states installation)))
                 (= (length seats)
                    (length (installation-seat-states installation)))
                 (null (set-exclusive-or
                        views (mapcar #'car
                                      (installation-view-states installation))
                        :test #'eq))
                 (null (set-exclusive-or
                        outputs (mapcar #'car
                                        (installation-output-states installation))
                        :test #'eq))
                 (null (set-exclusive-or
                        seats (mapcar #'car
                                      (installation-seat-states installation))
                        :test #'eq)))
      (error 'invalid-compositor-state
             :operation :replace-behavior-policy
             :state :incomplete-migration)))
  installation)

(defun refresh-policy-pointer-focus (compositor)
  (let ((time-msec
          (mod (floor (* 1000d0 (monotonic-seconds))) (expt 2 32))))
    (dolist (seat (interaction-seats (compositor-interaction compositor)))
      (let ((policy (compositor-behavior-policy compositor)))
        (unless (behavior-operation policy seat)
          (multiple-value-bind (pointer-x pointer-y)
              (behavior-cursor-layout-position policy seat)
            (update-pointer-focus-at
             (compositor-interaction compositor) seat
             pointer-x pointer-y time-msec)))))))

(defmethod replace-behavior-policy
    ((compositor compositor) (new-policy behavior-policy))
  (assert-compositor-owner compositor :replace-behavior-policy)
  (validate-component new-policy compositor)
  (when (eq new-policy (compositor-behavior-policy compositor))
    (return-from replace-behavior-policy new-policy))
  (dolist (seat (interaction-seats (compositor-interaction compositor)))
    (let ((old-policy (compositor-behavior-policy compositor)))
      (when (behavior-operation old-policy seat)
        (behavior-cancel-operation
         old-policy (compositor-interaction compositor) seat))))
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
                       (compositor-outputs compositor)))
              :seat-states
              (mapcar
               (lambda (seat)
                 (cons seat (behavior-seat-state old-policy seat)))
               (interaction-seats (compositor-interaction compositor)))))
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
            (install-behavior-state effective-policy new-installation)
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
            (install-behavior-state old-policy old-installation)
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
