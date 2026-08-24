;;;; Direct GLES renderer for the fullscreen World.
;;;;
;;;; Kernel activates the output framebuffer before calling World. This module
;;;; owns shader state and samples the opaque GLES texture handles exposed by
;;;; DRAWABLE-SURFACE records.

(in-package #:ataxia.fullscreen-world)

(cffi:defcfun ("glActiveTexture" %gl-active-texture) :void
  (texture :uint32))
(cffi:defcfun ("glAttachShader" %gl-attach-shader) :void
  (program :uint32) (shader :uint32))
(cffi:defcfun ("glBindAttribLocation" %gl-bind-attrib-location) :void
  (program :uint32) (index :uint32) (name :string))
(cffi:defcfun ("glBindBuffer" %gl-bind-buffer) :void
  (target :uint32) (buffer :uint32))
(cffi:defcfun ("glBindTexture" %gl-bind-texture) :void
  (target :uint32) (texture :uint32))
(cffi:defcfun ("glBlendEquationSeparate" %gl-blend-equation-separate) :void
  (rgb :uint32) (alpha :uint32))
(cffi:defcfun ("glBlendFuncSeparate" %gl-blend-func-separate) :void
  (source-rgb :uint32) (destination-rgb :uint32)
  (source-alpha :uint32) (destination-alpha :uint32))
(cffi:defcfun ("glBufferData" %gl-buffer-data) :void
  (target :uint32) (size :intptr) (data :pointer) (usage :uint32))
(cffi:defcfun ("glClear" %gl-clear) :void
  (mask :uint32))
(cffi:defcfun ("glClearColor" %gl-clear-color) :void
  (red :float) (green :float) (blue :float) (alpha :float))
(cffi:defcfun ("glColorMask" %gl-color-mask) :void
  (red :uint8) (green :uint8) (blue :uint8) (alpha :uint8))
(cffi:defcfun ("glCompileShader" %gl-compile-shader) :void
  (shader :uint32))
(cffi:defcfun ("glCreateProgram" %gl-create-program) :uint32)
(cffi:defcfun ("glCreateShader" %gl-create-shader) :uint32
  (type :uint32))
(cffi:defcfun ("glDeleteBuffers" %gl-delete-buffers) :void
  (count :int32) (buffers :pointer))
(cffi:defcfun ("glDeleteProgram" %gl-delete-program) :void
  (program :uint32))
(cffi:defcfun ("glDeleteShader" %gl-delete-shader) :void
  (shader :uint32))
(cffi:defcfun ("glDisable" %gl-disable) :void
  (capability :uint32))
(cffi:defcfun ("glDrawArrays" %gl-draw-arrays) :void
  (mode :uint32) (first :int32) (count :int32))
(cffi:defcfun ("glEnable" %gl-enable) :void
  (capability :uint32))
(cffi:defcfun ("glEnableVertexAttribArray" %gl-enable-vertex-attrib-array)
    :void
  (index :uint32))
(cffi:defcfun ("glFlush" %gl-flush) :void)
(cffi:defcfun ("glGenBuffers" %gl-gen-buffers) :void
  (count :int32) (buffers :pointer))
(cffi:defcfun ("glGetError" %gl-get-error) :uint32)
(cffi:defcfun ("glGetProgramInfoLog" %gl-get-program-info-log) :void
  (program :uint32) (capacity :int32) (length :pointer) (log :pointer))
(cffi:defcfun ("glGetProgramiv" %gl-get-program-iv) :void
  (program :uint32) (name :uint32) (value :pointer))
(cffi:defcfun ("glGetShaderInfoLog" %gl-get-shader-info-log) :void
  (shader :uint32) (capacity :int32) (length :pointer) (log :pointer))
(cffi:defcfun ("glGetShaderiv" %gl-get-shader-iv) :void
  (shader :uint32) (name :uint32) (value :pointer))
(cffi:defcfun ("glGetString" %gl-get-string) :pointer
  (name :uint32))
(cffi:defcfun ("glGetTexParameteriv" %gl-get-tex-parameter-iv) :void
  (target :uint32) (name :uint32) (value :pointer))
(cffi:defcfun ("glGetUniformLocation" %gl-get-uniform-location) :int32
  (program :uint32) (name :string))
(cffi:defcfun ("glLinkProgram" %gl-link-program) :void
  (program :uint32))
(cffi:defcfun ("glShaderSource" %gl-shader-source) :void
  (shader :uint32) (count :int32) (strings :pointer) (lengths :pointer))
(cffi:defcfun ("glTexParameteri" %gl-tex-parameter-i) :void
  (target :uint32) (name :uint32) (value :int32))
(cffi:defcfun ("glUniform1f" %gl-uniform-1f) :void
  (location :int32) (value :float))
(cffi:defcfun ("glUniform1i" %gl-uniform-1i) :void
  (location :int32) (value :int32))
(cffi:defcfun ("glUniformMatrix3fv" %gl-uniform-matrix-3fv) :void
  (location :int32) (count :int32) (transpose :uint8) (value :pointer))
(cffi:defcfun ("glUseProgram" %gl-use-program) :void
  (program :uint32))
(cffi:defcfun ("glVertexAttribPointer" %gl-vertex-attrib-pointer) :void
  (index :uint32) (size :int32) (type :uint32) (normalized :uint8)
  (stride :int32) (pointer :pointer))

(defconstant +gl-array-buffer+ #x8892)
(defconstant +gl-blend+ #x0be2)
(defconstant +gl-color-buffer-bit+ #x00004000)
(defconstant +gl-compile-status+ #x8b81)
(defconstant +gl-cull-face+ #x0b44)
(defconstant +gl-depth-test+ #x0b71)
(defconstant +gl-dynamic-draw+ #x88e8)
(defconstant +gl-extensions+ #x1f03)
(defconstant +gl-false+ 0)
(defconstant +gl-float+ #x1406)
(defconstant +gl-fragment-shader+ #x8b30)
(defconstant +gl-func-add+ #x8006)
(defconstant +gl-info-log-length+ #x8b84)
(defconstant +gl-link-status+ #x8b82)
(defconstant +gl-linear+ #x2601)
(defconstant +gl-no-error+ 0)
(defconstant +gl-one+ 1)
(defconstant +gl-one-minus-src-alpha+ #x0303)
(defconstant +gl-scissor-test+ #x0c11)
(defconstant +gl-stencil-test+ #x0b90)
(defconstant +gl-texture0+ #x84c0)
(defconstant +gl-texture-2d+ #x0de1)
(defconstant +gl-texture-external-oes+ #x8d65)
(defconstant +gl-texture-mag-filter+ #x2800)
(defconstant +gl-texture-min-filter+ #x2801)
(defconstant +gl-triangles+ #x0004)
(defconstant +gl-true+ 1)
(defconstant +gl-vertex-shader+ #x8b31)

(defparameter +texture-vertex-source+
  "attribute vec2 a_position;
uniform mat3 u_position_matrix;
uniform mat3 u_texture_matrix;
varying vec2 v_texture;
void main() {
  vec3 point = vec3(a_position, 1.0);
  gl_Position = vec4(u_position_matrix * point, 1.0);
  v_texture = (u_texture_matrix * point).xy;
}")

(defparameter +texture-fragment-source+
  "#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform sampler2D u_texture;
uniform float u_has_alpha;
varying vec2 v_texture;
void main() {
  vec4 sample_value = texture2D(u_texture, v_texture);
  sample_value.a = mix(1.0, sample_value.a, u_has_alpha);
  gl_FragColor = sample_value;
}")

(defparameter +external-texture-fragment-source+
  "#extension GL_OES_EGL_image_external : require
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform samplerExternalOES u_texture;
uniform float u_has_alpha;
varying vec2 v_texture;
void main() {
  vec4 sample_value = texture2D(u_texture, v_texture);
  sample_value.a = mix(1.0, sample_value.a, u_has_alpha);
  gl_FragColor = sample_value;
}")

(defstruct %shader-program
  (handle 0 :type (unsigned-byte 32))
  (position-matrix -1 :type integer)
  (texture-matrix -1 :type integer)
  (texture -1 :type integer)
  (has-alpha -1 :type integer))

(defstruct (%fullscreen-renderer (:constructor %make-fullscreen-renderer))
  texture-program
  external-texture-program
  (vertex-buffer 0 :type (unsigned-byte 32)))

(defstruct (%affine (:constructor %make-affine
                         (&key (xx 1d0) (yx 0d0) (xy 0d0)
                               (yy 1d0) (x0 0d0) (y0 0d0))))
  (xx 1d0 :type real)
  (yx 0d0 :type real)
  (xy 0d0 :type real)
  (yy 1d0 :type real)
  (x0 0d0 :type real)
  (y0 0d0 :type real))

(defun %gl-object-log (object status-function log-function)
  (cffi:with-foreign-object (length :int32)
    (funcall status-function object +gl-info-log-length+ length)
    (let ((capacity (max 1 (cffi:mem-ref length :int32))))
      (cffi:with-foreign-objects ((log :char capacity) (written :int32))
        (funcall log-function object capacity written log)
        (cffi:foreign-string-to-lisp
         log :count (max 0 (cffi:mem-ref written :int32)))))))

(defun %compile-shader (type source label)
  (let ((shader (%gl-create-shader type)))
    (when (zerop shader)
      (error "~A: glCreateShader returned zero." label))
    (handler-case
        (progn
          (cffi:with-foreign-string (source-pointer source)
            (cffi:with-foreign-object (sources :pointer)
              (setf (cffi:mem-ref sources :pointer) source-pointer)
              (%gl-shader-source
               shader 1 sources (cffi:null-pointer))))
          (%gl-compile-shader shader)
          (cffi:with-foreign-object (status :int32)
            (%gl-get-shader-iv shader +gl-compile-status+ status)
            (when (zerop (cffi:mem-ref status :int32))
              (error "~A: ~A" label
                     (%gl-object-log
                      shader #'%gl-get-shader-iv #'%gl-get-shader-info-log))))
          shader)
      (serious-condition (cause)
        (%gl-delete-shader shader)
        (error cause)))))

(defun %uniform-location (program name)
  (let ((location (%gl-get-uniform-location program name)))
    (when (= location -1)
      (error "Shader uniform ~A is unavailable." name))
    location))

(defun %link-texture-program (fragment-source label)
  (let ((vertex 0)
        (fragment 0)
        (program 0))
    (handler-case
        (progn
          (setf vertex
                (%compile-shader
                 +gl-vertex-shader+ +texture-vertex-source+ label)
                fragment
                (%compile-shader +gl-fragment-shader+ fragment-source label)
                program (%gl-create-program))
          (when (zerop program)
            (error "~A: glCreateProgram returned zero." label))
          (%gl-attach-shader program vertex)
          (%gl-attach-shader program fragment)
          (%gl-bind-attrib-location program 0 "a_position")
          (%gl-link-program program)
          (cffi:with-foreign-object (status :int32)
            (%gl-get-program-iv program +gl-link-status+ status)
            (when (zerop (cffi:mem-ref status :int32))
              (error "~A: ~A" label
                     (%gl-object-log
                      program #'%gl-get-program-iv
                      #'%gl-get-program-info-log))))
          (prog1
              (make-%shader-program
               :handle program
               :position-matrix (%uniform-location program "u_position_matrix")
               :texture-matrix (%uniform-location program "u_texture_matrix")
               :texture (%uniform-location program "u_texture")
               :has-alpha (%uniform-location program "u_has_alpha"))
            (%gl-delete-shader vertex)
            (%gl-delete-shader fragment)
            (setf vertex 0 fragment 0 program 0)))
      (serious-condition (cause)
        (when (plusp program) (%gl-delete-program program))
        (when (plusp vertex) (%gl-delete-shader vertex))
        (when (plusp fragment) (%gl-delete-shader fragment))
        (error cause)))))

(defun %gl-extensions ()
  (let ((pointer (%gl-get-string +gl-extensions+)))
    (unless (cffi:null-pointer-p pointer)
      (cffi:foreign-string-to-lisp pointer))))

(defun %check-gl (operation)
  (let ((code (%gl-get-error)))
    (unless (= code +gl-no-error+)
      (error "~A failed with GLES error 0x~X." operation code))))

(defun %make-renderer ()
  (let ((renderer (%make-fullscreen-renderer)))
    (handler-case
        (progn
          (setf (%fullscreen-renderer-texture-program renderer)
                (%link-texture-program
                 +texture-fragment-source+ "fullscreen texture shader"))
          (when (search "GL_OES_EGL_image_external" (or (%gl-extensions) ""))
            (setf (%fullscreen-renderer-external-texture-program renderer)
                  (%link-texture-program
                   +external-texture-fragment-source+
                   "fullscreen external texture shader")))
          (cffi:with-foreign-object (buffer :uint32)
            (%gl-gen-buffers 1 buffer)
            (setf (%fullscreen-renderer-vertex-buffer renderer)
                  (cffi:mem-ref buffer :uint32)))
          (when (zerop (%fullscreen-renderer-vertex-buffer renderer))
            (error "glGenBuffers returned zero."))
          (let ((vertices '(0f0 0f0 1f0 0f0 0f0 1f0
                            1f0 0f0 1f0 1f0 0f0 1f0)))
            (cffi:with-foreign-object (data :float (length vertices))
              (loop for value in vertices
                    for index from 0
                    do (setf (cffi:mem-aref data :float index) value))
              (%gl-bind-buffer
               +gl-array-buffer+
               (%fullscreen-renderer-vertex-buffer renderer))
              (%gl-buffer-data
               +gl-array-buffer+
               (* (length vertices) (cffi:foreign-type-size :float))
               data +gl-dynamic-draw+)))
          (%check-gl "fullscreen renderer creation")
          renderer)
      (serious-condition (cause)
        (ignore-errors (%destroy-renderer renderer))
        (error cause)))))

(defun %delete-shader-program (program)
  (when (and program (plusp (%shader-program-handle program)))
    (%gl-delete-program (%shader-program-handle program))
    (setf (%shader-program-handle program) 0)))

(defun %destroy-renderer (renderer)
  (when renderer
    (%delete-shader-program (%fullscreen-renderer-texture-program renderer))
    (%delete-shader-program
     (%fullscreen-renderer-external-texture-program renderer))
    (when (plusp (%fullscreen-renderer-vertex-buffer renderer))
      (cffi:with-foreign-object (buffer :uint32)
        (setf (cffi:mem-ref buffer :uint32)
              (%fullscreen-renderer-vertex-buffer renderer))
        (%gl-delete-buffers 1 buffer))
      (setf (%fullscreen-renderer-vertex-buffer renderer) 0)))
  nil)

(defun %texture-affine (surface)
  (let ((coordinates
          (ataxia.kernel:drawable-surface-texture-coordinates surface)))
    (%make-affine
     :xx (- (aref coordinates 2) (aref coordinates 0))
     :yx (- (aref coordinates 3) (aref coordinates 1))
     :xy (- (aref coordinates 4) (aref coordinates 0))
     :yy (- (aref coordinates 5) (aref coordinates 1))
     :x0 (aref coordinates 0)
     :y0 (aref coordinates 1))))

(defun %affine-matrix (transform)
  (vector
   (%affine-xx transform) (%affine-yx transform) 0d0
   (%affine-xy transform) (%affine-yy transform) 0d0
   (%affine-x0 transform) (%affine-y0 transform) 1d0))

(defun %position-matrix (x y width height target-width target-height)
  (vector
   (/ (* 2d0 width) target-width) 0d0 0d0
   0d0 (/ (* 2d0 height) target-height) 0d0
   (- (/ (* 2d0 x) target-width) 1d0)
   (- (/ (* 2d0 y) target-height) 1d0)
   1d0))

(defun %put-matrix (location matrix)
  (cffi:with-foreign-object (data :float 9)
    (loop for value across matrix
          for index from 0
          do (setf (cffi:mem-aref data :float index)
                   (coerce value 'single-float)))
    (%gl-uniform-matrix-3fv location 1 +gl-false+ data)))

(defun %begin-output-render (renderer)
  (%gl-disable +gl-scissor-test+)
  (%gl-disable +gl-depth-test+)
  (%gl-disable +gl-stencil-test+)
  (%gl-disable +gl-cull-face+)
  (%gl-color-mask +gl-true+ +gl-true+ +gl-true+ +gl-true+)
  (%gl-clear-color 0.015f0 0.018f0 0.025f0 1f0)
  (%gl-clear +gl-color-buffer-bit+)
  (%gl-enable +gl-blend+)
  (%gl-blend-equation-separate +gl-func-add+ +gl-func-add+)
  (%gl-blend-func-separate
   +gl-one+ +gl-one-minus-src-alpha+
   +gl-one+ +gl-one-minus-src-alpha+)
  (%gl-bind-buffer
   +gl-array-buffer+ (%fullscreen-renderer-vertex-buffer renderer))
  (%gl-enable-vertex-attrib-array 0)
  (%gl-vertex-attrib-pointer
   0 2 +gl-float+ +gl-false+ 0 (cffi:null-pointer)))

(defun %program-for-surface (renderer surface)
  (let ((target
          (ataxia.kernel:render-source-gles-target
           (ataxia.kernel:drawable-surface-render-source surface))))
    (cond
      ((= target +gl-texture-2d+)
       (%fullscreen-renderer-texture-program renderer))
      ((= target +gl-texture-external-oes+)
       (or (%fullscreen-renderer-external-texture-program renderer)
           (error "External GLES textures are unsupported by this context.")))
      (t
       (error "Unsupported GLES texture target 0x~X." target)))))

(defun %texture-parameter (target name)
  (cffi:with-foreign-object (value :int32)
    (%gl-get-tex-parameter-iv target name value)
    (cffi:mem-ref value :int32)))

(defun %call-with-linear-filter (target function)
  (let ((old-minification
          (%texture-parameter target +gl-texture-min-filter+))
        (old-magnification
          (%texture-parameter target +gl-texture-mag-filter+)))
    (unwind-protect
         (progn
           (%gl-tex-parameter-i
            target +gl-texture-min-filter+ +gl-linear+)
           (%gl-tex-parameter-i
            target +gl-texture-mag-filter+ +gl-linear+)
           (funcall function))
      (%gl-tex-parameter-i
       target +gl-texture-min-filter+ old-minification)
      (%gl-tex-parameter-i
       target +gl-texture-mag-filter+ old-magnification))))

(defun %draw-surface
    (renderer surface x y width height target-width target-height)
  (let* ((source (ataxia.kernel:drawable-surface-render-source surface))
         (program (%program-for-surface renderer surface))
         (target (ataxia.kernel:render-source-gles-target source)))
    (%gl-use-program (%shader-program-handle program))
    (%put-matrix
     (%shader-program-position-matrix program)
     (%position-matrix x y width height target-width target-height))
    (%put-matrix
     (%shader-program-texture-matrix program)
     (%affine-matrix (%texture-affine surface)))
    (%gl-uniform-1i (%shader-program-texture program) 0)
    (%gl-uniform-1f
     (%shader-program-has-alpha program)
     (if (ataxia.kernel:render-source-has-alpha-p source) 1f0 0f0))
    (%gl-active-texture +gl-texture0+)
    (%gl-bind-texture target (ataxia.kernel:render-source-gles-name source))
    (%call-with-linear-filter
     target (lambda () (%gl-draw-arrays +gl-triangles+ 0 6)))))

(defun %finish-output-render ()
  (%check-gl "fullscreen output rendering")
  (%gl-flush))
