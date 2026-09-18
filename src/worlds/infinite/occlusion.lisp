;;;; Conservative visibility in output-buffer pixels. Opaque coverage is never
;;;; approximated outwards; damage and visible coverage may be.
(in-package #:ataxia.infinite-world)

(defun %canvas-axis-aligned-p (state)
  ;; During arbitrary camera rotation, an enclosing rectangle is not opaque.
  ;; Output quarter-turns/reflections are already handled by the projection.
  (zerop (mod (%canvas-output-rotation state) (/ pi 2d0))))

(defun %surface-filter-insets (state surface x y width height)
  (let ((source (ataxia.kernel:drawable-surface-render-source surface)))
    (if (not (ataxia.kernel:render-source-has-alpha-p source))
        (values 0d0 0d0)
        (let* ((uv (ataxia.kernel:drawable-surface-texture-coordinates surface))
               (tw (ataxia.kernel:render-source-width source))
               (th (ataxia.kernel:render-source-height source))
               (horizontal (%canvas-rectangle-to-buffer state x y width 0d0))
               (vertical (%canvas-rectangle-to-buffer state x y 0d0 height)))
          ;; Leave one source texel plus one output pixel around alpha-bearing
          ;; opaque regions, covering bilinear and minification filter support.
          ;; UV edge lengths account for viewport crops and buffer transforms.
          (flet ((inset (index logical-size projected)
                   (+ (/ logical-size
                         (max 1d-9 (sqrt (+ (expt (* tw (- (aref uv index) (aref uv 0))) 2)
                                               (expt (* th (- (aref uv (1+ index)) (aref uv 1))) 2)))))
                      (/ logical-size (max 1d-9 (ataxia.world:rectangle-width projected)
                                                   (ataxia.world:rectangle-height projected))))))
            (values (inset 2 (ataxia.kernel:drawable-surface-width surface) horizontal)
                    (inset 4 (ataxia.kernel:drawable-surface-height surface) vertical)))))))

(defun %window-opaque-region (state window)
  (when (and (%window-visible-p window) (= 1d0 (%window-opacity window))
             (zerop (canvas-window-effect window)) (%canvas-axis-aligned-p state))
    (let ((result nil))
      (%map-window-surfaces
       state window
       (lambda (surface x y width height)
         (let ((sw (ataxia.kernel:drawable-surface-width surface))
               (sh (ataxia.kernel:drawable-surface-height surface))
               (opaque (ataxia.kernel:drawable-surface-opaque-region surface)))
           (when (and opaque (plusp width) (plusp height) (plusp sw) (plusp sh))
             (multiple-value-bind (inset-x inset-y)
                 (%surface-filter-insets state surface x y width height)
               (dolist (rectangle opaque)
                 (let* ((left (+ (max 0 (ataxia.kernel:frame-damage-rectangle-x rectangle)) inset-x))
                        (top (+ (max 0 (ataxia.kernel:frame-damage-rectangle-y rectangle)) inset-y))
                        (right (- (min sw (+ (ataxia.kernel:frame-damage-rectangle-x rectangle)
                                             (ataxia.kernel:frame-damage-rectangle-width rectangle))) inset-x))
                        (bottom (- (min sh (+ (ataxia.kernel:frame-damage-rectangle-y rectangle)
                                              (ataxia.kernel:frame-damage-rectangle-height rectangle))) inset-y)))
                   (when (and (< left right) (< top bottom))
                     (let* ((projected (%canvas-rectangle-to-buffer
                                        state (+ x (* width (/ left sw))) (+ y (* height (/ top sh)))
                                        (* width (/ (- right left) sw)) (* height (/ (- bottom top) sh))))
                            (px (max 0 (ceiling (ataxia.world:rectangle-x projected))))
                            (py (max 0 (ceiling (ataxia.world:rectangle-y projected))))
                            (pr (min (%canvas-output-buffer-width state) (floor (ataxia.world:rectangle-right projected))))
                            (pb (min (%canvas-output-buffer-height state) (floor (ataxia.world:rectangle-bottom projected)))))
                       (when (and (< px pr) (< py pb))
                         (push (ataxia.world:make-rectangle px py (- pr px) (- pb py)) result)))))))))))
      result)))

(defun %add-occluders (region additional)
  ;; Keep an under-approximation if opaque metadata becomes complicated. Never
  ;; replace these rectangles with the damage tracker's conservative unions.
  (dolist (rectangle additional region)
    ;; Normalize at most 65 candidates, even for a large subsurface tree.
    (setf region (ataxia.world:normalize-region (cons rectangle region)))
    (when (> (length region) 64)
      (setf region (subseq (sort region #'> :key #'ataxia.world:rectangle-area) 0 64)))))

(defun %window-occluders-above (world state window)
  (let ((opaque nil))
    (dolist (above (cdr (member window (%world-stacking world))) opaque)
      (setf opaque (%add-occluders opaque (%window-opaque-region state above))))))

(defun %visible-window-damage (world state window region)
  (ataxia.world:subtract-region region (%window-occluders-above world state window)))

(defun %window-callback-tokens (state window visible)
  (let ((tokens nil))
    (when (and visible
               (some #'ataxia.kernel:drawable-surface-frame-callback-p
                     (ataxia.kernel:drawable-surfaces (canvas-window-application window))))
      (%map-window-surfaces
       state window
       (lambda (surface x y width height)
         (let ((token (ataxia.kernel:drawable-surface-presentation-token surface)))
           (when (and token (ataxia.kernel:drawable-surface-frame-callback-p surface)
                      (ataxia.world:region-intersects-p
                       (%canvas-rectangle-to-buffer state x y width height) visible))
             (push token tokens))))))
    tokens))

(defun %window-needs-visible-callback-p (world state window)
  (when (and (%window-visible-p window)
             (some #'ataxia.kernel:drawable-surface-frame-callback-p
                   (ataxia.kernel:drawable-surfaces (canvas-window-application window))))
    (%window-callback-tokens
     state window
     (%visible-window-damage
      world state window
      (ataxia.world:clip-region (list (%window-buffer-coverage state window))
                               (%canvas-output-buffer-width state) (%canvas-output-buffer-height state))))))

(defun %canvas-paint-plan (state windows overlays seats)
  "Back-to-front entries (kind object visible-region), including background.
All subtraction has a fragmentation budget; falling back costs extra drawing,
never missing pixels. Bounds reject offscreen objects before collecting opacity."
  (let ((opaque nil) (window-entries nil) (below nil) (above nil) (cursors nil)
        (width (%canvas-output-buffer-width state)) (height (%canvas-output-buffer-height state)))
    (flet ((clip (region) (ataxia.world:clip-region region width height)))
      (dolist (window (reverse windows))
        (when (%window-visible-p window)
          (let ((coverage (clip (list (%window-buffer-coverage state window)))))
            (when coverage
              (push (list :window window (ataxia.world:subtract-region coverage opaque)) window-entries)
              (setf opaque (%add-occluders opaque (%window-opaque-region state window)))))))
      (dolist (overlay overlays)
        (when (%overlay-visible-on-state-p overlay state)
          (let ((coverage (clip (list (%overlay-buffer-coverage state overlay)))))
            (when coverage
              (if (%overlay-below-windows-p overlay)
                  (push (list :overlay overlay (ataxia.world:subtract-region coverage opaque)) below)
                  (push (list :overlay overlay coverage) above))))))
      (dolist (seat seats)
        (when (eq state (%canvas-seat-output seat))
          (let ((coverage (%cursor-buffer-coverage state seat)))
            (push (list :cursor seat (and coverage (clip (list (reduce #'ataxia.world:rectangle-union coverage)))))
                  cursors))))
      (append (list (list :background nil
                          (ataxia.world:subtract-region
                           (list (ataxia.world:make-rectangle 0 0 width height)) opaque)))
              (nreverse below) window-entries (nreverse above) (nreverse cursors)))))

(defun %canvas-plan-callbacks (state plan)
  (coerce (loop for (kind object visible) in plan when (eq kind :window)
                append (%window-callback-tokens state object visible)) 'vector))
