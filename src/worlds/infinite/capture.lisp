;;;; Shared offscreen capture backend for computer use and screen sharing.
(in-package #:ataxia.infinite-world)

(defmethod ataxia.world:world-supports-p :around ((world infinite-world) capability)
  (or (eq capability :window-capture) (call-next-method)))

(defun %gl-integers (parameter count)
  (cffi:with-foreign-object (buffer :int count)
    (cffi:foreign-funcall "glGetIntegerv" :uint parameter :pointer buffer :void)
    (loop for index below count collect (cffi:mem-aref buffer :int index))))

(defun %gl-integer (parameter)
  (first (%gl-integers parameter 1)))

(defparameter +capture-capabilities+ '(#x0BE2 #x0C11 #x0B71 #x0B90 #x0B44 #x8C89)
  "Blend, scissor, depth, stencil, face culling and rasterizer discard.")

(defparameter +capture-pixel-stores+ '(#x0D05 #x0D02 #x0D04 #x0D03)
  "Pack alignment, row length, skipped pixels and skipped rows.")

(defun %call-with-window-capture-state (world function)
  "Call FUNCTION, which renders a capture offscreen and reads it back, then put back
the GL state it changes, so the compositor's next frame finds its context as it was."
  (let ((external-p (%canvas-renderer-external-program (%world-renderer world)))
        (active (%gl-integer #x84E0))
        (draw-framebuffer (%gl-integer #x8CA6)) (read-framebuffer (%gl-integer #x8CAA))
        (program (%gl-integer #x8B8D)) (vertex-array (%gl-integer #x85B5))
        (array (%gl-integer #x8894)) (pack (%gl-integer #x88ED)) (unpack (%gl-integer #x88EF))
        (viewport (%gl-integers #x0BA2 4))
        ;; Equations for color and alpha, then source and destination factors for each.
        (blend (mapcar #'%gl-integer '(#x8009 #x883D #x80C9 #x80C8 #x80CB #x80CA)))
        (stores (mapcar #'%gl-integer +capture-pixel-stores+))
        (enabled (mapcar (lambda (capability)
                           (plusp (cffi:foreign-funcall "glIsEnabled" :uint capability :uchar)))
                         +capture-capabilities+))
        (clear (cffi:with-foreign-object (color :float 4)
                 (cffi:foreign-funcall "glGetFloatv" :uint #x0C22 :pointer color :void)
                 (loop for index below 4 collect (cffi:mem-aref color :float index))))
        (mask (cffi:with-foreign-object (mask :uchar 4)
                (cffi:foreign-funcall "glGetBooleanv" :uint #x0C23 :pointer mask :void)
                (loop for index below 4 collect (cffi:mem-aref mask :uchar index))))
        texture sampler external)
    ;; Capture draws through texture unit 0, possibly from an external client texture.
    (cffi:foreign-funcall "glActiveTexture" :uint #x84C0 :void)
    (setf texture (%gl-integer #x8069)
          sampler (%gl-integer #x8919)
          external (and external-p (%gl-integer #x8D67)))
    (unwind-protect (funcall function)
      (cffi:foreign-funcall "glBindFramebuffer" :uint #x8CA9 :uint draw-framebuffer :void)
      (cffi:foreign-funcall "glBindFramebuffer" :uint #x8CA8 :uint read-framebuffer :void)
      (cffi:foreign-funcall "glUseProgram" :uint program :void)
      (cffi:foreign-funcall "glBindVertexArray" :uint vertex-array :void)
      (cffi:foreign-funcall "glBindBuffer" :uint #x8892 :uint array :void)
      (cffi:foreign-funcall "glBindBuffer" :uint #x88EB :uint pack :void)
      (cffi:foreign-funcall "glBindBuffer" :uint #x88EC :uint unpack :void)
      (cffi:foreign-funcall "glActiveTexture" :uint #x84C0 :void)
      (cffi:foreign-funcall "glBindTexture" :uint #x0DE1 :uint texture :void)
      (when external (cffi:foreign-funcall "glBindTexture" :uint #x8D65 :uint external :void))
      (cffi:foreign-funcall "glBindSampler" :uint 0 :uint sampler :void)
      (cffi:foreign-funcall "glActiveTexture" :uint active :void)
      (loop for parameter in +capture-pixel-stores+ for value in stores
            do (cffi:foreign-funcall "glPixelStorei" :uint parameter :int value :void))
      (destructuring-bind (x y width height) viewport
        (cffi:foreign-funcall "glViewport" :int x :int y :int width :int height :void))
      (destructuring-bind (red green blue alpha) clear
        (cffi:foreign-funcall "glClearColor" :float red :float green :float blue :float alpha :void))
      (destructuring-bind (red green blue alpha) mask
        (cffi:foreign-funcall "glColorMask" :uchar red :uchar green :uchar blue :uchar alpha :void))
      (destructuring-bind (color-equation alpha-equation color-source color-destination
                           alpha-source alpha-destination)
          blend
        (cffi:foreign-funcall "glBlendEquationSeparate" :uint color-equation :uint alpha-equation :void)
        (cffi:foreign-funcall "glBlendFuncSeparate" :uint color-source :uint color-destination
                                                    :uint alpha-source :uint alpha-destination :void))
      (loop for capability in +capture-capabilities+ for enabled-p in enabled
            do (if enabled-p
                   (cffi:foreign-funcall "glEnable" :uint capability :void)
                   (cffi:foreign-funcall "glDisable" :uint capability :void))))))
(defun %render-capture-pixels (width height pixels draw)
  "Draw into an isolated target. Caller preserves the compositor's GL state."
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
             (funcall draw)
             (cffi:foreign-funcall "glBindBuffer" :uint #x88EB :uint 0 :void)
             (dolist (store '((#x0D05 . 1) (#x0D02 . 0) (#x0D04 . 0) (#x0D03 . 0)))
               (cffi:foreign-funcall "glPixelStorei" :uint (car store) :int (cdr store) :void))
             (sb-sys:with-pinned-objects (pixels)
               (cffi:foreign-funcall "glReadPixels" :int 0 :int 0 :int width :int height
                                     :uint #x1908 :uint #x1401 :pointer (sb-sys:vector-sap pixels) :void))
             (ataxia.world.gles:gles-check-error "agent window capture"))
        (cffi:foreign-funcall "glDeleteVertexArrays" :int 1 :pointer vao :void)
        (cffi:foreign-funcall "glDeleteFramebuffers" :int 1 :pointer framebuffer :void)
        (cffi:foreign-funcall "glDeleteTextures" :int 1 :pointer texture :void))))

(defun %draw-captured-surface (world surface x y w h logical-width logical-height width height &optional (rotation 0d0))
  (let ((positions
          (mapcar (lambda (point)
                    (let ((px (- (* (cos rotation) (car point)) (* (sin rotation) (cdr point))))
                          (py (+ (* (sin rotation) (car point)) (* (cos rotation) (cdr point)))))
                      (cons (- (* 2d0 (/ px logical-width)) 1d0)
                            (- (* 2d0 (/ py logical-height)) 1d0))))
                  (list (cons x y) (cons (+ x w) y) (cons x (+ y h)) (cons (+ x w) (+ y h))))))
    (%draw-surface-quad (%world-renderer world) surface positions width height 1d0 0d0 0d0)))

(defun %render-window-capture-pixels (world window bounds width height pixels)
  (destructuring-bind (left top logical-width logical-height) bounds
    (%render-capture-pixels width height pixels
      (lambda ()
        (loop for surface across (ataxia.kernel:drawable-surfaces (canvas-window-application window)) do
          (%draw-captured-surface world surface
            (- (ataxia.kernel:drawable-surface-local-x surface) left)
            (- (ataxia.kernel:drawable-surface-local-y surface) top)
            (ataxia.kernel:drawable-surface-width surface) (ataxia.kernel:drawable-surface-height surface)
            logical-width logical-height width height))))))

(defgeneric %map-region-widgets (world function)
  (:documentation "Visit spatial content only; consent UI and shell chrome are excluded.")
  (:method (world function) (declare (ignore world function))))

(defun %draw-captured-widget (world component x y width height left top logical-width logical-height pixel-width pixel-height rotation)
  (multiple-value-bind (rx ry rw rh) (ataxia.kernel:drawable-local-bounds component)
    (when (and (plusp rw) (plusp rh))
      (loop for surface across (ataxia.kernel:drawable-surfaces component) do
        (%draw-captured-surface world surface
          (+ (- x left) (* width (/ (- (ataxia.kernel:drawable-surface-local-x surface) rx) rw)))
          (+ (- y top) (* height (/ (- (ataxia.kernel:drawable-surface-local-y surface) ry) rh)))
          (* width (/ (ataxia.kernel:drawable-surface-width surface) rw))
          (* height (/ (ataxia.kernel:drawable-surface-height surface) rh))
          logical-width logical-height pixel-width pixel-height rotation)))))

(defun %capture-canvas-region (world bounds width height pixels &optional (rotation 0d0))
  "Capture a fixed oriented world rectangle; exclude private shell overlays."
  (destructuring-bind (left top logical-width logical-height) bounds
    (let ((projection (%make-canvas-output nil)))
      (setf (%canvas-output-camera-x projection) (coerce left 'double-float)
            (%canvas-output-camera-y projection) (coerce top 'double-float))
      (%call-with-window-capture-state world
        (lambda ()
          (%render-capture-pixels width height pixels
            (lambda ()
              ;; Stacking is back-to-front, just like the desktop paint plan.
              (dolist (window (%world-stacking world))
                (when (%window-visible-p window)
                  (%map-window-surfaces projection window
                    (lambda (surface x y w h)
                      (%draw-captured-surface world surface x y w h logical-width logical-height width height rotation)))))
              (%map-region-widgets world
                (lambda (component x y w h)
                  (%draw-captured-widget world component x y w h left top logical-width logical-height width height rotation))))))))))

(defmethod ataxia.world:capture-window-pixels
    ((world infinite-world) window bounds width height pixels)
  (%call-with-window-capture-state
   world (lambda () (%render-window-capture-pixels world window bounds width height pixels))))
