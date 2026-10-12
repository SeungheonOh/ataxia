;;;; Two-dimensional projective transforms.
;;;;
;;;; Scene nodes compose these from the output buffer down to their own local
;;;; space. Most are affine; a node tilted in depth adds perspective, which a
;;;; homogeneous 3x3 matrix keeps exact under composition and inversion. The
;;;; same mapping drives drawing, damage projection and picking, so input always
;;;; lands on exactly what was presented.

(in-package #:ataxia.stage-world)

(defstruct (transform (:constructor %make-transform (a b c d e f g h i)))
  "Maps (X, Y) to ((A·X + C·Y + E) / W, (B·X + D·Y + F) / W), where
W = G·X + H·Y + I. G and H are zero, and I one, unless it has perspective."
  (a 1d0 :type double-float :read-only t)
  (b 0d0 :type double-float :read-only t)
  (c 0d0 :type double-float :read-only t)
  (d 1d0 :type double-float :read-only t)
  (e 0d0 :type double-float :read-only t)
  (f 0d0 :type double-float :read-only t)
  (g 0d0 :type double-float :read-only t)
  (h 0d0 :type double-float :read-only t)
  (i 1d0 :type double-float :read-only t))

;; Transforms are applied to every item on every frame: the small operations are
;; inlined with double-float arithmetic, so applying one allocates nothing.
(declaim (inline transform-homogeneous transform-apply transform-multiply transform-jacobian))

(defun make-transform (a b c d e f &optional (g 0) (h 0) (i 1))
  (flet ((double (value) (coerce value 'double-float)))
    (%make-transform (double a) (double b) (double c) (double d) (double e) (double f)
                     (double g) (double h) (double i))))

(defparameter +identity-transform+ (make-transform 1 0 0 1 0 0))

(defconstant +nearest-depth+ 1d-6
  "The least homogeneous W of a point in front of the viewer. Perspective maps
points at or behind the viewer's plane to W at or below zero.")

(defun transform-translation (x y)
  (make-transform 1 0 0 1 x y))

(defun transform-multiply (outer inner)
  "Return the transform applying INNER first, then OUTER."
  (declare (type transform outer inner))
  (let ((a (transform-a outer)) (b (transform-b outer)) (c (transform-c outer))
        (d (transform-d outer)) (e (transform-e outer)) (f (transform-f outer))
        (g (transform-g outer)) (h (transform-h outer)) (i (transform-i outer))
        (a2 (transform-a inner)) (b2 (transform-b inner)) (c2 (transform-c inner))
        (d2 (transform-d inner)) (e2 (transform-e inner)) (f2 (transform-f inner))
        (g2 (transform-g inner)) (h2 (transform-h inner)) (i2 (transform-i inner)))
    (%make-transform (+ (* a a2) (* c b2) (* e g2))
                     (+ (* b a2) (* d b2) (* f g2))
                     (+ (* a c2) (* c d2) (* e h2))
                     (+ (* b c2) (* d d2) (* f h2))
                     (+ (* a e2) (* c f2) (* e i2))
                     (+ (* b e2) (* d f2) (* f i2))
                     (+ (* g a2) (* h b2) (* i g2))
                     (+ (* g c2) (* h d2) (* i h2))
                     (+ (* g e2) (* h f2) (* i i2)))))

(defun transform-homogeneous (transform x y)
  "Homogeneous image (X Y W) of point (X, Y), before the division by W."
  (declare (type transform transform) (type double-float x y))
  (values (+ (* (transform-a transform) x) (* (transform-c transform) y) (transform-e transform))
          (+ (* (transform-b transform) x) (* (transform-d transform) y) (transform-f transform))
          (+ (* (transform-g transform) x) (* (transform-h transform) y) (transform-i transform))))

(defun transform-apply (transform x y)
  "Map point (X, Y). A point at or behind the viewer maps far away."
  (declare (type transform transform) (type real x y))
  (multiple-value-bind (hx hy w) (transform-homogeneous transform (float x 1d0) (float y 1d0))
    (let ((w (max w +nearest-depth+)))
      (values (/ hx w) (/ hy w)))))

(defun transform-jacobian (transform x y)
  "How TRANSFORM stretches a small step from (X, Y): the partial derivatives
dX/dx, dY/dx, dX/dy and dY/dy of the image."
  (declare (type transform transform) (type real x y))
  (multiple-value-bind (hx hy w) (transform-homogeneous transform (float x 1d0) (float y 1d0))
    (let* ((w (max w +nearest-depth+))
           (image-x (/ hx w)) (image-y (/ hy w)))
      (values (/ (- (transform-a transform) (* image-x (transform-g transform))) w)
              (/ (- (transform-b transform) (* image-y (transform-g transform))) w)
              (/ (- (transform-c transform) (* image-x (transform-h transform))) w)
              (/ (- (transform-d transform) (* image-y (transform-h transform))) w)))))

(defun transform-scale-factor (transform &optional (x 0d0) (y 0d0))
  "Geometric mean of the axis scales around local point (X, Y): output pixels per
local unit there. Without perspective it is the same everywhere."
  (multiple-value-bind (dx-dx dy-dx dx-dy dy-dy) (transform-jacobian transform x y)
    (sqrt (abs (- (* dx-dx dy-dy) (* dy-dx dx-dy))))))

(defun transform-determinant (transform)
  "TRANSFORM's determinant. Where the image lies in front of the viewer its sign is
the image's orientation: negative for a plane seen from behind, mirrored."
  (declare (type transform transform))
  (let ((a (transform-a transform)) (b (transform-b transform)) (c (transform-c transform))
        (d (transform-d transform)) (e (transform-e transform)) (f (transform-f transform))
        (g (transform-g transform)) (h (transform-h transform)) (i (transform-i transform)))
    (+ (* a (- (* d i) (* f h)))
       (- (* c (- (* b i) (* f g))))
       (* e (- (* b h) (* d g))))))

(defun transform-invert (transform)
  "Return the inverse transform, or NIL when TRANSFORM collapses an axis."
  (declare (type transform transform))
  (let* ((a (transform-a transform)) (b (transform-b transform)) (c (transform-c transform))
         (d (transform-d transform)) (e (transform-e transform)) (f (transform-f transform))
         (g (transform-g transform)) (h (transform-h transform)) (i (transform-i transform))
         (determinant (transform-determinant transform)))
    (unless (< (abs determinant) 1d-12)
      (flet ((cofactor (value) (/ value determinant)))
        (%make-transform (cofactor (- (* d i) (* f h)))
                         (cofactor (- (* f g) (* b i)))
                         (cofactor (- (* e h) (* c i)))
                         (cofactor (- (* a i) (* e g)))
                         (cofactor (- (* c f) (* e d)))
                         (cofactor (- (* e b) (* a f)))
                         (cofactor (- (* b h) (* d g)))
                         (cofactor (- (* c g) (* a h)))
                         (cofactor (- (* a d) (* c b))))))))

(defparameter +unbounded+ (ataxia.world:make-rectangle -1d7 -1d7 2d7 2d7)
  "Bounds of a shape reaching behind the viewer, whose image has no finite bounds.")

(defun transform-rectangle-bounds (transform x y width height &optional (margin 0d0))
  "Axis-aligned bounds of the transformed rectangle, grown by MARGIN on every side,
as an ATAXIA.WORLD rectangle."
  (declare (type transform transform) (type real x y width height margin))
  (let* ((x (float x 1d0)) (y (float y 1d0))
         (x1 (+ x (float width 1d0))) (y1 (+ y (float height 1d0)))
         (left most-positive-double-float) (top most-positive-double-float)
         (right most-negative-double-float) (bottom most-negative-double-float))
    (declare (type double-float x y x1 y1 left top right bottom))
    (flet ((corner (cx cy)
             (declare (type double-float cx cy))
             (multiple-value-bind (hx hy w) (transform-homogeneous transform cx cy)
               (when (< w +nearest-depth+)
                 (return-from transform-rectangle-bounds +unbounded+))
               (let ((px (/ hx w)) (py (/ hy w)))
                 (setf left (min left px) top (min top py) right (max right px) bottom (max bottom py))))))
      (declare (inline corner))
      (corner x y)
      (corner x1 y)
      (corner x y1)
      (corner x1 y1))
    (let ((margin (float margin 1d0)))
      (ataxia.world:make-rectangle (- left margin) (- top margin)
                                   (+ (- right left) margin margin) (+ (- bottom top) margin margin)))))

;;; Three-dimensional transforms.
;;;
;;; Nodes declare transform functions, as CSS does, which compose into 4x4
;;; matrices down the scene. Depth survives nesting, so a group's perspective
;;; shows its children's turns in true 3D. A node draws on its z = 0 plane, which
;;; the composed matrix carries to the output as a projective TRANSFORM.

(deftype matrix ()
  "A 4x4 matrix of homogeneous 3D points, row by row."
  '(simple-array double-float (16)))

(defmacro %matrix (&rest rows)
  "A fresh matrix of the sixteen ROWS values, row by row."
  (let ((matrix (gensym "MATRIX")))
    `(let ((,matrix (make-array 16 :element-type 'double-float)))
       (setf ,@(loop for value in rows for index from 0
                     append `((aref ,matrix ,index) (float ,value 1d0))))
       ,matrix)))

(defparameter +identity-matrix+ (%matrix 1 0 0 0  0 1 0 0  0 0 1 0  0 0 0 1))

(defun matrix-multiply (outer inner)
  "Return the matrix applying INNER first, then OUTER."
  (declare (type matrix outer inner) (optimize speed))
  (let ((product (make-array 16 :element-type 'double-float)))
    (dotimes (row 4 product)
      (dotimes (column 4)
        (setf (aref product (+ (* row 4) column))
              (+ (* (aref outer (* row 4)) (aref inner column))
                 (* (aref outer (+ (* row 4) 1)) (aref inner (+ 4 column)))
                 (* (aref outer (+ (* row 4) 2)) (aref inner (+ 8 column)))
                 (* (aref outer (+ (* row 4) 3)) (aref inner (+ 12 column)))))))))

(defun matrix-translation (x y &optional (z 0d0))
  (%matrix 1 0 0 x  0 1 0 y  0 0 1 z  0 0 0 1))

(defun transform-matrix (transform)
  "TRANSFORM, which maps the plane, as a matrix leaving depth alone."
  (%matrix (transform-a transform) (transform-c transform) 0 (transform-e transform)
           (transform-b transform) (transform-d transform) 0 (transform-f transform)
           0 0 1 0
           (transform-g transform) (transform-h transform) 0 (transform-i transform)))

(defun matrix-plane (matrix)
  "Where MATRIX takes the z = 0 plane, as a projective transform of the plane."
  (declare (type matrix matrix))
  (%make-transform (aref matrix 0) (aref matrix 4) (aref matrix 1) (aref matrix 5)
                   (aref matrix 3) (aref matrix 7) (aref matrix 12) (aref matrix 13)
                   (aref matrix 15)))

;;; Transform functions.

(defparameter +transform-functions+
  '(("translate" :translate 3 1d-2) ("scale" :scale 3 1d-4) ("rotate" :rotate 4 1d-4)
    ("skew" :skew 2 1d-4) ("perspective" :perspective 1 1d-7) ("matrix" :matrix 16 1d-4))
  "Protocol name, kind, parameter count and settling tolerance of each transform function.")

(defun transform-function-arity (kind)
  (third (find kind +transform-functions+ :key #'second)))

(defun transform-parameter-tolerances (kinds)
  "How close each parameter of functions KINDS must come to settle."
  (loop for kind in kinds
        for (nil nil arity tolerance) = (find kind +transform-functions+ :key #'second)
        nconc (make-list arity :initial-element tolerance)))

(defstruct (transform-list (:constructor make-transform-list (kinds parameters)))
  "Transform functions in the order CSS lists them: the last applies first. KINDS
names them; PARAMETERS holds their numbers in turn, as channels animate them.
`translate` and `scale` take X, Y and Z; `rotate` an axis and radians; `skew`
two angles; `perspective` the inverse of the viewer's distance, so none is 0;
`matrix` sixteen numbers row by row."
  (kinds nil :type list :read-only t)
  (parameters #() :type simple-vector :read-only t))

(defparameter +no-transform+ (make-transform-list nil #()))

(defun %function-matrix (kind parameters start)
  (flet ((parameter (index) (float (svref parameters (+ start index)) 1d0)))
    (ecase kind
      (:translate (matrix-translation (parameter 0) (parameter 1) (parameter 2)))
      (:scale (%matrix (parameter 0) 0 0 0  0 (parameter 1) 0 0  0 0 (parameter 2) 0  0 0 0 1))
      (:rotate
       (let* ((x (parameter 0)) (y (parameter 1)) (z (parameter 2))
              (length (sqrt (+ (* x x) (* y y) (* z z)))))
         (if (< length 1d-12)
             +identity-matrix+
             (let* ((x (/ x length)) (y (/ y length)) (z (/ z length))
                    (cosine (cos (parameter 3))) (sine (sin (parameter 3)))
                    (turn (- 1d0 cosine)))
               ;; Rodrigues' rotation about the unit axis; clockwise on screen about
               ;; z, as y points down.
               (%matrix (+ (* turn x x) cosine) (- (* turn x y) (* sine z)) (+ (* turn x z) (* sine y)) 0
                        (+ (* turn x y) (* sine z)) (+ (* turn y y) cosine) (- (* turn y z) (* sine x)) 0
                        (- (* turn x z) (* sine y)) (+ (* turn y z) (* sine x)) (+ (* turn z z) cosine) 0
                        0 0 0 1)))))
      (:skew (%matrix 1 (tan (parameter 0)) 0 0  (tan (parameter 1)) 1 0 0  0 0 1 0  0 0 0 1))
      ;; The viewer sits on the z axis, which points toward them.
      (:perspective (%matrix 1 0 0 0  0 1 0 0  0 0 1 0  0 0 (- (parameter 0)) 1))
      (:matrix (let ((matrix (make-array 16 :element-type 'double-float)))
                 (dotimes (index 16 matrix)
                   (setf (aref matrix index) (parameter index))))))))

(defun transform-list-matrix (list)
  "The matrix of LIST's functions, composed in order."
  (let ((matrix +identity-matrix+) (start 0))
    (dolist (kind (transform-list-kinds list) matrix)
      (setf matrix (matrix-multiply matrix (%function-matrix kind (transform-list-parameters list) start)))
      (incf start (transform-function-arity kind)))))

(defun transform-list-append (first second)
  "FIRST's functions followed by SECOND's."
  (make-transform-list (append (transform-list-kinds first) (transform-list-kinds second))
                       (concatenate 'simple-vector (transform-list-parameters first)
                                    (transform-list-parameters second))))

(defun %identity-parameters (kind like)
  "Parameters making a KIND function do nothing; a rotation keeps LIKE's axis."
  (ecase kind
    ((:translate :skew :perspective) (make-array (transform-function-arity kind) :initial-element 0d0))
    (:scale (vector 1d0 1d0 1d0))
    (:rotate (if like (vector (svref like 0) (svref like 1) (svref like 2) 0d0) (vector 0d0 0d0 1d0 0d0)))
    (:matrix (map 'vector #'identity +identity-matrix+))))

(defun pad-transform-list (list kinds &optional like)
  "LIST continued with functions doing nothing to take on KINDS, or NIL unless
LIST's kinds begin KINDS. LIKE, a list of KINDS, lends the padding its rotation axes."
  (let ((own (transform-list-kinds list)))
    (when (and (<= (length own) (length kinds)) (every #'eq own kinds))
      (make-transform-list
       kinds
       (apply #'concatenate 'simple-vector (transform-list-parameters list)
              (loop with start = (loop for kind in own sum (transform-function-arity kind))
                    for kind in (nthcdr (length own) kinds)
                    for arity = (transform-function-arity kind)
                    collect (%identity-parameters
                             kind (and like (subseq (transform-list-parameters like) start (+ start arity))))
                    do (incf start arity)))))))

(defun transform-lists-shape (first second)
  "The kinds two lists animate between, the longer when the other begins it as CSS
pads lists, and whether they can."
  (let ((long (transform-list-kinds first)) (short (transform-list-kinds second)))
    (when (< (length long) (length short)) (rotatef long short))
    (if (every #'eq short long) (values long t) (values nil nil))))

(defun view-transform (x y zoom rotation viewport-width viewport-height)
  "Map world space to output-logical space, centering world point (X, Y)."
  (let* ((cosine (* zoom (cos rotation)))
         (sine (- (* zoom (sin rotation)))))
    ;; T(viewport center) · R(-rotation) · S(zoom) · T(-x, -y), expanded.
    (make-transform cosine sine (- sine) cosine
                    (- (/ viewport-width 2d0) (- (* cosine x) (* sine y)))
                    (- (/ viewport-height 2d0) (+ (* sine x) (* cosine y))))))

(defun output-buffer-transform (logical-width logical-height buffer-width buffer-height transform)
  "Map output-logical coordinates to buffer pixels for a wl_output TRANSFORM."
  (flet ((buffer-point (x y)
           (multiple-value-bind (u v)
               (ataxia.world:transform-normalized-point
                transform (/ x logical-width) (/ y logical-height))
             (values (* u buffer-width) (* v buffer-height)))))
    (multiple-value-bind (x0 y0) (buffer-point 0d0 0d0)
      (multiple-value-bind (x1 y1) (buffer-point logical-width 0d0)
        (multiple-value-bind (x2 y2) (buffer-point 0d0 logical-height)
          (make-transform (/ (- x1 x0) logical-width) (/ (- y1 y0) logical-width)
                          (/ (- x2 x0) logical-height) (/ (- y2 y0) logical-height)
                          x0 y0))))))
