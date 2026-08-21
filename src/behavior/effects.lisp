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
   (color :initarg :color :initform '(0.0 0.0 0.0 0.42)
          :accessor soft-shadow-color)
   (inset :initarg :inset :initform 24d0 :accessor soft-shadow-inset)
   (corner-radius :initarg :corner-radius :initform 12d0
                  :accessor soft-shadow-corner-radius)
   (blur-radius :initarg :blur-radius :initform 8d0
                :accessor soft-shadow-blur-radius)))

(defun ensure-soft-shadow-program (policy)
  (let ((renderer (compositor-graphics (component-compositor policy))))
    (unless (shader-program-installed-p
             renderer +soft-shadow-program-name+ :material)
      (replace-shader-program
       renderer +soft-shadow-program-name+
       (make-material-program-descriptor
        +soft-shadow-fragment-shader+
        '(color rectangle-size shadow-inset corner-radius blur-radius))))))

(defun make-soft-shadow-item (policy owner x y width height)
  "Return a policy-configured shadow item, or NIL when the effect is disabled."
  (let ((style (behavior-shadow-style policy)))
    (when (and style (soft-shadow-enabled-p style))
      (ensure-soft-shadow-program policy)
      (let ((inset (soft-shadow-inset style)))
        (make-shader-item
         (- x inset) (- y inset)
         (+ width (* 2d0 inset)) (+ height (* 2d0 inset))
         +soft-shadow-program-name+
         `((color . ,(soft-shadow-color style))
           (rectangle-size . (,(+ width (* 2d0 inset))
                              ,(+ height (* 2d0 inset))))
           (shadow-inset . ,inset)
           (corner-radius . ,(soft-shadow-corner-radius style))
           (blur-radius . ,(soft-shadow-blur-radius style)))
         :owner owner)))))
