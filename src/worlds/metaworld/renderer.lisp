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

(defvar *meta-border-cache* (make-hash-table :test #'eq :weakness :key))

(defun %meta-border-vertices (state x y width height)
  ;; The canvas-to-buffer transform is affine. Compute it once per border,
  ;; rather than repeating output queries and trigonometry for every dash.
  (multiple-value-bind (viewport-width viewport-height) (%output-logical-size state)
    (let* ((basis (%canvas-quad state 0d0 0d0 1d0 1d0))
           (key (list x y width height viewport-width viewport-height basis))
           (cache (gethash state *meta-border-cache*))
           (entry (assoc key cache :test #'equal)))
      (when entry (return-from %meta-border-vertices (cdr entry)))
      (let* ((origin (first basis))
             (xx (- (car (second basis)) (car origin)))
             (xy (- (cdr (second basis)) (cdr origin)))
             (yx (- (car (third basis)) (car origin)))
             (yy (- (cdr (third basis)) (cdr origin)))
             (vertices (make-array 4096 :adjustable t :fill-pointer 0
                                   :element-type 'single-float))
             (corners (loop for (px py) in (list (list 0d0 0d0) (list viewport-width 0d0)
                                                 (list 0d0 viewport-height) (list viewport-width viewport-height))
                            collect (multiple-value-list (%screen-to-canvas state px py))))
             (left (- (reduce #'min corners :key #'first) 1d0))
             (top (- (reduce #'min corners :key #'second) 1d0))
             (right (+ (reduce #'max corners :key #'first) 1d0))
             (bottom (+ (reduce #'max corners :key #'second) 1d0))
             (step 24d0)
             (pattern '((0d0 . 1d0) (5d0 . 5d0) (14d0 . 1d0))))
        (labels ((vertex (px py u v)
                   (vector-push-extend (coerce (+ (car origin) (* xx px) (* yx py)) 'single-float) vertices)
                   (vector-push-extend (coerce (+ (cdr origin) (* xy px) (* yy py)) 'single-float) vertices)
                   (vector-push-extend u vertices)
                   (vector-push-extend v vertices))
                 (stroke (left top w h)
                   (let ((right (+ left w)) (bottom (+ top h)))
                     (vertex left top 0f0 0f0)
                     (vertex right top 1f0 0f0)
                     (vertex left bottom 0f0 1f0)
                     (vertex right top 1f0 0f0)
                     (vertex right bottom 1f0 1f0)
                     (vertex left bottom 0f0 1f0))))
          (loop for offset from (* step (max 0 (floor (/ (- left x) step)))) below width by step
                while (< (+ x offset) right)
                do (dolist (segment pattern)
                     (let ((start (+ offset (car segment))))
                       (when (< start width)
                         (stroke (round (+ x start)) (round y) (min (cdr segment) (- width start)) 1d0)
                         (stroke (round (+ x start)) (round (+ y height))
                                 (min (cdr segment) (- width start)) 1d0)))))
          (loop for offset from (* step (max 0 (floor (/ (- top y) step)))) below height by step
                while (< (+ y offset) bottom)
                do (dolist (segment pattern)
                     (let ((start (+ offset (car segment))))
                       (when (< start height)
                         (stroke (round x) (round (+ y start)) 1d0 (min (cdr segment) (- height start)))
                         (stroke (round (+ x width)) (round (+ y start))
                                 1d0 (min (cdr segment) (- height start))))))))
        ;; Keep a bounded cache as the camera moves; the weak output key allows
        ;; retired Worlds and outputs to be reclaimed.
        (let ((packed (make-array (length vertices) :element-type 'single-float
                                 :initial-contents vertices)))
          (setf (gethash state *meta-border-cache*)
                (cons (cons key packed) (subseq cache 0 (min 15 (length cache)))))
          packed)))))

(defun %meta-dashed-rectangle (renderer state x y width height color)
  (let ((vertices (%meta-border-vertices state x y width height)))
    (when (plusp (length vertices))
      (let ((program (%canvas-renderer-solid-program renderer)))
        (%bind-vertices renderer vertices)
        (ataxia.world.gles:gles-use-program program)
        (apply #'ataxia.world.gles:gles-uniform-4f program "u_color" color)
        (ataxia.world.gles:gles-draw-triangles (/ (length vertices) 4))))))
