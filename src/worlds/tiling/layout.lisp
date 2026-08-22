;;;; Master-stack layout computation.
;;;;
;;;; Placements are derived for every output. Existing rectangles are captured
;;;; before each recomputation so geometry changes can interpolate smoothly.

(in-package #:ataxia.tiling-world)

(defparameter *outer-gap* 10d0)
(defparameter *inner-gap* 8d0)

(defun %now ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defun %layout-progress (layout timestamp)
  (if (%tiling-layout-previous layout)
      (max 0d0
           (min 1d0
                (/ (- timestamp (%tiling-layout-transition-start layout))
                   (%tiling-layout-transition-duration layout))))
      1d0))

(defun %spring-progress (progress)
  (cond
    ((not (plusp progress)) 0d0)
    ((>= progress 1d0) 1d0)
    (t (- 1d0 (* (exp (* -7d0 progress))
                   (cos (* 10d0 progress)))))))

(defun %tile-geometry (world node &optional (timestamp (%now)))
  (let* ((layout (%world-layout world))
         (target (gethash node (%tiling-layout-placements layout))))
    (when target
      (let ((previous
              (and (%tiling-layout-previous layout)
                   (gethash node (%tiling-layout-previous layout)))))
        (if previous
            (let ((progress (%spring-progress
                             (%layout-progress layout timestamp))))
              (flet ((blend (old new) (+ old (* (- new old) progress))))
                (values
                 (blend (%tile-rectangle-x previous) (%tile-rectangle-x target))
                 (blend (%tile-rectangle-y previous) (%tile-rectangle-y target))
                 (blend (%tile-rectangle-width previous) (%tile-rectangle-width target))
                 (blend (%tile-rectangle-height previous) (%tile-rectangle-height target)))))
            (values (%tile-rectangle-x target) (%tile-rectangle-y target)
                    (%tile-rectangle-width target) (%tile-rectangle-height target)))))))

(defun %tile-visual-geometry (world node &optional (timestamp (%now)))
  (multiple-value-bind (x y width height) (%tile-geometry world node timestamp)
    (when x
      (let* ((lift (%tile-elevation node))
             (scale (* (%tile-scale node) (+ 1d0 (* 0.026d0 lift))))
             (visual-width (* width scale))
             (visual-height (* height scale)))
        (values (- (+ x (/ width 2d0)) (/ visual-width 2d0))
                (- (+ y (/ height 2d0)) (/ visual-height 2d0)
                   (* 7d0 lift))
                visual-width visual-height)))))

(defun %capture-layout (world timestamp)
  (let ((captured (make-hash-table :test #'eq)))
    (dolist (node (%world-nodes world))
      (multiple-value-bind (x y width height) (%tile-geometry world node timestamp)
        (when x
          (setf (gethash node captured)
                (%make-tile-rectangle x y width height)))))
    (and (plusp (hash-table-count captured)) captured)))

(defun %place-output-nodes (world state placements)
  (let ((nodes (%presented-output-nodes world state)))
    (multiple-value-bind (logical-width logical-height) (%output-logical-size state)
      (cond
        ((null nodes) nil)
        ((%tile-fullscreen-p (first nodes))
         (setf (gethash (first nodes) placements)
               (%make-tile-rectangle 0d0 0d0 logical-width logical-height)))
        ((null (rest nodes))
         (setf (gethash (first nodes) placements)
               (%make-tile-rectangle
                *outer-gap* *outer-gap*
                (max 1d0 (- logical-width (* 2d0 *outer-gap*)))
                (max 1d0 (- logical-height (* 2d0 *outer-gap*))))))
        (t
         (let* ((usable-width
                  (max 2d0 (- logical-width (* 2d0 *outer-gap*) *inner-gap*)))
                (usable-height
                  (max 1d0 (- logical-height (* 2d0 *outer-gap*))))
                (master-width
                  (max 1d0 (* usable-width
                              (%tiling-output-master-ratio state))))
                (stack-width (max 1d0 (- usable-width master-width)))
                (stack (rest nodes))
                (stack-height
                  (max 1d0
                       (/ (- usable-height
                             (* *inner-gap* (1- (length stack))))
                          (length stack)))))
           (setf (gethash (first nodes) placements)
                 (%make-tile-rectangle
                  *outer-gap* *outer-gap* master-width usable-height))
           (loop for node in stack
                 for index from 0
                 for y = (+ *outer-gap* (* index (+ stack-height *inner-gap*)))
                 do (setf (gethash node placements)
                          (%make-tile-rectangle
                           (+ *outer-gap* master-width *inner-gap*) y
                           stack-width stack-height))))))))
  placements)

(defun %configure-node (world node rectangle)
  (let ((component (tile-node-component node)))
    (when (typep component 'ataxia.kernel:wayland-application)
      (let ((width (max 1 (round (%tile-rectangle-width rectangle))))
            (height (max 1 (round (%tile-rectangle-height rectangle)))))
        (ataxia.kernel:request-object-configuration
         component world
         (make-instance
          'ataxia.kernel:toplevel-configuration
          :width width :height height
          :bounds-width width :bounds-height height
          :tiled-edges 15)))))
  node)

(defun %recompute-layout (world &key (animate-p t))
  (let* ((timestamp (%now))
         (layout (%world-layout world))
         (previous (and animate-p (%capture-layout world timestamp)))
         (placements (make-hash-table :test #'eq)))
    (dolist (state (%output-states world))
      (%place-output-nodes world state placements))
    (setf (%tiling-layout-previous layout) previous
          (%tiling-layout-placements layout) placements
          (%tiling-layout-transition-start layout) timestamp)
    (maphash (lambda (node rectangle) (%configure-node world node rectangle))
             placements)
    (%full-damage-all world)
    (%update-all-membership world)
    (%revalidate-all-pointers world))
  world)

(defun %layout-animation-active-p (world timestamp)
  (and (%tiling-layout-previous (%world-layout world))
       (< (%layout-progress (%world-layout world) timestamp) 1d0)))

(defun %advance-layout-animation (world timestamp)
  (let ((layout (%world-layout world)))
    (when (%tiling-layout-previous layout)
      (if (%layout-animation-active-p world timestamp)
          (progn (%full-damage-all world) (%request-all-frames world))
          (progn
            (setf (%tiling-layout-previous layout) nil)
            (%full-damage-all world)))))
  world)
