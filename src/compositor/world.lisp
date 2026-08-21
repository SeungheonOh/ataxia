;;;; Replaceable world and coordinate protocol.
;;;;
;;;; The default planar world supports finite output viewports over unbounded
;;;; world coordinates. Projection and inverse mapping share the same camera.

(in-package #:ataxia.compositor)

(defclass behavior-policy (compositor-component)
  ((active-p :initform nil :accessor behavior-policy-active-p)
   (revision :initform 0 :accessor behavior-policy-revision)))

(defclass world (behavior-policy) ())

(defclass world-placement () ())

(defclass planar-placement (world-placement)
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

(defclass planar-world (world)
  ((cascade-x :initform 48d0 :accessor world-cascade-x)
   (cascade-y :initform 68d0 :accessor world-cascade-y)
   (cascade-step :initform 36d0 :reader world-cascade-step)
   (next-z :initform 0d0 :accessor world-next-z)))

(defclass planar-behavior-policy (planar-world) ())

(defgeneric activate-behavior-policy (policy))
(defgeneric quiesce-behavior-policy (policy reason))
(defgeneric behavior-view-created (policy view))
(defgeneric behavior-view-committed (policy view commit initial-commit-p))
(defgeneric behavior-view-mapped (policy view))
(defgeneric behavior-view-unmapped (policy view))
(defgeneric behavior-view-destroying (policy view))
(defgeneric behavior-view-identity-changed (policy view kind value))
(defgeneric behavior-place-view (policy view placement-request))
(defgeneric behavior-update-placement (policy view placement context))
(defgeneric behavior-project-view (policy output viewport view timestamp))
(defgeneric behavior-unproject-point
    (policy output viewport output-x output-y))
(defgeneric copy-behavior-view-state (policy state))
(defgeneric behavior-build-view-items
    (policy items output view timestamp titlebar-height))
(defgeneric behavior-begin-operation
    (policy interaction seat view kind edges button))
(defgeneric behavior-update-operation (policy interaction operation))
(defgeneric behavior-configure-view-for-output
    (policy compositor view fullscreen-p))
(defgeneric behavior-restore-view (policy compositor view))
(defgeneric behavior-pan-output (policy output delta-x delta-y))
(defgeneric behavior-zoom-output
    (policy output factor anchor-x anchor-y))

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

(defun adopt-planar-behavior-state (view)
  (let ((state (view-behavior-state view)))
    (unless (typep state 'planar-behavior-state)
      (setf state
            (make-instance
             'planar-behavior-state
             :placement (behavior-state-placement state)
             :width (behavior-state-width state)
             :height (behavior-state-height state)
             :restore-state (behavior-state-restore-state state)
             :animation-policy (behavior-state-animation-policy state)
             :shader-program-name
             (behavior-state-shader-program-name state)
             :presentation-state
             (behavior-state-presentation-state state))
            (view-behavior-state view) state))
    state))

(defgeneric world-place-view (world view placement-request))
(defgeneric world-update-placement (world view placement context))
(defgeneric world-project (world output viewport view timestamp))
(defgeneric world-unproject (world output viewport output-x output-y))
(defgeneric world-hit-test
    (world output viewport output-x output-y timestamp))
(defgeneric copy-world-placement (world placement))
(defgeneric world-update-interactive-operation
    (world interaction operation))

(defmethod behavior-view-created
    ((policy planar-behavior-policy) view)
  (adopt-planar-behavior-state view)
  (behavior-place-view policy view nil))

(defmethod behavior-view-committed
    ((policy planar-behavior-policy) view commit initial-commit-p)
  (declare (ignore initial-commit-p))
  (let ((width (ataxia.runtime:surface-commit-width commit))
        (height (ataxia.runtime:surface-commit-height commit)))
    (when (plusp width)
      (setf (view-width view) width
            (view-height view) height)
      (let ((placement (view-placement view)))
        (when (typep placement 'planar-placement)
          (setf (placement-width placement) (coerce width 'double-float)
                (placement-height placement) (coerce height 'double-float))))))
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-view-mapped
    ((policy behavior-policy) view)
  (declare (ignore view))
  (incf (behavior-policy-revision policy)))

(defmethod behavior-view-unmapped
    ((policy behavior-policy) view)
  (declare (ignore view))
  (incf (behavior-policy-revision policy)))

(defmethod behavior-view-destroying
    ((policy behavior-policy) view)
  (declare (ignore view))
  (incf (behavior-policy-revision policy)))

(defmethod behavior-view-identity-changed
    ((policy behavior-policy) view kind value)
  (declare (ignore view kind value))
  (incf (behavior-policy-revision policy)))

(defmethod behavior-place-view
    ((policy planar-behavior-policy) view placement-request)
  (world-place-view policy view placement-request))

(defmethod behavior-update-placement
    ((policy planar-behavior-policy) view placement context)
  (world-update-placement policy view placement context))

(defmethod behavior-project-view
    ((policy planar-behavior-policy) output viewport view timestamp)
  (world-project policy output viewport view timestamp))

(defmethod behavior-unproject-point
    ((policy planar-behavior-policy) output viewport output-x output-y)
  (world-unproject policy output viewport output-x output-y))

(defmethod copy-world-placement
    ((world planar-world) (placement planar-placement))
  (declare (ignore world))
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
        (copy-world-placement policy (behavior-state-placement state)))
   :width (behavior-state-width state)
   :height (behavior-state-height state)
   :restore-state
   (and (behavior-state-restore-state state)
        (copy-world-placement policy (behavior-state-restore-state state)))
   :animation-policy (behavior-state-animation-policy state)
   :shader-program-name (behavior-state-shader-program-name state)
   :presentation-state
   (copy-presentation-state (behavior-state-presentation-state state))))

(defmethod world-place-view
    ((world planar-world) view (request placement-request))
  (let* ((x (or (requested-placement-x request) (world-cascade-x world)))
         (y (or (requested-placement-y request) (world-cascade-y world)))
         (width (or (requested-placement-width request) (view-width view)))
         (height (or (requested-placement-height request) (view-height view)))
         (placement
           (make-instance 'planar-placement
                          :x (coerce x 'double-float)
                          :y (coerce y 'double-float)
                          :width (coerce width 'double-float)
                          :height (coerce height 'double-float)
                          :z (incf (world-next-z world)))))
    (incf (world-cascade-x world) (world-cascade-step world))
    (incf (world-cascade-y world) (world-cascade-step world))
    (when (> (world-cascade-x world) 360d0)
      (setf (world-cascade-x world) 48d0
            (world-cascade-y world) 68d0))
    (setf (view-placement view) placement)
    placement))

(defmethod world-place-view ((world planar-world) view (request null))
  (world-place-view world view (make-instance 'placement-request)))

(defmethod world-update-placement
    ((world planar-world) view (placement planar-placement) context)
  (declare (ignore world context))
  (setf (view-placement view) placement)
  placement)

(defmethod world-project
    ((world planar-world) output (viewport viewport) view timestamp)
  (declare (ignore world output timestamp))
  (let ((placement (view-placement view))
        (scale (viewport-scale viewport)))
    (check-type placement planar-placement)
    (values (* (- (placement-x placement) (viewport-camera-x viewport)) scale)
            (* (- (placement-y placement) (viewport-camera-y viewport)) scale)
            (* (placement-width placement) scale)
            (* (placement-height placement) scale))))

(defmethod world-unproject
    ((world planar-world) output (viewport viewport) output-x output-y)
  (declare (ignore world output))
  (values (+ (viewport-camera-x viewport)
             (/ output-x (viewport-scale viewport)))
          (+ (viewport-camera-y viewport)
             (/ output-y (viewport-scale viewport)))))

(defmethod world-hit-test
    ((world planar-world) output (viewport viewport)
     output-x output-y timestamp)
  (declare (ignore timestamp))
  (let* ((desktop (compositor-desktop (component-compositor world)))
         (views (reverse (desktop-stacking-order desktop))))
    (dolist (view views (values nil 0d0 0d0))
      (when (and (view-mapped-p view) (view-presentable-p view))
        (multiple-value-bind (x y width height)
            (world-project world output viewport view 0d0)
          (when (and (<= x output-x (+ x width))
                     (<= y output-y (+ y height)))
            (return
              (values view
                      (/ (- output-x x) (viewport-scale viewport))
                      (/ (- output-y y) (viewport-scale viewport))))))))))

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
