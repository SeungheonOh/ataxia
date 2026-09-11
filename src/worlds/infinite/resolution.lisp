(in-package #:ataxia.infinite-world)

(defvar *overlay-texture-limits* (make-hash-table :test #'eq :weakness :key))

(defun %overlay-raster-scale (logical-width logical-height displayed-width displayed-height
                              output-scale current-scale texture-limit)
  "Choose screen-aware supersampling with stable allocation buckets."
  (let* ((needed (* 2d0 output-scale
                    (max (/ displayed-width logical-width) (/ displayed-height logical-height))))
         ;; Half-octave buckets avoid reallocating a texture on every zoom frame.
         (bucket (expt 2d0 (/ (ceiling (* 2d0 (log (max 0.01d0 needed) 2d0))) 2d0)))
         (limit (min (/ texture-limit logical-width) (/ texture-limit logical-height)
                     (sqrt (/ 16777216d0 (* logical-width logical-height)))))
         (desired (min bucket limit)))
    ;; Grow before magnification loses detail; shrink only after a full octave.
    (min limit (if (or (> desired current-scale) (<= desired (/ current-scale 2d0)))
                   desired current-scale))))

(defun %prepare-overlay-resolution (world state overlay)
  (let ((component (canvas-overlay-component overlay)))
    (when (ataxia.world:ui-raster-scale component)
      (let* ((renderer (%world-renderer world))
             (limit (or (gethash renderer *overlay-texture-limits*)
                        (setf (gethash renderer *overlay-texture-limits*)
                              (cffi:with-foreign-object (value :int32)
                                (ataxia.world.gles::%gl-get-integer #x0D33 value) ; GL_MAX_TEXTURE_SIZE
                                (max 1 (cffi:mem-ref value :int32))))))
             (width (nth-value 2 (ataxia.kernel:drawable-local-bounds component)))
             (height (nth-value 3 (ataxia.kernel:drawable-local-bounds component)))
             (current (ataxia.world:ui-raster-scale component))
             (scale (%overlay-raster-scale
                     width height (max 1d0 (canvas-overlay-width overlay))
                     (max 1d0 (canvas-overlay-height overlay))
                     (ataxia.kernel:output-scale (%canvas-output-output state)) current limit)))
        (unless (= current scale)
          (ataxia.world:ui-resize component width height :scale scale)
          (%damage-overlay world overlay)))))
  overlay)
