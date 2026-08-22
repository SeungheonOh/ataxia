;;;; Packed atlas World policy and Kernel integration.
;;;;
;;;; This object is the sole Kernel-facing authority for the packed plane. It
;;;; owns the ordered window set, derived layout, cameras, input interpretation,
;;;; damage history, and GLES renderer while Kernel retains Wayland mechanics.

(in-package #:ataxia.atlas-world)

(defclass atlas-world (ataxia.kernel:world)
  ((kernel :initform nil :accessor ataxia.kernel:world-kernel)
   (windows :initform (make-hash-table :test #'eq) :reader %world-windows)
   (order :initform nil :accessor %world-order)
   (layout :initform (%make-atlas-layout) :reader %world-layout)
   (outputs :initform (make-hash-table :test #'eq) :reader %world-outputs)
   (seats :initform (make-hash-table :test #'eq) :reader %world-seats)
   (damage :initform (ataxia.world:make-damage-tracker) :reader %world-damage)
   (renderer :initform nil :accessor %world-renderer)
   (quiescing-p :initform nil :accessor %world-quiescing-p))
  (:documentation
   "A packed, coordinate-free window plane with per-output parallel cameras."))

(defun make-atlas-world ()
  (make-instance 'atlas-world))

(defun %now ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defun %hash-values (table)
  (loop for value being the hash-values of table collect value))

(defun %output-states (world)
  (%hash-values (%world-outputs world)))

(defun %seat-states (world)
  (%hash-values (%world-seats world)))

(defun %first-output-state (world)
  (first (%output-states world)))

(defun find-atlas-window (world application)
  (gethash application (%world-windows world)))

(defun %visible-windows (world)
  (remove-if-not #'%window-visible-p (%world-order world)))

(defun %request-output-state-frame (world state)
  (when (and state (not (%world-quiescing-p world)))
    (ataxia.kernel:request-output-frame (%atlas-output-output state)))
  world)

(defun %request-all-frames (world)
  (dolist (state (%output-states world))
    (%request-output-state-frame world state))
  world)

(defun %full-damage (world state)
  (when state
    (ataxia.world:damage-full-output
     (%world-damage world) (%atlas-output-output state))
    (%request-output-state-frame world state))
  world)

(defun %full-damage-all (world)
  (dolist (state (%output-states world))
    (%full-damage world state))
  world)

(defun %damage-window (world window &optional (timestamp (%now)))
  (when (%window-visible-p window)
    (dolist (state (%output-states world))
      (let ((coverage
              (%window-buffer-coverage
               state (%world-layout world) window timestamp)))
        (when coverage
          (ataxia.world:damage-add-region
           (%world-damage world) (%atlas-output-output state)
           (list coverage))))))
  window)

(defun %damage-cursor (world seat-state)
  (let ((state (%atlas-seat-output seat-state)))
    (when state
      (ataxia.world:damage-add-region
       (%world-damage world) (%atlas-output-output state)
       (list (%screen-rectangle-to-buffer
              state (- (%atlas-seat-x seat-state) 4d0)
              (- (%atlas-seat-y seat-state) 4d0) 52d0 52d0)))))
  world)

(defun fit-output-camera (world output)
  "Fit the complete derived atlas into OUTPUT and return OUTPUT."
  (let ((state (gethash output (%world-outputs world)))
        (layout (%world-layout world)))
    (unless state (error "Unknown atlas output."))
    (multiple-value-bind (logical-width logical-height)
        (%output-logical-size state)
      (let* ((atlas-width (max 1d0 (%atlas-layout-width layout)))
             (atlas-height (max 1d0 (%atlas-layout-height layout)))
             (zoom
               (max 0.05d0
                    (min 6d0
                         (min (/ (max 1d0 (- logical-width 72d0)) atlas-width)
                              (/ (max 1d0 (- logical-height 72d0)) atlas-height))))))
        (setf (%atlas-output-zoom state) zoom
              (%atlas-output-camera-x state)
              (- (/ atlas-width 2d0) (/ logical-width (* 2d0 zoom)))
              (%atlas-output-camera-y state)
              (- (/ atlas-height 2d0) (/ logical-height (* 2d0 zoom)))
              (%atlas-output-camera-authored-p state) nil)))
    (%full-damage world state)
    (%update-all-membership world))
  output)

(defun set-output-camera (world output x y zoom)
  "Set OUTPUT's parallel camera without changing any window placement."
  (let ((state (gethash output (%world-outputs world))))
    (unless state (error "Unknown atlas output."))
    (setf (%atlas-output-camera-x state) (coerce x 'double-float)
          (%atlas-output-camera-y state) (coerce y 'double-float)
          (%atlas-output-zoom state)
          (max 0.05d0 (min 8d0 (coerce zoom 'double-float)))
          (%atlas-output-camera-authored-p state) t)
    (%full-damage world state)
    (%update-all-membership world))
  output)

(defun %zoom-output-camera (world state factor anchor-x anchor-y)
  (multiple-value-bind (world-x world-y)
      (%screen-to-world state anchor-x anchor-y)
    (let ((zoom
            (max 0.05d0
                 (min 8d0 (* (%atlas-output-zoom state) factor)))))
      (setf (%atlas-output-zoom state) zoom
            (%atlas-output-camera-x state) (- world-x (/ anchor-x zoom))
            (%atlas-output-camera-y state) (- world-y (/ anchor-y zoom))
            (%atlas-output-camera-authored-p state) t)
      (%full-damage world state)
      (%update-all-membership world))))

(defun %capture-current-layout (world timestamp)
  (let ((captured (make-hash-table :test #'eq))
        (layout (%world-layout world)))
    (dolist (window (%visible-windows world))
      (multiple-value-bind (x y width height)
          (%placement-geometry layout window timestamp)
        (when x
          (setf (gethash window captured)
                (%make-atlas-placement window x y width height)))))
    (and (plusp (hash-table-count captured)) captured)))

(defun %repack-world (world &key (animate-p t))
  (let* ((timestamp (%now))
         (layout (%world-layout world))
         (previous (and animate-p (%capture-current-layout world timestamp))))
    (multiple-value-bind (placements width height)
        (%pack-atlas (%visible-windows world))
      (setf (%atlas-layout-previous layout) previous
            (%atlas-layout-placements layout) placements
            (%atlas-layout-width layout) width
            (%atlas-layout-height layout) height
            (%atlas-layout-transition-start layout) timestamp)
      (incf (%atlas-layout-revision layout)))
    (dolist (state (%output-states world))
      (if (%atlas-output-camera-authored-p state)
          (%full-damage world state)
          (fit-output-camera world (%atlas-output-output state))))
    (%update-all-membership world)
    (%revalidate-all-pointers world))
  world)

(defun %visual-animation-active-p (world timestamp)
  (or (and (%atlas-layout-previous (%world-layout world))
           (< (%layout-transition-progress (%world-layout world) timestamp) 1d0))
      (some (lambda (window)
              (let ((start (%atlas-window-appearance-start window)))
                (and start (< (- timestamp start) 0.18d0))))
            (%visible-windows world))))

(defun %advance-visual-state (world timestamp)
  (let ((layout (%world-layout world)))
    (when (%atlas-layout-previous layout)
      (if (< (%layout-transition-progress layout timestamp) 1d0)
          (progn
            (%full-damage-all world)
            (%revalidate-all-pointers world))
          (progn
            (setf (%atlas-layout-previous layout) nil)
            (%full-damage-all world)))))
  (dolist (window (%visible-windows world))
    (let ((start (%atlas-window-appearance-start window)))
      (when start
        (%damage-window world window timestamp)
        (when (>= (- timestamp start) 0.18d0)
          (setf (%atlas-window-appearance-start window) nil)))))
  (when (%visual-animation-active-p world timestamp)
    (%request-all-frames world)))

(defun %focus-window (world seat-state window)
  (let ((old (%atlas-seat-focused seat-state)))
    (unless (eq old window)
      (when old
        (ataxia.kernel:request-object-state
         (atlas-window-application old) world :activated nil))
      (setf (%atlas-seat-focused seat-state) window)
      (if window
          (progn
            (ataxia.kernel:request-object-state
             (atlas-window-application window) world :activated t)
            (ataxia.kernel:interactable-focus
             (atlas-window-application window) world
             (%atlas-seat-seat seat-state) :keyboard))
          (ataxia.kernel:clear-wayland-focus
           (%atlas-seat-seat seat-state) :keyboard t))))
  window)

(defun %top-visible-window (world &optional excluded)
  (find-if (lambda (window)
             (and (not (eq window excluded)) (%window-visible-p window)))
           (reverse (%world-order world))))

(defun %replace-focused-window (world seat-state removed-window)
  (when (eq removed-window (%atlas-seat-focused seat-state))
    (setf (%atlas-seat-focused seat-state) nil)
    (ataxia.kernel:clear-wayland-focus
     (%atlas-seat-seat seat-state) :keyboard t)
    (let ((replacement (%top-visible-window world removed-window)))
      (when replacement (%focus-window world seat-state replacement)))))

(defun %window-at-screen-point (world state x y &optional (timestamp (%now)))
  (when state
    (dolist (window (reverse (%world-order world)))
      (when (%window-visible-p window)
        (multiple-value-bind (window-x window-y width height)
            (%window-screen-geometry
             state (%world-layout world) window timestamp)
          (when (and window-x
                     (<= window-x x (+ window-x width))
                     (<= window-y y (+ window-y height)))
            (return window)))))))

(defun %window-local-position (world state window x y)
  (multiple-value-bind (window-x window-y width height)
      (%window-screen-geometry state (%world-layout world) window (%now))
    (multiple-value-bind (local-x local-y local-width local-height)
        (ataxia.kernel:drawable-local-bounds
         (atlas-window-application window))
      (values (+ local-x (* (/ (- x window-x) width) local-width))
              (+ local-y (* (/ (- y window-y) height) local-height))))))

(defun %deliver-motion (world seat-state input)
  (let* ((state (%atlas-seat-output seat-state))
         (window
           (%window-at-screen-point
            world state (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))))
    (setf (%atlas-seat-hovered seat-state) window)
    (if window
        (multiple-value-bind (local-x local-y)
            (%window-local-position
             world state window
             (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
          (ataxia.kernel:interactable-pointer-motion
           (atlas-window-application window) world
           (%atlas-seat-seat seat-state) local-x local-y input))
        (ataxia.kernel:clear-wayland-focus
         (%atlas-seat-seat seat-state) :pointer t))))

(defun %revalidate-seat-pointer (world seat-state &optional input)
  (unless (or (%atlas-seat-operation seat-state)
              (plusp (hash-table-count (%atlas-seat-buttons seat-state))))
    (%deliver-motion
     world seat-state
     (or input (%atlas-seat-last-pointer-input seat-state)
         (ataxia.kernel:make-cursor-motion-input :time-msec 0)))))

(defun %revalidate-all-pointers (world)
  (dolist (seat-state (%seat-states world))
    (%revalidate-seat-pointer world seat-state))
  world)

(defun %deliver-button-to-window (world seat-state window input &key clamp-p)
  (when window
    (multiple-value-bind (local-x local-y)
        (%window-local-position
         world (%atlas-seat-output seat-state) window
         (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
      (when clamp-p
        (multiple-value-bind (bounds-x bounds-y bounds-width bounds-height)
            (ataxia.kernel:drawable-local-bounds
             (atlas-window-application window))
          (setf local-x
                (max bounds-x
                     (min (- (+ bounds-x bounds-width)
                             least-positive-double-float)
                          local-x))
                local-y
                (max bounds-y
                     (min (- (+ bounds-y bounds-height)
                             least-positive-double-float)
                          local-y)))))
      (ataxia.kernel:interactable-pointer-button
       (atlas-window-application window) world
       (%atlas-seat-seat seat-state) local-x local-y input))))

(defun %deliver-axis-to-window (world seat-state window input)
  (when window
    (multiple-value-bind (local-x local-y)
        (%window-local-position
         world (%atlas-seat-output seat-state) window
         (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
      (ataxia.kernel:interactable-pointer-axis
       (atlas-window-application window) world
       (%atlas-seat-seat seat-state) local-x local-y input))))

(defun %update-seat-position (seat-state input)
  (let ((state (%atlas-seat-output seat-state)))
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (if (ataxia.kernel:cursor-motion-input-absolute-p input)
            (setf (%atlas-seat-x seat-state)
                  (* (ataxia.kernel:cursor-motion-input-x input) width)
                  (%atlas-seat-y seat-state)
                  (* (ataxia.kernel:cursor-motion-input-y input) height))
            (setf (%atlas-seat-x seat-state)
                  (+ (%atlas-seat-x seat-state)
                     (ataxia.kernel:cursor-motion-input-delta-x input))
                  (%atlas-seat-y seat-state)
                  (+ (%atlas-seat-y seat-state)
                     (ataxia.kernel:cursor-motion-input-delta-y input))))
        (setf (%atlas-seat-x seat-state)
              (max 0d0 (min (- width least-positive-double-float)
                            (%atlas-seat-x seat-state)))
              (%atlas-seat-y seat-state)
              (max 0d0 (min (- height least-positive-double-float)
                            (%atlas-seat-y seat-state))))))))

(defun %begin-pan (seat-state button &key window forward-release-p)
  (let ((state (%atlas-seat-output seat-state)))
    (setf (%atlas-seat-operation seat-state)
          (%make-atlas-operation
           :kind :pan :button button :window window
           :forward-release-p forward-release-p
           :cursor-x (%atlas-seat-x seat-state)
           :cursor-y (%atlas-seat-y seat-state)
           :camera-x (%atlas-output-camera-x state)
           :camera-y (%atlas-output-camera-y state)))))

(defun %restart-pan-anchor (seat-state)
  (let ((operation (%atlas-seat-operation seat-state))
        (state (%atlas-seat-output seat-state)))
    (when (and operation (eq (%atlas-operation-kind operation) :pan))
      (setf (%atlas-operation-cursor-x operation) (%atlas-seat-x seat-state)
            (%atlas-operation-cursor-y operation) (%atlas-seat-y seat-state)
            (%atlas-operation-camera-x operation) (%atlas-output-camera-x state)
            (%atlas-operation-camera-y operation) (%atlas-output-camera-y state)))))

(defun %begin-resize (world seat-state window edges)
  (setf (%atlas-seat-operation seat-state)
        (%make-atlas-operation
         :kind :resize :button +button-left+ :window window :edges edges
         :forward-release-p t
         :cursor-x (%atlas-seat-x seat-state)
         :cursor-y (%atlas-seat-y seat-state)
         :window-width (atlas-window-width window)
         :window-height (atlas-window-height window)))
  (%focus-window world seat-state window)
  (ataxia.kernel:request-object-state
   (atlas-window-application window) world :resizing t))

(defun %apply-pan (world seat-state operation)
  (let* ((state (%atlas-seat-output seat-state))
         (zoom (%atlas-output-zoom state)))
    (setf (%atlas-output-camera-x state)
          (- (%atlas-operation-camera-x operation)
             (/ (- (%atlas-seat-x seat-state)
                   (%atlas-operation-cursor-x operation)) zoom))
          (%atlas-output-camera-y state)
          (- (%atlas-operation-camera-y operation)
             (/ (- (%atlas-seat-y seat-state)
                   (%atlas-operation-cursor-y operation)) zoom))
          (%atlas-output-camera-authored-p state) t)
    (%full-damage world state)
    (%update-all-membership world)))

(defun %apply-resize (world seat-state operation)
  (let* ((state (%atlas-seat-output seat-state))
         (window (%atlas-operation-window operation))
         (zoom (%atlas-output-zoom state))
         (delta-x (/ (- (%atlas-seat-x seat-state)
                        (%atlas-operation-cursor-x operation)) zoom))
         (delta-y (/ (- (%atlas-seat-y seat-state)
                        (%atlas-operation-cursor-y operation)) zoom))
         (edges (%atlas-operation-edges operation))
         (width (%atlas-operation-window-width operation))
         (height (%atlas-operation-window-height operation)))
    (when (logtest +resize-left+ edges) (decf width delta-x))
    (when (logtest +resize-right+ edges) (incf width delta-x))
    (when (logtest +resize-top+ edges) (decf height delta-y))
    (when (logtest +resize-bottom+ edges) (incf height delta-y))
    (setf (atlas-window-width window) (max 96d0 width)
          (atlas-window-height window) (max 64d0 height))
    (ataxia.kernel:request-object-configuration
     (atlas-window-application window) world
     (make-instance 'ataxia.kernel:toplevel-configuration
                    :width (round (atlas-window-width window))
                    :height (round (atlas-window-height window))
                    :resizing t))
    (%repack-world world :animate-p nil)))

(defun %apply-operation (world seat-state)
  (let ((operation (%atlas-seat-operation seat-state)))
    (when operation
      (ecase (%atlas-operation-kind operation)
        (:pan (%apply-pan world seat-state operation))
        (:resize (%apply-resize world seat-state operation))))))

(defun %finish-operation (world seat-state input)
  (let ((operation (%atlas-seat-operation seat-state)))
    (when operation
      (let ((window (%atlas-operation-window operation)))
        (when (and window (%atlas-operation-forward-release-p operation))
          (%deliver-button-to-window
           world seat-state window input :clamp-p t))
        (when (and window (eq (%atlas-operation-kind operation) :resize))
          (ataxia.kernel:request-object-state
           (atlas-window-application window) world :resizing nil)))
      (setf (%atlas-seat-operation seat-state) nil)
      (%revalidate-seat-pointer world seat-state input))))

(defun %window-resize-active-p (world window)
  (some (lambda (seat-state)
          (let ((operation (%atlas-seat-operation seat-state)))
            (and operation
                 (eq (%atlas-operation-kind operation) :resize)
                 (eq (%atlas-operation-window operation) window))))
        (%seat-states world)))

(defun %sync-window-size (window)
  (multiple-value-bind (x y width height)
      (ataxia.kernel:drawable-local-bounds (atlas-window-application window))
    (declare (ignore x y))
    (when (and (plusp width) (plusp height))
      (let ((new-width (coerce width 'double-float))
            (new-height (coerce height 'double-float)))
        (unless (and (= new-width (atlas-window-width window))
                     (= new-height (atlas-window-height window)))
          (setf (atlas-window-width window) new-width
                (atlas-window-height window) new-height)
          (return-from %sync-window-size t)))))
  nil)

(defun %window-output-membership (world state window)
  (let ((coverage
          (%window-buffer-coverage
           state (%world-layout world) window (%now))))
    (when (and coverage
               (ataxia.world:rectangle-intersection
                (ataxia.world:make-rectangle
                 0 0 (%atlas-output-buffer-width state)
                 (%atlas-output-buffer-height state))
                coverage))
      (%atlas-output-output state))))

(defun %update-window-membership (world window)
  (let ((outputs
          (loop for state in (%output-states world)
                for output = (%window-output-membership world state window)
                when output collect output)))
    (multiple-value-bind (surfaces revision)
        (ataxia.kernel:drawable-surfaces (atlas-window-application window))
      (declare (ignore revision))
      (map nil
           (lambda (surface)
             (let ((token
                     (ataxia.kernel:drawable-surface-protocol-token surface)))
               (when token
                 (ataxia.kernel:set-wayland-surface-output-membership
                  token outputs))))
           surfaces))))

(defun %update-cursor-membership (seat-state)
  (let ((cursor (%atlas-seat-cursor-surface seat-state)))
    (when (and cursor (eq (ataxia.kernel:object-state cursor) :live))
      (multiple-value-bind (surfaces revision)
          (ataxia.kernel:drawable-surfaces cursor)
        (declare (ignore revision))
        (map nil
             (lambda (surface)
               (let ((token
                       (ataxia.kernel:drawable-surface-protocol-token surface)))
                 (when token
                   (ataxia.kernel:set-wayland-surface-output-membership
                    token
                    (if (%atlas-seat-output seat-state)
                        (list (%atlas-output-output
                               (%atlas-seat-output seat-state)))
                        nil)))))
             surfaces)))))

(defun %update-all-membership (world)
  (dolist (window (%world-order world))
    (%update-window-membership world window))
  (dolist (seat-state (%seat-states world))
    (%update-cursor-membership seat-state))
  world)

(defun %set-window-expanded (world window state requested-p output-state)
  (when output-state
    (if requested-p
        (progn
          (unless (%atlas-window-restore-size window)
            (setf (%atlas-window-restore-size window)
                  (cons (atlas-window-width window)
                        (atlas-window-height window))))
          (multiple-value-bind (logical-width logical-height)
              (%output-logical-size output-state)
            (setf (atlas-window-width window)
                  (/ logical-width (%atlas-output-zoom output-state))
                  (atlas-window-height window)
                  (/ logical-height (%atlas-output-zoom output-state)))))
        (when (%atlas-window-restore-size window)
          (setf (atlas-window-width window)
                (car (%atlas-window-restore-size window))
                (atlas-window-height window)
                (cdr (%atlas-window-restore-size window))
                (%atlas-window-restore-size window) nil)))
    (%repack-world world :animate-p nil)
    (when requested-p
      (multiple-value-bind (x y width height)
          (%placement-geometry (%world-layout world) window (%now))
        (declare (ignore width height))
        (when x
          (setf (%atlas-output-camera-x output-state) x
                (%atlas-output-camera-y output-state) y
                (%atlas-output-camera-authored-p output-state) t))))
    (ataxia.kernel:request-object-state
     (atlas-window-application window) world state requested-p)
    (ataxia.kernel:request-object-configuration
     (atlas-window-application window) world
     (make-instance 'ataxia.kernel:toplevel-configuration
                    :width (round (atlas-window-width window))
                    :height (round (atlas-window-height window))))
    (%full-damage world output-state)))

(defmethod ataxia.kernel:world-attached ((world atlas-world) kernel)
  (setf (ataxia.kernel:world-kernel world) kernel
        (%world-quiescing-p world) nil)
  world)

(defmethod ataxia.kernel:world-quiescing ((world atlas-world) reason)
  (declare (ignore reason))
  (setf (%world-quiescing-p world) t)
  world)

(defmethod ataxia.kernel:world-register-object
    ((world atlas-world) (application ataxia.kernel:wayland-application))
  (unless (find-atlas-window world application)
    (let ((window
            (make-instance
             'atlas-window :application application
             :width 900d0 :height 600d0)))
      (setf (gethash application (%world-windows world)) window
            (%world-order world)
            (append (%world-order world) (list window))
            (%atlas-window-mapped-p window)
            (ataxia.kernel:application-mapped-p application))
      (when (%atlas-window-mapped-p window)
        (%sync-window-size window)
        (setf (%atlas-window-appearance-start window) (%now)))
      (%repack-world world)))
  application)

(defmethod ataxia.kernel:world-unregister-object
    ((world atlas-world) (application ataxia.kernel:wayland-application) reason)
  (declare (ignore reason))
  (let ((window (find-atlas-window world application)))
    (when window
      (%damage-window world window)
      (remhash application (%world-windows world))
      (setf (%world-order world)
            (delete window (%world-order world) :test #'eq))
      (dolist (seat-state (%seat-states world))
        (%replace-focused-window world seat-state window)
        (let ((buttons (%atlas-seat-buttons seat-state)))
          (dolist (code
                    (loop for code being the hash-keys of buttons
                          using (hash-value target)
                          when (eq target window) collect code))
            (remhash code buttons)))
        (when (and (%atlas-seat-operation seat-state)
                   (eq window
                       (%atlas-operation-window
                        (%atlas-seat-operation seat-state))))
          (setf (%atlas-seat-operation seat-state) nil)))
      (%repack-world world)))
  application)

(defmethod ataxia.kernel:world-object-changed
    ((world atlas-world) object change)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((window (find-atlas-window world object)))
       (when (and window
                  (eq (ataxia.kernel:object-change-kind change) :mapped))
         (%damage-window world window)
         (setf (%atlas-window-mapped-p window)
               (ataxia.kernel:object-change-value change))
         (if (%atlas-window-mapped-p window)
             (progn
               (%sync-window-size window)
               (setf (%atlas-window-appearance-start window) (%now))
               (dolist (seat-state (%seat-states world))
                 (%focus-window world seat-state window)))
             (dolist (seat-state (%seat-states world))
               (%replace-focused-window world seat-state window)))
         (%repack-world world))))
    (ataxia.kernel:surface-node
     (when (eq (ataxia.kernel:object-change-kind change) :destroying)
       (dolist (seat-state (%seat-states world))
         (when (eq object (%atlas-seat-cursor-surface seat-state))
           (%damage-cursor world seat-state)
           (setf (%atlas-seat-cursor-surface seat-state) nil)
           (%request-output-state-frame
            world (%atlas-seat-output seat-state)))))))
  object)

(defmethod ataxia.kernel:world-object-invalidated
    ((world atlas-world) object invalidation)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((window (find-atlas-window world object)))
       (when window
         (%damage-window world window)
         (let ((size-changed-p
                 (and (not (%window-resize-active-p world window))
                      (%sync-window-size window))))
           (setf (%atlas-window-drawable-revision window)
                 (ataxia.kernel:drawable-invalidation-revision invalidation))
           (if size-changed-p
               (%repack-world world)
               (progn
                 (%damage-window world window)
                 (%update-window-membership world window)
                 (%request-all-frames world)))))))
    (ataxia.kernel:surface-node
     (dolist (seat-state (%seat-states world))
       (when (eq object (%atlas-seat-cursor-surface seat-state))
         (%damage-cursor world seat-state)
         (%update-cursor-membership seat-state)
         (%request-output-state-frame world (%atlas-seat-output seat-state))))))
  object)

(defmethod ataxia.kernel:world-output-added ((world atlas-world) output)
  (let ((state (%make-atlas-output output)))
    (setf (%atlas-output-buffer-width state)
          (max 1 (ataxia.kernel:output-width output))
          (%atlas-output-buffer-height state)
          (max 1 (ataxia.kernel:output-height output))
          (%atlas-output-transform state)
          (ataxia.kernel:output-transform output)
          (gethash output (%world-outputs world)) state)
    (dolist (seat-state (%seat-states world))
      (unless (%atlas-seat-output seat-state)
        (setf (%atlas-seat-output seat-state) state)
        (multiple-value-bind (width height) (%output-logical-size state)
          (setf (%atlas-seat-x seat-state) (/ width 2d0)
                (%atlas-seat-y seat-state) (/ height 2d0)))))
    (fit-output-camera world output))
  output)

(defmethod ataxia.kernel:world-output-changed
    ((world atlas-world) output change)
  (let ((state (gethash output (%world-outputs world))))
    (when state
      (if (eq (ataxia.kernel:object-change-kind change) :backend-damage)
          (ataxia.world:damage-add-region
           (%world-damage world) output
           (mapcar
            (lambda (rectangle)
              (ataxia.world:make-rectangle
               (ataxia.kernel:frame-damage-rectangle-x rectangle)
               (ataxia.kernel:frame-damage-rectangle-y rectangle)
               (ataxia.kernel:frame-damage-rectangle-width rectangle)
               (ataxia.kernel:frame-damage-rectangle-height rectangle)))
            (ataxia.kernel:object-change-value change)))
          (progn
            (setf (%atlas-output-buffer-width state)
                  (max 1 (ataxia.kernel:output-width output))
                  (%atlas-output-buffer-height state)
                  (max 1 (ataxia.kernel:output-height output))
                  (%atlas-output-transform state)
                  (ataxia.kernel:output-transform output))
            (ataxia.world:damage-reset-output (%world-damage world) output)
            (unless (%atlas-output-camera-authored-p state)
              (fit-output-camera world output))))
      (%request-output-state-frame world state)
      (%update-all-membership world)))
  output)

(defmethod ataxia.kernel:world-output-removing ((world atlas-world) output)
  (let ((state (gethash output (%world-outputs world))))
    (when state
      (remhash output (%world-outputs world))
      (ataxia.world:damage-forget-output (%world-damage world) output)
      (dolist (seat-state (%seat-states world))
        (when (eq state (%atlas-seat-output seat-state))
          (setf (%atlas-seat-output seat-state) (%first-output-state world))))))
  output)

(defmethod ataxia.kernel:world-seat-added ((world atlas-world) seat)
  (let* ((state (%first-output-state world))
         (seat-state (%make-atlas-seat seat)))
    (setf (%atlas-seat-output seat-state) state)
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (setf (%atlas-seat-x seat-state) (/ width 2d0)
              (%atlas-seat-y seat-state) (/ height 2d0))))
    (setf (gethash seat (%world-seats world)) seat-state)
    (%damage-cursor world seat-state)
    (%request-all-frames world))
  seat)

(defmethod ataxia.kernel:world-seat-removing ((world atlas-world) seat)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state (%damage-cursor world seat-state))
    (remhash seat (%world-seats world))
    (%request-all-frames world))
  seat)

(defmethod ataxia.kernel:world-cursor-motion
    ((world atlas-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (setf (%atlas-seat-last-pointer-input seat-state) input)
      (%update-seat-position seat-state input)
      (if (%atlas-seat-operation seat-state)
          (%apply-operation world seat-state)
          (%deliver-motion world seat-state input))
      (%damage-cursor world seat-state)
      (%request-output-state-frame world (%atlas-seat-output seat-state))))
  input)

(defmethod ataxia.kernel:world-cursor-button
    ((world atlas-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (let* ((code (ataxia.kernel:cursor-button-input-code input))
             (pressed-p
               (eq (ataxia.kernel:cursor-button-input-state input) :pressed))
             (buttons (%atlas-seat-buttons seat-state)))
        (if pressed-p
            (let ((window
                    (%window-at-screen-point
                     world (%atlas-seat-output seat-state)
                     (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))))
              (when window (%focus-window world seat-state window))
              (if (= code +button-middle+)
                  (progn
                    (setf (gethash code buttons) :world)
                    (%begin-pan seat-state code))
                  (progn
                    (setf (gethash code buttons) (or window :world))
                    (%deliver-button-to-window
                     world seat-state window input :clamp-p nil))))
            (let ((target (gethash code buttons))
                  (operation (%atlas-seat-operation seat-state)))
              (cond
                ((and operation (= code (%atlas-operation-button operation)))
                 (%finish-operation world seat-state input))
                ((typep target 'atlas-window)
                 (%deliver-button-to-window
                  world seat-state target input :clamp-p t)))
              (remhash code buttons)
              (%revalidate-seat-pointer world seat-state input)))
        (%damage-cursor world seat-state)
        (%request-all-frames world))))
  input)

(defmethod ataxia.kernel:world-cursor-axis
    ((world atlas-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (let* ((state (%atlas-seat-output seat-state))
             (operation (%atlas-seat-operation seat-state))
             (window
               (%window-at-screen-point
                world state (%atlas-seat-x seat-state)
                (%atlas-seat-y seat-state)))
             (zoom-p
               (and (eq (ataxia.kernel:cursor-axis-input-orientation input)
                        :vertical)
                    (or (and operation
                             (eq (%atlas-operation-kind operation) :pan))
                        (null window)))))
        (if zoom-p
            (progn
              (%zoom-output-camera
               world state
               (exp (* -0.0025d0
                       (ataxia.kernel:cursor-axis-input-delta input)))
               (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
              (%restart-pan-anchor seat-state)
              (%revalidate-seat-pointer world seat-state input))
            (%deliver-axis-to-window world seat-state window input)))))
  input)

(defmethod ataxia.kernel:world-key-event ((world atlas-world) seat input)
  (let* ((seat-state (gethash seat (%world-seats world)))
         (window (and seat-state (%atlas-seat-focused seat-state))))
    (when (and window (%window-visible-p window))
      (ataxia.kernel:interactable-key-event
       (atlas-window-application window) world seat input)))
  input)

(defmethod ataxia.kernel:world-seat-cursor-request
    ((world atlas-world) seat request)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (setf (%atlas-seat-cursor-surface seat-state)
            (ataxia.kernel:cursor-surface-request-surface request)
            (%atlas-seat-cursor-hotspot-x seat-state)
            (ataxia.kernel:cursor-surface-request-hotspot-x request)
            (%atlas-seat-cursor-hotspot-y seat-state)
            (ataxia.kernel:cursor-surface-request-hotspot-y request))
      (%update-cursor-membership seat-state)
      (%damage-cursor world seat-state)
      (%request-all-frames world)))
  request)

(defmethod ataxia.kernel:world-client-request
    ((world atlas-world) (application ataxia.kernel:wayland-application)
     request)
  (let ((window (find-atlas-window world application)))
    (when window
      (typecase request
        (ataxia.kernel:move-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq window
                          (gethash +button-left+
                                   (%atlas-seat-buttons seat-state))))
             (%begin-pan
              seat-state +button-left+ :window window
              :forward-release-p t))))
        (ataxia.kernel:resize-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq window
                          (gethash +button-left+
                                   (%atlas-seat-buttons seat-state))))
             (%begin-resize
              world seat-state window
              (ataxia.kernel:resize-client-request-edges request)))))
        (ataxia.kernel:fullscreen-client-request
         (when (%atlas-window-mapped-p window)
           (%set-window-expanded
            world window :fullscreen
            (ataxia.kernel:state-client-request-value request)
            (or (and (ataxia.kernel:fullscreen-client-request-output request)
                     (gethash
                      (ataxia.kernel:fullscreen-client-request-output request)
                      (%world-outputs world)))
                (%first-output-state world)))))
        (ataxia.kernel:state-client-request
         (case (ataxia.kernel:state-client-request-name request)
           (:maximized
            (when (%atlas-window-mapped-p window)
              (%set-window-expanded
               world window :maximized
               (ataxia.kernel:state-client-request-value request)
               (%first-output-state world))))
           (:minimized
            (%damage-window world window)
            (setf (%atlas-window-hidden-p window)
                  (ataxia.kernel:state-client-request-value request))
            (%repack-world world))
           (otherwise
            (ataxia.kernel:request-object-state
             application world
             (ataxia.kernel:state-client-request-name request)
             (ataxia.kernel:state-client-request-value request))))))))
  request)

(defmethod ataxia.kernel:world-graphics-attached
    ((world atlas-world) graphics-context)
  (declare (ignore graphics-context))
  (setf (%world-renderer world) (%create-atlas-renderer))
  (%full-damage-all world)
  world)

(defmethod ataxia.kernel:world-render ((world atlas-world) lease)
  (let* ((output (ataxia.kernel:frame-output lease))
         (state (gethash output (%world-outputs world)))
         (timestamp (ataxia.kernel:frame-timestamp lease)))
    (unless (and state (%world-renderer world))
      (error "Atlas World cannot render an unattached output."))
    (let ((geometry-changed-p
            (or (/= (%atlas-output-buffer-width state)
                    (ataxia.kernel:frame-width lease))
                (/= (%atlas-output-buffer-height state)
                    (ataxia.kernel:frame-height lease))
                (/= (%atlas-output-transform state)
                    (ataxia.kernel:frame-transform lease)))))
      (setf (%atlas-output-buffer-width state)
            (ataxia.kernel:frame-width lease)
            (%atlas-output-buffer-height state)
            (ataxia.kernel:frame-height lease)
            (%atlas-output-transform state)
            (ataxia.kernel:frame-transform lease))
      (when geometry-changed-p
        (ataxia.world:damage-reset-output (%world-damage world) output)))
    (%advance-visual-state world timestamp)
    (%update-all-membership world)
    (multiple-value-bind (region damage-frame)
        (ataxia.world:damage-begin-frame
         (%world-damage world) output
         (ataxia.kernel:frame-target-token lease)
         (ataxia.kernel:frame-generation lease)
         (ataxia.kernel:frame-width lease)
         (ataxia.kernel:frame-height lease))
      (let ((tokens
              (if region
                  (%render-atlas
                   (%world-renderer world) state (%world-layout world)
                   (%world-order world) (%seat-states world) region timestamp)
                  #())))
        (make-instance
         'ataxia.kernel:world-frame-result
         :target-token (ataxia.kernel:frame-target-token lease)
         :damage (ataxia.world:region-to-frame-damage
                  region (ataxia.kernel:frame-width lease)
                  (ataxia.kernel:frame-height lease))
         :protocol-tokens tokens
         :complete-p t
         :world-cookie (%make-world-frame-cookie damage-frame))))))

(defmethod ataxia.kernel:world-frame-committed
    ((world atlas-world) output frame-result commit-info)
  (declare (ignore output commit-info))
  (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
    (when cookie
      (ataxia.world:damage-commit-frame
       (%world-damage world) (%world-frame-cookie-damage-frame cookie))))
  frame-result)

(defmethod ataxia.kernel:world-frame-failed
    ((world atlas-world) output frame-result reason)
  (declare (ignore reason))
  (when frame-result
    (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
      (when cookie
        (ataxia.world:damage-fail-frame
         (%world-damage world) (%world-frame-cookie-damage-frame cookie)))))
  (when (and output (eq (ataxia.kernel:object-state output) :live))
    (ataxia.kernel:request-output-frame output))
  frame-result)

(defmethod ataxia.kernel:world-graphics-detaching
    ((world atlas-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (when (%world-renderer world)
    (%destroy-atlas-renderer (%world-renderer world))
    (setf (%world-renderer world) nil))
  world)
