;;;; Logical seats and interactive operations.
;;;;
;;;; This module assigns wlroots input devices to compositor-owned logical
;;;; seats, routes pointer hits from presentation snapshots, and owns move and
;;;; resize grabs. It never duplicates rendering geometry.

(in-package #:ataxia.compositor)

(defconstant +resize-edge-top+ 1)
(defconstant +resize-edge-bottom+ 2)
(defconstant +resize-edge-left+ 4)
(defconstant +resize-edge-right+ 8)

(defparameter *trace-input-p*
  (not (null (uiop:getenv "ATAXIA_TRACE_INPUT"))))

(defun trace-input (control &rest arguments)
  (when *trace-input-p*
    (apply #'format *error-output* control arguments)
    (finish-output *error-output*)))

(defclass interaction-system (compositor-component)
  ((seats :initform nil :accessor interaction-seats)
   (device-seats :initform (make-hash-table :test #'eq)
                 :reader interaction-device-seats)
   (default-seat :initform nil :accessor interaction-default-seat)))

(defclass logical-seat ()
  ((name :initarg :name :reader seat-name)
   (native :initarg :native :reader seat-native)
   (devices :initform nil :accessor seat-devices)
   (keyboards :initform nil :accessor seat-keyboards)
   (active-keyboard :initform nil :accessor seat-active-keyboard)
   (pointer-x :initarg :pointer-x :initform 160d0 :accessor seat-pointer-x)
   (pointer-y :initarg :pointer-y :initform 100d0 :accessor seat-pointer-y)
   (pointer-focus-surface :initform nil :accessor seat-pointer-focus-surface)
   (pointer-focus-view :initform nil :accessor seat-pointer-focus-view)
   (pointer-surface-x :initform 0d0 :accessor seat-pointer-surface-x)
   (pointer-surface-y :initform 0d0 :accessor seat-pointer-surface-y)
   (focused-view :initform nil :accessor seat-focused-view)
   (cursor-record :initform nil :accessor seat-cursor-record)
   (cursor-hotspot-x :initform 0d0 :accessor seat-cursor-hotspot-x)
   (cursor-hotspot-y :initform 0d0 :accessor seat-cursor-hotspot-y)
   (pressed-buttons :initform (make-hash-table :test #'eql)
                    :reader seat-pressed-buttons)
   (operation :initform nil :accessor seat-operation)))

(defclass interactive-operation ()
  ((kind :initarg :kind :reader interactive-operation-kind)
   (seat :initarg :seat :reader interactive-operation-seat)
   (view :initarg :view :reader interactive-operation-view)
   (edges :initarg :edges :initform 0 :reader interactive-operation-edges)
   (start-x :initarg :start-x :reader interactive-operation-start-x)
   (start-y :initarg :start-y :reader interactive-operation-start-y)
   (original-placement :initarg :original-placement
                       :reader interactive-operation-original-placement)))

(defun primary-output (interaction)
  (first
   (compositor-outputs-list
    (compositor-outputs (component-compositor interaction)))))

(defun update-seat-capabilities (seat)
  (let ((capabilities 0))
    (when (find :pointer (seat-devices seat)
                :key #'ataxia.runtime:input-device-type)
      (setf capabilities
            (logior capabilities ataxia.runtime:+seat-capability-pointer+)))
    (when (seat-keyboards seat)
      (setf capabilities
            (logior capabilities ataxia.runtime:+seat-capability-keyboard+)))
    (ataxia.runtime:set-seat-capabilities (seat-native seat) capabilities))
  seat)

(defun create-logical-seat (interaction name &key (pointer-x 160d0)
                                                   (pointer-y 100d0))
  (check-type interaction interaction-system)
  (let* ((compositor (component-compositor interaction))
         (seat
           (make-instance
            'logical-seat :name name
            :native (ataxia.runtime:create-seat
                     (compositor-runtime compositor) name)
            :pointer-x (coerce pointer-x 'double-float)
            :pointer-y (coerce pointer-y 'double-float))))
    (push seat (interaction-seats interaction))
    (unless (interaction-default-seat interaction)
      (setf (interaction-default-seat interaction) seat))
    (update-seat-capabilities seat)
    seat))

(defun destroy-logical-seat (interaction seat)
  (check-type interaction interaction-system)
  (check-type seat logical-seat)
  (cancel-interactive-operation interaction seat)
  (let ((devices nil))
    (maphash
     (lambda (device assigned-seat)
       (when (eq seat assigned-seat)
         (push device devices)))
     (interaction-device-seats interaction))
    (dolist (device devices)
      (remhash device (interaction-device-seats interaction))))
  (setf (interaction-seats interaction)
        (delete seat (interaction-seats interaction) :test #'eq))
  (when (eq seat (interaction-default-seat interaction))
    (setf (interaction-default-seat interaction)
          (first (interaction-seats interaction))))
  (ataxia.runtime:destroy-seat (seat-native seat))
  nil)

(defmethod detach-component :before
    ((interaction interaction-system) reason)
  (declare (ignore reason))
  (dolist (seat (copy-list (interaction-seats interaction)))
    (destroy-logical-seat interaction seat))
  (clrhash (interaction-device-seats interaction)))

(defun interaction-seat-for-native (interaction native-seat)
  (find native-seat (interaction-seats interaction)
        :key #'seat-native :test #'eq))

(defun interaction-seat-for-device (interaction device)
  (gethash device (interaction-device-seats interaction)))

(defun interaction-add-input-device (interaction device &optional seat)
  (let ((target (or seat (interaction-default-seat interaction))))
    (unless target
      (setf target (create-logical-seat interaction "seat0")))
    (setf (gethash device (interaction-device-seats interaction)) target)
    (trace-input "[input] add ~A ~A -> ~A~%"
                 (ataxia.runtime:input-device-type device)
                 (or (ataxia.runtime:input-device-name device) "unnamed")
                 (seat-name target))
    (pushnew device (seat-devices target) :test #'eq)
    (when (eq :keyboard (ataxia.runtime:input-device-type device))
      (ataxia.runtime:set-keyboard-keymap-from-names device)
      (ataxia.runtime:set-keyboard-repeat-info device 25 600)
      (pushnew device (seat-keyboards target) :test #'eq)
      (setf (seat-active-keyboard target) device)
      (ataxia.runtime:set-seat-keyboard (seat-native target) device))
    (update-seat-capabilities target)
    target))

(defun interaction-remove-input-device (interaction device)
  (let ((seat (interaction-seat-for-device interaction device)))
    (when seat
      (remhash device (interaction-device-seats interaction))
      (setf (seat-devices seat)
            (delete device (seat-devices seat) :test #'eq)
            (seat-keyboards seat)
            (delete device (seat-keyboards seat) :test #'eq))
      (when (eq device (seat-active-keyboard seat))
        (setf (seat-active-keyboard seat) (first (seat-keyboards seat))))
      (update-seat-capabilities seat))
    seat))

(defun seat-hit-view (hit)
  (let ((owner (and hit (presentation-hit-owner hit))))
    (typecase owner
      (view owner)
      (popup-view (popup-parent-view owner))
      (t nil))))

(defun current-input-snapshot (interaction output)
  ;; Before the first draw, establish the immutable geometry that draw will use.
  (or (output-last-snapshot output)
      (setf (output-last-snapshot output)
            (build-presentation-snapshot
             (compositor-presentation (component-compositor interaction))
             output (monotonic-seconds)))))

(defun interaction-hit-test (interaction x y)
  (let ((output (primary-output interaction)))
    (when output
      (values
       (presentation-hit-test
        (current-input-snapshot interaction output) x y)
       output))))

(defun clamp-seat-pointer (interaction seat)
  (let ((output (primary-output interaction)))
    (when output
      (setf (seat-pointer-x seat)
            (max 0d0
                 (min (coerce
                       (max 0 (1- (ataxia.runtime:output-width
                                  (output-native output))))
                       'double-float)
                      (seat-pointer-x seat)))
            (seat-pointer-y seat)
            (max 0d0
                 (min (coerce
                       (max 0 (1- (ataxia.runtime:output-height
                                  (output-native output))))
                       'double-float)
                      (seat-pointer-y seat))))))
  seat)

(defun update-pointer-focus (interaction seat time-msec)
  (multiple-value-bind (hit output)
      (interaction-hit-test interaction
                            (seat-pointer-x seat) (seat-pointer-y seat))
    (declare (ignore output))
    (let ((surface (and hit (presentation-hit-surface hit))))
      (cond
        (surface
         (unless (eq surface (seat-pointer-focus-surface seat))
           ;; A cursor shape belongs to the focused client surface. Reset it
           ;; until the newly entered client supplies its own shape.
           (setf (seat-cursor-record seat) nil))
         (if (eq surface (seat-pointer-focus-surface seat))
             (ataxia.runtime:seat-pointer-notify-motion
              (seat-native seat) time-msec
              (presentation-hit-surface-x hit)
              (presentation-hit-surface-y hit))
             (ataxia.runtime:seat-pointer-notify-enter
              (seat-native seat) surface
              (presentation-hit-surface-x hit)
              (presentation-hit-surface-y hit)))
         (setf (seat-pointer-focus-surface seat) surface
               (seat-pointer-focus-view seat) (seat-hit-view hit)
               (seat-pointer-surface-x seat) (presentation-hit-surface-x hit)
               (seat-pointer-surface-y seat) (presentation-hit-surface-y hit)))
        (t
         (when (seat-pointer-focus-surface seat)
           (ataxia.runtime:seat-pointer-notify-clear-focus
            (seat-native seat)))
         (setf (seat-pointer-focus-surface seat) nil
               (seat-pointer-focus-view seat) nil
               (seat-cursor-record seat) nil)))
      hit)))

(defun focus-view (interaction seat view)
  (check-type interaction interaction-system)
  (check-type seat logical-seat)
  (when (and view (not (view-mapped-p view)))
    (return-from focus-view nil))
  (let ((previous (seat-focused-view seat)))
    (unless (eq previous view)
      (when previous
        (ataxia.runtime:xdg-toplevel-set-activated
         (view-native previous) nil))
      (setf (seat-focused-view seat) view)
      (if view
          (progn
            (desktop-raise-view
             (compositor-desktop (component-compositor interaction)) view)
            (ataxia.runtime:xdg-toplevel-set-activated
             (view-native view) t)
            (let ((keyboard (seat-active-keyboard seat)))
              (when keyboard
                (ataxia.runtime:set-seat-keyboard (seat-native seat) keyboard)
                (ataxia.runtime:seat-keyboard-notify-enter
                 (seat-native seat)
                 (surface-record-native (view-surface view)) keyboard))))
          (ataxia.runtime:seat-keyboard-notify-clear-focus
           (seat-native seat)))
      (schedule-presentation
       (compositor-presentation (component-compositor interaction)))))
  view)

(defun copy-planar-placement (placement)
  (make-instance 'planar-placement
                 :x (placement-x placement) :y (placement-y placement)
                 :width (placement-width placement)
                 :height (placement-height placement)
                 :z (placement-z placement)))

(defun interaction-hook-context (interaction view descriptor phase)
  (make-instance
   'hook-context :subject view :operation descriptor
   :old-state (and (typep descriptor 'interaction-transition)
                   (interaction-old-state descriptor))
   :new-state (and (typep descriptor 'interaction-transition)
                   (interaction-new-state descriptor))
   :cause :pointer :provenance (make-local-provenance :seat)
   :phase phase))

(defun start-interaction-animation (interaction view old-state new-state)
  (let* ((descriptor
           (make-instance 'interaction-transition :subject view
                          :old-state old-state :new-state new-state))
         (context (interaction-hook-context interaction view descriptor :after)))
    (start-transition
     (presentation-animation-engine
      (compositor-presentation (component-compositor interaction)))
     view descriptor context)))

(defun begin-interactive-operation (interaction seat view kind edges)
  (let ((placement (view-placement view)))
    (unless (typep placement 'planar-placement)
      (error 'compositor-error))
    (let* ((descriptor
             (make-instance 'interaction-transition :subject view
                            :old-state nil :new-state kind))
           (context
             (interaction-hook-context interaction view descriptor :before))
           (hooks
             (extension-hooks
              (compositor-extensions (component-compositor interaction)))))
      (run-hook hooks 'before-interactive-operation context)
      (cancel-interactive-operation interaction seat)
      (setf (seat-operation seat)
            (make-instance
             'interactive-operation :kind kind :seat seat :view view
             :edges edges :start-x (seat-pointer-x seat)
             :start-y (seat-pointer-y seat)
             :original-placement (copy-planar-placement placement)))
      (when (eq kind :resize)
        (ataxia.runtime:xdg-toplevel-set-resizing (view-native view) t))
      (focus-view interaction seat view)
      (start-interaction-animation interaction view nil kind)
      (run-hook hooks 'after-interactive-operation
                (interaction-hook-context interaction view descriptor :after))
      (seat-operation seat))))

(defun begin-interactive-move (interaction seat view &key serial)
  (when (and serial
             (not (and (seat-pointer-focus-surface seat)
                       (ataxia.runtime:seat-validate-pointer-grab-serial
                        (seat-native seat)
                        (seat-pointer-focus-surface seat) serial))))
    (return-from begin-interactive-move nil))
  (begin-interactive-operation interaction seat view :move 0))

(defun begin-interactive-resize (interaction seat view edges &key serial)
  (when (zerop edges)
    (return-from begin-interactive-resize nil))
  (when (and serial
             (not (and (seat-pointer-focus-surface seat)
                       (ataxia.runtime:seat-validate-pointer-grab-serial
                        (seat-native seat)
                        (seat-pointer-focus-surface seat) serial))))
    (return-from begin-interactive-resize nil))
  (begin-interactive-operation interaction seat view :resize edges))

(defun cancel-interactive-operation (interaction seat)
  (let ((operation (seat-operation seat)))
    (when operation
      (let ((view (interactive-operation-view operation)))
        (when (eq :resize (interactive-operation-kind operation))
          (ataxia.runtime:xdg-toplevel-set-resizing (view-native view) nil))
        (setf (seat-operation seat) nil)
        (start-interaction-animation
         interaction view (interactive-operation-kind operation) nil)
        (schedule-presentation
         (compositor-presentation (component-compositor interaction)))))
    operation))

(defun update-interactive-move (interaction operation)
  (let* ((seat (interactive-operation-seat operation))
         (view (interactive-operation-view operation))
         (original (interactive-operation-original-placement operation))
         (output (primary-output interaction))
         (scale (if output
                    (viewport-scale (output-viewport output))
                    1d0))
         (delta-x (/ (- (seat-pointer-x seat)
                        (interactive-operation-start-x operation)) scale))
         (delta-y (/ (- (seat-pointer-y seat)
                        (interactive-operation-start-y operation)) scale))
         (placement (view-placement view)))
    (setf (placement-x placement) (+ (placement-x original) delta-x)
          (placement-y placement) (+ (placement-y original) delta-y))
    placement))

(defun update-interactive-resize (interaction operation)
  (let* ((seat (interactive-operation-seat operation))
         (view (interactive-operation-view operation))
         (original (interactive-operation-original-placement operation))
         (output (primary-output interaction))
         (scale (if output
                    (viewport-scale (output-viewport output))
                    1d0))
         (delta-x (/ (- (seat-pointer-x seat)
                        (interactive-operation-start-x operation)) scale))
         (delta-y (/ (- (seat-pointer-y seat)
                        (interactive-operation-start-y operation)) scale))
         (edges (interactive-operation-edges operation))
         (left (placement-x original))
         (top (placement-y original))
         (right (+ left (placement-width original)))
         (bottom (+ top (placement-height original))))
    (when (logtest +resize-edge-left+ edges) (incf left delta-x))
    (when (logtest +resize-edge-right+ edges) (incf right delta-x))
    (when (logtest +resize-edge-top+ edges) (incf top delta-y))
    (when (logtest +resize-edge-bottom+ edges) (incf bottom delta-y))
    (when (< (- right left) 120d0)
      (if (logtest +resize-edge-left+ edges)
          (setf left (- right 120d0))
          (setf right (+ left 120d0))))
    (when (< (- bottom top) 80d0)
      (if (logtest +resize-edge-top+ edges)
          (setf top (- bottom 80d0))
          (setf bottom (+ top 80d0))))
    (let ((placement (view-placement view)))
      (setf (placement-x placement) left
            (placement-y placement) top
            (placement-width placement) (- right left)
            (placement-height placement) (- bottom top)
            (view-width view) (max 1 (round (- right left)))
            (view-height view) (max 1 (round (- bottom top))))
      (ataxia.runtime:xdg-toplevel-set-size
       (view-native view) (view-width view) (view-height view))
      placement)))

(defun update-interactive-operation (interaction seat)
  (let ((operation (seat-operation seat)))
    (when operation
      (ecase (interactive-operation-kind operation)
        (:move (update-interactive-move interaction operation))
        (:resize (update-interactive-resize interaction operation)))
      (schedule-presentation
       (compositor-presentation (component-compositor interaction))))
    operation))

(defun interaction-handle-pointer-motion (interaction event)
  (let ((seat
          (interaction-seat-for-device
           interaction (ataxia.runtime:pointer-motion-pointer event))))
    (when seat
      (trace-input "[input] relative ~,2F ~,2F~%"
                   (ataxia.runtime:pointer-motion-delta-x event)
                   (ataxia.runtime:pointer-motion-delta-y event))
      (incf (seat-pointer-x seat)
            (ataxia.runtime:pointer-motion-delta-x event))
      (incf (seat-pointer-y seat)
            (ataxia.runtime:pointer-motion-delta-y event))
      (clamp-seat-pointer interaction seat)
      (if (seat-operation seat)
          (update-interactive-operation interaction seat)
          (update-pointer-focus
           interaction seat (ataxia.runtime:pointer-motion-time-msec event)))
      (schedule-presentation
       (compositor-presentation (component-compositor interaction))))
    seat))

(defun interaction-handle-pointer-motion-absolute (interaction event)
  (let* ((seat
           (interaction-seat-for-device
            interaction
            (ataxia.runtime:pointer-motion-absolute-pointer event)))
         (output (and seat (primary-output interaction))))
    (when (and seat output)
      (trace-input "[input] absolute ~,3F ~,3F~%"
                   (ataxia.runtime:pointer-motion-absolute-x event)
                   (ataxia.runtime:pointer-motion-absolute-y event))
      (setf (seat-pointer-x seat)
            (* (ataxia.runtime:pointer-motion-absolute-x event)
               (ataxia.runtime:output-width (output-native output)))
            (seat-pointer-y seat)
            (* (ataxia.runtime:pointer-motion-absolute-y event)
               (ataxia.runtime:output-height (output-native output))))
      (clamp-seat-pointer interaction seat)
      (if (seat-operation seat)
          (update-interactive-operation interaction seat)
          (update-pointer-focus
           interaction seat
           (ataxia.runtime:pointer-motion-absolute-time-msec event)))
      (schedule-presentation
       (compositor-presentation (component-compositor interaction))))
    seat))

(defun resize-edges-at-point (item x y)
  (let* ((margin 8d0)
         (left (presentation-item-x item))
         (top (presentation-item-y item))
         (right (+ left (presentation-item-width item)))
         (bottom (+ top (presentation-item-height item)))
         (edges 0))
    (when (<= (abs (- x left)) margin)
      (setf edges (logior edges +resize-edge-left+)))
    (when (<= (abs (- x right)) margin)
      (setf edges (logior edges +resize-edge-right+)))
    (when (<= (abs (- y top)) margin)
      (setf edges (logior edges +resize-edge-top+)))
    (when (<= (abs (- y bottom)) margin)
      (setf edges (logior edges +resize-edge-bottom+)))
    edges))

(defun interaction-handle-pointer-button (interaction event)
  (let ((seat
          (interaction-seat-for-device
           interaction (ataxia.runtime:pointer-button-pointer event))))
    (when seat
      (trace-input "[input] button ~D ~A~%"
                   (ataxia.runtime:pointer-button-code event)
                   (ataxia.runtime:pointer-button-state event))
      (let* ((state (ataxia.runtime:pointer-button-state event))
             (button (ataxia.runtime:pointer-button-code event))
             (time (ataxia.runtime:pointer-button-time-msec event))
             (operation (seat-operation seat))
             (hit (unless operation
                    (update-pointer-focus interaction seat time)))
             (view (seat-hit-view hit)))
        (if (eq state :pressed)
            (setf (gethash button (seat-pressed-buttons seat)) t)
            (remhash button (seat-pressed-buttons seat)))
        (when (and (eq state :pressed) view)
          (focus-view interaction seat view)
          (case (presentation-hit-kind hit)
            (:titlebar
             (begin-interactive-move interaction seat view))
            (:frame
             (begin-interactive-resize
              interaction seat view
              (resize-edges-at-point
               (presentation-hit-item hit)
               (seat-pointer-x seat) (seat-pointer-y seat))))))
        (when (seat-pointer-focus-surface seat)
          (ataxia.runtime:seat-pointer-notify-button
           (seat-native seat) time button state))
        (when (and (eq state :released) operation)
          (cancel-interactive-operation interaction seat))
        (schedule-presentation
         (compositor-presentation (component-compositor interaction))))
      seat)))

(defun interaction-handle-pointer-axis (interaction event)
  (let ((seat
          (interaction-seat-for-device
           interaction (ataxia.runtime:pointer-axis-pointer event))))
    (when seat
      (trace-input "[input] key ~D ~A~%"
                   (ataxia.runtime:keyboard-key-keycode event)
                   (ataxia.runtime:keyboard-key-state event))
      (ataxia.runtime:seat-pointer-notify-axis
       (seat-native seat)
       (ataxia.runtime:pointer-axis-time-msec event)
       (ataxia.runtime:pointer-axis-orientation event)
       (ataxia.runtime:pointer-axis-delta event)
       (ataxia.runtime:pointer-axis-discrete-delta event)
       (ataxia.runtime:pointer-axis-source event)
       (ataxia.runtime:pointer-axis-relative-direction event)))
    seat))

(defun interaction-handle-pointer-frame (interaction pointer)
  (let ((seat (interaction-seat-for-device interaction pointer)))
    (when seat
      (ataxia.runtime:seat-pointer-notify-frame (seat-native seat)))
    seat))

(defun interaction-handle-keyboard-key (interaction event)
  (let* ((keyboard (ataxia.runtime:keyboard-key-keyboard event))
         (seat (interaction-seat-for-device interaction keyboard)))
    (when seat
      (setf (seat-active-keyboard seat) keyboard)
      (ataxia.runtime:set-seat-keyboard (seat-native seat) keyboard)
      (ataxia.runtime:seat-keyboard-notify-key
       (seat-native seat)
       (ataxia.runtime:keyboard-key-time-msec event)
       (ataxia.runtime:keyboard-key-keycode event)
       (ataxia.runtime:keyboard-key-state event)))
    seat))

(defun interaction-handle-keyboard-modifiers (interaction event)
  (let* ((keyboard (ataxia.runtime:keyboard-modifiers-keyboard event))
         (seat (interaction-seat-for-device interaction keyboard)))
    (when seat
      (setf (seat-active-keyboard seat) keyboard)
      (ataxia.runtime:set-seat-keyboard (seat-native seat) keyboard)
      (ataxia.runtime:seat-keyboard-notify-modifiers
       (seat-native seat) keyboard))
    seat))

(defun interaction-handle-cursor-request (interaction request)
  (let* ((seat
           (interaction-seat-for-native
            interaction (ataxia.runtime:seat-cursor-request-seat request)))
         (surface (ataxia.runtime:seat-cursor-request-surface request)))
    (when (and seat
               (or (null surface)
                   (and (seat-pointer-focus-surface seat)
                        (ataxia.runtime:seat-validate-pointer-grab-serial
                         (seat-native seat)
                         (seat-pointer-focus-surface seat)
                         (ataxia.runtime:seat-cursor-request-serial request)))))
      (setf (seat-cursor-record seat)
            (and surface
                 (ensure-surface-record
                  (compositor-surfaces (component-compositor interaction))
                  surface))
            (seat-cursor-hotspot-x seat)
            (coerce (ataxia.runtime:seat-cursor-request-hotspot-x request)
                    'double-float)
            (seat-cursor-hotspot-y seat)
            (coerce (ataxia.runtime:seat-cursor-request-hotspot-y request)
                    'double-float))
      (schedule-presentation
       (compositor-presentation (component-compositor interaction))))
    seat))
