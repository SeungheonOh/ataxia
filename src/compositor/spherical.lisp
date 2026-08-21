;;;; Spherical Layer 2 behavior policy.
;;;;
;;;; Views occupy angular patches on a unit sphere. A per-output camera projects
;;;; those patches into the same immutable rectangles used for drawing and input.

(in-package #:ataxia.compositor)

(defconstant +two-pi+ (* 2d0 pi))
(defconstant +half-pi+ (/ pi 2d0))

(defclass spherical-placement (world-placement)
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
  ((next-longitude :initform -0.65d0
                   :accessor spherical-next-longitude)
   (next-latitude :initform 0.35d0
                  :accessor spherical-next-latitude)
   (next-depth :initform 0d0 :accessor spherical-next-depth)))

(defun normalize-longitude (longitude)
  (- (mod (+ (coerce longitude 'double-float) pi) +two-pi+) pi))

(defun clamp-latitude (latitude)
  (max (- +half-pi+ 0.02d0)
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
   :animation-policy (behavior-state-animation-policy state)
   :shader-program-name (behavior-state-shader-program-name state)
   :presentation-state
   (copy-presentation-state (behavior-state-presentation-state state))))

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
  (let* ((angular-width 0.78d0)
         (placement
           (make-instance
            'spherical-placement
            :longitude (spherical-next-longitude policy)
            :latitude (spherical-next-latitude policy)
            :angular-width angular-width
            :angular-height
            (spherical-aspect-angular-height view angular-width)
            :depth (incf (spherical-next-depth policy)))))
    (incf (spherical-next-longitude policy) 0.42d0)
    (when (> (spherical-next-longitude policy) 0.9d0)
      (setf (spherical-next-longitude policy) -0.65d0)
      (decf (spherical-next-latitude policy) 0.32d0))
    (when (< (spherical-next-latitude policy) -0.55d0)
      (setf (spherical-next-latitude policy) 0.35d0))
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

(defmethod behavior-build-view-items
    ((policy spherical-behavior-policy) items output view timestamp
     titlebar-height)
  (let ((record (view-surface view)))
    (when (and (view-mapped-p view) (not (view-minimized-p view))
               (view-presentable-p view) (surface-record-texture record))
      (multiple-value-bind (x y width content-height)
          (behavior-project-view
           policy output (output-behavior-state output) view timestamp)
        (when (and (plusp width) (plusp content-height)
                   (< x (ataxia.runtime:output-width (output-native output)))
                   (< y (ataxia.runtime:output-height (output-native output)))
                   (> (+ x width) 0d0) (> (+ y content-height) 0d0))
          (let* ((title-height
                   (if (or (view-fullscreen-p view)
                           (not (view-server-decorated-p view)))
                       0d0 titlebar-height))
                 (total-height (+ content-height title-height)))
            (multiple-value-bind (draw-x draw-y draw-width draw-height)
                (scaled-view-geometry
                 x y width total-height (view-presentation-state view))
              (let* ((scale (/ draw-width width))
                     (draw-title-height (* title-height scale))
                     (draw-content-y (+ draw-y draw-title-height))
                     (draw-content-height (- draw-height draw-title-height))
                     (opacity
                       (presentation-opacity (view-presentation-state view))))
                (multiple-value-bind (shader-name shader-uniforms)
                    (presentation-shader-values view)
                  (setf items
                        (nconc
                         items
                         (append
                          (unless (view-fullscreen-p view)
                            (list
                             (make-shadow-item
                              (- draw-x 24d0) (- draw-y 24d0)
                              (+ draw-width 48d0) (+ draw-height 48d0)
                              '(0.0 0.0 0.0 0.42) 24d0 12d0 8d0
                              :owner view)))
                          (when (and (not (view-fullscreen-p view))
                                     (view-server-decorated-p view))
                            (list
                             (make-solid-item
                              (- draw-x 2d0) (- draw-y 2d0)
                              (+ draw-width 4d0) (+ draw-height 4d0)
                              '(0.12 0.15 0.21 1.0) :owner view
                              :interactive-p t :hit-kind :frame)
                             (make-solid-item
                              draw-x draw-y draw-width draw-title-height
                              '(0.095 0.12 0.18 1.0) :owner view
                              :interactive-p t :hit-kind :titlebar)))
                          (list
                           (make-instance
                            'presentation-item :kind :surface :owner view
                            :surface (surface-record-native record)
                            :x draw-x :y draw-content-y
                            :width draw-width :height draw-content-height
                            :texture
                            (ataxia.runtime:texture-gles-attributes
                             (surface-record-texture record))
                            :shader-program-name shader-name
                            :shader-uniforms shader-uniforms
                            :opacity opacity :interactive-p t
                            :hit-kind :content
                            :source-width
                            (max 1 (surface-record-width record))
                            :source-height
                            (max 1 (surface-record-height record))))))))
                (setf items
                      (append-subsurface-tree-items
                       items (component-compositor policy)
                       (surface-record-native record) view
                       draw-x draw-content-y
                       (/ draw-width
                          (max 1d0
                               (coerce (surface-record-width record)
                                       'double-float)))
                       (/ draw-content-height
                          (max 1d0
                               (coerce (surface-record-height record)
                                       'double-float))))))))))))
  items)

(defmethod behavior-begin-operation
    ((policy spherical-behavior-policy) interaction seat view kind edges button)
  (declare (ignore interaction))
  (make-instance
   'interactive-operation :kind kind :seat seat :view view
   :edges edges :button button
   :start-x (seat-pointer-x seat) :start-y (seat-pointer-y seat)
   :original-width (view-width view)
   :original-height (view-height view)
   :original-placement (copy-spherical-placement (view-placement view))))

(defun spherical-operation-output (policy)
  (first-policy-output policy))

(defun update-spherical-move (policy operation)
  (let* ((output (spherical-operation-output policy))
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
        (multiple-value-bind (current-longitude current-latitude)
            (behavior-unproject-point
             policy output camera (seat-pointer-x seat) (seat-pointer-y seat))
          (setf (spherical-longitude placement)
                (normalize-longitude
                 (+ (spherical-longitude original)
                    (normalize-longitude
                     (- current-longitude start-longitude))))
                (spherical-latitude placement)
                (clamp-latitude
                 (+ (spherical-latitude original)
                    (- current-latitude start-latitude)))))))
    (incf (behavior-policy-revision policy))
    nil))

(defun update-spherical-resize (policy operation)
  (let* ((output (spherical-operation-output policy))
         (seat (interactive-operation-seat operation))
         (view (interactive-operation-view operation))
         (original (interactive-operation-original-placement operation))
         (edges (interactive-operation-edges operation))
         (delta-x (- (seat-pointer-x seat)
                     (interactive-operation-start-x operation)))
         (delta-y (- (seat-pointer-y seat)
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
    ((policy spherical-behavior-policy) compositor view fullscreen-p)
  (let ((output (first-policy-output policy)))
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
