;;;; Direct OpenGL ES graphics executor.
;;;;
;;;; The renderer uses Runtime's wlroots-owned EGL context, scanout-compatible
;;;; buffers, and GLES texture names. It executes generic shader materials while
;;;; behavior modules own the visual effects those materials implement.

(in-package #:ataxia.compositor)

(cffi:define-foreign-library glesv2
  (:unix (:or "libGLESv2.so.2" "libGLESv2.so")))
(cffi:use-foreign-library glesv2)

(defconstant +gl-false+ 0)
(defconstant +gl-float+ #x1406)
(defconstant +gl-triangles+ #x0004)
(defconstant +gl-color-buffer-bit+ #x00004000)
(defconstant +gl-blend+ #x0BE2)
(defconstant +gl-one+ 1)
(defconstant +gl-one-minus-src-alpha+ #x0303)
(defconstant +gl-framebuffer+ #x8D40)
(defconstant +gl-framebuffer-complete+ #x8CD5)
(defconstant +gl-texture0+ #x84C0)
(defconstant +gl-texture-2d+ #x0DE1)
(defconstant +gl-texture-min-filter+ #x2801)
(defconstant +gl-texture-mag-filter+ #x2800)
(defconstant +gl-linear+ #x2601)
(defconstant +gl-vertex-shader+ #x8B31)
(defconstant +gl-fragment-shader+ #x8B30)
(defconstant +gl-compile-status+ #x8B81)
(defconstant +gl-link-status+ #x8B82)
(defconstant +gl-info-log-length+ #x8B84)
(defconstant +gl-no-error+ 0)

(defparameter +renderer-clear-color+ '(0.0 0.0 0.0 0.0))

(cffi:defcfun ("glCreateShader" %gl-create-shader) :uint32
  (shader-type :uint32))
(cffi:defcfun ("glShaderSource" %gl-shader-source) :void
  (shader :uint32) (count :int) (strings :pointer) (lengths :pointer))
(cffi:defcfun ("glCompileShader" %gl-compile-shader) :void
  (shader :uint32))
(cffi:defcfun ("glGetShaderiv" %gl-get-shader-iv) :void
  (shader :uint32) (parameter :uint32) (value :pointer))
(cffi:defcfun ("glGetShaderInfoLog" %gl-get-shader-info-log) :void
  (shader :uint32) (capacity :int) (length :pointer) (log :pointer))
(cffi:defcfun ("glDeleteShader" %gl-delete-shader) :void
  (shader :uint32))
(cffi:defcfun ("glCreateProgram" %gl-create-program) :uint32)
(cffi:defcfun ("glAttachShader" %gl-attach-shader) :void
  (program :uint32) (shader :uint32))
(cffi:defcfun ("glBindAttribLocation" %gl-bind-attrib-location) :void
  (program :uint32) (index :uint32) (name :string))
(cffi:defcfun ("glLinkProgram" %gl-link-program) :void
  (program :uint32))
(cffi:defcfun ("glGetProgramiv" %gl-get-program-iv) :void
  (program :uint32) (parameter :uint32) (value :pointer))
(cffi:defcfun ("glGetProgramInfoLog" %gl-get-program-info-log) :void
  (program :uint32) (capacity :int) (length :pointer) (log :pointer))
(cffi:defcfun ("glDeleteProgram" %gl-delete-program) :void
  (program :uint32))
(cffi:defcfun ("glUseProgram" %gl-use-program) :void
  (program :uint32))
(cffi:defcfun ("glGetUniformLocation" %gl-get-uniform-location) :int
  (program :uint32) (name :string))
(cffi:defcfun ("glUniform1i" %gl-uniform-1i) :void
  (location :int) (value :int))
(cffi:defcfun ("glUniform1f" %gl-uniform-1f) :void
  (location :int) (value :float))
(cffi:defcfun ("glUniform2f" %gl-uniform-2f) :void
  (location :int) (first :float) (second :float))
(cffi:defcfun ("glUniform3f" %gl-uniform-3f) :void
  (location :int) (first :float) (second :float) (third :float))
(cffi:defcfun ("glUniform4f" %gl-uniform-4f) :void
  (location :int) (red :float) (green :float) (blue :float) (alpha :float))
(cffi:defcfun ("glEnableVertexAttribArray" %gl-enable-vertex-attrib-array)
    :void (index :uint32))
(cffi:defcfun ("glDisableVertexAttribArray" %gl-disable-vertex-attrib-array)
    :void (index :uint32))
(cffi:defcfun ("glVertexAttribPointer" %gl-vertex-attrib-pointer) :void
  (index :uint32) (size :int) (type :uint32) (normalized :uint8)
  (stride :int) (pointer :pointer))
(cffi:defcfun ("glActiveTexture" %gl-active-texture) :void
  (texture :uint32))
(cffi:defcfun ("glBindTexture" %gl-bind-texture) :void
  (target :uint32) (texture :uint32))
(cffi:defcfun ("glTexParameteri" %gl-tex-parameter-i) :void
  (target :uint32) (parameter :uint32) (value :int))
(cffi:defcfun ("glEnable" %gl-enable) :void (capability :uint32))
(cffi:defcfun ("glDisable" %gl-disable) :void (capability :uint32))
(cffi:defcfun ("glBlendFunc" %gl-blend-func) :void
  (source :uint32) (destination :uint32))
(cffi:defcfun ("glViewport" %gl-viewport) :void
  (x :int) (y :int) (width :int) (height :int))
(cffi:defcfun ("glClearColor" %gl-clear-color) :void
  (red :float) (green :float) (blue :float) (alpha :float))
(cffi:defcfun ("glClear" %gl-clear) :void (mask :uint32))
(cffi:defcfun ("glBindFramebuffer" %gl-bind-framebuffer) :void
  (target :uint32) (framebuffer :uint32))
(cffi:defcfun ("glCheckFramebufferStatus" %gl-check-framebuffer-status)
    :uint32 (target :uint32))
(cffi:defcfun ("glDrawArrays" %gl-draw-arrays) :void
  (mode :uint32) (first :int) (count :int))
(cffi:defcfun ("glFlush" %gl-flush) :void)
(cffi:defcfun ("glGetError" %gl-get-error) :uint32)

(defparameter +builtin-vertex-shader+
  "attribute vec2 position;
attribute vec2 texcoord;
varying vec2 texture_coordinate;
void main() {
  gl_Position = vec4(position, 0.0, 1.0);
  texture_coordinate = texcoord;
}")

(defparameter +builtin-solid-fragment-shader+
  "precision mediump float;
uniform vec4 color;
void main() { gl_FragColor = color; }")

(defparameter +builtin-texture-fragment-shader+
  "precision mediump float;
varying vec2 texture_coordinate;
uniform sampler2D texture_sampler;
uniform float opacity;
uniform float texture_has_alpha;
void main() {
  vec4 sampled = texture2D(texture_sampler, texture_coordinate);
  float alpha = texture_has_alpha > 0.5 ? sampled.a : 1.0;
  gl_FragColor = vec4(sampled.rgb, alpha) * opacity;
}")

(defparameter +builtin-external-fragment-shader+
  "#extension GL_OES_EGL_image_external :require
precision mediump float;
varying vec2 texture_coordinate;
uniform samplerExternalOES texture_sampler;
uniform float opacity;
uniform float texture_has_alpha;
void main() {
  vec4 sampled = texture2D(texture_sampler, texture_coordinate);
  float alpha = texture_has_alpha > 0.5 ? sampled.a : 1.0;
  gl_FragColor = vec4(sampled.rgb, alpha) * opacity;
}")

(defclass shader-program-descriptor ()
  ((vertex-source :initarg :vertex-source :reader program-vertex-source)
   (fragment-source :initarg :fragment-source :reader program-fragment-source)
   (kind :initarg :kind :initform :texture-2d
         :reader program-descriptor-kind)
   (uniforms :initarg :uniforms :initform nil :reader program-uniform-names)))

(defclass shader-program ()
  ((descriptor :initarg :descriptor :reader shader-program-descriptor)
   (native-program :initarg :native-program :reader shader-native-program)
   (uniforms :initarg :uniforms :reader shader-uniforms)
   (state :initform :live :accessor shader-program-state)))

(defclass direct-gles-renderer (compositor-component)
  ((solid-program :initform nil :accessor renderer-solid-program)
   (texture-program :initform nil :accessor renderer-texture-program)
   (external-program :initform nil :accessor renderer-external-program)
   (programs :initform (make-hash-table :test #'equal)
             :reader renderer-programs)
   (vertex-scratch :initform nil :accessor renderer-vertex-scratch)
   (vertex-scratch-capacity :initform 0
                            :accessor renderer-vertex-scratch-capacity)))

(defgeneric renderer-begin-frame (renderer output frame-context))
(defgeneric renderer-draw-item (renderer frame-context item))
(defgeneric renderer-draw-material (renderer frame-context item material))
(defgeneric renderer-end-frame (renderer frame-context))
(defgeneric renderer-abort-frame (renderer frame-context reason))

(defun gl-status (getter object parameter)
  (cffi:with-foreign-object (value :int)
    (funcall getter object parameter value)
    (cffi:mem-ref value :int)))

(defun shader-log (shader)
  (let ((length (gl-status #'%gl-get-shader-iv shader +gl-info-log-length+)))
    (if (<= length 1)
        "unknown shader compilation failure"
        (cffi:with-foreign-pointer (buffer length)
          (%gl-get-shader-info-log shader length (cffi:null-pointer) buffer)
          (cffi:foreign-string-to-lisp buffer)))))

(defun program-log (program)
  (let ((length (gl-status #'%gl-get-program-iv program +gl-info-log-length+)))
    (if (<= length 1)
        "unknown program link failure"
        (cffi:with-foreign-pointer (buffer length)
          (%gl-get-program-info-log program length (cffi:null-pointer) buffer)
          (cffi:foreign-string-to-lisp buffer)))))

(defun compile-shader-stage (shader-type source)
  (let ((shader (%gl-create-shader shader-type)))
    (when (zerop shader)
      (error 'graphics-failure :operation :create-shader))
    (handler-case
        (progn
          (cffi:with-foreign-string (source-pointer source)
            (cffi:with-foreign-object (source-cell :pointer)
              (setf (cffi:mem-ref source-cell :pointer) source-pointer)
              (%gl-shader-source shader 1 source-cell (cffi:null-pointer))))
          (%gl-compile-shader shader)
          (unless (= 1 (gl-status #'%gl-get-shader-iv
                                  shader +gl-compile-status+))
            (error 'graphics-failure
                   :operation :compile-shader :detail (shader-log shader)))
          shader)
      (serious-condition (condition)
        (%gl-delete-shader shader)
        (error condition)))))

(defun shader-interface-name (name)
  "Translate idiomatic Lisp symbols while preserving explicit GLSL strings."
  (etypecase name
    (symbol
     (substitute #\_ #\-
                 (string-downcase (symbol-name name))))
    (string name)))

(defun compile-shader-program (descriptor)
  (check-type descriptor shader-program-descriptor)
  (let ((vertex 0) (fragment 0) (program 0))
    (unwind-protect
         (progn
           (setf vertex
                 (compile-shader-stage
                  +gl-vertex-shader+ (program-vertex-source descriptor))
                 fragment
                 (compile-shader-stage
                  +gl-fragment-shader+ (program-fragment-source descriptor))
                 program (%gl-create-program))
           (when (zerop program)
             (error 'graphics-failure :operation :create-program))
           (%gl-attach-shader program vertex)
           (%gl-attach-shader program fragment)
           (%gl-bind-attrib-location program 0 "position")
           (%gl-bind-attrib-location program 1 "texcoord")
           (%gl-link-program program)
           (unless (= 1 (gl-status #'%gl-get-program-iv
                                   program +gl-link-status+))
             (error 'graphics-failure
                    :operation :link-program :detail (program-log program)))
           (let ((uniforms (make-hash-table :test #'equal)))
             (dolist (name (program-uniform-names descriptor))
               (setf (gethash (shader-interface-name name) uniforms)
                     (%gl-get-uniform-location
                      program (shader-interface-name name))))
             (prog1
                 (make-instance 'shader-program
                                :descriptor descriptor
                                :native-program program :uniforms uniforms)
               (setf program 0))))
      (when (plusp vertex) (%gl-delete-shader vertex))
      (when (plusp fragment) (%gl-delete-shader fragment))
      (when (plusp program) (%gl-delete-program program)))))

(defun delete-shader-program (program)
  (when (and program (eq :live (shader-program-state program)))
    (%gl-delete-program (shader-native-program program))
    (setf (shader-program-state program) :retired))
  nil)

(defun builtin-program-descriptor (fragment uniforms kind)
  (make-instance 'shader-program-descriptor
                 :vertex-source +builtin-vertex-shader+
                 :fragment-source fragment :uniforms uniforms :kind kind))

(defun make-material-program-descriptor
    (fragment-source uniforms &key (vertex-source +builtin-vertex-shader+))
  "Describe an untextured GLES material without assigning it visual meaning."
  (make-instance 'shader-program-descriptor
                 :vertex-source vertex-source
                 :fragment-source fragment-source
                 :uniforms uniforms
                 :kind :material))

(defun make-texture-program-descriptor
    (fragment-source uniforms kind
     &key (vertex-source +builtin-vertex-shader+))
  "Describe one target-specific variant of a logical texture program."
  (unless (member kind '(:texture-2d :texture-external) :test #'eq)
    (error 'graphics-failure
           :operation :describe-texture-program
           :detail (format nil "unsupported texture kind ~A" kind)))
  (make-instance 'shader-program-descriptor
                 :vertex-source vertex-source
                 :fragment-source fragment-source
                 :uniforms uniforms
                 :kind kind))

(defmethod attach-component :after ((renderer direct-gles-renderer))
  (let* ((compositor (component-compositor renderer))
         (runtime (compositor-runtime compositor)))
    (ataxia.runtime:with-egl-context ((ataxia.runtime:runtime-egl runtime))
      (setf (renderer-vertex-scratch renderer)
            (cffi:foreign-alloc :float :count 4096)
            (renderer-vertex-scratch-capacity renderer) 4096
            (renderer-solid-program renderer)
            (compile-shader-program
             (builtin-program-descriptor
              +builtin-solid-fragment-shader+ '(color) :solid))
            (renderer-texture-program renderer)
            (compile-shader-program
             (builtin-program-descriptor
              +builtin-texture-fragment-shader+
              '(texture-sampler opacity texture-has-alpha) :texture-2d))
            (renderer-external-program renderer)
            (compile-shader-program
             (builtin-program-descriptor
              +builtin-external-fragment-shader+
              '(texture-sampler opacity texture-has-alpha)
              :texture-external))))
  renderer))

(defmethod detach-component :before
    ((renderer direct-gles-renderer) reason)
  (declare (ignore reason))
  (let ((runtime (compositor-runtime (component-compositor renderer))))
    (when (and runtime
               (member (ataxia.runtime:runtime-state runtime)
                       '(:ready :running :stopping)))
      (ataxia.runtime:with-egl-context ((ataxia.runtime:runtime-egl runtime))
        (delete-shader-program (renderer-solid-program renderer))
        (delete-shader-program (renderer-texture-program renderer))
        (delete-shader-program (renderer-external-program renderer))
        (maphash (lambda (key program)
                   (declare (ignore key))
                   (delete-shader-program program))
                 (renderer-programs renderer)))))
  (when (renderer-vertex-scratch renderer)
    (cffi:foreign-free (renderer-vertex-scratch renderer))
    (setf (renderer-vertex-scratch renderer) nil
          (renderer-vertex-scratch-capacity renderer) 0)))

(defun shader-program-key (name kind)
  (list name kind))

(defun registered-shader-program (renderer name kind)
  (gethash (shader-program-key name kind) (renderer-programs renderer)))

(defun replace-shader-program (renderer name descriptor)
  (assert-compositor-owner
   (component-compositor renderer) :replace-shader-program)
  (check-type name (or symbol string))
  (let ((runtime (compositor-runtime (component-compositor renderer))))
    (ataxia.runtime:with-egl-context ((ataxia.runtime:runtime-egl runtime))
      (let* ((kind (program-descriptor-kind descriptor))
             (key (shader-program-key name kind))
             (candidate (compile-shader-program descriptor))
             (previous (gethash key (renderer-programs renderer))))
        (handler-case
            (progn
              (unless (member kind
                              '(:material :texture-2d :texture-external)
                              :test #'eq)
                (error 'graphics-failure
                       :operation :replace-shader
                       :detail "unsupported shader program kind"))
              (when (and (member kind '(:texture-2d :texture-external)
                                 :test #'eq)
                         (or (minusp
                              (uniform-location candidate 'texture-sampler))
                             (minusp (uniform-location candidate 'opacity))))
                (error 'graphics-failure
                       :operation :replace-shader
                       :detail "texture_sampler and opacity are required"))
              (setf (gethash key (renderer-programs renderer)) candidate)
              (delete-shader-program previous)
              (schedule-presentation
               (compositor-presentation (component-compositor renderer)))
              candidate)
          (serious-condition (condition)
            (delete-shader-program candidate)
            (error condition)))))))

(defun shader-program-installed-p (renderer name &optional kind)
  (labels ((live-kind-p (candidate-kind)
             (let ((program
                     (registered-shader-program
                      renderer name candidate-kind)))
               (and program (eq (shader-program-state program) :live)))))
    (if kind
        (live-kind-p kind)
        (some #'live-kind-p
              '(:material :texture-2d :texture-external)))))

(defun uniform-location (program name)
  (or (gethash (shader-interface-name name) (shader-uniforms program)) -1))

(defun shader-program-for-texture (renderer name target)
  (let* ((kind (if (= target +gl-texture-2d+)
                   :texture-2d
                   :texture-external))
         (candidate
           (and name (registered-shader-program renderer name kind))))
    (if candidate
        candidate
        (if (= target +gl-texture-2d+)
            (renderer-texture-program renderer)
            (renderer-external-program renderer)))))

(defun shader-program-for-material (renderer name)
  (let ((program
          (and name
               (registered-shader-program renderer name :material))))
    (unless program
      (error 'graphics-failure
             :operation :draw-material
             :detail (format nil "unknown material program ~A" name)))
    program))

(defun shader-uniform-value-p (value)
  (or (integerp value)
      (realp value)
      (and (typep value 'sequence)
           (not (stringp value))
           (<= 2 (length value) 4)
           (every #'realp value))))

(defun set-view-shader-program (renderer view name)
  (assert-compositor-owner
   (component-compositor renderer) :set-view-shader-program)
  (check-type view view)
  (when name
    (check-type name (or symbol string))
    (unless (or (shader-program-installed-p renderer name :texture-2d)
                (shader-program-installed-p renderer name :texture-external))
      (error 'graphics-failure
             :operation :set-view-shader-program
             :detail (format nil "unknown texture program ~A" name))))
  (setf (view-shader-program-name view) name)
  (schedule-presentation
   (compositor-presentation (component-compositor renderer)))
  view)

(defun set-view-shader-uniform (renderer view name value)
  (assert-compositor-owner
   (component-compositor renderer) :set-view-shader-uniform)
  (check-type view view)
  (check-type name (or symbol string))
  (unless (shader-uniform-value-p value)
    (error 'graphics-failure
           :operation :set-view-shader-uniform
           :detail (format nil "unsupported value for ~A" name)))
  (setf (gethash name
                 (presentation-shader-uniforms
                  (view-presentation-state view)))
        value)
  (schedule-presentation
   (compositor-presentation (component-compositor renderer)))
  view)

(defun apply-shader-uniform (program name value)
  "Set scalar or two-to-four component values supported by the shell API."
  (let ((location (uniform-location program name)))
    (unless (minusp location)
      (cond
        ((integerp value) (%gl-uniform-1i location value))
        ((realp value)
         (%gl-uniform-1f location (coerce value 'single-float)))
        (t
         (let ((values (coerce value 'list)))
           (ecase (length values)
             (2 (%gl-uniform-2f
                 location
                 (coerce (first values) 'single-float)
                 (coerce (second values) 'single-float)))
             (3 (%gl-uniform-3f
                 location
                 (coerce (first values) 'single-float)
                 (coerce (second values) 'single-float)
                 (coerce (third values) 'single-float)))
             (4 (%gl-uniform-4f
                 location
                 (coerce (first values) 'single-float)
                 (coerce (second values) 'single-float)
                 (coerce (third values) 'single-float)
                 (coerce (fourth values) 'single-float))))))))))

(defun put-vertex (scratch index x y texture-x texture-y)
  (let ((offset (* index 4)))
    (setf (cffi:mem-aref scratch :float offset) (coerce x 'single-float)
          (cffi:mem-aref scratch :float (+ offset 1)) (coerce y 'single-float)
          (cffi:mem-aref scratch :float (+ offset 2))
          (coerce texture-x 'single-float)
          (cffi:mem-aref scratch :float (+ offset 3))
          (coerce texture-y 'single-float))))

(defun ensure-vertex-scratch-capacity (renderer float-count)
  (when (> float-count (renderer-vertex-scratch-capacity renderer))
    (let ((capacity (max float-count
                         (* 2 (renderer-vertex-scratch-capacity renderer)))))
      (cffi:foreign-free (renderer-vertex-scratch renderer))
      (setf (renderer-vertex-scratch renderer)
            (cffi:foreign-alloc :float :count capacity)
            (renderer-vertex-scratch-capacity renderer) capacity)))
  (renderer-vertex-scratch renderer))

(defun fill-rectangle-vertices
    (renderer output-width output-height x y width height)
  (let* ((left (- (* 2d0 (/ x output-width)) 1d0))
         (right (- (* 2d0 (/ (+ x width) output-width)) 1d0))
         ;; wlroots exposes an FBO whose scanout orientation is inverted from
         ;; the conventional GLES viewport. Keep compositor coordinates
         ;; top-left based and invert once, here, for every draw path.
         (top (- (* 2d0 (/ y output-height)) 1d0))
         (bottom (- (* 2d0 (/ (+ y height) output-height)) 1d0))
         (scratch (renderer-vertex-scratch renderer)))
    (put-vertex scratch 0 left top 0d0 0d0)
    (put-vertex scratch 1 right top 1d0 0d0)
    (put-vertex scratch 2 right bottom 1d0 1d0)
    (put-vertex scratch 3 left top 0d0 0d0)
    (put-vertex scratch 4 right bottom 1d0 1d0)
    (put-vertex scratch 5 left bottom 0d0 1d0)
    scratch))

(defun fill-mesh-vertices
    (renderer output-width output-height geometry)
  (let* ((vertices (mesh-geometry-vertices geometry))
         (vertex-count (mesh-geometry-vertex-count geometry))
         (scratch
           (ensure-vertex-scratch-capacity renderer (* vertex-count 4))))
    (loop for vertex-index from 0 below vertex-count
          for offset = (* vertex-index 4)
          for x = (aref vertices offset)
          for y = (aref vertices (+ offset 1))
          do (put-vertex
              scratch vertex-index
              (- (* 2d0 (/ x output-width)) 1d0)
              (- (* 2d0 (/ y output-height)) 1d0)
              (aref vertices (+ offset 2))
              (aref vertices (+ offset 3))))
    scratch))

(defun fill-item-vertices
    (renderer output-width output-height x y width height geometry)
  (if (typep geometry 'mesh-geometry)
      (progn
        (fill-mesh-vertices renderer output-width output-height geometry)
        (mesh-geometry-vertex-count geometry))
      (progn
        (fill-rectangle-vertices
         renderer output-width output-height x y width height)
        6)))

(defun bind-rectangle-vertices (renderer)
  (let ((scratch (renderer-vertex-scratch renderer)))
    (%gl-enable-vertex-attrib-array 0)
    (%gl-enable-vertex-attrib-array 1)
    (%gl-vertex-attrib-pointer 0 2 +gl-float+ +gl-false+ 16 scratch)
    (%gl-vertex-attrib-pointer
     1 2 +gl-float+ +gl-false+ 16 (cffi:inc-pointer scratch 8))))

(defun draw-solid-rectangle
    (renderer output-width output-height x y width height color
     &optional geometry)
  (let ((program (renderer-solid-program renderer))
        (vertex-count
          (fill-item-vertices
           renderer output-width output-height x y width height geometry)))
    (%gl-use-program (shader-native-program program))
    (bind-rectangle-vertices renderer)
    (destructuring-bind (red green blue alpha) color
      (%gl-uniform-4f
       (uniform-location program 'color)
       (coerce red 'single-float) (coerce green 'single-float)
       (coerce blue 'single-float) (coerce alpha 'single-float)))
    (%gl-draw-arrays +gl-triangles+ 0 vertex-count)))

(defun draw-shader-material
    (renderer output-width output-height x y width height program-name
     uniform-values &optional geometry)
  "Execute a policy-provided untextured material over a quad or mesh."
  (let ((program (shader-program-for-material renderer program-name))
        (vertex-count
          (fill-item-vertices
           renderer output-width output-height x y width height geometry)))
    (%gl-use-program (shader-native-program program))
    (bind-rectangle-vertices renderer)
    (dolist (uniform uniform-values)
      (apply-shader-uniform program (car uniform) (cdr uniform)))
    (%gl-draw-arrays +gl-triangles+ 0 vertex-count)))

(defun draw-textured-rectangle
    (renderer output-width output-height x y width height attributes opacity
     program-name uniform-values &optional geometry)
  (let* ((target (ataxia.runtime:gles-texture-target attributes))
         (program (shader-program-for-texture renderer program-name target))
         (vertex-count
           (fill-item-vertices
            renderer output-width output-height x y width height geometry)))
    (%gl-use-program (shader-native-program program))
    (bind-rectangle-vertices renderer)
    (%gl-active-texture +gl-texture0+)
    (%gl-bind-texture target (ataxia.runtime:gles-texture-name attributes))
    ;; wlroots defers filter selection until its own render pass. Direct GLES
    ;; sampling must provide it or the imported non-mipmapped texture is black.
    (%gl-tex-parameter-i target +gl-texture-min-filter+ +gl-linear+)
    (%gl-tex-parameter-i target +gl-texture-mag-filter+ +gl-linear+)
    (dolist (uniform uniform-values)
      (apply-shader-uniform program (car uniform) (cdr uniform)))
    (%gl-uniform-1i (uniform-location program 'texture-sampler) 0)
    (%gl-uniform-1f
     (uniform-location program 'opacity) (coerce opacity 'single-float))
    (%gl-uniform-1f
     (uniform-location program 'texture-has-alpha)
     (if (ataxia.runtime:gles-texture-has-alpha-p attributes) 1.0 0.0))
    (%gl-draw-arrays +gl-triangles+ 0 vertex-count)
    (%gl-bind-texture target 0)))

(defmethod renderer-begin-frame
    ((renderer direct-gles-renderer) output frame-context)
  (declare (ignore output))
  (%gl-bind-framebuffer +gl-framebuffer+ (frame-context-framebuffer frame-context))
  (unless (= +gl-framebuffer-complete+
             (%gl-check-framebuffer-status +gl-framebuffer+))
    (error 'graphics-failure :operation :framebuffer-incomplete))
  (%gl-viewport 0 0
                (frame-context-width frame-context)
                (frame-context-height frame-context))
  (destructuring-bind (red green blue alpha) +renderer-clear-color+
    (%gl-clear-color
     (coerce red 'single-float) (coerce green 'single-float)
     (coerce blue 'single-float) (coerce alpha 'single-float)))
  (%gl-clear +gl-color-buffer-bit+)
  (%gl-enable +gl-blend+)
  (%gl-blend-func +gl-one+ +gl-one-minus-src-alpha+)
  frame-context)

(defmethod renderer-end-frame
    ((renderer direct-gles-renderer) frame-context)
  (declare (ignore renderer))
  (%gl-disable-vertex-attrib-array 0)
  (%gl-disable-vertex-attrib-array 1)
  (%gl-bind-framebuffer +gl-framebuffer+ 0)
  (%gl-flush)
  (let ((error (%gl-get-error)))
    (unless (= error +gl-no-error+)
      (error 'graphics-failure
             :operation :draw-frame :detail (format nil "GL error 0x~X" error))))
  frame-context)

(defmethod renderer-abort-frame
    ((renderer direct-gles-renderer) frame-context reason)
  (declare (ignore renderer frame-context reason))
  (%gl-bind-framebuffer +gl-framebuffer+ 0)
  nil)
