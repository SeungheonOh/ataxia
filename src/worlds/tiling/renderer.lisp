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

(defparameter +tiling-border-fragment-shader+
  "precision highp float;
uniform vec4 u_color_a;
uniform vec4 u_color_b;
uniform float u_phase;
varying vec2 v_uv;
void main() {
  float angle = u_phase * 2.4;
  vec2 axis = vec2(cos(angle), sin(angle));
  float wave = 0.5 + 0.5 * sin(6.2831853 * (dot(v_uv - 0.5, axis) + u_phase));
  vec4 color = mix(u_color_a, u_color_b, wave);
  gl_FragColor = vec4(color.rgb * color.a, color.a);
}")

(defparameter +tiling-shadow-fragment-shader+
  "precision mediump float;
uniform float u_strength;
varying vec2 v_uv;
void main() {
  vec2 edge = abs(v_uv - 0.5) * 2.0;
  float distance_to_edge = max(edge.x, edge.y);
  float alpha = (1.0 - smoothstep(0.52, 1.0, distance_to_edge)) * u_strength;
  gl_FragColor = vec4(0.008 * alpha, 0.018 * alpha, 0.040 * alpha, alpha);
}")

(defun %tiling-texture-fragment-shader (external-p)
  (format nil
          "~:[~;#extension GL_OES_EGL_image_external : require~%~]precision highp float;
uniform ~:[sampler2D~;samplerExternalOES~] u_texture;
uniform float u_has_alpha;
uniform float u_opacity;
uniform float u_effect;
uniform float u_seed;
varying vec2 v_uv;
float noise(vec2 point) {
  return fract(sin(dot(point, vec2(12.9898, 78.233)) + u_seed) * 43758.5453);
}
void main() {
  float band = floor((v_uv.y + noise(vec2(u_seed, 3.7)) * 0.013) * 61.0);
  float active = step(0.57, noise(vec2(band, floor(u_effect * 23.0))));
  float displacement = (noise(vec2(band, u_seed)) - 0.5) * 0.085 * u_effect * active;
  float wave = sin((v_uv.y * 29.0 + u_seed * 7.0) * 6.2831853) * 0.004 * u_effect;
  vec2 shifted = clamp(v_uv + vec2(displacement + wave, 0.0), 0.0, 1.0);
  float split = 0.011 * u_effect;
  vec4 center = texture2D(u_texture, shifted);
  vec4 left_sample = texture2D(u_texture, clamp(shifted - vec2(split, 0.0), 0.0, 1.0));
  vec4 right_sample = texture2D(u_texture, clamp(shifted + vec2(split, 0.0), 0.0, 1.0));
  center.r = mix(center.r, right_sample.r, u_effect);
  center.b = mix(center.b, left_sample.b, u_effect);
  float dropout = step(0.91, noise(vec2(band * 1.73, u_seed + 5.0))) * u_effect;
  center.rgb = mix(center.rgb, center.bgr * 0.55, dropout);
  center.a = mix(1.0, center.a, u_has_alpha);
  gl_FragColor = center * u_opacity;
}"
          external-p external-p))

(defstruct (%tiling-renderer (:constructor %make-tiling-renderer))
  solid-program border-program shadow-program texture-program external-program
  (vertex-buffer 0 :type (unsigned-byte 32)))

(defun %create-tiling-renderer ()
  (let ((renderer (%make-tiling-renderer)))
    (handler-case
        (progn
          (setf (%tiling-renderer-solid-program renderer)
                (ataxia.world.gles:make-gles-program
                +tiling-vertex-shader+ +tiling-solid-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%tiling-renderer-border-program renderer)
                (ataxia.world.gles:make-gles-program
                 +tiling-vertex-shader+ +tiling-border-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%tiling-renderer-shadow-program renderer)
                (ataxia.world.gles:make-gles-program
                 +tiling-vertex-shader+ +tiling-shadow-fragment-shader+
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
                    (%tiling-renderer-border-program renderer)
                    (%tiling-renderer-shadow-program renderer)
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

(defun %draw-border
    (renderer state x y width height color-a color-b phase)
  (let ((program (%tiling-renderer-border-program renderer)))
    (%bind-vertices
     renderer
     (%quad-vertices
      (%screen-quad state x y width height)
      (list (cons 0d0 0d0) (cons 1d0 0d0)
            (cons 0d0 1d0) (cons 1d0 1d0))))
    (ataxia.world.gles:gles-use-program program)
    (apply #'ataxia.world.gles:gles-uniform-4f program "u_color_a" color-a)
    (apply #'ataxia.world.gles:gles-uniform-4f program "u_color_b" color-b)
    (ataxia.world.gles:gles-uniform-1f program "u_phase" phase)
    (ataxia.world.gles:gles-draw-triangles 6)))

(defun %draw-shadow (renderer state x y width height strength lift)
  (let* ((spread (+ 18d0 (* 9d0 lift)))
         (program (%tiling-renderer-shadow-program renderer)))
    (%bind-vertices
     renderer
     (%quad-vertices
      (%screen-quad state (- x spread) (+ y (* 10d0 lift) (- spread))
                    (+ width (* 2d0 spread)) (+ height (* 2d0 spread)))
      (list (cons 0d0 0d0) (cons 1d0 0d0)
            (cons 0d0 1d0) (cons 1d0 1d0))))
    (ataxia.world.gles:gles-use-program program)
    (ataxia.world.gles:gles-uniform-1f program "u_strength" strength)
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

(defun %draw-surface
    (renderer state surface x y width height opacity effect seed)
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
    (ataxia.world.gles:gles-uniform-1f program "u_opacity" opacity)
    (ataxia.world.gles:gles-uniform-1f
     program "u_has_alpha"
     (if (ataxia.kernel:render-source-has-alpha-p source) 1d0 0d0))
    (ataxia.world.gles:gles-uniform-1f program "u_effect" effect)
    (ataxia.world.gles:gles-uniform-1f program "u_seed" seed)
    (ataxia.world.gles:call-with-gles-linear-filter
     target (lambda () (ataxia.world.gles:gles-draw-triangles 6)))))

(defun %tile-buffer-coverage (world state node &optional (timestamp (%now)))
  (multiple-value-bind (x y width height)
      (%tile-visual-geometry world node timestamp)
    (when x (%screen-rectangle-to-buffer state x y width height 30d0))))

(defun %draw-tile (renderer world state node timestamp tokens)
  (let ((component (tile-node-component node)))
    (multiple-value-bind (root-x root-y root-width root-height)
        (ataxia.kernel:drawable-local-bounds component)
      (when (and (plusp root-width) (plusp root-height))
        (multiple-value-bind (x y width height)
            (%tile-visual-geometry world node timestamp)
          (when x
            (let* ((focus (%tile-border-intensity node))
                   (lift (%tile-elevation node))
                   (energy (max focus lift))
                   (seed (/ (mod (sxhash node) 997) 997d0)))
              (%draw-shadow renderer state x y width height
                            (+ 0.18d0 (* 0.24d0 lift) (* 0.08d0 focus)) lift)
              (%draw-border
               renderer state (- x 3d0) (- y 3d0) (+ width 6d0) (+ height 6d0)
               (list (+ 0.12d0 (* 0.02d0 energy))
                     (+ 0.14d0 (* 0.56d0 focus) (* 0.42d0 lift))
                     (+ 0.18d0 (* 0.70d0 focus) (* 0.72d0 lift)) 1d0)
               (list (+ 0.12d0 (* 0.72d0 lift))
                     (+ 0.14d0 (* 0.20d0 focus))
                     (+ 0.18d0 (* 0.76d0 focus) (* 0.58d0 lift)) 1d0)
               (+ seed (* 0.35d0 focus) (* 0.48d0 lift)))
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
                       (%draw-surface
                        renderer state surface
                        surface-x surface-y surface-width surface-height
                        (%tile-opacity node) (%tile-effect node) seed)
                       (let ((token
                               (ataxia.kernel:drawable-surface-protocol-token surface)))
                         (when token (pushnew token tokens :test #'eq)))))
                   surfaces))))))))
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
                  (ataxia.kernel:drawable-surface-height surface)
                  1d0 0d0 0d0)
                 (let ((token
                         (ataxia.kernel:drawable-surface-protocol-token surface)))
                   (when token (pushnew token tokens :test #'eq))))
               surfaces))
        (%draw-solid-cursor renderer state x y))
    tokens))

(defun %render-tiling
    (renderer world state seats damage-region timestamp damage-debug-p)
  (let ((tokens nil))
    (ataxia.world.gles:gles-reset-state)
    (when damage-debug-p
      (ataxia.world.gles:gles-clear 0.55d0 0.015d0 0.08d0 1d0))
    (ataxia.world.gles:gles-set-scissor-enabled t)
    (dolist (damage damage-region)
      (multiple-value-bind (x y width height)
          (ataxia.world:rectangle-pixel-bounds
           damage
           (%tiling-output-buffer-width state)
           (%tiling-output-buffer-height state))
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
