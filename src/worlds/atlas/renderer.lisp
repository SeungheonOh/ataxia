;;;; Direct GLES renderer for the packed window plane.
;;;;
;;;; The renderer consumes only derived atlas placements. It draws the packed
;;;; plane, client surface trees, and one cursor per seat inside Kernel's active
;;;; frame lease; it does not retain EGL or output-buffer ownership.

(in-package #:ataxia.atlas-world)

(defparameter +atlas-vertex-shader+
  "attribute vec2 a_position;
attribute vec2 a_uv;
varying vec2 v_uv;
void main() {
  gl_Position = vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
}")

(defparameter +atlas-solid-fragment-shader+
  "precision mediump float;
uniform vec4 u_color;
void main() {
  gl_FragColor = vec4(u_color.rgb * u_color.a, u_color.a);
}")

(defun %atlas-texture-fragment-shader (external-p)
  (format nil
          "~:[~;#extension GL_OES_EGL_image_external : require~%~]precision highp float;
uniform ~:[sampler2D~;samplerExternalOES~] u_texture;
uniform float u_opacity;
uniform float u_has_alpha;
varying vec2 v_uv;
void main() {
  vec4 color = texture2D(u_texture, clamp(v_uv, 0.0, 1.0));
  color.a = mix(1.0, color.a, u_has_alpha);
  gl_FragColor = color * u_opacity;
}"
          external-p external-p))

(defstruct (%atlas-renderer (:constructor %make-atlas-renderer))
  solid-program texture-program external-program
  (vertex-buffer 0 :type (unsigned-byte 32)))

(defun %create-atlas-renderer ()
  (let ((renderer (%make-atlas-renderer)))
    (handler-case
        (progn
          (setf (%atlas-renderer-solid-program renderer)
                (ataxia.world.gles:make-gles-program
                 +atlas-vertex-shader+ +atlas-solid-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%atlas-renderer-texture-program renderer)
                (ataxia.world.gles:make-gles-program
                 +atlas-vertex-shader+ (%atlas-texture-fragment-shader nil)
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%atlas-renderer-external-program renderer)
                (ignore-errors
                  (ataxia.world.gles:make-gles-program
                   +atlas-vertex-shader+ (%atlas-texture-fragment-shader t)
                   :attributes '(("a_position" . 0) ("a_uv" . 1))))
                (%atlas-renderer-vertex-buffer renderer)
                (ataxia.world.gles:gles-create-buffer))
          (ataxia.world.gles:gles-check-error "atlas renderer creation")
          renderer)
      (serious-condition (cause)
        (ignore-errors (%destroy-atlas-renderer renderer))
        (error cause)))))

(defun %destroy-atlas-renderer (renderer)
  (when renderer
    (dolist (program
              (list (%atlas-renderer-solid-program renderer)
                    (%atlas-renderer-texture-program renderer)
                    (%atlas-renderer-external-program renderer)))
      (ataxia.world.gles:destroy-gles-program program))
    (setf (%atlas-renderer-vertex-buffer renderer)
          (ataxia.world.gles:gles-destroy-buffer
           (%atlas-renderer-vertex-buffer renderer))))
  nil)

(defun %output-logical-size (state)
  (let* ((output (%atlas-output-output state))
         (scale (max 0.01d0
                     (coerce (ataxia.kernel:output-scale output)
                             'double-float)))
         (width (/ (ataxia.kernel:output-width output) scale))
         (height (/ (ataxia.kernel:output-height output) scale)))
    (if (member (ataxia.kernel:output-transform output) '(1 3 5 7))
        (values height width)
        (values width height))))

(defun %world-to-screen (state x y)
  (values (* (- x (%atlas-output-camera-x state))
             (%atlas-output-zoom state))
          (* (- y (%atlas-output-camera-y state))
             (%atlas-output-zoom state))))

(defun %screen-to-world (state x y)
  (values (+ (%atlas-output-camera-x state)
             (/ x (%atlas-output-zoom state)))
          (+ (%atlas-output-camera-y state)
             (/ y (%atlas-output-zoom state)))))

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
         (%atlas-output-transform state)
         (/ x logical-width) (/ y logical-height))
      (values (* transformed-x (%atlas-output-buffer-width state))
              (* transformed-y (%atlas-output-buffer-height state))))))

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

(defun %window-screen-geometry (state layout window timestamp)
  (multiple-value-bind (x y width height)
      (%placement-geometry layout window timestamp)
    (when x
      (multiple-value-bind (screen-x screen-y) (%world-to-screen state x y)
        (let ((zoom (%atlas-output-zoom state)))
          (values screen-x screen-y (* width zoom) (* height zoom)))))))

(defun %window-buffer-coverage (state layout window timestamp)
  (multiple-value-bind (x y width height)
      (%window-screen-geometry state layout window timestamp)
    (when x
      (%screen-rectangle-to-buffer state x y width height 3d0))))

(defun %panel-buffer-coverage (state panel)
  (multiple-value-bind (x y width height) (%panel-screen-geometry panel)
    (%screen-rectangle-to-buffer state x y width height)))

(defun %ndc-point (state x y)
  (values (- (* 2d0 (/ x (%atlas-output-buffer-width state))) 1d0)
          (- (* 2d0 (/ y (%atlas-output-buffer-height state))) 1d0)))

(defun %screen-quad (state x y width height)
  (mapcar
   (lambda (point)
     (multiple-value-bind (buffer-x buffer-y)
         (%screen-point-to-buffer state (car point) (cdr point))
       (multiple-value-bind (ndc-x ndc-y) (%ndc-point state buffer-x buffer-y)
         (cons ndc-x ndc-y))))
   (list (cons x y) (cons (+ x width) y)
         (cons x (+ y height)) (cons (+ x width) (+ y height)))))

(defun %quad-vertices (positions texture-coordinates)
  (flet ((vertex (index)
           (list (car (nth index positions)) (cdr (nth index positions))
                 (car (nth index texture-coordinates))
                 (cdr (nth index texture-coordinates)))))
    (coerce (mapcan #'vertex '(0 1 2 1 3 2)) 'vector)))

(defun %bind-vertices (renderer vertices)
  (ataxia.world.gles:gles-upload-floats
   (%atlas-renderer-vertex-buffer renderer) vertices)
  (let ((stride (* 4 (cffi:foreign-type-size :float))))
    (ataxia.world.gles:gles-enable-attribute 0 2 stride 0)
    (ataxia.world.gles:gles-enable-attribute
     1 2 stride (* 2 (cffi:foreign-type-size :float)))))

(defun %draw-solid (renderer state x y width height color)
  (let ((program (%atlas-renderer-solid-program renderer)))
    (%bind-vertices
     renderer
     (%quad-vertices
      (%screen-quad state x y width height)
      (list (cons 0d0 0d0) (cons 1d0 0d0)
            (cons 0d0 1d0) (cons 1d0 1d0))))
    (ataxia.world.gles:gles-use-program program)
    (apply #'ataxia.world.gles:gles-uniform-4f program "u_color" color)
    (ataxia.world.gles:gles-draw-triangles 6)))

(defun %source-uv (surface)
  (let* ((box (ataxia.kernel:drawable-surface-source-box surface))
         (left (aref box 0))
         (top (aref box 1))
         (width (aref box 2))
         (height (aref box 3))
         (transform (ataxia.kernel:drawable-surface-buffer-transform surface)))
    (mapcar
     (lambda (point)
       (multiple-value-bind (u v)
           (%transform-normalized-point
            (case transform (1 3) (3 1) (otherwise transform))
            (car point) (cdr point))
         (cons (+ left (* u width)) (+ top (* v height)))))
     (list (cons 0d0 0d0) (cons 1d0 0d0)
           (cons 0d0 1d0) (cons 1d0 1d0)))))

(defun %draw-surface (renderer state surface x y width height opacity)
  (let* ((source (ataxia.kernel:drawable-surface-render-source surface))
         (target (ataxia.kernel:render-source-gles-target source))
         (external-p (= target ataxia.world.gles:+texture-external-oes+))
         (program
           (if external-p
               (%atlas-renderer-external-program renderer)
               (%atlas-renderer-texture-program renderer))))
    (unless program
      (error "Atlas renderer cannot sample texture target 0x~X." target))
    (%bind-vertices
     renderer
     (%quad-vertices (%screen-quad state x y width height)
                     (%source-uv surface)))
    (ataxia.world.gles:gles-use-program program)
    (ataxia.world.gles:gles-bind-texture
     target (ataxia.kernel:render-source-gles-name source))
    (ataxia.world.gles:gles-uniform-1i program "u_texture" 0)
    (ataxia.world.gles:gles-uniform-1f program "u_opacity" opacity)
    (ataxia.world.gles:gles-uniform-1f
     program "u_has_alpha"
     (if (ataxia.kernel:render-source-has-alpha-p source) 1d0 0d0))
    (ataxia.world.gles:call-with-gles-linear-filter
     target (lambda () (ataxia.world.gles:gles-draw-triangles 6)))))

(defun %window-opacity (window timestamp)
  (let ((start (%atlas-window-appearance-start window)))
    (if start
        (ataxia.world:ease-out-cubic
         (max 0d0 (min 1d0 (/ (- timestamp start) 0.18d0))))
        1d0)))

(defun %draw-window (renderer state layout window timestamp tokens)
  (let ((application (atlas-window-application window)))
    (multiple-value-bind (root-x root-y root-width root-height)
        (ataxia.kernel:drawable-local-bounds application)
      (when (and (plusp root-width) (plusp root-height))
        (multiple-value-bind (x y width height)
            (%window-screen-geometry state layout window timestamp)
          (multiple-value-bind (surfaces revision)
              (ataxia.kernel:drawable-surfaces application)
            (declare (ignore revision))
            (map nil
                 (lambda (surface)
                   (let ((surface-x
                           (+ x (* width
                                   (/ (- (ataxia.kernel:drawable-surface-local-x surface)
                                         root-x)
                                      root-width))))
                         (surface-y
                           (+ y (* height
                                   (/ (- (ataxia.kernel:drawable-surface-local-y surface)
                                         root-y)
                                      root-height))))
                         (surface-width
                           (* width
                              (/ (ataxia.kernel:drawable-surface-width surface)
                                 root-width)))
                         (surface-height
                           (* height
                              (/ (ataxia.kernel:drawable-surface-height surface)
                                 root-height))))
                     (%draw-surface
                      renderer state surface surface-x surface-y
                      surface-width surface-height
                      (%window-opacity window timestamp))
                     (let ((token
                             (ataxia.kernel:drawable-surface-protocol-token
                              surface)))
                       (when token (pushnew token tokens :test #'eq)))))
                 surfaces))))))
  tokens)

(defun %draw-slint-panel (renderer state panel)
  (multiple-value-bind (x y width height) (%panel-screen-geometry panel)
    (declare (ignore width height))
    (multiple-value-bind (surfaces revision)
        (ataxia.kernel:drawable-surfaces (%panel-component panel))
      (declare (ignore revision))
      (map nil
           (lambda (surface)
             (%draw-surface
              renderer state surface
              (+ x (ataxia.kernel:drawable-surface-local-x surface))
              (+ y (ataxia.kernel:drawable-surface-local-y surface))
              (ataxia.kernel:drawable-surface-width surface)
              (ataxia.kernel:drawable-surface-height surface)
              1d0))
           surfaces))))

(defun %draw-solid-cursor (renderer state x y)
  (%draw-solid renderer state (- x 2d0) (- y 2d0) 5d0 29d0
               '(0.02d0 0.025d0 0.04d0 0.95d0))
  (%draw-solid renderer state x y 3d0 24d0 '(0.96d0 0.98d0 1d0 1d0)))

(defun %draw-seat-cursor (renderer state seat-state tokens)
  (let ((cursor (%atlas-seat-cursor-surface seat-state))
        (x (%atlas-seat-x seat-state))
        (y (%atlas-seat-y seat-state)))
    (if (and cursor (eq (ataxia.kernel:object-state cursor) :live))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces cursor)
          (declare (ignore revision))
          (map nil
               (lambda (surface)
                 (%draw-surface
                  renderer state surface
                  (+ (- x (%atlas-seat-cursor-hotspot-x seat-state))
                     (ataxia.kernel:drawable-surface-local-x surface))
                  (+ (- y (%atlas-seat-cursor-hotspot-y seat-state))
                     (ataxia.kernel:drawable-surface-local-y surface))
                  (ataxia.kernel:drawable-surface-width surface)
                  (ataxia.kernel:drawable-surface-height surface)
                  1d0)
                 (let ((token
                         (ataxia.kernel:drawable-surface-protocol-token surface)))
                   (when token (pushnew token tokens :test #'eq))))
               surfaces))
        (%draw-solid-cursor renderer state x y))
    tokens))

(defun %draw-atlas-plane (renderer state layout)
  (multiple-value-bind (x y) (%world-to-screen state 0d0 0d0)
    (%draw-solid
     renderer state x y
     (* (%atlas-layout-width layout) (%atlas-output-zoom state))
     (* (%atlas-layout-height layout) (%atlas-output-zoom state))
     '(0.018d0 0.021d0 0.029d0 1d0))))

(defun %render-atlas
    (renderer state layout windows panel seats damage-region timestamp)
  (let ((tokens nil))
    (ataxia.world.gles:gles-reset-state)
    (ataxia.world.gles:gles-set-scissor-enabled t)
    (dolist (damage damage-region)
      (let ((x (max 0 (floor (ataxia.world:rectangle-x damage))))
            (y (max 0 (floor (ataxia.world:rectangle-y damage))))
            (width (ceiling (ataxia.world:rectangle-width damage)))
            (height (ceiling (ataxia.world:rectangle-height damage))))
        (ataxia.world.gles:gles-set-scissor x y width height)
        (ataxia.world.gles:gles-clear 0.034d0 0.039d0 0.052d0 1d0)
        (%draw-atlas-plane renderer state layout)
        (dolist (window windows)
          (let ((coverage
                  (and (%window-visible-p window)
                       (%window-buffer-coverage
                        state layout window timestamp))))
            (when (and coverage
                       (ataxia.world:region-intersects-p coverage (list damage)))
              (setf tokens
                    (%draw-window
                     renderer state layout window timestamp tokens)))))
        (when (and panel
                   (ataxia.world:region-intersects-p
                    (%panel-buffer-coverage state panel) (list damage)))
          (%draw-slint-panel renderer state panel))
        (dolist (seat-state seats)
          (when (eq state (%atlas-seat-output seat-state))
            (setf tokens
                  (%draw-seat-cursor renderer state seat-state tokens))))))
    (ataxia.world.gles:gles-set-scissor-enabled nil)
    (ataxia.world.gles:gles-disable-attribute 0)
    (ataxia.world.gles:gles-disable-attribute 1)
    (ataxia.world.gles:gles-flush)
    (ataxia.world.gles:gles-check-error "packed atlas frame")
    (coerce (nreverse tokens) 'vector)))
