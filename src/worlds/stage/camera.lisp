;;;; Per-output cameras.
;;;;
;;;; A camera is compositor state, not a scene node. Direct manipulation moves
;;;; it in the same frame as the input, without a director round trip, and it
;;;; survives remounts, reloads and director restarts. <Camera> nodes declare
;;;; targets, zoom limits and the transition for programmatic moves; the
;;;; director observes the camera through coalesced reports of its targets.

(in-package #:ataxia.stage-world)

(defparameter +camera-motion+ (make-motion :spring :stiffness 195d0 :damping 25.7d0)
  "Programmatic moves when no camera node declares a transition.")
(defparameter +wheel-zoom-motion+ (make-motion :tween :duration 0.14d0 :ease '(0d0 0d0 0.58d0 1d0))
  "Short glide between discrete wheel steps; continuous input zooms instantly.")
(defparameter +fling-time-constant+ 0.25d0)

(defstruct (stage-camera (:constructor make-stage-camera))
  (x (make-channel 0d0 1d-2) :read-only t)
  (y (make-channel 0d0 1d-2) :read-only t)
  ;; Natural logarithm of the zoom factor, so zoom animates at an even pace.
  (zoom (make-channel 0d0 1d-4) :read-only t)
  (rotation (make-channel 0d0 1d-4) :read-only t)
  (min-zoom 0.05d0 :type double-float)
  (max-zoom 8d0 :type double-float)
  (motion nil)
  ;; Values last applied from camera nodes, to apply only changed declarations.
  (declared nil :type list)
  ;; (WORLD-X WORLD-Y SCREEN-X SCREEN-Y) held fixed while zoom animates.
  (anchor nil :type list)
  ;; An unplaced camera maps world coordinates to output pixels.
  (placed-p nil)
  (reported nil :type list))

(defun camera-zoom (camera)
  (exp (channel-value (stage-camera-zoom camera))))

(defun %camera-viewport (stage-output)
  (ataxia.world:output-logical-size (stage-output-output stage-output)))

(defun camera-transform (stage-output)
  "Map world space to STAGE-OUTPUT's logical pixels."
  (let ((camera (stage-output-camera stage-output)))
    (multiple-value-bind (width height) (%camera-viewport stage-output)
      (camera-affine (channel-value (stage-camera-x camera)) (channel-value (stage-camera-y camera))
                     (camera-zoom camera) (channel-value (stage-camera-rotation camera))
                     width height))))

(defun screen-to-world (stage-output x y)
  (let ((inverse (affine-invert (camera-transform stage-output))))
    (if inverse (affine-apply inverse x y) (values x y))))

(defun %world-delta (camera dx dy zoom)
  "World-space displacement shown as the screen-space (DX, DY) at ZOOM."
  (let ((rotation (channel-value (stage-camera-rotation camera))))
    (values (/ (- (* (cos rotation) dx) (* (sin rotation) dy)) zoom)
            (/ (+ (* (sin rotation) dx) (* (cos rotation) dy)) zoom))))

(defun %anchored-center (camera stage-output zoom)
  "Camera center keeping the anchor's world point under its screen point at ZOOM."
  (destructuring-bind (world-x world-y screen-x screen-y) (stage-camera-anchor camera)
    (multiple-value-bind (width height) (%camera-viewport stage-output)
      (multiple-value-bind (dx dy)
          (%world-delta camera (- screen-x (/ width 2d0)) (- screen-y (/ height 2d0)) zoom)
        (values (- world-x dx) (- world-y dy))))))

(defun %follow-anchor (camera stage-output)
  "Keep the anchor under its screen point now, aiming x/y where it holds at the zoom target."
  (let ((x (stage-camera-x camera))
        (y (stage-camera-y camera)))
    (multiple-value-bind (now-x now-y) (%anchored-center camera stage-output (camera-zoom camera))
      (channel-jump x now-x)
      (channel-jump y now-y))
    (multiple-value-bind (target-x target-y)
        (%anchored-center camera stage-output (exp (channel-target (stage-camera-zoom camera))))
      (setf (channel-target x) target-x
            (channel-target y) target-y))))

(defun camera-sample (stage-output time)
  "Advance STAGE-OUTPUT's camera to TIME."
  (let* ((camera (stage-output-camera stage-output))
         (zooming-p (channel-sample (stage-camera-zoom camera) time)))
    (channel-sample (stage-camera-rotation camera) time)
    (cond ((stage-camera-anchor camera)
           (%follow-anchor camera stage-output)
           (unless zooming-p (setf (stage-camera-anchor camera) nil)))
          (t (channel-sample (stage-camera-x camera) time)
             (channel-sample (stage-camera-y camera) time)))))

(defun camera-moving-p (stage-output)
  (let ((camera (stage-output-camera stage-output)))
    (or (channel-active-p (stage-camera-x camera)) (channel-active-p (stage-camera-y camera))
        (channel-active-p (stage-camera-zoom camera))
        (channel-active-p (stage-camera-rotation camera)))))

(defun %clamp-zoom (camera zoom)
  (max (stage-camera-min-zoom camera) (min (stage-camera-max-zoom camera) zoom)))

(defun center-unplaced-camera (stage-output)
  "Keep an unplaced camera mapping world coordinates to output pixels."
  (let ((camera (stage-output-camera stage-output)))
    (unless (stage-camera-placed-p camera)
      (multiple-value-bind (width height) (%camera-viewport stage-output)
        (channel-jump (stage-camera-x camera) (/ width 2d0))
        (channel-jump (stage-camera-y camera) (/ height 2d0))))))

(defun camera-move (stage-output &key x y zoom rotation motion (time (%now)))
  "Retarget the camera; NIL arguments keep their current destination."
  (let* ((camera (stage-output-camera stage-output))
         (motion (or motion (stage-camera-motion camera) +camera-motion+)))
    (setf (stage-camera-anchor camera) nil
          (stage-camera-placed-p camera) t)
    (when x (channel-retarget (stage-camera-x camera) x motion time))
    (when y (channel-retarget (stage-camera-y camera) y motion time))
    (when zoom
      (channel-retarget (stage-camera-zoom camera) (log (%clamp-zoom camera zoom)) motion time))
    (when rotation (channel-retarget (stage-camera-rotation camera) rotation motion time))
    camera))

(defun camera-pan (stage-output dx dy)
  "Move the camera so content follows a screen-space drag of (DX, DY)."
  (let ((camera (stage-output-camera stage-output)))
    (setf (stage-camera-placed-p camera) t)
    (if (stage-camera-anchor camera)
        ;; Panning during a zoom moves the anchor's screen point with the content.
        (destructuring-bind (world-x world-y screen-x screen-y) (stage-camera-anchor camera)
          (setf (stage-camera-anchor camera) (list world-x world-y (+ screen-x dx) (+ screen-y dy)))
          (%follow-anchor camera stage-output))
        (multiple-value-bind (world-dx world-dy) (%world-delta camera dx dy (camera-zoom camera))
          (channel-jump (stage-camera-x camera) (- (channel-value (stage-camera-x camera)) world-dx))
          (channel-jump (stage-camera-y camera) (- (channel-value (stage-camera-y camera)) world-dy))))
    camera))

(defun camera-fling (stage-output velocity-x velocity-y &optional (time (%now)))
  "Let the camera coast after a pan released with a screen-space velocity."
  (let* ((camera (stage-output-camera stage-output))
         (zoom (camera-zoom camera)))
    ;; Coast until less than half a screen pixel remains.
    (unless (stage-camera-anchor camera)
      (multiple-value-bind (world-x world-y) (%world-delta camera velocity-x velocity-y zoom)
        (channel-fling (stage-camera-x camera) (- world-x) +fling-time-constant+ (/ 0.5d0 zoom) time)
        (channel-fling (stage-camera-y camera) (- world-y) +fling-time-constant+ (/ 0.5d0 zoom) time)))
    camera))

(defun camera-zoom-at (stage-output factor screen-x screen-y &key motion (time (%now)))
  "Scale the zoom target by FACTOR around an output-logical point."
  (let* ((camera (stage-output-camera stage-output))
         (zoom-channel (stage-camera-zoom camera))
         (target (%clamp-zoom camera (* (exp (channel-target zoom-channel)) factor))))
    (channel-sample zoom-channel time)
    (unless (and (stage-camera-anchor camera)
                 (= screen-x (third (stage-camera-anchor camera)))
                 (= screen-y (fourth (stage-camera-anchor camera))))
      (multiple-value-bind (world-x world-y) (screen-to-world stage-output screen-x screen-y)
        (setf (stage-camera-anchor camera) (list world-x world-y screen-x screen-y))))
    (setf (stage-camera-placed-p camera) t)
    (channel-retarget zoom-channel (log target) motion time)
    (%follow-anchor camera stage-output)
    (unless (channel-active-p zoom-channel)
      (setf (stage-camera-anchor camera) nil))
    camera))

(defun apply-camera-node (stage-output node time)
  "Apply a camera node's limits and any declared values that changed."
  (let ((camera (stage-output-camera stage-output))
        (declared (loop for key in '(:x :y :zoom :rotation)
                        when (node-declared-p node key)
                          append (list key (node-prop node key)))))
    (setf (stage-camera-min-zoom camera) (max 1d-4 (node-number node :min-zoom 0.05d0))
          (stage-camera-max-zoom camera) (max (stage-camera-min-zoom camera)
                                              (min 1d4 (node-number node :max-zoom 8d0)))
          (stage-camera-motion camera) (node-motion node :default))
    (let ((changed (loop for (key value) on declared by #'cddr
                         unless (eql value (getf (stage-camera-declared camera) key :none))
                           append (list key value))))
      (setf (stage-camera-declared camera) declared)
      (when changed
        ;; The first placement is immediate; later declarations animate.
        (apply #'camera-move stage-output :time time
               :motion (if (stage-camera-placed-p camera) nil (make-motion :instant))
               changed)))))

(defun camera-report (stage-output)
  "Report fields for STAGE-OUTPUT's camera destination, or NIL when unchanged."
  (let* ((camera (stage-output-camera stage-output))
         (report (list :output (%output-name stage-output)
                       :x (channel-target (stage-camera-x camera))
                       :y (channel-target (stage-camera-y camera))
                       :zoom (exp (channel-target (stage-camera-zoom camera)))
                       :rotation (channel-target (stage-camera-rotation camera)))))
    (unless (equal report (stage-camera-reported camera))
      (setf (stage-camera-reported camera) report))))
