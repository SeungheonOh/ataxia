;;;; Two-dimensional affine transforms.
;;;;
;;;; Scene nodes compose these from the output buffer down to their own local
;;;; space. The same mapping drives drawing, damage projection and picking, so
;;;; input always lands on exactly what was presented.

(in-package #:ataxia.stage-world)

(defstruct (affine (:constructor %make-affine (a b c d e f)))
  "Maps (X, Y) to (A·X + C·Y + E, B·X + D·Y + F)."
  (a 1d0 :type double-float :read-only t)
  (b 0d0 :type double-float :read-only t)
  (c 0d0 :type double-float :read-only t)
  (d 1d0 :type double-float :read-only t)
  (e 0d0 :type double-float :read-only t)
  (f 0d0 :type double-float :read-only t))

(defun make-affine (a b c d e f)
  (%make-affine (coerce a 'double-float) (coerce b 'double-float)
                (coerce c 'double-float) (coerce d 'double-float)
                (coerce e 'double-float) (coerce f 'double-float)))

(defparameter +identity-affine+ (make-affine 1 0 0 1 0 0))

(defun affine-translation (x y)
  (make-affine 1 0 0 1 x y))

(defun affine-multiply (outer inner)
  "Return the transform applying INNER first, then OUTER."
  (let ((a (affine-a outer)) (b (affine-b outer)) (c (affine-c outer))
        (d (affine-d outer)) (e (affine-e outer)) (f (affine-f outer)))
    (%make-affine
     (+ (* a (affine-a inner)) (* c (affine-b inner)))
     (+ (* b (affine-a inner)) (* d (affine-b inner)))
     (+ (* a (affine-c inner)) (* c (affine-d inner)))
     (+ (* b (affine-c inner)) (* d (affine-d inner)))
     (+ (* a (affine-e inner)) (* c (affine-f inner)) e)
     (+ (* b (affine-e inner)) (* d (affine-f inner)) f))))

(defun affine-apply (transform x y)
  (values (+ (* (affine-a transform) x) (* (affine-c transform) y) (affine-e transform))
          (+ (* (affine-b transform) x) (* (affine-d transform) y) (affine-f transform))))

(defun affine-determinant (transform)
  (- (* (affine-a transform) (affine-d transform))
     (* (affine-b transform) (affine-c transform))))

(defun affine-scale-factor (transform)
  "Geometric mean of the axis scales: output pixels per local unit."
  (sqrt (abs (affine-determinant transform))))

(defun affine-invert (transform)
  "Return the inverse transform, or NIL when TRANSFORM collapses an axis."
  (let ((determinant (affine-determinant transform)))
    (unless (< (abs determinant) 1d-12)
      (let ((a (/ (affine-d transform) determinant))
            (b (/ (- (affine-b transform)) determinant))
            (c (/ (- (affine-c transform)) determinant))
            (d (/ (affine-a transform) determinant)))
        (%make-affine a b c d
                      (- (+ (* a (affine-e transform)) (* c (affine-f transform))))
                      (- (+ (* b (affine-e transform)) (* d (affine-f transform)))))))))

(defun affine-rectangle-bounds (transform x y width height)
  "Axis-aligned bounds of the transformed rectangle, as an ATAXIA.WORLD rectangle."
  (let ((left most-positive-double-float) (top most-positive-double-float)
        (right most-negative-double-float) (bottom most-negative-double-float))
    (dolist (corner (list (cons x y) (cons (+ x width) y)
                          (cons x (+ y height)) (cons (+ x width) (+ y height))))
      (multiple-value-bind (px py) (affine-apply transform (car corner) (cdr corner))
        (setf left (min left px) top (min top py)
              right (max right px) bottom (max bottom py))))
    (ataxia.world:make-rectangle left top (- right left) (- bottom top))))

(defun node-affine (x y scale rotation origin-x origin-y)
  "Translate by (X, Y), then scale and rotate about the local ORIGIN point."
  (let* ((cosine (* scale (cos rotation)))
         (sine (* scale (sin rotation))))
    ;; T(x+ox, y+oy) · R · S · T(-ox, -oy), expanded.
    (make-affine cosine sine (- sine) cosine
                 (+ x origin-x (- (- (* cosine origin-x) (* sine origin-y))))
                 (+ y origin-y (- (+ (* sine origin-x) (* cosine origin-y)))))))

(defun camera-affine (x y zoom rotation viewport-width viewport-height)
  "Map world space to output-logical space, centering world point (X, Y)."
  (affine-multiply
   (node-affine (/ viewport-width 2d0) (/ viewport-height 2d0) zoom (- rotation) 0d0 0d0)
   (affine-translation (- x) (- y))))

(defun output-buffer-affine (logical-width logical-height buffer-width buffer-height transform)
  "Map output-logical coordinates to buffer pixels for a wl_output TRANSFORM."
  (flet ((buffer-point (x y)
           (multiple-value-bind (u v)
               (ataxia.world:transform-normalized-point
                transform (/ x logical-width) (/ y logical-height))
             (values (* u buffer-width) (* v buffer-height)))))
    (multiple-value-bind (x0 y0) (buffer-point 0d0 0d0)
      (multiple-value-bind (x1 y1) (buffer-point logical-width 0d0)
        (multiple-value-bind (x2 y2) (buffer-point 0d0 logical-height)
          (make-affine (/ (- x1 x0) logical-width) (/ (- y1 y0) logical-width)
                       (/ (- x2 x0) logical-height) (/ (- y2 y0) logical-height)
                       x0 y0))))))
