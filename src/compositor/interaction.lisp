;;;; Logical seats and interactive operations.
;;;;
;;;; This module assigns wlroots input devices to compositor-owned logical
;;;; seats, routes pointer hits from presentation snapshots, and owns move and
;;;; resize grabs. It never duplicates rendering geometry.

(in-package #:ataxia.compositor)

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
   (pointer-constraints :initform nil :accessor interaction-pointer-constraints)
   (active-pointer-constraints :initform (make-hash-table :test #'eq)
                               :reader interaction-active-pointer-constraints)
   (default-seat :initform nil :accessor interaction-default-seat))
  (:documentation
   "Owns interaction system subsystem state. Attach and detach it on the owner thread, and keep its tables synchronized with object lifecycle events."))

(defclass logical-seat ()
  ((name :initarg :name :reader seat-name)
   (native :initarg :native :reader seat-native)
   (devices :initform nil :accessor seat-devices)
   (keyboards :initform nil :accessor seat-keyboards)
   (active-keyboard :initform nil :accessor seat-active-keyboard)
   (depressed-modifiers :initform 0
                        :accessor seat-depressed-modifiers)
   (latched-modifiers :initform 0
                      :accessor seat-latched-modifiers)
   (locked-modifiers :initform 0
                     :accessor seat-locked-modifiers)
   (layout-group :initform 0 :accessor seat-layout-group)
   (pointer-x :initarg :pointer-x :initform 160d0 :accessor seat-pointer-x)
   (pointer-y :initarg :pointer-y :initform 100d0 :accessor seat-pointer-y)
   (pointer-output :initform nil :accessor seat-pointer-output)
   (pointer-focus-surface :initform nil :accessor seat-pointer-focus-surface)
   (pointer-focus-view :initform nil :accessor seat-pointer-focus-view)
   (pointer-surface-x :initform 0d0 :accessor seat-pointer-surface-x)
   (pointer-surface-y :initform 0d0 :accessor seat-pointer-surface-y)
   (focused-view :initform nil :accessor seat-focused-view)
   (cursor-record :initform nil :accessor seat-cursor-record)
   (cursor-mode :initform :default :accessor seat-cursor-mode)
   (cursor-hotspot-x :initform 0d0 :accessor seat-cursor-hotspot-x)
   (cursor-hotspot-y :initform 0d0 :accessor seat-cursor-hotspot-y)
   (pressed-buttons :initform (make-hash-table :test #'eql)
                    :reader seat-pressed-buttons)
   (operation :initform nil :accessor seat-operation))
  (:documentation
   "Represents compositor logical seat. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defgeneric create-logical-seat
    (interaction name &key pointer-x pointer-y)
  (:documentation
   "Implement CREATE-LOGICAL-SEAT for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric destroy-logical-seat (interaction seat)
  (:documentation
   "Implement DESTROY-LOGICAL-SEAT idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."))
(defgeneric interaction-add-input-device
    (interaction device &optional seat)
  (:documentation
   "Implement INTERACTION-ADD-INPUT-DEVICE for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-remove-input-device (interaction device)
  (:documentation
   "Implement INTERACTION-REMOVE-INPUT-DEVICE for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric assign-input-device (interaction device seat)
  (:documentation
   "Implement ASSIGN-INPUT-DEVICE for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric unassign-input-device (interaction device)
  (:documentation
   "Implement UNASSIGN-INPUT-DEVICE for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric focus-view (interaction seat view)
  (:documentation
   "Implement FOCUS-VIEW for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric begin-interactive-operation
    (interaction seat view kind edges &key button)
  (:documentation
   "Implement BEGIN-INTERACTIVE-OPERATION for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric begin-interactive-move
    (interaction seat view &key serial button)
  (:documentation
   "Implement BEGIN-INTERACTIVE-MOVE for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric begin-interactive-resize
    (interaction seat view edges &key serial button)
  (:documentation
   "Implement BEGIN-INTERACTIVE-RESIZE for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric cancel-interactive-operation (interaction seat)
  (:documentation
   "Implement CANCEL-INTERACTIVE-OPERATION for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric update-interactive-operation (interaction seat)
  (:documentation
   "Implement UPDATE-INTERACTIVE-OPERATION for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric interaction-handle-pointer-motion (interaction event)
  (:documentation
   "Implement INTERACTION-HANDLE-POINTER-MOTION for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-pointer-motion-absolute (interaction event)
  (:documentation
   "Implement INTERACTION-HANDLE-POINTER-MOTION-ABSOLUTE for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-pointer-button (interaction event)
  (:documentation
   "Implement INTERACTION-HANDLE-POINTER-BUTTON for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-pointer-axis (interaction event)
  (:documentation
   "Implement INTERACTION-HANDLE-POINTER-AXIS for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-pointer-frame (interaction pointer)
  (:documentation
   "Implement INTERACTION-HANDLE-POINTER-FRAME for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-keyboard-key (interaction event)
  (:documentation
   "Implement INTERACTION-HANDLE-KEYBOARD-KEY for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-keyboard-modifiers (interaction event)
  (:documentation
   "Implement INTERACTION-HANDLE-KEYBOARD-MODIFIERS for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))
(defgeneric interaction-handle-cursor-request (interaction request)
  (:documentation
   "Implement INTERACTION-HANDLE-CURSOR-REQUEST for implementations. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."))

(defmethod detach-component :before
    ((interaction interaction-system) reason)
  "Prepare or validate DETACH-COMPONENT before primary dispatch. Do not consume ownership or perform the primary operation early."
  (declare (ignore reason))
  (let ((constraints
          (loop for constraint being the hash-values
                  of (interaction-active-pointer-constraints interaction)
                collect constraint)))
    (clrhash (interaction-active-pointer-constraints interaction))
    (dolist (constraint constraints)
      (when (ataxia.runtime:native-object-live-p constraint)
        (ataxia.runtime:pointer-constraint-send-deactivated constraint))))
  (setf (interaction-pointer-constraints interaction) nil))

(defun seat-pointer-local-position (seat &optional (output (seat-pointer-output seat)))
  (when output
    (output-local-position output (seat-pointer-x seat) (seat-pointer-y seat))))

(defun seat-cursor-damage-box
    (seat output pointer-x pointer-y)
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

(defun schedule-seat-cursor-damage
    (interaction seat old-output old-box)
  (let* ((presentation
           (compositor-presentation (component-compositor interaction)))
         (new-output (seat-pointer-output seat))
         (new-box
           (seat-cursor-damage-box
            seat new-output (seat-pointer-x seat) (seat-pointer-y seat))))
    (dolist (output (remove-duplicates
                     (remove nil (list old-output new-output)) :test #'eq))
      (let ((boxes
              (remove nil
                      (list (and (eq output old-output) old-box)
                            (and (eq output new-output) new-box)))))
        (when boxes
          (schedule-presentation presentation output boxes)))))
  seat)

(defun interaction-owns-seat-p (interaction seat)
  (member seat (interaction-seats interaction) :test #'eq))

(defun interaction-owns-view-p (interaction view)
  (member view
          (desktop-views
           (compositor-desktop (component-compositor interaction)))
          :test #'eq))

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

(defmethod create-logical-seat
    ((interaction interaction-system) name
     &key (pointer-x 160d0) (pointer-y 100d0))
  "Implement CREATE-LOGICAL-SEAT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (check-type interaction interaction-system)
  (when (find name (interaction-seats interaction)
              :key #'seat-name :test #'string=)
    (error 'invalid-compositor-state
           :operation :create-logical-seat :state :duplicate-name))
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
    (clamp-seat-pointer interaction seat)
    (update-seat-capabilities seat)
    seat))

(defmethod destroy-logical-seat
    ((interaction interaction-system) (seat logical-seat))
  "Implement DESTROY-LOGICAL-SEAT idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (check-type interaction interaction-system)
  (check-type seat logical-seat)
  (unless (interaction-owns-seat-p interaction seat)
    (error 'invalid-compositor-state
           :operation :destroy-logical-seat :state :foreign-seat))
  (cancel-interactive-operation interaction seat)
  (let ((devices nil))
    (maphash
     (lambda (device assigned-seat)
       (when (eq seat assigned-seat)
         (push device devices)))
     (interaction-device-seats interaction))
    (dolist (device devices)
      (remhash device (interaction-device-seats interaction))))
  (let ((focused-view (seat-focused-view seat)))
    (setf (interaction-seats interaction)
          (delete seat (interaction-seats interaction) :test #'eq))
    (when (and focused-view
               (not (find focused-view (interaction-seats interaction)
                          :key #'seat-focused-view :test #'eq)))
      (ataxia.runtime:xdg-toplevel-set-activated
       (view-native focused-view) nil)))
  (when (eq seat (interaction-default-seat interaction))
    (setf (interaction-default-seat interaction)
          (first (interaction-seats interaction))))
  (ataxia.runtime:destroy-seat (seat-native seat))
  nil)

(defmethod detach-component :before
    ((interaction interaction-system) reason)
  "Prepare or validate DETACH-COMPONENT before primary dispatch. Do not consume ownership or perform the primary operation early."
  (declare (ignore reason))
  (dolist (seat (copy-list (interaction-seats interaction)))
    (destroy-logical-seat interaction seat))
  (clrhash (interaction-device-seats interaction)))

(defun interaction-seat-for-native (interaction native-seat)
  (find native-seat (interaction-seats interaction)
        :key #'seat-native :test #'eq))

(defun interaction-seat-for-device (interaction device)
  (gethash device (interaction-device-seats interaction)))

(defun synchronize-seat-keyboard (seat)
  (let ((keyboard (seat-active-keyboard seat)))
    (if keyboard
        (progn
          (ataxia.runtime:set-seat-keyboard (seat-native seat) keyboard)
          (when (seat-focused-view seat)
            (ataxia.runtime:seat-keyboard-notify-enter
             (seat-native seat)
             (surface-record-native
              (view-surface (seat-focused-view seat)))
             keyboard)))
        (progn
          (ataxia.runtime:seat-keyboard-notify-clear-focus
           (seat-native seat))
          (ataxia.runtime:clear-seat-keyboard (seat-native seat)))))
  seat)

(defmethod interaction-add-input-device
    ((interaction interaction-system) device &optional seat)
  "Implement INTERACTION-ADD-INPUT-DEVICE for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let ((current (interaction-seat-for-device interaction device))
        (target (or seat (interaction-default-seat interaction))))
    (unless target
      (setf target (create-logical-seat interaction "seat0")))
    (when (eq current target)
      (return-from interaction-add-input-device target))
    (when current
      (interaction-remove-input-device interaction device))
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
      (synchronize-seat-keyboard target))
    (update-seat-capabilities target)
    target))

(defmethod interaction-remove-input-device
    ((interaction interaction-system) device)
  "Implement INTERACTION-REMOVE-INPUT-DEVICE for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let ((seat (interaction-seat-for-device interaction device)))
    (when seat
      (let ((active-keyboard-p (eq device (seat-active-keyboard seat))))
        (remhash device (interaction-device-seats interaction))
        (setf (seat-devices seat)
              (delete device (seat-devices seat) :test #'eq)
              (seat-keyboards seat)
              (delete device (seat-keyboards seat) :test #'eq))
        (when active-keyboard-p
          (setf (seat-active-keyboard seat) (first (seat-keyboards seat)))
          (synchronize-seat-keyboard seat))
        (update-seat-capabilities seat)))
    seat))

(defmethod assign-input-device
    ((interaction interaction-system) device (seat logical-seat))
  "Move a live wlroots device between logical seats without native recreation."
  (check-type interaction interaction-system)
  (check-type device ataxia.runtime:wlr-input-device)
  (check-type seat logical-seat)
  (unless (and (interaction-owns-seat-p interaction seat)
               (member device
                       (ataxia.runtime:runtime-input-devices
                        (compositor-runtime
                         (component-compositor interaction)))
                       :test #'eq))
    (error 'invalid-compositor-state
           :operation :assign-input-device :state :foreign-object))
  (interaction-add-input-device interaction device seat))

(defmethod unassign-input-device
    ((interaction interaction-system) device)
  "Implement UNASSIGN-INPUT-DEVICE for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (check-type interaction interaction-system)
  (check-type device ataxia.runtime:wlr-input-device)
  (interaction-remove-input-device interaction device))

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
  (let* ((outputs (compositor-outputs (component-compositor interaction)))
         (output (output-at-layout-position outputs x y)))
    (when output
      (multiple-value-bind (local-x local-y)
          (output-local-position output x y)
        (values
         (presentation-hit-test
          (current-input-snapshot interaction output) local-x local-y)
         output)))))

(defun clamp-seat-pointer (interaction seat)
  (multiple-value-bind (output x y)
      (confine-layout-position
       (compositor-outputs (component-compositor interaction))
       (seat-pointer-x seat) (seat-pointer-y seat))
    (setf (seat-pointer-output seat) output)
    (when output
      (setf (seat-pointer-x seat) x
            (seat-pointer-y seat) y)))
  seat)

(defun update-pointer-focus (interaction seat time-msec)
  (multiple-value-bind (hit output)
      (interaction-hit-test interaction
                            (seat-pointer-x seat) (seat-pointer-y seat))
    (setf (seat-pointer-output seat) output)
    (let ((surface (and hit (presentation-hit-surface hit))))
      (cond
        (surface
         (unless (eq surface (seat-pointer-focus-surface seat))
           ;; A cursor shape belongs to the focused client surface. Reset it
           ;; until the newly entered client supplies its own shape.
           (setf (seat-cursor-record seat) nil
                 (seat-cursor-mode seat) :default))
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
               (seat-cursor-record seat) nil
               (seat-cursor-mode seat) :default)))
      (synchronize-seat-pointer-constraint interaction seat)
      hit)))

(defun constraint-logical-seat (interaction constraint)
  (find (ataxia.runtime:pointer-constraint-seat constraint)
        (interaction-seats interaction) :key #'seat-native :test #'eq))

(defun matching-seat-pointer-constraint (interaction seat)
  (unless (seat-operation seat)
    (find-if
     (lambda (constraint)
       (and (ataxia.runtime:native-object-live-p constraint)
            (eq (seat-native seat)
                (ataxia.runtime:pointer-constraint-seat constraint))
            (eq (seat-pointer-focus-surface seat)
                (ataxia.runtime:pointer-constraint-surface constraint))))
     (interaction-pointer-constraints interaction))))

(defun synchronize-seat-pointer-constraint (interaction seat)
  (let* ((active-table (interaction-active-pointer-constraints interaction))
         (current (gethash seat active-table))
         (desired (matching-seat-pointer-constraint interaction seat)))
    (unless (eq current desired)
      (when current
        (remhash seat active-table)
        (when (ataxia.runtime:native-object-live-p current)
          (ataxia.runtime:pointer-constraint-send-deactivated current)))
      (when (and desired (ataxia.runtime:native-object-live-p desired)
                 (null (gethash seat active-table)))
        (setf (gethash seat active-table) desired)
        (ataxia.runtime:pointer-constraint-send-activated desired))))
  (gethash seat (interaction-active-pointer-constraints interaction)))

(defun interaction-add-pointer-constraint (interaction constraint)
  (pushnew constraint (interaction-pointer-constraints interaction) :test #'eq)
  (let ((seat (constraint-logical-seat interaction constraint)))
    (when seat
      (synchronize-seat-pointer-constraint interaction seat)))
  constraint)

(defun pointer-constraint-presentation-item (interaction constraint)
  (loop for output in
          (compositor-outputs-list
           (compositor-outputs (component-compositor interaction)))
        for item =
          (presentation-item-for-surface
           output (ataxia.runtime:pointer-constraint-surface constraint))
        when item return (values item output)))

(defun apply-pointer-constraint-cursor-hint
    (interaction seat constraint)
  (multiple-value-bind (hint-p surface-x surface-y)
      (ataxia.runtime:pointer-constraint-cursor-hint constraint)
    (when hint-p
      (multiple-value-bind (item output)
          (pointer-constraint-presentation-item interaction constraint)
        (when item
          (multiple-value-bind (mapped-p output-x output-y)
              (presentation-item-output-point item surface-x surface-y)
            (when mapped-p
              (let* ((old-output (seat-pointer-output seat))
                     (old-box
                       (seat-cursor-damage-box
                        seat old-output
                        (seat-pointer-x seat) (seat-pointer-y seat))))
                (setf (seat-pointer-x seat) (+ (output-layout-x output) output-x)
                      (seat-pointer-y seat) (+ (output-layout-y output) output-y))
                (clamp-seat-pointer interaction seat)
                (update-pointer-focus
                 interaction seat
                 (mod (floor (* (monotonic-seconds) 1000d0)) #x100000000))
                (schedule-seat-cursor-damage
                 interaction seat old-output old-box)))))))))

(defun interaction-remove-pointer-constraint (interaction constraint)
  (let ((seat (constraint-logical-seat interaction constraint)))
    (let ((active-p
            (and seat
                 (eq constraint
                     (gethash seat
                              (interaction-active-pointer-constraints
                               interaction))))))
      (when active-p
        (remhash seat (interaction-active-pointer-constraints interaction)))
      (setf (interaction-pointer-constraints interaction)
            (delete constraint (interaction-pointer-constraints interaction)
                    :test #'eq))
      (when active-p
        (apply-pointer-constraint-cursor-hint
         interaction seat constraint)))
    (when seat
      (synchronize-seat-pointer-constraint interaction seat)))
  constraint)

(defun presentation-item-for-surface (output surface)
  (let ((snapshot (and output (output-last-snapshot output))))
    (and snapshot
         (find surface (snapshot-items snapshot)
               :key #'presentation-item-surface :test #'eq :from-end t))))

(defun estimate-presentation-local-point
    (item old-output-x old-output-y candidate-output-x candidate-output-y
     old-surface-x old-surface-y)
  (multiple-value-bind (mapped-p local-x local-y)
      (presentation-item-local-point item candidate-output-x candidate-output-y)
    (if mapped-p
        (values local-x local-y)
        (values
         (+ old-surface-x
            (* (- candidate-output-x old-output-x)
               (/ (presentation-item-source-width item)
                  (max 1d0 (presentation-item-width item)))))
         (+ old-surface-y
            (* (- candidate-output-y old-output-y)
               (/ (presentation-item-source-height item)
                  (max 1d0 (presentation-item-height item)))))))))

(defun confine-presentation-local-point
    (constraint item old-x old-y candidate-x candidate-y)
  (if (ataxia.runtime:pointer-constraint-region-empty-p constraint)
      (values
       t
       (max 0d0 (min (- (presentation-item-source-width item) 1d-6)
                       candidate-x))
       (max 0d0 (min (- (presentation-item-source-height item) 1d-6)
                       candidate-y)))
      (ataxia.runtime:pointer-constraint-confine
       constraint old-x old-y candidate-x candidate-y)))

(defun constrain-seat-pointer-position
    (interaction seat candidate-x candidate-y)
  (let ((constraint
          (gethash seat
                   (interaction-active-pointer-constraints interaction))))
    (cond
      ((or (null constraint)
           (not (ataxia.runtime:native-object-live-p constraint)))
       (values candidate-x candidate-y))
      ((eq :locked (ataxia.runtime:pointer-constraint-type constraint))
       (values (seat-pointer-x seat) (seat-pointer-y seat)))
      (t
       (let* ((output (seat-pointer-output seat))
              (item
                (presentation-item-for-surface
                 output (ataxia.runtime:pointer-constraint-surface constraint))))
         (if (null item)
             (values (seat-pointer-x seat) (seat-pointer-y seat))
             (multiple-value-bind (old-output-x old-output-y)
                 (seat-pointer-local-position seat output)
               (multiple-value-bind (candidate-output-x candidate-output-y)
                   (output-local-position output candidate-x candidate-y)
                 (multiple-value-bind (local-x local-y)
                     (estimate-presentation-local-point
                      item old-output-x old-output-y
                      candidate-output-x candidate-output-y
                      (seat-pointer-surface-x seat)
                      (seat-pointer-surface-y seat))
                   (multiple-value-bind (confined-p confined-x confined-y)
                       (confine-presentation-local-point
                        constraint item
                        (seat-pointer-surface-x seat)
                        (seat-pointer-surface-y seat)
                        local-x local-y)
                     (if confined-p
                         (multiple-value-bind (projected-p output-x output-y)
                             (presentation-item-output-point
                              item confined-x confined-y)
                           (if projected-p
                               (values (+ (output-layout-x output) output-x)
                                       (+ (output-layout-y output) output-y))
                               (values (seat-pointer-x seat)
                                       (seat-pointer-y seat))))
                         (values (seat-pointer-x seat)
                                 (seat-pointer-y seat)))))))))))))

(defun send-relative-pointer-event (interaction seat event)
  (let ((manager
          (ataxia.runtime:runtime-relative-pointer-manager
           (compositor-runtime (component-compositor interaction)))))
    (when manager
      (ataxia.runtime:relative-pointer-send-motion
       manager (seat-native seat)
       (* 1000 (ataxia.runtime:pointer-motion-time-msec event))
       (ataxia.runtime:pointer-motion-delta-x event)
       (ataxia.runtime:pointer-motion-delta-y event)
       (ataxia.runtime:pointer-motion-unaccelerated-delta-x event)
       (ataxia.runtime:pointer-motion-unaccelerated-delta-y event)))))

(defmethod focus-view
    ((interaction interaction-system) (seat logical-seat) view)
  "Implement FOCUS-VIEW for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (check-type interaction interaction-system)
  (check-type seat logical-seat)
  (unless (and (interaction-owns-seat-p interaction seat)
               (or (null view) (interaction-owns-view-p interaction view)))
    (error 'invalid-compositor-state
           :operation :focus-view :state :foreign-object))
  (when (and view (not (view-mapped-p view)))
    (return-from focus-view nil))
  (let ((previous (seat-focused-view seat)))
    (unless (eq previous view)
      (setf (seat-focused-view seat) view)
      ;; XDG activation is per toplevel, while keyboard focus is per seat.
      ;; Keep a view active until the final logical seat leaves it.
      (when (and previous
                 (not (find previous (interaction-seats interaction)
                            :key #'seat-focused-view :test #'eq)))
        (ataxia.runtime:xdg-toplevel-set-activated
         (view-native previous) nil))
      (behavior-focus-changed
       (compositor-behavior-policy
        (component-compositor interaction))
       seat previous view)
      (if view
          (progn
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

(defun interaction-hook-context (interaction view descriptor phase)
  (declare (ignore interaction))
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

(defun pressed-operation-button (seat)
  ;; Prefer the conventional primary button when several buttons are held.
  (if (gethash +button-left+ (seat-pressed-buttons seat))
      +button-left+
      (loop for button being the hash-keys of (seat-pressed-buttons seat)
            return button)))

(defmethod begin-interactive-operation
    ((interaction interaction-system) (seat logical-seat) (view view)
     kind edges &key button)
  "Implement BEGIN-INTERACTIVE-OPERATION for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (unless (and (interaction-owns-seat-p interaction seat)
               (interaction-owns-view-p interaction view))
    (error 'invalid-compositor-state
           :operation :begin-interactive-operation
           :state :foreign-object))
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
          (behavior-begin-operation
           (compositor-behavior-policy
            (component-compositor interaction))
           interaction seat view kind edges
           (or button (pressed-operation-button seat))))
    (when (eq kind :resize)
      (ataxia.runtime:xdg-toplevel-set-resizing (view-native view) t))
    (focus-view interaction seat view)
    (synchronize-seat-pointer-constraint interaction seat)
    (start-interaction-animation interaction view nil kind)
    (run-hook hooks 'after-interactive-operation
              (interaction-hook-context interaction view descriptor :after))
    (seat-operation seat)))

(defmethod begin-interactive-move
    ((interaction interaction-system) (seat logical-seat) (view view)
     &key serial button)
  "Implement BEGIN-INTERACTIVE-MOVE for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (when (and serial
             (not (and (seat-pointer-focus-surface seat)
                       (ataxia.runtime:seat-validate-pointer-grab-serial
                        (seat-native seat)
                        (seat-pointer-focus-surface seat) serial))))
    (return-from begin-interactive-move nil))
  (begin-interactive-operation
   interaction seat view :move 0 :button button))

(defmethod begin-interactive-resize
    ((interaction interaction-system) (seat logical-seat) (view view) edges
     &key serial button)
  "Implement BEGIN-INTERACTIVE-RESIZE for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (when (zerop edges)
    (return-from begin-interactive-resize nil))
  (when (and serial
             (not (and (seat-pointer-focus-surface seat)
                       (ataxia.runtime:seat-validate-pointer-grab-serial
                        (seat-native seat)
                        (seat-pointer-focus-surface seat) serial))))
    (return-from begin-interactive-resize nil))
  (begin-interactive-operation
   interaction seat view :resize edges :button button))

(defmethod cancel-interactive-operation
    ((interaction interaction-system) (seat logical-seat))
  "Implement CANCEL-INTERACTIVE-OPERATION for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (let ((operation (seat-operation seat)))
    (when operation
      (let ((view (interactive-operation-view operation)))
        (when (eq :resize (interactive-operation-kind operation))
          (ataxia.runtime:xdg-toplevel-set-resizing (view-native view) nil))
        (setf (seat-operation seat) nil)
        (synchronize-seat-pointer-constraint interaction seat)
        (start-interaction-animation
         interaction view (interactive-operation-kind operation) nil)
        (schedule-presentation-subject
         (compositor-presentation (component-compositor interaction)) view)))
    operation))

(defmethod update-interactive-operation
    ((interaction interaction-system) (seat logical-seat))
  "Implement UPDATE-INTERACTIVE-OPERATION for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (let ((operation (seat-operation seat)))
    (when operation
      (let ((decision
              (behavior-update-operation
               (compositor-behavior-policy
                (component-compositor interaction))
               interaction operation)))
        (when (typep decision 'view-configuration-decision)
          (apply-view-configuration-decision
           (interactive-operation-view operation) decision)))
      (schedule-presentation-subject
       (compositor-presentation (component-compositor interaction))
       (interactive-operation-view operation)))
    operation))

(defmethod interaction-handle-pointer-motion
    ((interaction interaction-system) event)
  "Implement INTERACTION-HANDLE-POINTER-MOTION for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let ((seat
          (interaction-seat-for-device
           interaction (ataxia.runtime:pointer-motion-pointer event))))
    (when seat
      (send-relative-pointer-event interaction seat event)
      (let* ((old-output (seat-pointer-output seat))
             (old-box
               (seat-cursor-damage-box
                seat old-output (seat-pointer-x seat) (seat-pointer-y seat))))
        (trace-input "[input] relative ~,2F ~,2F~%"
                     (ataxia.runtime:pointer-motion-delta-x event)
                     (ataxia.runtime:pointer-motion-delta-y event))
        (multiple-value-bind (x y)
            (constrain-seat-pointer-position
             interaction seat
             (+ (seat-pointer-x seat)
                (ataxia.runtime:pointer-motion-delta-x event))
             (+ (seat-pointer-y seat)
                (ataxia.runtime:pointer-motion-delta-y event)))
          (setf (seat-pointer-x seat) x
                (seat-pointer-y seat) y))
        (clamp-seat-pointer interaction seat)
        (if (seat-operation seat)
            (update-interactive-operation interaction seat)
            (progn
              (update-pointer-focus
               interaction seat (ataxia.runtime:pointer-motion-time-msec event))
              (schedule-seat-cursor-damage
               interaction seat old-output old-box)))))
    seat))

(defmethod interaction-handle-pointer-motion-absolute
    ((interaction interaction-system) event)
  "Implement INTERACTION-HANDLE-POINTER-MOTION-ABSOLUTE for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let* ((seat
           (interaction-seat-for-device
            interaction
            (ataxia.runtime:pointer-motion-absolute-pointer event)))
         (outputs (compositor-outputs (component-compositor interaction))))
    (when seat
      (let* ((old-output (seat-pointer-output seat))
             (old-box
               (seat-cursor-damage-box
                seat old-output (seat-pointer-x seat) (seat-pointer-y seat))))
        (trace-input "[input] absolute ~,3F ~,3F~%"
                     (ataxia.runtime:pointer-motion-absolute-x event)
                     (ataxia.runtime:pointer-motion-absolute-y event))
        (multiple-value-bind (minimum-x minimum-y maximum-x maximum-y)
            (output-layout-bounds outputs)
          (when minimum-x
            (multiple-value-bind (x y)
                (constrain-seat-pointer-position
                 interaction seat
                 (+ minimum-x
                    (* (ataxia.runtime:pointer-motion-absolute-x event)
                       (- maximum-x minimum-x)))
                 (+ minimum-y
                    (* (ataxia.runtime:pointer-motion-absolute-y event)
                       (- maximum-y minimum-y))))
              (setf (seat-pointer-x seat) x
                    (seat-pointer-y seat) y))))
        (clamp-seat-pointer interaction seat)
        (if (seat-operation seat)
            (update-interactive-operation interaction seat)
            (progn
              (update-pointer-focus
               interaction seat
               (ataxia.runtime:pointer-motion-absolute-time-msec event))
              (schedule-seat-cursor-damage
               interaction seat old-output old-box)))))
    seat))

(defmethod interaction-handle-pointer-button
    ((interaction interaction-system) event)
  "Implement INTERACTION-HANDLE-POINTER-BUTTON for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
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
             (decision
               (behavior-handle-pointer-button
                (compositor-behavior-policy
                 (component-compositor interaction))
                interaction seat hit button state time)))
        (if (eq state :pressed)
            (setf (gethash button (seat-pressed-buttons seat)) t)
            (remhash button (seat-pressed-buttons seat)))
        (let ((view (pointer-decision-focus-target decision)))
          (when view
            (focus-view interaction seat view))
          (case (pointer-decision-operation-kind decision)
            (:move
             (begin-interactive-move
              interaction seat view :button button))
            (:resize
             (begin-interactive-resize
              interaction seat view
              (pointer-decision-resize-edges decision)
              :button button))))
        (when (and (pointer-decision-deliver-p decision)
                   (seat-pointer-focus-surface seat))
          (ataxia.runtime:seat-pointer-notify-button
           (seat-native seat) time button state))
        (when (and (eq state :released) operation
                   (eql button (interactive-operation-button operation)))
          (cancel-interactive-operation interaction seat))
        (schedule-presentation
         (compositor-presentation (component-compositor interaction))))
      seat)))

(defmethod interaction-handle-pointer-axis
    ((interaction interaction-system) event)
  "Implement INTERACTION-HANDLE-POINTER-AXIS for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let ((seat
          (interaction-seat-for-device
           interaction (ataxia.runtime:pointer-axis-pointer event))))
    (when seat
      (let* ((input
               (make-instance
                'pointer-axis-input
                :time (ataxia.runtime:pointer-axis-time-msec event)
                :orientation (ataxia.runtime:pointer-axis-orientation event)
                :delta (ataxia.runtime:pointer-axis-delta event)
                :discrete-delta
                (ataxia.runtime:pointer-axis-discrete-delta event)
                :source (ataxia.runtime:pointer-axis-source event)
                :relative-direction
                (ataxia.runtime:pointer-axis-relative-direction event)))
             (decision
               (behavior-handle-pointer-axis
                (compositor-behavior-policy
                 (component-compositor interaction))
                interaction seat input)))
        (check-type decision pointer-axis-decision)
        (when (pointer-axis-decision-deliver-p decision)
          (ataxia.runtime:seat-pointer-notify-axis
           (seat-native seat)
           (pointer-axis-input-time input)
           (pointer-axis-input-orientation input)
           (pointer-axis-input-delta input)
           (pointer-axis-input-discrete-delta input)
           (pointer-axis-input-source input)
           (pointer-axis-input-relative-direction input)))))
    seat))

(defmethod interaction-handle-pointer-frame
    ((interaction interaction-system) pointer)
  "Implement INTERACTION-HANDLE-POINTER-FRAME for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let ((seat (interaction-seat-for-device interaction pointer)))
    (when seat
      (ataxia.runtime:seat-pointer-notify-frame (seat-native seat)))
    seat))

(defmethod interaction-handle-keyboard-key
    ((interaction interaction-system) event)
  "Implement INTERACTION-HANDLE-KEYBOARD-KEY for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let* ((keyboard (ataxia.runtime:keyboard-key-keyboard event))
         (seat (interaction-seat-for-device interaction keyboard)))
    (when seat
      (trace-input "[input] key ~D ~A~%"
                   (ataxia.runtime:keyboard-key-keycode event)
                   (ataxia.runtime:keyboard-key-state event))
      (setf (seat-active-keyboard seat) keyboard)
      (ataxia.runtime:set-seat-keyboard (seat-native seat) keyboard)
      (let* ((input
               (make-instance
                'keyboard-key-input
                :time (ataxia.runtime:keyboard-key-time-msec event)
                :keycode (ataxia.runtime:keyboard-key-keycode event)
                :state (ataxia.runtime:keyboard-key-state event)
                :depressed-modifiers (seat-depressed-modifiers seat)
                :latched-modifiers (seat-latched-modifiers seat)
                :locked-modifiers (seat-locked-modifiers seat)
                :layout-group (seat-layout-group seat)))
             (decision
               (behavior-handle-keyboard-key
                (compositor-behavior-policy
                 (component-compositor interaction))
                interaction seat input)))
        (check-type decision keyboard-key-decision)
        (when (keyboard-decision-deliver-p decision)
          (ataxia.runtime:seat-keyboard-notify-key
           (seat-native seat)
           (keyboard-input-time input)
           (keyboard-input-keycode input)
           (keyboard-input-state input)))))
    seat))

(defmethod interaction-handle-keyboard-modifiers
    ((interaction interaction-system) event)
  "Implement INTERACTION-HANDLE-KEYBOARD-MODIFIERS for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
  (let* ((keyboard (ataxia.runtime:keyboard-modifiers-keyboard event))
         (seat (interaction-seat-for-device interaction keyboard)))
    (when seat
      (setf (seat-active-keyboard seat) keyboard
            (seat-depressed-modifiers seat)
            (ataxia.runtime:keyboard-modifiers-depressed event)
            (seat-latched-modifiers seat)
            (ataxia.runtime:keyboard-modifiers-latched event)
            (seat-locked-modifiers seat)
            (ataxia.runtime:keyboard-modifiers-locked event)
            (seat-layout-group seat)
            (ataxia.runtime:keyboard-modifiers-group event))
      (ataxia.runtime:set-seat-keyboard (seat-native seat) keyboard)
      (ataxia.runtime:seat-keyboard-notify-modifiers
       (seat-native seat) keyboard))
    seat))

(defmethod interaction-handle-cursor-request
    ((interaction interaction-system) request)
  "Implement INTERACTION-HANDLE-CURSOR-REQUEST for this specialization. Preserve seat focus and grab invariants, and forward each protocol input event no more than once."
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
      (let* ((old-output (seat-pointer-output seat))
             (old-box
               (seat-cursor-damage-box
                seat old-output (seat-pointer-x seat) (seat-pointer-y seat))))
        (setf (seat-cursor-record seat)
              (and surface
                   (ensure-surface-record
                    (compositor-surfaces (component-compositor interaction))
                    surface))
              (seat-cursor-mode seat) (if surface :surface :hidden)
              (seat-cursor-hotspot-x seat)
              (coerce (ataxia.runtime:seat-cursor-request-hotspot-x request)
                      'double-float)
              (seat-cursor-hotspot-y seat)
              (coerce (ataxia.runtime:seat-cursor-request-hotspot-y request)
                      'double-float))
        (schedule-seat-cursor-damage interaction seat old-output old-box)))
    seat))
