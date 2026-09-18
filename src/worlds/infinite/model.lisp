;;;; Infinite canvas state values and application attachment.
;;;;
;;;; CANVAS-WINDOW is the World-owned wrapper requested by the architecture: it
;;;; attaches unbounded placement and presentation state to a stable Kernel
;;;; application without modifying or subclassing the Kernel object itself.

(in-package #:ataxia.infinite-world)

(defconstant +button-left+ 272)
(defconstant +button-middle+ 274)
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
   (minimized-p :initform nil :accessor %canvas-window-minimized-p)
   (expanded-state :initform nil :accessor %canvas-window-expanded-state)
   (z :initform 0 :accessor %canvas-window-z)
   (visibility-opacity :initform 1d0 :accessor %canvas-window-visibility-opacity)
   (input-enabled-p :initform t :accessor %canvas-window-input-enabled-p)
   (lift-offset :initform 10d0 :accessor %canvas-window-lift-offset)
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

(defstruct (%canvas-output (:constructor %make-canvas-output (output)))
  output
  (camera-x 0d0 :type double-float)
  (camera-y 0d0 :type double-float)
  (zoom 1d0 :type double-float)
  (rotation 0d0 :type double-float)
  (target-rotation 0d0 :type double-float)
  (last-rotation-time 0d0 :type double-float)
  (buffer-width 0 :type integer)
  (buffer-height 0 :type integer)
  (transform 0 :type integer))

(defstruct (%canvas-seat (:constructor %make-canvas-seat (seat)))
  seat output
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  (buttons (make-hash-table :test #'eql))
  focused hovered operation previous-focus
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
  (ataxia.world:output-logical-size (%canvas-output-output state)))

(defun %rotate-screen-point (state x y radians)
  (multiple-value-bind (width height) (%output-logical-size state)
    (let* ((center-x (/ width 2d0))
           (center-y (/ height 2d0))
           (delta-x (- x center-x))
           (delta-y (- y center-y))
           (cosine (cos radians))
           (sine (sin radians)))
      (values (+ center-x (- (* cosine delta-x) (* sine delta-y)))
              (+ center-y (* sine delta-x) (* cosine delta-y))))))

(defun %canvas-to-screen (state x y)
  (%rotate-screen-point state x y (%canvas-output-rotation state)))

(defun %screen-to-canvas (state x y)
  (%rotate-screen-point state x y (- (%canvas-output-rotation state))))

(defun %screen-vector-to-canvas (state x y)
  (let* ((radians (- (%canvas-output-rotation state)))
         (cosine (cos radians))
         (sine (sin radians)))
    (values (- (* cosine x) (* sine y))
            (+ (* sine x) (* cosine y)))))

(defun %canvas-vector-to-screen (state x y)
  (let* ((radians (%canvas-output-rotation state))
         (cosine (cos radians))
         (sine (sin radians)))
    (values (- (* cosine x) (* sine y))
            (+ (* sine x) (* cosine y)))))

(defun %oriented-screen-point (state anchor-x anchor-y x y)
  (multiple-value-bind (delta-x delta-y)
      (%canvas-vector-to-screen state (- x anchor-x) (- y anchor-y))
    (values (+ anchor-x delta-x) (+ anchor-y delta-y))))

(defun %screen-to-world (state x y)
  (multiple-value-bind (canvas-x canvas-y) (%screen-to-canvas state x y)
    (values (+ (%canvas-output-camera-x state)
               (/ canvas-x (%canvas-output-zoom state)))
            (+ (%canvas-output-camera-y state)
               (/ canvas-y (%canvas-output-zoom state))))))

(defun %world-to-canvas (state x y)
  (values (* (- x (%canvas-output-camera-x state))
             (%canvas-output-zoom state))
          (* (- y (%canvas-output-camera-y state))
             (%canvas-output-zoom state))))

(defun %transform-normalized-point (transform x y)
  (ataxia.world:transform-normalized-point transform x y))
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

(defun %oriented-screen-rectangle-to-buffer
    (state anchor-x anchor-y x y width height &optional (margin 0d0))
  (let ((points nil))
    (dolist (point (list (list (- x margin) (- y margin))
                         (list (+ x width margin) (- y margin))
                         (list (- x margin) (+ y height margin))
                         (list (+ x width margin) (+ y height margin))))
      (multiple-value-bind (screen-x screen-y)
          (%oriented-screen-point
           state anchor-x anchor-y (first point) (second point))
        (multiple-value-bind (buffer-x buffer-y)
            (%screen-point-to-buffer state screen-x screen-y)
          (push (cons buffer-x buffer-y) points))))
    (let ((left (reduce #'min points :key #'car))
          (top (reduce #'min points :key #'cdr))
          (right (reduce #'max points :key #'car))
          (bottom (reduce #'max points :key #'cdr)))
      (ataxia.world:make-rectangle left top (- right left) (- bottom top)))))

(defun %canvas-rectangle-to-buffer (state x y width height &optional (margin 0d0))
  (let ((points nil))
    (dolist (point (list (list (- x margin) (- y margin))
                         (list (+ x width margin) (- y margin))
                         (list (- x margin) (+ y height margin))
                         (list (+ x width margin) (+ y height margin))))
      (multiple-value-bind (screen-x screen-y)
          (%canvas-to-screen state (first point) (second point))
        (multiple-value-bind (buffer-x buffer-y)
            (%screen-point-to-buffer state screen-x screen-y)
          (push (cons buffer-x buffer-y) points))))
    (let ((left (reduce #'min points :key #'car))
          (top (reduce #'min points :key #'cdr))
          (right (reduce #'max points :key #'car))
          (bottom (reduce #'max points :key #'cdr)))
      (ataxia.world:make-rectangle left top (- right left) (- bottom top)))))

(defun %window-canvas-geometry (state window)
  (multiple-value-bind (screen-x screen-y)
      (%world-to-canvas state (canvas-window-x window) (canvas-window-y window))
    (let* ((zoom (%canvas-output-zoom state))
           (width (* (canvas-window-width window) zoom))
           (height (* (canvas-window-height window) zoom))
           (scale (canvas-window-scale window))
           (scaled-width (* width scale))
           (scaled-height (* height scale)))
      (values (+ screen-x (/ (- width scaled-width) 2d0))
              (+ screen-y (/ (- height scaled-height) 2d0)
                 (- (* (%canvas-window-lift-offset window) (canvas-window-elevation window))))
              scaled-width scaled-height))))

(defun %map-window-surfaces (state window function)
  "Visit committed quads with the same canvas geometry used for drawing."
  (let* ((application (canvas-window-application window))
         (surfaces (ataxia.kernel:drawable-surfaces application)))
    (when (plusp (length surfaces))
      (multiple-value-bind (root-x root-y root-width root-height)
          (ataxia.kernel:drawable-local-bounds application)
        (when (and (plusp root-width) (plusp root-height))
          (multiple-value-bind (x y width height) (%window-canvas-geometry state window)
            (let ((scale-x (/ width root-width)) (scale-y (/ height root-height)))
              (map nil
                   (lambda (surface)
                     (funcall function surface
                              (+ x (* scale-x (- (ataxia.kernel:drawable-surface-local-x surface) root-x)))
                              (+ y (* scale-y (- (ataxia.kernel:drawable-surface-local-y surface) root-y)))
                              (* scale-x (ataxia.kernel:drawable-surface-width surface))
                              (* scale-y (ataxia.kernel:drawable-surface-height surface))))
                   surfaces))))))))

(defun %window-buffer-coverage (state window)
  (multiple-value-bind (x y width height)
      (%window-canvas-geometry state window)
    (let ((coverage (%canvas-rectangle-to-buffer
                     state x y width height (+ 28d0 (* 14d0 (canvas-window-elevation window))))))
      ;; Popups and subsurfaces can extend beyond the root's window geometry.
      (%map-window-surfaces
       state window (lambda (surface sx sy sw sh)
                      (declare (ignore surface))
                      (setf coverage (ataxia.world:rectangle-union
                                      coverage (%canvas-rectangle-to-buffer state sx sy sw sh 1d0)))))
      coverage)))

(defun %overlay-buffer-coverage (state overlay)
  (%screen-rectangle-to-buffer
   state
   (overlay-x overlay) (overlay-y overlay)
   (overlay-width overlay) (overlay-height overlay)))

(defun %overlay-on-state-p (overlay state)
  (eq (overlay-output overlay) (%canvas-output-output state)))

(defun %overlay-visible-on-state-p (overlay state)
  (and (overlay-visible-p overlay)
       (plusp (overlay-opacity overlay))
       (%overlay-on-state-p overlay state)))

(defun %window-opacity (window)
  (* (canvas-window-opacity window) (%canvas-window-visibility-opacity window)))

(defun %window-visible-p (window)
  (and (%canvas-window-mapped-p window)
       (not (%canvas-window-minimized-p window))
       (not (%canvas-window-hidden-p window))
       (plusp (%window-opacity window))))
