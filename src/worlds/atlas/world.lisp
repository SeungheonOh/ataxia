;;;; Packed atlas World policy and Kernel integration.
;;;;
;;;; This object is the sole Kernel-facing authority for the packed plane. It
;;;; owns the component tree, derived layout, cameras, input interpretation,
;;;; damage history, and GLES renderer while Kernel retains Wayland mechanics.

(in-package #:ataxia.atlas-world)

(defun make-atlas-world (&key damage-debug-p)
  (make-instance 'atlas-world :damage-debug-p damage-debug-p))

(defmethod ataxia.world:damage-debug-mode-p ((world atlas-world))
  (%world-damage-debug-p world))

(defmethod (setf ataxia.world:damage-debug-mode-p)
    (enabled (world atlas-world))
  (setf (%world-damage-debug-p world) enabled))

(defun %now ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defun find-atlas-object (world component)
  (gethash component (%world-kernel-object-index world)))

(defun %visible-packed-objects (world)
  (remove-if-not
   (lambda (object)
     (and (%object-visible-p object) (%packed-object-p object)))
   (%scene-object-sequence world)))

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

(defmethod ataxia.world:refresh-world ((world atlas-world))
  (%full-damage-all world)
  (%request-all-frames world))

(defun %damage-object (world object &optional (timestamp (%now)))
  (when (%object-visible-p object)
    (dolist (state (%output-states world))
      (let ((coverage
              (%object-buffer-coverage
               state (%world-layout world) object timestamp)))
        (when coverage
          (ataxia.world:damage-add-region
           (%world-damage world) (%atlas-output-output state)
           (list coverage))))))
  object)

(defun %object-on-output-p (world object state timestamp)
  (nth-value 0
             (%object-screen-geometry
              state (%world-layout world) object timestamp)))

(defun %request-object-frames (world object &optional (timestamp (%now)))
  (dolist (state (%output-states world))
    (when (%object-on-output-p world object state timestamp)
      (%request-output-state-frame world state)))
  object)

(defun %damage-object-region (world object rectangles &optional (timestamp (%now)))
  (when (and rectangles (%object-visible-p object))
    (dolist (state (%output-states world))
      (multiple-value-bind (screen-x screen-y screen-width screen-height)
          (%object-screen-geometry state (%world-layout world) object timestamp)
        (when screen-x
          (multiple-value-bind (local-x local-y local-width local-height)
              (ataxia.kernel:drawable-local-bounds
               (atlas-object-component object))
            (when (and (plusp local-width) (plusp local-height))
              (ataxia.world:damage-add-region
               (%world-damage world) (%atlas-output-output state)
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
                rectangles))))))))
  object)

(defun %cursor-buffer-coverage (state seat-state)
  (let ((cursor (%atlas-seat-cursor-surface seat-state))
        (x (%atlas-seat-x seat-state))
        (y (%atlas-seat-y seat-state)))
    (if (and cursor (eq (ataxia.kernel:object-state cursor) :live))
        (multiple-value-bind (surfaces revision)
            (ataxia.kernel:drawable-surfaces cursor)
          (declare (ignore revision))
          (loop for surface across surfaces
                collect
                (%screen-rectangle-to-buffer
                 state
                 (+ (- x (%atlas-seat-cursor-hotspot-x seat-state))
                    (ataxia.kernel:drawable-surface-local-x surface))
                 (+ (- y (%atlas-seat-cursor-hotspot-y seat-state))
                    (ataxia.kernel:drawable-surface-local-y surface))
                 (ataxia.kernel:drawable-surface-width surface)
                 (ataxia.kernel:drawable-surface-height surface)
                 2d0)))
        (list (%screen-rectangle-to-buffer
               state (- x 4d0) (- y 4d0) 9d0 33d0)))))

(defun %damage-cursor (world seat-state)
  (let* ((state (%atlas-seat-output seat-state))
         (coverage (and state (%cursor-buffer-coverage state seat-state)))
         (previous-output (%atlas-seat-cursor-coverage-output seat-state)))
    (when (and previous-output (%atlas-seat-cursor-coverage seat-state))
      (ataxia.world:damage-add-region
       (%world-damage world) previous-output
       (%atlas-seat-cursor-coverage seat-state)))
    (when state
      (ataxia.world:damage-add-region
       (%world-damage world) (%atlas-output-output state) coverage))
    (setf (%atlas-seat-cursor-coverage seat-state) coverage
          (%atlas-seat-cursor-coverage-output seat-state)
          (and state (%atlas-output-output state))))
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
    (dolist (object (%visible-packed-objects world))
      (multiple-value-bind (x y width height)
          (%placement-geometry layout object timestamp)
        (when x
          (setf (gethash object captured)
                (%make-atlas-placement object x y width height)))))
    (and (plusp (hash-table-count captured)) captured)))

(defun %repack-world (world &key (animate-p t))
  (let* ((timestamp (%now))
         (layout (%world-layout world))
         (previous (and animate-p (%capture-current-layout world timestamp))))
    (multiple-value-bind (placements width height)
        (%pack-atlas (%visible-packed-objects world))
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
      (some (lambda (object)
              (let ((start (%atlas-object-appearance-start object)))
                (and start (< (- timestamp start) 0.18d0))))
            (%visible-packed-objects world))))

(defun %advance-visual-state (world timestamp)
  (let ((layout (%world-layout world)))
    (when (%atlas-layout-previous layout)
      (if (< (%layout-transition-progress layout timestamp) 1d0)
          (progn
            (%full-damage-all world)
            (%update-all-membership world)
            (%revalidate-all-pointers world))
          (progn
            (setf (%atlas-layout-previous layout) nil)
            (%full-damage-all world)))))
  (dolist (object (%visible-packed-objects world))
    (let ((start (%atlas-object-appearance-start object)))
      (when start
        (%damage-object world object timestamp)
        (when (>= (- timestamp start) 0.18d0)
          (setf (%atlas-object-appearance-start object) nil)))))
  (when (%visual-animation-active-p world timestamp)
    (%request-all-frames world)))

(defun %blur-target (world seat-state target)
  (let ((component (atlas-object-component target)))
    (ataxia.kernel:request-object-state component world :activated nil)
    (ataxia.kernel:interactable-focus
     component world (%atlas-seat-seat seat-state) :clear-keyboard)))

(defun %focus-target (world seat-state target)
  (let ((old (%atlas-seat-focused seat-state)))
    (unless (eq old target)
      (when old (%blur-target world seat-state old))
      (setf (%atlas-seat-focused seat-state) target)
      (ataxia.kernel:clear-wayland-focus
       (%atlas-seat-seat seat-state) :keyboard t)
      (when target
        (let ((component (atlas-object-component target)))
          (ataxia.kernel:request-object-state
           component world :activated t)
          (ataxia.kernel:interactable-focus
           component world (%atlas-seat-seat seat-state) :keyboard)))))
  target)

(defun %top-visible-object (world &optional excluded)
  (find-if (lambda (object)
             (and (not (eq object excluded)) (%object-visible-p object)))
           (reverse (%scene-object-sequence world))))

(defun %replace-focused-object (world seat-state removed-object)
  (when (eq removed-object (%atlas-seat-focused seat-state))
    (setf (%atlas-seat-focused seat-state) nil)
    (ataxia.kernel:clear-wayland-focus
     (%atlas-seat-seat seat-state) :keyboard t)
    (let ((replacement (%top-visible-object world removed-object)))
      (when replacement (%focus-target world seat-state replacement)))))

(defun %objects-at-screen-point (world state x y &optional (timestamp (%now)))
  (when state
    (loop for object in (reverse (%scene-object-sequence world))
          when (and (%object-visible-p object)
                    (multiple-value-bind (object-x object-y width height)
                        (%object-screen-geometry
                         state (%world-layout world) object timestamp)
                      (and object-x
                           (<= object-x x (+ object-x width))
                           (<= object-y y (+ object-y height)))))
            collect object)))

(defun %object-at-screen-point (world state x y &optional (timestamp (%now)))
  (first (%objects-at-screen-point world state x y timestamp)))

(defun %target-at-screen-point (world state x y)
  (%object-at-screen-point world state x y))

(defun %target-local-position (world state object x y)
  (multiple-value-bind (object-x object-y width height)
      (%object-screen-geometry state (%world-layout world) object (%now))
    (multiple-value-bind (local-x local-y local-width local-height)
        (ataxia.kernel:drawable-local-bounds
         (atlas-object-component object))
      (values (+ local-x (* (/ (- x object-x) width) local-width))
              (+ local-y (* (/ (- y object-y) height) local-height))))))

(defun %captured-pointer-target (seat-state)
  (loop for target being the hash-values of (%atlas-seat-buttons seat-state)
        when (and target (not (eq target :world))) return target))

(defun %deliver-motion (world seat-state input)
  (let* ((state (%atlas-seat-output seat-state))
         (old (%atlas-seat-hovered seat-state))
         (captured (%captured-pointer-target seat-state))
         (target
           (and state
                (or captured
                    (find-if
                     (lambda (candidate)
                       (multiple-value-bind (local-x local-y)
                           (%target-local-position
                            world state candidate
                            (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
                         (ataxia.kernel:interactable-hit-test
                          (atlas-object-component candidate) world
                          local-x local-y)))
                     (%objects-at-screen-point
                      world state
                      (%atlas-seat-x seat-state)
                      (%atlas-seat-y seat-state)))))))
    (when (and old (not (eq old target)))
      (ataxia.kernel:interactable-pointer-leave
       (atlas-object-component old) world (%atlas-seat-seat seat-state)))
    (setf (%atlas-seat-hovered seat-state) target)
    (unless target
      (ataxia.kernel:clear-wayland-focus
       (%atlas-seat-seat seat-state) :pointer t))
    (when target
      (multiple-value-bind (local-x local-y)
          (%target-local-position
           world state target
           (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
        (ataxia.world:interaction-delivered-p
         (ataxia.kernel:interactable-pointer-motion
          (atlas-object-component target) world
          (%atlas-seat-seat seat-state) local-x local-y input))))
    target))

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

(defun %deliver-button-to-target (world seat-state target input &key clamp-p)
  (when target
    (multiple-value-bind (local-x local-y)
        (%target-local-position
         world (%atlas-seat-output seat-state) target
         (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
      (when clamp-p
        (multiple-value-bind (bounds-x bounds-y bounds-width bounds-height)
            (ataxia.kernel:drawable-local-bounds
             (atlas-object-component target))
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
       (atlas-object-component target) world
       (%atlas-seat-seat seat-state) local-x local-y input))))

(defun %deliver-axis-to-target (world seat-state target input)
  (when target
    (multiple-value-bind (local-x local-y)
        (%target-local-position
         world (%atlas-seat-output seat-state) target
         (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
      (ataxia.kernel:interactable-pointer-axis
       (atlas-object-component target) world
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

(defun %begin-pan (seat-state button &key object forward-release-p)
  (let ((state (%atlas-seat-output seat-state)))
    (setf (%atlas-seat-operation seat-state)
          (%make-atlas-operation
           :kind :pan :button button :object object
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

(defun %begin-resize (world seat-state object edges)
  (setf (%atlas-seat-operation seat-state)
        (%make-atlas-operation
         :kind :resize :button +button-left+ :object object :edges edges
         :forward-release-p t
         :cursor-x (%atlas-seat-x seat-state)
         :cursor-y (%atlas-seat-y seat-state)
         :object-width (atlas-object-width object)
         :object-height (atlas-object-height object)))
  (%focus-target world seat-state object)
  (ataxia.kernel:request-object-state
   (atlas-object-component object) world :resizing t))

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
         (object (%atlas-operation-object operation))
         (zoom (%atlas-output-zoom state))
         (delta-x (/ (- (%atlas-seat-x seat-state)
                        (%atlas-operation-cursor-x operation)) zoom))
         (delta-y (/ (- (%atlas-seat-y seat-state)
                        (%atlas-operation-cursor-y operation)) zoom))
         (edges (%atlas-operation-edges operation))
         (width (%atlas-operation-object-width operation))
         (height (%atlas-operation-object-height operation))
         (layout (%world-layout world))
         (placement (gethash object (%atlas-layout-placements layout))))
    (when (logtest +resize-left+ edges) (decf width delta-x))
    (when (logtest +resize-right+ edges) (incf width delta-x))
    (when (logtest +resize-top+ edges) (decf height delta-y))
    (when (logtest +resize-bottom+ edges) (incf height delta-y))
    (%damage-object world object)
    (setf (atlas-object-width object) (max 96d0 width)
          (atlas-object-height object) (max 64d0 height))
    (when placement
      (setf (%atlas-placement-width placement) (atlas-object-width object)
            (%atlas-placement-height placement) (atlas-object-height object)))
    (incf (%atlas-layout-revision layout))
    (ataxia.kernel:request-object-configuration
     (atlas-object-component object) world
     (make-instance 'ataxia.kernel:toplevel-configuration
                    :width (round (atlas-object-width object))
                    :height (round (atlas-object-height object))
                    :resizing t))
    (%damage-object world object)
    (%update-object-membership world object)
    (%revalidate-all-pointers world)
    (%request-all-frames world)))

(defun %apply-operation (world seat-state)
  (let ((operation (%atlas-seat-operation seat-state)))
    (when operation
      (ecase (%atlas-operation-kind operation)
        (:pan (%apply-pan world seat-state operation))
        (:resize (%apply-resize world seat-state operation))))))

(defun %finish-operation (world seat-state input)
  (let ((operation (%atlas-seat-operation seat-state)))
    (when operation
      (let ((object (%atlas-operation-object operation)))
        (when (and object (%atlas-operation-forward-release-p operation))
          (%deliver-button-to-target
           world seat-state object input :clamp-p t))
        (when (and object (eq (%atlas-operation-kind operation) :resize))
          (ataxia.kernel:request-object-state
           (atlas-object-component object) world :resizing nil)
          (%repack-world world)))
      (setf (%atlas-seat-operation seat-state) nil)
      (%revalidate-seat-pointer world seat-state input))))

(defun %object-resize-active-p (world object)
  (some (lambda (seat-state)
          (let ((operation (%atlas-seat-operation seat-state)))
            (and operation
                 (eq (%atlas-operation-kind operation) :resize)
                 (eq (%atlas-operation-object operation) object))))
        (%seat-states world)))

(defun %sync-object-size (object)
  (multiple-value-bind (x y width height)
      (ataxia.kernel:drawable-local-bounds (atlas-object-component object))
    (declare (ignore x y))
    (when (and (plusp width) (plusp height))
      (let ((new-width (coerce width 'double-float))
            (new-height (coerce height 'double-float)))
        (unless (and (= new-width (atlas-object-width object))
                     (= new-height (atlas-object-height object)))
          (setf (atlas-object-width object) new-width
                (atlas-object-height object) new-height)
          (return-from %sync-object-size t)))))
  nil)

(defun %object-output-membership (world state object)
  (let ((coverage
          (%object-buffer-coverage
           state (%world-layout world) object (%now))))
    (when (and coverage
               (ataxia.world:rectangle-intersection
                (ataxia.world:make-rectangle
                 0 0 (%atlas-output-buffer-width state)
                 (%atlas-output-buffer-height state))
                coverage))
      (%atlas-output-output state))))

(defun %update-object-membership (world object)
  (let ((outputs
          (loop for state in (%output-states world)
                for output = (%object-output-membership world state object)
                when output collect output)))
    (multiple-value-bind (surfaces revision)
        (ataxia.kernel:drawable-surfaces (atlas-object-component object))
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
  (let ((cursor (%atlas-seat-cursor-surface seat-state)))
    (when (and cursor (eq (ataxia.kernel:object-state cursor) :live))
      (multiple-value-bind (surfaces revision)
          (ataxia.kernel:drawable-surfaces cursor)
        (declare (ignore revision))
        (map nil
             (lambda (surface)
               (let ((token
                       (ataxia.kernel:drawable-surface-presentation-token surface)))
                 (when token
                   (ataxia.kernel:set-wayland-surface-output-membership
                    token
                    (if (%atlas-seat-output seat-state)
                        (list (%atlas-output-output
                               (%atlas-seat-output seat-state)))
                        nil)))))
             surfaces)))))

(defun %update-all-membership (world)
  (dolist (object (%scene-object-sequence world))
    (%update-object-membership world object))
  (dolist (seat-state (%seat-states world))
    (%update-cursor-membership seat-state))
  world)

(defun %set-object-expanded (world object state requested-p output-state)
  (when output-state
    (if requested-p
        (progn
          (unless (%atlas-object-restore-size object)
            (setf (%atlas-object-restore-size object)
                  (cons (atlas-object-width object)
                        (atlas-object-height object))))
          (multiple-value-bind (logical-width logical-height)
              (%output-logical-size output-state)
            (setf (atlas-object-width object)
                  (/ logical-width (%atlas-output-zoom output-state))
                  (atlas-object-height object)
                  (/ logical-height (%atlas-output-zoom output-state)))))
        (when (%atlas-object-restore-size object)
          (setf (atlas-object-width object)
                (car (%atlas-object-restore-size object))
                (atlas-object-height object)
                (cdr (%atlas-object-restore-size object))
                (%atlas-object-restore-size object) nil)))
    (%repack-world world :animate-p nil)
    (when requested-p
      (multiple-value-bind (x y width height)
          (%placement-geometry (%world-layout world) object (%now))
        (declare (ignore width height))
        (when x
          (setf (%atlas-output-camera-x output-state) x
                (%atlas-output-camera-y output-state) y
                (%atlas-output-camera-authored-p output-state) t))))
    (ataxia.kernel:request-object-state
     (atlas-object-component object) world state requested-p)
    (ataxia.kernel:request-object-configuration
     (atlas-object-component object) world
     (make-instance 'ataxia.kernel:toplevel-configuration
                    :width (round (atlas-object-width object))
                    :height (round (atlas-object-height object))))
    (%full-damage world output-state)))

(defmethod ataxia.kernel:world-attached ((world atlas-world) kernel)
  (setf (ataxia.kernel:world-kernel world) kernel
        (%world-quiescing-p world) nil)
  world)

(defmethod ataxia.kernel:world-quiescing ((world atlas-world) reason)
  (declare (ignore reason))
  (setf (%world-quiescing-p world) t)
  (%remove-component-timer world)
  world)

(defmethod ataxia.kernel:world-detached ((world atlas-world) kernel)
  (when (eq kernel (ataxia.kernel:world-kernel world))
    (%destroy-output-components world)
    (dolist (state (%output-states world))
      (ataxia.world:damage-forget-output
       (%world-damage world) (%atlas-output-output state)))
    (setf (%scene-root-children (%world-scene world)) nil)
    (clrhash (%world-kernel-object-index world))
    (clrhash (%world-outputs world))
    (clrhash (%world-seats world))
    (setf (ataxia.kernel:world-kernel world) nil))
  world)

(defmethod ataxia.kernel:world-register-object
    ((world atlas-world) (application ataxia.kernel:wayland-application))
  (unless (find-atlas-object world application)
    (let ((object
            (make-instance
             'atlas-object :component application
             :mapping (make-instance 'atlas-plane-mapping)
             :width 900d0 :height 600d0
             :mapped-p (ataxia.kernel:application-mapped-p application))))
      (%insert-scene-object world object)
      (setf (gethash application (%world-kernel-object-index world)) object
            (%atlas-object-mapped-p object)
            (ataxia.kernel:application-mapped-p application))
      (when (%atlas-object-mapped-p object)
        (%sync-object-size object)
        (setf (%atlas-object-appearance-start object) (%now)))
      (%repack-world world)))
  application)

(defmethod ataxia.kernel:world-unregister-object
    ((world atlas-world) (application ataxia.kernel:wayland-application) reason)
  (declare (ignore reason))
  (let ((object (find-atlas-object world application)))
    (when object
      (%damage-object world object)
      (remhash application (%world-kernel-object-index world))
      (%remove-scene-object world object)
      (dolist (seat-state (%seat-states world))
        (%replace-focused-object world seat-state object)
        (when (eq object (%atlas-seat-hovered seat-state))
          (ataxia.kernel:interactable-pointer-leave
           application world (%atlas-seat-seat seat-state))
          (setf (%atlas-seat-hovered seat-state) nil))
        (let ((buttons (%atlas-seat-buttons seat-state)))
          (dolist (code
                    (loop for code being the hash-keys of buttons
                          using (hash-value target)
                          when (eq target object) collect code))
            (remhash code buttons)))
        (when (and (%atlas-seat-operation seat-state)
                   (eq object
                       (%atlas-operation-object
                        (%atlas-seat-operation seat-state))))
          (setf (%atlas-seat-operation seat-state) nil)))
      (%repack-world world)))
  application)

(defmethod ataxia.kernel:world-object-changed
    ((world atlas-world) object change)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((scene-object (find-atlas-object world object)))
       (when (and scene-object
                  (eq (ataxia.kernel:object-change-kind change) :mapped))
         (%damage-object world scene-object)
         (setf (%atlas-object-mapped-p scene-object)
               (ataxia.kernel:object-change-value change))
         (if (%atlas-object-mapped-p scene-object)
             (progn
               (%sync-object-size scene-object)
               (setf (%atlas-object-appearance-start scene-object) (%now))
               (dolist (seat-state (%seat-states world))
                 (%focus-target world seat-state scene-object)))
             (dolist (seat-state (%seat-states world))
               (%replace-focused-object world seat-state scene-object)))
         (%repack-world world))))
    (ataxia.kernel:surface-node
     (when (eq (ataxia.kernel:object-change-kind change) :destroying)
       (dolist (seat-state (%seat-states world))
         (when (eq object (%atlas-seat-cursor-surface seat-state))
           (%damage-cursor world seat-state)
           (setf (%atlas-seat-cursor-surface seat-state) nil)
           (%damage-cursor world seat-state)
           (%request-output-state-frame
            world (%atlas-seat-output seat-state)))))))
  object)

(defmethod ataxia.kernel:world-object-invalidated
    ((world atlas-world) object invalidation)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((scene-object (find-atlas-object world object)))
       (when scene-object
         (let ((size-changed-p nil))
           (unless (%object-resize-active-p world scene-object)
             (multiple-value-bind (x y width height)
                 (ataxia.kernel:drawable-local-bounds object)
               (declare (ignore x y))
               (setf size-changed-p
                     (and (plusp width) (plusp height)
                          (or (/= width (atlas-object-width scene-object))
                              (/= height (atlas-object-height scene-object)))))
               (when size-changed-p
                 (%damage-object world scene-object)
                 (%sync-object-size scene-object))))
           (setf (%atlas-object-drawable-revision scene-object)
                 (ataxia.kernel:drawable-invalidation-revision invalidation))
           (if size-changed-p
               (%repack-world world)
               (progn
                 (%damage-object-region
                  world scene-object
                  (ataxia.world:frame-damage-to-region
                   (ataxia.kernel:drawable-invalidation-damage invalidation)))
                 (%update-object-membership world scene-object)
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
    (let ((object (%make-output-component world state)))
      (%insert-scene-object world object)
      (setf (gethash output (%world-output-components world)) object))
    (%install-component-timer world)
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
            (let ((object (gethash output (%world-output-components world))))
              (when object (%resize-output-component object)))
            (ataxia.world:damage-reset-output (%world-damage world) output)
            (unless (%atlas-output-camera-authored-p state)
              (fit-output-camera world output))))
      (%request-output-state-frame world state)
      (%update-all-membership world)))
  output)

(defmethod ataxia.kernel:world-output-removing ((world atlas-world) output)
  (let ((state (gethash output (%world-outputs world)))
        (object (gethash output (%world-output-components world))))
    (when state
      (when object
        (dolist (seat-state (%seat-states world))
          (when (eq object (%atlas-seat-focused seat-state))
            (%focus-target world seat-state nil))
          (when (eq object (%atlas-seat-hovered seat-state))
            (ataxia.kernel:interactable-pointer-leave
             (atlas-object-component object) world
             (%atlas-seat-seat seat-state))
            (setf (%atlas-seat-hovered seat-state) nil))
          (let ((buttons (%atlas-seat-buttons seat-state)))
            (dolist (code
                      (loop for code being the hash-keys of buttons
                            using (hash-value target)
                            when (eq target object) collect code))
              (remhash code buttons))))
        (%retire-output-component world output))
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
    (when seat-state
      (%damage-cursor world seat-state)
      (when (%atlas-seat-focused seat-state)
        (%blur-target world seat-state (%atlas-seat-focused seat-state)))
      (when (%atlas-seat-hovered seat-state)
        (ataxia.kernel:interactable-pointer-leave
         (atlas-object-component (%atlas-seat-hovered seat-state))
         world seat)))
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
            (let ((target
                    (or (%atlas-seat-hovered seat-state)
                        (%target-at-screen-point
                         world (%atlas-seat-output seat-state)
                         (%atlas-seat-x seat-state) (%atlas-seat-y seat-state)))))
              (when target (%focus-target world seat-state target))
              (if (= code +button-middle+)
                  (progn
                    (setf (gethash code buttons) :world)
                    (%begin-pan seat-state code))
                  (progn
                    (setf (gethash code buttons) (or target :world))
                    (%deliver-button-to-target
                     world seat-state target input :clamp-p nil))))
            (let ((target (gethash code buttons))
                  (operation (%atlas-seat-operation seat-state)))
              (cond
                ((and operation (= code (%atlas-operation-button operation)))
                 (%finish-operation world seat-state input))
                ((typep target 'atlas-object)
                 (%deliver-button-to-target
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
             (target
               (or (%atlas-seat-hovered seat-state)
                   (%target-at-screen-point
                    world state (%atlas-seat-x seat-state)
                    (%atlas-seat-y seat-state))))
             (zoom-p
               (and (eq (ataxia.kernel:cursor-axis-input-orientation input)
                        :vertical)
                    (or (and operation
                             (eq (%atlas-operation-kind operation) :pan))
                        (null target)))))
        (if zoom-p
            (progn
              (%zoom-output-camera
               world state
               (exp (* -0.0025d0
                       (ataxia.kernel:cursor-axis-input-delta input)))
               (%atlas-seat-x seat-state) (%atlas-seat-y seat-state))
              (%restart-pan-anchor seat-state)
              (%revalidate-seat-pointer world seat-state input))
            (%deliver-axis-to-target world seat-state target input)))))
  input)

(defmethod ataxia.kernel:world-key-event ((world atlas-world) seat input)
  (let* ((seat-state (gethash seat (%world-seats world)))
         (target (and seat-state (%atlas-seat-focused seat-state))))
    (when (and target (%object-visible-p target))
      (ataxia.kernel:interactable-key-event
       (atlas-object-component target) world seat input)))
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
  (let ((object (find-atlas-object world application)))
    (when object
      (typecase request
        (ataxia.kernel:move-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq object
                          (gethash +button-left+
                                   (%atlas-seat-buttons seat-state))))
             (%begin-pan
              seat-state +button-left+ :object object
              :forward-release-p t))))
        (ataxia.kernel:resize-client-request
         (let ((seat-state
                 (gethash (ataxia.kernel:client-request-seat request)
                          (%world-seats world))))
           (when (and seat-state
                      (eq object
                          (gethash +button-left+
                                   (%atlas-seat-buttons seat-state))))
             (%begin-resize
              world seat-state object
              (ataxia.kernel:resize-client-request-edges request)))))
        (ataxia.kernel:fullscreen-client-request
         (when (%atlas-object-mapped-p object)
           (%set-object-expanded
            world object :fullscreen
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
              (when (and seat-state (%atlas-object-mapped-p object))
                (%focus-target world seat-state object))))
           (:maximized
            (when (%atlas-object-mapped-p object)
              (%set-object-expanded
               world object :maximized
               (ataxia.kernel:state-client-request-value request)
               (%first-output-state world))))
           (:minimized
            (%damage-object world object)
            (setf (%atlas-object-hidden-p object)
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
  (dolist (object (%scene-object-sequence world))
    (ataxia.kernel:drawable-attach-graphics
     (atlas-object-component object)))
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
    (%reap-retired-components world)
    (dolist (object (%scene-object-sequence world))
      (when (and (%object-visible-p object)
                 (%object-on-output-p world object state timestamp))
        (multiple-value-bind (damage active-p)
            (ataxia.kernel:drawable-prepare-frame
             (atlas-object-component object))
          (when damage
            (%damage-object-region world object damage timestamp))
          (when active-p
            (%request-object-frames world object timestamp)))))
    (%schedule-component-timer world)
    (%advance-visual-state world timestamp)
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
                   (%scene-object-sequence world)
                   (%seat-states world) region timestamp
                   (%world-damage-debug-p world))
                  #())))
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
  (declare (ignore output reason))
  (when frame-result
    (let ((cookie (ataxia.kernel:frame-result-world-cookie frame-result)))
      (when cookie
        (ataxia.world:damage-fail-frame
         (%world-damage world) (%world-frame-cookie-damage-frame cookie)))))
  frame-result)

(defmethod ataxia.kernel:world-graphics-detaching
    ((world atlas-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (dolist (object (%scene-object-sequence world))
    (ataxia.kernel:drawable-detach-graphics
     (atlas-object-component object)))
  (%reap-retired-components world)
  (when (%world-renderer world)
    (%destroy-atlas-renderer (%world-renderer world))
    (setf (%world-renderer world) nil))
  world)
