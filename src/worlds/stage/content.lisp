;;;; Text and image nodes.
;;;;
;;;; A text node measures again only when a layout property changes, and keeps
;;;; one raster per output, re-rendered when its text, color or raster scale
;;;; changes. While its on-screen scale changes from frame to frame the raster
;;;; scale snaps to half-octave steps; the first still frame renders it exactly.
;;;; Images are shared by path, decode off the owner thread, and release their
;;;; textures a while after they were last on screen.

(in-package #:ataxia.stage-world)

(defparameter +image-lifetime+ 30d0
  "Seconds an image texture outlives its last appearance on screen.")

;;; Text.

(defstruct (text-layout (:constructor %make-text-layout (style metrics revision)))
  (style nil :read-only t)
  (metrics nil :read-only t)
  ;; Distinguishes layouts in EQUALP signatures, which ignore letter case.
  (revision 0 :type fixnum :read-only t)
  ;; The node's prop revision and declared width it was last found current for.
  (prop-revision -1 :type fixnum)
  (width nil))

(defvar *text-revision* 0)

(defun %text-style-equal (left right)
  ;; EQUALP ignores letter case, so the text itself is compared exactly.
  (and (string= (text-style-text left) (text-style-text right)) (equalp left right)))

(defun node-text-layout (node)
  "NODE's text layout, measured again only after its style changed; NIL without Pango.
Asked several times a frame, it rebuilds the style only after a declaration or a
change of width, which alone animates."
  (let ((cached (stage-node-cache node))
        (width (and (node-declared-p node :width) (node-number node :width))))
    (if (and cached (= (text-layout-prop-revision cached) (stage-node-prop-revision node))
             (eql (text-layout-width cached) width))
        cached
        (let* ((style (node-text-style node))
               (layout (if (and cached (%text-style-equal style (text-layout-style cached)))
                           cached
                           (let ((metrics (measure-text style)))
                             (setf (stage-node-cache node)
                                   (and metrics (%make-text-layout style metrics (incf *text-revision*))))))))
          (when layout
            (setf (text-layout-prop-revision layout) (stage-node-prop-revision node)
                  (text-layout-width layout) width))
          layout))))

(defun text-node-size (node)
  (let ((layout (node-text-layout node)))
    (if layout
        (values (or (text-style-width (text-layout-style layout))
                    (text-metrics-width (text-layout-metrics layout)))
                (text-metrics-height (text-layout-metrics layout)))
        (values 0d0 0d0))))

(defun %text-color (node opacity)
  "Straight-alpha text color; undeclared text is black, as in CSS."
  (multiple-value-bind (red green blue alpha)
      (if (or (node-declared-p node :color) (gethash :color (stage-node-channels node)))
          (node-color node :color)
          (values 0d0 0d0 0d0 1d0))
    (values (vector red green blue alpha) (* alpha opacity))))

(defun %scale-change (context node scale)
  "NODE's on-screen SCALE quantized, and whether it changed since the last rendered
frame. A change asks for a refining frame, which sees the scale settled."
  (let* ((exact (max 0.0625d0 (/ (fround (* scale 32)) 32)))
         (scales (display-context-raster-scales context))
         (previous (and scales (gethash (stage-node-id node)
                                        (stage-output-raster-scales
                                         (display-context-stage-output context)))))
         (changing-p (and previous (/= previous exact))))
    (when scales (setf (gethash (stage-node-id node) scales) exact))
    (when changing-p (setf (display-context-refine-p context) t))
    (values exact changing-p)))

(defun %raster-scale (context node scale width height)
  "Raster scale for a text node drawn at SCALE device pixels per logical pixel."
  (multiple-value-bind (exact changing-p) (%scale-change context node scale)
    (min (/ *max-raster-pixels* (max 1d0 width height))
         (if changing-p
             ;; Half-octave steps above the exact scale: a zoom re-renders a few
             ;; times instead of every frame, and never upsamples.
             (expt 2d0 (/ (ceiling (* 2 (log exact 2))) 2))
             exact))))

(defun %touch-raster (world slot)
  (let* ((renderer (%renderer world))
         (raster (and renderer (gethash slot (stage-renderer-rasters renderer)))))
    (when raster (setf (raster-used raster) (%now)))))

(defmethod emit-content ((kind (eql :text)) context node transform opacity screen-inverse
                         parent-inverse)
  (let ((layout (node-text-layout node)))
    (when layout
      (multiple-value-bind (color alpha) (%text-color node opacity)
        (let* ((style (text-layout-style layout))
               (metrics (text-layout-metrics layout))
               (scale (transform-scale-factor
                       transform
                       (* 0.5d0 (+ (text-metrics-left metrics) (text-metrics-right metrics)))
                       (* 0.5d0 (+ (text-metrics-top metrics) (text-metrics-bottom metrics)))))
               (slot (list :text (stage-node-id node) (display-context-output-name context))))
          ;; Text scaled to nothing has no pixels, and no raster scale.
          (when (and (plusp alpha) (> scale 1d-6) (plusp (length (text-style-text style))))
            (multiple-value-bind (left top width height) (text-raster-box metrics scale)
              (let* ((raster-scale (%raster-scale context node scale width height))
                     (key (list (text-layout-revision layout) color raster-scale)))
                (%touch-raster (display-context-world context) slot)
                (%emit context (list (stage-node-id node) :text)
                       (transform-rectangle-bounds transform left top width height 1)
                       (list transform key opacity)
                       (lambda (renderer)
                         (let ((raster (%text-raster (display-context-world context) renderer slot key
                                                     style metrics color raster-scale)))
                           (when raster
                             ;; It may be one at another scale, until the worker's arrives.
                             (multiple-value-bind (left top width height)
                                 (text-raster-box metrics (third (raster-key raster)))
                               (draw-stage-raster renderer transform raster left top width height
                                                  +full-texture-uv+ 0d0 opacity))))))))))
        (when (%hit-target-p context node)
          (multiple-value-call #'%add-hit context node screen-inverse parent-inverse
            (text-node-size node)))))))

;;; Text rasters at a changing scale come from the worker: rasterizing every
;;; label again at each step of a zoom would cost frames, so until the new raster
;;; arrives the one at hand is drawn scaled. New or edited text, with nothing at
;;; hand to show, is rasterized at once.

(defun %same-text-p (key other)
  "Whether raster keys (REVISION COLOR SCALE) hold the same text at any scale."
  (and (eql (first key) (first other)) (equalp (second key) (second other))))

(defun %text-raster (world renderer slot key style metrics color scale)
  "SLOT's raster for KEY, or the one at hand while the worker renders it."
  (let ((job (gethash slot (%text-jobs world)))
        (failed-p nil))
    ;; A raster the worker finished replaces the one at hand, at whatever scale.
    (when (and job (or (text-job-surface job) (text-job-failed-p job)))
      (remhash slot (%text-jobs world))
      (setf failed-p (text-job-failed-p job))
      (when (text-job-surface job)
        (when (%same-text-p (text-job-key job) key)
          (install-raster renderer slot (text-job-key job)
                          (%cairo-image-surface-data (text-job-surface job))
                          (text-job-width job) (text-job-height job) +gl-bgra+))
        (%cairo-surface-destroy (text-job-surface job)))
      (setf job nil))
    (let ((current (slot-raster renderer slot)))
      (or (renderer-raster
           renderer slot key 2d0
           (lambda (upload)
             ;; Text only rescaled waits for the worker, as does new text once
             ;; the frame's spare time is spent. After the worker failed, the
             ;; owner tries itself and reports why.
             (if (and (not failed-p)
                      (if current
                          (%same-text-p (raster-key current) key)
                          (not (spare-time-p renderer))))
                 ;; One job a slot at a time: what it brings is closer, and the
                 ;; next draw asks for the rest.
                 (unless job
                   (let ((job (%make-text-job slot key style metrics color scale)))
                     (setf (gethash slot (%text-jobs world)) job)
                     (queue-text-raster (%worker world) job)))
                 (call-with-spare-time
                  renderer
                  (lambda ()
                    (call-with-text-raster style metrics color scale
                                           (lambda (pixels width height)
                                             (funcall upload pixels width height +gl-bgra+))))))))
          (and current (%same-text-p (raster-key current) key) current)))))

(defun %finish-text (world job surface &optional width height)
  "Take JOB's raster from the worker and repaint where its text is shown."
  (destructuring-bind (tag id output-name) (text-job-slot job)
    (declare (ignore tag))
    (if (not (eq job (gethash (text-job-slot job) (%text-jobs world))))
        (when surface (%cairo-surface-destroy surface))
        (let* ((stage-output (find output-name (%outputs world) :key #'%output-name :test #'equal))
               (item (and stage-output
                          (find-if (lambda (item) (let ((key (item-key item)))
                                                    (and (eql (second key) id) (eq (third key) :text))))
                                   (first (stage-output-display stage-output))))))
          (cond ((null item)
                 ;; The text left the screen; it rasterizes again when shown.
                 (remhash (text-job-slot job) (%text-jobs world))
                 (when surface (%cairo-surface-destroy surface)))
                (t
                 (if surface
                     (setf (text-job-surface job) surface
                           (text-job-width job) width
                           (text-job-height job) height)
                     (setf (text-job-failed-p job) t))
                 ;; Inside an effect, the effect paints it.
                 (loop while (item-owner item) do (setf item (item-owner item)))
                 (ataxia.world:damage-add-region (%damage world) (stage-output-output stage-output)
                                                 (list (item-bounds item)))
                 (%request-frames world (list stage-output))))))))

;;; Images.

(defvar *image-serial* 0)

(defun %image-loaded-p (image)
  "Whether IMAGE's natural size is known, even while its pixels are released."
  (plusp (stage-image-width image)))

(defun %drop-pixels (image)
  "Release IMAGE's decoded pixels; it decodes again when next shown."
  (when (stage-image-pixbuf image)
    (%g-object-unref (shiftf (stage-image-pixbuf image) nil)))
  (when (member (stage-image-state image) '(:decoded :ready))
    (setf (stage-image-state image) :idle)))

(defun %finish-image (world image pixbuf message width height)
  "Owner-thread completion of a decode started for IMAGE."
  (cond
    ((not (eq image (gethash (stage-image-path image) (%images world))))
     ;; Replaced while decoding, e.g. the file changed.
     (when pixbuf (%g-object-unref pixbuf)))
    (t
     (let ((first-p (zerop (stage-image-width image))))
       (setf (stage-image-pixbuf image) pixbuf
             (stage-image-error image) message
             (stage-image-state image) (if pixbuf :decoded :failed)
             (stage-image-touched image) (%now))
       (when pixbuf
         (setf (stage-image-width image) width
               (stage-image-height image) height))
       (when (or first-p (eq (stage-image-state image) :failed))
         (map-scene-nodes (lambda (node)
                            (when (eq (stage-node-cache node) image)
                              (%report-image world node image)))
                          (%scene world)))
       (%scene-changed world)))))

(defun %report-image (world node image)
  (case (stage-image-state image)
    (:failed (%emit-event world node :error :message (or (stage-image-error image) "")))
    (otherwise
     (when (%image-loaded-p image)
       (%emit-event world node :load :width (stage-image-width image)
                                     :height (stage-image-height image))))))

(defun %worker (world)
  "WORLD's media worker, started on first use."
  (or (%media-worker world)
      (setf (%media-worker world)
            (start-media-worker
             (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
             (%guarded world :stage-media
                       (lambda (job &rest result)
                         (etypecase job
                           (stage-image (apply #'%finish-image world job result))
                           (text-job (apply #'%finish-text world job result)))))))))

(defun %queue-image (world image)
  ;; Libraries load on the owner thread, so the worker only ever reads their state.
  (unless (%media-available-p 'stage-gobject 'stage-pixbuf)
    (return-from %queue-image (%finish-image world image nil "gdk-pixbuf is unavailable" 0 0)))
  (queue-image-decode (%worker world) image))

(defun %find-image (world path)
  "The shared image for PATH, decoding it again when the file changed."
  (let ((stamp (file-stamp path))
        (existing (gethash path (%images world))))
    (if (and existing (eql stamp (stage-image-stamp existing)))
        existing
        (let ((image (%make-stage-image path stamp)))
          ;; Nodes still holding the old image resolve the new one when next asked.
          (when existing (%drop-pixels existing))
          (setf (stage-image-serial image) (incf *image-serial*)
                (gethash path (%images world)) image)
          (if (uiop:absolute-pathname-p path)
              (%queue-image world image)
              (setf (stage-image-state image) :failed
                    (stage-image-error image) "src must be an absolute path"))
          image))))

(defun %node-image (world node)
  (let ((path (node-prop node :src))
        (cached (stage-node-cache node)))
    (cond ((null path) (setf (stage-node-cache node) nil))
          ((and cached (eq cached (gethash path (%images world)))) cached)
          (t (setf (stage-node-cache node) (%find-image world path))))))

(defun image-node-size (world node)
  "Declared size; a missing dimension follows the image's aspect ratio once loaded."
  (let ((width (node-number node :width))
        (height (node-number node :height))
        (image (%node-image world node)))
    (if (and image (%image-loaded-p image) (not (and width height)))
        (let ((natural-width (coerce (stage-image-width image) 'double-float))
              (natural-height (coerce (stage-image-height image) 'double-float)))
          (cond (width (values width (* width (/ natural-height natural-width))))
                (height (values (* height (/ natural-width natural-height)) height))
                (t (values natural-width natural-height))))
        (values (or width 0d0) (or height 0d0)))))

(defun refresh-media-node (world node)
  "Measure or resolve NODE after a commit, reporting results its handlers wait for."
  (let ((before (stage-node-cache node)))
    (ecase (stage-node-kind node)
      (:text
       (let ((layout (node-text-layout node)))
         (when (and layout (not (eq layout before)))
           (multiple-value-bind (width height) (text-node-size node)
             (%emit-event world node :measure :width width :height height)))))
      (:image
       (let ((image (%node-image world node)))
         (when (and image (not (eq image before))
                    (or (%image-loaded-p image) (eq (stage-image-state image) :failed)))
           (%report-image world node image)))))))

(defun %image-fit (fit image width height)
  "Local quad (X Y WIDTH HEIGHT) and corner UVs presenting IMAGE in a WIDTH x HEIGHT box."
  (let* ((natural-width (max 1d0 (coerce (stage-image-width image) 'double-float)))
         (natural-height (max 1d0 (coerce (stage-image-height image) 'double-float)))
         (scale-x (/ width natural-width))
         (scale-y (/ height natural-height)))
    (ecase fit
      (:fill (values 0d0 0d0 width height +full-texture-uv+))
      (:contain
       (let* ((scale (min scale-x scale-y))
              (quad-width (* natural-width scale))
              (quad-height (* natural-height scale)))
         (values (/ (- width quad-width) 2) (/ (- height quad-height) 2) quad-width quad-height
                 +full-texture-uv+)))
      (:cover
       (let* ((scale (max scale-x scale-y))
              (u (/ width (* natural-width scale) 2))
              (v (/ height (* natural-height scale) 2)))
         (values 0d0 0d0 width height
                 (vector (- 0.5d0 u) (- 0.5d0 v) (+ 0.5d0 u) (- 0.5d0 v)
                         (- 0.5d0 u) (+ 0.5d0 v) (+ 0.5d0 u) (+ 0.5d0 v))))))))

(defun %image-raster (renderer image)
  (let ((slot (list :image (stage-image-serial image))))
    (renderer-raster
     renderer slot (stage-image-serial image) +image-lifetime+
     (lambda (upload)
       (when (eq (stage-image-state image) :decoded)
         (let ((pixbuf (stage-image-pixbuf image)))
           (funcall upload (%pixbuf-pixels pixbuf) (%pixbuf-width pixbuf) (%pixbuf-height pixbuf)
                    +gl-rgba+)
           (%g-object-unref pixbuf)
           (setf (stage-image-pixbuf image) nil
                 (stage-image-state image) :ready)))))))

(defun %image-shown-p (world image)
  "Whether IMAGE has pixels to draw now. A released texture or pixels start a decode,
and the image appears again when it finishes."
  (let ((renderer (%renderer world)))
    (when (and (eq (stage-image-state image) :ready)
               (not (and renderer (gethash (list :image (stage-image-serial image))
                                           (stage-renderer-rasters renderer)))))
      (setf (stage-image-state image) :idle))
    (when (eq (stage-image-state image) :idle)
      (%queue-image world image))
    (member (stage-image-state image) '(:decoded :ready))))

(defun forget-unused-images (world)
  "Forget images no live or exiting node shows."
  (let ((images (%images world))
        (shown (make-hash-table :test #'eq)))
    (flet ((note (node)
             (when (eq (stage-node-kind node) :image)
               (setf (gethash (stage-node-cache node) shown) t))))
      (map-scene-nodes #'note (%scene world))
      (dolist (root (scene-exiting (%scene world)))
        (%walk-subtree root #'note)))
    (loop for path being the hash-keys of images using (hash-value image)
          unless (gethash image shown)
            do (%drop-pixels image)
               (remhash path images))))

(defun release-stale-pixels (world)
  "Release pixels decoded for images no frame has drawn for a while."
  (let ((now (%now)))
    (loop for image being the hash-values of (%images world)
          when (and (eq (stage-image-state image) :decoded)
                    (> (- now (stage-image-touched image)) +image-lifetime+))
            do (%drop-pixels image))))

(defmethod emit-content ((kind (eql :image)) context node transform opacity screen-inverse
                         parent-inverse)
  (let ((world (display-context-world context)))
    (multiple-value-bind (width height) (%node-size world node)
      (let ((image (%node-image world node))
            (radius (max 0d0 (node-number node :radius 0d0)))
            (border (max 0d0 (node-number node :border-width 0d0))))
        (when (and (plusp width) (plusp height))
          (%emit-shadow context node transform width height radius opacity)
          (%emit-backdrop-blur context node transform width height radius opacity)
          (when (and image (%image-loaded-p image) (%image-shown-p world image))
            (setf (stage-image-touched image) (%now))
            (%touch-raster world (list :image (stage-image-serial image)))
            (multiple-value-bind (x y quad-width quad-height uv)
                (%image-fit (node-prop node :fit) image width height)
              (let ((local (transform-multiply transform (transform-translation x y)))
                    (rounding (if (eq (node-prop node :fit) :contain) 0d0 radius)))
                (%emit context (list (stage-node-id node) :image)
                       (transform-rectangle-bounds local 0 0 quad-width quad-height 1)
                       (list local quad-width quad-height uv rounding opacity
                             (stage-image-serial image))
                       (lambda (renderer)
                         (let ((raster (%image-raster renderer image)))
                           (when raster
                             (draw-stage-raster renderer local raster 0d0 0d0 quad-width
                                                quad-height uv rounding opacity))))))))
          (%emit-box context node :border transform 0 0 width height radius border +clear-paint+
                     (%node-paint node :border-color :border-color-end :border-angle opacity))
          (when (%hit-target-p context node)
            (%add-hit context node screen-inverse parent-inverse width height)))))))

(defun stop-images (world)
  "Stop the worker and drop pixels not yet uploaded; textures go with the renderer."
  (stop-media-worker (%media-worker world))
  (setf (%media-worker world) nil)
  (loop for job being the hash-values of (%text-jobs world)
        when (text-job-surface job) do (%cairo-surface-destroy (text-job-surface job)))
  (clrhash (%text-jobs world))
  (loop for image being the hash-values of (%images world)
        when (stage-image-pixbuf image)
          do (%g-object-unref (stage-image-pixbuf image))
             (setf (stage-image-pixbuf image) nil))
  (clrhash (%images world)))
