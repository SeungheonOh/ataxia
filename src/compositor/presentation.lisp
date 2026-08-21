;;;; Frame snapshots, outputs, and presentation coordination.
;;;;
;;;; One snapshot supplies both drawing and hit testing. Output submission uses
;;;; Runtime swapchains and direct GLES without depending on wlr_scene.

(in-package #:ataxia.compositor)

(defclass compositor-output ()
  ((native :initarg :native :reader output-native)
   (viewport :initform (make-instance 'viewport) :reader output-viewport)
   (swapchain :initarg :swapchain :accessor output-swapchain)
   (last-snapshot :initform nil :accessor output-last-snapshot)
   (frame-revision :initform 0 :accessor output-frame-revision)
   (available-p :initform t :accessor output-available-p)))

(defclass output-system (compositor-component)
  ((outputs :initform (make-hash-table :test #'eq)
            :reader output-table)))

(defclass presentation-system (compositor-component)
  ((animation-engine :initarg :animation-engine
                     :reader presentation-animation-engine)
   (panel-height :initarg :panel-height :initform 32d0
                 :reader presentation-panel-height)
   (revision :initform 0 :accessor presentation-revision)))

(defclass presentation-item ()
  ((kind :initarg :kind :reader presentation-item-kind)
   (owner :initarg :owner :initform nil :reader presentation-item-owner)
   (surface :initarg :surface :initform nil :reader presentation-item-surface)
   (x :initarg :x :reader presentation-item-x)
   (y :initarg :y :reader presentation-item-y)
   (width :initarg :width :reader presentation-item-width)
   (height :initarg :height :reader presentation-item-height)
   (texture :initarg :texture :initform nil :reader presentation-item-texture)
   (color :initarg :color :initform nil :reader presentation-item-color)
   (opacity :initarg :opacity :initform 1d0 :reader presentation-item-opacity)
   (interactive-p :initarg :interactive-p :initform nil
                  :reader presentation-item-interactive-p)
   (hit-kind :initarg :hit-kind :initform nil :reader presentation-item-hit-kind)
   (source-width :initarg :source-width :initform 1d0
                 :reader presentation-item-source-width)
   (source-height :initarg :source-height :initform 1d0
                  :reader presentation-item-source-height)))

(defclass presentation-snapshot ()
  ((output :initarg :output :reader snapshot-output)
   (timestamp :initarg :timestamp :reader snapshot-timestamp)
   (revision :initarg :revision :reader snapshot-revision)
   (items :initarg :items :reader snapshot-items)))

(defclass frame-context ()
  ((output :initarg :output :reader frame-context-output)
   (snapshot :initarg :snapshot :reader frame-context-snapshot)
   (state :initarg :state :reader frame-context-state)
   (buffer :initarg :buffer :reader frame-context-buffer)
   (framebuffer :initarg :framebuffer :reader frame-context-framebuffer)
   (width :initarg :width :reader frame-context-width)
   (height :initarg :height :reader frame-context-height)))

(defstruct (presentation-hit
             (:constructor make-presentation-hit
                 (&key item owner surface surface-x surface-y kind)))
  item owner surface
  (surface-x 0d0 :type double-float)
  (surface-y 0d0 :type double-float)
  kind)

(defun compositor-outputs-list (outputs)
  (loop for output being the hash-values of (output-table outputs)
        when (output-available-p output)
          collect output))

(defun find-compositor-output (outputs native)
  (gethash native (output-table outputs)))

(defun configure-native-output (runtime native)
  (ataxia.runtime:initialize-output-render
   native (ataxia.runtime:runtime-allocator runtime)
   (ataxia.runtime:runtime-renderer runtime))
  (let ((state (ataxia.runtime:create-output-state native)))
    (unwind-protect
         (progn
           (ataxia.runtime:output-state-set-enabled state t)
           (let ((mode (ataxia.runtime:output-preferred-mode native)))
             (when mode
               (ataxia.runtime:output-state-set-mode state mode)))
           (unless (ataxia.runtime:output-test-state native state)
             (error 'ataxia.runtime:native-call-failed
                    :name :output-test-state
                    :detail (ataxia.runtime:output-name native)))
           (unless (ataxia.runtime:output-commit-state native state)
             (error 'ataxia.runtime:native-call-failed
                    :name :output-commit-state
                    :detail (ataxia.runtime:output-name native))))
      (ataxia.runtime:destroy-output-state state)))
  (ataxia.runtime:create-output-global native)
  (ataxia.runtime:configure-output-swapchain native))

(defun register-compositor-output (outputs runtime native)
  (handler-case
      (let* ((swapchain (configure-native-output runtime native))
             (output
               (make-instance 'compositor-output
                              :native native :swapchain swapchain)))
        (setf (gethash native (output-table outputs)) output)
        output)
    (ataxia.runtime:native-call-failed (condition)
      (format *error-output* "[compositor] output unavailable ~A: ~A~%"
              (or (ataxia.runtime:output-name native) "unknown") condition)
      (finish-output *error-output*)
      nil)))

(defun unregister-compositor-output (outputs native)
  (let ((output (gethash native (output-table outputs))))
    (when output
      (setf (output-available-p output) nil)
      (when (and (output-swapchain output)
                 (ataxia.runtime:native-object-live-p
                  (output-swapchain output)))
        (ataxia.runtime:destroy-output-swapchain
         (output-swapchain output)))
      (remhash native (output-table outputs)))
    output))

(defun make-solid-item (x y width height color &key owner interactive-p hit-kind)
  (make-instance 'presentation-item
                 :kind :solid :x x :y y :width width :height height
                 :color color :owner owner :interactive-p interactive-p
                 :hit-kind hit-kind))

(defun scaled-view-geometry (x y width height state)
  (let* ((scale (presentation-scale state))
         (scaled-width (* width scale))
         (scaled-height (* height scale)))
    (values (+ x (/ (- width scaled-width) 2d0)
               (presentation-offset-x state))
            (+ y (/ (- height scaled-height) 2d0)
               (presentation-offset-y state))
            scaled-width scaled-height)))

(defun append-view-items
    (items world output view timestamp titlebar-height)
  (let ((record (view-surface view)))
    (when (and (view-mapped-p view)
               (not (view-minimized-p view))
               (view-presentable-p view)
               (surface-record-texture record))
      (multiple-value-bind (world-x world-y world-width world-height)
          (world-project world output (output-viewport output) view timestamp)
        (let ((effective-titlebar-height
                (if (view-fullscreen-p view) 0d0 titlebar-height)))
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
            (setf items
                  (nconc
                   items
                   (append
                    (unless (view-fullscreen-p view)
                      (list
                       (make-solid-item
                        (- x 7d0) (- y 7d0) (+ width 14d0) (+ height 14d0)
                        '(0.0 0.0 0.0 0.28) :owner view)
                       (make-solid-item
                        (- x 2d0) (- y 2d0) (+ width 4d0) (+ height 4d0)
                        '(0.12 0.15 0.21 1.0) :owner view
                        :interactive-p t :hit-kind :frame)
                       (make-solid-item
                        x y width title-height '(0.095 0.12 0.18 1.0)
                        :owner view :interactive-p t :hit-kind :titlebar)))
                    (list
                    (make-instance
                     'presentation-item
                     :kind :surface :owner view
                     :surface (surface-record-native record)
                     :x x :y content-y :width width :height content-height
                     :texture
                     (ataxia.runtime:texture-gles-attributes
                      (surface-record-texture record))
                     :opacity opacity :interactive-p t :hit-kind :content
                     :source-width (max 1 (surface-record-width record))
                     :source-height
                     (max 1 (surface-record-height record))))))))))))
  items))

(defun append-popup-items (items desktop output titlebar-height)
  (dolist (popup (desktop-popups desktop) items)
    (let* ((record (popup-surface popup))
           (parent (popup-parent-view popup))
           (placement (and parent (view-placement parent))))
      (when (and (popup-mapped-p popup) placement
                 (surface-record-texture record))
        (multiple-value-bind (parent-x parent-y parent-width parent-height)
            (world-project
             (compositor-world (component-compositor desktop))
             output (output-viewport output) parent 0d0)
          (declare (ignore parent-width parent-height))
          (let ((scale (viewport-scale (output-viewport output))))
            (setf items
                  (nconc
                   items
                   (list
                    (make-instance
                     'presentation-item :kind :surface :owner popup
                     :surface (surface-record-native record)
                     :x (+ parent-x (* (popup-x popup) scale))
                     :y (+ parent-y titlebar-height (* (popup-y popup) scale))
                     :width (* (surface-record-width record) scale)
                     :height (* (surface-record-height record) scale)
                     :texture
                     (ataxia.runtime:texture-gles-attributes
                      (surface-record-texture record))
                     :interactive-p t :hit-kind :popup
                     :source-width (max 1 (surface-record-width record))
                     :source-height
                     (max 1 (surface-record-height record))))))))))))

(defun append-cursor-items (items compositor output)
  (dolist (seat (interaction-seats (compositor-interaction compositor)) items)
    (let* ((x (seat-pointer-x seat))
           (y (seat-pointer-y seat))
           (cursor-record (seat-cursor-record seat)))
      (if (and cursor-record (surface-record-texture cursor-record))
          (push
           (make-instance
            'presentation-item :kind :surface :owner seat
            :surface (surface-record-native cursor-record)
            :x (- x (seat-cursor-hotspot-x seat))
            :y (- y (seat-cursor-hotspot-y seat))
            :width (surface-record-width cursor-record)
            :height (surface-record-height cursor-record)
            :texture
            (ataxia.runtime:texture-gles-attributes
             (surface-record-texture cursor-record)))
           items)
          (setf items
                (nconc items
                       (list
                        (make-solid-item x y 3d0 20d0
                                         '(0.04 0.04 0.05 1.0))
                        (make-solid-item (+ x 3d0) (+ y 3d0) 9d0 3d0
                                         '(0.04 0.04 0.05 1.0))
                        (make-solid-item (+ x 1d0) (+ y 1d0) 1d0 16d0
                                         '(0.95 0.97 1.0 1.0)))))))))

(defun build-presentation-snapshot (presentation output timestamp)
  (let* ((compositor (component-compositor presentation))
         (desktop (compositor-desktop compositor))
         (world (compositor-world compositor))
         (items nil)
         (titlebar-height 28d0))
    (sample-animations (presentation-animation-engine presentation) timestamp)
    (dolist (view (desktop-stacking-order desktop))
      (setf items
            (append-view-items
             items world output view timestamp titlebar-height)))
    (setf items (append-popup-items items desktop output titlebar-height))
    (let ((panel-height (presentation-panel-height presentation)))
      (setf items
            (nconc items
                   (unless
                       (find-if
                        (lambda (view)
                          (and (view-mapped-p view)
                               (view-fullscreen-p view)))
                        (desktop-stacking-order desktop))
                     (list
                    (make-solid-item
                     0d0 0d0
                     (coerce
                      (ataxia.runtime:output-width (output-native output))
                      'double-float)
                     panel-height '(0.055 0.072 0.11 0.98))
                    (make-solid-item
                     0d0 (- panel-height 2d0)
                     (coerce
                      (ataxia.runtime:output-width (output-native output))
                      'double-float)
                     2d0 '(0.18 0.55 0.95 1.0)))))))
    (setf items (append-cursor-items items compositor output))
    (make-instance
     'presentation-snapshot :output output :timestamp timestamp
     :revision (incf (presentation-revision presentation)) :items items)))

(defun point-in-item-p (item x y)
  (and (<= (presentation-item-x item) x
           (+ (presentation-item-x item) (presentation-item-width item)))
       (<= (presentation-item-y item) y
           (+ (presentation-item-y item) (presentation-item-height item)))))

(defun presentation-hit-test (snapshot output-x output-y)
  (dolist (item (reverse (snapshot-items snapshot)))
    (when (and (presentation-item-interactive-p item)
               (point-in-item-p item output-x output-y))
      (let* ((local-x
               (* (/ (- output-x (presentation-item-x item))
                     (max 1d0 (presentation-item-width item)))
                  (presentation-item-source-width item)))
             (local-y
               (* (/ (- output-y (presentation-item-y item))
                     (max 1d0 (presentation-item-height item)))
                  (presentation-item-source-height item)))
             (surface nil)
             (surface-x local-x)
             (surface-y local-y))
        (when (eq :content (presentation-item-hit-kind item))
          (multiple-value-setq (surface surface-x surface-y)
            (ataxia.runtime:xdg-surface-at
             (view-native (presentation-item-owner item)) local-x local-y)))
        (when (eq :popup (presentation-item-hit-kind item))
          (multiple-value-setq (surface surface-x surface-y)
            (ataxia.runtime:surface-at
             (presentation-item-surface item) local-x local-y)))
        (return
          (make-presentation-hit
           :item item :owner (presentation-item-owner item)
           :surface surface
           :surface-x (coerce surface-x 'double-float)
           :surface-y (coerce surface-y 'double-float)
           :kind (presentation-item-hit-kind item)))))))

(defmethod renderer-draw-item
    ((renderer direct-gles-renderer) frame-context
     (item presentation-item))
  (ecase (presentation-item-kind item)
    (:solid
     (draw-solid-rectangle
      renderer (frame-context-width frame-context)
      (frame-context-height frame-context)
      (presentation-item-x item) (presentation-item-y item)
      (presentation-item-width item) (presentation-item-height item)
      (presentation-item-color item)))
    (:surface
     (draw-textured-rectangle
      renderer (frame-context-width frame-context)
      (frame-context-height frame-context)
      (presentation-item-x item) (presentation-item-y item)
      (presentation-item-width item) (presentation-item-height item)
      (presentation-item-texture item) (presentation-item-opacity item))))
  item)

(defun render-presentation-frame (presentation output snapshot)
  (let* ((compositor (component-compositor presentation))
         (runtime (compositor-runtime compositor))
         (renderer (compositor-graphics compositor))
         (native (output-native output))
         (state (ataxia.runtime:create-output-state native))
         (buffer nil))
    (unwind-protect
         (progn
           (setf (output-swapchain output)
                 (ataxia.runtime:configure-output-swapchain
                  native (output-swapchain output)))
           (setf buffer
                 (ataxia.runtime:acquire-output-buffer
                  (output-swapchain output)))
           (let ((frame
                   (make-instance
                    'frame-context :output output :snapshot snapshot
                    :state state :buffer buffer
                    :framebuffer
                    (ataxia.runtime:output-buffer-framebuffer
                     (ataxia.runtime:runtime-renderer runtime) buffer)
                    :width (ataxia.runtime:buffer-width buffer)
                    :height (ataxia.runtime:buffer-height buffer))))
             (ataxia.runtime:with-egl-context
                 ((ataxia.runtime:runtime-egl runtime))
               (renderer-begin-frame renderer output frame)
               (handler-case
                   (progn
                     (dolist (item (snapshot-items snapshot))
                       (renderer-draw-item renderer frame item))
                     (renderer-end-frame renderer frame))
                 (serious-condition (condition)
                   (renderer-abort-frame renderer frame condition)
                   (error condition)))))
           (ataxia.runtime:output-state-set-buffer state buffer)
           (ataxia.runtime:release-buffer buffer)
           (setf buffer nil)
           (unless (ataxia.runtime:output-test-state native state)
             (error 'graphics-failure :operation :output-test))
           (unless (ataxia.runtime:output-commit-state native state)
             (error 'graphics-failure :operation :output-commit)))
      (when (and buffer (ataxia.runtime:native-object-live-p buffer))
        (ataxia.runtime:release-buffer buffer))
      (ataxia.runtime:destroy-output-state state)))
  (setf (output-last-snapshot output) snapshot)
  (incf (output-frame-revision output))
  (let ((surfaces
          (remove-duplicates
           (remove nil (mapcar #'presentation-item-surface
                               (snapshot-items snapshot)))
           :test #'eq)))
    (dolist (surface surfaces)
      (when (ataxia.runtime:native-object-live-p surface)
        (ataxia.runtime:surface-send-frame-done surface))))
  snapshot)

(defun present-output (presentation output)
  (handler-case
      (let ((snapshot
              (build-presentation-snapshot
               presentation output (monotonic-seconds))))
        (render-presentation-frame presentation output snapshot)
        (when (active-animations-p
               (presentation-animation-engine presentation))
          (ataxia.runtime:output-schedule-frame (output-native output)))
        snapshot)
    (serious-condition (condition)
      (format *error-output* "[compositor] frame failed on ~A: ~A~%"
              (ataxia.runtime:output-name (output-native output)) condition)
      (finish-output *error-output*)
      nil)))

(defun schedule-presentation (presentation &optional output)
  (let ((outputs (compositor-outputs (component-compositor presentation))))
    (dolist (candidate
              (if output
                  (list output)
                  (compositor-outputs-list outputs)))
      (when (output-available-p candidate)
        (ataxia.runtime:output-schedule-frame (output-native candidate)))))
  presentation)
