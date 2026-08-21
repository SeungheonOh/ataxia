;;;; Stateless helpers for behavior-owned pointer interaction.
;;;;
;;;; Concrete policies own cursor and grab objects. This module only provides
;;;; fully contained algorithms that concrete policy methods may invoke.

(in-package #:ataxia.compositor)

(defconstant +resize-edge-top+ 1)
(defconstant +resize-edge-bottom+ 2)
(defconstant +resize-edge-left+ 4)
(defconstant +resize-edge-right+ 8)
(defconstant +button-left+ 272)

(defun require-behavior-seat-state (policy seat)
  (or (behavior-seat-state policy seat)
      (error 'invalid-compositor-state
             :operation :behavior-seat-state :state :missing-seat)))

(defun behavior-cursor-damage-region (seat output pointer-x pointer-y)
  (when output
    (multiple-value-bind (local-x local-y)
        (output-local-position output pointer-x pointer-y)
      (multiple-value-bind (width height hotspot-x hotspot-y)
          (case (seat-cursor-mode seat)
            (:hidden (values 0 0 0 0))
            (:surface
             (let ((record (seat-cursor-record seat)))
               (if record
                   (values (surface-record-width record)
                           (surface-record-height record)
                           (seat-cursor-hotspot-x seat)
                           (seat-cursor-hotspot-y seat))
                   (values 14 22 0 0))))
            (:default (values 14 22 0 0)))
        (when (and (plusp width) (plusp height))
          (make-damage-box
           (floor (- local-x hotspot-x 2d0))
           (floor (- local-y hotspot-y 2d0))
           (+ (ceiling width) 4) (+ (ceiling height) 4)))))))

(defun policy-presentation (policy)
  (compositor-presentation (component-compositor policy)))

(defun schedule-behavior-cursor-damage (policy seat old-output old-box)
  (let* ((state (require-behavior-seat-state policy seat))
         (new-output (behavior-state-cursor-output state))
         (new-box
           (behavior-cursor-damage-box
            policy seat new-output
            (behavior-cursor-x state) (behavior-cursor-y state))))
    (dolist (output
              (remove-duplicates
               (remove nil (list old-output new-output)) :test #'eq))
      (let ((boxes
              (remove nil
                      (list (and (eq output old-output) old-box)
                            (and (eq output new-output) new-box)))))
        (when boxes
          (schedule-presentation (policy-presentation policy) output boxes)))))
  seat)

(defun update-behavior-operation
    (policy interaction seat operation-updater)
  (let ((operation (behavior-operation policy seat)))
    (when operation
      (let ((decision
              (funcall operation-updater policy interaction operation)))
        (when (typep decision 'view-configuration-decision)
          (configure-view-size
           (interactive-operation-view operation)
           (configuration-width decision)
           (configuration-height decision))))
      (schedule-presentation-subject
       (policy-presentation policy)
       (interactive-operation-view operation)))
    operation))

(defun warp-behavior-cursor
    (policy interaction seat pointer-x pointer-y time-msec operation-updater)
  (let* ((state (require-behavior-seat-state policy seat))
         (old-x (behavior-cursor-x state))
         (old-y (behavior-cursor-y state))
         (old-output (behavior-state-cursor-output state))
         (old-box
           (behavior-cursor-damage-box
            policy seat old-output old-x old-y)))
    (multiple-value-bind (constrained-x constrained-y)
        (constrain-seat-pointer-position
         interaction seat old-x old-y old-output pointer-x pointer-y)
      (multiple-value-bind (output confined-x confined-y)
          (confine-layout-position
           (compositor-outputs (component-compositor policy))
           constrained-x constrained-y)
        (setf (behavior-state-cursor-output state) output)
        (when output
          (setf (behavior-cursor-x state) confined-x
                (behavior-cursor-y state) confined-y))))
    (if (behavior-operation policy seat)
        (update-behavior-operation
         policy interaction seat operation-updater)
        (update-pointer-focus-at
         interaction seat
         (behavior-cursor-x state) (behavior-cursor-y state) time-msec))
    (schedule-behavior-cursor-damage policy seat old-output old-box))
  seat)

(defun handle-behavior-pointer-motion
    (policy interaction seat event operation-updater)
  (multiple-value-bind (pointer-x pointer-y)
      (behavior-cursor-layout-position policy seat)
    (warp-behavior-cursor
     policy interaction seat
     (+ pointer-x (ataxia.runtime:pointer-motion-delta-x event))
     (+ pointer-y (ataxia.runtime:pointer-motion-delta-y event))
     (ataxia.runtime:pointer-motion-time-msec event)
     operation-updater)))

(defun handle-behavior-pointer-motion-absolute
    (policy interaction seat event operation-updater)
  (multiple-value-bind (minimum-x minimum-y maximum-x maximum-y)
      (output-layout-bounds
       (compositor-outputs (component-compositor policy)))
    (when minimum-x
      (warp-behavior-cursor
       policy interaction seat
       (+ minimum-x
          (* (ataxia.runtime:pointer-motion-absolute-x event)
             (- maximum-x minimum-x)))
       (+ minimum-y
          (* (ataxia.runtime:pointer-motion-absolute-y event)
             (- maximum-y minimum-y)))
       (ataxia.runtime:pointer-motion-absolute-time-msec event)
       operation-updater))))

(defun reconcile-behavior-cursors
    (policy interaction operation-updater)
  (let ((time-msec
          (mod (floor (* 1000d0 (monotonic-seconds))) #x100000000)))
    (dolist (seat (interaction-seats interaction))
      (multiple-value-bind (pointer-x pointer-y)
          (behavior-cursor-layout-position policy seat)
        (warp-behavior-cursor
         policy interaction seat pointer-x pointer-y time-msec
         operation-updater))))
  policy)

(defun behavior-interaction-context (view descriptor phase)
  (make-instance
   'hook-context :subject view :operation descriptor
   :old-state (interaction-old-state descriptor)
   :new-state (interaction-new-state descriptor)
   :cause :pointer :provenance (make-local-provenance :seat)
   :phase phase))

(defun start-behavior-interaction-animation
    (policy view old-state new-state)
  (let* ((descriptor
           (make-instance 'interaction-transition :subject view
                          :old-state old-state :new-state new-state))
         (context (behavior-interaction-context view descriptor :after)))
    (start-transition
     (presentation-animation-engine (policy-presentation policy))
     view descriptor context)
    (schedule-presentation-subject (policy-presentation policy) view)))

(defun pressed-operation-button (seat)
  (if (gethash +button-left+ (seat-pressed-buttons seat))
      +button-left+
      (loop for button being the hash-keys of (seat-pressed-buttons seat)
            return button)))

(defun begin-behavior-operation
    (policy interaction seat view kind edges button operation-maker)
  (unless (and (interaction-owns-seat-p interaction seat)
               (interaction-owns-view-p interaction view))
    (error 'invalid-compositor-state
           :operation :begin-behavior-operation :state :foreign-object))
  (let* ((descriptor
           (make-instance 'interaction-transition :subject view
                          :old-state nil :new-state kind))
         (hooks
           (extension-hooks
            (compositor-extensions (component-compositor policy)))))
    (run-hook hooks 'before-interactive-operation
              (behavior-interaction-context view descriptor :before))
    (behavior-cancel-operation policy interaction seat)
    (setf (behavior-state-operation
           (require-behavior-seat-state policy seat))
          (funcall operation-maker
                   policy interaction seat view kind edges
                   (or button (pressed-operation-button seat))))
    (when (eq kind :resize)
      (set-view-resizing view t))
    (focus-view interaction seat view)
    (synchronize-seat-pointer-constraint interaction seat)
    (start-behavior-interaction-animation policy view nil kind)
    (run-hook hooks 'after-interactive-operation
              (behavior-interaction-context view descriptor :after))
    (behavior-operation policy seat)))

(defun request-behavior-move
    (policy interaction seat view serial button operation-maker)
  (when (and serial
             (not (interaction-pointer-grab-serial-valid-p seat serial)))
    (return-from request-behavior-move nil))
  (begin-behavior-operation
   policy interaction seat view :move 0 button operation-maker))

(defun request-behavior-resize
    (policy interaction seat view edges serial button operation-maker)
  (when (or (zerop edges)
            (and serial
                 (not (interaction-pointer-grab-serial-valid-p seat serial))))
    (return-from request-behavior-resize nil))
  (begin-behavior-operation
   policy interaction seat view :resize edges button operation-maker))

(defun cancel-behavior-operation (policy interaction seat)
  (let* ((state (require-behavior-seat-state policy seat))
         (operation (behavior-state-operation state)))
    (when operation
      (let ((view (interactive-operation-view operation))
            (kind (interactive-operation-kind operation)))
        (when (eq kind :resize)
          (set-view-resizing view nil))
        (setf (behavior-state-operation state) nil)
        (synchronize-seat-pointer-constraint interaction seat)
        (start-behavior-interaction-animation policy view kind nil)))
    operation))

(defun cancel-behavior-view-operations (policy interaction view)
  (dolist (seat (interaction-seats interaction))
    (let ((operation (behavior-operation policy seat)))
      (when (and operation
                 (eq view (interactive-operation-view operation)))
        (behavior-cancel-operation policy interaction seat))))
  view)

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

(defun handle-behavior-pointer-button
    (policy interaction seat hit button state time)
  (declare (ignore time))
  (let* ((view (and hit (seat-hit-view hit)))
         (deliver-p t))
    (when (and (eq state :pressed) view)
      (case (presentation-hit-kind hit)
        (:titlebar
         (setf deliver-p nil)
         (focus-view interaction seat view)
         (when (= button +button-left+)
           (behavior-request-move
            policy interaction seat view :button button)))
        (:frame
         (setf deliver-p nil)
         (focus-view interaction seat view)
         (when (= button +button-left+)
           (multiple-value-bind (local-x local-y)
               (behavior-cursor-local-position policy seat)
             (behavior-request-resize
              policy interaction seat view
              (resize-edges-at-point
               (presentation-hit-item hit) local-x local-y)
              :button button))))))
    (let ((operation (behavior-operation policy seat)))
      (when (and (eq state :released) operation
                 (eql button (interactive-operation-button operation)))
        (behavior-cancel-operation policy interaction seat)))
    (make-instance 'pointer-button-decision
                   :focus-target (and (eq state :pressed) view)
                   :deliver-p deliver-p)))

(defmacro define-behavior-interaction-methods
    (policy-class seat-state-class seat-table-reader
     operation-maker operation-updater)
  `(progn
     (defmethod behavior-seat-state ((policy ,policy-class) seat)
       (gethash seat (,seat-table-reader policy)))

     (defmethod behavior-install-seat-state
         ((policy ,policy-class) seat state)
       (setf (gethash seat (,seat-table-reader policy)) state))

     (defmethod behavior-seat-created
         ((policy ,policy-class) interaction seat pointer-x pointer-y)
       (behavior-install-seat-state
        policy seat
        (make-instance ',seat-state-class
                       :cursor-x pointer-x :cursor-y pointer-y))
       (behavior-outputs-changed policy interaction)
       seat)

     (defmethod behavior-seat-destroying
         ((policy ,policy-class) interaction seat)
       (let* ((state (require-behavior-seat-state policy seat))
              (output (behavior-state-cursor-output state))
              (box
                (behavior-cursor-damage-box
                 policy seat output
                 (behavior-cursor-x state) (behavior-cursor-y state))))
         (behavior-cancel-operation policy interaction seat)
         (remhash seat (,seat-table-reader policy))
         (when (and output box)
           (schedule-presentation (policy-presentation policy)
                                  output (list box))))
       seat)

     (defmethod copy-behavior-seat-state
         ((policy ,policy-class) (state ,seat-state-class))
       (declare (ignore policy))
       (make-instance ',seat-state-class
                      :cursor-x (behavior-cursor-x state)
                      :cursor-y (behavior-cursor-y state)
                      :cursor-output (behavior-state-cursor-output state)))

     (defmethod behavior-cursor-layout-position
         ((policy ,policy-class) seat)
       (let ((state (require-behavior-seat-state policy seat)))
         (values (behavior-cursor-x state) (behavior-cursor-y state))))

     (defmethod behavior-cursor-output ((policy ,policy-class) seat)
       (behavior-state-cursor-output
        (require-behavior-seat-state policy seat)))

     (defmethod behavior-cursor-local-position
         ((policy ,policy-class) seat &optional output)
       (let* ((state (require-behavior-seat-state policy seat))
              (output (or output (behavior-state-cursor-output state))))
         (when output
           (output-local-position
            output (behavior-cursor-x state) (behavior-cursor-y state)))))

     (defmethod behavior-operation ((policy ,policy-class) seat)
       (behavior-state-operation
        (require-behavior-seat-state policy seat)))

     (defmethod behavior-cursor-damage-box
         ((policy ,policy-class) seat output pointer-x pointer-y)
       (declare (ignore policy))
       (behavior-cursor-damage-region
        seat output pointer-x pointer-y))

     (defmethod behavior-cursor-content-changed
         ((policy ,policy-class) interaction seat old-output old-box)
       (declare (ignore interaction))
       (schedule-behavior-cursor-damage policy seat old-output old-box))

     (defmethod behavior-warp-cursor
         ((policy ,policy-class) interaction seat
          pointer-x pointer-y time-msec)
       (warp-behavior-cursor
        policy interaction seat pointer-x pointer-y time-msec
        (function ,operation-updater)))

     (defmethod behavior-handle-pointer-motion
         ((policy ,policy-class) interaction seat event)
       (handle-behavior-pointer-motion
        policy interaction seat event (function ,operation-updater)))

     (defmethod behavior-handle-pointer-motion-absolute
         ((policy ,policy-class) interaction seat event)
       (handle-behavior-pointer-motion-absolute
        policy interaction seat event (function ,operation-updater)))

     (defmethod behavior-outputs-changed
         ((policy ,policy-class) interaction)
       (reconcile-behavior-cursors
        policy interaction (function ,operation-updater)))

     (defmethod behavior-request-move
         ((policy ,policy-class) interaction seat view &key serial button)
       (request-behavior-move
        policy interaction seat view serial button
        (function ,operation-maker)))

     (defmethod behavior-request-resize
         ((policy ,policy-class) interaction seat view edges
          &key serial button)
       (request-behavior-resize
        policy interaction seat view edges serial button
        (function ,operation-maker)))

     (defmethod behavior-cancel-operation
         ((policy ,policy-class) interaction seat)
       (cancel-behavior-operation policy interaction seat))

     (defmethod behavior-cancel-view-operations
         ((policy ,policy-class) interaction view)
       (cancel-behavior-view-operations policy interaction view))

     (defmethod behavior-handle-pointer-button
         ((policy ,policy-class) interaction seat hit button state time)
       (handle-behavior-pointer-button
        policy interaction seat hit button state time))

     (defmethod behavior-handle-pointer-axis
         ((policy ,policy-class) interaction seat input)
       (declare (ignore policy interaction seat input))
       (make-instance 'pointer-axis-decision))

     (defmethod behavior-handle-keyboard-key
         ((policy ,policy-class) interaction seat input)
       (declare (ignore policy interaction seat input))
       (make-instance 'keyboard-key-decision))))
