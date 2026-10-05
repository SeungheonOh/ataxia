;;;; Effects: the director's GLSL run over a node and its subtree, as CSS filters
;;;; run over an element.
;;;;
;;;; A node with a shader draws itself and its children into an offscreen
;;;; target covering just the effect's area, through a viewport offset so they
;;;; draw as they would on the output, then paints its box (or the whole output)
;;;; through a program built from the director's
;;;; `vec4 effect(vec2 position)`. What it contains stays ordinary items: they
;;;; are diffed and damaged and give frame callbacks as usual, but only their
;;;; effect draws them. Programs are compiled once per source and uniform layout;
;;;; one that fails reports its log as the node's error event and shows the node
;;;; unchanged. At amount 0 a node draws directly, at no cost.

(in-package #:ataxia.stage-world)

(defparameter +effect-prelude+
  "precision highp float;
varying vec2 v_local;
uniform vec2 u_viewport;
uniform sampler2D u_content;
uniform sampler2D u_backdrop;
uniform vec4 u_linear;
uniform vec2 u_translation;
uniform vec2 u_offset;
uniform vec2 u_texture_size;
uniform vec4 u_area;
uniform float u_opacity;
uniform vec2 size;
uniform float time;
uniform float amount;
uniform float pixel;
uniform vec2 pointer;
vec2 stage_uv(vec2 position) {
  vec2 buffer = vec2(u_linear.x * position.x + u_linear.z * position.y,
                     u_linear.y * position.x + u_linear.w * position.y) + u_translation;
  return clamp((buffer - u_offset) / u_texture_size, u_area.xy, u_area.zw);
}
vec4 content(vec2 position) { return texture2D(u_content, stage_uv(position)); }
vec4 backdrop(vec2 position) { return texture2D(u_backdrop, stage_uv(position)); }
"
  "Declarations every effect sees. POSITION, SIZE, PIXEL and POINTER are in the node's
local units; colors are premultiplied, as the effect must return them.")

(defparameter +far-pointer+ '(-1d6 -1d6)
  "Where the pointer is for an effect not reading it, or on another output.")

(defparameter +passthrough-effect+ "vec4 effect(vec2 position) { return content(position); }"
  "What a node whose shader does not compile is drawn through.")

(defparameter +max-shader-length+ 65536)

(defstruct (effect-state (:constructor %make-effect-state (start)))
  "What an effect node keeps between frames: when its `time` began, and the
source whose compile error was last reported."
  (start 0d0 :type double-float)
  (reported nil))

(defstruct (effect-draw (:constructor %make-effect-draw))
  "What an effect item paints: its program's source and uniforms, the local quad
(X Y WIDTH HEIGHT) and the transform from it to buffer pixels."
  world node source uniforms transform quad size time amount pointer opacity backdrop-p)

(defun %effect-state (world node)
  (or (gethash node (%effect-states world))
      (setf (gethash node (%effect-states world)) (%make-effect-state (%now)))))

(defun %effect-pointer (context quad-transform)
  "The first seat's pointer in the local units of QUAD-TRANSFORM, when it is on this output."
  (let* ((world (display-context-world context))
         (seat-state (%default-seat-state world))
         (inverse (affine-invert quad-transform)))
    (multiple-value-bind (stage-output x y) (and seat-state (%seat-screen-point world seat-state))
      (if (and inverse (eq stage-output (display-context-stage-output context)))
          (multiple-value-list
           (affine-apply (affine-multiply inverse (display-context-screen context)) x y))
          +far-pointer+))))

(defun %logical-rectangle (context rectangle)
  "Output-logical bounds of buffer RECTANGLE, for clipping hits."
  (let ((to-logical (affine-invert (display-context-screen context))))
    (if to-logical
        (affine-rectangle-bounds to-logical (ataxia.world:rectangle-x rectangle)
                                 (ataxia.world:rectangle-y rectangle)
                                 (ataxia.world:rectangle-width rectangle)
                                 (ataxia.world:rectangle-height rectangle))
        (display-context-logical-clip context))))

(defun effect-shown-p (node)
  (and (node-prop node :shader) (plusp (node-number node :amount 1d0))))

(defun emit-effect (context kind node transform opacity screen-inverse parent-inverse)
  "Emit NODE's effect item, then NODE and its subtree into the effect's content."
  (let* ((world (display-context-world context))
         (output-p (eq (node-prop node :area) :output))
         ;; Over the whole output, positions are output-logical pixels.
         (quad-transform (if output-p (display-context-screen context) transform))
         (size (multiple-value-list
                (if output-p
                    (ataxia.world:output-logical-size
                     (stage-output-output (display-context-stage-output context)))
                    (%node-size world node))))
         (margin (max 0d0 (node-number node :margin 0d0)))
         (quad (list (- margin) (- margin) (+ (first size) (* 2 margin)) (+ (second size) (* 2 margin))))
         (time-p (node-prop node :time))
         (time (if time-p
                   (max 0d0 (- (%advanced-at world) (effect-state-start (%effect-state world node))))
                   0d0))
         (uniforms (loop for (name . channels) in (stage-node-uniforms node)
                         collect (cons name (map 'vector #'channel-value channels))))
         (pointer-p (node-prop node :pointer))
         (pointer (if pointer-p (%effect-pointer context quad-transform) +far-pointer+))
         (draw (%make-effect-draw :world world :node node :source (node-prop node :shader)
                                  :uniforms uniforms :transform quad-transform :quad quad :size size
                                  :time time :amount (node-number node :amount 1d0) :pointer pointer
                                  :opacity opacity
                                  :backdrop-p (node-prop node :backdrop)))
         (item (%emit context (list (stage-node-id node) :effect)
                      (destructuring-bind (x y width height) quad
                        (affine-rectangle-bounds quad-transform x y width height 1))
                      (list (effect-draw-source draw) uniforms quad-transform quad time pointer
                            (effect-draw-amount draw) opacity (effect-draw-backdrop-p draw))
                      nil)))
    (when item
      (setf (item-effect item) draw)
      ;; Shown, a running clock repaints the effect every frame, like a loop, and
      ;; one reading the pointer is rebuilt as it moves.
      (when time-p (setf (display-context-animating-p context) t))
      (when pointer-p
        (setf (stage-output-pointer-effects-p (display-context-stage-output context)) t))
      ;; Unless the shader reads only its own pixel, any change inside repaints all
      ;; of it, as for a backdrop blur.
      (unless (and (node-prop node :local) (not (effect-draw-backdrop-p draw)))
        (setf (item-blur-area item) (item-bounds item)))
      (let ((owner (display-context-owner context))
            (clip (display-context-clip context))
            (logical-clip (display-context-logical-clip context))
            (before (display-context-items context)))
        (setf (display-context-owner context) item
              (display-context-clip context) (item-bounds item)
              (display-context-logical-clip context) (%logical-rectangle context (item-bounds item)))
        ;; The effect applies the node's opacity to its content as a whole.
        (emit-content kind context node transform 1d0 screen-inverse parent-inverse)
        (%emit-subtree context node transform screen-inverse 1d0)
        (setf (item-children item)
              (loop for rest on (display-context-items context)
                    until (eq rest before)
                    when (eq (item-owner (car rest)) item) collect (car rest) into owned
                    finally (return (nreverse owned)))
              (display-context-owner context) owner
              (display-context-clip context) clip
              (display-context-logical-clip context) logical-clip)))))

;;; Drawing.

(defun %effect-source (source uniforms)
  (with-output-to-string (out)
    (write-string +effect-prelude+ out)
    (loop for (name . values) in uniforms
          do (format out "uniform ~A ~A;~%" (ecase (length values) (1 "float") (2 "vec2") (4 "vec4")) name))
    ;; The director's lines number from 1 in compile errors.
    (format out "#line 1~%~A~%void main() { gl_FragColor = effect(v_local) * u_opacity; }~%" source)))

(defun %effect-program (renderer source uniforms)
  "The program for SOURCE with UNIFORMS' layout, or why it could not be built."
  (let* ((key (cons source (mapcar (lambda (uniform) (cons (car uniform) (length (cdr uniform))))
                                   uniforms)))
         (entry (or (gethash key (stage-renderer-effects renderer))
                    (setf (gethash key (stage-renderer-effects renderer))
                          (cons (handler-case
                                    (if (> (length source) +max-shader-length+)
                                        "The shader exceeds 64 KiB."
                                        (%make-program (%effect-source source uniforms)))
                                  (error (cause) (princ-to-string cause)))
                                0d0)))))
    (setf (cdr entry) (%now))
    (car entry)))

(defun %usable-effect-program (renderer draw)
  "DRAW's program, or after reporting why it failed, one showing the content as is."
  (let ((program (%effect-program renderer (effect-draw-source draw) (effect-draw-uniforms draw))))
    (if (stringp program)
        (let ((state (%effect-state (effect-draw-world draw) (effect-draw-node draw))))
          (unless (eq (effect-state-reported state) (effect-draw-source draw))
            (setf (effect-state-reported state) (effect-draw-source draw))
            (%log "effect ~D: ~A" (stage-node-id (effect-draw-node draw)) program)
            (%emit-event (effect-draw-world draw) (effect-draw-node draw) :error :message program))
          (%effect-program renderer +passthrough-effect+ nil))
        program)))

(defparameter +effect-target-step+ 256
  "Effect targets come in sizes stepped by this many pixels, so an effect whose area
moves or animates keeps reusing one.")

(defun %effect-target (renderer width height depth role)
  "A target of at least WIDTH x HEIGHT pixels for effects nested DEPTH deep, as their
content or backdrop."
  (flet ((stepped (size) (* +effect-target-step+ (max 1 (ceiling size +effect-target-step+)))))
    (let* ((key (list (stepped width) (stepped height) depth role))
           (entry (or (gethash key (stage-renderer-effect-targets renderer))
                      (setf (gethash key (stage-renderer-effect-targets renderer))
                            (cons (make-render-target (first key) (second key)) 0d0)))))
      (setf (cdr entry) (%now))
      (car entry))))

(defun draw-effect (renderer item rectangle width height)
  "Paint effect ITEM within buffer RECTANGLE: its children into its content, then its
quad through its program. Return the presentation tokens of surfaces drawn."
  (let ((area (ataxia.world:rectangle-intersection rectangle (item-bounds item)))
        (draw (item-effect item)))
    (when area
      (multiple-value-bind (x y area-width area-height)
          (ataxia.world:rectangle-pixel-bounds area width height)
        (when (and (plusp area-width) (plusp area-height))
          ;; The targets cover the effect's bounds, whose first pixel is (LEFT, BOTTOM).
          (multiple-value-bind (left bottom bounds-width bounds-height)
              (ataxia.world:rectangle-pixel-bounds (item-bounds item) width height)
            (let* ((depth (stage-renderer-effect-depth renderer))
                   (scissor (stage-renderer-scissor renderer))
                   (outer-x (stage-renderer-origin-x renderer))
                   (outer-y (stage-renderer-origin-y renderer))
                   (content (%effect-target renderer bounds-width bounds-height depth :content))
                   (backdrop (and (effect-draw-backdrop-p draw)
                                  (%effect-target renderer bounds-width bounds-height depth :backdrop)))
                   (tokens nil))
              ;; What is drawn so far, behind the effect, before the content replaces it.
              (when backdrop
                (gl-copy-framebuffer backdrop (- x left) (- y bottom) area-width area-height
                                     (- x outer-x) (- y outer-y)))
              (setf (stage-renderer-effect-depth renderer) (1+ depth)
                    (stage-renderer-origin-x renderer) left
                    (stage-renderer-origin-y renderer) bottom)
              (unwind-protect
                   (call-with-offset-target
                    content left bottom width height
                    (lambda ()
                      (set-stage-scissor renderer x y area-width area-height)
                      (ataxia.world.gles:gles-clear 0d0 0d0 0d0 0d0)
                      (setf tokens (draw-layer renderer (item-children item) area width height item))))
                (setf (stage-renderer-effect-depth renderer) depth
                      (stage-renderer-origin-x renderer) outer-x
                      (stage-renderer-origin-y renderer) outer-y)
                (apply #'set-stage-scissor renderer scissor))
              (%paint-effect renderer draw content backdrop x y area-width area-height left bottom)
              tokens)))))))

(defun %paint-effect (renderer draw content backdrop x y area-width area-height left bottom)
  "Paint DRAW's quad through its program over buffer area (X, Y, AREA-WIDTH, AREA-HEIGHT),
sampling CONTENT and BACKDROP, whose first pixel is buffer pixel (LEFT, BOTTOM)."
  (let ((program (%use renderer (%usable-effect-program renderer draw)))
        (transform (effect-draw-transform draw)))
    (flet ((uniform (name values)
             (case (length values)
               (1 (ataxia.world.gles:gles-uniform-1f program name (aref values 0)))
               (2 (ataxia.world.gles:gles-uniform-2f program name (aref values 0) (aref values 1)))
               (4 (ataxia.world.gles:gles-uniform-4f program name (aref values 0) (aref values 1)
                                                     (aref values 2) (aref values 3))))))
      (ataxia.world.gles:gles-uniform-4f program "u_linear" (affine-a transform) (affine-b transform)
                                         (affine-c transform) (affine-d transform))
      (ataxia.world.gles:gles-uniform-2f program "u_translation" (affine-e transform) (affine-f transform))
      (let ((texture-width (coerce (render-target-width content) 'double-float))
            (texture-height (coerce (render-target-height content) 'double-float)))
        (ataxia.world.gles:gles-uniform-2f program "u_offset" left bottom)
        (ataxia.world.gles:gles-uniform-2f program "u_texture_size" texture-width texture-height)
        ;; Samples stay inside the pixels this draw rendered.
        (ataxia.world.gles:gles-uniform-4f program "u_area"
                                           (/ (+ (- x left) 0.5d0) texture-width)
                                           (/ (+ (- y bottom) 0.5d0) texture-height)
                                           (/ (- (+ (- x left) area-width) 0.5d0) texture-width)
                                           (/ (- (+ (- y bottom) area-height) 0.5d0) texture-height)))
      (ataxia.world.gles:gles-uniform-1f program "u_opacity" (effect-draw-opacity draw))
      (uniform "size" (coerce (effect-draw-size draw) 'vector))
      (ataxia.world.gles:gles-uniform-1f program "time" (effect-draw-time draw))
      (ataxia.world.gles:gles-uniform-1f program "amount" (effect-draw-amount draw))
      (uniform "pointer" (coerce (effect-draw-pointer draw) 'vector))
      (ataxia.world.gles:gles-uniform-1f program "pixel"
                                         (/ 1d0 (max 1d-9 (affine-scale-factor transform))))
      (loop for (name . values) in (effect-draw-uniforms draw) do (uniform name values))
      (ataxia.world.gles:gles-uniform-1i program "u_content" 0)
      (ataxia.world.gles:gles-uniform-1i program "u_backdrop" 1)
      (%gl-active-texture (1+ +gl-texture-0+))
      (%gl-bind-texture +gl-texture-2d+ (if backdrop (render-target-texture backdrop) 0))
      (ataxia.world.gles:gles-bind-texture +gl-texture-2d+ (render-target-texture content))
      (apply #'%draw-quad renderer transform (effect-draw-quad draw))
      (%gl-active-texture (1+ +gl-texture-0+))
      (%gl-bind-texture +gl-texture-2d+ 0)
      (%gl-active-texture +gl-texture-0+))))
