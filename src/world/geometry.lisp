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

(defun rectangle-empty-p (rectangle)
  (or (<= (rectangle-width rectangle) 0)
      (<= (rectangle-height rectangle) 0)))

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

(defun %rectangles-touch-p (left right)
  (and (<= (rectangle-x left) (rectangle-right right))
       (<= (rectangle-x right) (rectangle-right left))
       (<= (rectangle-y left) (rectangle-bottom right))
       (<= (rectangle-y right) (rectangle-bottom left))))

(defun normalize-region (rectangles)
  "Return a conservative region with touching rectangles coalesced."
  (let ((result nil))
    (dolist (rectangle rectangles)
      (unless (rectangle-empty-p rectangle)
        (let ((merged rectangle)
              (remaining nil))
          (dolist (candidate result)
            (if (%rectangles-touch-p merged candidate)
                (setf merged (rectangle-union merged candidate))
                (push candidate remaining)))
          (setf result (cons merged remaining)))))
    (nreverse result)))

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

(defun region-to-frame-damage (region width height)
  (mapcar
   (lambda (rectangle)
     (let* ((x (max 0 (floor (rectangle-x rectangle))))
            (y (max 0 (floor (rectangle-y rectangle))))
            (right (min width (ceiling (rectangle-right rectangle))))
            (bottom (min height (ceiling (rectangle-bottom rectangle)))))
       (ataxia.kernel:make-frame-damage-rectangle
        x y (- right x) (- bottom y))))
   (clip-region region width height)))
