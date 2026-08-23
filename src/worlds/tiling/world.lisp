;;;; Master-stack tiling World policy and Kernel integration.
;;;;
;;;; This module owns tiling behavior, focus, shortcuts, input routing, damage,
;;;; and frame production. Kernel remains responsible for Wayland mechanics.

(in-package #:ataxia.tiling-world)

(defun %full-damage (world state)
  (when state
    (ataxia.world:damage-full-output
     (%world-damage world) (%tiling-output-output state))
    (%request-output-frame world state))
  world)

(defun %full-damage-all (world)
  (dolist (state (%output-states world))
    (%full-damage world state))
  world)

(defmethod ataxia.world:refresh-world ((world tiling-world))
  (%full-damage-all world)
  (%request-all-frames world))

(defun %damage-node (world node &optional (timestamp (%now)))
  (let ((state (%tile-output-state node)))
    (when state
      (let ((coverage (%tile-buffer-coverage world state node timestamp)))
        (when coverage
          (ataxia.world:damage-add-region
           (%world-damage world) (%tiling-output-output state)
           (list coverage))
          (%request-output-frame world state)))))
  node)

(defun %damage-node-region (world node rectangles &optional (timestamp (%now)))
  (let ((state (%tile-output-state node)))
    (when (and state rectangles)
      (multiple-value-bind (screen-x screen-y screen-width screen-height)
          (%tile-geometry world node timestamp)
        (multiple-value-bind (local-x local-y local-width local-height)
            (ataxia.kernel:drawable-local-bounds (tile-node-component node))
          (when (and screen-x (plusp local-width) (plusp local-height))
            (ataxia.world:damage-add-region
             (%world-damage world) (%tiling-output-output state)
             (mapcar
              (lambda (rectangle)
                (%screen-rectangle-to-buffer
                 state
                 (+ screen-x
                    (* screen-width
                       (/ (- (ataxia.world:rectangle-x rectangle) local-x)
                          local-width)))
                 (+ screen-y
                    (* screen-height
                       (/ (- (ataxia.world:rectangle-y rectangle) local-y)
                          local-height)))
                 (* screen-width
                    (/ (ataxia.world:rectangle-width rectangle) local-width))
                 (* screen-height
                    (/ (ataxia.world:rectangle-height rectangle) local-height))))
              rectangles))
            (%request-output-frame world state))))))
  node)

(defun %damage-cursor (world seat-state)
  (let ((state (%tiling-seat-output seat-state)))
    (when state
      (ataxia.world:damage-add-region
       (%world-damage world) (%tiling-output-output state)
       (list (%screen-rectangle-to-buffer
              state (- (%tiling-seat-x seat-state) 4d0)
              (- (%tiling-seat-y seat-state) 4d0) 52d0 52d0)))
      (%request-output-frame world state)))
  world)

(defun %ease-out-back (progress)
  (let* ((overshoot 1.35d0)
         (offset (- progress 1d0)))
    (+ 1d0 (* (+ overshoot 1d0) offset offset offset)
       (* overshoot offset offset))))

(defun %animate-node-scalar
    (world node channel target duration reader writer
     &key (easing #'ataxia.world:ease-out-cubic))
  (let ((start (funcall reader node))
        (destination (coerce target 'double-float)))
    (ataxia.world:start-animation
     (%world-animator world) node channel (%now) duration
     (lambda (subject progress)
       (funcall writer subject
                (+ start (* (- destination start) progress))))
     :easing easing
     :finish (lambda (subject) (funcall writer subject destination))))
  (%damage-node world node)
  (%request-all-frames world)
  node)

(defun %animate-node-entry (world node)
  (setf (%tile-opacity node) 0d0
        (%tile-scale node) 0.84d0
        (%tile-effect node) 1d0)
  (ataxia.world:start-animation
   (%world-animator world) node :presence (%now) 0.42d0
   (lambda (subject progress)
     (let ((settled (max 0d0 (min 1d0 progress))))
       (setf (%tile-opacity subject) (min 1d0 (* 1.35d0 settled))
             (%tile-scale subject) (+ 0.84d0 (* 0.16d0 progress))
             (%tile-effect subject) (expt (- 1d0 settled) 1.6d0))))
   :easing #'%ease-out-back
   :finish (lambda (subject)
             (setf (%tile-opacity subject) 1d0
                   (%tile-scale subject) 1d0
                   (%tile-effect subject) 0d0)))
  (%damage-node world node)
  (%request-all-frames world)
  node)

(defun %animate-node-focus (world node focused-p)
  (%animate-node-scalar
   world node :focus (if focused-p 1d0 0d0)
   (if focused-p 0.22d0 0.16d0)
   #'%tile-border-intensity
   (lambda (subject value) (setf (%tile-border-intensity subject) value))))

(defun %animate-node-lift (world node raised-p)
  (%animate-node-scalar
   world node :lift (if raised-p 1d0 0d0)
   (if raised-p 0.16d0 0.24d0)
   #'%tile-elevation
   (lambda (subject value) (setf (%tile-elevation subject) value))))

(defun %advance-node-animations (world timestamp)
  (when (> timestamp (%world-last-animation-time world))
    (multiple-value-bind (changed active-p)
        (ataxia.world:advance-animations (%world-animator world) timestamp)
      (setf (%world-last-animation-time world) timestamp)
      (dolist (node changed) (%damage-node world node timestamp))
      (when active-p (%request-all-frames world))))
  world)

(defun %set-component-membership (component outputs)
  (multiple-value-bind (surfaces revision)
      (ataxia.kernel:drawable-surfaces component)
    (declare (ignore revision))
    (map nil
         (lambda (surface)
           (let ((token
                   (ataxia.kernel:drawable-surface-protocol-token surface)))
             (when token
               (ataxia.kernel:set-wayland-surface-output-membership
                token outputs))))
         surfaces)))

(defun %update-node-membership (node)
  (%set-component-membership
   (tile-node-component node)
   (if (and (%visible-node-p node) (%tile-output-state node))
       (list (%tiling-output-output (%tile-output-state node)))
       nil))
  node)

(defun %update-cursor-membership (seat-state)
  (let ((cursor (%tiling-seat-cursor-surface seat-state)))
    (when (and cursor (eq (ataxia.kernel:object-state cursor) :live))
      (%set-component-membership
       cursor
       (if (%tiling-seat-output seat-state)
           (list (%tiling-output-output (%tiling-seat-output seat-state)))
           nil))))
  seat-state)

(defun %update-all-membership (world)
  (dolist (node (%world-nodes world)) (%update-node-membership node))
  (dolist (seat-state (%seat-states world))
    (%update-cursor-membership seat-state))
  world)

(defun %node-focused-p (world node)
  (some (lambda (seat-state) (eq node (%tiling-seat-focused seat-state)))
        (%seat-states world)))

(defun %focus-node (world seat-state node)
  (let ((old (%tiling-seat-focused seat-state))
        (seat (%tiling-seat-seat seat-state)))
    (unless (eq old node)
      (when old (%damage-node world old))
      (setf (%tiling-seat-focused seat-state) node)
      (when old
        (unless (%node-focused-p world old)
          (%animate-node-focus world old nil))
        (ataxia.kernel:interactable-focus
         (tile-node-component old) world seat :clear-keyboard)
        (unless (%node-focused-p world old)
          (ataxia.kernel:request-object-state
           (tile-node-component old) world :activated nil)))
      (ataxia.kernel:clear-wayland-focus seat :keyboard t)
      (when node
        (%animate-node-focus world node t)
        (ataxia.kernel:request-object-state
         (tile-node-component node) world :activated t)
        (ataxia.kernel:interactable-focus
         (tile-node-component node) world seat :keyboard)
        (%damage-node world node))))
  node)

(defun %focus-replacement (world seat-state removed)
  (when (eq removed (%tiling-seat-focused seat-state))
    (let* ((state (%tiling-seat-output seat-state))
           (nodes (remove removed (%output-nodes world state) :test #'eq)))
      (setf (%tiling-seat-focused seat-state) nil)
      (%focus-node world seat-state (first nodes)))))

(defun %captured-pointer-node (seat-state)
  (loop for node being the hash-values of (%tiling-seat-buttons seat-state)
        when node return node))

(defun %nodes-at-point (world state x y &optional (timestamp (%now)))
  (when state
    (loop for node in (reverse (%presented-output-nodes world state))
          when (multiple-value-bind (node-x node-y width height)
                   (%tile-geometry world node timestamp)
                 (and node-x
                      (<= node-x x (+ node-x width))
                      (<= node-y y (+ node-y height))))
            collect node)))

(defun %node-at-point (world state x y &optional (timestamp (%now)))
  (first (%nodes-at-point world state x y timestamp)))

(defun %node-local-position (world node x y)
  (multiple-value-bind (node-x node-y width height)
      (%tile-geometry world node)
    (multiple-value-bind (local-x local-y local-width local-height)
        (ataxia.kernel:drawable-local-bounds (tile-node-component node))
      (values (+ local-x (* (/ (- x node-x) width) local-width))
              (+ local-y (* (/ (- y node-y) height) local-height))))))

(defun %deliver-motion (world seat-state input)
  (let* ((old (%tiling-seat-hovered seat-state))
         (captured (%captured-pointer-node seat-state))
         (target
           (or captured
               (find-if
                (lambda (candidate)
                  (multiple-value-bind (local-x local-y)
                      (%node-local-position
                       world candidate
                       (%tiling-seat-x seat-state) (%tiling-seat-y seat-state))
                    (ataxia.kernel:interactable-hit-test
                     (tile-node-component candidate) world local-x local-y)))
                (%nodes-at-point
                 world (%tiling-seat-output seat-state)
                 (%tiling-seat-x seat-state) (%tiling-seat-y seat-state))))))
    (when (and old (not (eq old target)))
      (ataxia.kernel:interactable-pointer-leave
       (tile-node-component old) world (%tiling-seat-seat seat-state)))
    (setf (%tiling-seat-hovered seat-state) target)
    (unless target
      (ataxia.kernel:clear-wayland-focus
       (%tiling-seat-seat seat-state) :pointer t))
    (when target
      (multiple-value-bind (local-x local-y)
          (%node-local-position
           world target (%tiling-seat-x seat-state) (%tiling-seat-y seat-state))
        (ataxia.world:interaction-delivered-p
         (ataxia.kernel:interactable-pointer-motion
          (tile-node-component target) world (%tiling-seat-seat seat-state)
          local-x local-y input))))
    target))

(defun %revalidate-seat-pointer (world seat-state &optional input)
  (unless (plusp (hash-table-count (%tiling-seat-buttons seat-state)))
    (%deliver-motion
     world seat-state
     (or input (%tiling-seat-last-pointer-input seat-state)
         (ataxia.kernel:make-cursor-motion-input :time-msec 0)))))

(defun %revalidate-all-pointers (world)
  (dolist (seat-state (%seat-states world))
    (%revalidate-seat-pointer world seat-state))
  world)

(defun %deliver-button (world seat-state node input &key clamp-p)
  (when node
    (multiple-value-bind (local-x local-y)
        (%node-local-position
         world node (%tiling-seat-x seat-state) (%tiling-seat-y seat-state))
      (when clamp-p
        (multiple-value-bind (x y width height)
            (ataxia.kernel:drawable-local-bounds (tile-node-component node))
          (setf local-x (max x (min (- (+ x width) least-positive-double-float)
                                    local-x))
                local-y (max y (min (- (+ y height) least-positive-double-float)
                                    local-y)))))
      (ataxia.kernel:interactable-pointer-button
       (tile-node-component node) world (%tiling-seat-seat seat-state)
       local-x local-y input))))

(defun %deliver-axis (world seat-state node input)
  (when node
    (multiple-value-bind (local-x local-y)
        (%node-local-position
         world node (%tiling-seat-x seat-state) (%tiling-seat-y seat-state))
      (ataxia.kernel:interactable-pointer-axis
       (tile-node-component node) world (%tiling-seat-seat seat-state)
       local-x local-y input))))

(defun %clamp-coordinate (value extent)
  (max 0d0 (min (max 0d0 (- extent least-positive-double-float)) value)))

(defun %update-seat-position (seat-state input)
  (let ((state (%tiling-seat-output seat-state)))
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (if (ataxia.kernel:cursor-motion-input-absolute-p input)
            (setf (%tiling-seat-x seat-state)
                  (%clamp-coordinate
                   (* (ataxia.kernel:cursor-motion-input-x input) width) width)
                  (%tiling-seat-y seat-state)
                  (%clamp-coordinate
                   (* (ataxia.kernel:cursor-motion-input-y input) height) height))
            (setf (%tiling-seat-x seat-state)
                  (%clamp-coordinate
                   (+ (%tiling-seat-x seat-state)
                      (ataxia.kernel:cursor-motion-input-delta-x input)) width)
                  (%tiling-seat-y seat-state)
                  (%clamp-coordinate
                   (+ (%tiling-seat-y seat-state)
                      (ataxia.kernel:cursor-motion-input-delta-y input)) height))))))
  seat-state)

(defun %output-focus-nodes (world seat-state)
  (%output-nodes world (%tiling-seat-output seat-state)))

(defun %focus-relative (world seat-state delta)
  (let* ((nodes (%output-focus-nodes world seat-state))
         (focused (%tiling-seat-focused seat-state))
         (position (or (position focused nodes :test #'eq) 0)))
    (when nodes
      (%focus-node world seat-state
                   (nth (mod (+ position delta) (length nodes)) nodes)))))

(defun %swap-relative (world seat-state delta)
  (let* ((nodes (%output-focus-nodes world seat-state))
         (focused (%tiling-seat-focused seat-state))
         (position (position focused nodes :test #'eq)))
    (when (and position (> (length nodes) 1))
      (let* ((other (nth (mod (+ position delta) (length nodes)) nodes))
             (left (position focused (%world-nodes world) :test #'eq))
             (right (position other (%world-nodes world) :test #'eq)))
        (rotatef (nth left (%world-nodes world))
                 (nth right (%world-nodes world)))
        (%recompute-layout world)
        (%focus-node world seat-state focused)))))

(defun %move-focused-to-master (world seat-state)
  (let* ((nodes (%output-focus-nodes world seat-state))
         (focused (%tiling-seat-focused seat-state))
         (master (first nodes)))
    (when (and focused master (not (eq focused master)))
      (let ((left (position focused (%world-nodes world) :test #'eq))
            (right (position master (%world-nodes world) :test #'eq)))
        (rotatef (nth left (%world-nodes world))
                 (nth right (%world-nodes world)))
        (%recompute-layout world)))))

(defun %insert-node-relative (world node target after-p)
  (let* ((without-node (remove node (%world-nodes world) :test #'eq :count 1))
         (target-index (position target without-node :test #'eq))
         (insert-index (+ target-index (if after-p 1 0))))
    (setf (%world-nodes world)
          (append (subseq without-node 0 insert-index)
                  (list node)
                  (nthcdr insert-index without-node))))
  (%recompute-layout world))

(defun %drag-reorder (world seat-state)
  (let* ((dragged (%tiling-seat-drag-node seat-state))
         (state (%tiling-seat-output seat-state))
         (target (%node-at-point world state
                                 (%tiling-seat-x seat-state)
                                 (%tiling-seat-y seat-state))))
    (when (and dragged target (not (eq dragged target))
               (eq state (%tile-output-state dragged))
               (eq state (%tile-output-state target)))
      (multiple-value-bind (target-x target-y target-width target-height)
          (%tile-geometry world target)
        (declare (ignore target-x target-width))
        (%insert-node-relative
         world dragged target
         (and (not (eq target (first (%output-nodes world state))))
              (> (%tiling-seat-y seat-state)
                 (+ target-y (/ target-height 2d0)))))))))

(defun %begin-tile-drag (world seat-state node)
  (unless (%tile-fullscreen-p node)
    (setf (%tiling-seat-drag-node seat-state) node)
    (%focus-node world seat-state node)
    (%animate-node-lift world node t))
  node)

(defun %finish-tile-drag (world seat-state input)
  (let ((node (%tiling-seat-drag-node seat-state)))
    (when node
      (%deliver-button world seat-state node input :clamp-p t)
      (setf (%tiling-seat-drag-node seat-state) nil)
      (%animate-node-lift world node nil))
    node))

(defun %adjust-master-ratio (world seat-state amount)
  (let ((state (%tiling-seat-output seat-state)))
    (when state
      (setf (%tiling-output-master-ratio state)
            (max 0.30d0
                 (min 0.75d0 (+ (%tiling-output-master-ratio state) amount))))
      (%recompute-layout world))))

(defun %set-fullscreen (world node value)
  (when node
    (when value
      (dolist (other (%output-nodes world (%tile-output-state node)))
        (unless (eq other node)
          (setf (%tile-fullscreen-p other) nil)
          (ataxia.kernel:request-object-state
           (tile-node-component other) world :fullscreen nil))))
    (setf (%tile-fullscreen-p node) value)
    (ataxia.kernel:request-object-state
     (tile-node-component node) world :fullscreen value)
    (%recompute-layout world))
  node)

(defun %launch-terminal ()
  (handler-case
      (uiop:launch-program '("foot")
                           :input :null :output :null :error-output :null
                           :wait nil)
    (serious-condition (cause)
      (format *error-output* "[tiling-world] cannot launch foot: ~A~%" cause)
      (finish-output *error-output*))))

(defun %shortcut-pressed-p (seat-state input)
  (and (eq (ataxia.kernel:key-input-state input) :pressed)
       (logtest +modifier-logo+ (%tiling-seat-modifiers seat-state))))

(defun %handle-shortcut (world seat-state input)
  (when (%shortcut-pressed-p seat-state input)
    (let ((key (ataxia.kernel:key-input-keycode input))
          (shift-p (logtest +modifier-shift+
                            (%tiling-seat-modifiers seat-state))))
      (cond
        ((= key +key-enter+) (%launch-terminal) t)
        ((= key +key-q+)
         (when (%tiling-seat-focused seat-state)
           (ataxia.kernel:request-object-state
            (tile-node-component (%tiling-seat-focused seat-state))
            world :close t))
         t)
        ((= key +key-f+)
         (let ((node (%tiling-seat-focused seat-state)))
           (when node (%set-fullscreen world node (not (%tile-fullscreen-p node)))))
         t)
        ((= key +key-space+) (%move-focused-to-master world seat-state) t)
        ((= key +key-h+) (%adjust-master-ratio world seat-state -0.05d0) t)
        ((= key +key-l+) (%adjust-master-ratio world seat-state 0.05d0) t)
        ((= key +key-j+)
         (if shift-p
             (%swap-relative world seat-state 1)
             (%focus-relative world seat-state 1))
         t)
        ((= key +key-k+)
         (if shift-p
             (%swap-relative world seat-state -1)
             (%focus-relative world seat-state -1))
         t)
        (t nil)))))

(defmethod ataxia.kernel:world-attached ((world tiling-world) kernel)
  (setf (ataxia.kernel:world-kernel world) kernel
        (%world-quiescing-p world) nil)
  world)

(defmethod ataxia.kernel:world-quiescing ((world tiling-world) reason)
  (declare (ignore reason))
  (setf (%world-quiescing-p world) t)
  world)

(defmethod ataxia.kernel:world-detached ((world tiling-world) kernel)
  (when (eq kernel (ataxia.kernel:world-kernel world))
    (dolist (node (%world-nodes world))
      (ataxia.world:cancel-subject-animations (%world-animator world) node))
    (dolist (state (%output-states world))
      (ataxia.world:damage-forget-output
       (%world-damage world) (%tiling-output-output state)))
    (clrhash (%world-kernel-index world))
    (clrhash (%world-outputs world))
    (clrhash (%world-seats world))
    (setf (%world-nodes world) nil)
    (setf (ataxia.kernel:world-kernel world) nil))
  world)

(defmethod ataxia.kernel:world-register-object
    ((world tiling-world) (application ataxia.kernel:wayland-application))
  (unless (find-tile-node world application)
    (let* ((seat-state (first (%seat-states world)))
           (state (or (and seat-state (%tiling-seat-output seat-state))
                      (%first-output-state world)))
           (node (make-instance 'tile-node :component application
                                :output-state state)))
      (setf (gethash application (%world-kernel-index world)) node
            (%world-nodes world) (append (%world-nodes world) (list node))
            (%tile-mapped-p node)
            (ataxia.kernel:application-mapped-p application))
      (when (%tile-mapped-p node)
        (%animate-node-entry world node)
        (%recompute-layout world)
        (dolist (seat (%seat-states world))
          (when (eq state (%tiling-seat-output seat))
            (%focus-node world seat node))))))
  application)

(defmethod ataxia.kernel:world-unregister-object
    ((world tiling-world) (application ataxia.kernel:wayland-application) reason)
  (declare (ignore reason))
  (let ((node (find-tile-node world application)))
    (when node
      (ataxia.world:cancel-subject-animations (%world-animator world) node)
      (%damage-node world node)
      (%set-component-membership application nil)
      (remhash application (%world-kernel-index world))
      (setf (%world-nodes world)
            (delete node (%world-nodes world) :test #'eq))
      (dolist (seat-state (%seat-states world))
        (when (eq node (%tiling-seat-drag-node seat-state))
          (setf (%tiling-seat-drag-node seat-state) nil))
        (when (eq node (%tiling-seat-hovered seat-state))
          (ataxia.kernel:interactable-pointer-leave
           application world (%tiling-seat-seat seat-state))
          (setf (%tiling-seat-hovered seat-state) nil))
        (%focus-replacement world seat-state node)
        (let ((buttons (%tiling-seat-buttons seat-state)))
          (dolist (code
                    (loop for code being the hash-keys of buttons
                          using (hash-value target)
                          when (eq target node) collect code))
            (remhash code buttons))))
      (%recompute-layout world)))
  application)

(defmethod ataxia.kernel:world-object-changed
    ((world tiling-world) object change)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((node (find-tile-node world object)))
       (when (and node (eq (ataxia.kernel:object-change-kind change) :mapped))
         (%damage-node world node)
         (setf (%tile-mapped-p node)
               (ataxia.kernel:object-change-value change))
         (%recompute-layout world)
         (if (%tile-mapped-p node)
             (progn
               (%animate-node-entry world node)
               (dolist (seat-state (%seat-states world))
                 (when (eq (%tile-output-state node)
                           (%tiling-seat-output seat-state))
                   (%focus-node world seat-state node))))
             (progn
               (ataxia.world:cancel-subject-animations
                (%world-animator world) node)
               (setf (%tile-opacity node) 1d0
                     (%tile-scale node) 1d0
                     (%tile-effect node) 0d0
                     (%tile-elevation node) 0d0)
               (dolist (seat-state (%seat-states world))
                 (when (eq node (%tiling-seat-drag-node seat-state))
                   (setf (%tiling-seat-drag-node seat-state) nil))
                 (%focus-replacement world seat-state node)))))))
    (ataxia.kernel:surface-node
     (when (eq (ataxia.kernel:object-change-kind change) :destroying)
       (dolist (seat-state (%seat-states world))
         (when (eq object (%tiling-seat-cursor-surface seat-state))
           (%damage-cursor world seat-state)
           (setf (%tiling-seat-cursor-surface seat-state) nil))))))
  object)

(defmethod ataxia.kernel:world-object-invalidated
    ((world tiling-world) object invalidation)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((node (find-tile-node world object)))
       (when node
         (setf (%tile-drawable-revision node)
               (ataxia.kernel:drawable-invalidation-revision invalidation))
         (%damage-node-region
          world node (ataxia.kernel:drawable-invalidation-damage invalidation))
         (%update-node-membership node))))
    (ataxia.kernel:surface-node
     (dolist (seat-state (%seat-states world))
       (when (eq object (%tiling-seat-cursor-surface seat-state))
         (%damage-cursor world seat-state)
         (%update-cursor-membership seat-state)))))
  object)

(defmethod ataxia.kernel:world-output-added ((world tiling-world) output)
  (let ((state (%make-tiling-output output)))
    (setf (%tiling-output-buffer-width state)
          (max 1 (ataxia.kernel:output-width output))
          (%tiling-output-buffer-height state)
          (max 1 (ataxia.kernel:output-height output))
          (%tiling-output-transform state)
          (ataxia.kernel:output-transform output)
          (gethash output (%world-outputs world)) state)
    (dolist (node (%world-nodes world))
      (unless (%tile-output-state node) (setf (%tile-output-state node) state)))
    (dolist (seat-state (%seat-states world))
      (unless (%tiling-seat-output seat-state)
        (setf (%tiling-seat-output seat-state) state)
        (multiple-value-bind (width height) (%output-logical-size state)
          (setf (%tiling-seat-x seat-state) (/ width 2d0)
                (%tiling-seat-y seat-state) (/ height 2d0)))))
    (%recompute-layout world :animate-p nil))
  output)

(defmethod ataxia.kernel:world-output-changed
    ((world tiling-world) output change)
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
            (setf (%tiling-output-buffer-width state)
                  (max 1 (ataxia.kernel:output-width output))
                  (%tiling-output-buffer-height state)
                  (max 1 (ataxia.kernel:output-height output))
                  (%tiling-output-transform state)
                  (ataxia.kernel:output-transform output))
            (ataxia.world:damage-reset-output (%world-damage world) output)
            (%recompute-layout world :animate-p nil)))
      (%request-output-frame world state)))
  output)

(defmethod ataxia.kernel:world-output-removing ((world tiling-world) output)
  (let ((state (gethash output (%world-outputs world))))
    (when state
      (remhash output (%world-outputs world))
      (let ((replacement (%first-output-state world)))
        (dolist (node (%world-nodes world))
          (when (eq state (%tile-output-state node))
            (setf (%tile-output-state node) replacement)))
        (dolist (seat-state (%seat-states world))
          (when (eq state (%tiling-seat-output seat-state))
            (setf (%tiling-seat-output seat-state) replacement))))
      (ataxia.world:damage-forget-output (%world-damage world) output)
      (%recompute-layout world :animate-p nil)))
  output)

(defmethod ataxia.kernel:world-seat-added ((world tiling-world) seat)
  (let* ((state (%first-output-state world))
         (seat-state (%make-tiling-seat seat)))
    (setf (%tiling-seat-output seat-state) state
          (gethash seat (%world-seats world)) seat-state)
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (setf (%tiling-seat-x seat-state) (/ width 2d0)
              (%tiling-seat-y seat-state) (/ height 2d0)))
      (%focus-node world seat-state (first (%output-nodes world state))))
    (%damage-cursor world seat-state))
  seat)

(defmethod ataxia.kernel:world-seat-removing ((world tiling-world) seat)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (when (%tiling-seat-hovered seat-state)
        (ataxia.kernel:interactable-pointer-leave
         (tile-node-component (%tiling-seat-hovered seat-state)) world seat))
      (%focus-node world seat-state nil))
    (remhash seat (%world-seats world)))
  seat)

(defmethod ataxia.kernel:world-cursor-motion
    ((world tiling-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (setf (%tiling-seat-last-pointer-input seat-state) input)
      (%update-seat-position seat-state input)
      (if (%tiling-seat-drag-node seat-state)
          (%drag-reorder world seat-state)
          (%deliver-motion world seat-state input))
      (%damage-cursor world seat-state)))
  input)

(defmethod ataxia.kernel:world-cursor-button
    ((world tiling-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (let* ((code (ataxia.kernel:cursor-button-input-code input))
             (pressed-p
               (eq (ataxia.kernel:cursor-button-input-state input) :pressed))
             (buttons (%tiling-seat-buttons seat-state)))
        (if pressed-p
            (let ((target
                    (or (%tiling-seat-hovered seat-state)
                        (%node-at-point
                         world (%tiling-seat-output seat-state)
                         (%tiling-seat-x seat-state) (%tiling-seat-y seat-state)))))
              (when target (%focus-node world seat-state target))
              (when target (setf (gethash code buttons) target))
              (%deliver-button world seat-state target input))
            (let ((target (gethash code buttons)))
              (if (and (= code +button-left+)
                       (%tiling-seat-drag-node seat-state))
                  (%finish-tile-drag world seat-state input)
                  (%deliver-button world seat-state target input :clamp-p t))
              (remhash code buttons)
              (%revalidate-seat-pointer world seat-state input)))
        (%damage-cursor world seat-state))))
  input)

(defmethod ataxia.kernel:world-cursor-axis
    ((world tiling-world) seat input)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%deliver-axis
       world seat-state
       (or (%tiling-seat-hovered seat-state)
           (%node-at-point
            world (%tiling-seat-output seat-state)
            (%tiling-seat-x seat-state) (%tiling-seat-y seat-state)))
       input)))
  input)

(defmethod ataxia.kernel:world-key-event ((world tiling-world) seat input)
  (let* ((seat-state (gethash seat (%world-seats world)))
         (focused (and seat-state (%tiling-seat-focused seat-state))))
    (when seat-state
      (etypecase input
        (ataxia.kernel:modifiers-input
         (setf (%tiling-seat-modifiers seat-state)
               (logior (ataxia.kernel:modifiers-input-depressed input)
                       (ataxia.kernel:modifiers-input-latched input)
                       (ataxia.kernel:modifiers-input-locked input)))
         (when focused
           (ataxia.kernel:interactable-key-event
            (tile-node-component focused) world seat input)))
        (ataxia.kernel:key-input
         (let* ((key (ataxia.kernel:key-input-keycode input))
                (released-p
                  (eq (ataxia.kernel:key-input-state input) :released))
                (consumed-p
                  (gethash key (%tiling-seat-consumed-keys seat-state))))
           (cond
             ((and released-p consumed-p)
              (remhash key (%tiling-seat-consumed-keys seat-state)))
             ((%handle-shortcut world seat-state input)
              (setf (gethash key (%tiling-seat-consumed-keys seat-state)) t))
             (focused
              (ataxia.kernel:interactable-key-event
               (tile-node-component focused) world seat input))))))))
  input)

(defmethod ataxia.kernel:world-seat-cursor-request
    ((world tiling-world) seat request)
  (let ((seat-state (gethash seat (%world-seats world))))
    (when seat-state
      (%damage-cursor world seat-state)
      (setf (%tiling-seat-cursor-surface seat-state)
            (ataxia.kernel:cursor-surface-request-surface request)
            (%tiling-seat-cursor-hotspot-x seat-state)
            (ataxia.kernel:cursor-surface-request-hotspot-x request)
            (%tiling-seat-cursor-hotspot-y seat-state)
            (ataxia.kernel:cursor-surface-request-hotspot-y request))
      (%update-cursor-membership seat-state)
      (%damage-cursor world seat-state)))
  request)

(defmethod ataxia.kernel:world-client-request
    ((world tiling-world) (application ataxia.kernel:wayland-application) request)
  (let ((node (find-tile-node world application)))
    (when node
      (typecase request
        (ataxia.kernel:move-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq node
                          (gethash +button-left+
                                   (%tiling-seat-buttons seat-state))))
             (%begin-tile-drag world seat-state node))))
        (ataxia.kernel:fullscreen-client-request
         (%set-fullscreen
          world node (ataxia.kernel:state-client-request-value request)))
        (ataxia.kernel:state-client-request
         (case (ataxia.kernel:state-client-request-name request)
           (:activation
            (let ((seat-state
                    (or (gethash (ataxia.kernel:client-request-seat request)
                                 (%world-seats world))
                        (first (%seat-states world)))))
              (when seat-state (%focus-node world seat-state node))))
           (:maximized
            (ataxia.kernel:request-object-state
             application world :maximized
             (ataxia.kernel:state-client-request-value request)))
           (:minimized
            (%damage-node world node)
            (setf (%tile-hidden-p node)
                  (ataxia.kernel:state-client-request-value request))
            (%recompute-layout world))
           (otherwise
            (ataxia.kernel:request-object-state
             application world
             (ataxia.kernel:state-client-request-name request)
             (ataxia.kernel:state-client-request-value request))))))))
  request)

(defmethod ataxia.kernel:world-graphics-attached
    ((world tiling-world) graphics-context)
  (declare (ignore graphics-context))
  (setf (%world-renderer world) (%create-tiling-renderer))
  (dolist (node (%world-nodes world))
    (ataxia.kernel:drawable-attach-graphics (tile-node-component node)))
  (%full-damage-all world)
  world)

(defmethod ataxia.kernel:world-render ((world tiling-world) lease)
  (let* ((output (ataxia.kernel:frame-output lease))
         (state (gethash output (%world-outputs world)))
         (timestamp (ataxia.kernel:frame-timestamp lease)))
    (unless (and state (%world-renderer world))
      (error "Tiling World cannot render an unattached output."))
    (let ((geometry-changed-p
            (or (/= (%tiling-output-buffer-width state)
                    (ataxia.kernel:frame-width lease))
                (/= (%tiling-output-buffer-height state)
                    (ataxia.kernel:frame-height lease))
                (/= (%tiling-output-transform state)
                    (ataxia.kernel:frame-transform lease)))))
      (setf (%tiling-output-buffer-width state) (ataxia.kernel:frame-width lease)
            (%tiling-output-buffer-height state) (ataxia.kernel:frame-height lease)
            (%tiling-output-transform state) (ataxia.kernel:frame-transform lease))
      (when geometry-changed-p
        (ataxia.world:damage-reset-output (%world-damage world) output)
        (%recompute-layout world :animate-p nil)))
    (dolist (node (%presented-output-nodes world state))
      (multiple-value-bind (damage active-p)
          (ataxia.kernel:drawable-prepare-frame (tile-node-component node))
        (when damage (%damage-node-region world node damage timestamp))
        (when active-p (%request-output-frame world state))))
    (%advance-node-animations world timestamp)
    (%advance-layout-animation world timestamp)
    (multiple-value-bind (region damage-frame)
        (ataxia.world:damage-begin-frame
         (%world-damage world) output
         (ataxia.kernel:frame-target-token lease)
         (ataxia.kernel:frame-generation lease)
         (ataxia.kernel:frame-width lease)
         (ataxia.kernel:frame-height lease))
      (let ((tokens
              (if region
                  (%render-tiling
                   (%world-renderer world) world state (%seat-states world)
                   region timestamp (%world-damage-debug-p world))
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
    ((world tiling-world) output frame-result commit-info)
  (declare (ignore output commit-info))
  (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
    (when cookie
      (ataxia.world:damage-commit-frame
       (%world-damage world) (%world-frame-cookie-damage-frame cookie))))
  frame-result)

(defmethod ataxia.kernel:world-frame-failed
    ((world tiling-world) output frame-result reason)
  (declare (ignore output reason))
  (when frame-result
    (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
      (when cookie
        (ataxia.world:damage-fail-frame
         (%world-damage world) (%world-frame-cookie-damage-frame cookie)))))
  frame-result)

(defmethod ataxia.kernel:world-graphics-detaching
    ((world tiling-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (dolist (node (%world-nodes world))
    (ataxia.kernel:drawable-detach-graphics (tile-node-component node)))
  (when (%world-renderer world)
    (%destroy-tiling-renderer (%world-renderer world))
    (setf (%world-renderer world) nil))
  world)
