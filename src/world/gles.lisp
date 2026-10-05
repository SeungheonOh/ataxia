;;;; Compact GLES resource and shader helpers for World renderers.
;;;;
;;;; Callers remain responsible for using these functions only while Kernel
;;;; has provided a valid graphics scope or frame lease.

(in-package #:ataxia.world.gles)

(cffi:defcfun ("glActiveTexture" %gl-active-texture) :void (texture :uint32))
(cffi:defcfun ("glAttachShader" %gl-attach-shader) :void
  (program :uint32) (shader :uint32))
(cffi:defcfun ("glBindAttribLocation" %gl-bind-attrib-location) :void
  (program :uint32) (index :uint32) (name :string))
(cffi:defcfun ("glBindBuffer" %gl-bind-buffer) :void
  (target :uint32) (buffer :uint32))
(cffi:defcfun ("glBindTexture" %gl-bind-texture) :void
  (target :uint32) (texture :uint32))
(cffi:defcfun ("glBlendEquation" %gl-blend-equation) :void (mode :uint32))
(cffi:defcfun ("glBlendFunc" %gl-blend-func) :void
  (source :uint32) (destination :uint32))
(cffi:defcfun ("glBufferData" %gl-buffer-data) :void
  (target :uint32) (size :intptr) (data :pointer) (usage :uint32))
(cffi:defcfun ("glClear" %gl-clear) :void (mask :uint32))
(cffi:defcfun ("glClearColor" %gl-clear-color) :void
  (red :float) (green :float) (blue :float) (alpha :float))
(cffi:defcfun ("glColorMask" %gl-color-mask) :void
  (red :uint8) (green :uint8) (blue :uint8) (alpha :uint8))
(cffi:defcfun ("glCompileShader" %gl-compile-shader) :void (shader :uint32))
(cffi:defcfun ("glCreateProgram" %gl-create-program) :uint32)
(cffi:defcfun ("glCreateShader" %gl-create-shader) :uint32 (type :uint32))
(cffi:defcfun ("glDeleteBuffers" %gl-delete-buffers) :void
  (count :int32) (buffers :pointer))
(cffi:defcfun ("glDeleteProgram" %gl-delete-program) :void (program :uint32))
(cffi:defcfun ("glDeleteShader" %gl-delete-shader) :void (shader :uint32))
(cffi:defcfun ("glDisable" %gl-disable) :void (capability :uint32))
(cffi:defcfun ("glDisableVertexAttribArray" %gl-disable-vertex-attrib-array)
    :void (index :uint32))
(cffi:defcfun ("glDrawArrays" %gl-draw-arrays) :void
  (mode :uint32) (first :int32) (count :int32))
(cffi:defcfun ("glEnable" %gl-enable) :void (capability :uint32))
(cffi:defcfun ("glEnableVertexAttribArray" %gl-enable-vertex-attrib-array)
    :void (index :uint32))
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
(cffi:defcfun ("glGetTexParameteriv" %gl-get-texture-parameter) :void
  (target :uint32) (name :uint32) (value :pointer))
(cffi:defcfun ("glGetUniformLocation" %gl-get-uniform-location) :int32
  (program :uint32) (name :string))
(cffi:defcfun ("glLinkProgram" %gl-link-program) :void (program :uint32))
(cffi:defcfun ("glScissor" %gl-scissor) :void
  (x :int32) (y :int32) (width :int32) (height :int32))
(cffi:defcfun ("glShaderSource" %gl-shader-source) :void
  (shader :uint32) (count :int32) (strings :pointer) (lengths :pointer))
(cffi:defcfun ("glTexParameteri" %gl-texture-parameter) :void
  (target :uint32) (name :uint32) (value :int32))
(cffi:defcfun ("glUniform1f" %gl-uniform-1f) :void
  (location :int32) (value :float))
(cffi:defcfun ("glUniform1i" %gl-uniform-1i) :void
  (location :int32) (value :int32))
(cffi:defcfun ("glUniform2f" %gl-uniform-2f) :void
  (location :int32) (x :float) (y :float))
(cffi:defcfun ("glUniform4f" %gl-uniform-4f) :void
  (location :int32) (x :float) (y :float) (z :float) (w :float))
(cffi:defcfun ("glUseProgram" %gl-use-program) :void (program :uint32))
(cffi:defcfun ("glVertexAttribPointer" %gl-vertex-attrib-pointer) :void
  (index :uint32) (size :int32) (type :uint32) (normalized :uint8)
  (stride :int32) (pointer :pointer))

(defconstant +array-buffer+ #x8892)
(defconstant +blend+ #x0be2)
(defconstant +color-buffer-bit+ #x00004000)
(defconstant +compile-status+ #x8b81)
(defconstant +cull-face+ #x0b44)
(defconstant +depth-test+ #x0b71)
(defconstant +false+ 0)
(defconstant +float+ #x1406)
(defconstant +fragment-shader+ #x8b30)
(defconstant +func-add+ #x8006)
(defconstant +info-log-length+ #x8b84)
(defconstant +link-status+ #x8b82)
(defconstant +linear+ #x2601)
(defconstant +one+ 1)
(defconstant +one-minus-src-alpha+ #x0303)
(defconstant +scissor-test+ #x0c11)
(defconstant +stencil-test+ #x0b90)
(defconstant +stream-draw+ #x88e0)
(defconstant +texture0+ #x84c0)
(defconstant +texture-external-oes+ #x8d65)
(defconstant +texture-mag-filter+ #x2800)
(defconstant +texture-min-filter+ #x2801)
(defconstant +triangles+ #x0004)
(defconstant +vertex-shader+ #x8b31)

(defstruct (gles-program (:constructor %make-gles-program (handle)))
  (handle 0 :type (unsigned-byte 32))
  (uniforms (make-hash-table :test #'equal)))

(defun %object-log (object status-function log-function)
  (cffi:with-foreign-object (length :int32)
    (funcall status-function object +info-log-length+ length)
    (let ((capacity (max 1 (cffi:mem-ref length :int32))))
      (cffi:with-foreign-objects ((buffer :char capacity) (written :int32))
        (funcall log-function object capacity written buffer)
        (cffi:foreign-string-to-lisp
         buffer :count (max 0 (cffi:mem-ref written :int32)))))))

(defun %compile-shader (kind source)
  (let ((shader (%gl-create-shader kind)))
    (when (zerop shader)
      (error "glCreateShader returned zero."))
    (handler-case
        (progn
          (cffi:with-foreign-string (source-pointer source)
            (cffi:with-foreign-object (sources :pointer)
              (setf (cffi:mem-ref sources :pointer) source-pointer)
              (%gl-shader-source shader 1 sources (cffi:null-pointer))))
          (%gl-compile-shader shader)
          (cffi:with-foreign-object (status :int32)
            (%gl-get-shader-iv shader +compile-status+ status)
            (when (zerop (cffi:mem-ref status :int32))
              (error "Shader compilation failed: ~A"
                     (%object-log shader #'%gl-get-shader-iv
                                  #'%gl-get-shader-info-log))))
          shader)
      (serious-condition (cause)
        (%gl-delete-shader shader)
        (error cause)))))

(defun make-gles-program (vertex-source fragment-source &key attributes)
  (let ((vertex 0) (fragment 0) (program 0))
    (handler-case
        (progn
          (setf vertex (%compile-shader +vertex-shader+ vertex-source)
                fragment (%compile-shader +fragment-shader+ fragment-source)
                program (%gl-create-program))
          (when (zerop program)
            (error "glCreateProgram returned zero."))
          (%gl-attach-shader program vertex)
          (%gl-attach-shader program fragment)
          (dolist (attribute attributes)
            (%gl-bind-attrib-location program (cdr attribute) (car attribute)))
          (%gl-link-program program)
          (cffi:with-foreign-object (status :int32)
            (%gl-get-program-iv program +link-status+ status)
            (when (zerop (cffi:mem-ref status :int32))
              (error "Program link failed: ~A"
                     (%object-log program #'%gl-get-program-iv
                                  #'%gl-get-program-info-log))))
          (%gl-delete-shader vertex)
          (%gl-delete-shader fragment)
          (setf vertex 0 fragment 0)
          (prog1 (%make-gles-program program)
            (setf program 0)))
      (serious-condition (cause)
        (when (plusp program) (%gl-delete-program program))
        (when (plusp vertex) (%gl-delete-shader vertex))
        (when (plusp fragment) (%gl-delete-shader fragment))
        (error cause)))))

(defun destroy-gles-program (program)
  (when (and program (plusp (gles-program-handle program)))
    (%gl-delete-program (gles-program-handle program))
    (setf (gles-program-handle program) 0))
  nil)

(defun gles-use-program (program)
  (%gl-use-program (gles-program-handle program)))

(defun gles-uniform-location (program name)
  (multiple-value-bind (location found-p)
      (gethash name (gles-program-uniforms program))
    (if found-p
        location
        (setf (gethash name (gles-program-uniforms program))
              (%gl-get-uniform-location (gles-program-handle program) name)))))

(defun gles-uniform-1f (program name value)
  (let ((location (gles-uniform-location program name)))
    (unless (= location -1)
      (%gl-uniform-1f location (coerce value 'single-float)))))

(defun gles-uniform-1i (program name value)
  (let ((location (gles-uniform-location program name)))
    (unless (= location -1)
      (%gl-uniform-1i location value))))

(defun gles-uniform-2f (program name x y)
  (let ((location (gles-uniform-location program name)))
    (unless (= location -1)
      (%gl-uniform-2f location
                      (coerce x 'single-float) (coerce y 'single-float)))))

(defun gles-uniform-4f (program name x y z w)
  (let ((location (gles-uniform-location program name)))
    (unless (= location -1)
      (%gl-uniform-4f location
                      (coerce x 'single-float) (coerce y 'single-float)
                      (coerce z 'single-float) (coerce w 'single-float)))))

(defun gles-create-buffer ()
  (cffi:with-foreign-object (buffer :uint32)
    (%gl-gen-buffers 1 buffer)
    (let ((handle (cffi:mem-ref buffer :uint32)))
      (when (zerop handle)
        (error "glGenBuffers returned zero."))
      handle)))

(defun gles-destroy-buffer (buffer)
  (when (plusp buffer)
    (cffi:with-foreign-object (pointer :uint32)
      (setf (cffi:mem-ref pointer :uint32) buffer)
      (%gl-delete-buffers 1 pointer)))
  0)

(defun gles-upload-floats (buffer values)
  (%gl-bind-buffer +array-buffer+ buffer)
  (if (typep values '(simple-array single-float (*)))
      ;; glBufferData copies before returning. Pin packed geometry for the call
      ;; instead of allocating and converting every float on every frame.
      (cffi:with-pointer-to-vector-data (data values)
        (%gl-buffer-data +array-buffer+
                         (* (length values) (cffi:foreign-type-size :float))
                         data +stream-draw+))
      (let ((vector (coerce values 'vector)))
        (cffi:with-foreign-object (data :float (length vector))
          (loop for value across vector
                for index from 0
                do (setf (cffi:mem-aref data :float index)
                         (coerce value 'single-float)))
          (%gl-buffer-data +array-buffer+
                           (* (length vector) (cffi:foreign-type-size :float))
                           data +stream-draw+)))))

(defun gles-enable-attribute (index size stride offset)
  (%gl-enable-vertex-attrib-array index)
  (%gl-vertex-attrib-pointer
   index size +float+ +false+ stride (cffi:make-pointer offset)))

(defun gles-disable-attribute (index)
  (%gl-disable-vertex-attrib-array index))

(defun gles-bind-texture (target name)
  (%gl-active-texture +texture0+)
  (%gl-bind-texture target name))

(defun %texture-parameter (target name)
  (cffi:with-foreign-object (value :int32)
    (%gl-get-texture-parameter target name value)
    (cffi:mem-ref value :int32)))

(defun call-with-gles-linear-filter (target function)
  (let ((old-minimum (%texture-parameter target +texture-min-filter+))
        (old-maximum (%texture-parameter target +texture-mag-filter+)))
    (unwind-protect
         (progn
           (%gl-texture-parameter target +texture-min-filter+ +linear+)
           (%gl-texture-parameter target +texture-mag-filter+ +linear+)
           (funcall function))
      (%gl-texture-parameter target +texture-min-filter+ old-minimum)
      (%gl-texture-parameter target +texture-mag-filter+ old-maximum))))

(defun gles-clear (red green blue alpha)
  (%gl-clear-color
   (coerce red 'single-float) (coerce green 'single-float)
   (coerce blue 'single-float) (coerce alpha 'single-float))
  (%gl-clear +color-buffer-bit+))

(defun gles-set-scissor (x y width height)
  (%gl-scissor x y width height))

(defun gles-set-scissor-enabled (enabled-p)
  (funcall (if enabled-p #'%gl-enable #'%gl-disable) +scissor-test+))

(defun gles-set-blending-enabled (enabled-p)
  (if enabled-p
      (progn
        (%gl-enable +blend+)
        (%gl-blend-equation +func-add+)
        (%gl-blend-func +one+ +one-minus-src-alpha+))
      (%gl-disable +blend+)))

(defun gles-reset-state ()
  (%gl-disable +depth-test+)
  (%gl-disable +cull-face+)
  (%gl-disable +stencil-test+)
  (%gl-color-mask 1 1 1 1)
  (gles-set-scissor-enabled nil)
  (gles-set-blending-enabled t))

(defun gles-draw-triangles (count)
  (%gl-draw-arrays +triangles+ 0 count))

(defun gles-flush ()
  (%gl-flush))

(defun gles-check-error (operation)
  (let ((code (%gl-get-error)))
    (unless (zerop code)
      (error "~A failed with GLES error 0x~X." operation code))))

(cffi:defcfun ("glGetIntegerv" %gl-get-integer) :void
  (name :uint32) (value :pointer))
