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

(defparameter +shadow-fragment-shader+
  "precision highp float;
varying vec2 v_uv;
uniform vec2 u_size;
uniform float u_sigma;
uniform float u_padding;
uniform float u_opacity;
// Gaussian integral over a rectangle: continuous edges and soft corners.
vec2 gaussian_cdf(vec2 x) {
  vec2 a = abs(x) * 0.70710678;
  vec2 t = 1.0 / (1.0 + 0.3275911 * a);
  vec2 erf_value = 1.0 - (((((1.061405429 * t - 1.453152027) * t
                    + 1.421413741) * t - 0.284496736) * t
                    + 0.254829592) * t) * exp(-a * a);
  return 0.5 + 0.5 * sign(x) * erf_value;
}
void main() {
  vec2 p = v_uv * (u_size + 2.0 * u_padding) - u_padding;
  vec2 coverage = gaussian_cdf(p / u_sigma) - gaussian_cdf((p - u_size) / u_sigma);
  float alpha = clamp(coverage.x * coverage.y, 0.0, 1.0) * u_opacity;
  gl_FragColor = vec4(0.0, 0.0, 0.0, alpha);
}")

;; Separate ownership keeps renderer instances compatible across live updates.
(defvar *canvas-shadow-programs* (make-hash-table :test #'eq))

(defun %ensure-shadow-program (renderer)
  (or (gethash renderer *canvas-shadow-programs*)
      (setf (gethash renderer *canvas-shadow-programs*)
            (ataxia.world.gles:make-gles-program
             +canvas-vertex-shader+ +shadow-fragment-shader+
             :attributes '(("a_position" . 0) ("a_uv" . 1))))))

(defparameter +grid-fragment-shader+
  "precision highp float;
uniform vec2 u_camera;
uniform vec2 u_viewport;
uniform float u_zoom;
uniform float u_rotation;
varying vec2 v_uv;
float grid_dot(vec2 world, float spacing, float radius) {
  vec2 offset = abs(fract(world / spacing + 0.5) - 0.5) * spacing * u_zoom;
  return 1.0 - step(radius, length(offset));
}
void main() {
  vec2 delta = v_uv * u_viewport - u_viewport * 0.5;
  float cosine = cos(u_rotation);
  float sine = sin(u_rotation);
  vec2 canvas = vec2(cosine * delta.x + sine * delta.y,
                     -sine * delta.x + cosine * delta.y) + u_viewport * 0.5;
  vec2 world = u_camera + canvas / u_zoom;
  float fine_dot = grid_dot(world, 24.0, 0.75) * step(0.4, u_zoom);
  float major_dot = grid_dot(world, 120.0, 1.35);
  vec3 color = vec3(0.800);
  color = mix(color, vec3(0.430), fine_dot);
  color = mix(color, vec3(0.125), major_dot);
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
uniform vec2 u_filter_x;
uniform vec2 u_filter_y;
uniform vec2 u_filter_count;
uniform vec4 u_uv_bounds;
varying vec2 v_uv;
vec4 window_sample(vec2 uv) {
  if (u_filter_count.x <= 1.0 && u_filter_count.y <= 1.0)
    return texture2D(u_texture, uv);
  vec4 sum = vec4(0.0);
  // Bounded quadrature over a screen pixel's source footprint. Unlike one
  // bilinear lookup, this suppresses fine text/checkerboard aliasing at overview
  // scales. Uniform loop exits keep work proportional to the reduction.
  for (int y = 0; y < 16; ++y) {
    if (float(y) >= u_filter_count.y) break;
    for (int x = 0; x < 16; ++x) {
      if (float(x) >= u_filter_count.x) break;
      vec2 offset = u_filter_x * ((float(x) + 0.5) / u_filter_count.x - 0.5)
                  + u_filter_y * ((float(y) + 0.5) / u_filter_count.y - 0.5);
      sum += texture2D(u_texture, clamp(uv + offset, u_uv_bounds.xy, u_uv_bounds.zw));
    }
  }
  return sum / (u_filter_count.x * u_filter_count.y);
}
float noise(vec2 point) {
  return fract(sin(dot(point, vec2(12.9898, 78.233)) + u_seed) * 43758.5453);
}
void main() {
  float band = floor(v_uv.y * 37.0 + u_seed * 11.0);
  float displacement = (noise(vec2(band, u_seed)) - 0.5) * 0.075 * u_effect;
  vec2 shifted = clamp(v_uv + vec2(displacement, 0.0), 0.0, 1.0);
  vec4 center = window_sample(shifted);
  if (u_effect > 0.0) {
  vec4 left_sample = texture2D(u_texture, clamp(shifted - vec2(0.009 * u_effect, 0.0), 0.0, 1.0));
  vec4 right_sample = texture2D(u_texture, clamp(shifted + vec2(0.009 * u_effect, 0.0), 0.0, 1.0));
  center.r = mix(center.r, right_sample.r, u_effect);
  center.b = mix(center.b, left_sample.b, u_effect);
  float dropout = step(0.965 - 0.10 * u_effect, noise(vec2(band, floor(u_seed * 19.0))));
  center.rgb = mix(center.rgb, center.bgr * 0.45, dropout * u_effect);
  }
  center.a = mix(1.0, center.a, u_has_alpha);
  gl_FragColor = center * u_opacity;
}"
          external-p external-p))

(defstruct (%canvas-renderer (:constructor %make-canvas-renderer))
  solid-program grid-program texture-program external-program
  (vertex-buffer 0 :type (unsigned-byte 32)))

(defun %create-canvas-renderer (&optional (grid-shader +grid-fragment-shader+))
  (let ((renderer (%make-canvas-renderer)))
    (handler-case
        (progn
          (setf (%canvas-renderer-solid-program renderer)
                (ataxia.world.gles:make-gles-program
                 +canvas-vertex-shader+ +solid-fragment-shader+
                 :attributes '(("a_position" . 0) ("a_uv" . 1)))
                (%canvas-renderer-grid-program renderer)
                (ataxia.world.gles:make-gles-program
                 +canvas-vertex-shader+ grid-shader
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
    (ataxia.world.gles:destroy-gles-program (gethash renderer *canvas-shadow-programs*))
    (remhash renderer *canvas-shadow-programs*)
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

(defun %canvas-quad (state x y width height)
  (mapcar
   (lambda (point)
     (multiple-value-bind (screen-x screen-y)
         (%canvas-to-screen state (car point) (cdr point))
       (multiple-value-bind (buffer-x buffer-y)
           (%screen-point-to-buffer state screen-x screen-y)
         (multiple-value-bind (ndc-x ndc-y)
             (%ndc-point state buffer-x buffer-y)
           (cons ndc-x ndc-y)))))
   (list (cons x y) (cons (+ x width) y)
         (cons x (+ y height)) (cons (+ x width) (+ y height)))))

(defun %oriented-screen-quad (state anchor-x anchor-y x y width height)
  (mapcar
   (lambda (point)
     (multiple-value-bind (screen-x screen-y)
         (%oriented-screen-point
          state anchor-x anchor-y (car point) (cdr point))
       (multiple-value-bind (buffer-x buffer-y)
           (%screen-point-to-buffer state screen-x screen-y)
         (multiple-value-bind (ndc-x ndc-y)
             (%ndc-point state buffer-x buffer-y)
           (cons ndc-x ndc-y)))))
   (list (cons x y) (cons (+ x width) y)
         (cons x (+ y height)) (cons (+ x width) (+ y height)))))

(defun %quad-vertices (positions texture-coordinates)
  (let ((vertices (make-array 24 :element-type 'single-float)))
    (flet ((vertex (offset point uv)
             (setf (aref vertices offset) (coerce (car point) 'single-float)
                   (aref vertices (+ offset 1)) (coerce (cdr point) 'single-float)
                   (aref vertices (+ offset 2)) (coerce (car uv) 'single-float)
                   (aref vertices (+ offset 3)) (coerce (cdr uv) 'single-float))))
      (vertex 0 (first positions) (first texture-coordinates))
      (vertex 4 (second positions) (second texture-coordinates))
      (vertex 8 (third positions) (third texture-coordinates))
      (vertex 12 (second positions) (second texture-coordinates))
      (vertex 16 (fourth positions) (fourth texture-coordinates))
      (vertex 20 (third positions) (third texture-coordinates)))
    vertices))

(defun %bind-vertices (renderer vertices)
  (ataxia.world.gles:gles-upload-floats
   (%canvas-renderer-vertex-buffer renderer) vertices)
  (let ((stride (* 4 (cffi:foreign-type-size :float))))
    (ataxia.world.gles:gles-enable-attribute 0 2 stride 0)
    (ataxia.world.gles:gles-enable-attribute
     1 2 stride (* 2 (cffi:foreign-type-size :float)))))

(defun %draw-solid (renderer state x y width height color)
  (let* ((positions (%canvas-quad state x y width height))
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
      (ataxia.world.gles:gles-uniform-1f
       program "u_rotation" (%canvas-output-rotation state))
      (ataxia.world.gles:gles-draw-triangles 6))))

(defun %source-uv (surface)
  (let ((coordinates
          (ataxia.kernel:drawable-surface-texture-coordinates surface)))
    (loop for index from 0 below 8 by 2
          collect (cons (aref coordinates index)
                        (aref coordinates (1+ index))))))

(defun %draw-solid-triangle (renderer state points color &optional anchor)
  (let ((vertices
          (coerce
           (mapcan
            (lambda (point)
              (multiple-value-bind (screen-x screen-y)
                  (if anchor
                      (%oriented-screen-point
                       state (car anchor) (cdr anchor)
                       (car point) (cdr point))
                      (values (car point) (cdr point)))
                (multiple-value-bind (buffer-x buffer-y)
                    (%screen-point-to-buffer state screen-x screen-y)
                  (multiple-value-bind (x y)
                      (%ndc-point state buffer-x buffer-y)
                    (list x y 0d0 0d0)))))
            points)
           'vector))
        (program (%canvas-renderer-solid-program renderer)))
    (%bind-vertices renderer vertices)
    (ataxia.world.gles:gles-use-program program)
    (apply #'ataxia.world.gles:gles-uniform-4f program "u_color" color)
    (ataxia.world.gles:gles-draw-triangles 3)))

(defun %surface-minification-filter (positions uv buffer-width buffer-height source-width source-height)
  "Return footprint vectors and sample counts using actual physical pixels.
UV edges include buffer transforms and viewport crops; NDC edges include camera
rotation, output transform, fractional scale and window resizing."
  (labels ((edge (points index) (cons (- (car (nth index points)) (caar points))
                                    (- (cdr (nth index points)) (cdar points)))))
    (let ((vectors nil) (counts nil))
      (dolist (index '(1 2))
        (let* ((screen (edge positions index)) (texture (edge uv index))
               (pixels (max 0.000001d0 (sqrt (+ (expt (* 0.5d0 buffer-width (car screen)) 2)
                                              (expt (* 0.5d0 buffer-height (cdr screen)) 2)))))
               (texels (sqrt (+ (expt (* source-width (car texture)) 2)
                                (expt (* source-height (cdr texture)) 2))))
               (footprint (/ texels pixels))
               ;; Collapse continuously to a single bilinear sample at 1:1.
               (factor (if (> footprint 1d0) (/ (sqrt (- 1d0 (/ (* footprint footprint)))) pixels) 0d0)))
          (push (cons (* factor (car texture)) (* factor (cdr texture))) vectors)
          (push (min 16 (max 1 (ceiling footprint))) counts)))
      (values (nreverse vectors) (nreverse counts)))))

(defun %draw-surface-quad
    (renderer surface positions buffer-width buffer-height opacity effect seed)
  (let* ((source (ataxia.kernel:drawable-surface-render-source surface))
         (target (ataxia.kernel:render-source-gles-target source))
         (external-p (= target ataxia.world.gles:+texture-external-oes+))
         (program
           (if external-p
               (%canvas-renderer-external-program renderer)
               (%canvas-renderer-texture-program renderer))))
    (unless program
      (error "The GLES renderer cannot sample texture target 0x~X." target))
    (let ((uv (%source-uv surface)))
      (%bind-vertices renderer (%quad-vertices positions uv))
      (ataxia.world.gles:gles-use-program program)
      (multiple-value-bind (vectors counts)
          (%surface-minification-filter positions uv
                                        buffer-width buffer-height
                                        (ataxia.kernel:render-source-width source)
                                        (ataxia.kernel:render-source-height source))
        (ataxia.world.gles:gles-uniform-2f program "u_filter_x" (caar vectors) (cdar vectors))
        (ataxia.world.gles:gles-uniform-2f program "u_filter_y" (caadr vectors) (cdadr vectors))
        (ataxia.world.gles:gles-uniform-2f program "u_filter_count" (first counts) (second counts))
        (ataxia.world.gles:gles-uniform-4f program "u_uv_bounds"
                                        (reduce #'min uv :key #'car) (reduce #'min uv :key #'cdr)
                                        (reduce #'max uv :key #'car) (reduce #'max uv :key #'cdr)))
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
       target (lambda () (ataxia.world.gles:gles-draw-triangles 6))))))

(defvar *canvas-draw-clip* nil)

(defun %draw-surface
    (renderer state surface x y width height opacity effect seed
     &optional canvas-p orientation-anchor)
  (let* ((positions
           (cond (orientation-anchor
                  (%oriented-screen-quad state (car orientation-anchor) (cdr orientation-anchor) x y width height))
                 (canvas-p (%canvas-quad state x y width height))
                 (t (%screen-quad state x y width height))))
         (bw (%canvas-output-buffer-width state)) (bh (%canvas-output-buffer-height state))
         (clip *canvas-draw-clip*))
    ;; A window can have offscreen or covered popups/subsurfaces even when its
    ;; enclosing bounds are visible. Do not submit those quads or presentation tokens.
    (when (or (null clip)
              (and (< (* .5d0 bw (1+ (reduce #'min positions :key #'car))) (ataxia.world:rectangle-right clip))
                   (> (* .5d0 bw (1+ (reduce #'max positions :key #'car))) (ataxia.world:rectangle-x clip))
                   (< (* .5d0 bh (1+ (reduce #'min positions :key #'cdr))) (ataxia.world:rectangle-bottom clip))
                   (> (* .5d0 bh (1+ (reduce #'max positions :key #'cdr))) (ataxia.world:rectangle-y clip))))
      (%draw-surface-quad renderer surface positions bw bh opacity effect seed)
      t)))

(defun %draw-window-shadow (renderer state window)
  (multiple-value-bind (x y width height)
      (%window-canvas-geometry state window)
    (let* ((lift (max 0d0 (min 1d0 (canvas-window-elevation window))))
           (sigma (+ 5d0 (* lift 3d0)))
           (padding (* 3d0 sigma))
           (program (%ensure-shadow-program renderer)))
      (%bind-vertices renderer
                      (%quad-vertices
                       (%canvas-quad state (- x padding) (+ y (* 5d0 lift) (- padding))
                                     (+ width (* 2d0 padding)) (+ height (* 2d0 padding)))
                       (list (cons 0d0 0d0) (cons 1d0 0d0) (cons 0d0 1d0) (cons 1d0 1d0))))
      (ataxia.world.gles:gles-use-program program)
      (ataxia.world.gles:gles-uniform-2f program "u_size" width height)
      (ataxia.world.gles:gles-uniform-1f program "u_sigma" sigma)
      (ataxia.world.gles:gles-uniform-1f program "u_padding" padding)
      (ataxia.world.gles:gles-uniform-1f program "u_opacity"
                                          (* (%window-opacity window) (+ 0.22d0 (* lift 0.08d0))))
      (ataxia.world.gles:gles-draw-triangles 6))))

(defun %draw-window (renderer state window tokens)
  (%map-window-surfaces
   state window
   (lambda (surface x y width height)
     (when (%draw-surface renderer state surface x y width height
                          (%window-opacity window) (canvas-window-effect window)
                          (coerce (mod (ataxia.kernel:object-id (canvas-window-application window)) 997) 'double-float) t)
       (let ((token (ataxia.kernel:drawable-surface-presentation-token surface)))
         (when token (pushnew token tokens :test #'eq))))))
  tokens)

(defun %draw-overlay (renderer state overlay tokens)
  (let ((component (overlay-component overlay)))
    (multiple-value-bind (root-x root-y root-width root-height)
        (ataxia.kernel:drawable-local-bounds component)
      (when (and (plusp root-width) (plusp root-height))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces component)
          (declare (ignore revision))
          (map nil
               (lambda (surface)
                 (let* ((x (+ (overlay-x overlay)
                              (* (overlay-width overlay)
                                 (/ (- (ataxia.kernel:drawable-surface-local-x surface)
                                       root-x)
                                    root-width))))
                        (y (+ (overlay-y overlay)
                              (* (overlay-height overlay)
                                 (/ (- (ataxia.kernel:drawable-surface-local-y surface)
                                       root-y)
                                    root-height))))
                        (width (* (overlay-width overlay)
                                  (/ (ataxia.kernel:drawable-surface-width surface)
                                     root-width)))
                        (height (* (overlay-height overlay)
                                   (/ (ataxia.kernel:drawable-surface-height surface)
                                      root-height)))
                        (token (ataxia.kernel:drawable-surface-presentation-token surface)))
                   (when (%draw-surface
                          renderer state surface x y width height
                          (overlay-opacity overlay) 0d0
                          (coerce (mod (sxhash overlay) 997) 'double-float))
                     (when token (pushnew token tokens :test #'eq)))))
               surfaces)))))
  tokens)

(defvar *canvas-seat-cursor-tints* (make-hash-table :test #'eq :weakness :key))

(defun %draw-seat-cursor (renderer state seat-state tokens)
  ;; Drag previews are seat-local surfaces, drawn above windows and below the
  ;; pointer. Canvas zoom/rotation must not scale or rotate their content.
  (let ((icon (ataxia.kernel:seat-drag-icon (%canvas-seat-seat seat-state)))
        (x (%canvas-seat-x seat-state)) (y (%canvas-seat-y seat-state)))
    (when icon
      (loop for surface across (ataxia.kernel:drawable-surfaces icon) do
        (when (%draw-surface
               renderer state surface
               (+ x (ataxia.kernel:drawable-surface-local-x surface))
               (+ y (ataxia.kernel:drawable-surface-local-y surface))
               (ataxia.kernel:drawable-surface-width surface)
               (ataxia.kernel:drawable-surface-height surface)
               1d0 0d0 0d0)
          (let ((token (ataxia.kernel:drawable-surface-presentation-token surface)))
            (when token (pushnew token tokens :test #'eq)))))))
  (let ((tint (gethash (%canvas-seat-seat seat-state) *canvas-seat-cursor-tints*))
        (cursor (%canvas-seat-cursor-surface seat-state))
        (x (%canvas-seat-x seat-state))
        (y (%canvas-seat-y seat-state)))
    (if (and (null tint) cursor (eq (ataxia.kernel:object-state cursor) :live))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces cursor)
          (declare (ignore revision))
          (map nil
               (lambda (surface)
                 (when (%draw-surface
                  renderer state surface
                  (+ (- x (%canvas-seat-cursor-hotspot-x seat-state))
                     (ataxia.kernel:drawable-surface-local-x surface))
                  (+ (- y (%canvas-seat-cursor-hotspot-y seat-state))
                     (ataxia.kernel:drawable-surface-local-y surface))
                  (ataxia.kernel:drawable-surface-width surface)
                  (ataxia.kernel:drawable-surface-height surface)
                        1d0 0d0 0d0 nil (cons x y))
                 (let ((token
                         (ataxia.kernel:drawable-surface-presentation-token surface)))
                   (when token (pushnew token tokens :test #'eq)))))
               surfaces))
        (progn
          (%draw-solid-triangle
           renderer state
           (list (cons (- x 2d0) (- y 2d0))
                 (cons (- x 2d0) (+ y 28d0))
                 (cons (+ x 20d0) (+ y 18d0)))
           '(0.02d0 0.025d0 0.04d0 0.95d0) (cons x y))
          (%draw-solid-triangle
           renderer state
           (list (cons x y) (cons x (+ y 24d0))
                 (cons (+ x 17d0) (+ y 16d0)))
           (or tint '(0.96d0 0.98d0 1d0 1d0)) (cons x y))))
    tokens))

(defgeneric %draw-world-background (world renderer output-state))

(defmethod %draw-world-background (world renderer output-state)
  (declare (ignore world renderer output-state)))

(defun %render-canvas
    (renderer output-state windows overlays seats damage-region damage-debug-p
     &optional world)
  (let ((tokens nil) (plan (%canvas-paint-plan output-state windows overlays seats)))
    (ataxia.world.gles:gles-reset-state)
    (when damage-debug-p (ataxia.world.gles:gles-clear 0.55d0 0.015d0 0.08d0 1d0))
    (ataxia.world.gles:gles-set-scissor-enabled t)
    ;; Preserve paint order within every damaged rectangle. In particular,
    ;; overlapping damage must not accumulate alpha by painting a layer twice
    ;; without reconstructing its background first.
    (dolist (damage damage-region)
      (dolist (entry plan)
        (destructuring-bind (kind object visible) entry
          (dolist (piece visible)
            (let ((*canvas-draw-clip* (ataxia.world:rectangle-intersection damage piece)))
              (when *canvas-draw-clip*
                (multiple-value-bind (x y width height)
                    (ataxia.world:rectangle-pixel-bounds
                     *canvas-draw-clip* (%canvas-output-buffer-width output-state)
                     (%canvas-output-buffer-height output-state))
                  (when (and (plusp width) (plusp height))
                    (ataxia.world.gles:gles-set-scissor x y width height)
                    (ecase kind
                      (:background
                       (ataxia.world.gles:gles-clear 0.03d0 0.036d0 0.05d0 1d0)
                       (%draw-grid renderer output-state)
                       (%draw-world-background world renderer output-state))
                      (:window (setf tokens (%draw-window renderer output-state object tokens)))
                      (:overlay (setf tokens (%draw-overlay renderer output-state object tokens)))
                      (:cursor (setf tokens (%draw-seat-cursor renderer output-state object tokens))))))))))))
    (ataxia.world.gles:gles-set-scissor-enabled nil)
    (ataxia.world.gles:gles-disable-attribute 0)
    (ataxia.world.gles:gles-disable-attribute 1)
    (ataxia.world.gles:gles-flush)
    (ataxia.world.gles:gles-check-error "infinite canvas frame")
    (values (coerce (nreverse tokens) 'vector) (%canvas-plan-callbacks output-state plan))))
