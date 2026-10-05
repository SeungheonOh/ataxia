;;;; Pointer cursors.
;;;;
;;;; Over a client the pointer shows the cursor that client set, or nothing when
;;;; it hid it. Everywhere else the director chooses: a node's `cursor`, which its
;;;; children inherit, or the shape of a native move or resize. Shapes come from
;;;; the XCURSOR_THEME at XCURSOR_SIZE, falling back to a drawn arrow.

(in-package #:ataxia.stage-world)

(cffi:define-foreign-library libxcursor (t (:or "libXcursor.so.1" "libXcursor.so")))

(cffi:defcstruct xcursor-image
  (version :uint32) (size :uint32) (width :uint32) (height :uint32)
  (xhot :uint32) (yhot :uint32) (delay :uint32) (pixels :pointer))

(defvar *xcursor* :unloaded "Whether libXcursor loaded, once anything asked.")

(defparameter +cursor-names+
  '((:default "default" "left_ptr") (:pointer "pointer" "hand2") (:text "text" "xterm")
    (:crosshair "crosshair" "cross") (:move "move" "fleur") (:grab "grab" "openhand")
    (:grabbing "grabbing" "closedhand" "fleur") (:not-allowed "not-allowed" "crossed_circle")
    (:help "help" "question_arrow") (:wait "wait" "watch") (:progress "progress" "left_ptr_watch")
    (:zoom-in "zoom-in") (:zoom-out "zoom-out")
    (:ew-resize "ew-resize" "sb_h_double_arrow") (:ns-resize "ns-resize" "sb_v_double_arrow")
    (:nwse-resize "nwse-resize" "bd_double_arrow") (:nesw-resize "nesw-resize" "fd_double_arrow"))
  "Cursor shapes and the theme names that may hold each, preferred first.")

(defstruct (theme-cursor (:constructor %make-theme-cursor))
  ;; Logical size and hotspot, and the BGRA pixels behind them.
  (width 0d0 :type double-float :read-only t)
  (height 0d0 :type double-float :read-only t)
  (hot-x 0d0 :type double-float :read-only t)
  (hot-y 0d0 :type double-float :read-only t)
  (pixel-width 0 :type fixnum :read-only t)
  (pixel-height 0 :type fixnum :read-only t)
  (pixels nil :read-only t))

(defvar *cursor-size* nil)

(defun %cursor-size ()
  "Logical cursor size: XCURSOR_SIZE, read once, or 24."
  (or *cursor-size*
      (setf *cursor-size*
            (let ((size (ignore-errors (parse-integer (uiop:getenv "XCURSOR_SIZE")))))
              (if (and size (<= 8 size 256)) size 24)))))

(defun %load-theme-cursor (shape pixel-size)
  "SHAPE from the cursor theme at the size nearest PIXEL-SIZE, or NIL."
  (when (eq *xcursor* :unloaded)
    (setf *xcursor* (and (ignore-errors (cffi:load-foreign-library 'libxcursor)) t)))
  (when *xcursor*
    (loop for name in (rest (assoc shape +cursor-names+))
          for image = (cffi:foreign-funcall "XcursorLibraryLoadImage"
                                            :string name
                                            :string (or (uiop:getenv "XCURSOR_THEME") (cffi:null-pointer))
                                            :int pixel-size :pointer)
          unless (cffi:null-pointer-p image)
            return (unwind-protect
                        (cffi:with-foreign-slots ((size width height xhot yhot pixels) image
                                                  (:struct xcursor-image))
                          (let ((factor (float (/ (%cursor-size) (max 1 size)) 1d0))
                                (octets (make-array (* width height 4) :element-type '(unsigned-byte 8))))
                            ;; ARGB words are BGRA bytes on little-endian machines.
                            (sb-sys:with-pinned-objects (octets)
                              (cffi:foreign-funcall "memcpy" :pointer (sb-sys:vector-sap octets)
                                                    :pointer pixels :size (length octets) :pointer))
                            (%make-theme-cursor :width (* factor width) :height (* factor height)
                                                :hot-x (* factor xhot) :hot-y (* factor yhot)
                                                :pixel-width width :pixel-height height
                                                :pixels octets)))
                     (cffi:foreign-funcall "XcursorImageDestroy" :pointer image :void)))))

(defun %theme-cursor (world shape pixel-size)
  (let ((key (cons shape pixel-size))
        (cache (%cursor-images world)))
    (multiple-value-bind (cursor found-p) (gethash key cache)
      (if found-p
          cursor
          (setf (gethash key cache) (%load-theme-cursor shape pixel-size))))))

;;; Shapes.

(defun %node-cursor (node)
  (loop for current = node then (stage-node-parent current)
        while current
        do (let ((shape (node-prop current :cursor)))
             (when shape (return shape)))
        finally (return :default)))

(defun %edge-cursor (edges)
  "Resize shape for xdg_toplevel EDGES: top 1, bottom 2, left 4, right 8."
  (case edges
    ((5 10) :nwse-resize)
    ((6 9) :nesw-resize)
    ((1 2) :ns-resize)
    (t :ew-resize)))

(defun %cursor-shape (seat-state)
  "The shape SEAT-STATE's pointer shows, or :CLIENT for the cursor its client set."
  (let ((manipulation (stage-seat-manipulation seat-state))
        (client-hit (or (%client-grab seat-state) (stage-seat-hovered seat-state))))
    (cond (manipulation
           (if (eq (manipulation-kind manipulation) :resize)
               (%edge-cursor (manipulation-edges manipulation))
               :grabbing))
          ((stage-seat-capture seat-state) (%node-cursor (stage-seat-capture seat-state)))
          ((and client-hit (stage-seat-cursor-set-p seat-state)) :client)
          (client-hit (%node-cursor (hit-node client-hit)))
          (t (%node-cursor (stage-seat-entered seat-state))))))

;;; Drawing.

(defun %emit-theme-cursor (context key shape x y transform)
  "Emit SHAPE with its hotspot at logical (X, Y); NIL when the theme lacks it."
  (let* ((stage-output (display-context-stage-output context))
         (pixel-size (max 1 (round (* (%cursor-size)
                                      (ataxia.kernel:output-scale (stage-output-output stage-output))))))
         (cursor (%theme-cursor (display-context-world context) shape pixel-size)))
    (when cursor
      (let ((local (affine-multiply transform (affine-translation (- x (theme-cursor-hot-x cursor))
                                                                  (- y (theme-cursor-hot-y cursor)))))
            (width (theme-cursor-width cursor))
            (height (theme-cursor-height cursor))
            (slot (list :cursor shape pixel-size)))
        (%emit context key (affine-rectangle-bounds local 0 0 width height 1)
               (list slot local)
               (lambda (renderer)
                 (let ((raster (renderer-raster
                                renderer slot t 60d0
                                (lambda (upload)
                                  (let ((pixels (theme-cursor-pixels cursor)))
                                    (sb-sys:with-pinned-objects (pixels)
                                      (funcall upload (sb-sys:vector-sap pixels)
                                               (theme-cursor-pixel-width cursor)
                                               (theme-cursor-pixel-height cursor) +gl-bgra+)))))))
                   (when raster
                     (draw-stage-raster renderer local raster 0d0 0d0 width height
                                        +full-texture-uv+ 0d0 1d0)))))
        t))))

(defun %emit-arrow (context key x y transform)
  (flet ((triangle (points)
           (mapcar (lambda (point)
                     (multiple-value-bind (px py) (affine-apply transform (+ x (car point)) (+ y (cdr point)))
                       (cons px py)))
                   points)))
    (let ((outline (triangle '((-1.5d0 . -2.5d0) (-1.5d0 . 22d0) (16.5d0 . 15.5d0))))
          (fill (triangle '((0d0 . 0d0) (0d0 . 18.5d0) (13d0 . 13.5d0)))))
      (%emit context key (affine-rectangle-bounds transform (- x 3) (- y 4) 22 28 1)
             (list outline fill)
             (lambda (renderer)
               (draw-stage-solid renderer outline #(0.02d0 0.02d0 0.025d0 0.9d0))
               (draw-stage-solid renderer fill #(1d0 1d0 1d0 1d0)))))))

(defun %emit-cursor (context seat-state)
  (let* ((stage-output (display-context-stage-output context))
         (transform (display-context-screen context))
         (x (- (stage-seat-x seat-state) (stage-output-offset stage-output)))
         (y (stage-seat-y seat-state))
         (seat (stage-seat-seat seat-state))
         (key (list :cursor (ataxia.kernel:object-id seat)))
         (icon (ataxia.kernel:seat-drag-icon seat))
         (shape (%cursor-shape seat-state)))
    (when icon
      (%emit-surfaces-at context (list :drag (ataxia.kernel:object-id seat)) icon x y transform))
    (case shape
      (:none)
      (:client
       (let ((cursor (stage-seat-cursor seat-state)))
         (when (and cursor (eq (ataxia.kernel:object-state cursor) :live))
           (%emit-surfaces-at context key cursor (- x (stage-seat-cursor-x seat-state))
                              (- y (stage-seat-cursor-y seat-state)) transform))))
      (t (unless (or (%emit-theme-cursor context key shape x y transform)
                     (%emit-theme-cursor context key :default x y transform))
           (%emit-arrow context key x y transform))))))
