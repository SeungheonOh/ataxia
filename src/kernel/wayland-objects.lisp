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
               :generation (surface-commit-sequence surface)))
        (%register-object kernel surface :runtime-object runtime-surface)
        (setf (gethash runtime-surface (%kernel-surface-table kernel)) surface)
        surface)))

(defun %surface-damage-bounds (x y width height)
  ;; wlroots returns popup positions as doubles. Drawable placement may retain
  ;; them, but pixel damage must cover the translated rectangle with integers.
  (let ((left (floor x)) (top (floor y)))
    (make-frame-damage-rectangle left top (- (ceiling (+ x width)) left)
                                (- (ceiling (+ y height)) top))))

(defun %runtime-damage-rectangles (rectangles &optional (offset-x 0) (offset-y 0))
  (mapcar
   (lambda (rectangle)
     (%surface-damage-bounds
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
          (%surface-buffer-transform surface) transform
          (%surface-frame-callback-p surface)
          (ataxia.runtime:surface-has-frame-callbacks-p (surface-runtime-object surface))
          (%surface-opaque-region surface)
          (%runtime-damage-rectangles
           (ataxia.runtime:surface-opaque-region (surface-runtime-object surface)))))
  (when commit
    (setf (surface-commit-sequence surface)
          (ataxia.runtime:surface-commit-sequence commit)
          (%surface-damage surface)
          (%runtime-damage-rectangles
           (ataxia.runtime:surface-commit-damage-rectangles commit)))
    (setf (%surface-protocol-token surface)
          (make-instance
           'surface-protocol-token
           :surface surface
           :generation (surface-commit-sequence surface))))
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

(defun %inverse-buffer-transform (transform)
  (case transform
    (1 3)
    (3 1)
    (otherwise transform)))

(defun %transform-texture-point (transform x y)
  (case transform
    (0 (values x y))
    (1 (values (- 1d0 y) x))
    (2 (values (- 1d0 x) (- 1d0 y)))
    (3 (values y (- 1d0 x)))
    (4 (values (- 1d0 x) y))
    (5 (values (- 1d0 y) (- 1d0 x)))
    (6 (values x (- 1d0 y)))
    (7 (values y x))
    (otherwise (values x y))))

(defun %surface-texture-coordinates (surface)
  (let* ((box (%surface-source-box surface))
         (left (aref box 0))
         (top (aref box 1))
         (width (aref box 2))
         (height (aref box 3))
         (transform (%inverse-buffer-transform
                     (%surface-buffer-transform surface)))
         (coordinates (make-array 8 :element-type 'double-float)))
    (loop for (x y) in '((0d0 0d0) (1d0 0d0) (0d0 1d0) (1d0 1d0))
          for index from 0 by 2
          do (multiple-value-bind (u v)
                 (%transform-texture-point transform x y)
               (setf (aref coordinates index)
                     (coerce (+ left (* u width)) 'double-float)
                     (aref coordinates (1+ index))
                     (coerce (+ top (* v height)) 'double-float))))
    coordinates))

(defun %drawable-surface-identity (surface)
  (let ((token (drawable-surface-presentation-token surface)))
    (if token (%protocol-token-surface token)
        (drawable-surface-render-source surface))))

(defun %same-surface-placement-p (first second)
  (and (eq (%drawable-surface-identity first) (%drawable-surface-identity second))
       (= (drawable-surface-local-x first) (drawable-surface-local-x second))
       (= (drawable-surface-local-y first) (drawable-surface-local-y second))
       (= (drawable-surface-width first) (drawable-surface-width second))
       (= (drawable-surface-height first) (drawable-surface-height second))
       (equalp (drawable-surface-opaque-region first) (drawable-surface-opaque-region second))))

(defun %drawable-surface-damage (surface)
  (%surface-damage-bounds (drawable-surface-local-x surface) (drawable-surface-local-y surface)
                          (drawable-surface-width surface) (drawable-surface-height surface)))

(defun %rebuild-application-drawables (application)
  (let ((records nil)
        (damage nil)
        (old (%application-drawable-surfaces application)))
    (%walk-surface-tree
     (application-root-surface application)
     (lambda (surface x y)
       (when (and (surface-mapped-p surface)
                  (%surface-render-source surface)
                  (plusp (surface-width surface))
                  (plusp (surface-height surface)))
         (push
          (make-instance
           'wayland-drawable-surface
           :local-x x
           :local-y y
           :width (surface-width surface)
           :height (surface-height surface)
           :texture-coordinates (%surface-texture-coordinates surface)
           :render-source (%surface-render-source surface)
           :opaque-region (%surface-opaque-region surface)
           :frame-callback-p (%surface-frame-callback-p surface)
           :presentation-token (%surface-protocol-token surface))
          records)
         (dolist (rectangle (%surface-damage surface))
           (push
            (%surface-damage-bounds
             (+ x (frame-damage-rectangle-x rectangle))
             (+ y (frame-damage-rectangle-y rectangle))
             (frame-damage-rectangle-width rectangle)
             (frame-damage-rectangle-height rectangle))
            damage)))))
    (setf records (coerce (nreverse records) 'vector))
    ;; Buffer damage does not describe moved, mapped, or removed quads. Damage
    ;; both placements, including areas outside the root surface. Stable quads
    ;; keep the client's narrow buffer damage and do not wake idle outputs.
    ;; Compare in stacking order as well: moving a quad through another quad
    ;; changes visible pixels even when both rectangles stay in place.
    (loop for surface across old for index from 0
          unless (and (< index (length records))
                      (%same-surface-placement-p surface (aref records index)))
            do (pushnew (%drawable-surface-damage surface) damage :test #'equalp))
    (loop for surface across records for index from 0
          unless (and (< index (length old))
                      (%same-surface-placement-p surface (aref old index)))
            do (pushnew (%drawable-surface-damage surface) damage :test #'equalp))
    (setf (%application-drawable-surfaces application) records)
    (incf (%application-drawable-revision application))
    (nreverse damage)))

(defmethod drawable-surfaces ((surface surface-node))
  (let ((source (%surface-render-source surface)))
    (values
     (if (and source (surface-mapped-p surface))
         (vector
          (make-instance
           'wayland-drawable-surface
           :local-x 0
           :local-y 0
           :width (surface-width surface)
           :height (surface-height surface)
           :texture-coordinates (%surface-texture-coordinates surface)
           :render-source source
           :opaque-region (%surface-opaque-region surface)
           :frame-callback-p (%surface-frame-callback-p surface)
           :presentation-token (%surface-protocol-token surface)))
         #())
     (surface-commit-sequence surface))))

(defmethod drawable-local-bounds ((surface surface-node))
  (values 0 0 (surface-width surface) (surface-height surface)))

(defun %invalidate-application (application)
  ;; A popup's final offset is committed after its creation/reposition request.
  ;; Refresh from the same committed geometry that wlroots uses for hit testing.
  ;; Parent window geometry can also change without a commit on the popup.
  (maphash
   (lambda (popup surface)
     (when (and (surface-mapped-p surface)
                (eq application (%surface-tree-application surface)))
       (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
         (setf (surface-local-x surface) x
               (surface-local-y surface) y))))
   (%kernel-popup-table (object-kernel application)))
  (let ((damage (%rebuild-application-drawables application)))
    (%call-world
     (object-kernel application) world-object-invalidated application
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

(defun %retire-surface-node (surface &key (protocol-active-p t))
  (when (eq (object-state surface) :live)
    (let* ((kernel (object-kernel surface))
           (application (%surface-tree-application surface))
           (runtime-surface (surface-runtime-object surface)))
      (%detach-surface-node surface)
      (dolist (child (surface-children surface))
        (setf (surface-parent child) nil
              (%surface-application child) nil))
      (setf (surface-children surface) nil)
      (maphash
       (lambda (output present-p)
         (declare (ignore present-p))
         (when protocol-active-p
           (ataxia.runtime:surface-send-leave
            (surface-runtime-object surface)
            (output-runtime-object output))))
       (%surface-output-membership surface))
      (clrhash (%surface-output-membership surface))
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
    (%register-object kernel application :runtime-object toplevel)
    (setf (gethash toplevel (%kernel-toplevel-table kernel)) application)
    (%call-world kernel world-register-object application)
    application))

(defun %retire-wayland-application (application reason)
  (when (eq (object-state application) :live)
    (let ((kernel (object-kernel application)))
      (%call-world
       kernel world-unregister-object application reason)
      (remhash (application-toplevel application)
               (%kernel-toplevel-table kernel))
      (%retire-object
       kernel application
       :runtime-object (application-toplevel application))))
  application)

(defun %pointer-event-time (input)
  (etypecase input
    (cursor-motion-input (cursor-motion-input-time-msec input))
    (cursor-button-input (cursor-button-input-time-msec input))
    (cursor-axis-input (cursor-axis-input-time-msec input))))

(defun %application-surface-at (application local-x local-y)
  (ataxia.runtime:xdg-surface-at
   (application-toplevel application) local-x local-y))

(defun %application-pointer-surface-at (application seat local-x local-y)
  ;; wlroots leaves implicit pointer grabs to the compositor. Preserve the
  ;; pressed wl_surface, not just its application, until all buttons release.
  ;; Explicit popup and data-device grabs keep their own routing semantics.
  (let ((runtime-seat (seat-runtime-object seat)))
    (when (or (ataxia.runtime:seat-pointer-has-grab-p runtime-seat)
              ;; A World gesture can consume release; Runtime still releases
              ;; its protocol button even when no interactable receives it.
              (notany (lambda (code)
                        (plusp (ataxia.runtime:seat-pointer-button-press-count runtime-seat code)))
                      (getf (%seat-implicit-pointer-grab seat) :buttons)))
      (setf (%seat-implicit-pointer-grab seat) nil)))
  (let* ((grab (%seat-implicit-pointer-grab seat))
         (surface (getf grab :surface)))
    (when grab
      (return-from %application-pointer-surface-at
        (when (and (eq application (getf grab :application))
                   (eq :live (object-state surface)) (surface-mapped-p surface)
                   (ataxia.runtime:seat-pointer-surface-has-focus-p
                    (seat-runtime-object seat) (surface-runtime-object surface)))
          (let ((x 0) (y 0))
            (loop for node = surface then (surface-parent node) while node do
                  (incf x (surface-local-x node)) (incf y (surface-local-y node)))
            (values (surface-runtime-object surface) (- local-x x) (- local-y y)))))))
  (%application-surface-at application local-x local-y))

(defun %enter-application-surface (application seat local-x local-y input)
  (multiple-value-bind (surface surface-x surface-y)
      (%application-pointer-surface-at application seat local-x local-y)
    (when surface
      (ataxia.runtime:seat-pointer-notify-enter
       (seat-runtime-object seat) surface surface-x surface-y)
      (ataxia.runtime:seat-pointer-notify-motion
       (seat-runtime-object seat) (%pointer-event-time input)
       surface-x surface-y)
      (values surface surface-x surface-y))))

(defmethod interactable-hit-test
    ((application wayland-application) world local-x local-y)
  (declare (ignore world))
  (not (null (%application-surface-at application local-x local-y))))

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
  (let ((code (cursor-button-input-code input))
        (pressed (eq :pressed (cursor-button-input-state input)))
        (runtime-seat (seat-runtime-object seat)))
    (unwind-protect
         (let ((surface (%enter-application-surface application seat local-x local-y input)))
           (if surface
               (progn
                 (ataxia.runtime:seat-pointer-notify-button
                  runtime-seat (cursor-button-input-time-msec input) code
                  (cursor-button-input-state input))
                 (when (and pressed
                            (not (ataxia.runtime:seat-pointer-has-grab-p runtime-seat))
                            (ataxia.runtime:seat-pointer-surface-has-focus-p runtime-seat surface))
                   (unless (%seat-implicit-pointer-grab seat)
                     (setf (%seat-implicit-pointer-grab seat)
                           (list :application application
                                 :surface (gethash surface (%kernel-surface-table (object-kernel application)))
                                 :buttons nil)))
                   (push code (getf (%seat-implicit-pointer-grab seat) :buttons)))
                 (make-interaction-result :status :delivered :object application))
               (make-interaction-result :status :miss :object application)))
      (when (and (not pressed) (%seat-implicit-pointer-grab seat))
        (setf (getf (%seat-implicit-pointer-grab seat) :buttons)
              (remove code (getf (%seat-implicit-pointer-grab seat) :buttons) :count 1))
        (unless (getf (%seat-implicit-pointer-grab seat) :buttons)
          (setf (%seat-implicit-pointer-grab seat) nil))))))

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

(defmethod interactable-pointer-leave
    ((application wayland-application) world (seat logical-seat))
  (declare (ignore world))
  (clear-wayland-focus seat :pointer t)
  (make-interaction-result
   :status :delivered :object application :focus-changed-p t))

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
     (clear-wayland-focus seat :pointer t)))
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
