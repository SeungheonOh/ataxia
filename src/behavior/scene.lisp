;;;; Shared behavior scene composition.
;;;;
;;;; Policies assemble surface trees, popups, panels, and cursors from core
;;;; presentation primitives. Core only freezes and executes the result.

(in-package #:ataxia.compositor)

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
                    (make-surface-item
                     surface child-x child-y
                     (* (surface-record-width record) scale-x)
                     (* (surface-record-height record) scale-y)
                     (ataxia.runtime:texture-gles-attributes
                      (surface-record-texture record))
                     :record record :owner owner :program-name shader-name
                     :uniforms shader-uniforms
                     :interactive-p t :hit-kind :subsurface
                     :source-width (max 1 (surface-record-width record))
                     :source-height
                     (max 1 (surface-record-height record)))))))
          (setf items
                (append-subsurface-tree-items
                 items compositor surface owner child-x child-y
                 scale-x scale-y)))))))

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
                      (make-surface-item
                       (surface-record-native record) x y
                       (* (surface-record-width record) scale-x)
                       (* (surface-record-height record) scale-y)
                       (ataxia.runtime:texture-gles-attributes
                        (surface-record-texture record))
                       :record record :owner popup :program-name shader-name
                       :uniforms shader-uniforms
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

(defmethod behavior-build-popup-items
    ((policy behavior-policy) items desktop output timestamp)
  (declare (ignore policy output timestamp))
  (append-popup-items items desktop))

(defun append-cursor-items (items compositor output)
  (dolist (seat (interaction-seats (compositor-interaction compositor)) items)
    (when (eq output (seat-pointer-output seat))
      (multiple-value-bind (x y) (seat-pointer-local-position seat output)
        (let ((cursor-record (seat-cursor-record seat)))
      (ecase (seat-cursor-mode seat)
        (:hidden nil)
        (:surface
         (when (and cursor-record (surface-record-texture cursor-record))
           (setf items
                 (nconc
                  items
                  (list
                   (make-surface-item
                    (surface-record-native cursor-record)
                    (- x (seat-cursor-hotspot-x seat))
                    (- y (seat-cursor-hotspot-y seat))
                    (surface-record-width cursor-record)
                    (surface-record-height cursor-record)
                    (ataxia.runtime:texture-gles-attributes
                     (surface-record-texture cursor-record))
                    :record cursor-record :owner seat))))))
        (:default
         (setf items
               (nconc items
                      (list
                       (make-solid-item x y 3d0 20d0
                                        '(0.04 0.04 0.05 1.0))
                       (make-solid-item (+ x 3d0) (+ y 3d0) 9d0 3d0
                                        '(0.04 0.04 0.05 1.0))
                       (make-solid-item (+ x 1d0) (+ y 1d0) 1d0 16d0
                                        '(0.95 0.97 1.0 1.0))))))))))))

(defun append-panel-items (items presentation output desktop)
  (unless
      (find-if
       (lambda (view)
         (and (view-mapped-p view) (view-fullscreen-p view)))
       (desktop-stacking-order desktop))
    (let ((panel-height (presentation-panel-height presentation))
          (output-width
            (coerce
             (ataxia.runtime:output-width (output-native output))
             'double-float)))
      (setf items
            (nconc
             items
             (list
              (make-solid-item
               0d0 0d0 output-width panel-height
               '(0.055 0.072 0.11 0.98))
              (make-solid-item
               0d0 (- panel-height 2d0) output-width 2d0
               '(0.18 0.55 0.95 1.0)))))))
  items)

(defmethod behavior-build-scene
    ((policy standard-behavior-policy) (presentation presentation-system)
     (output compositor-output) timestamp)
  "Build the ordered scene while core retains snapshot and frame ownership."
  (let* ((compositor (component-compositor presentation))
         (desktop (compositor-desktop compositor))
         (native-output (output-native output))
         (items
           (list
            (make-solid-item
             0d0 0d0
             (coerce (ataxia.runtime:output-width native-output) 'double-float)
             (coerce (ataxia.runtime:output-height native-output) 'double-float)
             (behavior-background-color policy))))
         (titlebar-height (presentation-titlebar-height presentation)))
    (dolist (view (desktop-stacking-order desktop))
      (setf items
            (behavior-build-view-items
             policy items output view timestamp titlebar-height)))
    (setf items
          (behavior-build-popup-items
           policy items desktop output timestamp)
          items (append-panel-items items presentation output desktop)
          items (append-cursor-items items compositor output))
    items))

(defmethod behavior-compose-frame
    ((policy behavior-policy) presentation output snapshot timestamp)
  (declare (ignore policy presentation output timestamp))
  (make-instance
   'frame-plan :snapshot snapshot
   :passes
   (list (make-instance 'item-render-pass
                        :name :scene :target :scene
                        :items (snapshot-items snapshot))
         (make-instance 'present-render-pass
                        :name :present :target :output
                        :damage-mode :full))))
