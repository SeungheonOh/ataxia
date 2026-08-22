;;;; Direct GLES renderer for the tiling World.
;;;;
;;;; The renderer consumes component surfaces without knowing their origin. It
;;;; draws output-local tiles, focus borders, and one cursor per logical seat.

(in-package #:ataxia.tiling-world)

(defparameter +tiling-vertex-shader+
  "attribute vec2 a_position;
attribute vec2 a_uv;
varying vec2 v_uv;
void main() {
  gl_Position = vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
}")

(defparameter +tiling-solid-fragment-shader+
  "precision mediump float;
uniform vec4 u_color;
void main() { gl_FragColor = vec4(u_color.rgb * u_color.a, u_color.a); }")

(defun %tiling-texture-fragment-shader (external-p)
  (format nil
          "~:[~;#extension GL_OES_EGL_image_external : require~%~]precision highp float;
uniform ~:[sampler2D~;samplerExternalOES~] u_texture;
uniform float u_has_alpha;
varying vec2 v_uv;
void main() {
  vec4 sample_value = texture2D(u_texture, v_uv);
  sample_value.a = mix(1.0, sample_value.a, u_has_alpha);
  gl_FragColor = sample_value;
}"
          external-p external-p))

(defstruct (%tiling-renderer (:constructor %make-tiling-renderer))
  solid-program texture-program external-program
  (vertex-buffer 0 :type (unsigned-byte 32)))

(defun %create-tiling-renderer ()
  (let ((renderer (%make-tiling-renderer)))
    (handler-case
        (progn
          (setf (%tiling-renderer-solid-program renderer)
                (ataxia.world.gles:make-gles-program
                 +tiling-vertex-shader+ +tiling-solid-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%tiling-renderer-texture-program renderer)
                (ataxia.world.gles:make-gles-program
                 +tiling-vertex-shader+ (%tiling-texture-fragment-shader nil)
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%tiling-renderer-external-program renderer)
                (ignore-errors
                  (ataxia.world.gles:make-gles-program
                   +tiling-vertex-shader+ (%tiling-texture-fragment-shader t)
                   :attributes '(("a_position" . 0) ("a_uv" . 1))))
                (%tiling-renderer-vertex-buffer renderer)
                (ataxia.world.gles:gles-create-buffer))
          (ataxia.world.gles:gles-check-error "tiling renderer creation")
          renderer)
      (serious-condition (cause)
        (ignore-errors (%destroy-tiling-renderer renderer))
        (error cause)))))

(defun %destroy-tiling-renderer (renderer)
  (when renderer
    (dolist (program
              (list (%tiling-renderer-solid-program renderer)
                    (%tiling-renderer-texture-program renderer)
                    (%tiling-renderer-external-program renderer)))
      (ataxia.world.gles:destroy-gles-program program))
    (setf (%tiling-renderer-vertex-buffer renderer)
          (ataxia.world.gles:gles-destroy-buffer
           (%tiling-renderer-vertex-buffer renderer))))
  nil)

(defun %ndc-point (state x y)
  (values (- (* 2d0 (/ x (%tiling-output-buffer-width state))) 1d0)
          (- (* 2d0 (/ y (%tiling-output-buffer-height state))) 1d0)))

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
   (%tiling-renderer-vertex-buffer renderer) vertices)
  (let ((stride (* 4 (cffi:foreign-type-size :float))))
    (ataxia.world.gles:gles-enable-attribute 0 2 stride 0)
    (ataxia.world.gles:gles-enable-attribute
     1 2 stride (* 2 (cffi:foreign-type-size :float)))))

(defun %draw-solid (renderer state x y width height color)
  (let ((program (%tiling-renderer-solid-program renderer)))
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

(defun %draw-surface (renderer state surface x y width height)
  (let* ((source (ataxia.kernel:drawable-surface-render-source surface))
         (target (ataxia.kernel:render-source-gles-target source))
         (external-p (= target ataxia.world.gles:+texture-external-oes+))
         (program
           (if external-p
               (%tiling-renderer-external-program renderer)
               (%tiling-renderer-texture-program renderer))))
    (unless program
      (error "Tiling renderer cannot sample texture target 0x~X." target))
    (%bind-vertices
     renderer
     (%quad-vertices (%screen-quad state x y width height)
                     (%source-uv surface)))
    (ataxia.world.gles:gles-use-program program)
    (ataxia.world.gles:gles-bind-texture
     target (ataxia.kernel:render-source-gles-name source))
    (ataxia.world.gles:gles-uniform-1i program "u_texture" 0)
    (ataxia.world.gles:gles-uniform-1f
     program "u_has_alpha"
     (if (ataxia.kernel:render-source-has-alpha-p source) 1d0 0d0))
    (ataxia.world.gles:call-with-gles-linear-filter
     target (lambda () (ataxia.world.gles:gles-draw-triangles 6)))))

(defun %tile-buffer-coverage (world state node &optional (timestamp (%now)))
  (multiple-value-bind (x y width height) (%tile-geometry world node timestamp)
    (when x (%screen-rectangle-to-buffer state x y width height 3d0))))

(defun %tile-focused-p (world node)
  (some (lambda (seat-state) (eq node (%tiling-seat-focused seat-state)))
        (%seat-states world)))

(defun %draw-tile (renderer world state node timestamp tokens)
  (let ((component (tile-node-component node)))
    (multiple-value-bind (root-x root-y root-width root-height)
        (ataxia.kernel:drawable-local-bounds component)
      (when (and (plusp root-width) (plusp root-height))
        (multiple-value-bind (x y width height) (%tile-geometry world node timestamp)
          (when x
            (%draw-solid
             renderer state (- x 3d0) (- y 3d0) (+ width 6d0) (+ height 6d0)
             (if (%tile-focused-p world node)
                 '(0.05d0 0.55d0 0.88d0 1d0)
                 '(0.12d0 0.14d0 0.18d0 1d0)))
            (multiple-value-bind (surfaces revision)
                (ataxia.kernel:drawable-surfaces component)
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
                             (* width (/ (ataxia.kernel:drawable-surface-width surface)
                                         root-width)))
                           (surface-height
                             (* height (/ (ataxia.kernel:drawable-surface-height surface)
                                          root-height))))
                       (%draw-surface renderer state surface
                                      surface-x surface-y surface-width surface-height)
                       (let ((token
                               (ataxia.kernel:drawable-surface-protocol-token surface)))
                         (when token (pushnew token tokens :test #'eq)))))
                   surfaces)))))))
  tokens)

(defun %draw-solid-cursor (renderer state x y)
  (%draw-solid renderer state (- x 2d0) (- y 2d0) 5d0 29d0
               '(0.02d0 0.025d0 0.04d0 0.95d0))
  (%draw-solid renderer state x y 3d0 24d0 '(0.96d0 0.98d0 1d0 1d0)))

(defun %draw-seat-cursor (renderer state seat-state tokens)
  (let ((cursor (%tiling-seat-cursor-surface seat-state))
        (x (%tiling-seat-x seat-state))
        (y (%tiling-seat-y seat-state)))
    (if (and cursor (eq (ataxia.kernel:object-state cursor) :live))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces cursor)
          (declare (ignore revision))
          (map nil
               (lambda (surface)
                 (%draw-surface
                  renderer state surface
                  (+ (- x (%tiling-seat-cursor-hotspot-x seat-state))
                     (ataxia.kernel:drawable-surface-local-x surface))
                  (+ (- y (%tiling-seat-cursor-hotspot-y seat-state))
                     (ataxia.kernel:drawable-surface-local-y surface))
                  (ataxia.kernel:drawable-surface-width surface)
                  (ataxia.kernel:drawable-surface-height surface))
                 (let ((token
                         (ataxia.kernel:drawable-surface-protocol-token surface)))
                   (when token (pushnew token tokens :test #'eq))))
               surfaces))
        (%draw-solid-cursor renderer state x y))
    tokens))

(defun %render-tiling (renderer world state seats damage-region timestamp)
  (let ((tokens nil))
    (ataxia.world.gles:gles-reset-state)
    (ataxia.world.gles:gles-set-scissor-enabled t)
    (dolist (damage damage-region)
      (let ((x (max 0 (floor (ataxia.world:rectangle-x damage))))
            (y (max 0 (floor (ataxia.world:rectangle-y damage))))
            (width (ceiling (ataxia.world:rectangle-width damage)))
            (height (ceiling (ataxia.world:rectangle-height damage))))
        (ataxia.world.gles:gles-set-scissor x y width height)
        (ataxia.world.gles:gles-clear 0.025d0 0.029d0 0.039d0 1d0)
        (dolist (node (%presented-output-nodes world state))
          (let ((coverage (%tile-buffer-coverage world state node timestamp)))
            (when (and coverage
                       (ataxia.world:region-intersects-p coverage (list damage)))
              (setf tokens
                    (%draw-tile renderer world state node timestamp tokens)))))
        (dolist (seat-state seats)
          (when (eq state (%tiling-seat-output seat-state))
            (setf tokens
                  (%draw-seat-cursor renderer state seat-state tokens))))))
    (ataxia.world.gles:gles-set-scissor-enabled nil)
    (ataxia.world.gles:gles-disable-attribute 0)
    (ataxia.world.gles:gles-disable-attribute 1)
    (ataxia.world.gles:gles-flush)
    (ataxia.world.gles:gles-check-error "tiling frame")
    (coerce (nreverse tokens) 'vector)))
