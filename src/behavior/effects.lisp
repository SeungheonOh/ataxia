;;;; Behavior-owned graphical effects.
;;;;
;;;; Effects define their own GLES programs, uniforms, and presentation items.
;;;; The compositor renderer only registers and executes generic materials.

(in-package #:ataxia.compositor)

(defparameter +soft-shadow-program-name+ :behavior-soft-shadow)

(defparameter +soft-shadow-fragment-shader+
  "precision mediump float;
varying vec2 texture_coordinate;
uniform vec4 color;
uniform vec2 rectangle_size;
uniform float shadow_inset;
uniform float corner_radius;
uniform float blur_radius;

float rounded_box_distance(vec2 point, vec2 half_size, float radius) {
  vec2 corner = abs(point) - max(half_size - vec2(radius), vec2(0.0));
  return length(max(corner, vec2(0.0)))
       + min(max(corner.x, corner.y), 0.0) - radius;
}

void main() {
  vec2 pixel = texture_coordinate * rectangle_size;
  vec2 half_size = max(rectangle_size * 0.5 - vec2(shadow_inset), vec2(1.0));
  float radius = min(corner_radius, min(half_size.x, half_size.y));
  float distance = rounded_box_distance(
      pixel - rectangle_size * 0.5, half_size, radius);
  float sigma = max(blur_radius, 0.5);
  float exterior = max(distance, 0.0);
  float alpha = color.a * exp(-0.5 * exterior * exterior / (sigma * sigma));
  gl_FragColor = vec4(color.rgb * alpha, alpha);
}")

(defclass soft-shadow-style ()
  ((enabled-p :initarg :enabled-p :initform t
              :accessor soft-shadow-enabled-p)
   (color :initarg :color :initform '(0.0 0.0 0.0 0.24)
          :accessor soft-shadow-color)
   (inset :initarg :inset :initform 20d0 :accessor soft-shadow-inset)
   (corner-radius :initarg :corner-radius :initform 12d0
                  :accessor soft-shadow-corner-radius)
   (blur-radius :initarg :blur-radius :initform 12d0
                :accessor soft-shadow-blur-radius)
   (lifted-blur-radius :initarg :lifted-blur-radius :initform 24d0
                       :accessor soft-shadow-lifted-blur-radius)
   (rest-offset-x :initarg :rest-offset-x :initform 0d0
                  :accessor soft-shadow-rest-offset-x)
   (rest-offset-y :initarg :rest-offset-y :initform 2d0
                  :accessor soft-shadow-rest-offset-y)
   (lifted-offset-x :initarg :lifted-offset-x :initform 0d0
                    :accessor soft-shadow-lifted-offset-x)
   (lifted-offset-y :initarg :lifted-offset-y :initform 16d0
                    :accessor soft-shadow-lifted-offset-y)
   (ambient-color :initarg :ambient-color
                  :initform '(0.0 0.0 0.0 0.16)
                  :accessor soft-shadow-ambient-color)
   (ambient-blur-radius :initarg :ambient-blur-radius :initform 7d0
                        :accessor soft-shadow-ambient-blur-radius)))

(defclass effect-parameter-binding ()
  ((name :initarg :name :reader effect-parameter-binding-name)))

(defun view-effect-parameter (view name &optional (default 0d0))
  (gethash name
           (presentation-effect-parameters (view-presentation-state view))
           default))

(defun (setf view-effect-parameter) (value view name &optional default)
  (declare (ignore default))
  (setf (gethash name
                 (presentation-effect-parameters
                  (view-presentation-state view)))
        value))

(defun ensure-soft-shadow-program (policy)
  (let ((renderer (compositor-graphics (component-compositor policy))))
    (unless (shader-program-installed-p
             renderer +soft-shadow-program-name+ :material policy)
      (replace-shader-program
       renderer +soft-shadow-program-name+
       (make-material-program-descriptor
        +soft-shadow-fragment-shader+
        '(color rectangle-size shadow-inset corner-radius blur-radius))
       policy))))

(defun interpolate-effect-value (from to progress)
  (+ from (* (- to from) progress)))

(defun make-shadow-material-item
    (style owner x y width height color blur-radius offset-x offset-y)
  ;; Three standard deviations plus the configured minimum keeps every side,
  ;; including the top edge, inside the analytic shadow quad.
  (let* ((padding
           (max (soft-shadow-inset style)
                (+ (* 3d0 blur-radius)
                   (max (abs offset-x) (abs offset-y)))))
         (item-width (+ width (* 2d0 padding)))
         (item-height (+ height (* 2d0 padding))))
    (make-shader-item
     (+ x offset-x (- padding))
     (+ y offset-y (- padding))
     item-width item-height +soft-shadow-program-name+
     `((color . ,color)
       (rectangle-size . (,item-width ,item-height))
       (shadow-inset . ,padding)
       (corner-radius . ,(soft-shadow-corner-radius style))
       (blur-radius . ,blur-radius))
     :owner owner)))

(defun make-soft-shadow-items (policy style owner x y width height)
  "Return ambient and cast shadows derived from per-view elevation."
  (when (and style (soft-shadow-enabled-p style))
      (ensure-soft-shadow-program policy)
      (let* ((elevation
               (max 0d0 (min 1d0
                             (view-effect-parameter owner 'elevation 0d0))))
             (cast-blur
               (interpolate-effect-value
                (soft-shadow-blur-radius style)
                (soft-shadow-lifted-blur-radius style) elevation))
             (offset-x
               (interpolate-effect-value
                (soft-shadow-rest-offset-x style)
                (soft-shadow-lifted-offset-x style) elevation))
             (offset-y
               (interpolate-effect-value
                (soft-shadow-rest-offset-y style)
                (soft-shadow-lifted-offset-y style) elevation)))
        (list
         (make-shadow-material-item
          style owner x y width height
          (soft-shadow-ambient-color style)
          (soft-shadow-ambient-blur-radius style) 0d0 0d0)
         (make-shadow-material-item
          style owner x y width height (soft-shadow-color style)
          cast-blur offset-x offset-y)))))
