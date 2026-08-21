;;;; Standard and planar behavior policy implementations.
;;;;
;;;; These methods provide the default planar world, migration, viewport, and
;;;; lifecycle behavior behind the compositor-facing policy protocol.

(in-package #:ataxia.compositor)

(defclass standard-behavior-policy (behavior-policy)
  ((application-reveal-style
    :initarg :application-reveal-style
    :initform (make-instance 'codec-reveal-style)
    :accessor behavior-application-reveal-style)
   (background-color :initarg :background-color
                     :initform '(0.035 0.045 0.065 1.0)
                     :accessor behavior-background-color))
  (:documentation
   "Defines the replaceable standard behavior policy. It owns policy-specific state and must satisfy compositor generics without mutating Runtime objects directly."))

(defclass planar-placement (behavior-placement)
  ((x :initarg :x :accessor placement-x)
   (y :initarg :y :accessor placement-y)
   (width :initarg :width :accessor placement-width)
   (height :initarg :height :accessor placement-height)
   (z :initarg :z :initform 0d0 :accessor placement-z))
  (:documentation
   "Represents behavior implementation planar placement. It may own policy-specific state but must remain replaceable through the compositor behavior protocol."))

(defclass planar-behavior-state (behavior-view-state) ()
  (:documentation
   "Stores planar behavior state. Only the owning subsystem or active behavior policy may mutate it, and replacement must copy or migrate mutable members."))

(defclass viewport ()
  ((camera-x :initarg :camera-x :initform 0d0 :accessor viewport-camera-x)
   (camera-y :initarg :camera-y :initform 0d0 :accessor viewport-camera-y)
   (scale :initarg :scale :initform 1d0 :accessor viewport-scale))
  (:documentation
   "Represents behavior implementation viewport. It may own policy-specific state but must remain replaceable through the compositor behavior protocol."))

(defclass planar-behavior-policy (standard-behavior-policy)
  ((cascade-x :initform 48d0 :accessor planar-cascade-x)
   (cascade-y :initform 68d0 :accessor planar-cascade-y)
   (cascade-step :initform 36d0 :reader planar-cascade-step)
   (next-z :initform 0d0 :accessor planar-next-z)
   (shadow-style :initarg :shadow-style
                 :initform (make-instance 'soft-shadow-style)
                 :accessor behavior-shadow-style))
  (:documentation
   "Defines the replaceable planar behavior policy. It owns policy-specific state and must satisfy compositor generics without mutating Runtime objects directly."))

(defmethod activate-behavior-policy ((policy behavior-policy))
  "Implement ACTIVATE-BEHAVIOR-POLICY on the owner thread. Establish required listeners and state before publishing the object to other components."
  (setf (behavior-policy-active-p policy) t)
  policy)

(defmethod quiesce-behavior-policy
    ((policy behavior-policy) reason)
  "Implement QUIESCE-BEHAVIOR-POLICY for this behavior specialization. Keep policy state replaceable and return the protocol-defined result without bypassing core."
  (declare (ignore reason))
  (setf (behavior-policy-active-p policy) nil)
  policy)

(defmethod attach-component :after ((policy behavior-policy))
  "Extend ATTACH-COMPONENT after primary dispatch. Preserve the primary result and perform only the documented follow-up obligation."
  (activate-behavior-policy policy))

(defmethod detach-component :before
    ((policy behavior-policy) reason)
  "Prepare or validate DETACH-COMPONENT before primary dispatch. Do not consume ownership or perform the primary operation early."
  (quiesce-behavior-policy policy reason)
  (let* ((compositor (component-compositor policy))
         (renderer
           (and (slot-boundp compositor 'graphics)
                (compositor-graphics compositor))))
    (when (and renderer (eq (component-state renderer) :attached))
      (release-shader-program-owner renderer policy))))

(defmethod behavior-handle-pointer-axis
    ((policy behavior-policy) interaction seat input)
  "Implement BEHAVIOR-HANDLE-POINTER-AXIS for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy interaction seat input))
  (make-instance 'pointer-axis-decision))

(defmethod behavior-handle-keyboard-key
    ((policy behavior-policy) interaction seat input)
  "Implement BEHAVIOR-HANDLE-KEYBOARD-KEY for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy interaction seat input))
  (make-instance 'keyboard-key-decision))

(defmethod behavior-validate-resources
    ((policy behavior-policy) compositor snapshots context)
  "Implement BEHAVIOR-VALIDATE-RESOURCES for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy context))
  (let ((renderer (compositor-graphics compositor)))
    (dolist (entry snapshots)
      (validate-presentation-snapshot-resources renderer (cdr entry))))
  t)

(defun adopt-planar-behavior-state (view)
  (let ((state (view-behavior-state view)))
    (unless (typep state 'planar-behavior-state)
      (setf state
             (make-instance
             'planar-behavior-state
             :placement (and state (behavior-state-placement state))
             :restore-state (and state (behavior-state-restore-state state))
             :animation-policy
             (and state (behavior-state-animation-policy state))
             :shader-program-name
             (and state (behavior-state-shader-program-name state))
             :presentation-state
             (if state
                 (behavior-state-presentation-state state)
                 (make-instance 'presentation-state)))
            (view-behavior-state view) state))
    state))

(defmethod behavior-view-created
    ((policy planar-behavior-policy) view)
  "Implement BEHAVIOR-VIEW-CREATED for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (adopt-planar-behavior-state view)
  (behavior-place-view policy view nil))

(defmethod behavior-output-added
    ((policy planar-behavior-policy) output)
  "Implement BEHAVIOR-OUTPUT-ADDED for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (setf (output-behavior-state output) (make-instance 'viewport))
  (incf (behavior-policy-revision policy))
  output)

(defmethod behavior-output-removing
    ((policy behavior-policy) output)
  "Implement BEHAVIOR-OUTPUT-REMOVING for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (setf (output-behavior-state output) nil)
  (incf (behavior-policy-revision policy))
  output)

(defmethod behavior-view-committed
    ((policy planar-behavior-policy) view commit initial-commit-p)
  "Implement BEHAVIOR-VIEW-COMMITTED for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore initial-commit-p))
  (let ((width (ataxia.runtime:surface-commit-width commit))
        (height (ataxia.runtime:surface-commit-height commit)))
    (when (plusp width)
      (let ((placement (view-placement view)))
        (when (typep placement 'planar-placement)
          (setf (placement-width placement) (coerce width 'double-float)
                (placement-height placement) (coerce height 'double-float))))))
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-mapped
    ((policy behavior-policy) view)
  "Implement BEHAVIOR-VIEW-MAPPED for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-unmapped
    ((policy behavior-policy) view)
  "Implement BEHAVIOR-VIEW-UNMAPPED for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-destroying
    ((policy behavior-policy) view)
  "Implement BEHAVIOR-VIEW-DESTROYING for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-identity-changed
    ((policy behavior-policy) view kind value)
  "Implement BEHAVIOR-VIEW-IDENTITY-CHANGED for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore kind value))
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-recommend-initial-size
    ((policy planar-behavior-policy) compositor view)
  "Implement BEHAVIOR-RECOMMEND-INITIAL-SIZE for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy view))
  (let ((output (first (compositor-outputs-list
                        (compositor-outputs compositor)))))
    (values
     (if output
         (min 900 (max 320 (- (ataxia.runtime:output-width
                               (output-native output)) 96)))
         900)
     (if output
         (min 650 (max 240 (- (ataxia.runtime:output-height
                               (output-native output)) 128)))
         650))))

(defmethod behavior-set-view-size
    ((policy planar-behavior-policy) view width height context)
  "Implement BEHAVIOR-SET-VIEW-SIZE for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore context))
  (let ((placement (view-placement view)))
    (when placement
      (setf (placement-width placement) (coerce width 'double-float)
            (placement-height placement) (coerce height 'double-float))))
  (incf (behavior-policy-revision policy))
  (make-instance 'view-configuration-decision :width width :height height))

(defmethod copy-behavior-placement
    ((policy planar-behavior-policy) (placement planar-placement))
  "Implement COPY-BEHAVIOR-PLACEMENT by returning an independent copy. Do not share mutable policy, presentation, or lifecycle state with the source."
  (declare (ignore policy))
  (make-instance 'planar-placement
                 :x (placement-x placement) :y (placement-y placement)
                 :width (placement-width placement)
                 :height (placement-height placement)
                 :z (placement-z placement)))

(defun copy-presentation-state (state)
  (let ((copy (make-instance 'presentation-state)))
    (setf (presentation-opacity copy) (presentation-opacity state)
          (presentation-scale copy) (presentation-scale state)
          (presentation-offset-x copy) (presentation-offset-x state)
          (presentation-offset-y copy) (presentation-offset-y state))
    (maphash
     (lambda (name value)
       (setf (gethash name (presentation-effect-parameters copy)) value))
     (presentation-effect-parameters state))
    (maphash
     (lambda (name value)
       (setf (gethash name (presentation-shader-uniforms copy)) value))
     (presentation-shader-uniforms state))
    copy))

(defmethod copy-behavior-view-state
    ((policy planar-behavior-policy) (state planar-behavior-state))
  "Implement COPY-BEHAVIOR-VIEW-STATE by returning an independent copy. Do not share mutable policy, presentation, or lifecycle state with the source."
  (make-instance
   'planar-behavior-state
   :placement
   (and (behavior-state-placement state)
        (copy-behavior-placement policy (behavior-state-placement state)))
   :restore-state
   (and (behavior-state-restore-state state)
        (copy-behavior-placement
         policy (behavior-state-restore-state state)))
   :animation-policy (behavior-state-animation-policy state)
   :shader-program-name (behavior-state-shader-program-name state)
   :presentation-state
   (copy-presentation-state (behavior-state-presentation-state state))))

(defmethod copy-behavior-output-state
    ((policy planar-behavior-policy) (state viewport))
  "Implement COPY-BEHAVIOR-OUTPUT-STATE by returning an independent copy. Do not share mutable policy, presentation, or lifecycle state with the source."
  (declare (ignore policy))
  (make-instance 'viewport
                 :camera-x (viewport-camera-x state)
                 :camera-y (viewport-camera-y state)
                 :scale (viewport-scale state)))

(defmethod migrate-behavior-view-state
    ((old-policy planar-behavior-policy)
     (new-policy planar-behavior-policy) view
     (state planar-behavior-state))
  "Implement MIGRATE-BEHAVIOR-VIEW-STATE without mutating the source. Reject unsupported state before installation so policy replacement can roll back atomically."
  (declare (ignore old-policy view))
  (copy-behavior-view-state new-policy state))

(defmethod migrate-behavior-output-state
    ((old-policy planar-behavior-policy)
     (new-policy planar-behavior-policy) output (state viewport))
  "Implement MIGRATE-BEHAVIOR-OUTPUT-STATE without mutating the source. Reject unsupported state before installation so policy replacement can roll back atomically."
  (declare (ignore old-policy output))
  (copy-behavior-output-state new-policy state))

(defmethod behavior-export-state
    ((policy behavior-policy) compositor context)
  "Implement BEHAVIOR-EXPORT-STATE for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore context))
  (make-instance
   'behavior-portable-state
   :source-policy policy
   :view-states
   (mapcar
    (lambda (view)
      (cons view
            (copy-behavior-view-state
             policy (view-behavior-state view))))
    (desktop-views (compositor-desktop compositor)))
   :output-states
   (mapcar
    (lambda (output)
      (cons output
            (copy-behavior-output-state
             policy (output-behavior-state output))))
    (compositor-outputs-list (compositor-outputs compositor)))))

(defmethod behavior-import-state
    ((policy behavior-policy) (portable behavior-portable-state) context)
  "Implement BEHAVIOR-IMPORT-STATE for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore context))
  (let ((old-policy (portable-state-source-policy portable)))
    (make-instance
     'behavior-installation
     :view-states
     (mapcar
      (lambda (entry)
        (cons (car entry)
              (migrate-behavior-view-state
               old-policy policy (car entry) (cdr entry))))
      (portable-state-view-states portable))
     :output-states
     (mapcar
      (lambda (entry)
        (cons (car entry)
              (migrate-behavior-output-state
               old-policy policy (car entry) (cdr entry))))
      (portable-state-output-states portable)))))

(defmethod behavior-place-view
    ((policy planar-behavior-policy) view (request placement-request))
  "Implement BEHAVIOR-PLACE-VIEW for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (let* ((x (or (requested-placement-x request)
                (planar-cascade-x policy)))
         (y (or (requested-placement-y request)
                (planar-cascade-y policy)))
         (width (or (requested-placement-width request) (view-width view)))
         (height (or (requested-placement-height request) (view-height view)))
         (placement
           (make-instance 'planar-placement
                          :x (coerce x 'double-float)
                          :y (coerce y 'double-float)
                          :width (coerce width 'double-float)
                          :height (coerce height 'double-float)
                          :z (incf (planar-next-z policy)))))
    (incf (planar-cascade-x policy) (planar-cascade-step policy))
    (incf (planar-cascade-y policy) (planar-cascade-step policy))
    (when (> (planar-cascade-x policy) 360d0)
      (setf (planar-cascade-x policy) 48d0
            (planar-cascade-y policy) 68d0))
    (setf (view-placement view) placement)
    placement))

(defmethod behavior-place-view
    ((policy planar-behavior-policy) view (request null))
  "Implement BEHAVIOR-PLACE-VIEW for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (behavior-place-view policy view (make-instance 'placement-request)))

(defmethod behavior-update-placement
    ((policy planar-behavior-policy) view
     (placement planar-placement) context)
  "Implement BEHAVIOR-UPDATE-PLACEMENT for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy context))
  (setf (view-placement view) placement)
  placement)

(defmethod behavior-project-view
    ((policy planar-behavior-policy) output
     (viewport viewport) view timestamp)
  "Implement BEHAVIOR-PROJECT-VIEW for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy output timestamp))
  (let ((placement (view-placement view))
        (scale (viewport-scale viewport)))
    (check-type placement planar-placement)
    (values (* (- (placement-x placement) (viewport-camera-x viewport)) scale)
            (* (- (placement-y placement) (viewport-camera-y viewport)) scale)
            (* (placement-width placement) scale)
            (* (placement-height placement) scale))))

(defmethod behavior-unproject-point
    ((policy planar-behavior-policy) output
     (viewport viewport) output-x output-y)
  "Implement BEHAVIOR-UNPROJECT-POINT for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy output))
  (values (+ (viewport-camera-x viewport)
             (/ output-x (viewport-scale viewport)))
          (+ (viewport-camera-y viewport)
             (/ output-y (viewport-scale viewport)))))

(defgeneric pan-viewport (viewport delta-x delta-y)
  (:documentation
   "Implement PAN-VIEWPORT for behavior implementations. Keep policy state replaceable and return the protocol-defined result without bypassing core."))
(defgeneric zoom-viewport (viewport factor anchor-x anchor-y)
  (:documentation
   "Implement ZOOM-VIEWPORT for behavior implementations. Keep policy state replaceable and return the protocol-defined result without bypassing core."))

(defmethod pan-viewport
    ((viewport viewport) delta-x delta-y)
  "Implement PAN-VIEWPORT for this behavior specialization. Keep policy state replaceable and return the protocol-defined result without bypassing core."
  (incf (viewport-camera-x viewport) (coerce delta-x 'double-float))
  (incf (viewport-camera-y viewport) (coerce delta-y 'double-float))
  viewport)

(defmethod zoom-viewport
    ((viewport viewport) factor anchor-x anchor-y)
  "Implement ZOOM-VIEWPORT for this behavior specialization. Keep policy state replaceable and return the protocol-defined result without bypassing core."
  (let* ((old-scale (viewport-scale viewport))
         (new-scale (max 0.05d0 (min 32d0 (* old-scale factor))))
         (world-x (+ (viewport-camera-x viewport) (/ anchor-x old-scale)))
         (world-y (+ (viewport-camera-y viewport) (/ anchor-y old-scale))))
    (setf (viewport-scale viewport) new-scale
          (viewport-camera-x viewport) (- world-x (/ anchor-x new-scale))
          (viewport-camera-y viewport) (- world-y (/ anchor-y new-scale))))
  viewport)

(defmethod behavior-pan-output
    ((policy planar-behavior-policy) output delta-x delta-y)
  "Implement BEHAVIOR-PAN-OUTPUT for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy))
  (pan-viewport (output-viewport output) delta-x delta-y))

(defmethod behavior-zoom-output
    ((policy planar-behavior-policy) output factor anchor-x anchor-y)
  "Implement BEHAVIOR-ZOOM-OUTPUT for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore policy))
  (zoom-viewport
   (output-viewport output) factor anchor-x anchor-y))
