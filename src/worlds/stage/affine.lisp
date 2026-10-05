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

;; Transforms are applied to every item on every frame: the small operations are
;; inlined with double-float arithmetic, so applying one allocates nothing.
(declaim (inline affine-apply affine-multiply affine-determinant))

(defun make-affine (a b c d e f)
  (%make-affine (coerce a 'double-float) (coerce b 'double-float)
                (coerce c 'double-float) (coerce d 'double-float)
                (coerce e 'double-float) (coerce f 'double-float)))

(defparameter +identity-affine+ (make-affine 1 0 0 1 0 0))

(defun affine-translation (x y)
  (make-affine 1 0 0 1 x y))

(defun affine-multiply (outer inner)
  "Return the transform applying INNER first, then OUTER."
  (declare (type affine outer inner))
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
  (declare (type affine transform) (type real x y))
  (let ((x (float x 1d0)) (y (float y 1d0)))
    (values (+ (* (affine-a transform) x) (* (affine-c transform) y) (affine-e transform))
            (+ (* (affine-b transform) x) (* (affine-d transform) y) (affine-f transform)))))

(defun affine-determinant (transform)
  (declare (type affine transform))
  (- (* (affine-a transform) (affine-d transform))
     (* (affine-b transform) (affine-c transform))))

(defun affine-scale-factor (transform)
  "Geometric mean of the axis scales: output pixels per local unit."
  (sqrt (abs (affine-determinant transform))))

(defun affine-invert (transform)
  "Return the inverse transform, or NIL when TRANSFORM collapses an axis."
  (declare (type affine transform))
  (let ((determinant (affine-determinant transform)))
    (unless (< (abs determinant) 1d-12)
      (let ((a (/ (affine-d transform) determinant))
            (b (/ (- (affine-b transform)) determinant))
            (c (/ (- (affine-c transform)) determinant))
            (d (/ (affine-a transform) determinant)))
        (%make-affine a b c d
                      (- (+ (* a (affine-e transform)) (* c (affine-f transform))))
                      (- (+ (* b (affine-e transform)) (* d (affine-f transform)))))))))

(defun affine-rectangle-bounds (transform x y width height &optional (margin 0d0))
  "Axis-aligned bounds of the transformed rectangle, grown by MARGIN on every side,
as an ATAXIA.WORLD rectangle."
  (declare (type affine transform) (type real x y width height margin))
  (let* ((x (float x 1d0)) (y (float y 1d0))
         (x1 (+ x (float width 1d0))) (y1 (+ y (float height 1d0)))
         (left most-positive-double-float) (top most-positive-double-float)
         (right most-negative-double-float) (bottom most-negative-double-float))
    (declare (type double-float x y x1 y1 left top right bottom))
    (flet ((corner (cx cy)
             (declare (type double-float cx cy))
             (multiple-value-bind (px py) (affine-apply transform cx cy)
               (setf left (min left px) top (min top py) right (max right px) bottom (max bottom py)))))
      (declare (inline corner))
      (corner x y)
      (corner x1 y)
      (corner x y1)
      (corner x1 y1))
    (let ((margin (float margin 1d0)))
      (ataxia.world:make-rectangle (- left margin) (- top margin)
                                   (+ (- right left) margin margin) (+ (- bottom top) margin margin)))))

(defun node-affine (x y scale rotation origin-x origin-y)
  "Translate by (X, Y), then scale and rotate about the local ORIGIN point."
  (let* ((x (float x 1d0)) (y (float y 1d0)) (scale (float scale 1d0))
         (origin-x (float origin-x 1d0)) (origin-y (float origin-y 1d0))
         (rotation (float rotation 1d0))
         ;; An unrotated node, the common case, needs no trigonometry.
         (cosine (if (zerop rotation) scale (* scale (cos rotation))))
         (sine (if (zerop rotation) 0d0 (* scale (sin rotation)))))
    (declare (type double-float x y scale origin-x origin-y rotation cosine sine))
    ;; T(x+ox, y+oy) · R · S · T(-ox, -oy), expanded.
    (%make-affine cosine sine (- sine) cosine
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
