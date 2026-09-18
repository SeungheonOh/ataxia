;;;; Direct GLES rendering for World-owned RmlUi components.
;;;;
;;;; RmlUi renders into a texture-backed framebuffer during the active World
;;;; graphics scope. The compositor then samples that texture like any other
;;;; native drawable; no pixels cross the C++/Common Lisp boundary.

(in-package #:ataxia.world.rmlui)

(cffi:defcfun ("glBindFramebuffer" %gl-bind-framebuffer) :void
  (target :uint32) (framebuffer :uint32))
(cffi:defcfun ("glBindTexture" %gl-bind-texture) :void
  (target :uint32) (texture :uint32))
(cffi:defcfun ("glCheckFramebufferStatus" %gl-check-framebuffer-status) :uint32
  (target :uint32))
(cffi:defcfun ("glDeleteFramebuffers" %gl-delete-framebuffers) :void
  (count :int32) (framebuffers :pointer))
(cffi:defcfun ("glDeleteRenderbuffers" %gl-delete-renderbuffers) :void
  (count :int32) (renderbuffers :pointer))
(cffi:defcfun ("glDeleteTextures" %gl-delete-textures) :void
  (count :int32) (textures :pointer))
(cffi:defcfun ("glFramebufferTexture2D" %gl-framebuffer-texture) :void
  (target :uint32) (attachment :uint32) (texture-target :uint32)
  (texture :uint32) (level :int32))
(cffi:defcfun ("glFramebufferRenderbuffer" %gl-framebuffer-renderbuffer) :void
  (target :uint32) (attachment :uint32) (renderbuffer-target :uint32)
  (renderbuffer :uint32))
(cffi:defcfun ("glGenFramebuffers" %gl-gen-framebuffers) :void
  (count :int32) (framebuffers :pointer))
(cffi:defcfun ("glGenRenderbuffers" %gl-gen-renderbuffers) :void
  (count :int32) (renderbuffers :pointer))
(cffi:defcfun ("glGenTextures" %gl-gen-textures) :void
  (count :int32) (textures :pointer))
(cffi:defcfun ("glGetIntegerv" %gl-get-integer) :void
  (name :uint32) (value :pointer))
(cffi:defcfun ("glTexImage2D" %gl-texture-image) :void
  (target :uint32) (level :int32) (internal-format :int32)
  (width :int32) (height :int32) (border :int32)
  (format :uint32) (type :uint32) (pixels :pointer))
(cffi:defcfun ("glTexParameteri" %gl-texture-parameter) :void
  (target :uint32) (name :uint32) (value :int32))
(cffi:defcfun ("glBindRenderbuffer" %gl-bind-renderbuffer) :void
  (target :uint32) (renderbuffer :uint32))
(cffi:defcfun ("glRenderbufferStorage" %gl-renderbuffer-storage) :void
  (target :uint32) (internal-format :uint32) (width :int32) (height :int32))

(defconstant +rgba+ #x1908)
(defconstant +unsigned-byte+ #x1401)
(defconstant +texture-min-filter+ #x2801)
(defconstant +texture-mag-filter+ #x2800)
(defconstant +texture-wrap-s+ #x2802)
(defconstant +texture-wrap-t+ #x2803)
(defconstant +linear+ #x2601)
(defconstant +clamp-to-edge+ #x812f)
(defconstant +framebuffer+ #x8d40)
(defconstant +framebuffer-binding+ #x8ca6)
(defconstant +color-attachment-0+ #x8ce0)
(defconstant +renderbuffer+ #x8d41)
(defconstant +stencil-attachment+ #x8d20)
(defconstant +stencil-index-8+ #x8d48)
(defconstant +framebuffer-complete+ #x8cd5)

(defmethod ataxia.kernel:render-source-width ((source rmlui-render-source))
  (%render-source-width source))

(defmethod ataxia.kernel:render-source-height ((source rmlui-render-source))
  (%render-source-height source))

(defmethod ataxia.kernel:render-source-gles-target ((source rmlui-render-source))
  ataxia.world.gles:+texture-2d+)

(defmethod ataxia.kernel:render-source-gles-name ((source rmlui-render-source))
  (%render-source-texture source))

(defmethod ataxia.kernel:render-source-has-alpha-p ((source rmlui-render-source))
  t)

(defmethod ataxia.kernel:render-source-generation ((source rmlui-render-source))
  (%render-source-generation source))

(defmethod ataxia.kernel:retain-render-source ((source rmlui-render-source)) source)
(defmethod ataxia.kernel:release-render-source ((source rmlui-render-source)) nil)

(defmethod ataxia.kernel:drawable-local-bounds ((component rmlui-component))
  (values 0d0 0d0
          (rmlui-component-width component)
          (rmlui-component-height component)))

(defmethod ataxia.kernel:drawable-surfaces ((component rmlui-component))
  (values (%component-surfaces component) (%component-revision component)))

(defmethod ataxia.kernel:drawable-attach-graphics ((component rmlui-component))
  (attach-rmlui-component-graphics component))

(defmethod ataxia.kernel:drawable-detach-graphics ((component rmlui-component))
  (detach-rmlui-component-graphics component))

(defmethod ataxia.kernel:drawable-prepare-frame ((component rmlui-component))
  (unless (rmlui-component-graphics-attached-p component)
    (attach-rmlui-component-graphics component))
  (render-rmlui-component component))

(defmethod ataxia.kernel:drawable-active-p ((component rmlui-component))
  (rmlui-component-active-p component))

(defun rmlui-component-graphics-attached-p (component)
  (plusp (%component-framebuffer component)))

(defun %refresh-surface (component)
  (let* ((source
           (make-instance
            'rmlui-render-source
            :texture (%component-texture component)
            :width (%component-texture-width component)
            :height (%component-texture-height component)
            :generation (%component-texture-generation component)))
         (surface
           (make-instance
            'ataxia.kernel:drawable-surface
            :local-x 0d0 :local-y 0d0
            :width (rmlui-component-width component)
            :height (rmlui-component-height component)
            :texture-coordinates
            #(0d0 1d0 1d0 1d0 0d0 0d0 1d0 0d0)
            :render-source source)))
    (setf (%component-surfaces component) (vector surface))))

(defun %allocate-texture (component width height)
  (%gl-bind-texture ataxia.world.gles:+texture-2d+ (%component-texture component))
  (%gl-texture-parameter ataxia.world.gles:+texture-2d+
                         +texture-min-filter+ +linear+)
  (%gl-texture-parameter ataxia.world.gles:+texture-2d+
                         +texture-mag-filter+ +linear+)
  (%gl-texture-parameter ataxia.world.gles:+texture-2d+
                         +texture-wrap-s+ +clamp-to-edge+)
  (%gl-texture-parameter ataxia.world.gles:+texture-2d+
                         +texture-wrap-t+ +clamp-to-edge+)
  (%gl-texture-image
   ataxia.world.gles:+texture-2d+ 0 +rgba+ width height 0
   +rgba+ +unsigned-byte+ (cffi:null-pointer))
  (%gl-bind-renderbuffer +renderbuffer+ (%component-stencil-buffer component))
  (%gl-renderbuffer-storage
   +renderbuffer+ +stencil-index-8+ width height)
  (setf (%component-texture-width component) width
        (%component-texture-height component) height)
  (incf (%component-texture-generation component))
  (%refresh-surface component)
  component)

(defun call-with-preserved-graphics-state (function)
  (let ((state (ataxia.world.rmlui.raw::%gl-save)))
    (when (cffi:null-pointer-p state)
      (ataxia.world.rmlui.raw::native-error :graphics-scope))
    (unwind-protect (funcall function)
      (ataxia.world.rmlui.raw::%gl-restore state))))

(defun %create-framebuffer (component)
  (cffi:with-foreign-objects
      ((texture :uint32) (framebuffer :uint32) (stencil-buffer :uint32))
    (%gl-gen-textures 1 texture)
    (%gl-gen-framebuffers 1 framebuffer)
    (%gl-gen-renderbuffers 1 stencil-buffer)
    (setf (%component-texture component) (cffi:mem-ref texture :uint32)
          (%component-framebuffer component) (cffi:mem-ref framebuffer :uint32)
          (%component-stencil-buffer component)
          (cffi:mem-ref stencil-buffer :uint32)))
  (when (or (zerop (%component-texture component))
            (zerop (%component-framebuffer component))
            (zerop (%component-stencil-buffer component)))
    (error "GLES could not allocate a RmlUi render target."))
  (%allocate-texture
   component
   (ataxia.world.rmlui.raw::%component-width (%live-native component))
   (ataxia.world.rmlui.raw::%component-height (%live-native component)))
  (%gl-bind-framebuffer +framebuffer+ (%component-framebuffer component))
  (%gl-framebuffer-texture
   +framebuffer+ +color-attachment-0+ ataxia.world.gles:+texture-2d+
   (%component-texture component) 0)
  (%gl-framebuffer-renderbuffer
   +framebuffer+ +stencil-attachment+ +renderbuffer+
   (%component-stencil-buffer component))
  (let ((status (%gl-check-framebuffer-status +framebuffer+)))
    (unless (= status +framebuffer-complete+)
      (error "RmlUi framebuffer is incomplete: 0x~X." status)))
  component)

(defun attach-rmlui-component-graphics (component)
  "Attach a direct RmlUi GLES render target inside a World graphics scope."
  (when (zerop (%component-framebuffer component))
    (call-with-preserved-graphics-state
     (lambda ()
       (handler-case
           (progn
             (%create-framebuffer component)
             (ataxia.world.rmlui.raw::check-result
              (ataxia.world.rmlui.raw::%component-attach-graphics
               (%live-native component) (%component-framebuffer component))
              :attach-graphics))
         (serious-condition (cause)
           (ignore-errors (detach-rmlui-component-graphics component))
           (error cause))))))
  component)

(defun %delete-handle (function handle)
  (when (plusp handle)
    (cffi:with-foreign-object (pointer :uint32)
      (setf (cffi:mem-ref pointer :uint32) handle)
      (funcall function 1 pointer))))

(defun %detach-rmlui-component-graphics (component)
  "Release the direct RmlUi GLES target inside a World graphics scope."
  (when (plusp (%component-framebuffer component))
    (ataxia.world.rmlui.raw::check-result
     (ataxia.world.rmlui.raw::%component-detach-graphics
      (%live-native component))
     :detach-graphics)
    (%delete-handle #'%gl-delete-framebuffers (%component-framebuffer component))
    (%delete-handle #'%gl-delete-renderbuffers (%component-stencil-buffer component))
    (%delete-handle #'%gl-delete-textures (%component-texture component))
    (setf (%component-framebuffer component) 0
          (%component-stencil-buffer component) 0
          (%component-texture component) 0
          (%component-texture-width component) 0
          (%component-texture-height component) 0
          (%component-surfaces component) #()))
  component)

(defun %full-component-damage (component)
  (list
   (ataxia.world:make-rectangle
    0d0 0d0
    (rmlui-component-width component)
    (rmlui-component-height component))))

(defun %render-rmlui-component (component)
  "Render pending RmlUi work directly into its texture and return local damage."
  (unless (rmlui-component-graphics-attached-p component)
    (error "RmlUi component graphics are not attached."))
  (let* ((native (%live-native component))
         (width (ataxia.world.rmlui.raw::%component-width native))
         (height (ataxia.world.rmlui.raw::%component-height native)))
    (when (or (/= width (%component-texture-width component))
              (/= height (%component-texture-height component)))
      (%allocate-texture component width height))
    (let ((old-revision (%component-revision component)))
      (ataxia.world.rmlui.raw::check-result
       (ataxia.world.rmlui.raw::%component-render native) :render)
      (let ((revision (ataxia.world.rmlui.raw::%component-revision native)))
        (setf (%component-revision component) revision)
        (let ((damage (and (/= revision old-revision) (%full-component-damage component)))
              (active (rmlui-component-active-p component)))
          (poll-rmlui-callbacks component)
          (values damage active))))))

(defun detach-rmlui-component-graphics (component)
  (when (rmlui-component-graphics-attached-p component)
    (call-with-preserved-graphics-state
     (lambda () (%detach-rmlui-component-graphics component))))
  component)

(defun render-rmlui-component (component)
  ;; Other drawables can request a frame while this texture is unchanged.
  ;; Check the native dirty flag/deadline before saving any GLES state. Resizing
  ;; invalidates the component, and unattached graphics still take the error path.
  (when (and (rmlui-component-graphics-attached-p component)
             (not (rmlui-component-active-p component)))
    (poll-rmlui-callbacks component)
    (return-from render-rmlui-component
      (values nil (rmlui-component-active-p component))))
  (call-with-preserved-graphics-state
   (lambda () (%render-rmlui-component component))))
