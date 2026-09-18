;;;; Small geometry and region helpers shared by Worlds.
;;;;
;;;; Geometry here is deliberately output-space only. Projection from a
;;;; concrete World's topology remains the responsibility of that World.

(in-package #:ataxia.world)

(defstruct (rectangle (:constructor make-rectangle (x y width height)))
  x y width height)

(defun rectangle-right (rectangle)
  (+ (rectangle-x rectangle) (rectangle-width rectangle)))

(defun rectangle-bottom (rectangle)
  (+ (rectangle-y rectangle) (rectangle-height rectangle)))

(defun rectangle-pixel-bounds (rectangle width height)
  "Return conservative integer pixel bounds clipped to WIDTH and HEIGHT."
  (let* ((x (max 0 (floor (rectangle-x rectangle))))
         (y (max 0 (floor (rectangle-y rectangle))))
         (right (min width (ceiling (rectangle-right rectangle))))
         (bottom (min height (ceiling (rectangle-bottom rectangle)))))
    (values x y (max 0 (- right x)) (max 0 (- bottom y)))))

(defun rectangle-empty-p (rectangle)
  (or (<= (rectangle-width rectangle) 0)
      (<= (rectangle-height rectangle) 0)))

(defun rectangle-area (rectangle)
  (* (max 0 (rectangle-width rectangle)) (max 0 (rectangle-height rectangle))))

(defun rectangle-intersection (left right)
  (let* ((x (max (rectangle-x left) (rectangle-x right)))
         (y (max (rectangle-y left) (rectangle-y right)))
         (right-edge (min (rectangle-right left) (rectangle-right right)))
         (bottom-edge (min (rectangle-bottom left) (rectangle-bottom right))))
    (when (and (< x right-edge) (< y bottom-edge))
      (make-rectangle x y (- right-edge x) (- bottom-edge y)))))

(defun rectangle-union (left right)
  (let ((x (min (rectangle-x left) (rectangle-x right)))
        (y (min (rectangle-y left) (rectangle-y right))))
    (make-rectangle
     x y
     (- (max (rectangle-right left) (rectangle-right right)) x)
     (- (max (rectangle-bottom left) (rectangle-bottom right)) y))))

(defun %intervals-touch-p (left-start left-end right-start right-end)
  (and (<= left-start right-end) (<= right-start left-end)))

(defun %rectangle-contains-p (outer inner)
  (and (<= (rectangle-x outer) (rectangle-x inner))
       (<= (rectangle-y outer) (rectangle-y inner))
       (>= (rectangle-right outer) (rectangle-right inner))
       (>= (rectangle-bottom outer) (rectangle-bottom inner))))

(defun %rectangles-mergeable-p (left right)
  (or (%rectangle-contains-p left right)
      (%rectangle-contains-p right left)
      (and (= (rectangle-y left) (rectangle-y right))
           (= (rectangle-bottom left) (rectangle-bottom right))
           (%intervals-touch-p
            (rectangle-x left) (rectangle-right left)
            (rectangle-x right) (rectangle-right right)))
      (and (= (rectangle-x left) (rectangle-x right))
           (= (rectangle-right left) (rectangle-right right))
           (%intervals-touch-p
            (rectangle-y left) (rectangle-bottom left)
            (rectangle-y right) (rectangle-bottom right)))))

(defun normalize-region (rectangles)
  "Return a region with only exactly rectangular unions coalesced."
  (labels ((insert-rectangle (rectangle region)
             (let ((touching
                     (find-if
                      (lambda (candidate)
                        (%rectangles-mergeable-p rectangle candidate))
                      region)))
               (if touching
                   (insert-rectangle
                    (rectangle-union rectangle touching)
                    (delete touching region :test #'eq :count 1))
                   (cons rectangle region)))))
    (nreverse
     (reduce (lambda (region rectangle)
               (if (rectangle-empty-p rectangle)
                   region
                   (insert-rectangle rectangle region)))
             rectangles
             :initial-value nil))))

(defun clip-region (rectangles width height)
  (let ((bounds (make-rectangle 0 0 width height)))
    (normalize-region
     (loop for rectangle in rectangles
           for clipped = (rectangle-intersection rectangle bounds)
           when clipped collect clipped))))

(defun region-intersects-p (rectangle region)
  (some (lambda (candidate)
          (rectangle-intersection rectangle candidate))
        region))

(defun subtract-region (region occluders &key (rectangle-limit 64))
  "Subtract proven opaque rectangles, without enlarging them.
If fragmentation exceeds RECTANGLE-LIMIT, return the original visible region:
extra drawing is safe, whereas discarding an uncovered pixel is not. NIL disables
the limit. The second value says whether subtraction finished exactly."
  (let ((remaining region))
    (dolist (occluder occluders (values remaining t))
      (let ((next nil))
        (dolist (rectangle remaining)
          (let ((overlap (rectangle-intersection rectangle occluder)))
            (if (null overlap)
                (push rectangle next)
                (let ((x (rectangle-x rectangle)) (y (rectangle-y rectangle))
                      (right (rectangle-right rectangle)) (bottom (rectangle-bottom rectangle))
                      (ix (rectangle-x overlap)) (iy (rectangle-y overlap))
                      (ir (rectangle-right overlap)) (ib (rectangle-bottom overlap)))
                  ;; Disjoint strips: top/bottom span the original width, and
                  ;; left/right span only the intersection's height.
                  (dolist (piece (list (make-rectangle x y (- right x) (- iy y))
                                       (make-rectangle x ib (- right x) (- bottom ib))
                                       (make-rectangle x iy (- ix x) (- ib iy))
                                       (make-rectangle ir iy (- right ir) (- ib iy))))
                    (unless (rectangle-empty-p piece) (push piece next))))))
          (when (and rectangle-limit (> (length next) rectangle-limit))
            (return-from subtract-region (values region nil))))
        (setf remaining (nreverse next))))))

(defun region-to-frame-damage (region width height)
  (mapcar
   (lambda (rectangle)
     (multiple-value-bind (x y pixel-width pixel-height)
         (rectangle-pixel-bounds rectangle width height)
       (ataxia.kernel:make-frame-damage-rectangle
        x y pixel-width pixel-height)))
   (clip-region region width height)))

(defun frame-damage-to-region (damage)
  (mapcar
   (lambda (rectangle)
     (make-rectangle
      (ataxia.kernel:frame-damage-rectangle-x rectangle)
      (ataxia.kernel:frame-damage-rectangle-y rectangle)
      (ataxia.kernel:frame-damage-rectangle-width rectangle)
      (ataxia.kernel:frame-damage-rectangle-height rectangle)))
   damage))

(defun transform-normalized-point (transform x y)
  (case transform
    (0 (values x y))
    (1 (values (- 1d0 y) x))
    (2 (values (- 1d0 x) (- 1d0 y)))
    (3 (values y (- 1d0 x)))
    (4 (values (- 1d0 x) y))
    (5 (values (- 1d0 y) (- 1d0 x)))
    (6 (values x (- 1d0 y)))
    (7 (values y x))
    (otherwise (values x y))))
