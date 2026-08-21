;;;; Replaceable world and coordinate protocol.
;;;;
;;;; The default planar world supports finite output viewports over unbounded
;;;; world coordinates. Projection and inverse mapping share the same camera.

(in-package #:ataxia.compositor)

(defclass world (compositor-component) ())

(defclass world-placement () ())

(defclass planar-placement (world-placement)
  ((x :initarg :x :accessor placement-x)
   (y :initarg :y :accessor placement-y)
   (width :initarg :width :accessor placement-width)
   (height :initarg :height :accessor placement-height)
   (z :initarg :z :initform 0d0 :accessor placement-z)))

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

(defgeneric world-place-view (world view placement-request))
(defgeneric world-update-placement (world view placement context))
(defgeneric world-project (world output viewport view timestamp))
(defgeneric world-unproject (world output viewport output-x output-y))
(defgeneric world-hit-test
    (world output viewport output-x output-y timestamp))
(defgeneric copy-world-placement (world placement))
(defgeneric world-update-interactive-operation
    (world interaction operation))

(defmethod copy-world-placement
    ((world planar-world) (placement planar-placement))
  (declare (ignore world))
  (make-instance 'planar-placement
                 :x (placement-x placement) :y (placement-y placement)
                 :width (placement-width placement)
                 :height (placement-height placement)
                 :z (placement-z placement)))

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

(defun pan-viewport (viewport delta-x delta-y)
  (incf (viewport-camera-x viewport) (coerce delta-x 'double-float))
  (incf (viewport-camera-y viewport) (coerce delta-y 'double-float))
  viewport)

(defun zoom-viewport (viewport factor anchor-x anchor-y)
  (let* ((old-scale (viewport-scale viewport))
         (new-scale (max 0.05d0 (min 32d0 (* old-scale factor))))
         (world-x (+ (viewport-camera-x viewport) (/ anchor-x old-scale)))
         (world-y (+ (viewport-camera-y viewport) (/ anchor-y old-scale))))
    (setf (viewport-scale viewport) new-scale
          (viewport-camera-x viewport) (- world-x (/ anchor-x new-scale))
          (viewport-camera-y viewport) (- world-y (/ anchor-y new-scale))))
  viewport)
