(in-package #:ataxia.infinite-world)

(defparameter +metaworld-grid-shader+
  "precision highp float;
uniform vec2 u_camera;
uniform vec2 u_viewport;
uniform float u_zoom;
uniform float u_rotation;
varying vec2 v_uv;
float reticle(vec2 world, float spacing) {
  vec2 point = abs(fract(world / spacing + 0.5) - 0.5) * spacing * u_zoom;
  float vertical = (1.0 - smoothstep(0.35, 1.0, point.x)) * (1.0 - smoothstep(2.0, 3.0, point.y));
  float horizontal = (1.0 - smoothstep(0.35, 1.0, point.y)) * (1.0 - smoothstep(2.0, 3.0, point.x));
  return max(vertical, horizontal);
}
void main() {
  vec2 delta = v_uv * u_viewport - u_viewport * 0.5;
  float cosine = cos(u_rotation);
  float sine = sin(u_rotation);
  vec2 canvas = vec2(cosine * delta.x + sine * delta.y,
                    -sine * delta.x + cosine * delta.y) + u_viewport * 0.5;
  vec2 world = u_camera + canvas / u_zoom;
  float level = log2(112.0 / (96.0 * u_zoom));
  float spacing = 96.0 * exp2(floor(level));
  float marks = mix(reticle(world, spacing), reticle(world, spacing * 2.0), fract(level));
  vec3 base = vec3(0.970);
  gl_FragColor = vec4(mix(base, vec3(0.68), marks * 0.36), 1.0);
}")

(defmethod %world-grid-shader ((world metaworld))
  +metaworld-grid-shader+)

(defun %meta-dashed-rectangle (renderer state x y width height color)
  (multiple-value-bind (viewport-width viewport-height) (%output-logical-size state)
    (let ((step 24d0)
          (pattern '((0d0 . 1d0) (5d0 . 5d0) (14d0 . 1d0)))
          (vertices (make-array 4096 :adjustable t :fill-pointer 0 :element-type 'single-float))
          (uv '((0d0 . 0d0) (1d0 . 0d0) (0d0 . 1d0) (1d0 . 1d0))))
      (labels ((stroke (left top stroke-width stroke-height)
                 (loop for value across (%quad-vertices
                                         (%canvas-quad state left top stroke-width stroke-height) uv)
                       do (vector-push-extend (coerce value 'single-float) vertices))))
        (loop for offset from (* step (max 0 (floor (/ (- x) step)))) below width by step
              while (< (+ x offset) viewport-width)
              do (dolist (segment pattern)
                   (let ((start (+ offset (car segment))))
                     (when (< start width)
                       (stroke (round (+ x start)) (round y) (min (cdr segment) (- width start)) 1d0)
                       (stroke (round (+ x start)) (round (+ y height))
                               (min (cdr segment) (- width start)) 1d0)))))
        (loop for offset from (* step (max 0 (floor (/ (- y) step)))) below height by step
              while (< (+ y offset) viewport-height)
              do (dolist (segment pattern)
                   (let ((start (+ offset (car segment))))
                     (when (< start height)
                       (stroke (round x) (round (+ y start)) 1d0 (min (cdr segment) (- height start)))
                       (stroke (round (+ x width)) (round (+ y start))
                               1d0 (min (cdr segment) (- height start))))))))
      (when (plusp (length vertices))
        (let ((program (%canvas-renderer-solid-program renderer)))
          (%bind-vertices renderer vertices)
          (ataxia.world.gles:gles-use-program program)
          (apply #'ataxia.world.gles:gles-uniform-4f program "u_color" color)
          (ataxia.world.gles:gles-draw-triangles (/ (length vertices) 4)))))))
