;;;; Infinite canvas state values and application attachment.
;;;;
;;;; CANVAS-WINDOW is the World-owned wrapper requested by the architecture: it
;;;; attaches unbounded placement and presentation state to a stable Kernel
;;;; application without modifying or subclassing the Kernel object itself.

(in-package #:ataxia.infinite-world)

(defconstant +button-left+ 272)
(defconstant +button-middle+ 274)
(defconstant +modifier-logo+ #x40)
(defconstant +key-space+ 57)
(defconstant +resize-top+ 1)
(defconstant +resize-bottom+ 2)
(defconstant +resize-left+ 4)
(defconstant +resize-right+ 8)

(defclass canvas-window (ataxia.world:application-binding)
  ((x :initarg :x :accessor canvas-window-x)
   (y :initarg :y :accessor canvas-window-y)
   (width :initarg :width :accessor canvas-window-width)
   (height :initarg :height :accessor canvas-window-height)
   (mapped-p :initform nil :accessor %canvas-window-mapped-p)
   (hidden-p :initform nil :accessor %canvas-window-hidden-p)
   (z :initform 0 :accessor %canvas-window-z)
   (opacity :initform 1d0 :accessor canvas-window-opacity)
   (scale :initform 1d0 :accessor canvas-window-scale)
   (elevation :initform 0d0 :accessor canvas-window-elevation)
   (effect :initform 0d0 :accessor canvas-window-effect)
   (drawable-revision :initform 0 :accessor %canvas-window-drawable-revision)
   (restore-geometry :initform nil :accessor %canvas-window-restore-geometry)
   (animation-hooks
    :initform (make-hash-table :test #'equal)
    :reader canvas-window-animation-hooks))
  (:documentation
   "One infinite-World attachment for a Kernel Wayland application. All slots are World policy and may be changed live without adding state to Kernel."))

(defun canvas-window-application (window)
  (ataxia.world:binding-application window))

(defclass canvas-overlay ()
  ((component :initarg :component :reader canvas-overlay-component)
   (output :initarg :output :accessor canvas-overlay-output)
   (x :initarg :x :accessor canvas-overlay-x)
   (y :initarg :y :accessor canvas-overlay-y)
   (width :initarg :width :accessor canvas-overlay-width)
   (height :initarg :height :accessor canvas-overlay-height)
   (layer :initarg :layer :initform 0 :accessor canvas-overlay-layer)
   (visible-p :initarg :visible-p :initform nil
              :accessor canvas-overlay-visible-p)
   (opacity :initarg :opacity :initform 1d0
            :accessor canvas-overlay-opacity))
  (:documentation
   "Output-local drawable content composited above the World scene and below cursors. Interactable components also participate in input picking."))

(defmethod initialize-instance :after ((overlay canvas-overlay) &key)
  (unless (typep (canvas-overlay-component overlay) 'ataxia.kernel:drawable)
    (error "CANVAS-OVERLAY requires a drawable component.")))

(defun make-canvas-overlay
    (component output x y width height &key (layer 0) visible-p (opacity 1d0))
  (make-instance
   'canvas-overlay :component component :output output
   :x (coerce x 'double-float) :y (coerce y 'double-float)
   :width (coerce width 'double-float) :height (coerce height 'double-float)
   :layer layer :visible-p visible-p :opacity (coerce opacity 'double-float)))

(defgeneric %overlay-visibility-changed (overlay visible-p))

(defmethod %overlay-visibility-changed ((overlay canvas-overlay) visible-p)
  (declare (ignore visible-p))
  overlay)

(defgeneric %overlay-output-changed (overlay output-state))

(defmethod %overlay-output-changed
    ((overlay canvas-overlay) output-state)
  (declare (ignore output-state))
  overlay)

(defgeneric %destroy-overlay (overlay))

(defmethod %destroy-overlay ((overlay canvas-overlay))
  (ataxia.kernel:drawable-detach-graphics
   (canvas-overlay-component overlay))
  nil)

(defstruct (%canvas-output (:constructor %make-canvas-output (output)))
  output
  (camera-x 0d0 :type double-float)
  (camera-y 0d0 :type double-float)
  (zoom 1d0 :type double-float)
  (buffer-width 0 :type integer)
  (buffer-height 0 :type integer)
  (transform 0 :type integer))

(defstruct (%canvas-seat (:constructor %make-canvas-seat (seat)))
  seat output
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  (buttons (make-hash-table :test #'eql))
  focused hovered operation previous-focus
  (modifiers 0 :type integer)
  (launcher-shortcut-p nil :type boolean)
  cursor-surface
  (cursor-hotspot-x 0 :type integer)
  (cursor-hotspot-y 0 :type integer)
  cursor-coverage cursor-coverage-output)

(defstruct (%canvas-operation
             (:constructor %make-canvas-operation
                 (&key kind button window edges forward-release-p
                       cursor-x cursor-y camera-x camera-y window-x window-y
                       window-width window-height grab-x grab-y)))
  kind button window edges forward-release-p cursor-x cursor-y camera-x camera-y
  window-x window-y window-width window-height grab-x grab-y)

(defstruct (%world-frame-cookie
             (:constructor %make-world-frame-cookie (damage-frame)))
  damage-frame)

(defun %output-logical-size (state)
  (let* ((output (%canvas-output-output state))
         (scale (max 0.01d0 (coerce (ataxia.kernel:output-scale output)
                                    'double-float)))
         (width (/ (ataxia.kernel:output-width output) scale))
         (height (/ (ataxia.kernel:output-height output) scale)))
    (if (member (ataxia.kernel:output-transform output) '(1 3 5 7))
        (values height width)
        (values width height))))

(defun %screen-to-world (state x y)
  (values (+ (%canvas-output-camera-x state)
             (/ x (%canvas-output-zoom state)))
          (+ (%canvas-output-camera-y state)
             (/ y (%canvas-output-zoom state)))))

(defun %world-to-screen (state x y)
  (values (* (- x (%canvas-output-camera-x state))
             (%canvas-output-zoom state))
          (* (- y (%canvas-output-camera-y state))
             (%canvas-output-zoom state))))

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
         (%canvas-output-transform state)
         (/ x logical-width) (/ y logical-height))
      (values (* transformed-x (%canvas-output-buffer-width state))
              (* transformed-y (%canvas-output-buffer-height state))))))

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

(defun %window-screen-geometry (state window)
  (multiple-value-bind (screen-x screen-y)
      (%world-to-screen state (canvas-window-x window) (canvas-window-y window))
    (let* ((zoom (%canvas-output-zoom state))
           (width (* (canvas-window-width window) zoom))
           (height (* (canvas-window-height window) zoom))
           (scale (canvas-window-scale window))
           (scaled-width (* width scale))
           (scaled-height (* height scale)))
      (values (+ screen-x (/ (- width scaled-width) 2d0))
              (+ screen-y (/ (- height scaled-height) 2d0)
                 (* -10d0 (canvas-window-elevation window)))
              scaled-width scaled-height))))

(defun %window-buffer-coverage (state window)
  (multiple-value-bind (x y width height)
      (%window-screen-geometry state window)
    (%screen-rectangle-to-buffer
     state x y width height (+ 28d0 (* 14d0 (canvas-window-elevation window))))))

(defun %overlay-buffer-coverage (state overlay)
  (%screen-rectangle-to-buffer
   state
   (canvas-overlay-x overlay) (canvas-overlay-y overlay)
   (canvas-overlay-width overlay) (canvas-overlay-height overlay)))

(defun %overlay-on-state-p (overlay state)
  (eq (canvas-overlay-output overlay) (%canvas-output-output state)))

(defun %overlay-visible-on-state-p (overlay state)
  (and (canvas-overlay-visible-p overlay)
       (plusp (canvas-overlay-opacity overlay))
       (%overlay-on-state-p overlay state)))

(defun %window-visible-p (window)
  (and (%canvas-window-mapped-p window)
       (not (%canvas-window-hidden-p window))
       (plusp (canvas-window-opacity window))))
