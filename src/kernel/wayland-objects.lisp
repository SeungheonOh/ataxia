;;;; Wayland application objects.
;;;;
;;;; Kernel keeps committed wl_surface trees, retained client textures, and
;;;; protocol input resolution inside WAYLAND-APPLICATION. World receives one
;;;; logical object and immutable local drawable records.

(in-package #:ataxia.kernel)

(defun %ensure-surface-node (kernel runtime-surface)
  (or (gethash runtime-surface (%kernel-surface-table kernel))
      (let ((surface
              (make-instance
               'surface-node
               :kernel kernel
               :id (%allocate-object-id kernel)
               :runtime-object runtime-surface
               :mapped-p (ataxia.runtime:surface-mapped-p runtime-surface))))
        (setf (%surface-protocol-token surface)
              (make-instance
               'surface-protocol-token
               :surface surface
               :generation (object-generation surface)))
        (%register-object kernel surface :runtime-object runtime-surface)
        (setf (gethash runtime-surface (%kernel-surface-table kernel)) surface)
        surface)))

(defun %runtime-damage-rectangles (rectangles &optional (offset-x 0) (offset-y 0))
  (mapcar
   (lambda (rectangle)
     (make-frame-damage-rectangle
      (+ offset-x (ataxia.runtime:damage-rectangle-x rectangle))
      (+ offset-y (ataxia.runtime:damage-rectangle-y rectangle))
      (ataxia.runtime:damage-rectangle-width rectangle)
      (ataxia.runtime:damage-rectangle-height rectangle)))
   rectangles))

(defun %release-surface-source (surface)
  (when (%surface-render-source surface)
    (release-render-source (%surface-render-source surface))
    (setf (%surface-render-source surface) nil))
  surface)

(defun %make-wayland-render-source (surface generation)
  (let ((buffer
          (ataxia.runtime:retain-surface-buffer
           (surface-runtime-object surface))))
    (when buffer
      (let ((transferred-p nil))
        (unwind-protect
             (let ((texture (ataxia.runtime:buffer-texture buffer)))
               (when texture
                 (let ((attributes
                         (ataxia.runtime:texture-gles-attributes texture)))
                   (setf transferred-p t)
                   (make-instance
                    'wayland-render-source
                    :buffer buffer
                    :width (ataxia.runtime:buffer-width buffer)
                    :height (ataxia.runtime:buffer-height buffer)
                    :gles-target
                    (ataxia.runtime:gles-texture-target attributes)
                    :gles-name
                    (ataxia.runtime:gles-texture-name attributes)
                    :has-alpha-p
                    (ataxia.runtime:gles-texture-has-alpha-p attributes)
                    :generation generation))))
          (unless transferred-p
            (ataxia.runtime:release-buffer buffer)))))))

(defun %update-surface-node (surface commit)
  (%release-surface-source surface)
  (multiple-value-bind
      (width height source-x source-y source-width source-height transform)
      (ataxia.runtime:surface-content-layout (surface-runtime-object surface))
    (setf (surface-width surface) width
          (surface-height surface) height
          (surface-mapped-p surface)
          (ataxia.runtime:surface-mapped-p (surface-runtime-object surface))
          (%surface-source-box surface)
          (vector source-x source-y source-width source-height)
          (%surface-buffer-transform surface) transform))
  (when commit
    (setf (surface-commit-sequence surface)
          (ataxia.runtime:surface-commit-sequence commit)
          (%surface-damage surface)
          (%runtime-damage-rectangles
           (ataxia.runtime:surface-commit-damage-rectangles commit))))
  (when (surface-mapped-p surface)
    (setf (%surface-render-source surface)
          (%make-wayland-render-source
           surface (surface-commit-sequence surface))))
  surface)

(defun %walk-surface-tree (surface function &optional (parent-x 0) (parent-y 0))
  (let ((x (+ parent-x (surface-local-x surface)))
        (y (+ parent-y (surface-local-y surface))))
    (funcall function surface x y)
    (dolist (child (surface-children surface))
      (%walk-surface-tree child function x y))))

(defun %rebuild-application-drawables (application)
  (let ((records nil)
        (damage nil)
        (order 0))
    (%walk-surface-tree
     (application-root-surface application)
     (lambda (surface x y)
       (when (and (surface-mapped-p surface)
                  (%surface-render-source surface)
                  (plusp (surface-width surface))
                  (plusp (surface-height surface)))
         (push
          (make-instance
           'drawable-surface
           :id (object-id surface)
           :local-x x
           :local-y y
           :width (surface-width surface)
           :height (surface-height surface)
           :order order
           :source-box (%surface-source-box surface)
           :buffer-transform (%surface-buffer-transform surface)
           :render-source (%surface-render-source surface)
           :protocol-token (%surface-protocol-token surface)
           :damage (%surface-damage surface)
           :generation (surface-commit-sequence surface))
          records)
         (incf order)
         (dolist (rectangle (%surface-damage surface))
           (push
            (make-frame-damage-rectangle
             (+ x (frame-damage-rectangle-x rectangle))
             (+ y (frame-damage-rectangle-y rectangle))
             (frame-damage-rectangle-width rectangle)
             (frame-damage-rectangle-height rectangle))
            damage)))))
    (setf (%application-drawable-surfaces application)
          (coerce (nreverse records) 'vector))
    (incf (%application-drawable-revision application))
    (nreverse damage)))

(defmethod drawable-surfaces ((surface surface-node))
  (let ((source (%surface-render-source surface)))
    (values
     (if (and source (surface-mapped-p surface))
         (vector
          (make-instance
           'drawable-surface
           :id (object-id surface)
           :local-x 0
           :local-y 0
           :width (surface-width surface)
           :height (surface-height surface)
           :order 0
           :source-box (%surface-source-box surface)
           :buffer-transform (%surface-buffer-transform surface)
           :render-source source
           :protocol-token (%surface-protocol-token surface)
           :damage (%surface-damage surface)
           :generation (surface-commit-sequence surface)))
         #())
     (surface-commit-sequence surface))))

(defmethod drawable-local-bounds ((surface surface-node))
  (values 0 0 (surface-width surface) (surface-height surface)))

(defun %invalidate-application (application)
  (let ((damage (%rebuild-application-drawables application)))
    (world-object-invalidated
     (kernel-world (object-kernel application))
     application
     (make-drawable-invalidation
      (%application-drawable-revision application) damage)))
  application)

(defun %surface-tree-application (surface)
  (or (%surface-application surface)
      (let ((parent (surface-parent surface)))
        (and parent (%surface-tree-application parent)))))

(defun %attach-surface-child (parent child x y)
  (when (surface-parent child)
    (setf (surface-children (surface-parent child))
          (delete child (surface-children (surface-parent child)) :test #'eq)))
  (setf (surface-parent child) parent
        (surface-local-x child) x
        (surface-local-y child) y
        (%surface-application child) (%surface-tree-application parent))
  (unless (member child (surface-children parent) :test #'eq)
    (setf (surface-children parent)
          (append (surface-children parent) (list child))))
  child)

(defun %detach-surface-node (surface)
  (let ((parent (surface-parent surface)))
    (when parent
      (setf (surface-children parent)
            (delete surface (surface-children parent) :test #'eq))))
  (setf (surface-parent surface) nil
        (%surface-application surface) nil)
  surface)

(defun %retire-surface-node (surface)
  (when (eq (object-state surface) :live)
    (let* ((kernel (object-kernel surface))
           (application (%surface-tree-application surface))
           (runtime-surface (surface-runtime-object surface)))
      (%detach-surface-node surface)
      (dolist (child (surface-children surface))
        (setf (surface-parent child) nil
              (%surface-application child) nil))
      (setf (surface-children surface) nil)
      (%release-surface-source surface)
      (remhash runtime-surface (%kernel-surface-table kernel))
      (%retire-object kernel surface :runtime-object runtime-surface)
      (when (and application (eq (object-state application) :live))
        (%invalidate-application application))))
  surface)

(defun %create-wayland-application (kernel toplevel)
  (let* ((runtime-surface (ataxia.runtime:xdg-toplevel-surface toplevel))
         (root (%ensure-surface-node kernel runtime-surface))
         (application
           (make-instance
            'wayland-application
            :kernel kernel
            :id (%allocate-object-id kernel)
            :toplevel toplevel
            :root-surface root
            :title (ataxia.runtime:xdg-toplevel-title toplevel)
            :app-id (ataxia.runtime:xdg-toplevel-app-id toplevel)
            :mapped-p (ataxia.runtime:surface-mapped-p runtime-surface))))
    (setf (%surface-application root) application)
    (%register-object kernel application :runtime-object toplevel
                      :world-visible-p t)
    (setf (gethash toplevel (%kernel-toplevel-table kernel)) application)
    (world-register-object (kernel-world kernel) application)
    application))

(defun %retire-wayland-application (application reason)
  (when (eq (object-state application) :live)
    (let ((kernel (object-kernel application)))
      (world-unregister-object
       (kernel-world kernel) application reason)
      (remhash (application-toplevel application)
               (%kernel-toplevel-table kernel))
      (%retire-object
       kernel application
       :runtime-object (application-toplevel application)
       :world-visible-p t)))
  application)

(defun %pointer-event-time (input)
  (etypecase input
    (cursor-motion-input (cursor-motion-input-time-msec input))
    (cursor-button-input (cursor-button-input-time-msec input))
    (cursor-axis-input (cursor-axis-input-time-msec input))))

(defun %application-surface-at (application local-x local-y)
  (ataxia.runtime:xdg-surface-at
   (application-toplevel application) local-x local-y))

(defun %enter-application-surface (application seat local-x local-y input)
  (multiple-value-bind (surface surface-x surface-y)
      (%application-surface-at application local-x local-y)
    (when surface
      (ataxia.runtime:seat-pointer-notify-enter
       (seat-runtime-object seat) surface surface-x surface-y)
      (ataxia.runtime:seat-pointer-notify-motion
       (seat-runtime-object seat) (%pointer-event-time input)
       surface-x surface-y)
      (values surface surface-x surface-y))))

(defmethod interactable-pointer-motion
    ((application wayland-application) world (seat logical-seat)
     local-x local-y input)
  (declare (ignore world))
  (if (%enter-application-surface
       application seat local-x local-y input)
      (make-interaction-result :status :delivered :object application)
      (make-interaction-result :status :miss :object application)))

(defmethod interactable-pointer-button
    ((application wayland-application) world (seat logical-seat)
     local-x local-y input)
  (declare (ignore world))
  (if (%enter-application-surface
       application seat local-x local-y input)
      (progn
        (ataxia.runtime:seat-pointer-notify-button
         (seat-runtime-object seat)
         (cursor-button-input-time-msec input)
         (cursor-button-input-code input)
         (cursor-button-input-state input))
        (make-interaction-result :status :delivered :object application))
      (make-interaction-result :status :miss :object application)))

(defmethod interactable-pointer-axis
    ((application wayland-application) world (seat logical-seat)
     local-x local-y input)
  (declare (ignore world))
  (if (%enter-application-surface
       application seat local-x local-y input)
      (progn
        (ataxia.runtime:seat-pointer-notify-axis
         (seat-runtime-object seat)
         (cursor-axis-input-time-msec input)
         (cursor-axis-input-orientation input)
         (cursor-axis-input-delta input)
         (cursor-axis-input-discrete-delta input)
         (cursor-axis-input-source input)
         (cursor-axis-input-relative-direction input))
        (make-interaction-result :status :delivered :object application))
      (make-interaction-result :status :miss :object application)))

(defmethod interactable-key-event
    ((application wayland-application) world (seat logical-seat) input)
  (declare (ignore world))
  (etypecase input
    (key-input
     (ataxia.runtime:seat-keyboard-notify-key
      (seat-runtime-object seat)
      (key-input-time-msec input)
      (key-input-keycode input)
      (key-input-state input)))
    (modifiers-input
     (let ((keyboard (input-runtime-object (modifiers-input-device input))))
       (ataxia.runtime:seat-keyboard-notify-modifiers
        (seat-runtime-object seat) keyboard))))
  (make-interaction-result :status :delivered :object application))

(defmethod interactable-focus
    ((application wayland-application) world (seat logical-seat) focus-kind)
  (declare (ignore world))
  (ecase focus-kind
    (:keyboard
     (let ((keyboard (%seat-keyboard seat)))
       (unless keyboard
         (return-from interactable-focus
           (make-interaction-result :status :rejected :object application)))
       (ataxia.runtime:seat-keyboard-notify-enter
        (seat-runtime-object seat)
        (surface-runtime-object (application-root-surface application))
        keyboard)))
    (:clear-keyboard
     (ataxia.runtime:seat-keyboard-notify-clear-focus
      (seat-runtime-object seat)))
    (:clear-pointer
     (ataxia.runtime:seat-pointer-notify-clear-focus
      (seat-runtime-object seat))))
  (make-interaction-result
   :status :delivered :object application :focus-changed-p t))

(defun %apply-configuration-field (value function)
  (unless (eq value :unchanged)
    (funcall function value)))

(defmethod request-object-configuration
    ((application wayland-application) world
     (configuration toplevel-configuration))
  (declare (ignore world))
  (let ((toplevel (application-toplevel application))
        (width (configuration-width configuration))
        (height (configuration-height configuration))
        (bounds-width (configuration-bounds-width configuration))
        (bounds-height (configuration-bounds-height configuration)))
    (unless (and (eq width :unchanged) (eq height :unchanged))
      (ataxia.runtime:xdg-toplevel-set-size
       toplevel
       (if (eq width :unchanged) 0 width)
       (if (eq height :unchanged) 0 height)))
    (%apply-configuration-field
     (configuration-activated configuration)
     (lambda (value)
       (ataxia.runtime:xdg-toplevel-set-activated toplevel value)))
    (%apply-configuration-field
     (configuration-resizing configuration)
     (lambda (value)
       (ataxia.runtime:xdg-toplevel-set-resizing toplevel value)))
    (%apply-configuration-field
     (configuration-tiled-edges configuration)
     (lambda (value)
       (ataxia.runtime:xdg-toplevel-set-tiled toplevel value)))
    (unless (and (eq bounds-width :unchanged)
                 (eq bounds-height :unchanged))
      (ataxia.runtime:xdg-toplevel-set-bounds
       toplevel
       (if (eq bounds-width :unchanged) 0 bounds-width)
       (if (eq bounds-height :unchanged) 0 bounds-height))))
  application)

(defmethod request-object-state
    ((application wayland-application) world state value)
  (declare (ignore world))
  (let ((toplevel (application-toplevel application)))
    (ecase state
      (:maximized
       (ataxia.runtime:xdg-toplevel-set-maximized toplevel value))
      (:fullscreen
       (ataxia.runtime:xdg-toplevel-set-fullscreen toplevel value))
      (:resizing
       (ataxia.runtime:xdg-toplevel-set-resizing toplevel value))
      (:activated
       (ataxia.runtime:xdg-toplevel-set-activated toplevel value))
      (:suspended
       (ataxia.runtime:xdg-toplevel-set-suspended toplevel value))
      (:constrained
       (ataxia.runtime:xdg-toplevel-set-constrained toplevel value))
      (:close
       (ataxia.runtime:xdg-toplevel-send-close toplevel))))
  application)
