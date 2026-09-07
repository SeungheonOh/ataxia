(in-package #:ataxia.infinite-world)

(defvar *meta-packing-p* nil)
(defparameter +meta-subworld-gap+ 96d0)
(defparameter +meta-subworld-contact-gap+ 40d0)

(defun %meta-packing-records (world &optional targets-p)
  (loop for group in (metaworld-subworlds world)
        for motion = (and targets-p (gethash group (%meta-motions world)))
        for position = (and motion (%meta-trajectory-destination motion))
        collect (list group (if position (first position) (subworld-x group))
                      (if position (second position) (subworld-y group))
                      (%meta-footprint-width group) (%meta-footprint-height group))))

(defun %meta-records-overlap-p (a b gap)
  ;; Tiny tolerance prevents roundoff at an exactly touching boundary from
  ;; sending a monotone ray through the same obstacle repeatedly.
  (let ((gap (- gap 0.000001d0)))
    (and (< (second a) (+ (second b) (fourth b) gap))
         (< (second b) (+ (second a) (fourth a) gap))
         (< (third a) (+ (third b) (fifth b) gap))
         (< (third b) (+ (third a) (fifth a) gap)))))

(defun %meta-packing-ray (record placed gap axis sign)
  (let ((candidate (copy-list record)))
    ;; Each correction moves monotonically past an obstacle, so this cannot
    ;; oscillate or revisit an obstacle. The finite bound is defensive.
    (loop repeat (1+ (length placed))
          for obstacle = (find-if (lambda (other) (%meta-records-overlap-p candidate other gap)) placed)
          unless obstacle return candidate
          do (setf (nth axis candidate)
                   (if (plusp sign)
                       (+ (nth axis obstacle) (nth (+ axis 2) obstacle) gap)
                       (- (nth axis obstacle) (nth (+ axis 2) candidate) gap)))
          finally (error "Subworld packing failed to clear a monotone ray."))))

(defun %meta-pack-records (records anchor gap &optional (direction '(1d0 0d0)))
  "Keep ANCHOR fixed and find nearby free positions for every other footprint."
  (let ((placed nil)
        (ordered (let ((record (find anchor records :key #'first :test #'eq)))
                   (if record (cons record (remove record records :test #'eq)) records))))
    (dolist (record ordered)
      (let ((candidate record))
        (when (some (lambda (other) (%meta-records-overlap-p record other gap)) placed)
          (let ((best-distance most-positive-double-float)
                (best-alignment most-negative-double-float))
            (dolist (ray '((1 1) (1 -1) (2 1) (2 -1)))
              (let* ((proposal (%meta-packing-ray record placed gap (first ray) (second ray)))
                     (dx (- (second proposal) (second record)))
                     (dy (- (third proposal) (third record)))
                     (distance (+ (abs dx) (abs dy)))
                     (alignment (+ (* dx (first direction)) (* dy (second direction)))))
                (when (or (< distance (- best-distance 0.000001d0))
                          (and (< (abs (- distance best-distance)) 0.000001d0)
                               (> alignment best-alignment)))
                  (setf candidate proposal best-distance distance best-alignment alignment))))))
        (push candidate placed)))
    (nreverse placed)))

(defun %meta-packing-anchor-for-world (world)
  (let ((dragged (getf (%meta-group-drag world) :subject)))
    (cond ((typep dragged 'subworld) dragged)
          ((member (%meta-packing-anchor world) (metaworld-subworlds world)) (%meta-packing-anchor world))
          (t (first (metaworld-subworlds world))))))

(defun %meta-enforce-subworld-separation (world)
  "Project displayed positions out of contact before rendering or returning from a move."
  (let ((*meta-packing-p* t) (changed nil))
    (dolist (record (%meta-pack-records (%meta-packing-records world)
                                       (%meta-packing-anchor-for-world world)
                                       +meta-subworld-contact-gap+ (%meta-packing-direction world)))
      (destructuring-bind (group x y width height) record
        (declare (ignore width height))
        (unless (and (= x (subworld-x group)) (= y (subworld-y group)))
          (%meta-translate-subworld world group x y)
          (setf changed t))))
    (when changed (%meta-changed world)))
  world)

(defun %meta-push-subworlds (world anchor &optional (direction '(1d0 0d0)))
  (let ((*meta-packing-p* t))
    (%meta-cancel-motion world anchor :subworld-push)
    (setf (%meta-packing-anchor world) anchor (%meta-packing-direction world) direction)
    ;; A soft gap begins easing neighbors aside before actual contact. Fast
    ;; pointer jumps still honor the hard gap and never leave overlapping pages.
    (%meta-enforce-subworld-separation world)
    (dolist (record (%meta-pack-records (%meta-packing-records world t) anchor
                                       +meta-subworld-gap+ direction))
      (destructuring-bind (group x y width height) record
        (declare (ignore width height))
        (unless (eq group anchor)
          (let ((origin (list (subworld-x group) (subworld-y group)))
                (destination (list x y)))
            (unless (equalp origin destination)
              (%meta-animate-to
               world group :subworld-push origin destination 0.18d0
               (lambda (subject position)
                 (when (member subject (metaworld-subworlds world))
                   (let ((*meta-packing-p* t))
                     (%meta-translate-subworld world subject (first position) (second position))
                     (%meta-changed world)))))))))))
  world)

(defun %meta-maintain-subworld-spacing (world)
  (unless (or *meta-packing-p* (%meta-restoring-p world) (%world-quiescing-p world))
    (let* ((signature (loop for group in (metaworld-subworlds world)
                            collect (list group (%meta-footprint-width group) (%meta-footprint-height group))))
           (old (%meta-packing-signature world)))
      (unless (equalp signature old)
        (setf (%meta-packing-signature world) signature)
        (let ((changed (find-if (lambda (entry) (not (equalp entry (assoc (first entry) old)))) signature)))
          (%meta-push-subworlds world (or (and changed (first changed)) (%meta-packing-anchor-for-world world)))))))
  world)
