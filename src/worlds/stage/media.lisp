;;;; Text layout and image decoding for scene nodes.
;;;;
;;;; Pango lays text out in logical pixels with metric hinting off, so a layout
;;;; measures the same at every zoom and only its raster scale changes. One worker
;;;; thread decodes images into premultiplied RGBA and rasterizes text whose scale
;;;; changed; the owner thread uploads the results on its next frame. The
;;;; libraries load on first use, and a system without them still presents every
;;;; other node.

(in-package #:ataxia.stage-world)

(cffi:define-foreign-library stage-gobject (t "libgobject-2.0.so.0"))
(cffi:define-foreign-library stage-cairo (t "libcairo.so.2"))
(cffi:define-foreign-library stage-pango (t "libpango-1.0.so.0"))
(cffi:define-foreign-library stage-pangocairo (t "libpangocairo-1.0.so.0"))
(cffi:define-foreign-library stage-pixbuf (t "libgdk_pixbuf-2.0.so.0"))

(defvar *media-libraries* nil
  "Library name -> :LOADED or the error text from the one failed attempt.")

(defun %media-available-p (&rest libraries)
  (every (lambda (library)
           (let ((state (getf *media-libraries* library)))
             (unless state
               (setf state (handler-case (progn (cffi:load-foreign-library library) :loaded)
                             (error (cause)
                               (%log "~(~A~) is unavailable: ~A" library cause)
                               (princ-to-string cause)))
                     (getf *media-libraries* library) state))
             (eq state :loaded)))
         libraries))

(cffi:defcfun ("g_object_unref" %g-object-unref) :void (object :pointer))
(cffi:defcfun ("g_free" %g-free) :void (memory :pointer))
(cffi:defcfun ("g_error_free" %g-error-free) :void (error :pointer))
(cffi:defcstruct g-error (domain :uint32) (code :int) (message :pointer))

(cffi:defcfun ("cairo_image_surface_create" %cairo-image-surface-create) :pointer
  (format :int) (width :int) (height :int))
(cffi:defcfun ("cairo_surface_status" %cairo-surface-status) :int (surface :pointer))
(cffi:defcfun ("cairo_surface_flush" %cairo-surface-flush) :void (surface :pointer))
(cffi:defcfun ("cairo_surface_destroy" %cairo-surface-destroy) :void (surface :pointer))
(cffi:defcfun ("cairo_image_surface_get_data" %cairo-image-surface-data) :pointer (surface :pointer))
(cffi:defcfun ("cairo_create" %cairo-create) :pointer (surface :pointer))
(cffi:defcfun ("cairo_destroy" %cairo-destroy) :void (cairo :pointer))
(cffi:defcfun ("cairo_scale" %cairo-scale) :void (cairo :pointer) (x :double) (y :double))
(cffi:defcfun ("cairo_translate" %cairo-translate) :void (cairo :pointer) (x :double) (y :double))
(cffi:defcfun ("cairo_set_source_rgba" %cairo-set-source-rgba) :void
  (cairo :pointer) (red :double) (green :double) (blue :double) (alpha :double))
(cffi:defcfun ("cairo_font_options_create" %cairo-font-options-create) :pointer)
(cffi:defcfun ("cairo_font_options_set_hint_metrics" %cairo-font-options-set-hint-metrics) :void
  (options :pointer) (value :int))
(cffi:defcfun ("cairo_font_options_set_hint_style" %cairo-font-options-set-hint-style) :void
  (options :pointer) (value :int))
(cffi:defcfun ("cairo_font_options_set_antialias" %cairo-font-options-set-antialias) :void
  (options :pointer) (value :int))
(cffi:defcfun ("cairo_font_options_destroy" %cairo-font-options-destroy) :void (options :pointer))

(cffi:defcfun ("pango_cairo_font_map_new" %pango-cairo-font-map-new) :pointer)
(cffi:defcfun ("pango_font_map_create_context" %pango-font-map-create-context) :pointer
  (font-map :pointer))
(cffi:defcfun ("pango_cairo_context_set_font_options" %pango-cairo-context-set-font-options) :void
  (context :pointer) (options :pointer))
(cffi:defcfun ("pango_context_set_round_glyph_positions" %pango-context-set-round-glyph-positions)
    :void (context :pointer) (round :boolean))
(cffi:defcfun ("pango_cairo_show_layout" %pango-cairo-show-layout) :void
  (cairo :pointer) (layout :pointer))
(cffi:defcfun ("pango_layout_new" %pango-layout-new) :pointer (context :pointer))
(cffi:defcfun ("pango_layout_set_text" %pango-layout-set-text) :void
  (layout :pointer) (text :string) (length :int))
(cffi:defcfun ("pango_layout_set_attributes" %pango-layout-set-attributes) :void
  (layout :pointer) (attributes :pointer))
(cffi:defcfun ("pango_attr_list_unref" %pango-attr-list-unref) :void (attributes :pointer))
(cffi:defcfun ("pango_parse_markup" %pango-parse-markup) :boolean
  (markup :string) (length :int) (accelerator :uint32) (attributes :pointer) (text :pointer)
  (accelerator-char :pointer) (error :pointer))
(cffi:defcfun ("pango_layout_set_font_description" %pango-layout-set-font-description) :void
  (layout :pointer) (description :pointer))
(cffi:defcfun ("pango_layout_set_width" %pango-layout-set-width) :void (layout :pointer) (width :int))
(cffi:defcfun ("pango_layout_set_height" %pango-layout-set-height) :void (layout :pointer) (height :int))
(cffi:defcfun ("pango_layout_set_wrap" %pango-layout-set-wrap) :void (layout :pointer) (wrap :int))
(cffi:defcfun ("pango_layout_set_ellipsize" %pango-layout-set-ellipsize) :void
  (layout :pointer) (mode :int))
(cffi:defcfun ("pango_layout_set_alignment" %pango-layout-set-alignment) :void
  (layout :pointer) (alignment :int))
(cffi:defcfun ("pango_layout_set_spacing" %pango-layout-set-spacing) :void
  (layout :pointer) (spacing :int))
(cffi:defcfun ("pango_layout_get_line_count" %pango-layout-line-count) :int (layout :pointer))
(cffi:defcfun ("pango_layout_get_extents" %pango-layout-get-extents) :void
  (layout :pointer) (ink :pointer) (logical :pointer))
(cffi:defcfun ("pango_font_description_new" %pango-font-description-new) :pointer)
(cffi:defcfun ("pango_font_description_free" %pango-font-description-free) :void (description :pointer))
(cffi:defcfun ("pango_font_description_set_family" %pango-font-description-set-family) :void
  (description :pointer) (family :string))
(cffi:defcfun ("pango_font_description_set_absolute_size" %pango-font-description-set-absolute-size)
    :void (description :pointer) (size :double))
(cffi:defcfun ("pango_font_description_set_weight" %pango-font-description-set-weight) :void
  (description :pointer) (weight :int))
(cffi:defcfun ("pango_font_description_set_style" %pango-font-description-set-style) :void
  (description :pointer) (style :int))

(cffi:defcstruct pango-rectangle (x :int) (y :int) (width :int) (height :int))

(cffi:defcfun ("gdk_pixbuf_get_file_info" %pixbuf-file-info) :pointer
  (path :string) (width :pointer) (height :pointer))
(cffi:defcfun ("gdk_pixbuf_format_is_scalable" %pixbuf-format-scalable-p) :boolean (format :pointer))
(cffi:defcfun ("gdk_pixbuf_new_from_file_at_scale" %pixbuf-new-at-scale) :pointer
  (path :string) (width :int) (height :int) (preserve-aspect :boolean) (error :pointer))
(cffi:defcfun ("gdk_pixbuf_apply_embedded_orientation" %pixbuf-apply-orientation) :pointer
  (pixbuf :pointer))
(cffi:defcfun ("gdk_pixbuf_add_alpha" %pixbuf-add-alpha) :pointer
  (pixbuf :pointer) (substitute :boolean) (red :uint8) (green :uint8) (blue :uint8))
(cffi:defcfun ("gdk_pixbuf_get_width" %pixbuf-width) :int (pixbuf :pointer))
(cffi:defcfun ("gdk_pixbuf_get_height" %pixbuf-height) :int (pixbuf :pointer))
(cffi:defcfun ("gdk_pixbuf_get_pixels" %pixbuf-pixels) :pointer (pixbuf :pointer))

(defconstant +pango-scale+ 1024)
(defparameter *max-raster-pixels* 4096
  "Longest edge of any text or image texture.")

;;; Text.

(defstruct (text-style (:constructor %make-text-style))
  (text "" :type string :read-only t)
  (markup-p nil :read-only t)
  (font "sans-serif" :type string :read-only t)
  (size 14d0 :type double-float :read-only t)
  (weight 400 :type fixnum :read-only t)
  (italic-p nil :read-only t)
  (align :start :read-only t)
  ;; Wrap width in logical pixels, or NIL for one line per paragraph.
  (width nil :read-only t)
  ;; Line pitch as a multiple of the font size, as in CSS, or NIL for the font's own.
  (line-height nil :read-only t)
  (max-lines nil :read-only t))

(defun text-style (lookup)
  "The text style that LOOKUP, a function from property key to declared or default
value, describes; ranges keep every value inside Pango's integer units."
  (let ((width (funcall lookup :width))
        (line-height (funcall lookup :line-height))
        (max-lines (funcall lookup :max-lines)))
    (%make-text-style
     :text (or (funcall lookup :text) "")
     :markup-p (funcall lookup :markup)
     :font (or (funcall lookup :font) "sans-serif")
     :size (max 1d0 (min 2048d0 (funcall lookup :font-size)))
     :weight (max 100 (min 1000 (round (funcall lookup :font-weight))))
     :italic-p (funcall lookup :italic)
     :align (funcall lookup :align)
     :width (and width (max 1d0 (min 100000d0 width)))
     :line-height (and line-height (max 0.1d0 (min 10d0 line-height)))
     :max-lines (and max-lines (max 1 (min 10000 max-lines))))))

(defun node-text-style (node)
  (text-style (lambda (key)
                (if (eq key :width)
                    (and (node-declared-p node :width) (node-number node :width))
                    (node-prop node key)))))

(defstruct (text-metrics (:constructor %make-text-metrics))
  ;; Logical size: the box the node occupies.
  (width 0d0 :type double-float)
  ;; Space added between lines for the style's line height.
  (spacing 0d0 :type double-float)
  (height 0d0 :type double-float)
  ;; Logical-pixel rectangle covering every inked and logical pixel.
  (left 0d0 :type double-float)
  (top 0d0 :type double-float)
  (right 0d0 :type double-float)
  (bottom 0d0 :type double-float))

(defvar *text-context* nil
  "Pango context on a private font map, laying text out at its logical size for
measuring and rasterizing alike. The worker binds its own.")

(defun %text-context ()
  (or *text-context*
      (when (%media-available-p 'stage-gobject 'stage-cairo 'stage-pango 'stage-pangocairo)
        (let ((font-map (%pango-cairo-font-map-new))
              (options (%cairo-font-options-create)))
          ;; Unhinted metrics keep glyph advances independent of the raster
          ;; scale; grayscale antialiasing survives any later transform.
          (%cairo-font-options-set-hint-metrics options 1)
          (%cairo-font-options-set-hint-style options 2)
          (%cairo-font-options-set-antialias options 2)
          (let ((context (%pango-font-map-create-context font-map)))
            (%pango-cairo-context-set-font-options context options)
            (%pango-context-set-round-glyph-positions context nil)
            (%cairo-font-options-destroy options)
            (%g-object-unref font-map)
            (setf *text-context* context))))))

(defun %configure-layout (layout style spacing)
  (unless (and (text-style-markup-p style) (%set-markup layout (text-style-text style)))
    (%pango-layout-set-text layout (text-style-text style) -1))
  (let ((description (%pango-font-description-new)))
    (%pango-font-description-set-family description (text-style-font style))
    (%pango-font-description-set-absolute-size description (* (text-style-size style) +pango-scale+))
    (%pango-font-description-set-weight description (text-style-weight style))
    (%pango-font-description-set-style description (if (text-style-italic-p style) 2 0))
    (%pango-layout-set-font-description layout description)
    (%pango-font-description-free description))
  (let ((width (text-style-width style)))
    (%pango-layout-set-width layout (if width (round (* width +pango-scale+)) -1))
    ;; Word wrapping, falling back to characters for words wider than a line.
    (%pango-layout-set-wrap layout 2)
    (when (and width (text-style-max-lines style))
      (%pango-layout-set-height layout (- (text-style-max-lines style)))
      (%pango-layout-set-ellipsize layout 3)))
  (%pango-layout-set-alignment layout (ecase (text-style-align style)
                                        (:start 0) (:center 1) (:end 2)))
  ;; Pango's own line-spacing factor grows with the target's scale; fixed
  ;; spacing in layout units does not.
  (%pango-layout-set-spacing layout (round (* spacing +pango-scale+)))
  layout)

(defun %set-markup (layout markup)
  "Apply Pango MARKUP to LAYOUT; return NIL without changes when it does not parse."
  (cffi:with-foreign-objects ((attributes :pointer) (text :pointer) (error :pointer))
    (setf (cffi:mem-ref error :pointer) (cffi:null-pointer))
    (if (%pango-parse-markup markup -1 0 attributes text (cffi:null-pointer) error)
        (progn
          (%pango-layout-set-text layout (cffi:foreign-string-to-lisp (cffi:mem-ref text :pointer)) -1)
          (%pango-layout-set-attributes layout (cffi:mem-ref attributes :pointer))
          (%pango-attr-list-unref (cffi:mem-ref attributes :pointer))
          (%g-free (cffi:mem-ref text :pointer))
          t)
        (progn
          (unless (cffi:null-pointer-p (cffi:mem-ref error :pointer))
            (%g-error-free (cffi:mem-ref error :pointer)))
          nil))))

(defun %layout-metrics (layout spacing)
  (cffi:with-foreign-objects ((ink '(:struct pango-rectangle)) (logical '(:struct pango-rectangle)))
    (%pango-layout-get-extents layout ink logical)
    (flet ((field (rectangle name)
             (/ (cffi:foreign-slot-value rectangle '(:struct pango-rectangle) name)
                (coerce +pango-scale+ 'double-float))))
      (let ((ink-x (field ink 'x)) (ink-y (field ink 'y))
            (logical-x (field logical 'x)) (logical-y (field logical 'y))
            (logical-width (field logical 'width)) (logical-height (field logical 'height)))
        (%make-text-metrics
         :width logical-width :height logical-height :spacing spacing
         :left (min ink-x logical-x) :top (min ink-y logical-y)
         :right (max (+ ink-x (field ink 'width)) (+ logical-x logical-width))
         :bottom (max (+ ink-y (field ink 'height)) (+ logical-y logical-height)))))))

(defun measure-text (style)
  "Logical metrics of STYLE, or NIL when Pango is unavailable."
  (let ((context (%text-context)))
    (when context
      (let ((layout (%configure-layout (%pango-layout-new context) style 0d0)))
        (unwind-protect
             (let ((metrics (%layout-metrics layout 0d0))
                   (line-height (text-style-line-height style)))
               (if line-height
                   (let ((spacing (- (* line-height (text-style-size style))
                                     (/ (text-metrics-height metrics)
                                        (max 1 (%pango-layout-line-count layout))))))
                     (%layout-metrics (%configure-layout layout style spacing) spacing))
                   metrics))
          (%g-object-unref layout))))))

(defun text-raster-box (metrics scale)
  "Logical rectangle (LEFT TOP WIDTH HEIGHT) and pixel size of a raster at SCALE."
  ;; One device pixel of padding keeps antialiased edges off the texture border.
  (let* ((pad (/ 1d0 scale))
         (left (- (text-metrics-left metrics) pad))
         (top (- (text-metrics-top metrics) pad))
         (width (+ (- (text-metrics-right metrics) (text-metrics-left metrics)) (* 2 pad)))
         (height (+ (- (text-metrics-bottom metrics) (text-metrics-top metrics)) (* 2 pad))))
    (values left top width height
            (max 1 (ceiling (* width scale))) (max 1 (ceiling (* height scale))))))

(defun %text-surface (context style metrics color scale)
  "STYLE rasterized through Pango CONTEXT in straight-alpha COLOR at SCALE device
pixels per logical pixel: a premultiplied BGRA Cairo image surface the caller
destroys, and its width and height."
  (multiple-value-bind (left top width height pixel-width pixel-height)
      (text-raster-box metrics scale)
    (declare (ignore width height))
    (let ((surface (%cairo-image-surface-create 0 pixel-width pixel-height))
          (done-p nil))
      (unwind-protect
           (progn
             (unless (zerop (%cairo-surface-status surface))
               (error "Cairo could not allocate a ~Dx~D text raster." pixel-width pixel-height))
             (let ((cairo (%cairo-create surface))
                   (layout nil))
               (unwind-protect
                    (progn
                      (%cairo-scale cairo scale scale)
                      (%cairo-translate cairo (- left) (- top))
                      (%cairo-set-source-rgba cairo (aref color 0) (aref color 1) (aref color 2)
                                              (aref color 3))
                      ;; Pango lays out at the logical size and Cairo scales the
                      ;; outlines. Told the scale, Pango would look the font up
                      ;; again for each one, which takes milliseconds.
                      (setf layout (%configure-layout (%pango-layout-new context) style
                                                      (text-metrics-spacing metrics)))
                      (%pango-cairo-show-layout cairo layout))
                 (when layout (%g-object-unref layout))
                 (%cairo-destroy cairo)))
             (%cairo-surface-flush surface)
             (setf done-p t)
             (values surface pixel-width pixel-height))
        (unless done-p (%cairo-surface-destroy surface))))))

(defun call-with-text-raster (style metrics color scale function)
  "Rasterize STYLE in straight-alpha COLOR at SCALE device pixels per logical pixel,
then call FUNCTION with the premultiplied BGRA pixels, their width and height."
  (let ((context (%text-context)))
    (when context
      (multiple-value-bind (surface width height) (%text-surface context style metrics color scale)
        (unwind-protect (funcall function (%cairo-image-surface-data surface) width height)
          (%cairo-surface-destroy surface))))))

;;; Images.

(defstruct (stage-image (:constructor %make-stage-image (path stamp)))
  (path "" :type string :read-only t)
  ;; File modification time, so an edited file decodes again.
  (stamp nil :read-only t)
  ;; Identifies the image in signatures and raster slots.
  (serial 0 :type fixnum)
  ;; :DECODING, :DECODED (pixbuf awaiting upload), :READY (uploaded), :IDLE (size
  ;; known, pixels released; decoded again when shown) or :FAILED.
  (state :decoding :type keyword)
  ;; When a frame last presented it, or its pixels arrived.
  (touched 0d0 :type double-float)
  ;; Intrinsic size in logical pixels; the texture may be smaller or larger.
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (pixbuf nil)
  (error nil))

(defun file-stamp (path)
  (ignore-errors (sb-posix:stat-mtime (sb-posix:stat path))))

(defun %premultiply (pixels count)
  (declare (type fixnum count) (optimize speed))
  (loop for offset of-type fixnum from 0 below (* 4 count) by 4
        for alpha of-type (unsigned-byte 8) = (cffi:mem-aref pixels :uint8 (+ offset 3))
        unless (= alpha 255)
          do (dotimes (channel 3)
               (setf (cffi:mem-aref pixels :uint8 (+ offset channel))
                     (floor (+ (* (cffi:mem-aref pixels :uint8 (+ offset channel)) alpha) 127) 255)))))

(defun decode-image (path)
  "Decode PATH into a premultiplied RGBA pixbuf at most *MAX-RASTER-PIXELS* on a side.
Return the pixbuf, NIL and the intrinsic size, or NIL and an error message. Safe on
any thread once the owner thread found gdk-pixbuf available."
  (cffi:with-foreign-objects ((width :int) (height :int) (error :pointer))
    (setf (cffi:mem-ref error :pointer) (cffi:null-pointer))
    (let ((format (%pixbuf-file-info path width height)))
      (when (cffi:null-pointer-p format)
        (return-from decode-image (values nil "not a supported image")))
      (let* ((natural (max 1 (cffi:mem-ref width :int) (cffi:mem-ref height :int)))
             ;; Vector images get four times their intrinsic size, at least 256
             ;; pixels: sharp when shown larger or zoomed, small for icons.
             (limit (min *max-raster-pixels*
                         (if (%pixbuf-format-scalable-p format)
                             (max natural (min 1024 (max 256 (* 4 natural))))
                             natural)))
             (scale (/ limit natural))
             (decoded (%pixbuf-new-at-scale path (max 1 (round (* scale (cffi:mem-ref width :int))))
                                            (max 1 (round (* scale (cffi:mem-ref height :int))))
                                            t error)))
        (when (cffi:null-pointer-p decoded)
          (let ((message (if (cffi:null-pointer-p (cffi:mem-ref error :pointer))
                             "decoding failed"
                             (let ((cause (cffi:mem-ref error :pointer)))
                               (prog1 (cffi:foreign-string-to-lisp
                                       (cffi:foreign-slot-value cause '(:struct g-error) 'message))
                                 (%g-error-free cause))))))
            (return-from decode-image (values nil message))))
        (let* ((oriented (prog1 (%pixbuf-apply-orientation decoded) (%g-object-unref decoded)))
               ;; A private RGBA copy, so premultiplying cannot touch shared pixels.
               (rgba (prog1 (%pixbuf-add-alpha oriented nil 0 0 0) (%g-object-unref oriented))))
          (%premultiply (%pixbuf-pixels rgba) (* (%pixbuf-width rgba) (%pixbuf-height rgba)))
          (values rgba nil (cffi:mem-ref width :int) (cffi:mem-ref height :int)))))))

(defstruct (text-job (:constructor %make-text-job (slot key style metrics color scale)))
  "Text the worker rasterizes for raster SLOT, where it will hold KEY. Once done, the
owner thread sets SURFACE, a Cairo image surface, and its size, or FAILED-P, and
DONE-AT."
  slot key style metrics color scale
  (surface nil) (width 0) (height 0) (failed-p nil) (done-at nil))

(defstruct (media-worker (:constructor %make-media-worker))
  (lock (sb-thread:make-mutex :name "Stage media worker") :read-only t)
  (wake (sb-thread:make-waitqueue) :read-only t)
  ;; STAGE-IMAGEs to decode and TEXT-JOBs to rasterize, in order.
  (queue nil :type list)
  ;; (JOB . RESULT) awaiting the owner thread.
  (finished nil :type list)
  (stopped-p nil)
  ;; Pipe the worker writes to; the owner thread watches the read end.
  read-fd write-fd source)

(defun start-media-worker (runtime on-finished)
  "Start the worker. ON-FINISHED runs on the owner thread for each job and its result:
for an image, its pixbuf or NIL, an error message, and its intrinsic width and
height; for text, its Cairo surface and size, or NIL and an error message."
  (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
    (let ((worker (%make-media-worker :read-fd read-fd :write-fd write-fd)))
      (sb-posix:fcntl read-fd sb-posix:f-setfl
                      (logior (sb-posix:fcntl read-fd sb-posix:f-getfl) sb-posix:o-nonblock))
      (setf (media-worker-source worker)
            (ataxia.runtime:add-event-loop-fd
             runtime read-fd ataxia.runtime:+event-readable+
             (lambda (source fd mask)
               (declare (ignore source mask))
               (cffi:with-foreign-object (bytes :uint8 64)
                 (loop while (plusp (cffi:foreign-funcall "read" :int fd :pointer bytes :size 64
                                                                 :long))))
               (dolist (result (sb-thread:with-mutex ((media-worker-lock worker))
                                 (prog1 (nreverse (media-worker-finished worker))
                                   (setf (media-worker-finished worker) nil))))
                 (apply on-finished (car result) (cdr result)))
               0)))
      (sb-thread:make-thread (lambda () (%media-worker-loop worker)) :name "Stage media worker")
      worker)))

(defun %release-result (job result)
  "Free what RESULT, the worker's result for JOB, holds."
  (when (first result)
    (etypecase job
      (stage-image (%g-object-unref (first result)))
      (text-job (%cairo-surface-destroy (first result))))))

(defun %media-worker-loop (worker)
  ;; The worker owns the pipe once stopped: closing it here means a job still
  ;; running at stop never writes into a descriptor number the owner reused. Its
  ;; text contexts are its own, on its own font map.
  (let ((*text-context* nil))
    (unwind-protect (%run-media-jobs worker)
      (when *text-context* (%g-object-unref *text-context*))
      (sb-posix:close (media-worker-read-fd worker))
      (sb-posix:close (media-worker-write-fd worker)))))

(defun %run-job (job)
  "Do JOB on the worker; return its result as a list."
  (handler-case
      (etypecase job
        (stage-image (multiple-value-list (decode-image (stage-image-path job))))
        (text-job
         (let ((context (%text-context)))
           (if context
               (multiple-value-list
                (%text-surface context (text-job-style job) (text-job-metrics job)
                               (text-job-color job) (text-job-scale job)))
               (list nil "Pango is unavailable")))))
    (error (cause) (list nil (princ-to-string cause)))))

(defun %run-media-jobs (worker)
  (loop
    (let ((job (sb-thread:with-mutex ((media-worker-lock worker))
                 (loop until (or (media-worker-stopped-p worker) (media-worker-queue worker))
                       do (sb-thread:condition-wait (media-worker-wake worker)
                                                    (media-worker-lock worker)))
                 (if (media-worker-stopped-p worker)
                     (return-from %run-media-jobs)
                     (pop (media-worker-queue worker))))))
      (let ((result (%run-job job)))
        (sb-thread:with-mutex ((media-worker-lock worker))
          (if (media-worker-stopped-p worker)
              (%release-result job result)
              (progn
                (push (cons job result) (media-worker-finished worker))
                (cffi:with-foreign-object (byte :uint8)
                  (setf (cffi:mem-ref byte :uint8) 1)
                  (cffi:foreign-funcall "write" :int (media-worker-write-fd worker) :pointer byte
                                                :size 1 :long)))))))))

(defun %queue-job (worker job)
  (sb-thread:with-mutex ((media-worker-lock worker))
    (setf (media-worker-queue worker) (append (media-worker-queue worker) (list job)))
    (sb-thread:condition-notify (media-worker-wake worker))))

(defun queue-image-decode (worker image)
  (setf (stage-image-state image) :decoding)
  (%queue-job worker image))

(defun queue-text-raster (worker job)
  (%queue-job worker job))

(defun stop-media-worker (worker)
  "Stop WORKER without waiting for a job in progress; the worker drops its result."
  (when worker
    (ataxia.runtime:remove-event-loop-source (media-worker-source worker))
    (sb-thread:with-mutex ((media-worker-lock worker))
      (setf (media-worker-stopped-p worker) t
            (media-worker-queue worker) nil)
      (loop for (job . result) in (shiftf (media-worker-finished worker) nil)
            do (%release-result job result))
      (sb-thread:condition-broadcast (media-worker-wake worker))))
  nil)
