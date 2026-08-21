;;;; Behavior-owned application reveal effects.
;;;;
;;;; New views may temporarily replace their surface program with a codec-
;;;; corruption material. Animation bindings restore the prior program after
;;;; the reveal, leaving core view and renderer policy unchanged.

(in-package #:ataxia.compositor)

(defparameter +codec-reveal-program-name+ :behavior-codec-reveal)

(defparameter +codec-reveal-uniforms+
  '(texture-sampler opacity texture-has-alpha reveal-progress
    corruption-phase fragmentation displacement chroma-separation))

(defun codec-reveal-fragment-shader (external-p)
  (format
   nil
   "~:[~;#extension GL_OES_EGL_image_external :require~%~]precision mediump float;
varying vec2 texture_coordinate;
uniform ~A texture_sampler;
uniform float opacity;
uniform float texture_has_alpha;
uniform float reveal_progress;
uniform float corruption_phase;
uniform float fragmentation;
uniform float displacement;
uniform float chroma_separation;

float codec_random(float seed) {
  return fract(sin(seed * 91.3458) * 47453.5453);
}

vec2 codec_random2(float seed) {
  return vec2(codec_random(seed + 17.17), codec_random(seed + 63.41));
}

void main() {
  vec2 clean_uv = texture_coordinate;
  float amount = clamp(1.0 - reveal_progress, 0.0, 1.0);
  float epoch = floor(corruption_phase * 1.35);
  vec2 damaged_uv = clean_uv;
  float fragment_mask = 0.0;
  float fragment_noise = codec_random(epoch + 7.0);

  for (int fragment_index = 0; fragment_index < 7; fragment_index++) {
    float index = float(fragment_index);
    float seed = epoch * 37.0 + index * 83.0 + 11.0;
    vec2 center = codec_random2(seed);
    vec2 random_size = codec_random2(seed + 29.0);
    vec2 half_size = vec2(
        mix(0.035, 0.31, pow(random_size.x, 1.45)),
        mix(0.004, 0.075, pow(random_size.y, 2.1)));
    vec2 distance_to_center = abs(clean_uv - center);
    float inside = step(distance_to_center.x, half_size.x)
                 * step(distance_to_center.y, half_size.y);
    float active = step(codec_random(seed + 51.0), fragmentation);
    float region = inside * active;
    float signed_noise = codec_random(seed + 71.0) * 2.0 - 1.0;
    vec2 source_uv = clean_uv;
    source_uv.x += signed_noise * displacement
                 * mix(0.25, 1.0, codec_random(seed + 91.0));
    source_uv.y += (codec_random(seed + 113.0) - 0.5)
                 * half_size.y * 1.8;
    source_uv.x = mix(
        source_uv.x,
        center.x + (source_uv.x - center.x)
                 * mix(0.12, 0.72, codec_random(seed + 137.0)),
        codec_random(seed + 149.0));
    damaged_uv = mix(damaged_uv, source_uv, region * amount);
    fragment_mask = max(fragment_mask, region);
    fragment_noise = mix(
        fragment_noise, codec_random(seed + 173.0), region);
  }

  damaged_uv = clamp(damaged_uv, vec2(0.002), vec2(0.998));

  float split = chroma_separation * amount * (0.3 + fragment_mask);
  vec4 clean_sample = texture2D(texture_sampler, clean_uv);
  vec4 damaged_sample = texture2D(texture_sampler, damaged_uv);
  float red = texture2D(
      texture_sampler, clamp(damaged_uv + vec2(split, 0.0),
                             vec2(0.002), vec2(0.998))).r;
  float blue = texture2D(
      texture_sampler, clamp(damaged_uv - vec2(split, 0.0),
                             vec2(0.002), vec2(0.998))).b;
  vec3 codec_color = vec3(red, damaged_sample.g, blue);
  float posterize = mix(7.0, 32.0, reveal_progress);
  vec3 quantized = floor(codec_color * posterize + 0.5) / posterize;
  codec_color = mix(codec_color, quantized, fragment_mask);
  codec_color += (fragment_noise - 0.5) * 0.16
               * amount * fragment_mask;

  float corruption_mix = amount * mix(0.16, 1.0, fragment_mask);
  vec3 color = mix(clean_sample.rgb, codec_color, corruption_mix);
  float alpha = texture_has_alpha > 0.5 ? clean_sample.a : 1.0;
  gl_FragColor = vec4(color, alpha) * opacity;
}"
   external-p
   (if external-p "samplerExternalOES" "sampler2D")))

(defclass codec-reveal-style ()
  ((enabled-p :initarg :enabled-p :initform t
              :accessor codec-reveal-enabled-p)
   (duration :initarg :duration :initform 1.10d0
             :accessor codec-reveal-duration)
   (fragmentation :initarg :fragmentation :initform 0.78d0
                  :accessor codec-reveal-fragmentation)
   (displacement :initarg :displacement :initform 0.16d0
                 :accessor codec-reveal-displacement)
   (chroma-separation :initarg :chroma-separation :initform 0.018d0
                      :accessor codec-reveal-chroma-separation)))

(defclass reveal-progress-binding (shader-uniform-binding)
  ((program-name :initarg :program-name :reader reveal-binding-program-name)
   (previous-program :initarg :previous-program
                     :reader reveal-binding-previous-program)))

(defun codec-reveal-uniform-table (view)
  (presentation-shader-uniforms (view-presentation-state view)))

(defun clear-codec-reveal-state (view &optional previous-program)
  (when (eq (view-shader-program-name view) +codec-reveal-program-name+)
    (setf (view-shader-program-name view) previous-program))
  (let ((uniforms (codec-reveal-uniform-table view)))
    (dolist (name '(reveal-progress corruption-phase fragmentation
                    displacement chroma-separation))
      (remhash name uniforms)))
  (remhash 'codec-reveal-previous-program
           (presentation-effect-parameters (view-presentation-state view)))
  view)

(defmethod apply-animation-sample
    ((subject view) (property reveal-progress-binding) value context)
  (call-next-method)
  (when (>= value (- 1d0 1d-6))
    (clear-codec-reveal-state
     subject (reveal-binding-previous-program property)))
  subject)

(defun install-codec-reveal-variant (policy renderer kind external-p)
  (unless (shader-program-installed-p
           renderer +codec-reveal-program-name+ kind policy)
    (replace-shader-program
     renderer +codec-reveal-program-name+
     (make-texture-program-descriptor
      (codec-reveal-fragment-shader external-p)
      +codec-reveal-uniforms+ kind)
     policy)))

(defun ensure-codec-reveal-programs (policy)
  (let ((renderer (compositor-graphics (component-compositor policy))))
    (dolist (variant '((:texture-2d nil) (:texture-external t)))
      (handler-case
          (install-codec-reveal-variant
           policy renderer (first variant) (second variant))
        (graphics-failure (condition)
          (format *error-output*
                  "[behavior] codec reveal ~A unavailable: ~A~%"
                  (first variant) condition))))
    (or (shader-program-installed-p
         renderer +codec-reveal-program-name+ :texture-2d policy)
        (shader-program-installed-p
         renderer +codec-reveal-program-name+ :texture-external policy))))

(defun codec-reveal-seed (view)
  (coerce (mod (+ (* (view-id view) 37) 11) 997) 'double-float))

(defun make-codec-reveal-animation (policy view)
  (let ((style (behavior-application-reveal-style policy)))
    (when (and style (codec-reveal-enabled-p style)
               (ensure-codec-reveal-programs policy))
      (let* ((state (view-presentation-state view))
             (parameters (presentation-effect-parameters state))
             (current-program (view-shader-program-name view))
             (previous-program
               (if (eq current-program +codec-reveal-program-name+)
                   (gethash 'codec-reveal-previous-program parameters)
                   current-program))
             (seed (codec-reveal-seed view))
             (uniforms (presentation-shader-uniforms state)))
        (setf (gethash 'codec-reveal-previous-program parameters)
              previous-program
              (view-shader-program-name view) +codec-reveal-program-name+
              (gethash 'reveal-progress uniforms) 0d0
              (gethash 'corruption-phase uniforms) seed
              (gethash 'fragmentation uniforms)
              (codec-reveal-fragmentation style)
              (gethash 'displacement uniforms)
              (codec-reveal-displacement style)
              (gethash 'chroma-separation uniforms)
              (codec-reveal-chroma-separation style))
        (make-instance
         'animation-definition :name :codec-reveal
         :duration (codec-reveal-duration style)
         :tracks
         (list
          (make-instance
           'animation-track
           :property
           (make-instance
            'reveal-progress-binding :name 'reveal-progress
            :program-name +codec-reveal-program-name+
            :previous-program previous-program)
           :from 0d0 :to 1d0 :interpolator #'linear-interpolation)
          (make-instance
           'animation-track
           :property
           (make-instance 'shader-uniform-binding :name 'corruption-phase)
           :from seed :to (+ seed 8d0)
           :interpolator #'linear-interpolation)))))))

(defmethod behavior-view-unmapped :after
    ((policy behavior-policy) view)
  (declare (ignore policy))
  (let* ((parameters
           (presentation-effect-parameters (view-presentation-state view)))
         (previous-program
           (gethash 'codec-reveal-previous-program parameters)))
    (when (or previous-program
              (eq (view-shader-program-name view)
                  +codec-reveal-program-name+))
      (clear-codec-reveal-state view previous-program))))
