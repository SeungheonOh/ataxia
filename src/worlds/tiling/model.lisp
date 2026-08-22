;;;; Tiling World state.
;;;;
;;;; TILE-NODE attaches tiling policy to a component without modifying the
;;;; Kernel object. Outputs own independent master-stack parameters and seats
;;;; own focus, pointer capture, cursor, and shortcut state.

(in-package #:ataxia.tiling-world)

(defconstant +button-left+ 272)
(defconstant +modifier-shift+ #x01)
(defconstant +modifier-logo+ #x40)
(defconstant +key-q+ 16)
(defconstant +key-enter+ 28)
(defconstant +key-h+ 35)
(defconstant +key-j+ 36)
(defconstant +key-k+ 37)
(defconstant +key-l+ 38)
(defconstant +key-f+ 33)
(defconstant +key-space+ 57)

(defclass tile-node ()
  ((component :initarg :component :reader tile-node-component)
   (output-state :initarg :output-state :accessor %tile-output-state)
   (mapped-p :initform nil :accessor %tile-mapped-p)
   (hidden-p :initform nil :accessor %tile-hidden-p)
   (fullscreen-p :initform nil :accessor %tile-fullscreen-p)
   (drawable-revision :initform 0 :accessor %tile-drawable-revision))
  (:documentation "World-owned tiling state for one drawable and interactable component."))

(defmethod initialize-instance :after ((node tile-node) &key)
  (unless (typep (tile-node-component node) 'ataxia.kernel:drawable)
    (error "TILE-NODE requires a drawable component."))
  (unless (typep (tile-node-component node) 'ataxia.kernel:interactable)
    (error "TILE-NODE requires an interactable component.")))

(defstruct (%tile-rectangle
             (:constructor %make-tile-rectangle (x y width height)))
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  (width 0d0 :type double-float)
  (height 0d0 :type double-float))

(defstruct (%tiling-layout (:constructor %make-tiling-layout))
  (placements (make-hash-table :test #'eq))
  previous
  (transition-start 0d0 :type double-float)
  (transition-duration 0.16d0 :type double-float))

(defstruct (%tiling-output (:constructor %make-tiling-output (output)))
  output
  (master-ratio 0.60d0 :type double-float)
  (buffer-width 0 :type integer)
  (buffer-height 0 :type integer)
  (transform 0 :type integer))

(defstruct (%tiling-seat (:constructor %make-tiling-seat (seat)))
  seat output
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  focused hovered last-pointer-input drag-node
  (buttons (make-hash-table :test #'eql))
  (modifiers 0 :type integer)
  (consumed-keys (make-hash-table :test #'eql))
  cursor-surface
  (cursor-hotspot-x 0 :type integer)
  (cursor-hotspot-y 0 :type integer))

(defstruct (%world-frame-cookie
             (:constructor %make-world-frame-cookie (damage-frame)))
  damage-frame)

(defclass tiling-world (ataxia.kernel:world)
  ((kernel :initform nil :accessor ataxia.kernel:world-kernel)
   (kernel-index :initform (make-hash-table :test #'eq)
                 :reader %world-kernel-index)
   (nodes :initform nil :accessor %world-nodes)
   (layout :initform (%make-tiling-layout) :reader %world-layout)
   (outputs :initform (make-hash-table :test #'eq) :reader %world-outputs)
   (seats :initform (make-hash-table :test #'eq) :reader %world-seats)
   (damage :initform (ataxia.world:make-damage-tracker) :reader %world-damage)
   (renderer :initform nil :accessor %world-renderer)
   (quiescing-p :initform nil :accessor %world-quiescing-p))
  (:documentation "Per-output master-stack tiling policy and direct GLES renderer."))

(defun make-tiling-world ()
  (make-instance 'tiling-world))

(defun find-tile-node (world component)
  (gethash component (%world-kernel-index world)))

(defun %hash-values (table)
  (loop for value being the hash-values of table collect value))

(defun %output-states (world)
  (%hash-values (%world-outputs world)))

(defun %seat-states (world)
  (%hash-values (%world-seats world)))

(defun %first-output-state (world)
  (first (%output-states world)))

(defun %output-logical-size (state)
  (let* ((output (%tiling-output-output state))
         (scale (max 0.01d0 (coerce (ataxia.kernel:output-scale output)
                                    'double-float)))
         (width (/ (ataxia.kernel:output-width output) scale))
         (height (/ (ataxia.kernel:output-height output) scale)))
    (if (member (ataxia.kernel:output-transform output) '(1 3 5 7))
        (values height width)
        (values width height))))

(defun %visible-node-p (node)
  (and (%tile-mapped-p node) (not (%tile-hidden-p node))
       (%tile-output-state node)))

(defun %output-nodes (world state)
  (remove-if-not
   (lambda (node)
     (and (%visible-node-p node) (eq state (%tile-output-state node))))
   (%world-nodes world)))

(defun %presented-output-nodes (world state)
  (let* ((nodes (%output-nodes world state))
         (fullscreen (find-if #'%tile-fullscreen-p (reverse nodes))))
    (if fullscreen (list fullscreen) nodes)))

(defun %request-output-frame (world state)
  (when (and state (not (%world-quiescing-p world)))
    (ataxia.kernel:request-output-frame (%tiling-output-output state)))
  world)

(defun %request-all-frames (world)
  (dolist (state (%output-states world))
    (%request-output-frame world state))
  world)

(defun %transform-normalized-point (transform x y)
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

(defun %screen-point-to-buffer (state x y)
  (multiple-value-bind (logical-width logical-height)
      (%output-logical-size state)
    (multiple-value-bind (transformed-x transformed-y)
        (%transform-normalized-point
         (%tiling-output-transform state)
         (/ x logical-width) (/ y logical-height))
      (values (* transformed-x (%tiling-output-buffer-width state))
              (* transformed-y (%tiling-output-buffer-height state))))))

(defun %screen-rectangle-to-buffer (state x y width height &optional (margin 0d0))
  (let ((points nil))
    (dolist (point (list (list (- x margin) (- y margin))
                         (list (+ x width margin) (- y margin))
                         (list (- x margin) (+ y height margin))
                         (list (+ x width margin) (+ y height margin))))
      (multiple-value-bind (buffer-x buffer-y)
          (%screen-point-to-buffer state (first point) (second point))
        (push (cons buffer-x buffer-y) points)))
    (let ((left (reduce #'min points :key #'car))
          (top (reduce #'min points :key #'cdr))
          (right (reduce #'max points :key #'car))
          (bottom (reduce #'max points :key #'cdr)))
      (ataxia.world:make-rectangle left top (- right left) (- bottom top)))))
