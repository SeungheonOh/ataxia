;;;; Infinite canvas World policy and Kernel integration.
;;;;
;;;; The World is the single Kernel-facing authority. Its tables, animator,
;;;; damage tracker, renderer, cameras, and seat states are private collaborators
;;;; coordinated synchronously by these methods.

(in-package #:ataxia.infinite-world)

(declaim (ftype function
                %view-shift-for-seat
                %sync-view-shift-overlay
                %update-view-shift-modifiers
                %advance-view-shifts
                %end-view-shift
                %end-view-shifts-for-output
                %end-all-view-shifts))

(ataxia.world:define-shortcuts %make-infinite-shortcut-controller
  (:application-launcher
   (:key (:keysym :space) :modifiers (:logo))
   (:press (world seat input)
     (declare (ignore input))
     (toggle-application-launcher world seat))))

(defclass infinite-world (ataxia.world:ui-host ataxia.kernel:world)
  ((kernel :initform nil :accessor ataxia.kernel:world-kernel)
   (windows :initform (make-hash-table :test #'eq) :reader %world-windows)
   (stacking :initform nil :accessor %world-stacking)
   (outputs :initform (make-hash-table :test #'eq) :reader %world-outputs)
   (seats :initform (make-hash-table :test #'eq) :reader %world-seats)
   (pending-tab-drops :initform (make-hash-table :test #'eq) :reader %world-pending-tab-drops)
   (view-shifts :initform (make-hash-table :test #'eq)
                :reader %world-view-shifts)
   (shortcuts :initform (%make-infinite-shortcut-controller)
              :reader ataxia.world:world-shortcut-controller)
   (overlays :initform nil :accessor world-overlays)
   (retired-overlays :initform nil :accessor %world-retired-overlays)
   (component-timer :initform nil :accessor %world-component-timer)
   (animator :initform (ataxia.world:make-animator) :reader %world-animator)
   (damage :initform (ataxia.world:make-damage-tracker) :reader %world-damage)
   (damage-debug-p :initarg :damage-debug-p :initform nil
                   :accessor %world-damage-debug-p)
   (renderer :initform nil :accessor %world-renderer)
   (last-animation-time :initform -1d0 :accessor %world-last-animation-time)
   (quiescing-p :initform nil :accessor %world-quiescing-p))
  (:documentation
   "One unbounded planar workspace with independent output cameras and World-owned animation, damage, interaction, and GLES state."))

(defun make-infinite-world (&key damage-debug-p)
  (make-instance 'infinite-world :damage-debug-p damage-debug-p))

(defmethod ataxia.world:damage-debug-mode-p ((world infinite-world))
  (%world-damage-debug-p world))

(defmethod (setf ataxia.world:damage-debug-mode-p)
    (enabled (world infinite-world))
  (setf (%world-damage-debug-p world) enabled))

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
  (when (and state (not (%world-quiescing-p world)))
    (ataxia.kernel:request-output-frame (%canvas-output-output state)))
  world)

(defun %component-animation-active-p (world)
  (some (lambda (overlay)
          (and (overlay-visible-p overlay)
               (ataxia.kernel:drawable-active-p
                (overlay-component overlay))))
        (world-overlays world)))

(defun %visible-component-p (world)
  (some #'overlay-visible-p (world-overlays world)))

(defun %updatable-overlay-p (world overlay)
  (let ((state (gethash (overlay-output overlay) (%world-outputs world))))
    (and state (%overlay-visible-on-state-p overlay state)
         (multiple-value-bind (width height) (%output-logical-size state)
           (and (< (overlay-x overlay) width)
                (< (overlay-y overlay) height)
                (> (+ (overlay-x overlay) (overlay-width overlay)) 0)
                (> (+ (overlay-y overlay) (overlay-height overlay)) 0))))))

(defun %service-ui-engines (world)
  (let ((serviced nil))
    (dolist (overlay (world-overlays world))
      (when (%updatable-overlay-p world overlay)
        (let* ((component (overlay-component overlay))
               (key (ataxia.world:ui-service-key component)))
          (when (and key (not (member key serviced)))
            (push key serviced)
            (ataxia.world:ui-service component)))))
    (dolist (overlay (world-overlays world))
      (when (%updatable-overlay-p world overlay)
        (ataxia.world:ui-dispatch-callbacks (overlay-component overlay))))))

(defun %schedule-component-timer (world)
  (let ((timer (%world-component-timer world)) (deadline nil))
    (when timer
      (dolist (overlay (world-overlays world))
        (when (%updatable-overlay-p world overlay)
          (let* ((component (overlay-component overlay))
                 (active (ataxia.kernel:drawable-active-p component))
                 (delay (ataxia.world:ui-next-update-delay component)))
            (when (or active (and delay (zerop delay)))
              (%request-output-state-frame
               world (gethash (overlay-output overlay) (%world-outputs world))))
            (when (and delay (plusp delay))
              (setf deadline (if deadline (min deadline delay) delay))))))
      (ataxia.runtime:update-event-loop-timer
       timer (if deadline (max 1 (min (ceiling deadline) 86400000)) 0))))
  world)

(defun %component-timer-fired (world source)
  (declare (ignore source))
  (unless (%world-quiescing-p world)
    (%service-ui-engines world)
    (%schedule-component-timer world))
  0)

(defun %install-component-timer (world)
  (unless (%world-component-timer world)
    (setf (%world-component-timer world)
          (ataxia.runtime:add-event-loop-timer
           (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
           (lambda (source)
             (unless (%world-quiescing-p world)
               (ataxia.kernel:call-with-current-world
                (ataxia.kernel:world-kernel world)
                (lambda (current)
                  (when (eq current world) (%component-timer-fired world source)))
                :operation :ui-timer))
             0)))
    (%schedule-component-timer world))
  world)

(defun %remove-component-timer (world)
  (when (%world-component-timer world)
    (ataxia.runtime:remove-event-loop-source (%world-component-timer world))
    (setf (%world-component-timer world) nil))
  world)

(defun %damage-window (world window)
  (dolist (state (%output-states world))
    (let ((region (ataxia.world:clip-region
                   (list (%window-buffer-coverage state window))
                   (%canvas-output-buffer-width state) (%canvas-output-buffer-height state))))
      (when region
        (ataxia.world:damage-add-region
         (%world-damage world) (%canvas-output-output state) region))))
  window)

(defun %damage-window-region (world window rectangles)
  (when (and rectangles (%window-visible-p window))
    (multiple-value-bind (local-x local-y local-width local-height)
        (ataxia.kernel:drawable-local-bounds
         (canvas-window-application window))
      (when (and (plusp local-width) (plusp local-height))
        (dolist (state (%output-states world))
          (multiple-value-bind (screen-x screen-y screen-width screen-height)
              (%window-canvas-geometry state window)
            (let ((region
                    (ataxia.world:coalesce-damage-region
                     (mapcar
                      (lambda (rectangle)
                        (%canvas-rectangle-to-buffer
                         state
                         (+ screen-x
                            (* screen-width
                               (/ (- (ataxia.world:rectangle-x rectangle) local-x) local-width)))
                         (+ screen-y
                            (* screen-height
                               (/ (- (ataxia.world:rectangle-y rectangle) local-y) local-height)))
                         (* screen-width (/ (ataxia.world:rectangle-width rectangle) local-width))
                         (* screen-height (/ (ataxia.world:rectangle-height rectangle) local-height))))
                      rectangles)
                     :width (%canvas-output-buffer-width state) :height (%canvas-output-buffer-height state))))
              (setf region (%visible-window-damage world state window region))
              (when region
                (ataxia.world:damage-add-region
                 (%world-damage world) (%canvas-output-output state) region))))))))
  window)

(defun %damage-overlay (world overlay)
  (let ((state (gethash (overlay-output overlay)
                        (%world-outputs world))))
    (when state
      (let ((region (ataxia.world:clip-region
                     (list (%overlay-buffer-coverage state overlay))
                     (%canvas-output-buffer-width state) (%canvas-output-buffer-height state))))
        (when region
          (ataxia.world:damage-add-region
           (%world-damage world) (overlay-output overlay) region)))))
  overlay)

(defun %damage-overlay-region (world overlay rectangles)
  (let ((state (gethash (overlay-output overlay)
                        (%world-outputs world))))
    (when (and state rectangles)
      (multiple-value-bind (local-x local-y local-width local-height)
          (ataxia.kernel:drawable-local-bounds
           (overlay-component overlay))
        (when (and (plusp local-width) (plusp local-height))
          (ataxia.world:damage-add-region
           (%world-damage world) (overlay-output overlay)
           (mapcar
            (lambda (rectangle)
              (%screen-rectangle-to-buffer
               state
               (+ (overlay-x overlay)
                  (* (overlay-width overlay)
                     (/ (- (ataxia.world:rectangle-x rectangle) local-x)
                        local-width)))
               (+ (overlay-y overlay)
                  (* (overlay-height overlay)
                     (/ (- (ataxia.world:rectangle-y rectangle) local-y)
                        local-height)))
               (* (overlay-width overlay)
                  (/ (ataxia.world:rectangle-width rectangle) local-width))
               (* (overlay-height overlay)
                  (/ (ataxia.world:rectangle-height rectangle) local-height))))
            rectangles))))))
  overlay)

(defmethod add-overlay ((world infinite-world) overlay)
  "Insert an output-local drawable/interactable above the window scene."
  (check-type world infinite-world)
  (check-type overlay ui-overlay)
  (unless (member overlay (world-overlays world) :test #'eq)
    (setf (world-overlays world)
          (stable-sort (append (world-overlays world) (list overlay)) #'<
                       :key #'overlay-layer))
    (%damage-overlay world overlay)
    (let ((state (gethash (overlay-output overlay)
                          (%world-outputs world))))
      (when state (%request-output-state-frame world state)))
    (%schedule-component-timer world))
  overlay)

(defmethod remove-overlay ((world infinite-world) overlay)
  "Remove OVERLAY from the scene and retire its graphics on the next frame."
  (when (member overlay (world-overlays world) :test #'eq)
    (%damage-overlay world overlay)
    (dolist (seat-state (%seat-states world))
      (when (eq overlay (%canvas-seat-hovered seat-state))
        (ataxia.kernel:interactable-pointer-leave
         (overlay-component overlay) world
         (%canvas-seat-seat seat-state))
        (setf (%canvas-seat-hovered seat-state) nil))
      (when (eq overlay (%canvas-seat-focused seat-state))
        (%focus-target world seat-state nil))
      (let ((buttons (%canvas-seat-buttons seat-state)))
        (dolist (code
                  (loop for code being the hash-keys of buttons
                        using (hash-value target)
                        when (eq target overlay) collect code))
          (remhash code buttons))))
    (setf (world-overlays world)
          (delete overlay (world-overlays world) :test #'eq))
    (pushnew overlay (%world-retired-overlays world) :test #'eq)
    (let ((state (gethash (overlay-output overlay)
                          (%world-outputs world))))
      (when state (%request-output-state-frame world state)))
    (%schedule-component-timer world))
  overlay)

(defmethod show-overlay ((world infinite-world) overlay)
  "Make OVERLAY visible and damage its output-local bounds."
  (unless (member overlay (world-overlays world) :test #'eq)
    (error "Overlay does not belong to this World."))
  (unless (overlay-visible-p overlay)
    (setf (overlay-visible-p overlay) t)
    (overlay-visibility-changed overlay t)
    (%damage-overlay world overlay)
    (let ((state (gethash (overlay-output overlay)
                          (%world-outputs world))))
      (when state (%request-output-state-frame world state)))
    (%schedule-component-timer world))
  overlay)

(defmethod hide-overlay ((world infinite-world) overlay)
  "Hide OVERLAY, restore displaced keyboard focus, and repaint its old bounds."
  (when (overlay-visible-p overlay)
    (%damage-overlay world overlay)
    (setf (overlay-visible-p overlay) nil)
    (overlay-visibility-changed overlay nil)
    (%schedule-component-timer world)
    (dolist (seat-state (%seat-states world))
      (when (eq overlay (%canvas-seat-hovered seat-state))
        (ataxia.kernel:interactable-pointer-leave
         (overlay-component overlay) world
         (%canvas-seat-seat seat-state))
        (setf (%canvas-seat-hovered seat-state) nil))
      (when (eq overlay (%canvas-seat-focused seat-state))
        (let ((previous (%canvas-seat-previous-focus seat-state)))
          (setf (%canvas-seat-previous-focus seat-state) nil)
          (%focus-target
           world seat-state
           (if (%target-visible-p previous)
               previous
               (%top-visible-window world)))))
      (let ((buttons (%canvas-seat-buttons seat-state)))
        (dolist (code
                  (loop for code being the hash-keys of buttons
                        using (hash-value target)
                        when (eq target overlay) collect code))
          (remhash code buttons))))
    (let ((state (gethash (overlay-output overlay)
                          (%world-outputs world))))
      (when state (%request-output-state-frame world state))))
  overlay)

(defun %reap-retired-overlays (world)
  (dolist (overlay (%world-retired-overlays world))
    (destroy-overlay overlay))
  (setf (%world-retired-overlays world) nil)
  world)

(defun %cursor-buffer-coverage (state seat-state)
  (append (%drag-icon-buffer-coverage state seat-state)
          (%cursor-only-buffer-coverage state seat-state)))

(defun %drag-icon-buffer-coverage (state seat-state)
  (let ((icon (ataxia.kernel:seat-drag-icon (%canvas-seat-seat seat-state)))
        (x (%canvas-seat-x seat-state)) (y (%canvas-seat-y seat-state)))
    (when icon
      (loop for surface across (ataxia.kernel:drawable-surfaces icon)
            collect (%screen-rectangle-to-buffer
                     state
                     (+ x (ataxia.kernel:drawable-surface-local-x surface))
                     (+ y (ataxia.kernel:drawable-surface-local-y surface))
                     (ataxia.kernel:drawable-surface-width surface)
                     (ataxia.kernel:drawable-surface-height surface) 2d0)))))

(defun %cursor-only-buffer-coverage (state seat-state)
  (let ((cursor (%canvas-seat-cursor-surface seat-state))
        (x (%canvas-seat-x seat-state))
        (y (%canvas-seat-y seat-state)))
    (if (and cursor (eq (ataxia.kernel:object-state cursor) :live))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces cursor)
          (declare (ignore revision))
          (loop for surface across surfaces
                collect
                (%oriented-screen-rectangle-to-buffer
                 state x y
                 (+ (- x (%canvas-seat-cursor-hotspot-x seat-state))
                    (ataxia.kernel:drawable-surface-local-x surface))
                 (+ (- y (%canvas-seat-cursor-hotspot-y seat-state))
                    (ataxia.kernel:drawable-surface-local-y surface))
                 (ataxia.kernel:drawable-surface-width surface)
                 (ataxia.kernel:drawable-surface-height surface)
                 2d0)))
        (list (%oriented-screen-rectangle-to-buffer
               state x y (- x 4d0) (- y 4d0) 26d0 34d0)))))

(defun %damage-cursor (world seat-state)
  (let* ((state (%canvas-seat-output seat-state))
         (coverage (and state (%cursor-buffer-coverage state seat-state)))
         (previous-output (%canvas-seat-cursor-coverage-output seat-state)))
    (when (and previous-output (%canvas-seat-cursor-coverage seat-state))
      (ataxia.world:damage-add-region
       (%world-damage world) previous-output
       (%canvas-seat-cursor-coverage seat-state)))
    (when state
      (ataxia.world:damage-add-region
       (%world-damage world) (%canvas-output-output state) coverage))
    (setf (%canvas-seat-cursor-coverage seat-state) coverage
          (%canvas-seat-cursor-coverage-output seat-state)
          (and state (%canvas-output-output state))))
  world)

(defun %full-damage (world state)
  (ataxia.world:damage-full-output
   (%world-damage world) (%canvas-output-output state))
  (%request-output-state-frame world state))

(defmethod ataxia.world:refresh-world ((world infinite-world))
  (dolist (state (%output-states world))
    (%full-damage world state))
  world)

(defun %capture-window-coverage (world &optional (windows (%world-stacking world)))
  (let ((coverage (make-hash-table :test #'eq)))
    (dolist (window windows)
      (let ((per-output (make-hash-table :test #'eq)))
        (dolist (state (%output-states world))
          (setf (gethash state per-output)
                (%window-buffer-coverage state window)))
        (setf (gethash window coverage) per-output)))
    coverage))

(defun %advance-world-animations (world timestamp)
  (let ((animator (%world-animator world)))
    (when (and (ataxia.world:animations-active-p animator)
               (> timestamp (%world-last-animation-time world)))
      (let ((old-coverage
              (%capture-window-coverage
               world (remove-if-not (lambda (subject) (typep subject 'canvas-window))
                                    (ataxia.world:animation-subjects animator)))))
        (multiple-value-bind (changed active-p)
            (ataxia.world:advance-animations animator timestamp)
          (declare (ignore active-p))
          (setf (%world-last-animation-time world) timestamp)
          (dolist (subject changed)
            (typecase subject
              (canvas-window
               (let ((before (gethash subject old-coverage)))
                 (dolist (state (%output-states world))
                   (ataxia.world:damage-add-region
                    (%world-damage world) (%canvas-output-output state)
                    (list (gethash state before)
                          (%window-buffer-coverage state subject)))))
               (%update-window-membership world subject))
              (%canvas-output (%full-damage world subject)))))))
    (when (ataxia.world:animations-active-p animator)
      (%request-all-frames world)))
  world)

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

(defun %target-component (target)
  (etypecase target
    (canvas-window (canvas-window-application target))
    (ui-overlay (overlay-component target))))

(defgeneric %overlay-below-windows-p (overlay)
  (:documentation "Whether an overlay belongs to canvas decoration below application windows."))
(defmethod %overlay-below-windows-p ((overlay ui-overlay)) nil)


(defun %target-visible-p (target)
  (typecase target
    (canvas-window (and (%canvas-window-input-enabled-p target) (%window-visible-p target)))
    (ui-overlay (and (overlay-visible-p target) (overlay-input-enabled-p target)))
    (otherwise nil)))

(defun %focus-target (world seat-state target)
  (let ((old (%canvas-seat-focused seat-state))
        (seat (%canvas-seat-seat seat-state)))
    (unless (ataxia.world:seat-focus-allowed-p seat target)
      (return-from %focus-target old))
    (unless (eq old target)
      (when old
        (when (and (typep old 'canvas-window)
                 (notany (lambda (other) (and (not (eq other seat-state))
                                              (eq old (%canvas-seat-focused other))))
                         (%seat-states world)))
          (ataxia.kernel:request-object-state
           (canvas-window-application old) world :activated nil))
        (ataxia.kernel:interactable-focus
         (%target-component old) world seat :clear-keyboard))
      (setf (%canvas-seat-focused seat-state) target)
      (ataxia.kernel:clear-wayland-focus seat :keyboard t)
      (when target
        (when (typep target 'canvas-window)
          (when (ataxia.world:seat-raises-focused-window-p seat) (%raise-window world target))
          (ataxia.kernel:request-object-state
           (canvas-window-application target) world :activated t))
        (ataxia.kernel:interactable-focus
         (%target-component target) world seat :keyboard))))
  target)

(defun %focus-window (world seat-state window)
  (%focus-target world seat-state window))

(defun %window-input-geometry (state window)
  (multiple-value-bind (x y width height)
      (%window-canvas-geometry state window)
    (multiple-value-bind (root-x root-y root-width root-height)
        (ataxia.kernel:drawable-local-bounds
         (canvas-window-application window))
      (multiple-value-bind (surfaces revision)
          (ataxia.kernel:drawable-surfaces
           (canvas-window-application window))
        (declare (ignore revision))
        (if (or (zerop (length surfaces))
                (not (plusp root-width))
                (not (plusp root-height)))
            (values x y width height)
            (let ((left root-x)
                  (top root-y)
                  (right (+ root-x root-width))
                  (bottom (+ root-y root-height)))
              (map nil
                   (lambda (surface)
                     (let ((surface-x
                             (ataxia.kernel:drawable-surface-local-x surface))
                           (surface-y
                             (ataxia.kernel:drawable-surface-local-y surface)))
                       (setf left (min left surface-x)
                             top (min top surface-y)
                             right
                             (max right
                                  (+ surface-x
                                     (ataxia.kernel:drawable-surface-width
                                      surface)))
                             bottom
                             (max bottom
                                  (+ surface-y
                                     (ataxia.kernel:drawable-surface-height
                                      surface))))))
                   surfaces)
              (let ((scale-x (/ width root-width))
                    (scale-y (/ height root-height)))
                (values (+ x (* (- left root-x) scale-x))
                        (+ y (* (- top root-y) scale-y))
                        (* (- right left) scale-x)
                        (* (- bottom top) scale-y)))))))))

(defun %windows-at-screen-point (world state x y)
  (multiple-value-bind (canvas-x canvas-y) (%screen-to-canvas state x y)
    (loop for window in (reverse (%world-stacking world))
          when (and (%window-visible-p window) (%canvas-window-input-enabled-p window)
                    (multiple-value-bind (window-x window-y width height)
                        (%window-input-geometry state window)
                      (and (<= window-x canvas-x (+ window-x width))
                           (<= window-y canvas-y (+ window-y height)))))
            collect window)))

(defun %overlays-at-screen-point (world state x y)
  (remove-if-not
   (lambda (overlay)
     (and (typep (overlay-component overlay)
                 'ataxia.kernel:interactable)
          (%overlay-visible-on-state-p overlay state)
          (overlay-input-enabled-p overlay)
          (<= (overlay-x overlay) x
              (+ (overlay-x overlay) (overlay-width overlay)))
          (<= (overlay-y overlay) y
              (+ (overlay-y overlay) (overlay-height overlay)))))
   (reverse (world-overlays world))))

(defun %targets-at-screen-point (world state x y)
  (let ((overlays (%overlays-at-screen-point world state x y)))
    (append (remove-if #'%overlay-below-windows-p overlays)
            (%windows-at-screen-point world state x y)
            (remove-if-not #'%overlay-below-windows-p overlays))))

(defun %target-at-screen-point (world state x y)
  (first (%targets-at-screen-point world state x y)))

(defun %top-visible-window (world &optional excluded)
  (find-if (lambda (window)
             (and (not (eq window excluded)) (%window-visible-p window)))
           (reverse (%world-stacking world))))

(defun %replace-focused-window (world seat-state removed-window)
  (when (eq removed-window (%canvas-seat-focused seat-state))
    (setf (%canvas-seat-focused seat-state) nil)
    (ataxia.kernel:clear-wayland-focus
     (%canvas-seat-seat seat-state) :keyboard t)
    (%focus-target world seat-state
                   (%top-visible-window world removed-window))))

(defun %target-screen-geometry (state target)
  (etypecase target
    (canvas-window (%window-canvas-geometry state target))
    (ui-overlay
     (values (overlay-x target) (overlay-y target)
             (overlay-width target) (overlay-height target)))))

(defun %target-local-position (state target x y)
  (multiple-value-bind (position-x position-y)
      (etypecase target
        (canvas-window (%screen-to-canvas state x y))
        (ui-overlay (values x y)))
    (multiple-value-bind (target-x target-y width height)
        (%target-screen-geometry state target)
      (multiple-value-bind (local-x local-y local-width local-height)
          (ataxia.kernel:drawable-local-bounds
           (%target-component target))
        (values
         (+ local-x (* (/ (- position-x target-x) width) local-width))
         (+ local-y (* (/ (- position-y target-y) height) local-height)))))))

(defun %captured-pointer-target (seat-state)
  (unless (ataxia.kernel:seat-pointer-drag-active-p (%canvas-seat-seat seat-state))
    (loop for target being the hash-values of (%canvas-seat-buttons seat-state)
          when (and target (not (eq target :world))) return target)))

(defun %target-accepts-position-p (world seat-state state target)
  (multiple-value-bind (local-x local-y)
      (%target-local-position
       state target (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
    (ataxia.kernel:interactable-hit-test
     (%target-component target) world local-x local-y)))

(defun %deliver-motion (world seat-state input)
  (let* ((state (%canvas-seat-output seat-state))
         (captured (%captured-pointer-target seat-state))
         (candidates
           (cond
             (captured (list captured))
             (state
              (%targets-at-screen-point
               world state (%canvas-seat-x seat-state) (%canvas-seat-y seat-state)))))
         (target
           (and state
                (or captured
                    (find-if
                     (lambda (candidate)
                       (%target-accepts-position-p
                        world seat-state state candidate))
                     candidates)))))
    (unless (eq target (%canvas-seat-hovered seat-state))
      (when (%canvas-seat-hovered seat-state)
        (ataxia.kernel:interactable-pointer-leave
         (%target-component (%canvas-seat-hovered seat-state)) world
         (%canvas-seat-seat seat-state)))
      (setf (%canvas-seat-hovered seat-state) target))
    (unless target
      (ataxia.kernel:clear-wayland-focus
       (%canvas-seat-seat seat-state) :pointer t))
    (when target
      (multiple-value-bind (local-x local-y)
          (%target-local-position
           state target (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
        (ataxia.world:interaction-delivered-p
         (ataxia.kernel:interactable-pointer-motion
          (%target-component target) world
          (%canvas-seat-seat seat-state) local-x local-y input))))
    target))

(defun %deliver-button-to-target (world seat-state target input &key clamp-p)
  (when target
    (multiple-value-bind (local-x local-y)
        (%target-local-position
         (%canvas-seat-output seat-state) target
         (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
      (when clamp-p
        (multiple-value-bind (bounds-x bounds-y bounds-width bounds-height)
            (ataxia.kernel:drawable-local-bounds
             (%target-component target))
          (setf local-x (max bounds-x
                             (min (- (+ bounds-x bounds-width)
                                     least-positive-double-float)
                                  local-x))
                local-y (max bounds-y
                             (min (- (+ bounds-y bounds-height)
                                     least-positive-double-float)
                                  local-y)))))
      (ataxia.kernel:interactable-pointer-button
       (%target-component target) world
       (%canvas-seat-seat seat-state) local-x local-y input))))

(defun %deliver-axis-to-target (world seat-state target input)
  (when target
    (multiple-value-bind (local-x local-y)
        (%target-local-position
         (%canvas-seat-output seat-state) target
         (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
      (ataxia.kernel:interactable-pointer-axis
       (%target-component target) world
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
            (multiple-value-bind (delta-x delta-y)
                (%canvas-vector-to-screen
                 state
                 (ataxia.kernel:cursor-motion-input-delta-x input)
                 (ataxia.kernel:cursor-motion-input-delta-y input))
              (incf (%canvas-seat-x seat-state) delta-x)
              (incf (%canvas-seat-y seat-state) delta-y)))
        (%route-seat-output seat-state)))))

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
         (edges (%canvas-operation-edges operation))
         (x (%canvas-operation-window-x operation))
         (y (%canvas-operation-window-y operation))
         (width (%canvas-operation-window-width operation))
         (height (%canvas-operation-window-height operation)))
    (multiple-value-bind (screen-delta-x screen-delta-y)
        (%screen-vector-to-canvas
         state
         (- (%canvas-seat-x seat-state) (%canvas-operation-cursor-x operation))
         (- (%canvas-seat-y seat-state) (%canvas-operation-cursor-y operation)))
      (let ((delta-x (/ screen-delta-x zoom))
            (delta-y (/ screen-delta-y zoom)))
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
        (%damage-window world window)))))

(defun %pan-operation (world seat-state operation)
  (let* ((state (%canvas-seat-output seat-state))
         (zoom (%canvas-output-zoom state)))
    (multiple-value-bind (delta-x delta-y)
        (%screen-vector-to-canvas
         state
         (- (%canvas-seat-x seat-state) (%canvas-operation-cursor-x operation))
         (- (%canvas-seat-y seat-state) (%canvas-operation-cursor-y operation)))
      (setf (%canvas-output-camera-x state)
            (- (%canvas-operation-camera-x operation) (/ delta-x zoom))
            (%canvas-output-camera-y state)
            (- (%canvas-operation-camera-y operation) (/ delta-y zoom))))
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
                     (ataxia.kernel:drawable-surface-presentation-token surface)))
               (when token
                 (ataxia.kernel:set-wayland-surface-output-membership
                  token outputs))))
           surfaces))))

(defun %update-cursor-membership (seat-state)
  (dolist (drawable (list (%canvas-seat-cursor-surface seat-state)
                          (ataxia.kernel:seat-drag-icon (%canvas-seat-seat seat-state))))
    (when (and drawable
               (or (typep drawable 'ataxia.kernel:drag-icon)
                   (eq (ataxia.kernel:object-state drawable) :live)))
      (multiple-value-bind (surfaces revision)
          (ataxia.kernel:drawable-surfaces drawable)
        (declare (ignore revision))
        (map nil
             (lambda (surface)
               (let ((token
                       (ataxia.kernel:drawable-surface-presentation-token surface)))
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

(defun %remember-tab-drop (world seat-state input)
  ;; Firefox creates its detached toplevel asynchronously after an unaccepted
  ;; tab drop. Snapshot the release in world coordinates before wlroots tears
  ;; down the drag; subsequent pointer/camera motion must not move the window.
  (let ((seat (%canvas-seat-seat seat-state)))
    (when (and (eq :released (ataxia.kernel:cursor-button-input-state input))
               (eql (ataxia.kernel:cursor-button-input-code input)
                    (ataxia.kernel:seat-drag-grab-button seat))
               (%canvas-seat-output seat-state)
               (ataxia.kernel:seat-drag-has-mime-type-p
                seat "application/x-moz-tabbrowser-tab")
               (not (ataxia.kernel:seat-drag-drop-accepted-p seat)))
      (let ((client (ataxia.kernel:seat-drag-client-identity seat)))
        (when client
          (multiple-value-bind (x y)
              (%screen-to-world (%canvas-seat-output seat-state)
                                (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))
            (setf (gethash seat (%world-pending-tab-drops world))
                  (list client (+ (%now) 5d0) x y))))))))

(defun %claim-tab-drop (world application)
  ;; Bounded to one hint per seat, consumed by a newly created toplevel from
  ;; the exact connection. Expiry is checked on demand, with no idle timer.
  (let ((table (%world-pending-tab-drops world)) (now (%now)))
    (loop for seat being the hash-keys of table using (hash-value drop)
          do (when (> now (second drop)) (remhash seat table)))
    (when (plusp (hash-table-count table))
      (let ((client (and (typep application 'ataxia.kernel:wayland-application)
                         (ataxia.kernel:application-client-identity application))))
        (loop for seat being the hash-keys of table using (hash-value drop)
              when (eql client (first drop))
                do (remhash seat table)
                   (return (cddr drop)))))))

(defun %make-window-binding (world application)
  (let ((width 900d0) (height 600d0))
    (multiple-value-bind (x y) (%initial-window-position world width height)
      (let* ((drop (%claim-tab-drop world application))
             (window (make-instance 'canvas-window
                       :application application :x (if drop (first drop) x)
                       :y (if drop (second drop) y) :width width :height height)))
        (setf (%canvas-window-drop-placed-p window) (not (null drop)))
        (%install-default-animation-hooks window)))))

(defun %sync-window-size (window)
  (multiple-value-bind (x y width height)
      (ataxia.kernel:drawable-local-bounds (canvas-window-application window))
    (declare (ignore x y))
    (when (and (plusp width) (plusp height))
      (setf (canvas-window-width window) (coerce width 'double-float)
            (canvas-window-height window) (coerce height 'double-float))))
  window)

(defun %window-resize-active-p (world window)
  (some (lambda (seat-state)
          (let ((operation (%canvas-seat-operation seat-state)))
            (and operation
                 (eq (%canvas-operation-kind operation) :resize)
                 (eq (%canvas-operation-window operation) window))))
        (%seat-states world)))

(defgeneric %set-window-minimized (world window minimized-p))
(defmethod %set-window-minimized ((world infinite-world) window minimized-p)
  (%damage-window world window)
  (setf (%canvas-window-minimized-p window) (not (null minimized-p)))
  (when minimized-p
    (dolist (seat-state (%seat-states world))
      (when (eq window (%canvas-seat-focused seat-state))
        (%focus-target world seat-state nil))))
  (%damage-window world window)
  (%update-window-membership world window)
  (%request-all-frames world)
  window)

(defun %canvas-work-area (world state)
  (if (%canvas-output-output state)
      (ataxia.world:world-output-work-area world (%canvas-output-output state))
      (multiple-value-bind (width height) (%output-logical-size state)
        (values 0d0 0d0 width height))))

(defun %set-window-expanded (world window state requested-p output-state)
  (let ((previous (%canvas-window-expanded-state window)))
    (when (and requested-p previous (not (eq state previous)))
      (ataxia.kernel:request-object-state (canvas-window-application window) world previous nil)))
  (if requested-p
      (progn
        (unless (%canvas-window-restore-geometry window)
          (setf (%canvas-window-restore-geometry window)
                (list (canvas-window-x window) (canvas-window-y window)
                      (canvas-window-width window) (canvas-window-height window))))
        (multiple-value-bind (x y logical-width logical-height)
            (if (eq state :maximized)
                (%canvas-work-area world output-state)
                (multiple-value-bind (width height) (%output-logical-size output-state)
                  (values 0d0 0d0 width height)))
          (setf (canvas-window-x window) (+ (%canvas-output-camera-x output-state) (/ x (%canvas-output-zoom output-state)))
                (canvas-window-y window) (+ (%canvas-output-camera-y output-state) (/ y (%canvas-output-zoom output-state)))
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
  (setf (%canvas-window-expanded-state window) (and requested-p state))
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

(defun set-window-position (world window x y)
  "Move WINDOW in world coordinates and schedule the affected outputs."
  (check-type world infinite-world)
  (check-type window canvas-window)
  (unless (eq window
              (find-canvas-window world (canvas-window-application window)))
    (error "Canvas window does not belong to this World."))
  (%damage-window world window)
  (setf (canvas-window-x window) (coerce x 'double-float)
        (canvas-window-y window) (coerce y 'double-float))
  (%damage-window world window)
  (%update-window-membership world window)
  (%request-all-frames world)
  window)

(defun zoom-output-camera
    (world output factor &key anchor-x anchor-y)
  (let ((state (gethash output (%world-outputs world))))
    (unless state (error "Unknown canvas output."))
    (multiple-value-bind (logical-width logical-height) (%output-logical-size state)
      (let* ((screen-x (coerce (or anchor-x (/ logical-width 2d0)) 'double-float))
             (screen-y (coerce (or anchor-y (/ logical-height 2d0)) 'double-float)))
        (multiple-value-bind (world-x world-y)
            (%screen-to-world state screen-x screen-y)
          (multiple-value-bind (canvas-x canvas-y)
              (%screen-to-canvas state screen-x screen-y)
            (let ((zoom (max 0.08d0
                             (min 8d0 (* (%canvas-output-zoom state) factor)))))
              (set-output-camera
               world output
               (- world-x (/ canvas-x zoom))
               (- world-y (/ canvas-y zoom))
               zoom)))))))
  output)

(defmethod ataxia.kernel:world-attached ((world infinite-world) kernel)
  (setf (ataxia.kernel:world-kernel world) kernel
        (%world-quiescing-p world) nil)
  world)

(defmethod ataxia.kernel:world-quiescing ((world infinite-world) reason)
  (declare (ignore reason))
  (setf (%world-quiescing-p world) t)
  (%end-all-view-shifts world)
  (%remove-component-timer world)
  world)

(defmethod ataxia.kernel:world-detached ((world infinite-world) kernel)
  (when (eq kernel (ataxia.kernel:world-kernel world))
    (dolist (window (%world-stacking world))
      (ataxia.world:cancel-subject-animations (%world-animator world) window))
    (dolist (state (%output-states world))
      (ataxia.world:damage-forget-output
       (%world-damage world) (%canvas-output-output state)))
    (dolist (overlay (world-overlays world))
      (destroy-overlay overlay))
    (clrhash (%world-windows world))
    (clrhash (%world-outputs world))
    (clrhash (%world-seats world))
    (clrhash (%world-pending-tab-drops world))
    (clrhash (%world-view-shifts world))
    (setf (world-overlays world) nil
          (%world-retired-overlays world) nil
          (%world-stacking world) nil
          (ataxia.kernel:world-kernel world) nil))
  world)

(defmethod ataxia.kernel:world-register-object
    ((world infinite-world) (application ataxia.kernel:interactable))
  (unless (find-canvas-window world application)
    (let ((window (%make-window-binding world application)))
      (setf (gethash application (%world-windows world)) window
            (%world-stacking world)
            (append (%world-stacking world) (list window))
            (%canvas-window-mapped-p window)
            (ataxia.kernel:application-mapped-p application))
      (when (%canvas-window-mapped-p window)
        (%sync-window-size window)
        (run-window-animation-hook world window :visible))
      (%damage-window world window)
      (%update-window-membership world window)
      (%request-all-frames world)))
  application)

(defmethod ataxia.kernel:world-unregister-object
    ((world infinite-world) (application ataxia.kernel:interactable) reason)
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
        (when (eq window (%canvas-seat-previous-focus seat-state))
          (setf (%canvas-seat-previous-focus seat-state) nil))
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
    (ataxia.kernel:interactable
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
                    (unless (typep (%canvas-seat-focused seat-state)
                                   'ui-overlay)
                      (%focus-window world seat-state window))))
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
           (%damage-cursor world seat-state)
           (%request-output-state-frame world (%canvas-seat-output seat-state)))))))
  object)

(defmethod ataxia.kernel:world-object-invalidated
    ((world infinite-world) object invalidation)
  (typecase object
    (ataxia.kernel:interactable
     (let ((window (find-canvas-window world object)))
       (when window
         (let ((size-changed-p nil))
           (unless (%window-resize-active-p world window)
             (multiple-value-bind (x y width height)
                 (ataxia.kernel:drawable-local-bounds object)
               (declare (ignore x y))
               (setf size-changed-p
                     (and (plusp width) (plusp height)
                          (or (/= width (canvas-window-width window))
                              (/= height (canvas-window-height window)))))
               (when size-changed-p
                 (%damage-window world window)
                 (%sync-window-size window))))
           (setf (%canvas-window-drawable-revision window)
                 (ataxia.kernel:drawable-invalidation-revision invalidation))
           (if size-changed-p
               (%damage-window world window)
               (%damage-window-region
                world window
                (ataxia.world:frame-damage-to-region
                 (ataxia.kernel:drawable-invalidation-damage invalidation)))))
         (%update-window-membership world window)
         ;; A client may commit while its workspace or damaged pixels are off
         ;; screen. Keep its latest content without waking unaffected outputs.
         (dolist (state (%output-states world))
           (when (or (ataxia.world:damage-pending-p (%world-damage world) (%canvas-output-output state))
                     ;; Visible clients still receive frame callbacks even when
                     ;; their changed pixels are covered. Fully occluded clients
                     ;; wait until exposure; their latest buffers remain retained.
                     (%window-needs-visible-callback-p world state window))
             (%request-output-state-frame world state))))))
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
    (%initialize-output-viewport world state)
    (%ensure-output-launcher world state)
    (%install-component-timer world)
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
            (ataxia.world:damage-reset-output (%world-damage world) output)
            (dolist (overlay (world-overlays world))
              (when (%overlay-on-state-p overlay state)
                (overlay-output-changed overlay output)
                (%damage-overlay world overlay)))))
      (%request-output-state-frame world state)
      (%update-all-membership world)))
  output)

(defmethod ataxia.kernel:world-output-removing
    ((world infinite-world) output)
  (let ((state (gethash output (%world-outputs world))))
    (when state
      (%end-view-shifts-for-output world state)
      (dolist (overlay
                (remove-if-not
                 (lambda (candidate)
                   (eq output (overlay-output candidate)))
                 (copy-list (world-overlays world))))
        (remove-overlay world overlay))
      (remhash output (%world-outputs world))
      (ataxia.world:damage-forget-output (%world-damage world) output)
      (dolist (seat-state (%seat-states world))
        (when (eq state (%canvas-seat-output seat-state))
          (setf (%canvas-seat-output seat-state) (%first-output-state world))
          (when (%canvas-seat-output seat-state)
            (%route-seat-output seat-state)
            (%update-cursor-membership seat-state)
            (%request-output-state-frame world (%canvas-seat-output seat-state)))))))
  output)

(defmethod ataxia.kernel:world-seat-added
    ((world infinite-world) seat)
  (let* ((state (%first-output-state world))
         (seat-state (%make-canvas-seat seat)))
    (setf (%canvas-seat-output seat-state) state
          (%canvas-seat-world seat-state) world)
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (setf (%canvas-seat-x seat-state) (/ width 2d0)
              (%canvas-seat-y seat-state) (/ height 2d0))))
    (setf (gethash seat (%world-seats world)) seat-state)
    (%update-cursor-membership seat-state)
    (%damage-cursor world seat-state)
    (%request-all-frames world))
  seat)

(defmethod ataxia.kernel:world-seat-drag-icon-changed
    ((world infinite-world) seat)
  (let ((state (gethash seat (%world-seats world))))
    (when state
      (%damage-cursor world state)
      (%update-cursor-membership state)
      (%request-output-state-frame world (%canvas-seat-output state)))))

(defmethod ataxia.kernel:world-seat-removing
    ((world infinite-world) seat)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%end-view-shift world seat)
      (%damage-cursor world seat-state)
      (when (%canvas-seat-hovered seat-state)
        (ataxia.kernel:interactable-pointer-leave
         (%target-component (%canvas-seat-hovered seat-state)) world seat))
      (when (%canvas-seat-focused seat-state)
        (ataxia.kernel:interactable-focus
         (%target-component (%canvas-seat-focused seat-state))
         world seat :clear-keyboard)))
    (remhash seat (%world-seats world))
    (remhash seat (%world-pending-tab-drops world))
    (ataxia.world:forget-shortcut-seat
     (ataxia.world:world-shortcut-controller world) seat)
    (%request-all-frames world))
  seat)

(defmethod ataxia.kernel:world-cursor-motion
    ((world infinite-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (%update-seat-position seat-state input)
      (let ((shift (%view-shift-for-seat world seat)))
        (cond
          (shift (%sync-view-shift-overlay world seat-state shift))
          ((%canvas-seat-operation seat-state)
           (%apply-operation world seat-state))
          (t (%deliver-motion world seat-state input))))
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
        (when pressed-p (remhash seat (%world-pending-tab-drops world)))
        (if (ataxia.kernel:seat-pointer-drag-active-p seat)
            (progn
              (%remember-tab-drop world seat-state input)
              (ataxia.kernel:forward-pointer-drag-button seat input)
              (unless pressed-p (remhash code buttons)))
            (if pressed-p
            (let ((target
                    (or (%canvas-seat-hovered seat-state)
                        (%target-at-screen-point
                         world (%canvas-seat-output seat-state)
                         (%canvas-seat-x seat-state) (%canvas-seat-y seat-state)))))
              (when target (%focus-target world seat-state target))
              (if (and (= code +button-middle+)
                       (not (typep target 'ui-overlay)))
                  (progn
                    (setf (gethash code buttons) :world)
                    (%begin-pan seat-state))
                  (progn
                    (setf (gethash code buttons) (or target :world))
                    (%deliver-button-to-target
                     world seat-state target input :clamp-p nil))))
            (let ((target (gethash code buttons))
                  (operation (%canvas-seat-operation seat-state)))
              (cond
                ((and operation
                      (= code (%canvas-operation-button operation)))
                 (when (%canvas-operation-forward-release-p operation)
                   (%deliver-button-to-target
                    world seat-state (%canvas-operation-window operation)
                    input :clamp-p t))
                 (%finish-operation world seat-state))
                ((typep target '(or canvas-window ui-overlay))
                 (%deliver-button-to-target
                  world seat-state target input :clamp-p t)))
              (remhash code buttons))))
        (%damage-cursor world seat-state)
        (%request-all-frames world))))
  input)

(defmethod ataxia.kernel:world-cursor-axis
    ((world infinite-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (let ((target
              (or (%canvas-seat-hovered seat-state)
                  (%target-at-screen-point
                   world (%canvas-seat-output seat-state)
                   (%canvas-seat-x seat-state) (%canvas-seat-y seat-state)))))
        (if target
            (%deliver-axis-to-target world seat-state target input)
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

(defmethod ataxia.kernel:world-key-event :around
    ((world infinite-world) seat input)
  (when (and (typep input 'ataxia.kernel:key-input)
             (eq :pressed (ataxia.kernel:key-input-state input)))
    (remhash seat (%world-pending-tab-drops world)))
  (call-next-method))

(defmethod ataxia.kernel:world-key-event
    ((world infinite-world) seat input)
  (let* ((seat-state (gethash seat (%world-seats world)))
         (target (and seat-state (%canvas-seat-focused seat-state))))
    (when seat-state
      (%update-view-shift-modifiers world seat seat-state input))
    (when (and seat-state
               (eq :forward
                   (ataxia.world:handle-shortcut-input
                    (ataxia.world:world-shortcut-controller world)
                    world seat input))
               (%target-visible-p target))
      (ataxia.kernel:interactable-key-event
       (%target-component target) world seat input)))
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
    ((world infinite-world) (application ataxia.kernel:interactable)
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
           (:activation
            (let ((seat-state
                    (or (gethash (ataxia.kernel:client-request-seat request)
                                 (%world-seats world))
                        (first (%seat-states world)))))
              (when (and seat-state (%canvas-window-mapped-p window))
                (%raise-window world window)
                (%focus-target world seat-state window))))
           (:maximized
            (when (%canvas-window-mapped-p window)
              (%damage-window world window)
              (%set-window-expanded
               world window :maximized
               (ataxia.kernel:state-client-request-value request)
               (%first-output-state world))))
           (:minimized
            (%set-window-minimized world window (ataxia.kernel:state-client-request-value request)))
           (otherwise
            (ataxia.kernel:request-object-state
             application world
             (ataxia.kernel:state-client-request-name request)
             (ataxia.kernel:state-client-request-value request))))))))
  request)

(defgeneric %world-grid-shader (world))

(defmethod %world-grid-shader ((world infinite-world))
  +grid-fragment-shader+)

(defmethod ataxia.kernel:world-graphics-attached
    ((world infinite-world) graphics-context)
  (declare (ignore graphics-context))
  (setf (%world-renderer world) (%create-canvas-renderer (%world-grid-shader world)))
  (dolist (overlay (world-overlays world))
    (ataxia.kernel:drawable-attach-graphics
     (overlay-component overlay)))
  (%install-component-timer world)
  (dolist (state (%output-states world))
    (%full-damage world state))
  world)

(defgeneric %prepare-canvas-frame (world state)
  (:documentation "Synchronize overlays after animation sampling, once per output frame."))

(defmethod %prepare-canvas-frame ((world infinite-world) state)
  (declare (ignore world state)))

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
    (%service-ui-engines world)
    (%advance-world-animations world (ataxia.kernel:frame-timestamp lease))
    (%advance-view-shifts world (ataxia.kernel:frame-timestamp lease))
    (%prepare-canvas-frame world state)
    (%reap-retired-overlays world)
    (dolist (overlay (world-overlays world))
      (when (and (%overlay-visible-on-state-p overlay state)
                 (%updatable-overlay-p world overlay))
        (%prepare-overlay-resolution world state overlay)
        (multiple-value-bind (damage active-p)
            (ataxia.kernel:drawable-prepare-frame
             (overlay-component overlay))
          (when damage
            (%damage-overlay-region world overlay damage))
          (when active-p
            (%request-output-state-frame world state)))))
    (%schedule-component-timer world)
    (multiple-value-bind (region damage-frame)
        (ataxia.world:damage-begin-frame
         (%world-damage world) output
         (ataxia.kernel:frame-target-token lease)
         (ataxia.kernel:frame-generation lease)
         (ataxia.kernel:frame-width lease)
         (ataxia.kernel:frame-height lease))
      (multiple-value-bind (tokens callbacks)
          (if region
              (%render-canvas
               (%world-renderer world) state
               (%world-stacking world) (world-overlays world)
               (%seat-states world) region
               (%world-damage-debug-p world) world)
              (values #() (%canvas-plan-callbacks
                           state (%canvas-paint-plan state (%world-stacking world) (world-overlays world) nil))))
        (make-instance
         'ataxia.kernel:world-frame-result
         :target-token (ataxia.kernel:frame-target-token lease)
         :damage (ataxia.world:region-to-frame-damage
                  (if (%world-damage-debug-p world)
                      (list (ataxia.world:make-rectangle
                             0 0
                             (ataxia.kernel:frame-width lease)
                             (ataxia.kernel:frame-height lease)))
                      region)
                  (ataxia.kernel:frame-width lease)
                  (ataxia.kernel:frame-height lease))
         :presentation-tokens tokens
         :callback-tokens callbacks
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
  (declare (ignore output reason))
  (when frame-result
    (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
      (when cookie
        (ataxia.world:damage-fail-frame
         (%world-damage world) (%world-frame-cookie-damage-frame cookie)))))
  frame-result)

(defmethod ataxia.kernel:world-graphics-detaching
    ((world infinite-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (%remove-component-timer world)
  (dolist (overlay (world-overlays world))
    (ataxia.kernel:drawable-detach-graphics
     (overlay-component overlay)))
  (%reap-retired-overlays world)
  (when (%world-renderer world)
    (%destroy-canvas-renderer (%world-renderer world))
    (setf (%world-renderer world) nil))
  world)
