;;;; Direct manipulation in the compositor.
;;;;
;;;; Pans, zooms, moves and resizes follow input in the same frame, with no
;;;; director round trip. A manipulated node holds the keys it drives, so
;;;; director commits cannot fight the pointer. The director learns the outcome
;;;; from coalesced progress events and a final event carrying the new values,
;;;; which it should store so its next render declares them.

(in-package #:ataxia.stage-world)

(defparameter +minimum-window-size+ '(120d0 . 80d0))
(defparameter +velocity-window+ 0.1d0
  "Seconds of motion history used to estimate release velocity.")
(defparameter +fling-threshold+ 150d0
  "Screen pixels per second below which a release simply stops.")
(defparameter +fling-limit+ 6000d0)

(defstruct (manipulation (:constructor %make-manipulation))
  (kind :pan :type (member :pan :zoom :move :resize))
  (stage-output nil)
  (node nil)
  (window nil)
  ;; xdg_toplevel resize edges: top 1, bottom 2, left 4, right 8.
  (edges 0 :type integer)
  ;; Node values when the manipulation began: :X :Y :WIDTH :HEIGHT.
  (origin nil :type list)
  ;; Pointer at the start, in the node's parent space.
  (anchor-x 0d0 :type double-float)
  (anchor-y 0d0 :type double-float)
  ;; Previous screen point for pans, or pinch scale for zooms.
  (last-x 0d0 :type double-float)
  (last-y 0d0 :type double-float)
  ;; Recent (TIME X Y) screen samples, newest first.
  (samples nil :type list)
  ;; Binding or node whose press started it, told about the release.
  (source nil))

;;; Coordinates.

(defun %scene-root-of (node)
  (loop for current = node then parent
        for parent = (stage-node-parent current)
        while parent
        finally (return current)))

(defun node-parent-transform (world stage-output node)
  "Map NODE's parent space to STAGE-OUTPUT's logical pixels."
  (let ((transform (if (eq (%scene-root-of node) (scene-root (%scene world)))
                       (camera-transform stage-output)
                       +identity-affine+))
        (ancestors (loop for parent = (stage-node-parent node) then (stage-node-parent parent)
                         while (and parent (stage-node-parent parent))
                         collect parent)))
    (dolist (ancestor (nreverse ancestors) transform)
      (let ((local (%node-local-affine world ancestor)))
        ;; A screen node restarts from output pixels, ignoring the camera.
        (setf transform (if (eq (stage-node-kind ancestor) :screen)
                            local
                            (affine-multiply transform local)))))))

(defun %manipulation-point (seat-state manipulation)
  "The pointer relative to the manipulated output, even after leaving it."
  (values (- (stage-seat-x seat-state)
             (stage-output-offset (manipulation-stage-output manipulation)))
          (stage-seat-y seat-state)))

(defun %parent-point (world stage-output node x y)
  (let ((inverse (affine-invert (node-parent-transform world stage-output node))))
    (if inverse (affine-apply inverse x y) (values x y))))

(defun %record-sample (manipulation x y)
  (let ((now (%now)))
    (setf (manipulation-samples manipulation)
          (cons (list now x y)
                (remove-if (lambda (sample) (> (- now (first sample)) +velocity-window+))
                           (manipulation-samples manipulation))))))

(defun %release-velocity (manipulation)
  "Screen velocity at release, or zero when the input had already stopped."
  (let* ((samples (manipulation-samples manipulation))
         (newest (first samples))
         (oldest (car (last samples)))
         (span (and newest (- (first newest) (first oldest)))))
    (if (or (null newest) (< span 0.01d0) (> (- (%now) (first newest)) 0.05d0))
        (values 0d0 0d0)
        (let* ((vx (/ (- (second newest) (second oldest)) span))
               (vy (/ (- (third newest) (third oldest)) span))
               (speed (sqrt (+ (* vx vx) (* vy vy)))))
          (cond ((< speed +fling-threshold+) (values 0d0 0d0))
                ((> speed +fling-limit+) (values (* vx (/ +fling-limit+ speed))
                                                 (* vy (/ +fling-limit+ speed))))
                (t (values vx vy)))))))

(defun %emit-progress (world node name &rest fields)
  "Send a coalesced progress event; only the latest per node survives a flush."
  (when (node-handles-p node name)
    (%send world (list* :type "event" :node (stage-node-id node)
                        :name (string-downcase (symbol-name name)) fields)
           :coalesce (cons (stage-node-id node) name))))

;;; Targets.

(defun move-target (node)
  "NODE or its nearest ancestor that direct manipulation may move."
  (loop for current = node then (stage-node-parent current)
        while (and current (stage-node-parent current))
        when (if (eq (stage-node-kind current) :window)
                 (node-prop current :movable)
                 (and (member (stage-node-kind current) '(:rect :group :text :image))
                      (node-prop current :draggable)))
          return current))

(defun resize-edges (local-x local-y width height)
  "Resize from the corner nearest to a node-local point, as Hyprland and sway do."
  (logior (if (< local-y (/ height 2d0)) 1 2)
          (if (< local-x (/ width 2d0)) 4 8)))

;;; Pointer manipulations.

(defun begin-pan (world seat-state &optional (stage-output (%seat-output world seat-state)))
  "Start panning STAGE-OUTPUT's camera with the pointer; return the manipulation."
  (when stage-output
    (let ((manipulation (%make-manipulation :kind :pan :stage-output stage-output)))
      (multiple-value-bind (x y) (%manipulation-point seat-state manipulation)
        (setf (manipulation-last-x manipulation) x
              (manipulation-last-y manipulation) y)
        (%record-sample manipulation x y))
      ;; Grabbing a coasting canvas stops it where it is.
      (let ((camera (stage-output-camera stage-output)))
        (dolist (channel (list (stage-camera-x camera) (stage-camera-y camera)))
          (when (channel-active-p channel) (channel-jump channel (channel-value channel)))))
      (setf (stage-seat-manipulation seat-state) manipulation))))

(defun begin-move (world seat-state node)
  "Start moving NODE with the pointer; return the manipulation."
  (let ((stage-output (%seat-output world seat-state)))
    (when stage-output
      (let* ((manipulation (%make-manipulation :kind :move :stage-output stage-output :node node))
             (x (node-number node :x 0d0))
             (y (node-number node :y 0d0)))
        (multiple-value-bind (screen-x screen-y) (%manipulation-point seat-state manipulation)
          (multiple-value-bind (px py) (%parent-point world stage-output node screen-x screen-y)
            (setf (manipulation-anchor-x manipulation) px
                  (manipulation-anchor-y manipulation) py
                  (manipulation-origin manipulation) (list :x x :y y))))
        (setf (stage-node-held node) (union '(:x :y) (stage-node-held node))
              (stage-seat-manipulation seat-state) manipulation)
        (%emit-event world node :dragstart :x x :y y)
        manipulation))))

(defun begin-resize (world seat-state node window edges)
  "Start resizing window NODE from EDGES with the pointer; return the manipulation."
  (let ((stage-output (%seat-output world seat-state)))
    (when stage-output
      (multiple-value-bind (width height) (%node-size world node)
        (let* ((manipulation (%make-manipulation :kind :resize :stage-output stage-output
                                                 :node node :window window :edges edges))
               (x (node-number node :x 0d0))
               (y (node-number node :y 0d0)))
          (multiple-value-bind (screen-x screen-y) (%manipulation-point seat-state manipulation)
            (multiple-value-bind (px py) (%parent-point world stage-output node screen-x screen-y)
              (setf (manipulation-anchor-x manipulation) px
                    (manipulation-anchor-y manipulation) py
                    (manipulation-origin manipulation)
                    (list :x x :y y :width width :height height))))
          (setf (stage-node-held node) (union '(:x :y :width :height) (stage-node-held node))
                (stage-seat-manipulation seat-state) manipulation)
          (ataxia.kernel:request-object-state (stage-window-application window) world :resizing t)
          (%emit-event world node :resizestart :x x :y y :width width :height height)
          manipulation)))))

(defun %update-pan (world seat-state manipulation)
  (multiple-value-bind (x y) (%manipulation-point seat-state manipulation)
    (camera-pan (manipulation-stage-output manipulation)
                (- x (manipulation-last-x manipulation)) (- y (manipulation-last-y manipulation)))
    (setf (manipulation-last-x manipulation) x
          (manipulation-last-y manipulation) y)
    (%record-sample manipulation x y)
    (%report-cameras world)))

(defun %resized-box (manipulation dx dy)
  "New x, y, width and height after dragging the manipulated edges by (DX, DY)."
  (destructuring-bind (&key x y width height) (manipulation-origin manipulation)
    (let ((edges (manipulation-edges manipulation)))
      (flet ((edge (start size delta low-bit high-bit minimum)
               (cond ((logtest edges high-bit)
                      (values start (max minimum (+ size delta))))
                     ((logtest edges low-bit)
                      (let ((new-size (max minimum (- size delta))))
                        (values (+ start (- size new-size)) new-size)))
                     (t (values start size)))))
        (multiple-value-bind (new-x new-width)
            (edge x width dx 4 8 (car +minimum-window-size+))
          (multiple-value-bind (new-y new-height)
              (edge y height dy 1 2 (cdr +minimum-window-size+))
            (values new-x new-y new-width new-height)))))))

(defun %update-node-manipulation (world seat-state manipulation)
  (let ((node (manipulation-node manipulation))
        (scene (%scene world)))
    (multiple-value-bind (screen-x screen-y) (%manipulation-point seat-state manipulation)
      (multiple-value-bind (px py)
          (%parent-point world (manipulation-stage-output manipulation) node screen-x screen-y)
        (let* ((scale (max 1d-6 (node-number node :scale 1d0)))
               (dx (- px (manipulation-anchor-x manipulation)))
               (dy (- py (manipulation-anchor-y manipulation))))
          (if (eq (manipulation-kind manipulation) :move)
              (let ((x (+ (getf (manipulation-origin manipulation) :x) dx))
                    (y (+ (getf (manipulation-origin manipulation) :y) dy)))
                (node-jump scene node :x x)
                (node-jump scene node :y y)
                (%emit-progress world node :drag :x x :y y))
              (multiple-value-bind (x y width height)
                  (%resized-box manipulation (/ dx scale) (/ dy scale))
                (node-jump scene node :x x)
                (node-jump scene node :y y)
                (node-jump scene node :width width)
                (node-jump scene node :height height)
                (%configure-window world (manipulation-window manipulation))
                (%emit-progress world node :resize :x x :y y :width width :height height))))))
    (%scene-changed world)))

(defun update-manipulation (world seat-state)
  (let* ((manipulation (stage-seat-manipulation seat-state))
         (node (manipulation-node manipulation)))
    (cond
      ((eq (manipulation-kind manipulation) :pan) (%update-pan world seat-state manipulation))
      ;; The director removed the node mid-drag; finish without it.
      ((not (eq (stage-node-state node) :live))
       (end-manipulation world seat-state))
      (t (%update-node-manipulation world seat-state manipulation)))))

(defun end-manipulation (world seat-state)
  (let* ((manipulation (shiftf (stage-seat-manipulation seat-state) nil))
         (node (manipulation-node manipulation)))
    (ecase (manipulation-kind manipulation)
      (:pan
       (multiple-value-bind (vx vy) (%release-velocity manipulation)
         (unless (and (zerop vx) (zerop vy))
           (camera-fling (manipulation-stage-output manipulation) vx vy)))
       (%report-cameras world))
      ((:move :resize)
       (setf (stage-node-held node)
             (set-difference (stage-node-held node) '(:x :y :width :height)))
       (when (eq (manipulation-kind manipulation) :resize)
         (let ((application (stage-window-application (manipulation-window manipulation))))
           (when (%live-application-p application)
             (ataxia.kernel:request-object-state application world :resizing nil))))
       (when (eq (stage-node-state node) :live)
         (let ((x (node-number node :x 0d0)) (y (node-number node :y 0d0)))
           (if (eq (manipulation-kind manipulation) :move)
               (%emit-event world node :dragend :x x :y y)
               (multiple-value-bind (width height) (%node-size world node)
                 (%emit-event world node :resizeend :x x :y y :width width :height height)))))))
    (%scene-changed world)))

;;; Camera input without a pointer grab.

(defun wheel-zoom (world seat-state delta source)
  (multiple-value-bind (stage-output x y) (%seat-screen-point world seat-state)
    (when stage-output
      (camera-zoom-at stage-output (expt 2d0 (- (/ delta 120d0))) x y
                      ;; Notched wheels glide between steps; touchpads track exactly.
                      :motion (if (eq source :wheel) +wheel-zoom-motion+ nil))
      (%report-cameras world)
      (%scene-changed world))))

(defun wheel-pan (world seat-state orientation delta)
  (let ((stage-output (%seat-output world seat-state)))
    (when stage-output
      (if (eq orientation :horizontal)
          (camera-pan stage-output (- delta) 0d0)
          (camera-pan stage-output 0d0 (- delta)))
      (%report-cameras world)
      (%scene-changed world))))

(defun begin-gesture-manipulation (world seat-state action)
  (let ((stage-output (%seat-output world seat-state)))
    (when stage-output
      (let ((manipulation (%make-manipulation :kind (if (eq action :zoom) :zoom :pan)
                                              :stage-output stage-output
                                              ;; Pinch scale is relative to the gesture start.
                                              :last-x 1d0)))
        (%record-sample manipulation 0d0 0d0)
        (setf (stage-seat-gesture-manipulation seat-state) manipulation)))))

(defun update-gesture-manipulation (world seat-state dx dy scale)
  (let* ((manipulation (stage-seat-gesture-manipulation seat-state))
         (stage-output (manipulation-stage-output manipulation)))
    (when (eq (manipulation-kind manipulation) :zoom)
      (multiple-value-bind (x y) (%manipulation-point seat-state manipulation)
        (camera-zoom-at stage-output (/ scale (manipulation-last-x manipulation)) x y))
      (setf (manipulation-last-x manipulation) scale))
    (camera-pan stage-output dx dy)
    (destructuring-bind (time x y) (first (manipulation-samples manipulation))
      (declare (ignore time))
      (%record-sample manipulation (+ x dx) (+ y dy)))
    (%report-cameras world)
    (%scene-changed world)))

(defun end-gesture-manipulation (world seat-state cancelled-p)
  (let ((manipulation (shiftf (stage-seat-gesture-manipulation seat-state) nil)))
    (when (and (eq (manipulation-kind manipulation) :pan) (not cancelled-p))
      (multiple-value-bind (vx vy) (%release-velocity manipulation)
        (unless (and (zerop vx) (zerop vy))
          (camera-fling (manipulation-stage-output manipulation) vx vy))))
    (%report-cameras world)
    (%scene-changed world)))
