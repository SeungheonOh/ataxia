;;;; Behavior-owned cursor and interactive operation policy.
;;;;
;;;; Standard policies keep spatial cursor state and move/resize grabs here.
;;;; The compositor interaction component only enforces Wayland protocol rules.

(in-package #:ataxia.compositor)

(defconstant +resize-edge-top+ 1)
(defconstant +resize-edge-bottom+ 2)
(defconstant +resize-edge-left+ 4)
(defconstant +resize-edge-right+ 8)
(defconstant +button-left+ 272)

(defclass standard-seat-state ()
  ((cursor-x :initarg :cursor-x :accessor behavior-cursor-x)
   (cursor-y :initarg :cursor-y :accessor behavior-cursor-y)
   (cursor-output :initarg :cursor-output :initform nil
                  :accessor standard-cursor-output)
   (operation :initform nil :accessor standard-seat-operation)))

(defclass interactive-operation ()
  ((kind :initarg :kind :reader interactive-operation-kind)
   (seat :initarg :seat :reader interactive-operation-seat)
   (view :initarg :view :reader interactive-operation-view)
   (output :initarg :output :initform nil :reader interactive-operation-output)
   (edges :initarg :edges :initform 0 :reader interactive-operation-edges)
   (button :initarg :button :reader interactive-operation-button)
   (start-x :initarg :start-x :reader interactive-operation-start-x)
   (start-y :initarg :start-y :reader interactive-operation-start-y)
   (original-width :initarg :original-width
                   :reader interactive-operation-original-width)
   (original-height :initarg :original-height
                    :reader interactive-operation-original-height)
   (original-placement :initarg :original-placement
                       :reader interactive-operation-original-placement)))

(defgeneric behavior-begin-operation
    (policy interaction seat view kind edges button))
(defgeneric behavior-update-operation (policy interaction operation))

(defun require-standard-seat-state (policy seat)
  (or (behavior-seat-state policy seat)
      (error 'invalid-compositor-state
             :operation :behavior-seat-state :state :missing-seat)))

(defmethod behavior-seat-created
    ((policy standard-behavior-policy) interaction seat pointer-x pointer-y)
  (declare (ignore interaction))
  (behavior-install-seat-state
   policy seat
   (make-instance 'standard-seat-state
                  :cursor-x pointer-x :cursor-y pointer-y))
  (behavior-outputs-changed policy (seat-interaction seat))
  seat)

(defmethod behavior-seat-destroying
    ((policy standard-behavior-policy) interaction seat)
  (let* ((state (require-standard-seat-state policy seat))
         (output (standard-cursor-output state))
         (box
           (behavior-cursor-damage-box
            policy seat output
            (behavior-cursor-x state) (behavior-cursor-y state))))
    (behavior-cancel-operation policy interaction seat)
    (remhash seat (standard-behavior-seat-states policy))
    (when (and output box)
      (behavior-schedule-presentation
       policy :output output :damage (list box))))
  seat)

(defmethod copy-behavior-seat-state
    ((policy standard-behavior-policy) (state standard-seat-state))
  (declare (ignore policy))
  (make-instance 'standard-seat-state
                 :cursor-x (behavior-cursor-x state)
                 :cursor-y (behavior-cursor-y state)
                 :cursor-output (standard-cursor-output state)))

(defmethod migrate-behavior-seat-state
    ((old-policy standard-behavior-policy)
     (new-policy standard-behavior-policy) seat
     (state standard-seat-state))
  (declare (ignore old-policy seat))
  (copy-behavior-seat-state new-policy state))

(defmethod behavior-cursor-layout-position
    ((policy standard-behavior-policy) seat)
  (let ((state (require-standard-seat-state policy seat)))
    (values (behavior-cursor-x state) (behavior-cursor-y state))))

(defmethod behavior-cursor-output
    ((policy standard-behavior-policy) seat)
  (standard-cursor-output (require-standard-seat-state policy seat)))

(defmethod behavior-cursor-local-position
    ((policy standard-behavior-policy) seat &optional output)
  (let* ((state (require-standard-seat-state policy seat))
         (output (or output (standard-cursor-output state))))
    (when output
      (output-local-position
       output (behavior-cursor-x state) (behavior-cursor-y state)))))

(defmethod behavior-operation ((policy standard-behavior-policy) seat)
  (standard-seat-operation (require-standard-seat-state policy seat)))

(defmethod behavior-cursor-damage-box
    ((policy standard-behavior-policy) seat output pointer-x pointer-y)
  (declare (ignore policy))
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

(defun schedule-standard-cursor-damage
    (policy seat old-output old-box)
  (let* ((state (require-standard-seat-state policy seat))
         (new-output (standard-cursor-output state))
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
          (behavior-schedule-presentation
           policy :output output :damage boxes)))))
  seat)

(defmethod behavior-cursor-content-changed
    ((policy standard-behavior-policy) interaction seat old-output old-box)
  (declare (ignore interaction))
  (schedule-standard-cursor-damage policy seat old-output old-box))

(defun update-standard-operation (policy interaction seat)
  (let ((operation (behavior-operation policy seat)))
    (when operation
      (let ((decision
              (behavior-update-operation policy interaction operation)))
        (when (typep decision 'view-configuration-decision)
          (configure-view-size
           (interactive-operation-view operation)
           (configuration-width decision)
           (configuration-height decision))))
      (behavior-schedule-presentation
       policy :subject (interactive-operation-view operation)))
    operation))

(defmethod behavior-warp-cursor
    ((policy standard-behavior-policy) interaction seat
     pointer-x pointer-y time-msec)
  (let* ((state (require-standard-seat-state policy seat))
         (old-x (behavior-cursor-x state))
         (old-y (behavior-cursor-y state))
         (old-output (standard-cursor-output state))
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
        (setf (standard-cursor-output state) output)
        (when output
          (setf (behavior-cursor-x state) confined-x
                (behavior-cursor-y state) confined-y))))
    (if (behavior-operation policy seat)
        (update-standard-operation policy interaction seat)
        (update-pointer-focus-at
         interaction seat
         (behavior-cursor-x state) (behavior-cursor-y state) time-msec))
    (schedule-standard-cursor-damage policy seat old-output old-box))
  seat)

(defmethod behavior-handle-pointer-motion
    ((policy standard-behavior-policy) interaction seat event)
  (multiple-value-bind (pointer-x pointer-y)
      (behavior-cursor-layout-position policy seat)
    (behavior-warp-cursor
     policy interaction seat
     (+ pointer-x (ataxia.runtime:pointer-motion-delta-x event))
     (+ pointer-y (ataxia.runtime:pointer-motion-delta-y event))
     (ataxia.runtime:pointer-motion-time-msec event))))

(defmethod behavior-handle-pointer-motion-absolute
    ((policy standard-behavior-policy) interaction seat event)
  (multiple-value-bind (minimum-x minimum-y maximum-x maximum-y)
      (output-layout-bounds
       (compositor-outputs (component-compositor policy)))
    (when minimum-x
      (behavior-warp-cursor
       policy interaction seat
       (+ minimum-x
          (* (ataxia.runtime:pointer-motion-absolute-x event)
             (- maximum-x minimum-x)))
       (+ minimum-y
          (* (ataxia.runtime:pointer-motion-absolute-y event)
             (- maximum-y minimum-y)))
       (ataxia.runtime:pointer-motion-absolute-time-msec event)))))

(defmethod behavior-outputs-changed
    ((policy standard-behavior-policy) interaction)
  (let ((time-msec
          (mod (floor (* 1000d0 (monotonic-seconds))) #x100000000)))
    (dolist (seat (interaction-seats interaction))
      (multiple-value-bind (pointer-x pointer-y)
          (behavior-cursor-layout-position policy seat)
        (behavior-warp-cursor
         policy interaction seat pointer-x pointer-y time-msec))))
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
     (presentation-animation-engine
      (compositor-presentation (component-compositor policy)))
     view descriptor context)))

(defun pressed-operation-button (seat)
  (if (gethash +button-left+ (seat-pressed-buttons seat))
      +button-left+
      (loop for button being the hash-keys of (seat-pressed-buttons seat)
            return button)))

(defun begin-behavior-operation
    (policy interaction seat view kind edges button)
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
    (setf (standard-seat-operation
           (require-standard-seat-state policy seat))
          (behavior-begin-operation
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

(defmethod behavior-request-move
    ((policy standard-behavior-policy) interaction seat view
     &key serial button)
  (when (and serial
             (not (interaction-pointer-grab-serial-valid-p seat serial)))
    (return-from behavior-request-move nil))
  (begin-behavior-operation
   policy interaction seat view :move 0 button))

(defmethod behavior-request-resize
    ((policy standard-behavior-policy) interaction seat view edges
     &key serial button)
  (when (or (zerop edges)
            (and serial
                 (not (interaction-pointer-grab-serial-valid-p seat serial))))
    (return-from behavior-request-resize nil))
  (begin-behavior-operation
   policy interaction seat view :resize edges button))

(defmethod behavior-cancel-operation
    ((policy standard-behavior-policy) interaction seat)
  (let* ((state (require-standard-seat-state policy seat))
         (operation (standard-seat-operation state)))
    (when operation
      (let ((view (interactive-operation-view operation))
            (kind (interactive-operation-kind operation)))
        (when (eq kind :resize)
          (set-view-resizing view nil))
        (setf (standard-seat-operation state) nil)
        (synchronize-seat-pointer-constraint interaction seat)
        (start-behavior-interaction-animation policy view kind nil)
        (behavior-schedule-presentation policy :subject view)))
    operation))

(defmethod behavior-cancel-view-operations
    ((policy standard-behavior-policy) interaction view)
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

(defmethod behavior-handle-pointer-button
    ((policy standard-behavior-policy) interaction seat hit button state time)
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
