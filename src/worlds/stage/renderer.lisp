;;;; Direct GLES renderer for Stage display items.
;;;;
;;;; All programs share one vertex layout: buffer position, node-local position
;;;; and texture coordinates. Shapes are signed-distance fields evaluated in
;;;; node-local units, so rotation and zoom keep corners and borders exact.
;;;; Call only inside a Kernel graphics scope or frame lease.

(in-package #:ataxia.stage-world)

(defparameter +stage-vertex-shader+
  "attribute vec2 a_position;
attribute vec2 a_local;
attribute vec2 a_uv;
uniform vec2 u_viewport;
varying vec2 v_local;
varying vec2 v_uv;
void main() {
  gl_Position = vec4(a_position / u_viewport * 2.0 - 1.0, 0.0, 1.0);
  v_local = a_local;
  v_uv = a_uv;
}")

(defparameter +box-distance+
  "float box_distance(vec2 point, vec2 half_size, float radius) {
  vec2 q = abs(point) - half_size + radius;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}
")

(defparameter +solid-fragment-shader+
  "precision mediump float;
uniform vec4 u_color;
void main() { gl_FragColor = u_color; }")

(defparameter +rect-fragment-shader+
  (concatenate 'string
   "precision highp float;
varying vec2 v_local;
uniform vec2 u_size;
uniform float u_radius;
uniform float u_border;
uniform float u_pixel;
uniform vec4 u_fill;
uniform vec4 u_fill_end;
uniform vec2 u_fill_direction;
uniform vec4 u_stroke;
uniform vec4 u_stroke_end;
uniform vec2 u_stroke_direction;
" +box-distance+
   "// Position along a linear gradient spanning the box in DIRECTION, in 0..1.
float gradient(vec2 point, vec2 half_size, vec2 direction) {
  float extent = abs(half_size.x * direction.x) + abs(half_size.y * direction.y);
  return clamp(0.5 + 0.5 * dot(point, direction) / max(extent, 1e-4), 0.0, 1.0);
}
void main() {
  vec2 half_size = u_size * 0.5;
  vec2 point = v_local - half_size;
  float radius = min(u_radius, min(half_size.x, half_size.y));
  float distance = box_distance(point, half_size, radius);
  float outer = clamp(0.5 - distance / u_pixel, 0.0, 1.0);
  float inner = clamp(0.5 - (distance + u_border) / u_pixel, 0.0, 1.0);
  vec4 fill = mix(u_fill, u_fill_end, gradient(point, half_size, u_fill_direction));
  vec4 stroke = mix(u_stroke, u_stroke_end, gradient(point, half_size, u_stroke_direction));
  gl_FragColor = fill * inner + stroke * (outer - inner);
}"))

;;; Rounded-rectangle shadow after Evan Wallace, "Fast Rounded Rectangle
;;; Shadows" (public domain): exact Gaussian along X, four samples along Y.
(defparameter +shadow-fragment-shader+
  "precision highp float;
varying vec2 v_local;
uniform vec4 u_box;
uniform float u_sigma;
uniform float u_corner;
uniform vec4 u_color;
float gaussian(float x, float sigma) {
  return exp(-(x * x) / (2.0 * sigma * sigma)) / (2.5066282746 * sigma);
}
vec2 approximate_erf(vec2 x) {
  vec2 s = sign(x);
  vec2 a = abs(x);
  x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
  x *= x;
  return s - s / (x * x);
}
float shadow_row(float x, float y, float sigma, float corner, vec2 half_size) {
  float delta = min(half_size.y - corner - abs(y), 0.0);
  float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
  vec2 integral = 0.5 + 0.5 * approximate_erf((x + vec2(-curved, curved)) * (0.70710678 / sigma));
  return integral.y - integral.x;
}
void main() {
  vec2 half_size = (u_box.zw - u_box.xy) * 0.5;
  vec2 point = v_local - (u_box.xy + u_box.zw) * 0.5;
  float corner = min(u_corner, min(half_size.x, half_size.y));
  float start = clamp(-3.0 * u_sigma, point.y - half_size.y, point.y + half_size.y);
  float end = clamp(3.0 * u_sigma, point.y - half_size.y, point.y + half_size.y);
  float step = (end - start) / 4.0;
  float y = start + step * 0.5;
  float value = 0.0;
  for (int i = 0; i < 4; i++) {
    value += shadow_row(point.x, point.y - y, u_sigma, corner, half_size) * gaussian(y, u_sigma) * step;
    y += step;
  }
  gl_FragColor = u_color * value;
}")

(defun %texture-fragment-shader (external-p)
  (concatenate
   'string
   (if external-p "#extension GL_OES_EGL_image_external : require
" "")
   "precision highp float;
varying vec2 v_local;
varying vec2 v_uv;
uniform " (if external-p "samplerExternalOES" "sampler2D") " u_texture;
uniform float u_opacity;
uniform float u_has_alpha;
uniform float u_dim;
uniform vec2 u_size;
uniform float u_radius;
uniform float u_pixel;
uniform vec2 u_filter_x;
uniform vec2 u_filter_y;
uniform vec2 u_taps;
uniform vec4 u_uv_bounds;
" +box-distance+
   "vec4 filtered(vec2 uv) {
  if (u_taps.x <= 1.0 && u_taps.y <= 1.0) return texture2D(u_texture, uv);
  // Box filter over one output pixel's footprint: a minified window keeps
  // its text legible instead of shimmering under a single bilinear tap.
  vec4 sum = vec4(0.0);
  for (int y = 0; y < 6; ++y) {
    if (float(y) >= u_taps.y) break;
    for (int x = 0; x < 6; ++x) {
      if (float(x) >= u_taps.x) break;
      vec2 offset = u_filter_x * ((float(x) + 0.5) / u_taps.x - 0.5)
                  + u_filter_y * ((float(y) + 0.5) / u_taps.y - 0.5);
      sum += texture2D(u_texture, clamp(uv + offset, u_uv_bounds.xy, u_uv_bounds.zw));
    }
  }
  return sum / (u_taps.x * u_taps.y);
}
void main() {
  vec4 color = filtered(v_uv);
  color.a = mix(1.0, color.a, u_has_alpha);
  color.rgb *= 1.0 - u_dim;
  float coverage = 1.0;
  vec2 half_size = u_size * 0.5;
  vec2 point = v_local - half_size;
  // Round only the window's own corners; popups outside its box are untouched.
  if (u_radius > 0.0 && abs(point.x) <= half_size.x && abs(point.y) <= half_size.y) {
    float radius = min(u_radius, min(half_size.x, half_size.y));
    coverage = clamp(0.5 - box_distance(point, half_size, radius) / u_pixel, 0.0, 1.0);
  }
  gl_FragColor = color * (u_opacity * coverage);
}"))

(defparameter +background-fragment-shader+
  "precision highp float;
uniform vec4 u_color;
uniform vec4 u_grid_color;
uniform float u_spacing;
uniform float u_size;
uniform float u_lines;
uniform float u_pixel;
uniform vec4 u_row_x;
uniform vec4 u_row_y;
void main() {
  vec3 point = vec3(gl_FragCoord.xy, 1.0);
  vec2 local = vec2(dot(u_row_x.xyz, point), dot(u_row_y.xyz, point));
  // Distance to the nearest grid point, per axis, in output pixels.
  vec2 cell = abs(fract(local / u_spacing + 0.5) - 0.5) * u_spacing / u_pixel;
  float distance = u_lines > 0.5 ? min(cell.x, cell.y) : length(cell);
  float coverage = clamp(u_size + 0.5 - distance, 0.0, 1.0);
  // Fade the pattern out before it becomes a dense texture when zoomed out.
  coverage *= smoothstep(4.0, 12.0, u_spacing / u_pixel);
  vec4 grid = u_grid_color * coverage;
  gl_FragColor = grid + u_color * (1.0 - grid.a);
}")

;;; Dual Kawase blur (Bjørge, "Bandwidth-Efficient Rendering", 2015): each
;;; downsample halves the image, each upsample doubles it back, and the passes
;;; sample between texels so a few taps give a wide, smooth kernel.
(defparameter +blur-sampling+
  "precision highp float;
varying vec2 v_uv;
uniform sampler2D u_texture;
uniform vec2 u_offset;
uniform vec4 u_bounds;
vec4 at(vec2 uv) { return texture2D(u_texture, clamp(uv, u_bounds.xy, u_bounds.zw)); }
")

(defparameter +blur-down-fragment-shader+
  (concatenate 'string +blur-sampling+
   "void main() {
  vec4 sum = at(v_uv) * 4.0;
  sum += at(v_uv - u_offset);
  sum += at(v_uv + u_offset);
  sum += at(v_uv + vec2(u_offset.x, -u_offset.y));
  sum += at(v_uv - vec2(u_offset.x, -u_offset.y));
  gl_FragColor = sum / 8.0;
}"))

(defparameter +blur-up-fragment-shader+
  (concatenate 'string +blur-sampling+
   "void main() {
  vec4 sum = at(v_uv + vec2(-u_offset.x * 2.0, 0.0));
  sum += at(v_uv + vec2(-u_offset.x, u_offset.y)) * 2.0;
  sum += at(v_uv + vec2(0.0, u_offset.y * 2.0));
  sum += at(v_uv + vec2(u_offset.x, u_offset.y)) * 2.0;
  sum += at(v_uv + vec2(u_offset.x * 2.0, 0.0));
  sum += at(v_uv + vec2(u_offset.x, -u_offset.y)) * 2.0;
  sum += at(v_uv + vec2(0.0, -u_offset.y * 2.0));
  sum += at(v_uv + vec2(-u_offset.x, -u_offset.y)) * 2.0;
  gl_FragColor = sum / 12.0;
}"))

(defparameter +backdrop-fragment-shader+
  (concatenate 'string
   "precision highp float;
varying vec2 v_local;
uniform sampler2D u_texture;
uniform vec2 u_viewport;
uniform vec4 u_bounds;
uniform vec2 u_size;
uniform float u_radius;
uniform float u_pixel;
uniform float u_opacity;
" +box-distance+
   "void main() {
  vec2 half_size = u_size * 0.5;
  float radius = min(u_radius, min(half_size.x, half_size.y));
  float coverage = clamp(0.5 - box_distance(v_local - half_size, half_size, radius) / u_pixel, 0.0, 1.0);
  vec2 uv = clamp(gl_FragCoord.xy / u_viewport, u_bounds.xy, u_bounds.zw);
  gl_FragColor = vec4(texture2D(u_texture, uv).rgb, 1.0) * (coverage * u_opacity);
}"))

(defstruct (stage-renderer (:constructor %make-stage-renderer))
  solid rect shadow texture external background blur-down blur-up backdrop
  (buffer 0 :type (unsigned-byte 32))
  (vertices (make-array 36 :element-type 'single-float) :read-only t)
  (viewport-width 1d0 :type double-float)
  (viewport-height 1d0 :type double-float)
  ;; Buffer-space scissor of the damage rectangle being repainted.
  (scissor nil :type list)
  ;; (WIDTH . HEIGHT) -> list of render targets halving in size, and when each
  ;; chain was last used.
  (blur-chains (make-hash-table :test #'equal) :read-only t)
  (blur-used (make-hash-table :test #'equal) :read-only t)
  ;; Slot -> RASTER: uploaded text and image textures.
  (rasters (make-hash-table :test #'equal) :read-only t))

;; A texture the World uploads itself, such as rendered text or a decoded image.
(defstruct (raster (:constructor %make-raster))
  (texture 0 :type (unsigned-byte 32))
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (key nil)
  (used 0d0 :type double-float)
  ;; Seconds the raster survives without being drawn.
  (lifetime 2d0 :type double-float))

(defparameter +stage-attributes+ '(("a_position" . 0) ("a_local" . 1) ("a_uv" . 2)))

(defun %make-program (fragment)
  (ataxia.world.gles:make-gles-program +stage-vertex-shader+ fragment
                                       :attributes +stage-attributes+))

(defun create-stage-renderer ()
  (let ((renderer (%make-stage-renderer)))
    (handler-case
        (progn
          (setf (stage-renderer-solid renderer) (%make-program +solid-fragment-shader+)
                (stage-renderer-rect renderer) (%make-program +rect-fragment-shader+)
                (stage-renderer-shadow renderer) (%make-program +shadow-fragment-shader+)
                (stage-renderer-texture renderer) (%make-program (%texture-fragment-shader nil))
                ;; External images are optional; a context without them still
                ;; renders ordinary client buffers.
                (stage-renderer-external renderer)
                (ignore-errors (%make-program (%texture-fragment-shader t)))
                (stage-renderer-background renderer) (%make-program +background-fragment-shader+)
                (stage-renderer-blur-down renderer) (%make-program +blur-down-fragment-shader+)
                (stage-renderer-blur-up renderer) (%make-program +blur-up-fragment-shader+)
                (stage-renderer-backdrop renderer) (%make-program +backdrop-fragment-shader+)
                (stage-renderer-buffer renderer) (ataxia.world.gles:gles-create-buffer))
          (ataxia.world.gles:gles-check-error "Stage renderer creation")
          renderer)
      (serious-condition (cause)
        (ignore-errors (destroy-stage-renderer renderer))
        (error cause)))))

(defun destroy-stage-renderer (renderer)
  (when renderer
    (dolist (program (list (stage-renderer-solid renderer) (stage-renderer-rect renderer)
                           (stage-renderer-shadow renderer) (stage-renderer-texture renderer)
                           (stage-renderer-external renderer)
                           (stage-renderer-background renderer)
                           (stage-renderer-blur-down renderer) (stage-renderer-blur-up renderer)
                           (stage-renderer-backdrop renderer)))
      (ataxia.world.gles:destroy-gles-program program))
    (loop for chain being the hash-values of (stage-renderer-blur-chains renderer)
          do (mapc #'destroy-render-target chain))
    (clrhash (stage-renderer-blur-chains renderer))
    (clrhash (stage-renderer-blur-used renderer))
    (loop for raster being the hash-values of (stage-renderer-rasters renderer)
          do (gl-delete-texture (raster-texture raster)))
    (clrhash (stage-renderer-rasters renderer))
    (setf (stage-renderer-buffer renderer)
          (ataxia.world.gles:gles-destroy-buffer (stage-renderer-buffer renderer))))
  nil)

(defun begin-stage-frame (renderer width height)
  (setf (stage-renderer-viewport-width renderer) (coerce width 'double-float)
        (stage-renderer-viewport-height renderer) (coerce height 'double-float))
  (ataxia.world.gles:gles-reset-state)
  (ataxia.world.gles:gles-set-scissor-enabled t))

(defun set-stage-scissor (renderer x y width height)
  (setf (stage-renderer-scissor renderer) (list x y width height))
  (ataxia.world.gles:gles-set-scissor x y width height))

(defun finish-stage-frame ()
  (ataxia.world.gles:gles-set-scissor-enabled nil)
  (dotimes (index 3) (ataxia.world.gles:gles-disable-attribute index))
  (ataxia.world.gles:gles-flush)
  (ataxia.world.gles:gles-check-error "Stage frame"))

(defun %use (renderer program)
  (ataxia.world.gles:gles-use-program program)
  (ataxia.world.gles:gles-uniform-2f program "u_viewport"
                                     (stage-renderer-viewport-width renderer)
                                     (stage-renderer-viewport-height renderer))
  program)

(defun %draw-quad (renderer transform x y width height &optional uv)
  "Draw local rectangle (X, Y, WIDTH, HEIGHT) through TRANSFORM. UV holds the
texture coordinates of its top-left, top-right, bottom-left and bottom-right corners."
  (let ((vertices (stage-renderer-vertices renderer))
        (x (float x 1d0)) (y (float y 1d0)) (width (float width 1d0)) (height (float height 1d0))
        (a (affine-a transform)) (b (affine-b transform)) (c (affine-c transform))
        (d (affine-d transform)) (e (affine-e transform)) (f (affine-f transform)))
    (declare (type (simple-array single-float (36)) vertices)
             (double-float x y width height a b c d e f))
    ;; Written in place: a quad is drawn for every item on every frame.
    (loop for corner of-type fixnum in '(0 1 2 1 3 2)
          for index of-type fixnum from 0 by 6
          for local-x of-type double-float = (if (oddp corner) (+ x width) x)
          for local-y of-type double-float = (if (>= corner 2) (+ y height) y)
          do (setf (aref vertices index) (coerce (+ (* a local-x) (* c local-y) e) 'single-float)
                   (aref vertices (+ index 1)) (coerce (+ (* b local-x) (* d local-y) f) 'single-float)
                   (aref vertices (+ index 2)) (coerce local-x 'single-float)
                   (aref vertices (+ index 3)) (coerce local-y 'single-float)
                   (aref vertices (+ index 4)) (if uv (coerce (aref uv (* 2 corner)) 'single-float) 0f0)
                   (aref vertices (+ index 5))
                   (if uv (coerce (aref uv (1+ (* 2 corner))) 'single-float) 0f0)))
    (ataxia.world.gles:gles-upload-floats (stage-renderer-buffer renderer) vertices)
    (let ((stride (* 6 4)))
      (ataxia.world.gles:gles-enable-attribute 0 2 stride 0)
      (ataxia.world.gles:gles-enable-attribute 1 2 stride 8)
      (ataxia.world.gles:gles-enable-attribute 2 2 stride 16))
    (ataxia.world.gles:gles-draw-triangles 6)))

(defun %uniform-color (program name color)
  (ataxia.world.gles:gles-uniform-4f program name
                                     (aref color 0) (aref color 1) (aref color 2) (aref color 3)))

(defstruct (paint (:constructor make-paint (start end angle)))
  "A premultiplied color, or a two-stop linear gradient at ANGLE radians."
  (start nil :type simple-vector :read-only t)
  (end nil :type simple-vector :read-only t)
  (angle 0d0 :type double-float :read-only t))

(defun %uniform-paint (program prefix paint)
  (%uniform-color program prefix (paint-start paint))
  (%uniform-color program (concatenate 'string prefix "_end") (paint-end paint))
  (ataxia.world.gles:gles-uniform-2f program (concatenate 'string prefix "_direction")
                                     (cos (paint-angle paint)) (sin (paint-angle paint))))

(defun draw-stage-rect (renderer transform width height radius border fill stroke)
  "Fill and inner border of a rounded rectangle, painted with FILL and STROKE paints."
  (let* ((program (%use renderer (stage-renderer-rect renderer)))
         (pixel (/ 1d0 (max 1d-9 (affine-scale-factor transform))))
         (margin pixel))
    (ataxia.world.gles:gles-uniform-2f program "u_size" width height)
    (ataxia.world.gles:gles-uniform-1f program "u_radius" radius)
    (ataxia.world.gles:gles-uniform-1f program "u_border" border)
    (ataxia.world.gles:gles-uniform-1f program "u_pixel" pixel)
    (%uniform-paint program "u_fill" fill)
    (%uniform-paint program "u_stroke" stroke)
    (%draw-quad renderer transform (- margin) (- margin)
                (+ width (* 2 margin)) (+ height (* 2 margin)))))

(defun shadow-extent (blur)
  "Distance beyond its box at which a shadow of BLUR becomes invisible."
  (* 1.5d0 (max blur 1d0)))

(defun draw-stage-shadow (renderer transform x y width height radius blur color)
  (let ((program (%use renderer (stage-renderer-shadow renderer)))
        (extent (shadow-extent blur))
        (pixel (/ 1d0 (max 1d-9 (affine-scale-factor transform)))))
    (ataxia.world.gles:gles-uniform-4f program "u_box" x y (+ x width) (+ y height))
    (ataxia.world.gles:gles-uniform-1f program "u_sigma" (max (/ blur 2d0) (* 0.5d0 pixel)))
    (ataxia.world.gles:gles-uniform-1f program "u_corner" radius)
    (%uniform-color program "u_color" color)
    (%draw-quad renderer transform (- x extent) (- y extent)
                (+ width (* 2 extent)) (+ height (* 2 extent)))))

(defun draw-stage-solid (renderer points color)
  "Fill a triangle given in buffer coordinates."
  (%use renderer (stage-renderer-solid renderer))
  (%uniform-color (stage-renderer-solid renderer) "u_color" color)
  (let ((vertices (stage-renderer-vertices renderer)))
    (fill vertices 0f0)
    (loop for (x . y) in points
          for index from 0 by 6
          do (setf (aref vertices index) (coerce x 'single-float)
                   (aref vertices (1+ index)) (coerce y 'single-float)))
    (ataxia.world.gles:gles-upload-floats (stage-renderer-buffer renderer) vertices)
    (ataxia.world.gles:gles-enable-attribute 0 2 24 0)
    (ataxia.world.gles:gles-draw-triangles 3)))

(defun draw-stage-background (renderer transform color grid grid-color spacing size)
  (let ((program (%use renderer (stage-renderer-background renderer)))
        (inverse (or (affine-invert transform) +identity-affine+))
        (width (stage-renderer-viewport-width renderer))
        (height (stage-renderer-viewport-height renderer)))
    (%uniform-color program "u_color" color)
    (%uniform-color program "u_grid_color" (if (eq grid :none) #(0d0 0d0 0d0 0d0) grid-color))
    (ataxia.world.gles:gles-uniform-1f program "u_spacing" (max spacing 1d-3))
    (ataxia.world.gles:gles-uniform-1f program "u_size" size)
    (ataxia.world.gles:gles-uniform-1f program "u_lines" (if (eq grid :lines) 1d0 0d0))
    (ataxia.world.gles:gles-uniform-1f program "u_pixel"
                                       (/ 1d0 (max 1d-9 (affine-scale-factor transform))))
    (ataxia.world.gles:gles-uniform-4f program "u_row_x"
                                       (affine-a inverse) (affine-c inverse) (affine-e inverse) 0d0)
    (ataxia.world.gles:gles-uniform-4f program "u_row_y"
                                       (affine-b inverse) (affine-d inverse) (affine-f inverse) 0d0)
    (%draw-quad renderer +identity-affine+ 0d0 0d0 width height)))

(defun %uv-filter (uv from to local-length pixels-per-unit texel-width texel-height)
  "UV offset spanning one output pixel along an edge, and the taps it needs."
  (let* ((du (- (aref uv (* 2 to)) (aref uv (* 2 from))))
         (dv (- (aref uv (1+ (* 2 to))) (aref uv (1+ (* 2 from)))))
         (pixels (max 1d-6 (* local-length pixels-per-unit)))
         (texels (+ (abs (* du texel-width)) (abs (* dv texel-height))))
         (ratio (/ texels pixels)))
    (values (/ du pixels) (/ dv pixels)
            (if (> ratio 1.25d0) (min 6 (ceiling ratio)) 1))))

(defun draw-stage-texture (renderer transform target name has-alpha-p texel-width texel-height uv
                           x y width height mask-width mask-height radius opacity &optional (dim 0d0))
  "Draw a texture at local (X, Y, WIDTH, HEIGHT) with corner UVs, rounding the box
of size MASK-WIDTH by MASK-HEIGHT at the local origin."
  (let ((program (if (= target ataxia.world.gles:+texture-external-oes+)
                     (stage-renderer-external renderer)
                     (stage-renderer-texture renderer)))
        (scale (max 1d-9 (affine-scale-factor transform))))
    (when program
      (%use renderer program)
      (multiple-value-bind (xu xv x-taps) (%uv-filter uv 0 1 width scale texel-width texel-height)
        (multiple-value-bind (yu yv y-taps) (%uv-filter uv 0 2 height scale texel-width texel-height)
          (ataxia.world.gles:gles-uniform-2f program "u_filter_x" xu xv)
          (ataxia.world.gles:gles-uniform-2f program "u_filter_y" yu yv)
          (ataxia.world.gles:gles-uniform-2f program "u_taps" x-taps y-taps)))
      (ataxia.world.gles:gles-uniform-4f
       program "u_uv_bounds"
       (min (aref uv 0) (aref uv 2) (aref uv 4) (aref uv 6))
       (min (aref uv 1) (aref uv 3) (aref uv 5) (aref uv 7))
       (max (aref uv 0) (aref uv 2) (aref uv 4) (aref uv 6))
       (max (aref uv 1) (aref uv 3) (aref uv 5) (aref uv 7)))
      (ataxia.world.gles:gles-uniform-1i program "u_texture" 0)
      (ataxia.world.gles:gles-uniform-1f program "u_opacity" opacity)
      (ataxia.world.gles:gles-uniform-1f program "u_dim" dim)
      (ataxia.world.gles:gles-uniform-1f program "u_has_alpha" (if has-alpha-p 1d0 0d0))
      (ataxia.world.gles:gles-uniform-2f program "u_size" mask-width mask-height)
      (ataxia.world.gles:gles-uniform-1f program "u_radius" radius)
      (ataxia.world.gles:gles-uniform-1f program "u_pixel" (/ 1d0 scale))
      (ataxia.world.gles:gles-bind-texture target name)
      (ataxia.world.gles:call-with-gles-linear-filter
       target (lambda () (%draw-quad renderer transform x y width height uv)))
      t)))

(defun draw-stage-surface (renderer transform surface x y width height mask-width mask-height
                           radius opacity &optional (dim 0d0))
  "Draw a client surface at local (X, Y, WIDTH, HEIGHT); see DRAW-STAGE-TEXTURE."
  (let ((source (ataxia.kernel:drawable-surface-render-source surface)))
    (draw-stage-texture renderer transform (ataxia.kernel:render-source-gles-target source)
                        (ataxia.kernel:render-source-gles-name source)
                        (ataxia.kernel:render-source-has-alpha-p source)
                        (ataxia.kernel:render-source-width source)
                        (ataxia.kernel:render-source-height source)
                        (ataxia.kernel:drawable-surface-texture-coordinates surface)
                        x y width height mask-width mask-height radius opacity dim)))

;;; Rasters: textures the World uploads itself.

(defparameter +full-texture-uv+ #(0d0 0d0 1d0 0d0 0d0 1d0 1d0 1d0))

(defun renderer-raster (renderer slot key lifetime producer)
  "The raster in SLOT holding KEY. When SLOT holds anything else, PRODUCER is
called with an uploader taking (PIXELS WIDTH HEIGHT FORMAT); it may decline.
Return the raster, or NIL while none holds KEY."
  (let* ((rasters (stage-renderer-rasters renderer))
         (raster (gethash slot rasters)))
    (unless (and raster (equalp key (raster-key raster)))
      (funcall producer
               (lambda (pixels width height format)
                 (unless raster
                   (setf raster (%make-raster) (gethash slot rasters) raster))
                 (setf (raster-texture raster)
                       (if (zerop (raster-texture raster))
                           (gl-create-texture width height pixels format)
                           (gl-upload-texture (raster-texture raster) width height pixels format))
                       (raster-width raster) width
                       (raster-height raster) height
                       (raster-key raster) key))))
    (when (and raster (equalp key (raster-key raster)))
      (setf (raster-used raster) (%now)
            (raster-lifetime raster) lifetime)
      raster)))

(defun sweep-rasters (renderer now)
  "Delete rasters no frame has drawn within their lifetime, and blur targets of a
buffer size no longer drawn, e.g. after a mode change."
  (let ((chains (stage-renderer-blur-chains renderer)))
    (loop for key being the hash-keys of chains using (hash-value chain)
          when (> (- now (gethash key (stage-renderer-blur-used renderer))) 2d0)
            do (mapc #'destroy-render-target chain)
               (remhash key chains)
               (remhash key (stage-renderer-blur-used renderer))))
  (let ((rasters (stage-renderer-rasters renderer)))
    (loop for slot being the hash-keys of rasters using (hash-value raster)
          when (> (- now (raster-used raster)) (raster-lifetime raster))
            do (gl-delete-texture (raster-texture raster))
               (remhash slot rasters))))

(defun draw-stage-raster (renderer transform raster x y width height uv radius opacity)
  "Draw RASTER over local (X, Y, WIDTH, HEIGHT), rounding that box by RADIUS."
  (draw-stage-texture renderer (affine-multiply transform (affine-translation x y))
                      +gl-texture-2d+ (raster-texture raster) t
                      (raster-width raster) (raster-height raster) uv
                      0d0 0d0 width height width height radius opacity))

;;; Backdrop blur.

(defun blur-parameters (radius)
  "Passes, sample offset and sampling margin, in output pixels, for a blur RADIUS."
  (let* ((passes (max 1 (min 5 (1- (round (log (max radius 2d0) 2))))))
         (offset (max 1d0 (min 3d0 (/ radius (expt 2 (1+ passes)))))))
    (values passes offset (+ 2 (ceiling (* offset (expt 2 (1+ passes))))))))

(defun %blur-chain (renderer width height passes)
  "Render targets for levels 0..PASSES of a WIDTH x HEIGHT buffer, created on demand."
  (let* ((key (cons width height))
         (chain (gethash key (stage-renderer-blur-chains renderer))))
    (loop for level from (length chain) to passes
          do (setf chain (append chain (list (make-render-target
                                              (max 1 (ceiling width (expt 2 level)))
                                              (max 1 (ceiling height (expt 2 level))))))))
    (setf (gethash key (stage-renderer-blur-used renderer)) (%now)
          (gethash key (stage-renderer-blur-chains renderer)) chain)))

(defun %level-area (x y width height level)
  "A buffer-space area in LEVEL's pixels, rounded outwards."
  (let* ((factor (expt 2 level))
         (left (floor x factor)) (top (floor y factor)))
    (list left top (- (ceiling (+ x width) factor) left) (- (ceiling (+ y height) factor) top))))

(defun %blur-pass (renderer program source target source-area target-area ratio offset)
  "Draw TARGET-AREA of TARGET from SOURCE, sampling only SOURCE-AREA. RATIO is
the scale from target to source pixels: 2 when downsampling, 1/2 when upsampling."
  (destructuring-bind (sx sy sw sh) source-area
    (destructuring-bind (tx ty tw th) target-area
      (let ((source-width (coerce (render-target-width source) 'double-float))
            (source-height (coerce (render-target-height source) 'double-float)))
        (call-with-render-target
         target
         (lambda ()
           (setf (stage-renderer-viewport-width renderer) (coerce (render-target-width target) 'double-float)
                 (stage-renderer-viewport-height renderer) (coerce (render-target-height target) 'double-float))
           (%use renderer program)
           (ataxia.world.gles:gles-uniform-2f program "u_offset"
                                              (/ (* 0.5d0 offset) source-width)
                                              (/ (* 0.5d0 offset) source-height))
           (ataxia.world.gles:gles-uniform-4f program "u_bounds"
                                              (/ (+ sx 0.5d0) source-width) (/ (+ sy 0.5d0) source-height)
                                              (/ (- (+ sx sw) 0.5d0) source-width)
                                              (/ (- (+ sy sh) 0.5d0) source-height))
           (ataxia.world.gles:gles-uniform-1i program "u_texture" 0)
           (ataxia.world.gles:gles-bind-texture ataxia.world.gles:+texture-2d+ (render-target-texture source))
           (let ((u0 (/ (* tx ratio) source-width)) (v0 (/ (* ty ratio) source-height))
                 (u1 (/ (* (+ tx tw) ratio) source-width)) (v1 (/ (* (+ ty th) ratio) source-height)))
             (%draw-quad renderer +identity-affine+ tx ty tw th
                         (vector u0 v0 u1 v0 u0 v1 u1 v1)))))))))

(defun draw-stage-blur (renderer transform width height radius blur opacity area)
  "Blur the already-drawn pixels in AREA (buffer x y width height) and draw them
inside the rounded local box WIDTH x HEIGHT through TRANSFORM."
  (destructuring-bind (x y area-width area-height) area
    (when (and (plusp area-width) (plusp area-height))
      (let* ((buffer-width (round (stage-renderer-viewport-width renderer)))
             (buffer-height (round (stage-renderer-viewport-height renderer))))
        (multiple-value-bind (passes offset) (blur-parameters blur)
          (let ((chain (%blur-chain renderer buffer-width buffer-height passes))
                (areas (loop for level from 0 to passes
                             collect (%level-area x y area-width area-height level))))
            (gl-copy-framebuffer (first chain) x y area-width area-height)
            (ataxia.world.gles:gles-set-scissor-enabled nil)
            (ataxia.world.gles:gles-set-blending-enabled nil)
            (unwind-protect
                 (progn
                   (loop for level from 1 to passes
                         do (%blur-pass renderer (stage-renderer-blur-down renderer)
                                        (nth (1- level) chain) (nth level chain)
                                        (nth (1- level) areas) (nth level areas) 2 offset))
                   (loop for level from (1- passes) downto 0
                         do (%blur-pass renderer (stage-renderer-blur-up renderer)
                                        (nth (1+ level) chain) (nth level chain)
                                        (nth (1+ level) areas) (nth level areas) 1/2 offset)))
              (setf (stage-renderer-viewport-width renderer) (coerce buffer-width 'double-float)
                    (stage-renderer-viewport-height renderer) (coerce buffer-height 'double-float))
              (ataxia.world.gles:gles-set-blending-enabled t)
              (ataxia.world.gles:gles-set-scissor-enabled t)
              (apply #'ataxia.world.gles:gles-set-scissor (stage-renderer-scissor renderer)))
            (let ((program (%use renderer (stage-renderer-backdrop renderer)))
                  (pixel (/ 1d0 (max 1d-9 (affine-scale-factor transform)))))
              (ataxia.world.gles:gles-uniform-4f program "u_bounds"
                                                 (/ (+ x 0.5d0) buffer-width) (/ (+ y 0.5d0) buffer-height)
                                                 (/ (- (+ x area-width) 0.5d0) buffer-width)
                                                 (/ (- (+ y area-height) 0.5d0) buffer-height))
              (ataxia.world.gles:gles-uniform-2f program "u_size" width height)
              (ataxia.world.gles:gles-uniform-1f program "u_radius" radius)
              (ataxia.world.gles:gles-uniform-1f program "u_pixel" pixel)
              (ataxia.world.gles:gles-uniform-1f program "u_opacity" opacity)
              (ataxia.world.gles:gles-uniform-1i program "u_texture" 0)
              (ataxia.world.gles:gles-bind-texture ataxia.world.gles:+texture-2d+
                                                   (render-target-texture (first chain)))
              (%draw-quad renderer transform 0d0 0d0 width height))))))))
