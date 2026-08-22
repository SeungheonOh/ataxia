;;;; Direct GLES renderer for the infinite canvas.
;;;;
;;;; This implementation is independent of the fullscreen example. It renders
;;;; an infinite camera-relative grid, animated window materials, shadows, and
;;;; one cursor per seat while respecting the World's output damage region.

(in-package #:ataxia.infinite-world)

(defparameter +canvas-vertex-shader+
  "attribute vec2 a_position;
attribute vec2 a_uv;
varying vec2 v_uv;
void main() {
  gl_Position = vec4(a_position, 0.0, 1.0);
  v_uv = a_uv;
}")

(defparameter +solid-fragment-shader+
  "precision mediump float;
uniform vec4 u_color;
void main() {
  gl_FragColor = vec4(u_color.rgb * u_color.a, u_color.a);
}")

(defparameter +grid-fragment-shader+
  "precision highp float;
uniform vec2 u_camera;
uniform vec2 u_viewport;
uniform float u_zoom;
varying vec2 v_uv;
void main() {
  vec2 world = u_camera + (v_uv * u_viewport) / u_zoom;
  vec2 minor_cell = abs(fract(world / 32.0) - 0.5);
  vec2 major_cell = abs(fract(world / 160.0) - 0.5);
  float minor_line = 1.0 - step(0.035 * u_zoom, min(minor_cell.x, minor_cell.y));
  float major_line = 1.0 - step(0.018 * u_zoom, min(major_cell.x, major_cell.y));
  vec3 base = vec3(0.030, 0.036, 0.050);
  vec3 color = mix(base, vec3(0.065, 0.080, 0.110), minor_line);
  color = mix(color, vec3(0.115, 0.145, 0.200), major_line);
  gl_FragColor = vec4(color, 1.0);
}")

(defun %texture-fragment-shader (external-p)
  (format nil
          "~:[~;#extension GL_OES_EGL_image_external : require~%~]precision highp float;
uniform ~:[sampler2D~;samplerExternalOES~] u_texture;
uniform float u_opacity;
uniform float u_has_alpha;
uniform float u_effect;
uniform float u_seed;
varying vec2 v_uv;
float noise(vec2 point) {
  return fract(sin(dot(point, vec2(12.9898, 78.233)) + u_seed) * 43758.5453);
}
void main() {
  float band = floor(v_uv.y * 37.0 + u_seed * 11.0);
  float displacement = (noise(vec2(band, u_seed)) - 0.5) * 0.075 * u_effect;
  vec2 shifted = clamp(v_uv + vec2(displacement, 0.0), 0.0, 1.0);
  vec4 center = texture2D(u_texture, shifted);
  vec4 left_sample = texture2D(u_texture, clamp(shifted - vec2(0.009 * u_effect, 0.0), 0.0, 1.0));
  vec4 right_sample = texture2D(u_texture, clamp(shifted + vec2(0.009 * u_effect, 0.0), 0.0, 1.0));
  center.r = mix(center.r, right_sample.r, u_effect);
  center.b = mix(center.b, left_sample.b, u_effect);
  float dropout = step(0.965 - 0.10 * u_effect, noise(vec2(band, floor(u_seed * 19.0))));
  center.rgb = mix(center.rgb, center.bgr * 0.45, dropout * u_effect);
  center.a = mix(1.0, center.a, u_has_alpha);
  gl_FragColor = center * u_opacity;
}"
          external-p external-p))

(defstruct (%canvas-renderer (:constructor %make-canvas-renderer))
  solid-program grid-program texture-program external-program
  (vertex-buffer 0 :type (unsigned-byte 32)))

(defun %create-canvas-renderer ()
  (let ((renderer (%make-canvas-renderer)))
    (handler-case
        (progn
          (setf (%canvas-renderer-solid-program renderer)
                (ataxia.world.gles:make-gles-program
                 +canvas-vertex-shader+ +solid-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%canvas-renderer-grid-program renderer)
                (ataxia.world.gles:make-gles-program
                 +canvas-vertex-shader+ +grid-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%canvas-renderer-texture-program renderer)
                (ataxia.world.gles:make-gles-program
                 +canvas-vertex-shader+ (%texture-fragment-shader nil)
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%canvas-renderer-external-program renderer)
                (ignore-errors
                  (ataxia.world.gles:make-gles-program
                   +canvas-vertex-shader+ (%texture-fragment-shader t)
                   :attributes '(("a_position" . 0) ("a_uv" . 1))))
                (%canvas-renderer-vertex-buffer renderer)
                (ataxia.world.gles:gles-create-buffer))
          (ataxia.world.gles:gles-check-error "canvas renderer creation")
          renderer)
      (serious-condition (cause)
        (ignore-errors (%destroy-canvas-renderer renderer))
        (error cause)))))

(defun %destroy-canvas-renderer (renderer)
  (when renderer
    (dolist (program
              (list (%canvas-renderer-solid-program renderer)
                    (%canvas-renderer-grid-program renderer)
                    (%canvas-renderer-texture-program renderer)
                    (%canvas-renderer-external-program renderer)))
      (ataxia.world.gles:destroy-gles-program program))
    (setf (%canvas-renderer-vertex-buffer renderer)
          (ataxia.world.gles:gles-destroy-buffer
           (%canvas-renderer-vertex-buffer renderer))))
  nil)

(defun %ndc-point (state x y)
  (values (- (* 2d0 (/ x (%canvas-output-buffer-width state))) 1d0)
          (- (* 2d0 (/ y (%canvas-output-buffer-height state))) 1d0)))

(defun %screen-quad (state x y width height)
  (mapcar
   (lambda (point)
     (multiple-value-bind (buffer-x buffer-y)
         (%screen-point-to-buffer state (car point) (cdr point))
       (multiple-value-bind (ndc-x ndc-y)
           (%ndc-point state buffer-x buffer-y)
         (cons ndc-x ndc-y))))
   (list (cons x y) (cons (+ x width) y)
         (cons x (+ y height)) (cons (+ x width) (+ y height)))))

(defun %quad-vertices (positions texture-coordinates)
  (flet ((vertex (index)
           (list (car (nth index positions)) (cdr (nth index positions))
                 (car (nth index texture-coordinates))
                 (cdr (nth index texture-coordinates)))))
    (coerce
     (mapcan #'vertex '(0 1 2 1 3 2))
     'vector)))

(defun %bind-vertices (renderer vertices)
  (ataxia.world.gles:gles-upload-floats
   (%canvas-renderer-vertex-buffer renderer) vertices)
  (let ((stride (* 4 (cffi:foreign-type-size :float))))
    (ataxia.world.gles:gles-enable-attribute 0 2 stride 0)
    (ataxia.world.gles:gles-enable-attribute
     1 2 stride (* 2 (cffi:foreign-type-size :float)))))

(defun %draw-solid (renderer state x y width height color)
  (let* ((positions (%screen-quad state x y width height))
         (uv (list (cons 0d0 0d0) (cons 1d0 0d0)
                   (cons 0d0 1d0) (cons 1d0 1d0)))
         (program (%canvas-renderer-solid-program renderer)))
    (%bind-vertices renderer (%quad-vertices positions uv))
    (ataxia.world.gles:gles-use-program program)
    (apply #'ataxia.world.gles:gles-uniform-4f program "u_color" color)
    (ataxia.world.gles:gles-draw-triangles 6)))

(defun %draw-grid (renderer state)
  (multiple-value-bind (width height) (%output-logical-size state)
    (let ((program (%canvas-renderer-grid-program renderer)))
      (%bind-vertices
       renderer
       (%quad-vertices
        (%screen-quad state 0d0 0d0 width height)
        (list (cons 0d0 0d0) (cons 1d0 0d0)
              (cons 0d0 1d0) (cons 1d0 1d0))))
      (ataxia.world.gles:gles-use-program program)
      (ataxia.world.gles:gles-uniform-2f
       program "u_camera"
       (%canvas-output-camera-x state) (%canvas-output-camera-y state))
      (ataxia.world.gles:gles-uniform-2f program "u_viewport" width height)
      (ataxia.world.gles:gles-uniform-1f
       program "u_zoom" (%canvas-output-zoom state))
      (ataxia.world.gles:gles-draw-triangles 6))))

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
         (cons (+ left (* u width))
               (+ top (* v height)))))
     (list (cons 0d0 0d0) (cons 1d0 0d0)
           (cons 0d0 1d0) (cons 1d0 1d0)))))

(defun %draw-solid-triangle (renderer state points color)
  (let ((vertices
          (coerce
           (mapcan
            (lambda (point)
              (multiple-value-bind (buffer-x buffer-y)
                  (%screen-point-to-buffer state (car point) (cdr point))
                (multiple-value-bind (x y) (%ndc-point state buffer-x buffer-y)
                  (list x y 0d0 0d0))))
            points)
           'vector))
        (program (%canvas-renderer-solid-program renderer)))
    (%bind-vertices renderer vertices)
    (ataxia.world.gles:gles-use-program program)
    (apply #'ataxia.world.gles:gles-uniform-4f program "u_color" color)
    (ataxia.world.gles:gles-draw-triangles 3)))

(defun %draw-surface
    (renderer state surface x y width height opacity effect seed)
  (let* ((source (ataxia.kernel:drawable-surface-render-source surface))
         (target (ataxia.kernel:render-source-gles-target source))
         (external-p (= target ataxia.world.gles:+texture-external-oes+))
         (program
           (if external-p
               (%canvas-renderer-external-program renderer)
               (%canvas-renderer-texture-program renderer))))
    (unless program
      (error "The GLES renderer cannot sample texture target 0x~X." target))
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
    (ataxia.world.gles:gles-uniform-1f program "u_effect" effect)
    (ataxia.world.gles:gles-uniform-1f program "u_seed" seed)
    (ataxia.world.gles:call-with-gles-linear-filter
     target (lambda () (ataxia.world.gles:gles-draw-triangles 6)))))

(defun %draw-window-shadow (renderer state window)
  (multiple-value-bind (x y width height)
      (%window-screen-geometry state window)
    (let ((lift (canvas-window-elevation window)))
      (loop for layer from 4 downto 1
            for spread = (+ (* layer 4d0) (* lift 8d0))
            for alpha = (* (+ 0.018d0 (* lift 0.014d0)) (- 5 layer))
            do (%draw-solid renderer state
                            (- x spread) (+ y (* 5d0 lift) (- spread))
                            (+ width (* 2d0 spread))
                            (+ height (* 2d0 spread))
                            (list 0d0 0d0 0d0 alpha))))))

(defun %draw-window (renderer state window tokens)
  (let ((application (canvas-window-application window)))
    (multiple-value-bind (root-x root-y root-width root-height)
        (ataxia.kernel:drawable-local-bounds application)
      (declare (ignore root-x root-y))
      (when (and (plusp root-width) (plusp root-height))
        (multiple-value-bind (x y width height)
            (%window-screen-geometry state window)
          (%draw-window-shadow renderer state window)
          (multiple-value-bind (surfaces revision)
              (ataxia.kernel:drawable-surfaces application)
            (declare (ignore revision))
            (map nil
                 (lambda (surface)
                   (let* ((surface-x
                            (+ x (* width
                                    (/ (ataxia.kernel:drawable-surface-local-x surface)
                                       root-width))))
                          (surface-y
                            (+ y (* height
                                    (/ (ataxia.kernel:drawable-surface-local-y surface)
                                       root-height))))
                          (surface-width
                            (* width
                               (/ (ataxia.kernel:drawable-surface-width surface)
                                  root-width)))
                          (surface-height
                            (* height
                               (/ (ataxia.kernel:drawable-surface-height surface)
                                  root-height)))
                          (token
                            (ataxia.kernel:drawable-surface-protocol-token surface)))
                     (%draw-surface
                      renderer state surface
                      surface-x surface-y surface-width surface-height
                      (canvas-window-opacity window)
                      (canvas-window-effect window)
                      (coerce (mod (ataxia.kernel:object-id application) 997)
                              'double-float))
                     (when token (pushnew token tokens :test #'eq))))
                 surfaces))))))
  tokens)

(defun %draw-seat-cursor (renderer state seat-state tokens)
  (let ((cursor (%canvas-seat-cursor-surface seat-state))
        (x (%canvas-seat-x seat-state))
        (y (%canvas-seat-y seat-state)))
    (if (and cursor (eq (ataxia.kernel:object-state cursor) :live))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces cursor)
          (declare (ignore revision))
          (map nil
               (lambda (surface)
                 (%draw-surface
                  renderer state surface
                  (+ (- x (%canvas-seat-cursor-hotspot-x seat-state))
                     (ataxia.kernel:drawable-surface-local-x surface))
                  (+ (- y (%canvas-seat-cursor-hotspot-y seat-state))
                     (ataxia.kernel:drawable-surface-local-y surface))
                  (ataxia.kernel:drawable-surface-width surface)
                  (ataxia.kernel:drawable-surface-height surface)
                  1d0 0d0 0d0)
                 (let ((token
                         (ataxia.kernel:drawable-surface-protocol-token surface)))
                   (when token (pushnew token tokens :test #'eq))))
               surfaces))
        (progn
          (%draw-solid-triangle
           renderer state
           (list (cons (- x 2d0) (- y 2d0))
                 (cons (- x 2d0) (+ y 28d0))
                 (cons (+ x 20d0) (+ y 18d0)))
           '(0.02d0 0.025d0 0.04d0 0.95d0))
          (%draw-solid-triangle
           renderer state
           (list (cons x y) (cons x (+ y 24d0))
                 (cons (+ x 17d0) (+ y 16d0)))
           '(0.96d0 0.98d0 1d0 1d0))))
    tokens))

(defun %render-canvas (renderer output-state windows seats damage-region)
  (let ((tokens nil))
    (ataxia.world.gles:gles-reset-state)
    (ataxia.world.gles:gles-set-scissor-enabled t)
    (dolist (damage damage-region)
      (let ((x (max 0 (floor (ataxia.world:rectangle-x damage))))
            (y (max 0 (floor (ataxia.world:rectangle-y damage))))
            (width (ceiling (ataxia.world:rectangle-width damage)))
            (damage-height (ceiling (ataxia.world:rectangle-height damage))))
        (ataxia.world.gles:gles-set-scissor x y width damage-height)
        (ataxia.world.gles:gles-clear 0.03d0 0.036d0 0.05d0 1d0)
        (%draw-grid renderer output-state)
        (dolist (window windows)
          (when (and (%window-visible-p window)
                     (ataxia.world:region-intersects-p
                      (%window-buffer-coverage output-state window)
                      (list damage)))
            (setf tokens (%draw-window renderer output-state window tokens))))
        (dolist (seat-state seats)
          (when (eq output-state (%canvas-seat-output seat-state))
            (setf tokens
                  (%draw-seat-cursor renderer output-state seat-state tokens))))))
    (ataxia.world.gles:gles-set-scissor-enabled nil)
    (ataxia.world.gles:gles-disable-attribute 0)
    (ataxia.world.gles:gles-disable-attribute 1)
    (ataxia.world.gles:gles-flush)
    (ataxia.world.gles:gles-check-error "infinite canvas frame")
    (coerce (nreverse tokens) 'vector)))
