;;;; Direct EGL context handoff.
;;;;
;;;; This module makes the GLES renderer's wlroots-owned EGL context current
;;;; for a dynamic Lisp extent and restores the prior EGL state afterward, and
;;;; times GL work in it with timestamp queries.
;;;; Shader compilation, draw submission, and render policy remain in the
;;;; compositor system.

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
(defcfun ("wlr_surface_send_enter" %wlr-surface-send-enter) :void
  (surface :pointer)
  (output :pointer))
(defcfun ("wlr_surface_send_leave" %wlr-surface-send-leave) :void
  (surface :pointer)
  (output :pointer))
(defcstruct timespec
  (seconds :long)
  (nanoseconds :long))
(defcfun ("clock_gettime" %clock-gettime) :int
  (clock-id :int)
  (time (:pointer (:struct timespec))))
(defcfun ("wlr_surface_send_frame_done" %wlr-surface-send-frame-done) :void
  (surface :pointer)
  (time (:pointer (:struct timespec))))
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
(defcfun ("glGetString" %gl-get-string) :pointer
  (name :uint32))
(defcfun ("eglGetProcAddress" %egl-get-proc-address) :pointer
  (name :string))
(defcfun ("glGetIntegerv" %gl-get-integer) :void
  (name :uint32)
  (value :pointer))

(in-package #:ataxia.runtime)

(defconstant +egl-draw-surface+ #x3059)
(defconstant +egl-read-surface+ #x305a)
(defconstant +clock-monotonic+ 1)
(defconstant +gl-extensions+ #x1f03)
(defconstant +gl-timestamp+ #x8e28)
(defconstant +gl-query-result+ #x8866)
(defconstant +gl-query-result-available+ #x8867)
(defconstant +gl-gpu-disjoint+ #x8fbb)

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

(defun %assert-surface-output-pair (surface output operation)
  (check-type surface wlr-surface)
  (check-type output wlr-output)
  (let ((runtime (%native-runtime surface)))
    (%assert-runtime-live runtime operation)
    (%assert-object-runtime runtime output operation))
  surface)

(defun surface-send-enter (surface output)
  (%assert-surface-output-pair surface output :surface-send-enter)
  (ataxia.runtime.raw:%wlr-surface-send-enter
   (%object-pointer surface) (%object-pointer output))
  surface)

(defun surface-send-leave (surface output)
  (%assert-surface-output-pair surface output :surface-send-leave)
  (ataxia.runtime.raw:%wlr-surface-send-leave
   (%object-pointer surface) (%object-pointer output))
  surface)

(defun surface-send-frame-done (surface)
  (check-type surface wlr-surface)
  (%assert-runtime-live (%native-runtime surface) :surface-send-frame-done)
  (cffi:with-foreign-object
      (timestamp '(:struct ataxia.runtime.raw::timespec))
    (unless (zerop
             (ataxia.runtime.raw:%clock-gettime +clock-monotonic+ timestamp))
      (error 'native-call-failed :name :clock-gettime))
    (ataxia.runtime.raw:%wlr-surface-send-frame-done
     (%object-pointer surface) timestamp))
  surface)

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

;;; GPU timing. Timestamp queries around a stretch of GL work measure what the
;;; GPU spent on it without waiting for it; results arrive a frame or two later.

(defvar *gpu-timer-functions* :unknown
  "Entry points of EXT_disjoint_timer_query: gen, delete, counter, available and
result; NIL when the driver lacks it.")

(defun %gpu-timer-functions ()
  (when (eq *gpu-timer-functions* :unknown)
    (let ((extensions (ataxia.runtime.raw:%gl-get-string +gl-extensions+)))
      (setf *gpu-timer-functions*
            (and (not (ataxia.runtime.raw:null-pointer-p extensions))
                 (search "GL_EXT_disjoint_timer_query"
                         (ataxia.runtime.raw:foreign-string-to-lisp extensions))
                 (mapcar #'ataxia.runtime.raw:%egl-get-proc-address
                         '("glGenQueriesEXT" "glDeleteQueriesEXT" "glQueryCounterEXT"
                           "glGetQueryObjectivEXT" "glGetQueryObjectui64vEXT"))))))
  *gpu-timer-functions*)

(defstruct (gpu-timer (:constructor %make-gpu-timer (egl)))
  (egl nil :type wlr-egl :read-only t)
  ;; Query pairs: the span being timed, spans awaiting results newest first, and
  ;; pairs to reuse.
  (open nil)
  (pending nil :type list)
  (free nil :type list))

(defun make-gpu-timer (egl)
  "A timer for GL work in EGL's context, or NIL when its driver cannot time it.
Call with that context current."
  (check-type egl wlr-egl)
  (%assert-runtime-live (%native-runtime egl) :make-gpu-timer)
  (and (%gpu-timer-functions) (%make-gpu-timer egl)))

(defun %gpu-timestamp (query)
  (cffi:foreign-funcall-pointer (third (%gpu-timer-functions)) ()
                                :uint32 query :uint32 +gl-timestamp+ :void))

(defun gpu-timer-start (timer)
  "Mark the start of GL work to time. A span still open, its end never marked,
starts again. With too many spans awaiting results, they stopped coming and
nothing is timed."
  (check-type timer gpu-timer)
  (when (and (null (gpu-timer-open timer)) (< (length (gpu-timer-pending timer)) 4))
    (setf (gpu-timer-open timer)
          (or (pop (gpu-timer-free timer))
              (cffi:with-foreign-object (ids :uint32 2)
                (cffi:foreign-funcall-pointer (first (%gpu-timer-functions)) ()
                                              :int32 2 :pointer ids :void)
                (cons (cffi:mem-aref ids :uint32 0) (cffi:mem-aref ids :uint32 1))))))
  (when (gpu-timer-open timer)
    (%gpu-timestamp (car (gpu-timer-open timer))))
  timer)

(defun gpu-timer-stop (timer)
  "Mark the end of the GL work started with GPU-TIMER-START."
  (check-type timer gpu-timer)
  (let ((pair (shiftf (gpu-timer-open timer) nil)))
    (when pair
      (%gpu-timestamp (cdr pair))
      (push pair (gpu-timer-pending timer))))
  timer)

(defun gpu-timer-results (timer)
  "Nanoseconds the GPU spent on each timed span finished since the last call,
oldest first, without waiting for any. None when the GPU's clock jumped since,
which makes the spans meaningless."
  (check-type timer gpu-timer)
  (destructuring-bind (gen delete counter available result) (%gpu-timer-functions)
    (declare (ignore gen delete counter))
    (cffi:with-foreign-objects ((ready :int32) (start :uint64) (end :uint64))
      (ataxia.runtime.raw:%gl-get-integer +gl-gpu-disjoint+ ready)
      (unless (zerop (cffi:mem-ref ready :int32))
        (setf (gpu-timer-free timer) (append (gpu-timer-pending timer) (gpu-timer-free timer))
              (gpu-timer-pending timer) nil)
        (return-from gpu-timer-results nil))
      (loop for pair in (reverse (gpu-timer-pending timer))
            do (cffi:foreign-funcall-pointer available () :uint32 (cdr pair)
                                             :uint32 +gl-query-result-available+ :pointer ready :void)
            until (zerop (cffi:mem-ref ready :int32))
            do (cffi:foreign-funcall-pointer result () :uint32 (car pair)
                                             :uint32 +gl-query-result+ :pointer start :void)
               (cffi:foreign-funcall-pointer result () :uint32 (cdr pair)
                                             :uint32 +gl-query-result+ :pointer end :void)
               (setf (gpu-timer-pending timer) (remove pair (gpu-timer-pending timer)))
               (push pair (gpu-timer-free timer))
            collect (- (cffi:mem-ref end :uint64) (cffi:mem-ref start :uint64))))))

(defun release-gpu-timer (timer)
  "Delete TIMER's queries while its EGL lives."
  (check-type timer gpu-timer)
  (let ((pairs (append (and (gpu-timer-open timer) (list (gpu-timer-open timer)))
                       (gpu-timer-pending timer) (gpu-timer-free timer)))
        (egl (gpu-timer-egl timer)))
    (setf (gpu-timer-open timer) nil (gpu-timer-pending timer) nil (gpu-timer-free timer) nil)
    (when (and pairs (native-object-live-p egl))
      (with-egl-context (egl)
        (cffi:with-foreign-object (ids :uint32 (* 2 (length pairs)))
          (loop for (start . end) in pairs
                for index from 0 by 2
                do (setf (cffi:mem-aref ids :uint32 index) start
                         (cffi:mem-aref ids :uint32 (1+ index)) end))
          (cffi:foreign-funcall-pointer (second (%gpu-timer-functions)) ()
                                        :int32 (* 2 (length pairs)) :pointer ids :void)))))
  nil)
