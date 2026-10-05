;;;; Offscreen GLES targets owned by the Stage renderer.
;;;;
;;;; Backdrop blur, window capture and uploaded text/image textures need GL
;;;; objects beyond the shared helpers. They are created and destroyed only
;;;; inside Kernel graphics scopes, and every operation that rebinds the
;;;; framebuffer or viewport restores the Kernel's target before returning.

(in-package #:ataxia.stage-world)

(cffi:defcfun ("glGenTextures" %gl-gen-textures) :void (count :int32) (textures :pointer))
(cffi:defcfun ("glDeleteTextures" %gl-delete-textures) :void (count :int32) (textures :pointer))
(cffi:defcfun ("glBindTexture" %gl-bind-texture) :void (target :uint32) (texture :uint32))
(cffi:defcfun ("glActiveTexture" %gl-active-texture) :void (unit :uint32))
(cffi:defcfun ("glTexImage2D" %gl-tex-image-2d) :void
  (target :uint32) (level :int32) (internal-format :int32) (width :int32) (height :int32)
  (border :int32) (format :uint32) (type :uint32) (pixels :pointer))
(cffi:defcfun ("glTexParameteri" %gl-tex-parameter) :void
  (target :uint32) (name :uint32) (value :int32))
(cffi:defcfun ("glCopyTexSubImage2D" %gl-copy-tex-sub-image-2d) :void
  (target :uint32) (level :int32) (x-offset :int32) (y-offset :int32)
  (x :int32) (y :int32) (width :int32) (height :int32))
(cffi:defcfun ("glGenFramebuffers" %gl-gen-framebuffers) :void (count :int32) (framebuffers :pointer))
(cffi:defcfun ("glDeleteFramebuffers" %gl-delete-framebuffers) :void
  (count :int32) (framebuffers :pointer))
(cffi:defcfun ("glBindFramebuffer" %gl-bind-framebuffer) :void (target :uint32) (framebuffer :uint32))
(cffi:defcfun ("glFramebufferTexture2D" %gl-framebuffer-texture-2d) :void
  (target :uint32) (attachment :uint32) (texture-target :uint32) (texture :uint32) (level :int32))
(cffi:defcfun ("glCheckFramebufferStatus" %gl-check-framebuffer-status) :uint32 (target :uint32))
(cffi:defcfun ("glViewport" %gl-viewport) :void (x :int32) (y :int32) (width :int32) (height :int32))
(cffi:defcfun ("glGetIntegerv" %gl-get-integerv) :void (name :uint32) (value :pointer))
(cffi:defcfun ("glPixelStorei" %gl-pixel-store) :void (name :uint32) (value :int32))
(cffi:defcfun ("glReadPixels" %gl-read-pixels) :void
  (x :int32) (y :int32) (width :int32) (height :int32) (format :uint32) (type :uint32)
  (pixels :pointer))

(defconstant +gl-texture-2d+ #x0de1)
(defconstant +gl-texture-0+ #x84c0)
(defconstant +gl-rgba+ #x1908)
;; EXT_texture_format_BGRA8888, which wlroots' GLES2 renderer requires.
(defconstant +gl-bgra+ #x80e1)
(defconstant +gl-unsigned-byte+ #x1401)
(defconstant +gl-texture-min-filter+ #x2801)
(defconstant +gl-texture-mag-filter+ #x2800)
(defconstant +gl-texture-wrap-s+ #x2802)
(defconstant +gl-texture-wrap-t+ #x2803)
(defconstant +gl-linear+ #x2601)
(defconstant +gl-clamp-to-edge+ #x812f)
(defconstant +gl-framebuffer+ #x8d40)
(defconstant +gl-framebuffer-binding+ #x8ca6)
(defconstant +gl-color-attachment-0+ #x8ce0)
(defconstant +gl-framebuffer-complete+ #x8cd5)
(defconstant +gl-viewport+ #x0ba2)
(defconstant +gl-unpack-alignment+ #x0cf5)
(defconstant +gl-pack-alignment+ #x0d05)

(defun gl-create-texture (width height &optional (pixels (cffi:null-pointer)) (format +gl-rgba+))
  "A texture with linear filtering and clamped edges; PIXELS may be NULL."
  (let ((texture (cffi:with-foreign-object (name :uint32)
                   (%gl-gen-textures 1 name)
                   (cffi:mem-ref name :uint32))))
    (when (zerop texture) (error "glGenTextures returned zero."))
    (%gl-bind-texture +gl-texture-2d+ texture)
    (dolist (parameter (list (cons +gl-texture-min-filter+ +gl-linear+)
                             (cons +gl-texture-mag-filter+ +gl-linear+)
                             (cons +gl-texture-wrap-s+ +gl-clamp-to-edge+)
                             (cons +gl-texture-wrap-t+ +gl-clamp-to-edge+)))
      (%gl-tex-parameter +gl-texture-2d+ (car parameter) (cdr parameter)))
    (gl-upload-texture texture width height pixels format)))

(defun gl-upload-texture (texture width height pixels &optional (format +gl-rgba+))
  "Replace TEXTURE's contents with tightly packed 8-bit PIXELS in FORMAT; return TEXTURE."
  (%gl-bind-texture +gl-texture-2d+ texture)
  (%gl-pixel-store +gl-unpack-alignment+ 4)
  ;; GLES requires the internal format to match the pixel format.
  (%gl-tex-image-2d +gl-texture-2d+ 0 format width height 0 format +gl-unsigned-byte+ pixels)
  (%gl-bind-texture +gl-texture-2d+ 0)
  texture)

(defun gl-delete-texture (texture)
  (when (and texture (plusp texture))
    (cffi:with-foreign-object (name :uint32)
      (setf (cffi:mem-ref name :uint32) texture)
      (%gl-delete-textures 1 name)))
  0)

(defstruct (render-target (:constructor %make-render-target (texture framebuffer width height)))
  (texture 0 :type (unsigned-byte 32))
  (framebuffer 0 :type (unsigned-byte 32))
  (width 0 :type fixnum)
  (height 0 :type fixnum))

(defun make-render-target (width height)
  (let ((texture (gl-create-texture width height))
        (framebuffer 0)
        (previous (gl-framebuffer-binding)))
    (handler-case
        (progn
          (setf framebuffer (cffi:with-foreign-object (name :uint32)
                              (%gl-gen-framebuffers 1 name)
                              (cffi:mem-ref name :uint32)))
          (%gl-bind-framebuffer +gl-framebuffer+ framebuffer)
          (%gl-framebuffer-texture-2d +gl-framebuffer+ +gl-color-attachment-0+ +gl-texture-2d+
                                      texture 0)
          (unless (= (%gl-check-framebuffer-status +gl-framebuffer+) +gl-framebuffer-complete+)
            (error "Stage render target ~Dx~D is incomplete." width height))
          (%gl-bind-framebuffer +gl-framebuffer+ previous)
          (%make-render-target texture framebuffer width height))
      (serious-condition (cause)
        (%gl-bind-framebuffer +gl-framebuffer+ previous)
        (destroy-render-target (%make-render-target texture framebuffer width height))
        (error cause)))))

(defun destroy-render-target (target)
  (when target
    (when (plusp (render-target-framebuffer target))
      (cffi:with-foreign-object (name :uint32)
        (setf (cffi:mem-ref name :uint32) (render-target-framebuffer target))
        (%gl-delete-framebuffers 1 name))
      (setf (render-target-framebuffer target) 0))
    (setf (render-target-texture target) (gl-delete-texture (render-target-texture target))))
  nil)

(defun gl-framebuffer-binding ()
  (cffi:with-foreign-object (value :int32)
    (%gl-get-integerv +gl-framebuffer-binding+ value)
    (cffi:mem-ref value :int32)))

(defun call-with-render-target (target function)
  "Draw into TARGET with a matching viewport, then restore the previous framebuffer and viewport."
  (let ((previous (gl-framebuffer-binding)))
    (cffi:with-foreign-object (viewport :int32 4)
      (%gl-get-integerv +gl-viewport+ viewport)
      (unwind-protect
           (progn
             (%gl-bind-framebuffer +gl-framebuffer+ (render-target-framebuffer target))
             (%gl-viewport 0 0 (render-target-width target) (render-target-height target))
             (funcall function))
        (%gl-bind-framebuffer +gl-framebuffer+ previous)
        (%gl-viewport (cffi:mem-aref viewport :int32 0) (cffi:mem-aref viewport :int32 1)
                      (cffi:mem-aref viewport :int32 2) (cffi:mem-aref viewport :int32 3))))))

(defun gl-copy-framebuffer (target x y width height &optional (source-x x) (source-y y))
  "Copy WIDTH x HEIGHT pixels at (SOURCE-X, SOURCE-Y) of the bound framebuffer to (X, Y)
of TARGET's texture."
  (%gl-bind-texture +gl-texture-2d+ (render-target-texture target))
  (%gl-copy-tex-sub-image-2d +gl-texture-2d+ 0 x y source-x source-y width height)
  (%gl-bind-texture +gl-texture-2d+ 0))

(defun call-with-offset-target (target x y buffer-width buffer-height function)
  "Draw into TARGET as into a BUFFER-WIDTH x BUFFER-HEIGHT buffer whose pixel (X, Y)
is TARGET's first, then restore the previous framebuffer and viewport."
  (let ((previous (gl-framebuffer-binding)))
    (cffi:with-foreign-object (viewport :int32 4)
      (%gl-get-integerv +gl-viewport+ viewport)
      (unwind-protect
           (progn
             (%gl-bind-framebuffer +gl-framebuffer+ (render-target-framebuffer target))
             (%gl-viewport (- x) (- y) buffer-width buffer-height)
             (funcall function))
        (%gl-bind-framebuffer +gl-framebuffer+ previous)
        (%gl-viewport (cffi:mem-aref viewport :int32 0) (cffi:mem-aref viewport :int32 1)
                      (cffi:mem-aref viewport :int32 2) (cffi:mem-aref viewport :int32 3))))))

(defun gl-read-pixels (width height pixels)
  "Read the bound framebuffer's WIDTH x HEIGHT RGBA pixels into octet vector PIXELS."
  (cffi:with-foreign-object (alignment :int32)
    (%gl-get-integerv +gl-pack-alignment+ alignment)
    (%gl-pixel-store +gl-pack-alignment+ 1)
    (sb-sys:with-pinned-objects (pixels)
      (%gl-read-pixels 0 0 width height +gl-rgba+ +gl-unsigned-byte+ (sb-sys:vector-sap pixels)))
    (%gl-pixel-store +gl-pack-alignment+ (cffi:mem-ref alignment :int32))))
