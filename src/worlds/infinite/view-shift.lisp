;;;; Mouse-directed viewport shifting for the Infinite World.
;;;;
;;;; Holding Meta+Shift anchors a small HUD at the cursor. Cursor distance and
;;;; direction from that anchor continuously control camera velocity.

(in-package #:ataxia.infinite-world)

(defconstant +view-shift-dead-zone+ 42d0)
(defconstant +view-shift-ramp-distance+ 150d0)
(defconstant +view-shift-max-speed+ 900d0)

(defclass %view-shift-state ()
  ((output-state :initarg :output-state :reader %view-shift-output-state)
   (anchor-x :initarg :anchor-x :reader %view-shift-anchor-x)
   (anchor-y :initarg :anchor-y :reader %view-shift-anchor-y)
   (last-time :initarg :last-time :accessor %view-shift-last-time)
   (overlay :initarg :overlay :reader %view-shift-overlay)))

(defun %view-shift-for-seat (world seat)
  (gethash seat (%world-view-shifts world)))

(defun %set-view-shift-properties (shift cursor-x cursor-y)
  (let ((component
          (overlay-component (%view-shift-overlay shift))))
    (ataxia.world:ui-set-property
     component "anchor-x" (%view-shift-anchor-x shift))
    (ataxia.world:ui-set-property
     component "anchor-y" (%view-shift-anchor-y shift))
    (ataxia.world:ui-set-property component "cursor-x" cursor-x)
    (ataxia.world:ui-set-property component "cursor-y" cursor-y))
  shift)

(defun %make-view-shift-overlay (world state)
  (let* ((output (%canvas-output-output state))
         (component nil)
         (overlay nil))
    (multiple-value-bind (width height) (%output-logical-size state)
      (handler-case
          (progn
            (setf component
                  (ataxia.world.web.ui:make-ui-component
                   :world world
                   :source-path (asdf:system-relative-pathname "ataxia-infinite-world" "src/worlds/infinite/view-shift.html")
                   :component-name "ViewShiftHud"
                   :width width :height height
                   :scale (ataxia.kernel:output-scale output))
                  overlay
                  (make-instance 'ataxia.world.web.ui:document-overlay
                   :component component :output output :x 0d0 :y 0d0 :width width :height height
                   :layer 1900 :visible-p t :opacity 1d0))
            (ataxia.world:ui-set-invalidator
             component
             (lambda (ignored)
               (declare (ignore ignored))
               (%request-output-state-frame world state)
               (%schedule-component-timer world)))
            (add-overlay world overlay))
        (serious-condition (cause)
          (unless (and overlay
                       (member overlay (world-overlays world) :test #'eq))
            (when component
              (ataxia.world:ui-set-invalidator component nil)
              (ataxia.world:ui-destroy component)))
          (error cause))))
    overlay))

(defun %sync-view-shift-overlay (world seat-state shift)
  (let* ((state (%view-shift-output-state shift))
         (overlay (%view-shift-overlay shift)))
    (multiple-value-bind (width height) (%output-logical-size state)
      (when (or (/= width (overlay-width overlay))
                (/= height (overlay-height overlay)))
        (%damage-overlay world overlay)
        (setf (overlay-width overlay) width
              (overlay-height overlay) height)
        (ataxia.world:ui-resize
         (overlay-component overlay) width height
         :scale (ataxia.world:ui-raster-scale
                 (overlay-component overlay)))
        (%damage-overlay world overlay)))
    (%set-view-shift-properties
     shift (%canvas-seat-x seat-state) (%canvas-seat-y seat-state))))

(defun %begin-view-shift (world seat seat-state)
  (unless (or (%view-shift-for-seat world seat)
              (%canvas-seat-operation seat-state))
    (let ((state (%canvas-seat-output seat-state)))
      (when state
        (let* ((anchor-x (%canvas-seat-x seat-state))
               (anchor-y (%canvas-seat-y seat-state))
               (overlay (%make-view-shift-overlay world state))
               (shift
                 (make-instance
                  '%view-shift-state
                  :output-state state
                  :anchor-x anchor-x
                  :anchor-y anchor-y
                  :last-time (%now)
                  :overlay overlay)))
          (%set-view-shift-properties shift anchor-x anchor-y)
          (setf (gethash seat (%world-view-shifts world)) shift)))))
  world)

(defun %end-view-shift (world seat)
  (let ((shift (%view-shift-for-seat world seat)))
    (when shift
      (remhash seat (%world-view-shifts world))
      (remove-overlay world (%view-shift-overlay shift))))
  world)

(defun %end-view-shifts-for-output (world state)
  (let ((seats nil))
    (maphash
     (lambda (seat shift)
       (when (eq state (%view-shift-output-state shift))
         (push seat seats)))
     (%world-view-shifts world))
    (dolist (seat seats)
      (%end-view-shift world seat)))
  world)

(defun %end-all-view-shifts (world)
  (dolist (seat (loop for seat being the hash-keys
                        of (%world-view-shifts world) collect seat))
    (%end-view-shift world seat))
  world)

(defun %update-view-shift-modifiers (world seat seat-state input)
  (when (typep input 'ataxia.kernel:modifiers-input)
    (let* ((names (ataxia.kernel:modifiers-input-names input))
           (active-p (and (member :shift names) (member :logo names))))
      (if active-p
          (%begin-view-shift world seat seat-state)
          (%end-view-shift world seat))))
  world)

(defun %advance-view-shifts (world timestamp)
  (let ((stale-seats nil))
    (maphash
     (lambda (seat shift)
       (let ((seat-state (gethash seat (%world-seats world))))
         (if (or (null seat-state)
                 (not (eq (%canvas-seat-output seat-state)
                          (%view-shift-output-state shift))))
             (push seat stale-seats)
             (let* ((state (%view-shift-output-state shift))
                    (delta-x
                      (- (%canvas-seat-x seat-state)
                         (%view-shift-anchor-x shift)))
                    (delta-y
                      (- (%canvas-seat-y seat-state)
                         (%view-shift-anchor-y shift)))
                    (distance (sqrt (+ (* delta-x delta-x)
                                       (* delta-y delta-y))))
                    (elapsed
                      (max 0d0
                           (min 0.05d0
                                (- timestamp (%view-shift-last-time shift)))))
                    (outside (max 0d0 (- distance +view-shift-dead-zone+))))
               (setf (%view-shift-last-time shift) timestamp)
               (if (and (plusp outside) (plusp elapsed))
                   (let* ((strength
                            (min 1d0 (/ outside +view-shift-ramp-distance+)))
                          (speed
                            (* +view-shift-max-speed+
                               (expt strength 1.35d0)))
                     (world-distance
                            (/ (* speed elapsed)
                               (%canvas-output-zoom state))))
                     (multiple-value-bind (canvas-x canvas-y)
                         (%screen-vector-to-canvas state delta-x delta-y)
                       (incf (%canvas-output-camera-x state)
                             (* world-distance (/ canvas-x distance)))
                       (incf (%canvas-output-camera-y state)
                             (* world-distance (/ canvas-y distance))))
                     (%full-damage world state)
                     (%update-all-membership world))
                   (%request-output-state-frame world state))))))
     (%world-view-shifts world))
    (dolist (seat stale-seats)
      (%end-view-shift world seat)))
  world)
