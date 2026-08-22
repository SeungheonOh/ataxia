;;;; Infinite canvas World policy and Kernel integration.
;;;;
;;;; The World is the single Kernel-facing authority. Its tables, animator,
;;;; damage tracker, renderer, cameras, and seat states are private collaborators
;;;; coordinated synchronously by these methods.

(in-package #:ataxia.infinite-world)

(defclass infinite-world (ataxia.kernel:world)
  ((kernel :initform nil :accessor ataxia.kernel:world-kernel)
   (windows :initform (make-hash-table :test #'eq) :reader %world-windows)
   (stacking :initform nil :accessor %world-stacking)
   (outputs :initform (make-hash-table :test #'eq) :reader %world-outputs)
   (seats :initform (make-hash-table :test #'eq) :reader %world-seats)
   (animator :initform (ataxia.world:make-animator) :reader %world-animator)
   (damage :initform (ataxia.world:make-damage-tracker) :reader %world-damage)
   (renderer :initform nil :accessor %world-renderer)
   (last-animation-time :initform -1d0 :accessor %world-last-animation-time)
   (quiescing-p :initform nil :accessor %world-quiescing-p))
  (:documentation
   "One unbounded planar workspace with independent output cameras and World-owned animation, damage, interaction, and GLES state."))

(defun make-infinite-world ()
  (make-instance 'infinite-world))

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

(defun find-canvas-window (world application)
  (gethash application (%world-windows world)))

(defun set-window-animation-hook (window name function)
  "Install a window-local animation launcher under an arbitrary World key."
  (check-type function function)
  (setf (gethash name (canvas-window-animation-hooks window)) function)
  window)

(defun remove-window-animation-hook (window name)
  (remhash name (canvas-window-animation-hooks window))
  window)

(defun animate-window
    (world window channel duration update
     &key (start-time (%now)) (delay 0d0)
       (easing #'ataxia.world:linear-easing) finish (repeat 0) alternate-p)
  "Animate any window-specific state through an arbitrary update closure."
  (ataxia.world:start-animation
   (%world-animator world) window channel start-time duration update
   :delay delay :easing easing :finish finish
   :repeat repeat :alternate-p alternate-p)
  (%damage-window world window)
  (%request-all-frames world)
  window)

(defun run-window-animation-hook
    (world window name &optional (timestamp (%now)))
  (let ((hook (gethash name (canvas-window-animation-hooks window))))
    (when hook
      (funcall hook world window timestamp)))
  window)

(defun %install-default-animation-hooks (window)
  (set-window-animation-hook
   window :visible
   (lambda (world subject timestamp)
     (setf (canvas-window-opacity subject) 0d0
           (canvas-window-scale subject) 0.88d0
           (canvas-window-effect subject) 1d0)
     (animate-window
      world subject :presence 0.34d0
      (lambda (target progress)
        (setf (canvas-window-opacity target) progress
              (canvas-window-scale target) (+ 0.88d0 (* 0.12d0 progress))
              (canvas-window-effect target)
              (* (- 1d0 progress) (- 1d0 progress))))
      :start-time timestamp :easing #'ataxia.world:ease-out-cubic)))
  (set-window-animation-hook
   window :engaged
   (lambda (world subject timestamp)
     (let ((start-elevation (canvas-window-elevation subject))
           (start-scale (canvas-window-scale subject)))
       (animate-window
        world subject :engagement 0.14d0
        (lambda (target progress)
          (setf (canvas-window-elevation target)
                (+ start-elevation (* (- 1d0 start-elevation) progress))
                (canvas-window-scale target)
                (+ start-scale (* (- 1.018d0 start-scale) progress))))
        :start-time timestamp :easing #'ataxia.world:ease-out-cubic))))
  (set-window-animation-hook
   window :released
   (lambda (world subject timestamp)
     (let ((start-elevation (canvas-window-elevation subject))
           (start-scale (canvas-window-scale subject)))
       (animate-window
        world subject :engagement 0.22d0
        (lambda (target progress)
          (setf (canvas-window-elevation target)
                (* start-elevation (- 1d0 progress))
                (canvas-window-scale target)
                (+ start-scale (* (- 1d0 start-scale) progress))))
        :start-time timestamp :easing #'ataxia.world:ease-out-cubic))))
  window)

(defun %request-all-frames (world)
  (unless (%world-quiescing-p world)
    (dolist (state (%output-states world))
      (ataxia.kernel:request-output-frame (%canvas-output-output state))))
  world)

(defun %request-output-state-frame (world state)
  (unless (%world-quiescing-p world)
    (ataxia.kernel:request-output-frame (%canvas-output-output state)))
  world)

(defun %damage-window (world window)
  (dolist (state (%output-states world))
    (ataxia.world:damage-add-region
     (%world-damage world) (%canvas-output-output state)
     (list (%window-buffer-coverage state window))))
  window)

(defun %damage-cursor (world seat-state)
  (let ((state (%canvas-seat-output seat-state)))
    (when state
      (ataxia.world:damage-add-region
       (%world-damage world) (%canvas-output-output state)
       (list (%screen-rectangle-to-buffer
              state
              (- (%canvas-seat-x seat-state) 4d0)
              (- (%canvas-seat-y seat-state) 4d0)
              52d0 52d0)))))
  world)

(defun %full-damage (world state)
  (ataxia.world:damage-full-output
   (%world-damage world) (%canvas-output-output state))
  (%request-output-state-frame world state))

(defun %capture-window-coverage (world)
  (let ((coverage (make-hash-table :test #'eq)))
    (dolist (window (%world-stacking world))
      (let ((per-output (make-hash-table :test #'eq)))
        (dolist (state (%output-states world))
          (setf (gethash state per-output)
                (%window-buffer-coverage state window)))
        (setf (gethash window coverage) per-output)))
    coverage))

(defun %advance-world-animations (world timestamp)
  (when (> timestamp (%world-last-animation-time world))
    (let ((old-coverage (%capture-window-coverage world)))
      (multiple-value-bind (changed active-p)
          (ataxia.world:advance-animations (%world-animator world) timestamp)
        (setf (%world-last-animation-time world) timestamp)
        (dolist (subject changed)
          (typecase subject
            (canvas-window
             (let ((before (gethash subject old-coverage)))
               (dolist (state (%output-states world))
                 (ataxia.world:damage-add-region
                  (%world-damage world) (%canvas-output-output state)
                  (list (gethash state before)
                        (%window-buffer-coverage state subject))))))
            (%canvas-output (%full-damage world subject))))
        (when active-p
          (%request-all-frames world))))))

(defun %raise-window (world window)
  (let ((old-coverage (%capture-window-coverage world)))
    (setf (%world-stacking world)
          (append (delete window (%world-stacking world) :test #'eq)
                  (list window)))
    (loop for candidate in (%world-stacking world)
          for z from 0
          do (setf (%canvas-window-z candidate) z))
    (dolist (candidate (%world-stacking world))
      (let ((before (gethash candidate old-coverage)))
        (dolist (state (%output-states world))
          (ataxia.world:damage-add-region
           (%world-damage world) (%canvas-output-output state)
           (list (gethash state before)
                 (%window-buffer-coverage state candidate)))))))
  (%request-all-frames world)
  window)

(defun %focus-window (world seat-state window)
  (let ((old (%canvas-seat-focused seat-state)))
    (unless (eq old window)
      (when old
        (ataxia.kernel:request-object-state
         (canvas-window-application old) world :activated nil))
      (setf (%canvas-seat-focused seat-state) window)
      (if window
          (progn
            (%raise-window world window)
            (ataxia.kernel:request-object-state
             (canvas-window-application window) world :activated t)
            (ataxia.kernel:interactable-focus
             (canvas-window-application window) world
             (%canvas-seat-seat seat-state) :keyboard))
          (ataxia.kernel:clear-wayland-focus
           (%canvas-seat-seat seat-state) :keyboard t))))
  window)

(defun %window-at-screen-point (world state x y)
  (dolist (window (reverse (%world-stacking world)))
    (when (%window-visible-p window)
      (multiple-value-bind (window-x window-y width height)
          (%window-screen-geometry state window)
        (when (and (<= window-x x (+ window-x width))
                   (<= window-y y (+ window-y height)))
          (return window))))))

(defun %top-visible-window (world &optional excluded)
  (find-if (lambda (window)
             (and (not (eq window excluded)) (%window-visible-p window)))
           (reverse (%world-stacking world))))

(defun %replace-focused-window (world seat-state removed-window)
  (when (eq removed-window (%canvas-seat-focused seat-state))
    (setf (%canvas-seat-focused seat-state) nil)
    (ataxia.kernel:clear-wayland-focus
     (%canvas-seat-seat seat-state) :keyboard t)
    (let ((replacement (%top-visible-window world removed-window)))
      (when replacement
        (%focus-window world seat-state replacement)))))

(defun %window-local-position (state window x y)
  (multiple-value-bind (window-x window-y width height)
      (%window-screen-geometry state window)
    (multiple-value-bind (local-x local-y local-width local-height)
        (ataxia.kernel:drawable-local-bounds
         (canvas-window-application window))
      (values (+ local-x (* (/ (- x window-x) width) local-width))
              (+ local-y (* (/ (- y window-y) height) local-height))))))

(defun %deliver-motion (world seat-state input)
  (let* ((state (%canvas-seat-output seat-state))
         (window
           (and state
                (%window-at-screen-point
                 world state (%canvas-seat-x seat-state) (%canvas-seat-y seat-state)))))
    (setf (%canvas-seat-hovered seat-state) window)
    (if window
        (multiple-value-bind (local-x local-y)
            (%window-local-position
             state window (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
          (ataxia.kernel:interactable-pointer-motion
           (canvas-window-application window) world
           (%canvas-seat-seat seat-state) local-x local-y input))
        (ataxia.kernel:clear-wayland-focus
         (%canvas-seat-seat seat-state) :pointer t))))

(defun %deliver-button-to-window (world seat-state window input &key clamp-p)
  (when window
    (multiple-value-bind (local-x local-y)
        (%window-local-position
         (%canvas-seat-output seat-state) window
         (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
      (when clamp-p
        (multiple-value-bind (bounds-x bounds-y bounds-width bounds-height)
            (ataxia.kernel:drawable-local-bounds
             (canvas-window-application window))
          (setf local-x (max bounds-x
                             (min (- (+ bounds-x bounds-width)
                                     least-positive-double-float)
                                  local-x))
                local-y (max bounds-y
                             (min (- (+ bounds-y bounds-height)
                                     least-positive-double-float)
                                  local-y)))))
      (ataxia.kernel:interactable-pointer-button
       (canvas-window-application window) world
       (%canvas-seat-seat seat-state) local-x local-y input))))

(defun %deliver-axis-to-window (world seat-state window input)
  (when window
    (multiple-value-bind (local-x local-y)
        (%window-local-position
         (%canvas-seat-output seat-state) window
         (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
      (ataxia.kernel:interactable-pointer-axis
       (canvas-window-application window) world
       (%canvas-seat-seat seat-state) local-x local-y input))))

(defun %update-seat-position (seat-state input)
  (let ((state (%canvas-seat-output seat-state)))
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (if (ataxia.kernel:cursor-motion-input-absolute-p input)
            (setf (%canvas-seat-x seat-state)
                  (* (ataxia.kernel:cursor-motion-input-x input) width)
                  (%canvas-seat-y seat-state)
                  (* (ataxia.kernel:cursor-motion-input-y input) height))
            (setf (%canvas-seat-x seat-state)
                  (+ (%canvas-seat-x seat-state)
                     (ataxia.kernel:cursor-motion-input-delta-x input))
                  (%canvas-seat-y seat-state)
                  (+ (%canvas-seat-y seat-state)
                     (ataxia.kernel:cursor-motion-input-delta-y input))))
        (setf (%canvas-seat-x seat-state)
              (max 0d0 (min (- width least-positive-double-float)
                            (%canvas-seat-x seat-state)))
              (%canvas-seat-y seat-state)
              (max 0d0 (min (- height least-positive-double-float)
                            (%canvas-seat-y seat-state))))))))

(defun %move-operation (world seat-state operation)
  (let* ((state (%canvas-seat-output seat-state))
         (window (%canvas-operation-window operation)))
    (%damage-window world window)
    (multiple-value-bind (world-x world-y)
        (%screen-to-world state (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
      (setf (canvas-window-x window) (- world-x (%canvas-operation-grab-x operation))
            (canvas-window-y window) (- world-y (%canvas-operation-grab-y operation))))
    (%damage-window world window)))

(defun %resize-operation (world seat-state operation)
  (let* ((state (%canvas-seat-output seat-state))
         (window (%canvas-operation-window operation))
         (zoom (%canvas-output-zoom state))
         (delta-x (/ (- (%canvas-seat-x seat-state)
                        (%canvas-operation-cursor-x operation)) zoom))
         (delta-y (/ (- (%canvas-seat-y seat-state)
                        (%canvas-operation-cursor-y operation)) zoom))
         (edges (%canvas-operation-edges operation))
         (x (%canvas-operation-window-x operation))
         (y (%canvas-operation-window-y operation))
         (width (%canvas-operation-window-width operation))
         (height (%canvas-operation-window-height operation)))
    (%damage-window world window)
    (when (logtest +resize-left+ edges)
      (incf x delta-x)
      (decf width delta-x))
    (when (logtest +resize-right+ edges)
      (incf width delta-x))
    (when (logtest +resize-top+ edges)
      (incf y delta-y)
      (decf height delta-y))
    (when (logtest +resize-bottom+ edges)
      (incf height delta-y))
    (when (< width 96d0)
      (when (logtest +resize-left+ edges)
        (decf x (- 96d0 width)))
      (setf width 96d0))
    (when (< height 64d0)
      (when (logtest +resize-top+ edges)
        (decf y (- 64d0 height)))
      (setf height 64d0))
    (setf (canvas-window-x window) x
          (canvas-window-y window) y
          (canvas-window-width window) width
          (canvas-window-height window) height)
    (ataxia.kernel:request-object-configuration
     (canvas-window-application window) world
     (make-instance 'ataxia.kernel:toplevel-configuration
                    :width (max 1 (round width))
                    :height (max 1 (round height))
                    :resizing t))
    (%damage-window world window)))

(defun %pan-operation (world seat-state operation)
  (let* ((state (%canvas-seat-output seat-state))
         (zoom (%canvas-output-zoom state)))
    (setf (%canvas-output-camera-x state)
          (- (%canvas-operation-camera-x operation)
             (/ (- (%canvas-seat-x seat-state)
                   (%canvas-operation-cursor-x operation)) zoom))
          (%canvas-output-camera-y state)
          (- (%canvas-operation-camera-y operation)
             (/ (- (%canvas-seat-y seat-state)
                   (%canvas-operation-cursor-y operation)) zoom)))
    (%full-damage world state)
    (%update-all-membership world)))

(defun %apply-operation (world seat-state)
  (let ((operation (%canvas-seat-operation seat-state)))
    (when operation
      (ecase (%canvas-operation-kind operation)
        (:move (%move-operation world seat-state operation))
        (:resize (%resize-operation world seat-state operation))
        (:pan (%pan-operation world seat-state operation))))))

(defun %begin-pan (seat-state)
  (let ((state (%canvas-seat-output seat-state)))
    (setf (%canvas-seat-operation seat-state)
          (%make-canvas-operation
           :kind :pan
           :button +button-middle+
           :cursor-x (%canvas-seat-x seat-state)
           :cursor-y (%canvas-seat-y seat-state)
           :camera-x (%canvas-output-camera-x state)
           :camera-y (%canvas-output-camera-y state)))))

(defun %begin-window-operation
    (world seat-state window kind &key edges forward-release-p)
  (let ((state (%canvas-seat-output seat-state)))
    (multiple-value-bind (world-x world-y)
        (%screen-to-world state (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
      (setf (%canvas-seat-operation seat-state)
            (%make-canvas-operation
             :kind kind :window window :edges edges
             :button +button-left+
             :forward-release-p forward-release-p
             :cursor-x (%canvas-seat-x seat-state)
             :cursor-y (%canvas-seat-y seat-state)
             :window-x (canvas-window-x window)
             :window-y (canvas-window-y window)
             :window-width (canvas-window-width window)
             :window-height (canvas-window-height window)
             :grab-x (- world-x (canvas-window-x window))
             :grab-y (- world-y (canvas-window-y window))))))
  (%focus-window world seat-state window)
  (run-window-animation-hook world window :engaged)
  (when (eq kind :resize)
    (ataxia.kernel:request-object-state
     (canvas-window-application window) world :resizing t)))

(defun %finish-operation (world seat-state)
  (let ((operation (%canvas-seat-operation seat-state)))
    (when operation
      (let ((window (%canvas-operation-window operation)))
        (when window
          (when (eq (%canvas-operation-kind operation) :resize)
            (ataxia.kernel:request-object-state
             (canvas-window-application window) world :resizing nil))
          (run-window-animation-hook world window :released)))
      (setf (%canvas-seat-operation seat-state) nil))))

(defun %window-output-membership (state window)
  (let* ((output (%canvas-output-output state))
         (bounds
           (ataxia.world:make-rectangle
            0 0 (%canvas-output-buffer-width state)
            (%canvas-output-buffer-height state))))
    (when (and (%window-visible-p window)
               (ataxia.world:rectangle-intersection
                bounds (%window-buffer-coverage state window)))
      output)))

(defun %update-window-membership (world window)
  (let ((outputs
          (loop for state in (%output-states world)
                for output = (%window-output-membership state window)
                when output collect output)))
    (multiple-value-bind (surfaces revision)
        (ataxia.kernel:drawable-surfaces (canvas-window-application window))
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
  (let ((cursor (%canvas-seat-cursor-surface seat-state)))
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
                    (if (%canvas-seat-output seat-state)
                        (list (%canvas-output-output
                               (%canvas-seat-output seat-state)))
                        nil)))))
             surfaces)))))

(defun %update-all-membership (world)
  (dolist (window (%world-stacking world))
    (%update-window-membership world window))
  (dolist (seat-state (%seat-states world))
    (%update-cursor-membership seat-state))
  world)

(defun %initial-window-position (world width height)
  (let* ((index (hash-table-count (%world-windows world)))
         (state (%first-output-state world))
         (offset (* 38d0 (mod index 9))))
    (if state
        (multiple-value-bind (logical-width logical-height)
            (%output-logical-size state)
          (values (+ (%canvas-output-camera-x state)
                     (/ (- (/ logical-width (%canvas-output-zoom state)) width) 2d0)
                     offset)
                  (+ (%canvas-output-camera-y state)
                     (/ (- (/ logical-height (%canvas-output-zoom state)) height) 2d0)
                     offset)))
        (values offset offset))))

(defun %make-window-binding (world application)
  (let ((width 900d0) (height 600d0))
    (multiple-value-bind (x y) (%initial-window-position world width height)
      (%install-default-animation-hooks
       (make-instance 'canvas-window
                      :application application :x x :y y
                      :width width :height height)))))

(defun %sync-window-size (window)
  (multiple-value-bind (x y width height)
      (ataxia.kernel:drawable-local-bounds (canvas-window-application window))
    (declare (ignore x y))
    (when (and (plusp width) (plusp height))
      (setf (canvas-window-width window) (coerce width 'double-float)
            (canvas-window-height window) (coerce height 'double-float))))
  window)

(defun %set-window-expanded (world window state requested-p output-state)
  (if requested-p
      (progn
        (unless (%canvas-window-restore-geometry window)
          (setf (%canvas-window-restore-geometry window)
                (list (canvas-window-x window) (canvas-window-y window)
                      (canvas-window-width window) (canvas-window-height window))))
        (multiple-value-bind (logical-width logical-height)
            (%output-logical-size output-state)
          (setf (canvas-window-x window) (%canvas-output-camera-x output-state)
                (canvas-window-y window) (%canvas-output-camera-y output-state)
                (canvas-window-width window)
                (/ logical-width (%canvas-output-zoom output-state))
                (canvas-window-height window)
                (/ logical-height (%canvas-output-zoom output-state)))))
      (when (%canvas-window-restore-geometry window)
        (destructuring-bind (x y width height)
            (%canvas-window-restore-geometry window)
          (setf (canvas-window-x window) x
                (canvas-window-y window) y
                (canvas-window-width window) width
                (canvas-window-height window) height
                (%canvas-window-restore-geometry window) nil))))
  (ataxia.kernel:request-object-state
   (canvas-window-application window) world state requested-p)
  (ataxia.kernel:request-object-configuration
   (canvas-window-application window) world
   (make-instance 'ataxia.kernel:toplevel-configuration
                  :width (max 1 (round (canvas-window-width window)))
                  :height (max 1 (round (canvas-window-height window)))))
  (%damage-window world window)
  (%request-all-frames world))

(defun set-output-camera (world output x y zoom)
  (let ((state (gethash output (%world-outputs world))))
    (unless state (error "Unknown canvas output."))
    (setf (%canvas-output-camera-x state) (coerce x 'double-float)
          (%canvas-output-camera-y state) (coerce y 'double-float)
          (%canvas-output-zoom state)
          (max 0.08d0 (min 8d0 (coerce zoom 'double-float))))
    (%full-damage world state)
    (%update-all-membership world))
  output)

(defun pan-output-camera (world output delta-x delta-y)
  (let ((state (gethash output (%world-outputs world))))
    (unless state (error "Unknown canvas output."))
    (set-output-camera
     world output
     (+ (%canvas-output-camera-x state) delta-x)
     (+ (%canvas-output-camera-y state) delta-y)
     (%canvas-output-zoom state))))

(defun zoom-output-camera
    (world output factor &key anchor-x anchor-y)
  (let ((state (gethash output (%world-outputs world))))
    (unless state (error "Unknown canvas output."))
    (multiple-value-bind (logical-width logical-height) (%output-logical-size state)
      (let* ((screen-x (coerce (or anchor-x (/ logical-width 2d0)) 'double-float))
             (screen-y (coerce (or anchor-y (/ logical-height 2d0)) 'double-float)))
        (multiple-value-bind (world-x world-y)
            (%screen-to-world state screen-x screen-y)
          (let ((zoom (max 0.08d0
                           (min 8d0 (* (%canvas-output-zoom state) factor)))))
            (set-output-camera
             world output
             (- world-x (/ screen-x zoom))
             (- world-y (/ screen-y zoom))
             zoom))))))
  output)

(defmethod ataxia.kernel:world-attached ((world infinite-world) kernel)
  (setf (ataxia.kernel:world-kernel world) kernel
        (%world-quiescing-p world) nil)
  world)

(defmethod ataxia.kernel:world-quiescing ((world infinite-world) reason)
  (declare (ignore reason))
  (setf (%world-quiescing-p world) t)
  world)

(defmethod ataxia.kernel:world-register-object
    ((world infinite-world) (application ataxia.kernel:wayland-application))
  (unless (find-canvas-window world application)
    (let ((window (%make-window-binding world application)))
      (setf (gethash application (%world-windows world)) window
            (%world-stacking world)
            (append (%world-stacking world) (list window))
            (%canvas-window-mapped-p window)
            (ataxia.kernel:application-mapped-p application))
      (when (%canvas-window-mapped-p window)
        (run-window-animation-hook world window :visible))
      (%damage-window world window)
      (%update-window-membership world window)
      (%request-all-frames world)))
  application)

(defmethod ataxia.kernel:world-unregister-object
    ((world infinite-world) (application ataxia.kernel:wayland-application) reason)
  (declare (ignore reason))
  (let ((window (find-canvas-window world application)))
    (when window
      (%damage-window world window)
      (ataxia.world:cancel-subject-animations (%world-animator world) window)
      (remhash application (%world-windows world))
      (setf (%world-stacking world)
            (delete window (%world-stacking world) :test #'eq))
      (dolist (seat-state (%seat-states world))
        (%replace-focused-window world seat-state window)
        (let ((buttons (%canvas-seat-buttons seat-state)))
          (dolist (code
                    (loop for code being the hash-keys of buttons
                          using (hash-value target)
                          when (eq target window) collect code))
            (remhash code buttons)))
        (when (and (%canvas-seat-operation seat-state)
                   (eq window
                       (%canvas-operation-window
                        (%canvas-seat-operation seat-state))))
          (setf (%canvas-seat-operation seat-state) nil)))
      (%request-all-frames world)))
  application)

(defmethod ataxia.kernel:world-object-changed
    ((world infinite-world) object change)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((window (find-canvas-window world object)))
       (when window
         (case (ataxia.kernel:object-change-kind change)
           (:mapped
            (%damage-window world window)
            (setf (%canvas-window-mapped-p window)
                  (ataxia.kernel:object-change-value change))
            (if (%canvas-window-mapped-p window)
                (progn
                  (%sync-window-size window)
                  (run-window-animation-hook world window :visible)
                  (dolist (seat-state (%seat-states world))
                    (%focus-window world seat-state window)))
                (dolist (seat-state (%seat-states world))
                  (%replace-focused-window world seat-state window)))
            (%damage-window world window)
            (%update-window-membership world window)
            (%request-all-frames world))))))
    (ataxia.kernel:surface-node
     (when (eq (ataxia.kernel:object-change-kind change) :destroying)
       (dolist (seat-state (%seat-states world))
         (when (eq object (%canvas-seat-cursor-surface seat-state))
           (%damage-cursor world seat-state)
           (setf (%canvas-seat-cursor-surface seat-state) nil)
           (%request-output-state-frame world (%canvas-seat-output seat-state)))))))
  object)

(defmethod ataxia.kernel:world-object-invalidated
    ((world infinite-world) object invalidation)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((window (find-canvas-window world object)))
       (when window
         (%damage-window world window)
         (%sync-window-size window)
         (setf (%canvas-window-drawable-revision window)
               (ataxia.kernel:drawable-invalidation-revision invalidation))
         (%damage-window world window)
         (%update-window-membership world window)
         (%request-all-frames world))))
    (ataxia.kernel:surface-node
     (dolist (seat-state (%seat-states world))
       (when (eq object (%canvas-seat-cursor-surface seat-state))
         (%damage-cursor world seat-state)
         (%update-cursor-membership seat-state)
         (%request-output-state-frame world (%canvas-seat-output seat-state))))))
  object)

(defmethod ataxia.kernel:world-output-added
    ((world infinite-world) output)
  (let ((state (%make-canvas-output output)))
    (setf (%canvas-output-buffer-width state)
          (max 1 (ataxia.kernel:output-width output))
          (%canvas-output-buffer-height state)
          (max 1 (ataxia.kernel:output-height output))
          (%canvas-output-transform state)
          (ataxia.kernel:output-transform output)
          (gethash output (%world-outputs world)) state)
    (dolist (seat-state (%seat-states world))
      (unless (%canvas-seat-output seat-state)
        (setf (%canvas-seat-output seat-state) state)
        (multiple-value-bind (width height) (%output-logical-size state)
          (setf (%canvas-seat-x seat-state) (/ width 2d0)
                (%canvas-seat-y seat-state) (/ height 2d0)))))
    (%full-damage world state)
    (%update-all-membership world))
  output)

(defmethod ataxia.kernel:world-output-changed
    ((world infinite-world) output change)
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
            (setf (%canvas-output-buffer-width state)
                  (max 1 (ataxia.kernel:output-width output))
                  (%canvas-output-buffer-height state)
                  (max 1 (ataxia.kernel:output-height output))
                  (%canvas-output-transform state)
                  (ataxia.kernel:output-transform output))
            (ataxia.world:damage-reset-output (%world-damage world) output)))
      (%request-output-state-frame world state)
      (%update-all-membership world)))
  output)

(defmethod ataxia.kernel:world-output-removing
    ((world infinite-world) output)
  (let ((state (gethash output (%world-outputs world))))
    (when state
      (remhash output (%world-outputs world))
      (ataxia.world:damage-forget-output (%world-damage world) output)
      (dolist (seat-state (%seat-states world))
        (when (eq state (%canvas-seat-output seat-state))
          (setf (%canvas-seat-output seat-state) (%first-output-state world))))))
  output)

(defmethod ataxia.kernel:world-seat-added
    ((world infinite-world) seat)
  (let* ((state (%first-output-state world))
         (seat-state (%make-canvas-seat seat)))
    (setf (%canvas-seat-output seat-state) state)
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (setf (%canvas-seat-x seat-state) (/ width 2d0)
              (%canvas-seat-y seat-state) (/ height 2d0))))
    (setf (gethash seat (%world-seats world)) seat-state)
    (%damage-cursor world seat-state)
    (%request-all-frames world))
  seat)

(defmethod ataxia.kernel:world-seat-removing
    ((world infinite-world) seat)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state (%damage-cursor world seat-state))
    (remhash seat (%world-seats world))
    (%request-all-frames world))
  seat)

(defmethod ataxia.kernel:world-cursor-motion
    ((world infinite-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (%update-seat-position seat-state input)
      (if (%canvas-seat-operation seat-state)
          (%apply-operation world seat-state)
          (%deliver-motion world seat-state input))
      (%damage-cursor world seat-state)
      (%request-output-state-frame world (%canvas-seat-output seat-state))))
  input)

(defmethod ataxia.kernel:world-cursor-button
    ((world infinite-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (let* ((code (ataxia.kernel:cursor-button-input-code input))
             (pressed-p (eq (ataxia.kernel:cursor-button-input-state input)
                            :pressed))
             (buttons (%canvas-seat-buttons seat-state)))
        (if pressed-p
            (let ((window
                    (%window-at-screen-point
                     world (%canvas-seat-output seat-state)
                     (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))))
              (when window (%focus-window world seat-state window))
              (if (= code +button-middle+)
                  (progn
                    (setf (gethash code buttons) :world)
                    (%begin-pan seat-state))
                  (progn
                    (setf (gethash code buttons) (or window :world))
                    (%deliver-button-to-window
                     world seat-state window input :clamp-p nil))))
            (let ((target (gethash code buttons))
                  (operation (%canvas-seat-operation seat-state)))
              (cond
                ((and operation
                      (= code (%canvas-operation-button operation)))
                 (when (%canvas-operation-forward-release-p operation)
                   (%deliver-button-to-window
                    world seat-state (%canvas-operation-window operation)
                    input :clamp-p t))
                 (%finish-operation world seat-state))
                ((typep target 'canvas-window)
                 (%deliver-button-to-window
                  world seat-state target input :clamp-p t)))
              (remhash code buttons)))
        (%damage-cursor world seat-state)
        (%request-all-frames world))))
  input)

(defmethod ataxia.kernel:world-cursor-axis
    ((world infinite-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (let ((window
              (%window-at-screen-point
               world (%canvas-seat-output seat-state)
               (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))))
        (if window
            (%deliver-axis-to-window world seat-state window input)
            (when (eq (ataxia.kernel:cursor-axis-input-orientation input)
                      :vertical)
              (zoom-output-camera
               world
               (%canvas-output-output (%canvas-seat-output seat-state))
               (exp (* -0.0025d0
                       (ataxia.kernel:cursor-axis-input-delta input)))
               :anchor-x (%canvas-seat-x seat-state)
               :anchor-y (%canvas-seat-y seat-state)))))))
  input)

(defmethod ataxia.kernel:world-key-event
    ((world infinite-world) seat input)
  (let* ((seat-state (gethash seat (%world-seats world)))
         (window (and seat-state (%canvas-seat-focused seat-state))))
    (when (and window (%window-visible-p window))
      (ataxia.kernel:interactable-key-event
       (canvas-window-application window) world seat input)))
  input)

(defmethod ataxia.kernel:world-seat-cursor-request
    ((world infinite-world) seat request)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (setf (%canvas-seat-cursor-surface seat-state)
            (ataxia.kernel:cursor-surface-request-surface request)
            (%canvas-seat-cursor-hotspot-x seat-state)
            (ataxia.kernel:cursor-surface-request-hotspot-x request)
            (%canvas-seat-cursor-hotspot-y seat-state)
            (ataxia.kernel:cursor-surface-request-hotspot-y request))
      (%update-cursor-membership seat-state)
      (%damage-cursor world seat-state)
      (%request-all-frames world)))
  request)

(defmethod ataxia.kernel:world-client-request
    ((world infinite-world) (application ataxia.kernel:wayland-application)
     request)
  (let ((window (find-canvas-window world application)))
    (when window
      (typecase request
        (ataxia.kernel:move-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq window
                          (gethash +button-left+
                                   (%canvas-seat-buttons seat-state))))
             (%begin-window-operation
              world seat-state window :move :forward-release-p t))))
        (ataxia.kernel:resize-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq window
                          (gethash +button-left+
                                   (%canvas-seat-buttons seat-state))))
             (%begin-window-operation
              world seat-state window :resize
              :edges (ataxia.kernel:resize-client-request-edges request)
              :forward-release-p t))))
        (ataxia.kernel:fullscreen-client-request
         (when (%canvas-window-mapped-p window)
           (%damage-window world window)
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
            (when (%canvas-window-mapped-p window)
              (%damage-window world window)
              (%set-window-expanded
               world window :maximized
               (ataxia.kernel:state-client-request-value request)
               (%first-output-state world))))
           (:minimized
            (%damage-window world window)
            (setf (%canvas-window-hidden-p window)
                  (ataxia.kernel:state-client-request-value request))
            (%damage-window world window)
            (%update-window-membership world window)
            (%request-all-frames world))
           (otherwise
            (ataxia.kernel:request-object-state
             application world
             (ataxia.kernel:state-client-request-name request)
             (ataxia.kernel:state-client-request-value request))))))))
  request)

(defmethod ataxia.kernel:world-graphics-attached
    ((world infinite-world) graphics-context)
  (declare (ignore graphics-context))
  (setf (%world-renderer world) (%create-canvas-renderer))
  (dolist (state (%output-states world))
    (%full-damage world state))
  world)

(defmethod ataxia.kernel:world-render
    ((world infinite-world) lease)
  (let* ((output (ataxia.kernel:frame-output lease))
         (state (gethash output (%world-outputs world))))
    (unless (and state (%world-renderer world))
      (error "Infinite World cannot render an unattached output."))
    (let ((geometry-changed-p
            (or (/= (%canvas-output-buffer-width state)
                    (ataxia.kernel:frame-width lease))
                (/= (%canvas-output-buffer-height state)
                    (ataxia.kernel:frame-height lease))
                (/= (%canvas-output-transform state)
                    (ataxia.kernel:frame-transform lease)))))
      (setf (%canvas-output-buffer-width state)
            (ataxia.kernel:frame-width lease)
            (%canvas-output-buffer-height state)
            (ataxia.kernel:frame-height lease)
            (%canvas-output-transform state)
            (ataxia.kernel:frame-transform lease))
      (when geometry-changed-p
        (ataxia.world:damage-reset-output (%world-damage world) output)))
    (%advance-world-animations world (ataxia.kernel:frame-timestamp lease))
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
                  (%render-canvas
                   (%world-renderer world) state
                   (%world-stacking world) (%seat-states world) region)
                  #())))
        (make-instance
         'ataxia.kernel:world-frame-result
         :target-token (ataxia.kernel:frame-target-token lease)
         :damage (ataxia.world:region-to-frame-damage
                  region
                  (ataxia.kernel:frame-width lease)
                  (ataxia.kernel:frame-height lease))
         :protocol-tokens tokens
         :complete-p t
         :world-cookie (%make-world-frame-cookie damage-frame))))))

(defmethod ataxia.kernel:world-frame-committed
    ((world infinite-world) output frame-result commit-info)
  (declare (ignore output commit-info))
  (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
    (when cookie
      (ataxia.world:damage-commit-frame
       (%world-damage world) (%world-frame-cookie-damage-frame cookie))))
  frame-result)

(defmethod ataxia.kernel:world-frame-failed
    ((world infinite-world) output frame-result reason)
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
    ((world infinite-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (when (%world-renderer world)
    (%destroy-canvas-renderer (%world-renderer world))
    (setf (%world-renderer world) nil))
  world)
