;;;; Pixels of what Stage shows: window and output captures for screen sharing,
;;;; the desktop protocol and the director's screenshots.
;;;;
;;;; Everything renders into offscreen targets through the EGL context, so a
;;;; capture never forces an output frame. A screenshot leaves the compositor as
;;;; raw RGBA in a private file; the director encodes it, keeping compression off
;;;; the owner thread.

(in-package #:ataxia.stage-world)

(defparameter +capture-limit+ 8192 "Largest screenshot side, in pixels.")

(defun fit-size (width height limit-width limit-height)
  "WIDTH x HEIGHT scaled down, keeping its aspect, to fit LIMIT-WIDTH x LIMIT-HEIGHT."
  (let ((factor (min 1d0 (/ limit-width (max 1 width)) (/ limit-height (max 1 height)))))
    (values (max 1 (round (* factor width))) (max 1 (round (* factor height))))))

(defun fitted-target (target width height)
  "TARGET when it is WIDTH x HEIGHT, else a new target of that size in its place."
  (if (and target (= width (render-target-width target)) (= height (render-target-height target)))
      target
      (progn (destroy-render-target target) (make-render-target width height))))

(defun %region-or-all (output region)
  "REGION, output-logical (X Y WIDTH HEIGHT), or the whole of OUTPUT."
  (or region
      (multiple-value-bind (width height) (ataxia.world:output-logical-size (stage-output-output output))
        (list 0d0 0d0 width height))))

(defun screen-source (output region)
  "Layout position and pixel size of OUTPUT's REGION, by default all of it."
  (multiple-value-bind (logical-width logical-height)
      (ataxia.world:output-logical-size (stage-output-output output))
    (destructuring-bind (x y width height) (%region-or-all output region)
      (unless (and (<= 0 x) (<= 0 y) (>= width 8) (>= height 8)
                   (<= (+ x width) (+ logical-width 1d-6)) (<= (+ y height) (+ logical-height 1d-6)))
        (protocol-error "The region lies outside output ~A." (%output-name output)))
      (let ((scale (ataxia.kernel:output-scale (stage-output-output output))))
        (values (round (+ (stage-output-offset output) x)) (round y)
                (round (* width scale)) (round (* height scale)))))))

(defun %window-scale (window)
  (reduce #'max (stage-window-outputs window) :key #'ataxia.kernel:output-scale :initial-value 1))

(defun source-pixels (window output region)
  "Layout position and pixel size of WINDOW at the scale it is shown at, or of
OUTPUT's REGION, by default all of it."
  (if window
      (multiple-value-bind (x y width height) (%window-bounds window)
        (declare (ignore x y))
        (let ((scale (%window-scale window)))
          (values 0 0 (round (* scale width)) (round (* scale height)))))
      (screen-source output region)))

(defun draw-window-capture (renderer window bounds width height)
  "Draw WINDOW's application-local BOUNDS over the bound WIDTH x HEIGHT target, top row first."
  (destructuring-bind (left top logical-width logical-height) bounds
    (let ((sx (/ width logical-width)) (sy (/ height logical-height)))
      (begin-stage-frame renderer width height)
      (set-stage-scissor renderer 0 0 width height)
      (ataxia.world.gles:gles-clear 0.035d0 0.04d0 0.05d0 1d0)
      (loop with transform = (make-affine sx 0 0 sy (- (* left sx)) (- (* top sy)))
            for surface across (ataxia.kernel:drawable-surfaces (stage-window-application window))
            do (draw-stage-surface renderer transform surface
                                   (ataxia.kernel:drawable-surface-local-x surface)
                                   (ataxia.kernel:drawable-surface-local-y surface)
                                   (ataxia.kernel:drawable-surface-width surface)
                                   (ataxia.kernel:drawable-surface-height surface)
                                   0 0 0d0 1d0))
      (finish-stage-frame))))

(defun read-window-pixels (world window bounds width height pixels target)
  "Read WINDOW's BOUNDS scaled to WIDTH x HEIGHT into PIXELS through TARGET."
  (call-with-render-target target
                           (lambda ()
                             (draw-window-capture (%renderer world) window bounds width height)
                             (gl-read-pixels width height pixels))))

(defun read-output-pixels (world stage-output region width height pixels full target)
  "Render STAGE-OUTPUT's REGION (output-logical X Y WIDTH HEIGHT, or all of it) as it
presents now into FULL, a target of the output's buffer size, then read it scaled to
WIDTH x HEIGHT into PIXELS through TARGET."
  (let ((renderer (%renderer world))
        (buffer-width (stage-output-buffer-width stage-output))
        (buffer-height (stage-output-buffer-height stage-output))
        (buffer (%buffer-transform stage-output)))
    (%refresh-display world stage-output)
    (destructuring-bind (x y region-width region-height) (%region-or-all stage-output region)
      (let ((items (first (stage-output-display stage-output))))
        (call-with-render-target
         full (lambda ()
                (begin-stage-frame renderer buffer-width buffer-height)
                ;; Only the region and what its blurs sample are drawn.
                (%draw-items renderer (list items (build-seat-items world stage-output))
                             (%blur-passes (list (affine-rectangle-bounds buffer x y region-width
                                                                          region-height))
                                           items buffer-width buffer-height)
                             buffer-width buffer-height nil)
                (finish-stage-frame))))
      ;; Corner UVs follow the output transform, so the capture stays upright.
      (call-with-render-target
       target (lambda ()
                (begin-stage-frame renderer width height)
                (set-stage-scissor renderer 0 0 width height)
                (ataxia.world.gles:gles-clear 0d0 0d0 0d0 1d0)
                (draw-stage-texture
                 renderer +identity-affine+ +gl-texture-2d+ (render-target-texture full) t
                 buffer-width buffer-height
                 (coerce (loop for (cx cy) in (list (list x y) (list (+ x region-width) y)
                                                    (list x (+ y region-height))
                                                    (list (+ x region-width) (+ y region-height)))
                               nconc (multiple-value-bind (bx by) (affine-apply buffer cx cy)
                                       (list (/ bx buffer-width) (/ by buffer-height))))
                         'vector)
                 0d0 0d0 width height 0d0 0d0 0d0 1d0)
                (finish-stage-frame)
                (gl-read-pixels width height pixels))))))

;;; Screenshots.

(defun %capture-path (id)
  (namestring (merge-pathnames (format nil "ataxia-stage-~D-capture-~D.rgba" (sb-posix:getpid) id)
                               (uiop:ensure-directory-pathname (uiop:getenv "XDG_RUNTIME_DIR")))))

(defun capture-for-director (world id &key window output region)
  "Write WINDOW, or OUTPUT's REGION, at full resolution to a private file and tell
the director where; the director owns the file from then on."
  (handler-case
      (progn
        (unless (%renderer world) (protocol-error "Stage World has no graphics."))
        (multiple-value-bind (x y source-width source-height) (source-pixels window output region)
          (declare (ignore x y))
          (multiple-value-bind (width height)
              (fit-size source-width source-height +capture-limit+ +capture-limit+)
            (let ((pixels (make-array (* width height 4) :element-type '(unsigned-byte 8)))
                  (path (%capture-path id)))
              (%call-with-gl
               world
               (lambda ()
                 (let ((target nil) (full nil))
                   (unwind-protect
                        (progn
                          (setf target (make-render-target width height))
                          (if window
                              (read-window-pixels world window (multiple-value-list (%window-bounds window))
                                                  width height pixels target)
                              (progn
                                (setf full (make-render-target (stage-output-buffer-width output)
                                                               (stage-output-buffer-height output)))
                                (read-output-pixels world output region width height pixels full target))))
                     (destroy-render-target target)
                     (destroy-render-target full)))))
              (with-open-file (file path :direction :output :element-type '(unsigned-byte 8)
                                         :if-exists :supersede)
                (write-sequence pixels file))
              (%send world (list :type "captured" :id id :path path :width width :height height))))))
    (error (cause)
      (%send world (list :type "captured" :id id :error (princ-to-string cause))))))
