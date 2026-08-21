;;;; Layer 2 behavior policy implementations.
;;;;
;;;; Policies own workspace geometry, scene composition, and interactive
;;;; operation math while the compositor core retains protocol enforcement.

(in-package #:ataxia.compositor)

(defconstant +resize-edge-top+ 1)
(defconstant +resize-edge-bottom+ 2)
(defconstant +resize-edge-left+ 4)
(defconstant +resize-edge-right+ 8)
(defconstant +button-left+ 272)

(defclass interactive-operation ()
  ((kind :initarg :kind :reader interactive-operation-kind)
   (seat :initarg :seat :reader interactive-operation-seat)
   (view :initarg :view :reader interactive-operation-view)
   (output :initarg :output :initform nil :reader interactive-operation-output)
   (edges :initarg :edges :initform 0 :reader interactive-operation-edges)
   (button :initarg :button :reader interactive-operation-button)
   (start-x :initarg :start-x :reader interactive-operation-start-x)
   (start-y :initarg :start-y :reader interactive-operation-start-y)
   (original-width :initarg :original-width
                   :reader interactive-operation-original-width)
   (original-height :initarg :original-height
                    :reader interactive-operation-original-height)
   (original-placement :initarg :original-placement
                       :reader interactive-operation-original-placement)))

(defmethod behavior-build-view-items
    ((policy planar-behavior-policy) items output view timestamp titlebar-height)
  (let ((record (view-surface view)))
    (when (and (view-mapped-p view)
               (not (view-minimized-p view))
               (view-presentable-p view)
               (surface-record-texture record))
      (multiple-value-bind (world-x world-y world-width world-height)
          (behavior-project-view
           policy output (output-viewport output) view timestamp)
        (let ((effective-titlebar-height
                (if (or (view-fullscreen-p view)
                        (not (view-server-decorated-p view)))
                    0d0
                    titlebar-height)))
          (multiple-value-bind (x y width height)
              (scaled-view-geometry
               world-x world-y world-width
               (+ world-height effective-titlebar-height)
               (view-presentation-state view))
            (let* ((scale (/ width world-width))
                   (title-height (* effective-titlebar-height scale))
                   (content-y (+ y title-height))
                   (content-height (- height title-height))
                   (opacity
                     (presentation-opacity (view-presentation-state view))))
              (multiple-value-bind (shader-name shader-uniforms)
                  (presentation-shader-values view)
                (setf items
                      (nconc
                       items
                       (append
                        (unless (view-fullscreen-p view)
                          (make-soft-shadow-items
                           policy view x y width height))
                        (when (and (not (view-fullscreen-p view))
                                   (view-server-decorated-p view))
                          (list
                           (make-solid-item
                            (- x 2d0) (- y 2d0) (+ width 4d0) (+ height 4d0)
                            '(0.12 0.15 0.21 1.0) :owner view
                            :interactive-p t :hit-kind :frame)
                           (make-solid-item
                            x y width title-height '(0.095 0.12 0.18 1.0)
                            :owner view :interactive-p t :hit-kind :titlebar)))
                        (list
                         (make-surface-item
                          (surface-record-native record)
                          x content-y width content-height
                          (ataxia.runtime:texture-gles-attributes
                           (surface-record-texture record))
                          :owner view :program-name shader-name
                          :uniforms shader-uniforms
                          :opacity opacity :interactive-p t :hit-kind :content
                          :source-width (max 1 (surface-record-width record))
                          :source-height
                          (max 1 (surface-record-height record))))))))
              (setf items
                    (append-subsurface-tree-items
                     items (component-compositor policy)
                     (surface-record-native record) view x content-y
                     (/ width
                        (max 1d0
                             (coerce (surface-record-width record)
                                     'double-float)))
                     (/ content-height
                        (max 1d0
                             (coerce (surface-record-height record)
                                     'double-float))))))))))
  items))

(defun copy-planar-placement (placement)
  (make-instance 'planar-placement
                 :x (placement-x placement) :y (placement-y placement)
                 :width (placement-width placement)
                 :height (placement-height placement)
                 :z (placement-z placement)))

(defmethod behavior-begin-operation
    ((policy planar-behavior-policy) interaction seat view kind edges button)
  (declare (ignore interaction))
  (make-instance
   'interactive-operation :kind kind :seat seat :view view
   :output (seat-pointer-output seat) :edges edges :button button
   :start-x (seat-pointer-x seat)
   :start-y (seat-pointer-y seat)
   :original-width (view-width view)
   :original-height (view-height view)
   :original-placement
   (copy-behavior-placement policy (view-placement view))))

(defun planar-pointer-scale (policy operation)
  (let ((output (or (interactive-operation-output operation)
                    (seat-pointer-output (interactive-operation-seat operation))
                    (default-compositor-output
                     (component-compositor policy)))))
    (if output (viewport-scale (output-viewport output)) 1d0)))

(defun update-planar-move (policy operation)
  (let* ((seat (interactive-operation-seat operation))
         (view (interactive-operation-view operation))
         (original (interactive-operation-original-placement operation))
         (scale (planar-pointer-scale policy operation))
         (delta-x (/ (- (seat-pointer-x seat)
                        (interactive-operation-start-x operation)) scale))
         (delta-y (/ (- (seat-pointer-y seat)
                        (interactive-operation-start-y operation)) scale))
         (placement (view-placement view)))
    (setf (placement-x placement) (+ (placement-x original) delta-x)
          (placement-y placement) (+ (placement-y original) delta-y))
    placement))

(defun update-planar-resize (policy operation)
  (let* ((seat (interactive-operation-seat operation))
         (view (interactive-operation-view operation))
         (original (interactive-operation-original-placement operation))
         (scale (planar-pointer-scale policy operation))
         (delta-x (/ (- (seat-pointer-x seat)
                        (interactive-operation-start-x operation)) scale))
         (delta-y (/ (- (seat-pointer-y seat)
                        (interactive-operation-start-y operation)) scale))
         (edges (interactive-operation-edges operation))
         (left (placement-x original))
         (top (placement-y original))
         (right (+ left (placement-width original)))
         (bottom (+ top (placement-height original))))
    (when (logtest +resize-edge-left+ edges) (incf left delta-x))
    (when (logtest +resize-edge-right+ edges) (incf right delta-x))
    (when (logtest +resize-edge-top+ edges) (incf top delta-y))
    (when (logtest +resize-edge-bottom+ edges) (incf bottom delta-y))
    (when (< (- right left) 120d0)
      (if (logtest +resize-edge-left+ edges)
          (setf left (- right 120d0))
          (setf right (+ left 120d0))))
    (when (< (- bottom top) 80d0)
      (if (logtest +resize-edge-top+ edges)
          (setf top (- bottom 80d0))
          (setf bottom (+ top 80d0))))
    (let ((placement (view-placement view)))
      (setf (placement-x placement) left
            (placement-y placement) top
            (placement-width placement) (- right left)
            (placement-height placement) (- bottom top))
      (make-instance
       'view-configuration-decision
       :width (- right left) :height (- bottom top)))))

(defmethod behavior-update-operation
    ((policy planar-behavior-policy) interaction
     (operation interactive-operation))
  (declare (ignore interaction))
  (ecase (interactive-operation-kind operation)
    (:move (update-planar-move policy operation))
    (:resize (update-planar-resize policy operation))))

(defmethod behavior-restore-view
    ((policy planar-behavior-policy) compositor view)
  (declare (ignore compositor))
  (let ((restore (view-restore-placement view)))
    (when restore
      (setf (view-placement view) restore
            (view-restore-placement view) nil))
    (incf (behavior-policy-revision policy))
    (let ((placement (view-placement view)))
      (make-instance 'view-configuration-decision
                     :width (placement-width placement)
                     :height (placement-height placement)))))

(defmethod behavior-configure-view-for-output
    ((policy planar-behavior-policy) compositor view output fullscreen-p)
  (let ((output (or output (default-compositor-output compositor))))
    (if (null output)
        (make-instance 'view-configuration-decision
                       :width (view-width view) :height (view-height view))
        (progn
          (unless (view-restore-placement view)
            (setf (view-restore-placement view)
                  (copy-planar-placement (view-placement view))))
          (let* ((native (output-native output))
                 (panel (if fullscreen-p
                            0d0
                            (presentation-panel-height
                             (compositor-presentation compositor))))
                 (titlebar
                   (if (or fullscreen-p
                           (not (view-server-decorated-p view)))
                       0d0
                       (presentation-titlebar-height
                        (compositor-presentation compositor))))
                 (scale (viewport-scale (output-viewport output)))
                 (placement (view-placement view))
                 (width (/ (ataxia.runtime:output-width native) scale))
                 (height (/ (- (ataxia.runtime:output-height native)
                               panel titlebar)
                            scale)))
            (multiple-value-bind (world-x world-y)
                (behavior-unproject-point
                 policy output (output-viewport output) 0d0 panel)
              (setf (placement-x placement) world-x
                    (placement-y placement) world-y
                    (placement-width placement) width
                    (placement-height placement) height))
            (incf (behavior-policy-revision policy))
            (make-instance 'view-configuration-decision
                           :width width :height height))))))

(defmethod behavior-move-view
    ((policy planar-behavior-policy) view x y context)
  (let* ((placement (view-placement view))
         (old-placement (copy-planar-placement placement)))
    (check-type placement planar-placement)
    (setf (placement-x placement) (coerce x 'double-float)
          (placement-y placement) (coerce y 'double-float))
    (behavior-update-placement policy view placement context)
    (incf (behavior-policy-revision policy))
    (values placement old-placement)))

(defmethod behavior-focus-changed
    ((policy behavior-policy) seat previous view)
  (declare (ignore seat previous))
  (when view
    (desktop-raise-view
     (compositor-desktop (component-compositor policy)) view))
  (incf (behavior-policy-revision policy))
  view)

(defun resize-edges-at-point (item x y)
  (let* ((margin 8d0)
         (left (presentation-item-x item))
         (top (presentation-item-y item))
         (right (+ left (presentation-item-width item)))
         (bottom (+ top (presentation-item-height item)))
         (edges 0))
    (when (<= (abs (- x left)) margin)
      (setf edges (logior edges +resize-edge-left+)))
    (when (<= (abs (- x right)) margin)
      (setf edges (logior edges +resize-edge-right+)))
    (when (<= (abs (- y top)) margin)
      (setf edges (logior edges +resize-edge-top+)))
    (when (<= (abs (- y bottom)) margin)
      (setf edges (logior edges +resize-edge-bottom+)))
    edges))

(defmethod behavior-handle-pointer-button
    ((policy behavior-policy) interaction seat hit button state time)
  (declare (ignore policy interaction time))
  (let ((view (and hit (seat-hit-view hit))))
    (if (and (eq state :pressed) view)
        (case (presentation-hit-kind hit)
          (:titlebar
           (make-instance
            'pointer-button-decision :focus-target view
            :operation-kind (and (= button +button-left+) :move)
            :deliver-p nil))
          (:frame
           (make-instance
            'pointer-button-decision :focus-target view
            :operation-kind (and (= button +button-left+) :resize)
            :resize-edges
            (multiple-value-bind (local-x local-y)
                (seat-pointer-local-position seat)
              (resize-edges-at-point
               (presentation-hit-item hit) local-x local-y))
            :deliver-p nil))
          (otherwise
           (make-instance 'pointer-button-decision :focus-target view)))
        (make-instance 'pointer-button-decision))))

(defmethod behavior-observe-output
    ((policy planar-behavior-policy) output)
  (declare (ignore policy))
  (let ((viewport (output-viewport output)))
    (list :camera-x (viewport-camera-x viewport)
          :camera-y (viewport-camera-y viewport)
          :scale (viewport-scale viewport))))

(defmethod behavior-observe-view
    ((policy planar-behavior-policy) view)
  (declare (ignore policy))
  (let ((placement (view-placement view)))
    (list :x (placement-x placement) :y (placement-y placement)
          :width (placement-width placement)
          :height (placement-height placement)
          :z (placement-z placement))))
