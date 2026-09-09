(in-package #:ataxia.infinite-world)

(defstruct (%meta-trajectory (:constructor %make-meta-trajectory))
  origin destination velocity acceleration)

(defun %meta-motion (world subject channel)
  (cdr (assoc channel (gethash subject (%meta-motions world)))))

(defun (setf %meta-motion) (motion world subject channel)
  (let ((entry (assoc channel (gethash subject (%meta-motions world)))))
    (if entry (setf (cdr entry) motion)
        (push (cons channel motion) (gethash subject (%meta-motions world)))))
  motion)

(defun %meta-forget-motion (world subject channel)
  (let ((remaining (remove channel (gethash subject (%meta-motions world)) :key #'car)))
    (if remaining (setf (gethash subject (%meta-motions world)) remaining)
        (remhash subject (%meta-motions world)))))

(defun %meta-cancel-motion (world subject channel)
  ;; Cancellation freezes the last displayed sample; it never applies a target.
  (ataxia.world:cancel-animation (%world-animator world) subject channel)
  (%meta-forget-motion world subject channel))

(defun %meta-motion-sample (origin destination velocity duration progress
                            &optional acceleration)
  "Quintic motion preserving initial velocity/acceleration and settling at rest."
  (let ((p (max 0d0 (min 1d0 (coerce progress 'double-float))))
        (positions nil) (speeds nil) (accelerations nil))
    (loop for a in origin for b in destination for v in velocity
          for index from 0
          for initial-acceleration = (if acceleration (nth index acceleration) 0d0)
          for d = (- b a)
          for vt = (* v duration)
          for at2 = (* initial-acceleration duration duration)
          for c3 = (- (* 10d0 d) (* 6d0 vt) (* 1.5d0 at2))
          for c4 = (+ (* -15d0 d) (* 8d0 vt) (* 1.5d0 at2))
          for c5 = (- (* 6d0 d) (* 3d0 vt) (* .5d0 at2))
          for p2 = (* p p) for p3 = (* p2 p)
          for p4 = (* p3 p) for p5 = (* p4 p)
          do (push (if (= p 1d0) b
                       (+ a (* vt p) (* .5d0 at2 p2)
                          (* c3 p3) (* c4 p4) (* c5 p5)))
                   positions)
             (push (if (= p 1d0) 0d0
                       (/ (+ vt (* at2 p) (* 3d0 c3 p2)
                             (* 4d0 c4 p3) (* 5d0 c5 p4)) duration))
                   speeds)
             (push (if (= p 1d0) 0d0
                       (/ (+ at2 (* 6d0 c3 p) (* 12d0 c4 p2) (* 20d0 c5 p3))
                          (* duration duration)))
                   accelerations))
    (values (nreverse positions) (nreverse speeds) (nreverse accelerations))))

(defun %meta-motion-derivatives (origin velocity acceleration duration bounds)
  ;; A quintic Bezier lies inside its control-point hull. Constrain only the
  ;; first two controls for bounded values (sizes, zoom, opacity); translations
  ;; retain their derivatives even on reversal. End controls all equal target.
  (let ((speeds nil) (accelerations nil))
    (loop for a in origin for v in velocity for acc in acceleration
          for index from 0 for bound = (nth index bounds)
          do (if (null bound)
                 (progn (push v speeds) (push acc accelerations))
                 (flet ((limit (value)
                          (max (first bound) (min (second bound) value))))
                   (let* ((raw-p1 (+ a (/ (* v duration) 5d0)))
                          (raw-p2 (+ a (/ (* 2d0 v duration) 5d0)
                                     (/ (* acc duration duration) 20d0)))
                          (p1 (limit raw-p1)) (p2 (limit raw-p2)))
                     (if (and (= p1 raw-p1) (= p2 raw-p2))
                         (progn (push v speeds) (push acc accelerations))
                         (progn
                           (push (/ (* 5d0 (- p1 a)) duration) speeds)
                           (push (/ (* 20d0 (+ p2 a (* -2d0 p1))) (* duration duration))
                                 accelerations)))))))
    (values (nreverse speeds) (nreverse accelerations))))

(defun %meta-animate-to (world subject channel origin destination duration update
                         &key bounds)
  (let ((previous (%meta-motion world subject channel)))
    (when (and previous (equalp destination (%meta-trajectory-destination previous)))
      (return-from %meta-animate-to subject))
    (multiple-value-bind (velocity acceleration)
        (%meta-motion-derivatives
         origin
         (if previous (%meta-trajectory-velocity previous) (mapcar (constantly 0d0) origin))
         (if previous (%meta-trajectory-acceleration previous) (mapcar (constantly 0d0) origin))
         duration bounds)
      (let ((motion (%make-meta-trajectory :origin (copy-list origin)
                                           :destination (copy-list destination)
                                           :velocity velocity :acceleration acceleration)))
        (setf (%meta-motion world subject channel) motion)
        (ataxia.world:start-animation
         (%world-animator world) subject channel (%now) duration
         (lambda (target progress)
           (multiple-value-bind (geometry speed acc)
               (%meta-motion-sample (%meta-trajectory-origin motion)
                                    (%meta-trajectory-destination motion)
                                    velocity duration progress acceleration)
             (setf (%meta-trajectory-velocity motion) speed
                   (%meta-trajectory-acceleration motion) acc)
             (funcall update target geometry)))
         :finish (lambda (target)
                   (when (eq motion (%meta-motion world target channel))
                     (%meta-forget-motion world target channel))))
        (%request-all-frames world))))
  subject)

(defun %meta-target-geometry (world object)
  (let ((motion (%meta-motion world object :metaworld-layout)))
    (if motion (%meta-trajectory-destination motion) (%meta-object-geometry object))))
