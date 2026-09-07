(in-package #:ataxia.infinite-world)

(defstruct (%meta-trajectory (:constructor %make-meta-trajectory))
  origin destination velocity)

(defun %meta-cancel-motion (world subject channel)
  ;; Cancellation freezes the last displayed sample; it never applies a target.
  (ataxia.world:cancel-animation (%world-animator world) subject channel)
  (remhash subject (%meta-motions world)))

(defun %meta-motion-sample (origin destination velocity duration progress)
  "Cubic Hermite motion with a stationary endpoint and bounded initial velocity."
  (let* ((p (coerce progress 'double-float)) (p2 (* p p)) (p3 (* p2 p)))
    (values
     (mapcar (lambda (a b v)
               (+ a (* (- b a) (- (* 3d0 p2) (* 2d0 p3)))
                  (* duration v (+ p (- (* 2d0 p2)) p3))))
             origin destination velocity)
     (mapcar (lambda (a b v)
               (+ (/ (* (- b a) (- (* 6d0 p) (* 6d0 p2))) duration)
                  (* v (+ 1d0 (- (* 4d0 p)) (* 3d0 p2)))))
             origin destination velocity))))

(defun %meta-animate-to (world subject channel origin destination duration update)
  (let ((previous (gethash subject (%meta-motions world))))
    (when (and previous (equalp destination (%meta-trajectory-destination previous)))
      (return-from %meta-animate-to subject))
    (let* ((velocity
             (mapcar (lambda (a b v)
                       ;; A reversal brakes at the displayed position. The bound
                       ;; keeps sizes/zoom positive and prevents overshooting.
                       (let ((limit (/ (* 3d0 (- b a)) duration)))
                         (if (plusp limit) (max 0d0 (min limit v))
                             (min 0d0 (max limit v)))))
                     origin destination
                     (if previous (%meta-trajectory-velocity previous)
                         (mapcar (constantly 0d0) origin))))
           (motion (%make-meta-trajectory :origin (copy-list origin) :destination (copy-list destination) :velocity velocity)))
      (setf (gethash subject (%meta-motions world)) motion)
      (ataxia.world:start-animation
       (%world-animator world) subject channel (%now) duration
       (lambda (target progress)
         (multiple-value-bind (geometry speed)
             (%meta-motion-sample (%meta-trajectory-origin motion) (%meta-trajectory-destination motion)
                                  velocity duration progress)
           (setf (%meta-trajectory-velocity motion) speed)
           (funcall update target geometry)))
       :finish (lambda (target)
                 (funcall update target (%meta-trajectory-destination motion))
                 (when (eq motion (gethash subject (%meta-motions world)))
                   (remhash subject (%meta-motions world)))))
      (%request-all-frames world)))
  subject)

(defun %meta-target-geometry (world object)
  (let ((motion (gethash object (%meta-motions world))))
    (if motion (%meta-trajectory-destination motion) (%meta-object-geometry object))))
