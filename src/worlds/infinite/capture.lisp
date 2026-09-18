;;;; Infinite World capture backend. Loaded by ataxia-computer-use/infinite-world.
(in-package #:ataxia.infinite-world)

(defmethod ataxia.world:world-supports-p :around ((world infinite-world) capability)
  (or (eq capability :window-capture) (call-next-method)))

(defun %call-with-window-capture-state (world function)
  (ataxia.world.rmlui:call-with-preserved-graphics-state
   (lambda ()
     ;; The shared UI guard covers drawing and upload state. Capture additionally
     ;; changes readback strides and may sample an external client texture.
     (cffi:with-foreign-objects ((stores :int 3) (external :int))
       (let ((parameters '(#x0D02 #x0D04 #x0D03))
             (external-p (%canvas-renderer-external-program (%world-renderer world)))
             (discard (cffi:foreign-funcall "glIsEnabled" :uint #x8C89 :uchar)))
         (loop for parameter in parameters for i from 0 do
               (cffi:foreign-funcall "glGetIntegerv" :uint parameter :pointer (cffi:mem-aptr stores :int i) :void))
         (cffi:foreign-funcall "glActiveTexture" :uint #x84C0 :void)
         (when external-p (cffi:foreign-funcall "glGetIntegerv" :uint #x8D67 :pointer external :void))
         (unwind-protect (funcall function)
           (loop for parameter in parameters for i from 0 do
                 (cffi:foreign-funcall "glPixelStorei" :uint parameter :int (cffi:mem-aref stores :int i) :void))
           (when external-p
             (cffi:foreign-funcall "glActiveTexture" :uint #x84C0 :void)
             (cffi:foreign-funcall "glBindTexture" :uint #x8D65 :uint (cffi:mem-ref external :int) :void))
           (unless (zerop discard) (cffi:foreign-funcall "glEnable" :uint #x8C89 :void))))))))
(defun %render-window-capture-pixels (world window bounds width height pixels)
  "Draw and read one window while the caller preserves the compositor's GL state."
  (destructuring-bind (left top logical-width logical-height) bounds
    (cffi:with-foreign-objects ((texture :uint) (framebuffer :uint) (vao :uint))
      (setf (cffi:mem-ref texture :uint) 0
            (cffi:mem-ref framebuffer :uint) 0
            (cffi:mem-ref vao :uint) 0)
      (unwind-protect
           (progn
             (cffi:foreign-funcall "glGenTextures" :int 1 :pointer texture :void)
             (cffi:foreign-funcall "glGenFramebuffers" :int 1 :pointer framebuffer :void)
             (cffi:foreign-funcall "glGenVertexArrays" :int 1 :pointer vao :void)
             (cffi:foreign-funcall "glBindVertexArray" :uint (cffi:mem-ref vao :uint) :void)
             (cffi:foreign-funcall "glActiveTexture" :uint #x84C0 :void)
             (cffi:foreign-funcall "glBindSampler" :uint 0 :uint 0 :void)
             (cffi:foreign-funcall "glBindTexture" :uint #x0DE1 :uint (cffi:mem-ref texture :uint) :void)
             (cffi:foreign-funcall "glBindBuffer" :uint #x88EC :uint 0 :void)
             (cffi:foreign-funcall "glTexImage2D" :uint #x0DE1 :int 0 :int #x8058
                                   :int width :int height :int 0 :uint #x1908 :uint #x1401
                                   :pointer (cffi:null-pointer) :void)
             (cffi:foreign-funcall "glBindFramebuffer" :uint #x8D40 :uint (cffi:mem-ref framebuffer :uint) :void)
             (cffi:foreign-funcall "glFramebufferTexture2D" :uint #x8D40 :uint #x8CE0 :uint #x0DE1
                                   :uint (cffi:mem-ref texture :uint) :int 0 :void)
             (unless (= #x8CD5 (cffi:foreign-funcall "glCheckFramebufferStatus" :uint #x8D40 :uint))
               (error "Window capture framebuffer is incomplete."))
             (cffi:foreign-funcall "glViewport" :int 0 :int 0 :int width :int height :void)
             (dolist (cap '(#x0C11 #x0B71 #x0B90 #x0B44 #x8C89))
               (cffi:foreign-funcall "glDisable" :uint cap :void))
             (cffi:foreign-funcall "glColorMask" :uchar 1 :uchar 1 :uchar 1 :uchar 1 :void)
             ;; An opaque neutral backing preserves premultiplied client alpha.
             (cffi:foreign-funcall "glClearColor" :float .035 :float .04 :float .05 :float 1.0 :void)
             (cffi:foreign-funcall "glClear" :uint #x4000 :void)
             (cffi:foreign-funcall "glEnable" :uint #x0BE2 :void)
             (cffi:foreign-funcall "glBlendEquation" :uint #x8006 :void)
             (cffi:foreign-funcall "glBlendFunc" :uint 1 :uint #x0303 :void)
             (loop for surface across (ataxia.kernel:drawable-surfaces (canvas-window-application window)) do
               (let* ((x (- (ataxia.kernel:drawable-surface-local-x surface) left))
                      (y (- (ataxia.kernel:drawable-surface-local-y surface) top))
                      (w (ataxia.kernel:drawable-surface-width surface))
                      (h (ataxia.kernel:drawable-surface-height surface))
                      (positions
                        (mapcar (lambda (point)
                                  (cons (- (* 2d0 (/ (car point) logical-width)) 1d0)
                                        (- (* 2d0 (/ (cdr point) logical-height)) 1d0)))
                                (list (cons x y) (cons (+ x w) y)
                                      (cons x (+ y h)) (cons (+ x w) (+ y h))))))
                 (%draw-surface-quad (%world-renderer world) surface positions width height 1d0 0d0 0d0)))
             (cffi:foreign-funcall "glBindBuffer" :uint #x88EB :uint 0 :void)
             (dolist (store '((#x0D05 . 1) (#x0D02 . 0) (#x0D04 . 0) (#x0D03 . 0)))
               (cffi:foreign-funcall "glPixelStorei" :uint (car store) :int (cdr store) :void))
             (sb-sys:with-pinned-objects (pixels)
               (cffi:foreign-funcall "glReadPixels" :int 0 :int 0 :int width :int height
                                     :uint #x1908 :uint #x1401 :pointer (sb-sys:vector-sap pixels) :void))
             (ataxia.world.gles:gles-check-error "agent window capture"))
        (cffi:foreign-funcall "glDeleteVertexArrays" :int 1 :pointer vao :void)
        (cffi:foreign-funcall "glDeleteFramebuffers" :int 1 :pointer framebuffer :void)
        (cffi:foreign-funcall "glDeleteTextures" :int 1 :pointer texture :void)))))


(defmethod ataxia.world:capture-window-pixels
    ((world infinite-world) window bounds width height pixels)
  (%call-with-window-capture-state
   world (lambda () (%render-window-capture-pixels world window bounds width height pixels))))
