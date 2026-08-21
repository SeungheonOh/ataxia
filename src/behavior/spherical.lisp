;;;; Spherical Layer 2 behavior policy.
;;;;
;;;; Views occupy angular patches on a unit sphere. A per-output camera projects
;;;; those patches into the same immutable rectangles used for drawing and input.

(in-package #:ataxia.compositor)

(defconstant +two-pi+ (* 2d0 pi))
(defconstant +half-pi+ (/ pi 2d0))

(defclass spherical-placement (behavior-placement)
  ((longitude :initarg :longitude :accessor spherical-longitude)
   (latitude :initarg :latitude :accessor spherical-latitude)
   (angular-width :initarg :angular-width
                  :accessor spherical-angular-width)
   (angular-height :initarg :angular-height
                   :accessor spherical-angular-height)
   (depth :initarg :depth :initform 0d0 :accessor spherical-depth)))

(defclass spherical-camera ()
  ((longitude :initarg :longitude :initform 0d0
              :accessor camera-longitude)
   (latitude :initarg :latitude :initform 0d0
             :accessor camera-latitude)
   (field-of-view :initarg :field-of-view :initform 1.45d0
                  :accessor camera-field-of-view)))

(defclass spherical-behavior-state (behavior-view-state) ())

(defclass spherical-restore-state ()
  ((placement :initarg :placement :reader spherical-restore-placement)
   (width :initarg :width :reader spherical-restore-width)
   (height :initarg :height :reader spherical-restore-height)))

(defclass spherical-behavior-policy (behavior-policy)
  ((next-longitude :initform -0.25d0
                   :accessor spherical-next-longitude)
   (next-latitude :initform 0.12d0
                  :accessor spherical-next-latitude)
   (next-depth :initform 0d0 :accessor spherical-next-depth)
   (mesh-columns :initarg :mesh-columns :initform 12
                 :reader spherical-mesh-columns)
   (mesh-rows :initarg :mesh-rows :initform 8
              :reader spherical-mesh-rows)
   (mesh-cache :initform (make-hash-table :test #'equal)
               :reader spherical-mesh-cache)
   (mesh-cache-revision :initform -1
                        :accessor spherical-mesh-cache-revision)
   (shadow-style :initarg :shadow-style
                 :initform (make-instance 'soft-shadow-style)
                 :accessor behavior-shadow-style)))

(defun normalize-longitude (longitude)
  (- (mod (+ (coerce longitude 'double-float) pi) +two-pi+) pi))

(defun clamp-latitude (latitude)
  (max (+ (- +half-pi+) 0.02d0)
       (min (- +half-pi+ 0.02d0) (coerce latitude 'double-float))))

(defun copy-spherical-placement (placement)
  (make-instance
   'spherical-placement
   :longitude (spherical-longitude placement)
   :latitude (spherical-latitude placement)
   :angular-width (spherical-angular-width placement)
   :angular-height (spherical-angular-height placement)
   :depth (spherical-depth placement)))

(defun copy-spherical-camera (camera)
  (make-instance
   'spherical-camera
   :longitude (camera-longitude camera)
   :latitude (camera-latitude camera)
   :field-of-view (camera-field-of-view camera)))

(defun spherical-aspect-angular-height (view angular-width)
  (max 0.12d0
       (min 1.2d0
            (* angular-width
               (/ (coerce (view-height view) 'double-float)
                  (max 1d0 (coerce (view-width view) 'double-float)))))))

(defun make-spherical-view-state (state placement)
  (make-instance
   'spherical-behavior-state
   :placement placement
   :restore-state nil
   :animation-policy (and state (behavior-state-animation-policy state))
   :shader-program-name
   (and state (behavior-state-shader-program-name state))
   :presentation-state
   (if state
       (copy-presentation-state (behavior-state-presentation-state state))
       (make-instance 'presentation-state))))

(defun adopt-spherical-behavior-state (view)
  (let ((state (view-behavior-state view)))
    (unless (typep state 'spherical-behavior-state)
      (setf state (make-spherical-view-state state nil)
            (view-behavior-state view) state))
    state))

(defmethod behavior-output-added
    ((policy spherical-behavior-policy) output)
  (setf (output-behavior-state output) (make-instance 'spherical-camera))
  (incf (behavior-policy-revision policy))
  output)

(defmethod behavior-view-created
    ((policy spherical-behavior-policy) view)
  (adopt-spherical-behavior-state view)
  (behavior-place-view policy view nil))

(defmethod behavior-place-view
    ((policy spherical-behavior-policy) view request)
  (declare (ignore request))
  (let* ((angular-width 0.65d0)
         (placement
           (make-instance
            'spherical-placement
            :longitude (spherical-next-longitude policy)
            :latitude (spherical-next-latitude policy)
            :angular-width angular-width
            :angular-height
            (spherical-aspect-angular-height view angular-width)
            :depth (incf (spherical-next-depth policy)))))
    (incf (spherical-next-longitude policy) 0.34d0)
    (when (> (spherical-next-longitude policy) 0.55d0)
      (setf (spherical-next-longitude policy) -0.25d0)
      (decf (spherical-next-latitude policy) 0.26d0))
    (when (< (spherical-next-latitude policy) -0.4d0)
      (setf (spherical-next-latitude policy) 0.12d0))
    (setf (view-placement view) placement)
    (incf (behavior-policy-revision policy))
    placement))

(defmethod behavior-update-placement
    ((policy spherical-behavior-policy) view
     (placement spherical-placement) context)
  (declare (ignore context))
  (setf (view-placement view) placement)
  (incf (behavior-policy-revision policy))
  placement)

(defmethod behavior-view-committed
    ((policy spherical-behavior-policy) view commit initial-commit-p)
  (declare (ignore initial-commit-p))
  (when (plusp (ataxia.runtime:surface-commit-width commit))
    (let ((placement (view-placement view)))
      (setf (spherical-angular-height placement)
            (spherical-aspect-angular-height
             view (spherical-angular-width placement)))))
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-recommend-initial-size
    ((policy spherical-behavior-policy) compositor view)
  (declare (ignore policy view))
  (let ((output (first (compositor-outputs-list
                        (compositor-outputs compositor)))))
    (values (if output
                (min 900 (max 320 (- (ataxia.runtime:output-width
                                      (output-native output)) 120)))
                900)
            (if output
                (min 650 (max 240 (- (ataxia.runtime:output-height
                                      (output-native output)) 150)))
                650))))

(defmethod behavior-set-view-size
    ((policy spherical-behavior-policy) view width height context)
  (declare (ignore context))
  (let ((placement (view-placement view)))
    (when placement
      (setf (spherical-angular-height placement)
            (max 0.12d0
                 (min 1.2d0
                      (* (spherical-angular-width placement)
                         (/ (coerce height 'double-float)
                            (max 1d0 (coerce width 'double-float)))))))))
  (incf (behavior-policy-revision policy))
  (make-instance 'view-configuration-decision :width width :height height))

(defun spherical-camera-basis (camera)
  (let* ((longitude (camera-longitude camera))
         (latitude (camera-latitude camera))
         (cos-longitude (cos longitude))
         (sin-longitude (sin longitude))
         (cos-latitude (cos latitude))
         (sin-latitude (sin latitude)))
    (values
     (list (* cos-latitude cos-longitude)
           (* cos-latitude sin-longitude) sin-latitude)
     (list (- sin-longitude) cos-longitude 0d0)
     (list (* (- sin-latitude) cos-longitude)
           (* (- sin-latitude) sin-longitude) cos-latitude))))

(defun vector-dot (left right)
  (+ (* (first left) (first right))
     (* (second left) (second right))
     (* (third left) (third right))))

(defun spherical-point-vector (longitude latitude)
  (let ((cos-latitude (cos latitude)))
    (list (* cos-latitude (cos longitude))
          (* cos-latitude (sin longitude))
          (sin latitude))))

(defun spherical-vertical-field-of-view (camera output)
  (* 2d0
     (atan (* (tan (/ (camera-field-of-view camera) 2d0))
              (/ (coerce (ataxia.runtime:output-height (output-native output))
                         'double-float)
                 (max 1d0
                      (coerce (ataxia.runtime:output-width
                               (output-native output))
                              'double-float)))))))

(defun project-spherical-placement (camera output placement)
  (multiple-value-bind (forward right up) (spherical-camera-basis camera)
    (let* ((point (spherical-point-vector
                   (spherical-longitude placement)
                   (spherical-latitude placement)))
           (depth (vector-dot point forward))
           (output-width
             (coerce (ataxia.runtime:output-width (output-native output))
                     'double-float))
           (output-height
             (coerce (ataxia.runtime:output-height (output-native output))
                     'double-float)))
      (if (<= depth 0.05d0)
          (values 0d0 0d0 0d0 0d0)
          (let* ((horizontal-tangent
                   (tan (/ (camera-field-of-view camera) 2d0)))
                 (vertical-tangent
                   (tan (/ (spherical-vertical-field-of-view camera output)
                           2d0)))
                 (center-x
                   (* 0.5d0 output-width
                      (+ 1d0 (/ (vector-dot point right)
                                (* depth horizontal-tangent)))))
                 (center-y
                   (* 0.5d0 output-height
                      (- 1d0 (/ (vector-dot point up)
                                (* depth vertical-tangent)))))
                 (width
                   (* output-width
                      (/ (tan (/ (spherical-angular-width placement) 2d0))
                         (* depth horizontal-tangent))))
                 (height
                   (* output-height
                      (/ (tan (/ (spherical-angular-height placement) 2d0))
                         (* depth vertical-tangent)))))
            (values (- center-x (/ width 2d0))
                    (- center-y (/ height 2d0)) width height))))))

(defmethod behavior-project-view
    ((policy spherical-behavior-policy) output
     (camera spherical-camera) view timestamp)
  (declare (ignore policy timestamp))
  (project-spherical-placement camera output (view-placement view)))

(defun normalize-vector (vector)
  (let ((length (sqrt (vector-dot vector vector))))
    (mapcar (lambda (component) (/ component length)) vector)))

(defmethod behavior-unproject-point
    ((policy spherical-behavior-policy) output
     (camera spherical-camera) output-x output-y)
  (declare (ignore policy))
  (multiple-value-bind (forward right up) (spherical-camera-basis camera)
    (let* ((width (coerce (ataxia.runtime:output-width (output-native output))
                          'double-float))
           (height (coerce (ataxia.runtime:output-height (output-native output))
                           'double-float))
           (screen-x (* (- (/ output-x width) 0.5d0) 2d0
                        (tan (/ (camera-field-of-view camera) 2d0))))
           (screen-y (* (- 0.5d0 (/ output-y height)) 2d0
                        (tan (/ (spherical-vertical-field-of-view camera output)
                                2d0))))
           (ray
             (normalize-vector
              (mapcar (lambda (forward-value right-value up-value)
                        (+ forward-value (* screen-x right-value)
                           (* screen-y up-value)))
                      forward right up))))
      (values (atan (second ray) (first ray))
              (asin (third ray))))))

(defmethod copy-behavior-view-state
    ((policy spherical-behavior-policy) (state spherical-behavior-state))
  (declare (ignore policy))
  (make-instance
   'spherical-behavior-state
   :placement
   (and (behavior-state-placement state)
        (copy-spherical-placement (behavior-state-placement state)))
   :restore-state
   (let ((restore (behavior-state-restore-state state)))
     (and restore
          (make-instance
           'spherical-restore-state
           :placement
           (copy-spherical-placement (spherical-restore-placement restore))
           :width (spherical-restore-width restore)
           :height (spherical-restore-height restore))))
   :animation-policy (behavior-state-animation-policy state)
   :shader-program-name (behavior-state-shader-program-name state)
   :presentation-state
   (copy-presentation-state (behavior-state-presentation-state state))))

(defmethod copy-behavior-output-state
    ((policy spherical-behavior-policy) (state spherical-camera))
  (declare (ignore policy))
  (copy-spherical-camera state))

(defmethod migrate-behavior-view-state
    ((old-policy spherical-behavior-policy)
     (new-policy spherical-behavior-policy) view
     (state spherical-behavior-state))
  (declare (ignore old-policy view))
  (copy-behavior-view-state new-policy state))

(defmethod migrate-behavior-output-state
    ((old-policy spherical-behavior-policy)
     (new-policy spherical-behavior-policy) output
     (state spherical-camera))
  (declare (ignore old-policy output))
  (copy-behavior-output-state new-policy state))

(defun first-policy-output (policy)
  (first
   (compositor-outputs-list
    (compositor-outputs (component-compositor policy)))))

(defmethod migrate-behavior-output-state
    ((old-policy planar-behavior-policy)
     (new-policy spherical-behavior-policy) output (state viewport))
  (declare (ignore old-policy output state))
  (make-instance 'spherical-camera))

(defmethod migrate-behavior-view-state
    ((old-policy planar-behavior-policy)
     (new-policy spherical-behavior-policy) view
     (state planar-behavior-state))
  (let* ((output (first-policy-output new-policy))
         (viewport (and output (output-behavior-state output)))
         (placement (behavior-state-placement state))
         (camera (make-instance 'spherical-camera))
         (center-x
           (if output
               (* (- (+ (placement-x placement)
                        (/ (placement-width placement) 2d0))
                     (viewport-camera-x viewport))
                  (viewport-scale viewport))
               0d0))
         (center-y
           (if output
               (* (- (+ (placement-y placement)
                        (/ (placement-height placement) 2d0))
                     (viewport-camera-y viewport))
                  (viewport-scale viewport))
               0d0)))
    (multiple-value-bind (longitude latitude)
        (if output
            (behavior-unproject-point
             new-policy output camera center-x center-y)
            (values 0d0 0d0))
      (let ((angular-width
              (if output
                  (* (/ (* (placement-width placement)
                           (viewport-scale viewport))
                        (max 1d0
                             (coerce (ataxia.runtime:output-width
                                      (output-native output))
                                     'double-float)))
                     (camera-field-of-view camera))
                  0.78d0)))
        (make-spherical-view-state
         state
         (make-instance
          'spherical-placement
          :longitude longitude :latitude latitude
          :angular-width (max 0.12d0 (min 1.25d0 angular-width))
          :angular-height
          (max 0.12d0
               (min 1.2d0
                    (* angular-width
                       (/ (coerce (view-height view) 'double-float)
                          (max 1d0 (coerce (view-width view)
                                          'double-float))))))))))))

(defmethod migrate-behavior-output-state
    ((old-policy spherical-behavior-policy)
     (new-policy planar-behavior-policy) output (state spherical-camera))
  (declare (ignore old-policy new-policy output state))
  (make-instance 'viewport))

(defmethod migrate-behavior-view-state
    ((old-policy spherical-behavior-policy)
     (new-policy planar-behavior-policy) view
     (state spherical-behavior-state))
  (let* ((output (first-policy-output old-policy))
         (camera (and output (output-behavior-state output)))
         (placement (behavior-state-placement state)))
    (multiple-value-bind (x y width height)
        (if output
            (project-spherical-placement camera output placement)
            (values 48d0 68d0
                    (coerce (view-width view) 'double-float)
                    (coerce (view-height view) 'double-float)))
      (make-instance
       'planar-behavior-state
       :placement
       (make-instance 'planar-placement
                      :x x :y y :width (max 120d0 width)
                      :height (max 80d0 height)
                      :z (spherical-depth placement))
       :animation-policy (behavior-state-animation-policy state)
       :shader-program-name (behavior-state-shader-program-name state)
       :presentation-state
       (copy-presentation-state
        (behavior-state-presentation-state state))))))

(defun make-spherical-projector (camera output)
  (multiple-value-bind (forward right up) (spherical-camera-basis camera)
    (let ((forward-x (first forward))
          (forward-y (second forward))
          (forward-z (third forward))
          (right-x (first right))
          (right-y (second right))
          (right-z (third right))
          (up-x (first up))
          (up-y (second up))
          (up-z (third up))
          (horizontal-tangent
            (tan (/ (camera-field-of-view camera) 2d0)))
          (vertical-tangent
            (tan (/ (spherical-vertical-field-of-view camera output) 2d0)))
          (width
            (coerce (ataxia.runtime:output-width (output-native output))
                    'double-float))
          (height
            (coerce (ataxia.runtime:output-height (output-native output))
                    'double-float)))
      (lambda (longitude latitude)
        (let* ((cos-latitude (cos latitude))
               (point-x (* cos-latitude (cos longitude)))
               (point-y (* cos-latitude (sin longitude)))
               (point-z (sin latitude))
               (depth (+ (* point-x forward-x) (* point-y forward-y)
                         (* point-z forward-z))))
          (when (> depth 0.05d0)
            (values
             t
             (* 0.5d0 width
                (+ 1d0
                   (/ (+ (* point-x right-x) (* point-y right-y)
                         (* point-z right-z))
                      (* depth horizontal-tangent))))
             (* 0.5d0 height
                (- 1d0
                   (/ (+ (* point-x up-x) (* point-y up-y)
                         (* point-z up-z))
                      (* depth vertical-tangent)))))))))))

(defun make-spherical-patch-mesh (policy projector placement)
  (let* ((columns (spherical-mesh-columns policy))
         (rows (spherical-mesh-rows policy))
         (row-width (1+ columns))
         (point-count (* row-width (1+ rows)))
         (projected-x (make-array point-count :element-type 'double-float))
         (projected-y (make-array point-count :element-type 'double-float))
         (visible (make-array point-count :element-type 'bit :initial-element 0))
         (vertices
           (make-array 0 :element-type 'double-float
                         :adjustable t :fill-pointer 0))
         (center-latitude (spherical-latitude placement))
         (longitude-scale (max 0.2d0 (cos center-latitude))))
    (dotimes (row (1+ rows))
      (let ((texture-y (/ (coerce row 'double-float) rows)))
        (dotimes (column (1+ columns))
          (let* ((texture-x (/ (coerce column 'double-float) columns))
                 (index (+ column (* row row-width)))
                 (longitude
                   (normalize-longitude
                    (+ (spherical-longitude placement)
                       (/ (* (- texture-x 0.5d0)
                             (spherical-angular-width placement))
                          longitude-scale))))
                 (latitude
                   (clamp-latitude
                    (+ center-latitude
                       (* (- 0.5d0 texture-y)
                          (spherical-angular-height placement))))))
            (multiple-value-bind (visible-p x y)
                (funcall projector longitude latitude)
              (when visible-p
                (setf (aref visible index) 1
                      (aref projected-x index) x
                      (aref projected-y index) y)))))))
    (labels ((texture-x (index)
               (/ (coerce (mod index row-width) 'double-float) columns))
             (texture-y (index)
               (/ (coerce (floor index row-width) 'double-float) rows))
             (emit (index)
               (vector-push-extend (aref projected-x index) vertices)
               (vector-push-extend (aref projected-y index) vertices)
               (vector-push-extend (texture-x index) vertices)
               (vector-push-extend (texture-y index) vertices))
             (emit-triangle (first second third)
               (when (and (= 1 (aref visible first))
                          (= 1 (aref visible second))
                          (= 1 (aref visible third)))
                 (emit first) (emit second) (emit third))))
      (dotimes (row rows)
        (dotimes (column columns)
          (let* ((top-left (+ column (* row row-width)))
                 (top-right (1+ top-left))
                 (bottom-left (+ top-left row-width))
                 (bottom-right (1+ bottom-left)))
            (emit-triangle top-left top-right bottom-right)
            (emit-triangle top-left bottom-right bottom-left)))))
    (unless (zerop (length vertices))
      (make-mesh-geometry vertices))))

(defun spherical-mesh-cache-key (policy output placement)
  (let ((camera (output-behavior-state output)))
    (list output
          (ataxia.runtime:output-width (output-native output))
          (ataxia.runtime:output-height (output-native output))
          (camera-longitude camera) (camera-latitude camera)
          (camera-field-of-view camera)
          (spherical-mesh-columns policy) (spherical-mesh-rows policy)
          (spherical-longitude placement) (spherical-latitude placement)
          (spherical-angular-width placement)
          (spherical-angular-height placement))))

(defun cached-spherical-patch-mesh
    (policy output projector placement)
  (let ((revision (behavior-policy-revision policy)))
    (unless (= revision (spherical-mesh-cache-revision policy))
      (clrhash (spherical-mesh-cache policy))
      (setf (spherical-mesh-cache-revision policy) revision))
    (let ((key (spherical-mesh-cache-key policy output placement)))
      (multiple-value-bind (geometry present-p)
          (gethash key (spherical-mesh-cache policy))
        (if present-p
            geometry
            (setf (gethash key (spherical-mesh-cache policy))
                  (make-spherical-patch-mesh
                   policy projector placement)))))))

(defun transform-mesh-geometry
    (geometry source-x source-y source-width source-height
     target-x target-y target-width target-height)
  (let* ((source (mesh-geometry-vertices geometry))
         (vertices (copy-seq source))
         (scale-x (/ target-width (max 1d-9 source-width)))
         (scale-y (/ target-height (max 1d-9 source-height))))
    (loop for offset from 0 below (length vertices) by 4
          do (setf (aref vertices offset)
                   (+ target-x
                      (* (- (aref source offset) source-x) scale-x))
                   (aref vertices (+ offset 1))
                   (+ target-y
                      (* (- (aref source (+ offset 1)) source-y) scale-y))))
    (make-mesh-geometry vertices)))

(defclass spherical-surface-mapping (presentation-mapping)
  ((output :initarg :output :reader spherical-mapping-output)
   (placement :initarg :placement
              :reader spherical-mapping-placement)
   (projector :initarg :projector
              :reader spherical-mapping-projector)
   (source-width :initarg :source-width
                 :reader spherical-mapping-source-width)
   (source-height :initarg :source-height
                  :reader spherical-mapping-source-height)
   (base-x :initarg :base-x :reader spherical-mapping-base-x)
   (base-y :initarg :base-y :reader spherical-mapping-base-y)
   (base-width :initarg :base-width
               :reader spherical-mapping-base-width)
   (base-height :initarg :base-height
                :reader spherical-mapping-base-height)
   (draw-x :initarg :draw-x :reader spherical-mapping-draw-x)
   (draw-y :initarg :draw-y :reader spherical-mapping-draw-y)
   (draw-width :initarg :draw-width
               :reader spherical-mapping-draw-width)
   (draw-height :initarg :draw-height
                 :reader spherical-mapping-draw-height)))

(defmethod map-presentation-point
    ((mapping spherical-surface-mapping) item output-x output-y)
  (declare (ignore mapping))
  (mesh-local-point
   (presentation-item-geometry item) output-x output-y
   (presentation-item-source-width item)
   (presentation-item-source-height item)))

(defstruct (spherical-view-scene
             (:constructor make-spherical-view-scene
                 (&key mapping content-geometry frame-geometry
                       title-geometry)))
  mapping content-geometry frame-geometry title-geometry)

(defun spherical-mapping-geometry (policy mapping)
  (let ((geometry
          (cached-spherical-patch-mesh
           policy (spherical-mapping-output mapping)
           (spherical-mapping-projector mapping)
           (spherical-mapping-placement mapping))))
    (when geometry
      (transform-mesh-geometry
       geometry
       (spherical-mapping-base-x mapping)
       (spherical-mapping-base-y mapping)
       (spherical-mapping-base-width mapping)
       (spherical-mapping-base-height mapping)
       (spherical-mapping-draw-x mapping)
       (spherical-mapping-draw-y mapping)
       (spherical-mapping-draw-width mapping)
       (spherical-mapping-draw-height mapping)))))

(defun derive-spherical-surface-mapping
    (parent offset-x offset-y source-width source-height)
  "Map a child surface through the same spherical patch and animation transform."
  (let* ((parent-placement (spherical-mapping-placement parent))
         (parent-width (max 1d0 (spherical-mapping-source-width parent)))
         (parent-height (max 1d0 (spherical-mapping-source-height parent)))
         (child-width (max 1d0 (coerce source-width 'double-float)))
         (child-height (max 1d0 (coerce source-height 'double-float)))
         (center-x (/ (+ (coerce offset-x 'double-float)
                         (/ child-width 2d0))
                      parent-width))
         (center-y (/ (+ (coerce offset-y 'double-float)
                         (/ child-height 2d0))
                      parent-height))
         (parent-latitude (spherical-latitude parent-placement))
         (longitude-span
           (/ (spherical-angular-width parent-placement)
              (max 0.2d0 (cos parent-latitude))))
         (latitude
           (clamp-latitude
            (+ parent-latitude
               (* (- 0.5d0 center-y)
                  (spherical-angular-height parent-placement)))))
         (placement
           (make-instance
            'spherical-placement
            :longitude
            (normalize-longitude
             (+ (spherical-longitude parent-placement)
                (* (- center-x 0.5d0) longitude-span)))
            :latitude latitude
            :angular-width
            (* longitude-span (/ child-width parent-width)
               (max 0.2d0 (cos latitude)))
            :angular-height
            (* (spherical-angular-height parent-placement)
               (/ child-height parent-height))
            :depth (spherical-depth parent-placement))))
    (make-instance
     'spherical-surface-mapping
     :output (spherical-mapping-output parent) :placement placement
     :projector (spherical-mapping-projector parent)
     :source-width child-width :source-height child-height
     :base-x (spherical-mapping-base-x parent)
     :base-y (spherical-mapping-base-y parent)
     :base-width (spherical-mapping-base-width parent)
     :base-height (spherical-mapping-base-height parent)
     :draw-x (spherical-mapping-draw-x parent)
     :draw-y (spherical-mapping-draw-y parent)
     :draw-width (spherical-mapping-draw-width parent)
     :draw-height (spherical-mapping-draw-height parent))))

(defun build-spherical-view-scene
    (policy output view titlebar-height)
  (let* ((record (view-surface view))
         (placement (view-placement view))
         (decorated-p
           (and (not (view-fullscreen-p view))
                (view-server-decorated-p view)))
         (title-angular-height
           (if decorated-p
               (* (spherical-angular-height placement)
                  (/ titlebar-height
                     (max 1d0 (coerce (view-height view) 'double-float))))
               0d0))
         (full-placement (copy-spherical-placement placement))
         (title-placement (copy-spherical-placement placement))
         (frame-placement (copy-spherical-placement placement))
         (border-angular-width
           (* (spherical-angular-width placement)
              (/ 4d0 (max 1d0 (coerce (view-width view) 'double-float)))))
         (border-angular-height
           (* (spherical-angular-height placement)
              (/ 4d0 (max 1d0 (coerce (view-height view) 'double-float))))))
    (setf (spherical-latitude full-placement)
          (clamp-latitude
           (+ (spherical-latitude placement) (/ title-angular-height 2d0)))
          (spherical-angular-height full-placement)
          (+ (spherical-angular-height placement) title-angular-height)
          (spherical-latitude title-placement)
          (clamp-latitude
           (+ (spherical-latitude placement)
              (/ (spherical-angular-height placement) 2d0)
              (/ title-angular-height 2d0)))
          (spherical-angular-height title-placement) title-angular-height
          (spherical-latitude frame-placement)
          (spherical-latitude full-placement)
          (spherical-angular-width frame-placement)
          (+ (spherical-angular-width full-placement) border-angular-width)
          (spherical-angular-height frame-placement)
          (+ (spherical-angular-height full-placement) border-angular-height))
    (let* ((projector
             (make-spherical-projector
              (output-behavior-state output) output))
           (content-geometry
             (cached-spherical-patch-mesh
              policy output projector placement))
           (frame-geometry
             (cached-spherical-patch-mesh
              policy output projector frame-placement))
           (title-geometry
             (and decorated-p
                  (cached-spherical-patch-mesh
                   policy output projector title-placement))))
      (when (and content-geometry frame-geometry
                 (or (not decorated-p) title-geometry))
        (multiple-value-bind (base-x base-y base-width base-height)
            (mesh-geometry-bounds frame-geometry)
          (multiple-value-bind (draw-x draw-y draw-width draw-height)
              (scaled-view-geometry
               base-x base-y base-width base-height
               (view-presentation-state view))
            (let* ((mapping
                     (make-instance
                      'spherical-surface-mapping
                      :output output :placement placement :projector projector
                      :source-width
                      (max 1d0
                           (coerce (surface-record-width record)
                                   'double-float))
                      :source-height
                      (max 1d0
                           (coerce (surface-record-height record)
                                   'double-float))
                      :base-x base-x :base-y base-y
                      :base-width base-width :base-height base-height
                      :draw-x draw-x :draw-y draw-y
                      :draw-width draw-width :draw-height draw-height))
                   (mapped-content
                     (spherical-mapping-geometry policy mapping))
                   (mapped-frame
                     (transform-mesh-geometry
                      frame-geometry base-x base-y base-width base-height
                      draw-x draw-y draw-width draw-height))
                   (mapped-title
                     (and title-geometry
                          (transform-mesh-geometry
                           title-geometry base-x base-y
                           base-width base-height
                           draw-x draw-y draw-width draw-height))))
              (when mapped-content
                (make-spherical-view-scene
                 :mapping mapping :content-geometry mapped-content
                 :frame-geometry mapped-frame
                 :title-geometry mapped-title)))))))))

(defun spherical-owner-opacity (owner)
  (let ((view (typecase owner
                (view owner)
                (popup-view (popup-parent-view owner)))))
    (if view
        (presentation-opacity (view-presentation-state view))
        1d0)))

(defun make-spherical-surface-item
    (policy owner record mapping hit-kind &optional geometry)
  (let ((geometry (or geometry (spherical-mapping-geometry policy mapping))))
    (when (and geometry (surface-record-texture record))
      (multiple-value-bind (x y width height)
          (mesh-geometry-bounds geometry)
        (multiple-value-bind (shader-name shader-uniforms)
            (presentation-shader-values owner)
          (make-surface-item
           (surface-record-native record) x y width height
           (ataxia.runtime:texture-gles-attributes
            (surface-record-texture record))
           :owner owner :geometry geometry :mapping mapping
           :program-name shader-name :uniforms shader-uniforms
           :opacity (spherical-owner-opacity owner)
           :interactive-p t :hit-kind hit-kind
           :source-width (max 1 (surface-record-width record))
           :source-height (max 1 (surface-record-height record))))))))

(defun append-spherical-subsurface-tree-items
    (policy items compositor parent-surface owner parent-mapping)
  (let ((surfaces (compositor-surfaces compositor)))
    (dolist (subsurface
              (surface-child-subsurfaces surfaces parent-surface) items)
      (let* ((surface (ataxia.runtime:subsurface-surface subsurface))
             (record (gethash surface (surface-records surfaces))))
        (when (and record (surface-record-mapped-p record)
                   (surface-record-texture record))
          (let* ((mapping
                   (derive-spherical-surface-mapping
                    parent-mapping
                    (ataxia.runtime:subsurface-x subsurface)
                    (ataxia.runtime:subsurface-y subsurface)
                    (surface-record-width record)
                    (surface-record-height record)))
                 (item
                   (make-spherical-surface-item
                    policy owner record mapping :subsurface)))
            (when item
              (setf items (nconc items (list item))
                    items
                    (append-spherical-subsurface-tree-items
                     policy items compositor surface owner mapping)))))))))

(defmethod behavior-build-view-items
    ((policy spherical-behavior-policy) items output view timestamp
     titlebar-height)
  (declare (ignore timestamp))
  (let ((record (view-surface view)))
    (when (and (view-mapped-p view) (not (view-minimized-p view))
               (view-presentable-p view) (surface-record-texture record))
      (let ((scene
              (build-spherical-view-scene
               policy output view titlebar-height)))
        (when scene
          (let ((frame-geometry (spherical-view-scene-frame-geometry scene))
                (title-geometry (spherical-view-scene-title-geometry scene)))
            (multiple-value-bind (frame-x frame-y frame-width frame-height)
                (mesh-geometry-bounds frame-geometry)
              (setf items
                    (nconc
                     items
                     (append
                      (unless (view-fullscreen-p view)
                        (make-soft-shadow-items
                         policy view frame-x frame-y
                         frame-width frame-height))
                      (when title-geometry
                        (multiple-value-bind
                              (title-x title-y title-width title-height)
                            (mesh-geometry-bounds title-geometry)
                          (list
                           (make-solid-item
                            frame-x frame-y frame-width frame-height
                            '(0.12 0.15 0.21 1.0) :owner view
                            :interactive-p t :hit-kind :frame
                            :geometry frame-geometry)
                           (make-solid-item
                            title-x title-y title-width title-height
                            '(0.095 0.12 0.18 1.0) :owner view
                            :interactive-p t :hit-kind :titlebar
                            :geometry title-geometry)))))))
              (let ((item
                      (make-spherical-surface-item
                       policy view record
                       (spherical-view-scene-mapping scene) :content
                       (spherical-view-scene-content-geometry scene))))
                (when item
                  (setf items (nconc items (list item))
                        items
                        (append-spherical-subsurface-tree-items
                         policy items (component-compositor policy)
                         (surface-record-native record) view
                         (spherical-view-scene-mapping scene)))))))))))
  items)

(defun append-spherical-popup-tree-items
    (policy items desktop parent)
  (dolist (popup (desktop-popups desktop) items)
    (when (and (eq parent (popup-parent popup)) (popup-mapped-p popup))
      (let* ((record (popup-surface popup))
             (parent-surface
               (typecase parent
                 (view (surface-record-native (view-surface parent)))
                 (popup-view
                  (surface-record-native (popup-surface parent)))))
             (parent-item
               (find-surface-presentation-item items parent-surface))
             (parent-mapping
               (and parent-item (presentation-item-mapping parent-item))))
        (when (and (typep parent-mapping 'spherical-surface-mapping)
                   (surface-record-texture record))
          (let* ((mapping
                   (derive-spherical-surface-mapping
                    parent-mapping (popup-x popup) (popup-y popup)
                    (surface-record-width record)
                    (surface-record-height record)))
                 (item
                   (make-spherical-surface-item
                    policy popup record mapping :popup)))
            (when item
              (setf items (nconc items (list item))
                    items
                    (append-spherical-subsurface-tree-items
                     policy items (component-compositor desktop)
                     (surface-record-native record) popup mapping)
                    items
                    (append-spherical-popup-tree-items
                     policy items desktop popup)))))))))

(defmethod behavior-build-popup-items
    ((policy spherical-behavior-policy) items desktop output timestamp)
  (declare (ignore output timestamp))
  (dolist (view (desktop-stacking-order desktop) items)
    (setf items
          (append-spherical-popup-tree-items policy items desktop view))))

(defmethod behavior-begin-operation
    ((policy spherical-behavior-policy) interaction seat view kind edges button)
  (declare (ignore interaction policy))
  (let ((output (seat-pointer-output seat)))
    (multiple-value-bind (start-x start-y)
        (seat-pointer-local-position seat output)
      (make-instance
       'interactive-operation :kind kind :seat seat :view view
       :output output :edges edges :button button
       :start-x start-x :start-y start-y
       :original-width (view-width view)
       :original-height (view-height view)
       :original-placement (copy-spherical-placement (view-placement view))))))

(defun spherical-operation-output (operation)
  (interactive-operation-output operation))

(defun update-spherical-move (policy operation)
  (let* ((output (spherical-operation-output operation))
         (camera (and output (output-behavior-state output)))
         (seat (interactive-operation-seat operation))
         (original (interactive-operation-original-placement operation))
         (placement (view-placement (interactive-operation-view operation))))
    (when output
      (multiple-value-bind (start-longitude start-latitude)
          (behavior-unproject-point
           policy output camera
           (interactive-operation-start-x operation)
           (interactive-operation-start-y operation))
        (multiple-value-bind (current-x current-y)
            (output-local-position output (seat-pointer-x seat) (seat-pointer-y seat))
          (multiple-value-bind (current-longitude current-latitude)
              (behavior-unproject-point
               policy output camera current-x current-y)
            (setf (spherical-longitude placement)
                  (normalize-longitude
                   (+ (spherical-longitude original)
                      (normalize-longitude
                       (- current-longitude start-longitude))))
                  (spherical-latitude placement)
                  (clamp-latitude
                   (+ (spherical-latitude original)
                      (- current-latitude start-latitude))))))))
    (incf (behavior-policy-revision policy))
    nil))

(defun update-spherical-resize (policy operation)
  (let* ((output (spherical-operation-output operation))
         (seat (interactive-operation-seat operation))
         (view (interactive-operation-view operation))
         (original (interactive-operation-original-placement operation))
         (edges (interactive-operation-edges operation))
         (current-x (and output
                         (- (seat-pointer-x seat) (output-layout-x output))))
         (current-y (and output
                         (- (seat-pointer-y seat) (output-layout-y output))))
         (delta-x (- (or current-x (interactive-operation-start-x operation))
                     (interactive-operation-start-x operation)))
         (delta-y (- (or current-y (interactive-operation-start-y operation))
                     (interactive-operation-start-y operation)))
         (width-delta
           (cond ((logtest +resize-edge-left+ edges) (- delta-x))
                 ((logtest +resize-edge-right+ edges) delta-x)
                 (t 0d0)))
         (height-delta
           (cond ((logtest +resize-edge-top+ edges) (- delta-y))
                 ((logtest +resize-edge-bottom+ edges) delta-y)
                 (t 0d0)))
         (original-width
           (coerce (interactive-operation-original-width operation)
                   'double-float))
         (original-height
           (coerce (interactive-operation-original-height operation)
                   'double-float))
         (new-width (max 120d0 (+ original-width width-delta)))
         (new-height (max 80d0 (+ original-height height-delta)))
         (placement (view-placement view)))
    (when output
      (setf (spherical-angular-width placement)
            (max 0.12d0
                 (* (spherical-angular-width original)
                    (/ new-width (max 1d0 original-width))))
            (spherical-angular-height placement)
            (max 0.12d0
                 (* (spherical-angular-height original)
                    (/ new-height (max 1d0 original-height))))))
    (incf (behavior-policy-revision policy))
    (make-instance 'view-configuration-decision
                   :width new-width :height new-height)))

(defmethod behavior-update-operation
    ((policy spherical-behavior-policy) interaction
     (operation interactive-operation))
  (declare (ignore interaction))
  (ecase (interactive-operation-kind operation)
    (:move (update-spherical-move policy operation))
    (:resize (update-spherical-resize policy operation))))

(defmethod behavior-move-view
    ((policy spherical-behavior-policy) view longitude latitude context)
  (declare (ignore context))
  (let ((placement (view-placement view)))
    (check-type placement spherical-placement)
    (setf (spherical-longitude placement) (normalize-longitude longitude)
          (spherical-latitude placement) (clamp-latitude latitude))
    (incf (behavior-policy-revision policy))
    placement))

(defmethod behavior-restore-view
    ((policy spherical-behavior-policy) compositor view)
  (declare (ignore compositor))
  (let ((restore (view-restore-placement view)))
    (when restore
      (setf (view-placement view) (spherical-restore-placement restore)
            (view-restore-placement view) nil))
    (incf (behavior-policy-revision policy))
    (make-instance 'view-configuration-decision
                   :width (if restore
                              (spherical-restore-width restore)
                              (view-width view))
                   :height (if restore
                               (spherical-restore-height restore)
                               (view-height view)))))

(defmethod behavior-configure-view-for-output
    ((policy spherical-behavior-policy) compositor view output fullscreen-p)
  (let ((output (or output (first-policy-output policy))))
    (if (null output)
        (make-instance 'view-configuration-decision
                       :width (view-width view) :height (view-height view))
        (let* ((camera (output-behavior-state output))
               (placement (view-placement view))
               (panel (if fullscreen-p 0d0
                          (presentation-panel-height
                           (compositor-presentation compositor))))
               (titlebar (if (or fullscreen-p
                                 (not (view-server-decorated-p view)))
                             0d0
                             (presentation-titlebar-height
                              (compositor-presentation compositor))))
               (width (ataxia.runtime:output-width (output-native output)))
               (height (- (ataxia.runtime:output-height (output-native output))
                          panel titlebar)))
          (unless (view-restore-placement view)
            (setf (view-restore-placement view)
                  (make-instance
                   'spherical-restore-state
                   :placement (copy-spherical-placement placement)
                   :width (view-width view) :height (view-height view))))
          (setf (spherical-longitude placement) (camera-longitude camera)
                (spherical-latitude placement) (camera-latitude camera)
                (spherical-angular-width placement)
                (* 0.9d0 (camera-field-of-view camera))
                (spherical-angular-height placement)
                (* 0.9d0 (spherical-vertical-field-of-view camera output)))
          (incf (behavior-policy-revision policy))
          (make-instance 'view-configuration-decision
                         :width width :height height)))))

(defmethod behavior-pan-output
    ((policy spherical-behavior-policy) output delta-x delta-y)
  (let ((camera (output-behavior-state output)))
    (setf (camera-longitude camera)
          (normalize-longitude (+ (camera-longitude camera) delta-x))
          (camera-latitude camera)
          (clamp-latitude (+ (camera-latitude camera) delta-y)))
    (incf (behavior-policy-revision policy))
    camera))

(defmethod behavior-zoom-output
    ((policy spherical-behavior-policy) output factor anchor-x anchor-y)
  (let ((camera (output-behavior-state output)))
    (multiple-value-bind (anchor-longitude anchor-latitude)
        (behavior-unproject-point
         policy output camera anchor-x anchor-y)
      (setf (camera-field-of-view camera)
            (max 0.35d0
                 (min 2.7d0 (/ (camera-field-of-view camera) factor))))
      (multiple-value-bind (new-longitude new-latitude)
          (behavior-unproject-point
           policy output camera anchor-x anchor-y)
        (setf (camera-longitude camera)
              (normalize-longitude
               (+ (camera-longitude camera)
                  (normalize-longitude
                   (- anchor-longitude new-longitude))))
              (camera-latitude camera)
              (clamp-latitude
               (+ (camera-latitude camera)
                  (- anchor-latitude new-latitude))))))
    (incf (behavior-policy-revision policy))
    camera))

(defmethod behavior-observe-output
    ((policy spherical-behavior-policy) output)
  (declare (ignore policy))
  (let ((camera (output-behavior-state output)))
    (list :longitude (camera-longitude camera)
          :latitude (camera-latitude camera)
          :field-of-view (camera-field-of-view camera))))

(defmethod behavior-observe-view
    ((policy spherical-behavior-policy) view)
  (declare (ignore policy))
  (let ((placement (view-placement view)))
    (list :longitude (spherical-longitude placement)
          :latitude (spherical-latitude placement)
          :angular-width (spherical-angular-width placement)
          :angular-height (spherical-angular-height placement)
          :depth (spherical-depth placement))))
