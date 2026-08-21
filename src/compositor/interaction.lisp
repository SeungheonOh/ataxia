;;;; Logical seats and interactive operations.
;;;;
;;;; This module assigns wlroots input devices to compositor-owned logical
;;;; seats and forwards protocol input events through behavior policy.

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
   (default-seat :initform nil :accessor interaction-default-seat)))

(defclass logical-seat ()
  ((interaction :initarg :interaction :reader seat-interaction)
   (name :initarg :name :reader seat-name)
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
                    :reader seat-pressed-buttons)))

(defgeneric create-logical-seat
    (interaction name &key pointer-x pointer-y))
(defgeneric destroy-logical-seat (interaction seat))
(defgeneric interaction-add-input-device
    (interaction device &optional seat))
(defgeneric interaction-remove-input-device (interaction device))
(defgeneric assign-input-device (interaction device seat))
(defgeneric unassign-input-device (interaction device))
(defgeneric focus-view (interaction seat view))
(defgeneric interaction-handle-pointer-motion (interaction event))
(defgeneric interaction-handle-pointer-motion-absolute (interaction event))
(defgeneric interaction-handle-pointer-button (interaction event))
(defgeneric interaction-handle-pointer-axis (interaction event))
(defgeneric interaction-handle-pointer-frame (interaction pointer))
(defgeneric interaction-handle-keyboard-key (interaction event))
(defgeneric interaction-handle-keyboard-modifiers (interaction event))
(defgeneric interaction-handle-cursor-request (interaction request))

(defmethod detach-component :before
    ((interaction interaction-system) reason)
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
  (check-type interaction interaction-system)
  (when (find name (interaction-seats interaction)
              :key #'seat-name :test #'string=)
    (error 'invalid-compositor-state
           :operation :create-logical-seat :state :duplicate-name))
  (let* ((compositor (component-compositor interaction))
         (seat
           (make-instance
            'logical-seat :interaction interaction :name name
            :native (ataxia.runtime:create-seat
                     (compositor-runtime compositor) name))))
    (push seat (interaction-seats interaction))
    (unless (interaction-default-seat interaction)
      (setf (interaction-default-seat interaction) seat))
    (behavior-seat-created
     (compositor-behavior-policy compositor) interaction seat
     (coerce pointer-x 'double-float) (coerce pointer-y 'double-float))
    (update-seat-capabilities seat)
    seat))

(defmethod destroy-logical-seat
    ((interaction interaction-system) (seat logical-seat))
  (check-type interaction interaction-system)
  (check-type seat logical-seat)
  (unless (interaction-owns-seat-p interaction seat)
    (error 'invalid-compositor-state
           :operation :destroy-logical-seat :state :foreign-seat))
  (behavior-seat-destroying
   (compositor-behavior-policy (component-compositor interaction))
   interaction seat)
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

(defun update-pointer-focus-at
    (interaction seat pointer-x pointer-y time-msec)
  (multiple-value-bind (hit output)
      (interaction-hit-test interaction pointer-x pointer-y)
    (declare (ignore output))
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
  (unless (behavior-operation
           (compositor-behavior-policy (component-compositor interaction))
           seat)
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
              (behavior-warp-cursor
               (compositor-behavior-policy
                (component-compositor interaction))
               interaction seat
               (+ (output-layout-x output) output-x)
               (+ (output-layout-y output) output-y)
               (mod (floor (* (monotonic-seconds) 1000d0))
                    #x100000000)))))))))

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
    (interaction seat old-x old-y old-output candidate-x candidate-y)
  (let ((constraint
          (gethash seat
                   (interaction-active-pointer-constraints interaction))))
    (cond
      ((or (null constraint)
           (not (ataxia.runtime:native-object-live-p constraint)))
       (values candidate-x candidate-y))
      ((eq :locked (ataxia.runtime:pointer-constraint-type constraint))
       (values old-x old-y))
      (t
       (let* ((output old-output)
              (item
                (presentation-item-for-surface
                 output (ataxia.runtime:pointer-constraint-surface constraint))))
         (if (null item)
             (values old-x old-y)
             (multiple-value-bind (old-output-x old-output-y)
                 (output-local-position output old-x old-y)
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
                               (values old-x old-y)))
                         (values old-x old-y))))))))))))

(defun interaction-pointer-grab-serial-valid-p (seat serial)
  (and (seat-pointer-focus-surface seat)
       (ataxia.runtime:seat-validate-pointer-grab-serial
        (seat-native seat) (seat-pointer-focus-surface seat) serial)))

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

(defmethod interaction-handle-pointer-motion
    ((interaction interaction-system) event)
  (let ((seat
          (interaction-seat-for-device
           interaction (ataxia.runtime:pointer-motion-pointer event))))
    (when seat
      (send-relative-pointer-event interaction seat event)
      (trace-input "[input] relative ~,2F ~,2F~%"
                   (ataxia.runtime:pointer-motion-delta-x event)
                   (ataxia.runtime:pointer-motion-delta-y event))
      (behavior-handle-pointer-motion
       (compositor-behavior-policy (component-compositor interaction))
       interaction seat event))
    seat))

(defmethod interaction-handle-pointer-motion-absolute
    ((interaction interaction-system) event)
  (let* ((seat
           (interaction-seat-for-device
            interaction
            (ataxia.runtime:pointer-motion-absolute-pointer event)))
         (policy
           (compositor-behavior-policy (component-compositor interaction))))
    (when seat
      (trace-input "[input] absolute ~,3F ~,3F~%"
                   (ataxia.runtime:pointer-motion-absolute-x event)
                   (ataxia.runtime:pointer-motion-absolute-y event))
      (behavior-handle-pointer-motion-absolute
       policy interaction seat event))
    seat))

(defmethod interaction-handle-pointer-button
    ((interaction interaction-system) event)
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
             (policy
               (compositor-behavior-policy
                (component-compositor interaction)))
             (operation (behavior-operation policy seat))
             (hit (unless operation
                    (multiple-value-bind (pointer-x pointer-y)
                        (behavior-cursor-layout-position policy seat)
                      (update-pointer-focus-at
                       interaction seat pointer-x pointer-y time))))
             (decision
               (behavior-handle-pointer-button
                policy
                interaction seat hit button state time)))
        (if (eq state :pressed)
            (setf (gethash button (seat-pressed-buttons seat)) t)
            (remhash button (seat-pressed-buttons seat)))
        (let ((view (pointer-decision-focus-target decision)))
          (when view
            (focus-view interaction seat view)))
        (when (and (pointer-decision-deliver-p decision)
                   (seat-pointer-focus-surface seat))
          (ataxia.runtime:seat-pointer-notify-button
           (seat-native seat) time button state)))
      seat)))

(defmethod interaction-handle-pointer-axis
    ((interaction interaction-system) event)
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
  (let ((seat (interaction-seat-for-device interaction pointer)))
    (when seat
      (ataxia.runtime:seat-pointer-notify-frame (seat-native seat)))
    seat))

(defmethod interaction-handle-keyboard-key
    ((interaction interaction-system) event)
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
      (let* ((policy
               (compositor-behavior-policy
                (component-compositor interaction)))
             (old-output (behavior-cursor-output policy seat))
             (old-box
               (multiple-value-bind (pointer-x pointer-y)
                   (behavior-cursor-layout-position policy seat)
                 (behavior-cursor-damage-box
                  policy seat old-output pointer-x pointer-y))))
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
        (behavior-cursor-content-changed
         policy interaction seat old-output old-box)))
    seat))
