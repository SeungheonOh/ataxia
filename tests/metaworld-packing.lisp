;;;; Run: sbcl --script tests/metaworld-packing.lisp
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)

(defun assert-separated (records gap)
  (loop for tail on records do
    (dolist (other (rest tail))
      (assert (not (%meta-records-overlap-p (first tail) other gap))))))

;; Dense, negative-coordinate and varied-size layouts; anchor remains fixed.
(loop for count from 1 to 30 do
  (loop for trial below 30 do
    (let* ((records (loop for i below count collect
                     (list i (coerce (- (mod (+ (* i 157) (* trial 71)) 900) 450) 'double-float)
                             (coerce (- (mod (+ (* i 239) (* trial 31)) 800) 400) 'double-float)
                             (+ 100d0 (mod (* i 113) 500)) (+ 80d0 (mod (* i 191) 900)))))
           (anchor (mod trial count))
           (packed (%meta-pack-records records anchor +meta-subworld-gap+)))
      (assert-separated packed +meta-subworld-gap+)
      (assert (equal (assoc anchor records) (assoc anchor packed)))
      (assert (equal packed (%meta-pack-records packed anchor +meta-subworld-gap+))))))

(let* ((names '(%now %damage-window %update-window-membership %request-all-frames %meta-changed))
       (saved (mapcar #'symbol-function names))
       (clock 0d0))
  (unwind-protect
       (progn
         (dolist (name (rest names))
           (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (symbol-function '%now) (lambda () clock))
         (let* ((world (make-metaworld :state-file nil))
                (groups (loop for i below 8 collect
                          (%make-subworld :id i :kind :floating :x (* i 596d0) :y 0d0
                                          :width 500d0 :height 400d0)))
                (anchor (first groups))
                (neighbor (second groups))
                (app (make-instance 'ataxia.kernel:wayland-application))
                (child (make-instance 'canvas-window :application app :x 616d0 :y 30d0 :width 200d0 :height 100d0))
                (member (%make-subworld-member :object child :restore-geometry '(616d0 30d0 200d0 100d0))))
           (setf (metaworld-subworlds world) groups
                 (subworld-members neighbor) (list member))
           (%meta-maintain-subworld-spacing world)
           ;; The soft buffer moves the neighbor gradually, then propagates.
           (move-subworld world anchor 30d0 0d0)
           (assert (= 596d0 (subworld-x neighbor)))
           (assert (%meta-motion world neighbor :subworld-push))
           (incf clock .06d0)
           (ataxia.world:advance-animations (%world-animator world) clock)
           (%meta-enforce-subworld-separation world)
           (assert (< 596d0 (subworld-x neighbor) 626d0))
           ;; Repeated diagonal drags, large jumps and reversals never render overlap.
           (loop for i below 90 do
             (move-subworld world anchor (* 37d0 (if (< i 45) i (- 90 i)))
                            (* 25d0 (mod i 17)))
             (assert-separated (%meta-packing-records world) +meta-subworld-contact-gap+)
             (dotimes (frame 3)
               (incf clock .016d0)
               (ataxia.world:advance-animations (%world-animator world) clock)
               (%meta-enforce-subworld-separation world)
               (assert-separated (%meta-packing-records world) +meta-subworld-contact-gap+)
               (assert (< (abs (- (canvas-window-x child) (subworld-x neighbor) 20d0)) .00001d0))
               (assert (< (abs (- (canvas-window-y child) (subworld-y neighbor) 30d0)) .00001d0))
               (assert (< (abs (- (first (subworld-member-restore-geometry member))
                                 (subworld-x neighbor) 20d0)) .00001d0))))
           (incf clock 1d0)
           (ataxia.world:advance-animations (%world-animator world) clock)
           (%meta-enforce-subworld-separation world)
           (assert-separated (%meta-packing-records world) +meta-subworld-gap+)
           (assert (zerop (hash-table-count (%meta-motions world))))
           ;; A newly expanded Niri page footprint displaces other groups.
           (setf (subworld-kind anchor) :niri
                 (gethash anchor *meta-workspace-counts*) 4)
           (%meta-maintain-subworld-spacing world)
           (assert (= (%meta-footprint-height anchor) (* 4 400d0)))
           (assert-separated (%meta-packing-records world) +meta-subworld-contact-gap+)
           (incf clock 1d0)
           (ataxia.world:advance-animations (%world-animator world) clock)
           (%meta-enforce-subworld-separation world)
           (assert-separated (%meta-packing-records world) +meta-subworld-gap+)
           ;; Grabbing a moving neighbor cancels its prior push trajectory.
           (move-subworld world anchor (subworld-x neighbor) (subworld-y neighbor))
           (move-subworld world neighbor -5000d0 -5000d0)
           (assert (null (%meta-motion world neighbor :subworld-push)))
           (incf clock 1d0)
           (ataxia.world:advance-animations (%world-animator world) clock)
           (%meta-enforce-subworld-separation world)
           (assert (= -5000d0 (subworld-x neighbor)))
           (assert (= -5000d0 (subworld-y neighbor)))))
    (loop for name in names for fn in saved do (setf (symbol-function name) fn))))
(format t "Metaworld packing tests passed.~%")
