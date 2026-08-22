;;;; GLES texture bridge for Slint's damage-tracked software scene buffer.
;;;;
;;;; Uploads occur only inside a World graphics scope. Dirty rectangles are
;;;; copied into one reusable staging allocation and uploaded independently.

(in-package #:ataxia.world.slint)

(cffi:defcfun ("glBindTexture" %gl-bind-texture) :void
  (target :uint32) (texture :uint32))
(cffi:defcfun ("glDeleteTextures" %gl-delete-textures) :void
  (count :int32) (textures :pointer))
(cffi:defcfun ("glGenTextures" %gl-gen-textures) :void
  (count :int32) (textures :pointer))
(cffi:defcfun ("glPixelStorei" %gl-pixel-store) :void
  (name :uint32) (value :int32))
(cffi:defcfun ("glTexImage2D" %gl-texture-image) :void
  (target :uint32) (level :int32) (internal-format :int32)
  (width :int32) (height :int32) (border :int32)
  (format :uint32) (type :uint32) (pixels :pointer))
(cffi:defcfun ("glTexParameteri" %gl-texture-parameter) :void
  (target :uint32) (name :uint32) (value :int32))
(cffi:defcfun ("glTexSubImage2D" %gl-texture-sub-image) :void
  (target :uint32) (level :int32) (x :int32) (y :int32)
  (width :int32) (height :int32) (format :uint32) (type :uint32)
  (pixels :pointer))
(cffi:defcfun ("memcpy" %memcpy) :pointer
  (destination :pointer) (source :pointer) (size :size))

(defconstant +rgba+ #x1908)
(defconstant +unsigned-byte+ #x1401)
(defconstant +texture-min-filter+ #x2801)
(defconstant +texture-mag-filter+ #x2800)
(defconstant +texture-wrap-s+ #x2802)
(defconstant +texture-wrap-t+ #x2803)
(defconstant +linear+ #x2601)
(defconstant +clamp-to-edge+ #x812f)
(defconstant +unpack-alignment+ #x0cf5)

(defmethod ataxia.kernel:render-source-width ((source slint-render-source))
  (%render-source-width source))

(defmethod ataxia.kernel:render-source-height ((source slint-render-source))
  (%render-source-height source))

(defmethod ataxia.kernel:render-source-gles-target ((source slint-render-source))
  ataxia.world.gles:+texture-2d+)

(defmethod ataxia.kernel:render-source-gles-name ((source slint-render-source))
  (%render-source-texture source))

(defmethod ataxia.kernel:render-source-has-alpha-p ((source slint-render-source))
  t)

(defmethod ataxia.kernel:render-source-generation ((source slint-render-source))
  (%render-source-generation source))

(defmethod ataxia.kernel:retain-render-source ((source slint-render-source)) source)
(defmethod ataxia.kernel:release-render-source ((source slint-render-source)) nil)

(defmethod ataxia.kernel:drawable-local-bounds ((component slint-component))
  (values 0d0 0d0
          (slint-component-width component)
          (slint-component-height component)))

(defmethod ataxia.kernel:drawable-surfaces ((component slint-component))
  (values (%component-surfaces component) (%component-revision component)))

(defmethod ataxia.kernel:drawable-attach-graphics ((component slint-component))
  (attach-slint-component-graphics component))

(defmethod ataxia.kernel:drawable-detach-graphics ((component slint-component))
  (detach-slint-component-graphics component))

(defmethod ataxia.kernel:drawable-prepare-frame ((component slint-component))
  (update-slint-timers)
  (unless (slint-component-graphics-attached-p component)
    (attach-slint-component-graphics component))
  (render-slint-component component))

(defmethod ataxia.kernel:drawable-active-p ((component slint-component))
  (slint-component-active-p component))

(defun slint-component-graphics-attached-p (component)
  (plusp (%component-texture component)))

(defun %refresh-surface (component damage)
  (let* ((source
           (make-instance
            'slint-render-source
            :texture (%component-texture component)
            :width (%component-texture-width component)
            :height (%component-texture-height component)
            :generation (%component-revision component)))
         (surface
           (make-instance
            'ataxia.kernel:drawable-surface
            :id component :local-x 0d0 :local-y 0d0
            :width (slint-component-width component)
            :height (slint-component-height component)
            :order 0 :source-box #(0d0 0d0 1d0 1d0)
            :buffer-transform 0 :render-source source
            :damage damage :generation (%component-revision component))))
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
  (setf (%component-texture-width component) width
        (%component-texture-height component) height)
  component)

(defun attach-slint-component-graphics (component)
  "Create COMPONENT's sampling texture while a World GLES scope is active."
  (when (zerop (%component-texture component))
    (cffi:with-foreign-object (texture :uint32)
      (%gl-gen-textures 1 texture)
      (setf (%component-texture component) (cffi:mem-ref texture :uint32)))
    (when (zerop (%component-texture component))
      (error "glGenTextures returned zero for a Slint component."))
    (%allocate-texture
     component
     (ataxia.world.slint.raw::%component-width (%live-native component))
     (ataxia.world.slint.raw::%component-height (%live-native component)))
    (%refresh-surface component nil))
  component)

(defun detach-slint-component-graphics (component)
  "Release COMPONENT's GLES resources while a World GLES scope is active."
  (when (plusp (%component-texture component))
    (cffi:with-foreign-object (texture :uint32)
      (setf (cffi:mem-ref texture :uint32) (%component-texture component))
      (%gl-delete-textures 1 texture))
    (setf (%component-texture component) 0
          (%component-texture-width component) 0
          (%component-texture-height component) 0
          (%component-surfaces component) #()))
  (unless (cffi:null-pointer-p (%component-upload-buffer component))
    (cffi:foreign-free (%component-upload-buffer component))
    (setf (%component-upload-buffer component) (cffi:null-pointer)
          (%component-upload-capacity component) 0))
  component)

(defun %ensure-upload-capacity (component bytes)
  (when (> bytes (%component-upload-capacity component))
    (unless (cffi:null-pointer-p (%component-upload-buffer component))
      (cffi:foreign-free (%component-upload-buffer component)))
    (setf (%component-upload-buffer component) (cffi:foreign-alloc :uint8 :count bytes)
          (%component-upload-capacity component) bytes))
  (%component-upload-buffer component))

(defun %native-damage (component)
  (let ((native (%live-native component)))
    (cffi:with-foreign-object (rectangle '(:struct ataxia.world.slint.raw::damage-rectangle))
      (loop for index below (ataxia.world.slint.raw::%component-damage-count native)
            when (ataxia.world.slint.raw::%component-damage-rectangle
                  native index rectangle)
              collect
              (list
               (cffi:foreign-slot-value
                rectangle '(:struct ataxia.world.slint.raw::damage-rectangle) 'ataxia.world.slint.raw::x)
               (cffi:foreign-slot-value
                rectangle '(:struct ataxia.world.slint.raw::damage-rectangle) 'ataxia.world.slint.raw::y)
               (cffi:foreign-slot-value
                rectangle '(:struct ataxia.world.slint.raw::damage-rectangle) 'ataxia.world.slint.raw::width)
               (cffi:foreign-slot-value
                rectangle '(:struct ataxia.world.slint.raw::damage-rectangle) 'ataxia.world.slint.raw::height))))))

(defun %upload-rectangle (component pixels source-width rectangle)
  (destructuring-bind (x y width height) rectangle
    (let* ((row-bytes (* width 4))
           (bytes (* row-bytes height))
           (staging (%ensure-upload-capacity component bytes)))
      (loop for row below height
            for source-offset = (* (+ (* (+ y row) source-width) x) 4)
            for destination-offset = (* row row-bytes)
            do (%memcpy
                (cffi:inc-pointer staging destination-offset)
                (cffi:inc-pointer pixels source-offset) row-bytes))
      (%gl-texture-sub-image
       ataxia.world.gles:+texture-2d+ 0 x y width height
       +rgba+ +unsigned-byte+ staging))))

(defun render-slint-component (component)
  "Render pending Slint scene work, upload changed pixels, and return local damage."
  (unless (plusp (%component-texture component))
    (error "Slint component graphics are not attached."))
  (let* ((native (%live-native component))
         (width (ataxia.world.slint.raw::%component-width native))
         (height (ataxia.world.slint.raw::%component-height native)))
    (when (or (/= width (%component-texture-width component))
              (/= height (%component-texture-height component)))
      (%allocate-texture component width height))
    (ataxia.world.slint.raw::check-result
     (ataxia.world.slint.raw::%component-render native) :render)
    (let* ((rectangles (%native-damage component))
           (revision (ataxia.world.slint.raw::%component-revision native))
           (scale (slint-component-scale component))
           (logical-damage
             (mapcar
              (lambda (rectangle)
                (destructuring-bind (x y damaged-width damaged-height) rectangle
                  (ataxia.world:make-rectangle
                   (/ x scale) (/ y scale)
                   (/ damaged-width scale) (/ damaged-height scale))))
              rectangles)))
      (when rectangles
        (%gl-bind-texture ataxia.world.gles:+texture-2d+
                          (%component-texture component))
        (%gl-pixel-store +unpack-alignment+ 1)
        (let ((pixels (ataxia.world.slint.raw::%component-pixels native)))
          (dolist (rectangle rectangles)
            (%upload-rectangle component pixels width rectangle))))
      (when (/= revision (%component-revision component))
        (setf (%component-revision component) revision)
        (%refresh-surface component logical-damage))
      (poll-slint-callbacks component)
      (values logical-damage (slint-component-active-p component)))))
