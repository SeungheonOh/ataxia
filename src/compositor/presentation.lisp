;;;; Frame snapshots, outputs, and presentation coordination.
;;;;
;;;; One snapshot supplies both drawing and hit testing. Output submission uses
;;;; Runtime swapchains and direct GLES without depending on wlr_scene.

(in-package #:ataxia.compositor)

(defparameter *trace-output-p*
  (not (null (uiop:getenv "ATAXIA_TRACE_OUTPUT"))))

(defun trace-output (control &rest arguments)
  (when *trace-output-p*
    (apply #'format *error-output* control arguments)
    (finish-output *error-output*)))

(defclass compositor-output ()
  ((native :initarg :native :reader output-native)
   (viewport :initform (make-instance 'viewport) :reader output-viewport)
   (swapchain :initarg :swapchain :accessor output-swapchain)
   (last-snapshot :initform nil :accessor output-last-snapshot)
   (frame-revision :initform 0 :accessor output-frame-revision)
   (commit-pending-p :initform nil :accessor output-commit-pending-p)
   (redraw-pending-p :initform t :accessor output-redraw-pending-p)
   (render-source :initform nil :accessor output-render-source)
   (frame-timer :initform nil :accessor output-frame-timer)
   (frame-timer-armed-p :initform nil
                        :accessor output-frame-timer-armed-p)
   (frame-requested-p :initform nil :accessor output-frame-requested-p)
   (last-present-time :initform 0d0 :accessor output-last-present-time)
   (refresh-seconds :initform (/ 1d0 60d0)
                    :accessor output-refresh-seconds)
   (available-p :initform t :accessor output-available-p)))

(defclass output-system (compositor-component)
  ((outputs :initform (make-hash-table :test #'eq)
            :reader output-table)
   (order :initform nil :accessor output-order)))

(defclass presentation-system (compositor-component)
  ((animation-engine :initarg :animation-engine
                     :reader presentation-animation-engine)
   (panel-height :initarg :panel-height :initform 32d0
                 :reader presentation-panel-height)
   (revision :initform 0 :accessor presentation-revision)))

(defgeneric build-presentation-snapshot (presentation output timestamp))
(defgeneric presentation-hit-test (snapshot output-x output-y))
(defgeneric render-presentation-frame (presentation output snapshot))
(defgeneric present-output (presentation output))
(defgeneric schedule-presentation (presentation &optional output))

(defmethod attach-component :before ((presentation presentation-system))
  (let ((animation (presentation-animation-engine presentation)))
    (validate-component animation (component-compositor presentation))
    (unless (eq (component-state animation) :attached)
      (attach-component animation))))

(defmethod detach-component :before
    ((presentation presentation-system) reason)
  (let ((animation (presentation-animation-engine presentation)))
    (when (eq (component-state animation) :attached)
      (detach-component animation reason))))

(defclass presentation-item ()
  ((kind :initarg :kind :reader presentation-item-kind)
   (owner :initarg :owner :initform nil :reader presentation-item-owner)
   (surface :initarg :surface :initform nil :reader presentation-item-surface)
   (x :initarg :x :reader presentation-item-x)
   (y :initarg :y :reader presentation-item-y)
   (width :initarg :width :reader presentation-item-width)
   (height :initarg :height :reader presentation-item-height)
   (texture :initarg :texture :initform nil :reader presentation-item-texture)
   (shader-program-name :initarg :shader-program-name :initform nil
                        :reader presentation-item-shader-program-name)
   (shader-uniforms :initarg :shader-uniforms :initform nil
                    :reader presentation-item-shader-uniforms)
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
  (remove-if-not #'output-available-p (copy-list (output-order outputs))))

(defun find-compositor-output (outputs native)
  (gethash native (output-table outputs)))

(defun output-scanout-pending-p (output)
  (or (output-commit-pending-p output)
      (ataxia.runtime:output-frame-pending-p (output-native output))))

(defun output-frame-delay-milliseconds (output)
  (let* ((elapsed (- (monotonic-seconds)
                     (output-last-present-time output)))
         (remaining (max 0d0 (- (output-refresh-seconds output) elapsed))))
    (max 1 (ceiling (* remaining 1000d0)))))

(defun arm-output-frame (output)
  "Coalesce redraws and ask wlroots for one frame at the next refresh deadline."
  (when (and (output-available-p output)
             (output-frame-timer output)
             (not (output-frame-timer-armed-p output))
             (not (output-scanout-pending-p output)))
    (ataxia.runtime:update-event-loop-timer
     (output-frame-timer output)
     (output-frame-delay-milliseconds output))
    (setf (output-frame-timer-armed-p output) t))
  output)

(defun request-output-frame-now (output)
  (when (and (output-available-p output)
             (not (output-frame-requested-p output))
             (not (output-scanout-pending-p output)))
    (setf (output-frame-requested-p output) t)
    (ataxia.runtime:output-schedule-frame (output-native output)))
  output)

(defun install-output-frame-timer (runtime output)
  (setf
   (output-frame-timer output)
   (ataxia.runtime:add-event-loop-timer
    runtime
    (lambda (source)
      (declare (ignore source))
      (setf (output-frame-timer-armed-p output) nil)
      (when (and (output-available-p output)
                 (output-redraw-pending-p output)
                 (not (output-scanout-pending-p output)))
        (request-output-frame-now output))
      0)))
  output)

(defun record-output-presentation (output event)
  (setf (output-last-present-time output) (monotonic-seconds))
  (let ((refresh-nanoseconds
          (ataxia.runtime:output-present-refresh-nanoseconds event)))
    (when (plusp refresh-nanoseconds)
      (setf (output-refresh-seconds output)
            (/ (coerce refresh-nanoseconds 'double-float) 1d9))))
  (setf (output-commit-pending-p output) nil)
  (when (output-redraw-pending-p output)
    (arm-output-frame output))
  output)

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
                              :native native :swapchain swapchain))
             (published-p nil))
        (unwind-protect
             (progn
               ;; Install callback-owned resources before publishing the
               ;; output to the rest of the compositor as fully usable.
               (install-output-frame-timer runtime output)
               (setf (gethash native (output-table outputs)) output
                     (output-order outputs)
                     (append (output-order outputs) (list output))
                     published-p t)
               output)
          (unless published-p
            (when (and (output-frame-timer output)
                       (ataxia.runtime:native-object-live-p
                        (output-frame-timer output)))
              (ataxia.runtime:remove-event-loop-source
               (output-frame-timer output)))
            (when (ataxia.runtime:native-object-live-p swapchain)
              (ataxia.runtime:destroy-output-swapchain swapchain)))))
    (ataxia.runtime:native-call-failed (condition)
      (format *error-output* "[compositor] output unavailable ~A: ~A~%"
              (or (ataxia.runtime:output-name native) "unknown") condition)
      (finish-output *error-output*)
      nil)))

(defun unregister-compositor-output (outputs native)
  (let ((output (gethash native (output-table outputs))))
    (when output
      (setf (output-available-p output) nil)
      (when (and (output-render-source output)
                 (ataxia.runtime:native-object-live-p
                  (output-render-source output)))
        (ataxia.runtime:remove-event-loop-source
         (output-render-source output)))
      (setf (output-render-source output) nil)
      (when (and (output-frame-timer output)
                 (ataxia.runtime:native-object-live-p
                  (output-frame-timer output)))
        (ataxia.runtime:remove-event-loop-source
         (output-frame-timer output)))
      (setf (output-frame-timer output) nil
            (output-frame-timer-armed-p output) nil
            (output-frame-requested-p output) nil)
      (when (and (output-swapchain output)
                 (ataxia.runtime:native-object-live-p
                  (output-swapchain output)))
        (ataxia.runtime:destroy-output-swapchain
         (output-swapchain output)))
      (setf (output-order outputs)
            (delete output (output-order outputs) :test #'eq))
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

(defun presentation-shader-values (owner)
  ;; Copy values into the frame snapshot so shell edits cannot mutate a frame
  ;; while its items are being submitted.
  (let* ((view (typecase owner
                 (view owner)
                 (popup-view (popup-parent-view owner))))
         (state (and view (view-presentation-state view))))
    (values
     (and view (view-shader-program-name view))
     (when state
       (loop for name being the hash-keys
               of (presentation-shader-uniforms state)
             using (hash-value value)
             collect (cons name value))))))

(defun append-subsurface-tree-items
    (items compositor parent-surface owner x y scale-x scale-y)
  ;; Runtime reports exact parent-relative offsets. Keeping traversal here lets
  ;; alternate presentation engines replace tree composition independently.
  (let ((surfaces (compositor-surfaces compositor)))
    (dolist (subsurface
              (surface-child-subsurfaces surfaces parent-surface) items)
      (let* ((surface (ataxia.runtime:subsurface-surface subsurface))
             (record (gethash surface (surface-records surfaces)))
             (child-x (+ x (* (ataxia.runtime:subsurface-x subsurface)
                              scale-x)))
             (child-y (+ y (* (ataxia.runtime:subsurface-y subsurface)
                              scale-y))))
        (when (and record (surface-record-mapped-p record)
                   (surface-record-texture record))
          (multiple-value-bind (shader-name shader-uniforms)
              (presentation-shader-values owner)
            (setf items
                  (nconc
                   items
                   (list
                    (make-instance
                     'presentation-item :kind :surface :owner owner
                     :surface surface :x child-x :y child-y
                     :width (* (surface-record-width record) scale-x)
                     :height (* (surface-record-height record) scale-y)
                     :texture
                     (ataxia.runtime:texture-gles-attributes
                      (surface-record-texture record))
                     :shader-program-name shader-name
                     :shader-uniforms shader-uniforms
                     :interactive-p t :hit-kind :subsurface
                     :source-width (max 1 (surface-record-width record))
                     :source-height
                     (max 1 (surface-record-height record)))))))
          (setf items
                (append-subsurface-tree-items
                 items compositor surface owner child-x child-y
                 scale-x scale-y)))))))

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
              (multiple-value-bind (shader-name shader-uniforms)
                  (presentation-shader-values view)
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
                          :shader-program-name shader-name
                          :shader-uniforms shader-uniforms
                          :opacity opacity :interactive-p t :hit-kind :content
                          :source-width (max 1 (surface-record-width record))
                          :source-height
                          (max 1 (surface-record-height record))))))))
              (setf items
                    (append-subsurface-tree-items
                     items (component-compositor world)
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

(defun find-surface-presentation-item (items surface)
  (find surface items :key #'presentation-item-surface :test #'eq
        :from-end t))

(defun append-popup-tree-items (items desktop parent)
  ;; Parent-item geometry is the authoritative transform for both root and
  ;; nested popups, including viewport and per-view animation scaling.
  (dolist (popup (desktop-popups desktop) items)
    (when (and (eq parent (popup-parent popup)) (popup-mapped-p popup))
      (let* ((record (popup-surface popup))
             (parent-surface
               (typecase parent
                 (view (surface-record-native (view-surface parent)))
                 (popup-view
                  (surface-record-native (popup-surface parent)))))
             (parent-item
               (find-surface-presentation-item items parent-surface)))
        (when (and parent-item (surface-record-texture record))
          (let* ((scale-x
                   (/ (presentation-item-width parent-item)
                      (presentation-item-source-width parent-item)))
                 (scale-y
                   (/ (presentation-item-height parent-item)
                      (presentation-item-source-height parent-item)))
                 (x (+ (presentation-item-x parent-item)
                       (* (popup-x popup) scale-x)))
                 (y (+ (presentation-item-y parent-item)
                       (* (popup-y popup) scale-y))))
            (multiple-value-bind (shader-name shader-uniforms)
                (presentation-shader-values popup)
              (setf items
                    (nconc
                     items
                     (list
                      (make-instance
                       'presentation-item :kind :surface :owner popup
                       :surface (surface-record-native record)
                       :x x :y y
                       :width (* (surface-record-width record) scale-x)
                       :height (* (surface-record-height record) scale-y)
                       :texture
                       (ataxia.runtime:texture-gles-attributes
                        (surface-record-texture record))
                       :shader-program-name shader-name
                       :shader-uniforms shader-uniforms
                       :interactive-p t :hit-kind :popup
                       :source-width (max 1 (surface-record-width record))
                       :source-height
                       (max 1 (surface-record-height record)))))))
            (setf items
                  (append-subsurface-tree-items
                   items (component-compositor desktop)
                   (surface-record-native record) popup x y scale-x scale-y))
            (setf items (append-popup-tree-items items desktop popup))))))))

(defun append-popup-items (items desktop)
  (dolist (view (desktop-stacking-order desktop) items)
    (setf items (append-popup-tree-items items desktop view))))

(defun append-cursor-items (items compositor output)
  (declare (ignore output))
  (dolist (seat (interaction-seats (compositor-interaction compositor)) items)
    (let* ((x (seat-pointer-x seat))
           (y (seat-pointer-y seat))
           (cursor-record (seat-cursor-record seat)))
      (ecase (seat-cursor-mode seat)
        (:hidden nil)
        (:surface
         (when (and cursor-record (surface-record-texture cursor-record))
           (setf items
                 (nconc
                  items
                  (list
                   (make-instance
                    'presentation-item :kind :surface :owner seat
                    :surface (surface-record-native cursor-record)
                    :x (- x (seat-cursor-hotspot-x seat))
                    :y (- y (seat-cursor-hotspot-y seat))
                    :width (surface-record-width cursor-record)
                    :height (surface-record-height cursor-record)
                    :texture
                    (ataxia.runtime:texture-gles-attributes
                     (surface-record-texture cursor-record))))))))
        (:default
         (setf items
               (nconc items
                      (list
                       (make-solid-item x y 3d0 20d0
                                        '(0.04 0.04 0.05 1.0))
                       (make-solid-item (+ x 3d0) (+ y 3d0) 9d0 3d0
                                        '(0.04 0.04 0.05 1.0))
                       (make-solid-item (+ x 1d0) (+ y 1d0) 1d0 16d0
                                        '(0.95 0.97 1.0 1.0))))))))))

(defmethod build-presentation-snapshot
    ((presentation presentation-system) (output compositor-output) timestamp)
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
    (setf items (append-popup-items items desktop))
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

(defmethod presentation-hit-test
    ((snapshot presentation-snapshot) output-x output-y)
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
        (when (eq :subsurface (presentation-item-hit-kind item))
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
      (presentation-item-texture item) (presentation-item-opacity item)
      (presentation-item-shader-program-name item)
      (presentation-item-shader-uniforms item))))
  item)

(defmethod render-presentation-frame
    ((presentation presentation-system) (output compositor-output)
     (snapshot presentation-snapshot))
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

(defmethod present-output
    ((presentation presentation-system) (output compositor-output))
  (handler-case
      (let ((snapshot
              (build-presentation-snapshot
               presentation output (monotonic-seconds))))
        (setf (output-redraw-pending-p output) nil)
        (render-presentation-frame presentation output snapshot)
        (setf (output-commit-pending-p output) t)
        (trace-output
         "[output] commit ~A revision=~D native-pending=~A~%"
         (ataxia.runtime:output-name (output-native output))
         (output-frame-revision output)
         (ataxia.runtime:output-frame-pending-p (output-native output)))
        (when (active-animations-p
               (presentation-animation-engine presentation))
          (setf (output-redraw-pending-p output) t))
        snapshot)
    (serious-condition (condition)
      (format *error-output* "[compositor] frame failed on ~A: ~A~%"
              (ataxia.runtime:output-name (output-native output)) condition)
      (finish-output *error-output*)
      ;; Transient DRM busy failures must not strand the output without a
      ;; future frame. If scanout is pending, its presentation callback owns
      ;; the retry; otherwise wlroots may schedule immediately.
      (setf (output-redraw-pending-p output) t)
      (trace-output
       "[output] failure ~A lisp-pending=~A native-pending=~A~%"
       (ataxia.runtime:output-name (output-native output))
       (output-commit-pending-p output)
       (ataxia.runtime:output-frame-pending-p (output-native output)))
      (arm-output-frame output)
      nil)))

(defun queue-output-presentation (presentation output)
  ;; The DRM backend may emit FRAME from inside presentation cleanup. Deferring
  ;; until the Wayland loop unwinds avoids an atomic commit in that same turn.
  (unless (output-render-source output)
    (setf
     (output-render-source output)
     (ataxia.runtime:add-event-loop-idle
      (compositor-runtime (component-compositor presentation))
      (lambda (source)
        (declare (ignore source))
        (setf (output-render-source output) nil)
        (when (and (output-available-p output)
                   (output-redraw-pending-p output)
                   (not (output-scanout-pending-p output)))
          (present-output presentation output))
        0))))
  output)

(defmethod schedule-presentation
    ((presentation presentation-system) &optional output)
  (let ((outputs (compositor-outputs (component-compositor presentation))))
    (dolist (candidate
              (if output
                  (list output)
                  (compositor-outputs-list outputs)))
      (when (output-available-p candidate)
        (setf (output-redraw-pending-p candidate) t)
        (trace-output
         "[output] request ~A lisp-pending=~A native-pending=~A~%"
         (ataxia.runtime:output-name (output-native candidate))
         (output-commit-pending-p candidate)
         (ataxia.runtime:output-frame-pending-p (output-native candidate)))
        ;; Once the backend frame cycle has produced a snapshot, it owns
        ;; pacing. Manual scheduling here would create idle frames faster than
        ;; DRM refresh and can race a just-presented page flip.
        (if (null (output-last-snapshot candidate))
            (unless (output-scanout-pending-p candidate)
              (request-output-frame-now candidate))
            (arm-output-frame candidate)))))
  presentation)
