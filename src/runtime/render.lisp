;;;; Direct EGL context handoff.
;;;;
;;;; This module makes the GLES renderer's wlroots-owned EGL context current
;;;; for a dynamic Lisp extent and restores the prior EGL state afterward.
;;;; Shader compilation, draw submission, and render policy remain in Layer 2.

(in-package #:ataxia.runtime.raw)

(defcfun ("wlr_egl_get_display" %wlr-egl-get-display) :pointer
  (egl :pointer))
(defcfun ("wlr_egl_get_context" %wlr-egl-get-context) :pointer
  (egl :pointer))
(defcfun ("eglGetCurrentDisplay" %egl-get-current-display) :pointer)
(defcfun ("eglGetCurrentContext" %egl-get-current-context) :pointer)
(defcfun ("eglGetCurrentSurface" %egl-get-current-surface) :pointer
  (which :uint32))
(defcfun ("eglMakeCurrent" %egl-make-current) :boolean
  (display :pointer)
  (draw-surface :pointer)
  (read-surface :pointer)
  (context :pointer))
(defcfun ("eglGetError" %egl-get-error) :uint32)
(defcfun ("wlr_buffer_unlock" %wlr-buffer-unlock) :void
  (buffer :pointer))
(defcfun ("wlr_texture_is_gles2" %wlr-texture-is-gles2) :boolean
  (texture :pointer))
(defcfun ("ataxia_surface_lock_buffer" %surface-lock-buffer) :pointer
  (surface :pointer))
(defcfun ("ataxia_buffer_width" %buffer-width) :int32
  (buffer :pointer))
(defcfun ("ataxia_buffer_height" %buffer-height) :int32
  (buffer :pointer))
(defcfun ("ataxia_client_buffer_texture" %client-buffer-texture) :pointer
  (buffer :pointer))
(defcfun ("ataxia_texture_width" %texture-width) :uint32
  (texture :pointer))
(defcfun ("ataxia_texture_height" %texture-height) :uint32
  (texture :pointer))
(defcfun ("ataxia_gles2_texture_target" %gles2-texture-target) :uint32
  (texture :pointer))
(defcfun ("ataxia_gles2_texture_name" %gles2-texture-name) :uint32
  (texture :pointer))
(defcfun ("ataxia_gles2_texture_has_alpha" %gles2-texture-has-alpha)
    :boolean
  (texture :pointer))

(in-package #:ataxia.runtime)

(defconstant +egl-draw-surface+ #x3059)
(defconstant +egl-read-surface+ #x305a)

(defclass wlr-buffer (native-object)
  ((width :initarg :width :reader buffer-width)
   (height :initarg :height :reader buffer-height)
   (textures :initform nil :accessor %buffer-textures)))

(defclass wlr-texture (native-object)
  ((buffer :initarg :buffer :reader %texture-buffer)
   (width :initarg :width :reader texture-width)
   (height :initarg :height :reader texture-height)))

(defstruct (gles-texture-attributes
             (:constructor %make-gles-texture-attributes
                 (&key target name has-alpha-p))
             (:conc-name gles-texture-))
  (target 0 :type (unsigned-byte 32) :read-only t)
  (name 0 :type (unsigned-byte 32) :read-only t)
  (has-alpha-p nil :type boolean :read-only t))

(defun retain-surface-buffer (surface)
  (check-type surface wlr-surface)
  (let* ((runtime (%native-runtime surface))
         (pointer
           (progn
             (%assert-runtime-live runtime :retain-surface-buffer)
             (ataxia.runtime.raw:%surface-lock-buffer
              (%object-pointer surface)))))
    (unless (ataxia.runtime.raw:null-pointer-p pointer)
      (let ((buffer
              (%wrap-pointer
               'wlr-buffer pointer runtime
               :width (ataxia.runtime.raw:%buffer-width pointer)
               :height (ataxia.runtime.raw:%buffer-height pointer))))
        (setf (gethash buffer (%runtime-retained-buffer-table runtime)) t)
        buffer))))

(defun buffer-texture (buffer)
  (check-type buffer wlr-buffer)
  (let ((runtime (%native-runtime buffer)))
    (%assert-runtime-live runtime :buffer-texture)
    (let ((pointer
            (ataxia.runtime.raw:%client-buffer-texture
             (%object-pointer buffer))))
      (unless (ataxia.runtime.raw:null-pointer-p pointer)
        (let ((texture
                (%wrap-pointer
                 'wlr-texture pointer runtime
                 :buffer buffer
                 :width (ataxia.runtime.raw:%texture-width pointer)
                 :height (ataxia.runtime.raw:%texture-height pointer))))
          (push texture (%buffer-textures buffer))
          texture)))))

(defun texture-gles-attributes (texture)
  (check-type texture wlr-texture)
  (%assert-runtime-live
   (%native-runtime texture) :texture-gles-attributes)
  (let ((pointer (%object-pointer texture)))
    (unless (ataxia.runtime.raw:%wlr-texture-is-gles2 pointer)
      (error 'native-call-failed
             :name :texture-gles-attributes
             :detail "texture does not belong to the GLES2 renderer"))
    (%make-gles-texture-attributes
     :target (ataxia.runtime.raw:%gles2-texture-target pointer)
     :name (ataxia.runtime.raw:%gles2-texture-name pointer)
     :has-alpha-p (ataxia.runtime.raw:%gles2-texture-has-alpha pointer))))

(defun release-buffer (buffer)
  (check-type buffer wlr-buffer)
  (when (native-object-live-p buffer)
    (let ((runtime (%native-runtime buffer)))
      (%assert-owner-thread runtime :release-buffer)
      (dolist (texture (%buffer-textures buffer))
        (%invalidate-native-object texture))
      (setf (%buffer-textures buffer) nil)
      (ataxia.runtime.raw:%wlr-buffer-unlock (%object-pointer buffer))
      (%invalidate-native-object buffer)
      (remhash buffer (%runtime-retained-buffer-table runtime))))
  nil)

(defun %release-runtime-buffers (runtime)
  (dolist (buffer
            (loop for buffer being the hash-keys
                    of (%runtime-retained-buffer-table runtime)
                  collect buffer))
    (release-buffer buffer))
  (clrhash (%runtime-retained-buffer-table runtime))
  runtime)

(defun %require-egl-current
    (display draw-surface read-surface context operation)
  (unless (ataxia.runtime.raw:%egl-make-current
           display draw-surface read-surface context)
    (error 'native-call-failed
           :name operation
           :detail (format nil "EGL error 0x~X"
                           (ataxia.runtime.raw:%egl-get-error)))))

(defun call-with-egl-context (egl function)
  (check-type egl wlr-egl)
  (check-type function function)
  (let ((runtime (%native-runtime egl)))
    (%assert-runtime-live runtime :call-with-egl-context)
    (let* ((egl-pointer (%object-pointer egl))
           (display
             (%require-pointer
              (ataxia.runtime.raw:%wlr-egl-get-display egl-pointer)
              :wlr-egl-get-display))
           (context
             (%require-pointer
              (ataxia.runtime.raw:%wlr-egl-get-context egl-pointer)
              :wlr-egl-get-context))
           (previous-display
             (ataxia.runtime.raw:%egl-get-current-display))
           (previous-context
             (ataxia.runtime.raw:%egl-get-current-context))
           (previous-draw
             (ataxia.runtime.raw:%egl-get-current-surface
              +egl-draw-surface+))
           (previous-read
             (ataxia.runtime.raw:%egl-get-current-surface
              +egl-read-surface+)))
      (%require-egl-current
       display
       (ataxia.runtime.raw:null-pointer)
       (ataxia.runtime.raw:null-pointer)
       context
       :egl-make-current)
      (unwind-protect
           (funcall function)
        (if (ataxia.runtime.raw:null-pointer-p previous-context)
            (%require-egl-current
             display
             (ataxia.runtime.raw:null-pointer)
             (ataxia.runtime.raw:null-pointer)
             (ataxia.runtime.raw:null-pointer)
             :egl-clear-current)
            (%require-egl-current
             previous-display previous-draw previous-read previous-context
             :egl-restore-current))))))

(defmacro with-egl-context ((egl) &body body)
  `(call-with-egl-context ,egl (lambda () ,@body)))
