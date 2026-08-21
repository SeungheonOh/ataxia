;;;; Replaceable Layer 2 behavior policy protocol.
;;;;
;;;; Policies own placement, projection, scene construction, interaction math,
;;;; and presentation choices without changing protocol-correct core objects.

(in-package #:ataxia.compositor)

(defclass presentation-state ()
  ((opacity :initform 1d0 :accessor presentation-opacity)
   (scale :initform 1d0 :accessor presentation-scale)
   (offset-x :initform 0d0 :accessor presentation-offset-x)
   (offset-y :initform 0d0 :accessor presentation-offset-y)
   (shader-uniforms :initform (make-hash-table :test #'equal)
                    :reader presentation-shader-uniforms)))

(defclass behavior-view-state ()
  ((placement :initarg :placement :initform nil
              :accessor behavior-state-placement)
   (restore-state :initarg :restore-state :initform nil
                  :accessor behavior-state-restore-state)
   (animation-policy :initarg :animation-policy :initform nil
                     :accessor behavior-state-animation-policy)
   (shader-program-name :initarg :shader-program-name :initform nil
                        :accessor behavior-state-shader-program-name)
   (presentation-state :initarg :presentation-state
                       :initform (make-instance 'presentation-state)
                       :reader behavior-state-presentation-state)))

(defun view-placement (view)
  (behavior-state-placement (view-behavior-state view)))

(defun (setf view-placement) (placement view)
  (setf (behavior-state-placement (view-behavior-state view)) placement))

(defun view-restore-placement (view)
  (behavior-state-restore-state (view-behavior-state view)))

(defun (setf view-restore-placement) (state view)
  (setf (behavior-state-restore-state (view-behavior-state view)) state))

(defun view-animation-policy (view)
  (behavior-state-animation-policy (view-behavior-state view)))

(defun (setf view-animation-policy) (policy view)
  (setf (behavior-state-animation-policy (view-behavior-state view)) policy))

(defun view-shader-program-name (view)
  (behavior-state-shader-program-name (view-behavior-state view)))

(defun (setf view-shader-program-name) (name view)
  (setf (behavior-state-shader-program-name (view-behavior-state view)) name))

(defun view-presentation-state (view)
  (behavior-state-presentation-state (view-behavior-state view)))

(defclass behavior-policy (compositor-component)
  ((active-p :initform nil :accessor behavior-policy-active-p)
   (revision :initform 0 :accessor behavior-policy-revision)))

(defclass behavior-placement () ())

(defclass planar-placement (behavior-placement)
  ((x :initarg :x :accessor placement-x)
   (y :initarg :y :accessor placement-y)
   (width :initarg :width :accessor placement-width)
   (height :initarg :height :accessor placement-height)
   (z :initarg :z :initform 0d0 :accessor placement-z)))

(defclass planar-behavior-state (behavior-view-state) ())

(defclass placement-request ()
  ((x :initarg :x :initform nil :reader requested-placement-x)
   (y :initarg :y :initform nil :reader requested-placement-y)
   (width :initarg :width :initform nil :reader requested-placement-width)
   (height :initarg :height :initform nil :reader requested-placement-height)))

(defclass viewport ()
  ((camera-x :initarg :camera-x :initform 0d0 :accessor viewport-camera-x)
   (camera-y :initarg :camera-y :initform 0d0 :accessor viewport-camera-y)
   (scale :initarg :scale :initform 1d0 :accessor viewport-scale)))

(defclass planar-behavior-policy (behavior-policy)
  ((cascade-x :initform 48d0 :accessor planar-cascade-x)
   (cascade-y :initform 68d0 :accessor planar-cascade-y)
   (cascade-step :initform 36d0 :reader planar-cascade-step)
   (next-z :initform 0d0 :accessor planar-next-z)))

(defclass behavior-portable-state ()
  ((source-policy :initarg :source-policy
                  :reader portable-state-source-policy)
   (view-states :initarg :view-states
                :reader portable-state-view-states)
   (output-states :initarg :output-states
                  :reader portable-state-output-states)))

(defclass behavior-installation ()
  ((view-states :initarg :view-states
                :reader installation-view-states)
   (output-states :initarg :output-states
                  :reader installation-output-states)))

(defgeneric activate-behavior-policy (policy))
(defgeneric quiesce-behavior-policy (policy reason))
(defgeneric behavior-view-created (policy view))
(defgeneric behavior-view-committed (policy view commit initial-commit-p))
(defgeneric behavior-view-mapped (policy view))
(defgeneric behavior-view-unmapped (policy view))
(defgeneric behavior-view-destroying (policy view))
(defgeneric behavior-view-identity-changed (policy view kind value))
(defgeneric behavior-output-added (policy output))
(defgeneric behavior-output-removing (policy output))
(defgeneric behavior-recommend-initial-size (policy compositor view))
(defgeneric behavior-set-view-size (policy view width height context))
(defgeneric behavior-place-view (policy view placement-request))
(defgeneric behavior-update-placement (policy view placement context))
(defgeneric behavior-project-view (policy output viewport view timestamp))
(defgeneric behavior-unproject-point
    (policy output viewport output-x output-y))
(defgeneric copy-behavior-placement (policy placement))
(defgeneric copy-behavior-view-state (policy state))
(defgeneric copy-behavior-output-state (policy state))
(defgeneric migrate-behavior-view-state
    (old-policy new-policy view state))
(defgeneric migrate-behavior-output-state
    (old-policy new-policy output state))
(defgeneric behavior-export-state (policy compositor context))
(defgeneric behavior-import-state (policy portable-state context))
(defgeneric behavior-build-scene
    (policy presentation output timestamp))
(defgeneric behavior-build-view-items
    (policy items output view timestamp titlebar-height))
(defgeneric behavior-build-popup-items
    (policy items desktop output timestamp))
(defgeneric behavior-begin-operation
    (policy interaction seat view kind edges button))
(defgeneric behavior-update-operation (policy interaction operation))
(defgeneric behavior-configure-view-for-output
    (policy compositor view fullscreen-p))
(defgeneric behavior-restore-view (policy compositor view))
(defgeneric behavior-pan-output (policy output delta-x delta-y))
(defgeneric behavior-zoom-output
    (policy output factor anchor-x anchor-y))
(defgeneric behavior-move-view (policy view x y context))
(defgeneric behavior-focus-changed (policy seat previous view))
(defgeneric behavior-handle-pointer-button
    (policy interaction seat hit button state time))
(defgeneric behavior-handle-pointer-axis
    (policy interaction seat input))
(defgeneric behavior-handle-keyboard-key
    (policy interaction seat input))
(defgeneric behavior-observe-output (policy output))
(defgeneric behavior-observe-view (policy view))
(defgeneric behavior-resolve-animation
    (policy engine subject descriptor context))
(defgeneric behavior-set-view-animation-definition
    (policy view descriptor-class definition))

(defmethod activate-behavior-policy ((policy behavior-policy))
  (setf (behavior-policy-active-p policy) t)
  policy)

(defmethod quiesce-behavior-policy
    ((policy behavior-policy) reason)
  (declare (ignore reason))
  (setf (behavior-policy-active-p policy) nil)
  policy)

(defmethod attach-component :after ((policy behavior-policy))
  (activate-behavior-policy policy))

(defmethod detach-component :before
    ((policy behavior-policy) reason)
  (quiesce-behavior-policy policy reason))

(defmethod behavior-handle-pointer-axis
    ((policy behavior-policy) interaction seat input)
  (declare (ignore policy interaction seat input))
  (make-instance 'pointer-axis-decision))

(defmethod behavior-handle-keyboard-key
    ((policy behavior-policy) interaction seat input)
  (declare (ignore policy interaction seat input))
  (make-instance 'keyboard-key-decision))

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
  (adopt-planar-behavior-state view)
  (behavior-place-view policy view nil))

(defmethod behavior-output-added
    ((policy planar-behavior-policy) output)
  (setf (output-behavior-state output) (make-instance 'viewport))
  (incf (behavior-policy-revision policy))
  output)

(defmethod behavior-output-removing
    ((policy behavior-policy) output)
  (setf (output-behavior-state output) nil)
  (incf (behavior-policy-revision policy))
  output)

(defmethod behavior-view-committed
    ((policy planar-behavior-policy) view commit initial-commit-p)
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
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-unmapped
    ((policy behavior-policy) view)
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-destroying
    ((policy behavior-policy) view)
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-identity-changed
    ((policy behavior-policy) view kind value)
  (declare (ignore kind value))
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-recommend-initial-size
    ((policy planar-behavior-policy) compositor view)
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
  (declare (ignore context))
  (let ((placement (view-placement view)))
    (when placement
      (setf (placement-width placement) (coerce width 'double-float)
            (placement-height placement) (coerce height 'double-float))))
  (incf (behavior-policy-revision policy))
  (make-instance 'view-configuration-decision :width width :height height))

(defmethod copy-behavior-placement
    ((policy planar-behavior-policy) (placement planar-placement))
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
       (setf (gethash name (presentation-shader-uniforms copy)) value))
     (presentation-shader-uniforms state))
    copy))

(defmethod copy-behavior-view-state
    ((policy planar-behavior-policy) (state planar-behavior-state))
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
  (declare (ignore policy))
  (make-instance 'viewport
                 :camera-x (viewport-camera-x state)
                 :camera-y (viewport-camera-y state)
                 :scale (viewport-scale state)))

(defmethod migrate-behavior-view-state
    ((old-policy planar-behavior-policy)
     (new-policy planar-behavior-policy) view
     (state planar-behavior-state))
  (declare (ignore old-policy view))
  (copy-behavior-view-state new-policy state))

(defmethod migrate-behavior-output-state
    ((old-policy planar-behavior-policy)
     (new-policy planar-behavior-policy) output (state viewport))
  (declare (ignore old-policy output))
  (copy-behavior-output-state new-policy state))

(defmethod behavior-export-state
    ((policy behavior-policy) compositor context)
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
  (behavior-place-view policy view (make-instance 'placement-request)))

(defmethod behavior-update-placement
    ((policy planar-behavior-policy) view
     (placement planar-placement) context)
  (declare (ignore policy context))
  (setf (view-placement view) placement)
  placement)

(defmethod behavior-project-view
    ((policy planar-behavior-policy) output
     (viewport viewport) view timestamp)
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
  (declare (ignore policy output))
  (values (+ (viewport-camera-x viewport)
             (/ output-x (viewport-scale viewport)))
          (+ (viewport-camera-y viewport)
             (/ output-y (viewport-scale viewport)))))

(defgeneric pan-viewport (viewport delta-x delta-y))
(defgeneric zoom-viewport (viewport factor anchor-x anchor-y))

(defmethod pan-viewport
    ((viewport viewport) delta-x delta-y)
  (incf (viewport-camera-x viewport) (coerce delta-x 'double-float))
  (incf (viewport-camera-y viewport) (coerce delta-y 'double-float))
  viewport)

(defmethod zoom-viewport
    ((viewport viewport) factor anchor-x anchor-y)
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
  (declare (ignore policy))
  (pan-viewport (output-viewport output) delta-x delta-y))

(defmethod behavior-zoom-output
    ((policy planar-behavior-policy) output factor anchor-x anchor-y)
  (declare (ignore policy))
  (zoom-viewport
   (output-viewport output) factor anchor-x anchor-y))
