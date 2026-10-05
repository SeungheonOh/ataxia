;;;; Explicit output camera navigation, independent of shell/workspace policy.
(in-package #:ataxia.infinite-world)

(defgeneric %desktop-viewport-camera (world state))
(defmethod %desktop-viewport-camera ((world infinite-world) state)
  (list (%canvas-output-camera-x state) (%canvas-output-camera-y state)
        (%canvas-output-zoom state) (%canvas-output-rotation state)))
(defgeneric %desktop-viewport-geometry (world window))
(defmethod %desktop-viewport-geometry ((world infinite-world) window)
  (list (canvas-window-x window) (canvas-window-y window)
        (canvas-window-width window) (canvas-window-height window)))
(defgeneric %apply-desktop-viewport (world state camera))
(defmethod %apply-desktop-viewport ((world infinite-world) state camera)
  (ataxia.world:cancel-animation (%world-animator world) state :touchpad-pan)
  (destructuring-bind (x y zoom rotation) camera
    (setf (%canvas-output-rotation state) rotation
          (%canvas-output-target-rotation state) rotation)
    (set-output-camera world (%canvas-output-output state) x y zoom)))

(defun %viewport-number (value low high name)
  (unless (and (realp value) (<= low value high))
    (error "~A must be a finite number between ~A and ~A." name low high))
  (coerce value 'double-float))

(defun %viewport-frame-camera (world state x y width height rotation padding)
  (setf x (%viewport-number x -1d9 1d9 "x")
        y (%viewport-number y -1d9 1d9 "y")
        width (%viewport-number width 1d-6 1d9 "width")
        height (%viewport-number height 1d-6 1d9 "height")
        padding (%viewport-number padding 0d0 10000d0 "padding"))
  (multiple-value-bind (work-x work-y work-width work-height) (%canvas-work-area world state)
    (multiple-value-bind (output-width output-height) (%output-logical-size state)
      (let* ((available-width (- work-width (* 2 padding)))
             (available-height (- work-height (* 2 padding)))
             (cosine (cos rotation)) (sine (sin rotation)))
        (unless (and (plusp available-width) (plusp available-height))
          (error "Padding leaves no viewport work area."))
        (let* ((zoom (min 8d0
                          (/ available-width (+ (* (abs cosine) width) (* (abs sine) height)))
                          (/ available-height (+ (* (abs sine) width) (* (abs cosine) height)))))
               (center-x (/ output-width 2d0)) (center-y (/ output-height 2d0))
               (dx (- (+ work-x (/ work-width 2d0)) center-x))
               (dy (- (+ work-y (/ work-height 2d0)) center-y)))
          (when (< zoom .08d0) (error "Region is too large to fit at the minimum zoom (0.08)."))
          ;; Rotation is about the output center, while framing honors shell reservations.
          (list (- (+ x (/ width 2d0)) (/ (+ center-x (* cosine dx) (* sine dy)) zoom))
                (- (+ y (/ height 2d0)) (/ (+ center-y (- (* sine dx)) (* cosine dy)) zoom))
                zoom rotation))))))

(defmethod ataxia.world:navigate-world-viewport
    ((world infinite-world) output action &key x y dx dy zoom rotation width height window (padding 32d0))
  (let ((state (gethash output (%world-outputs world))))
    (unless state (error "Choose a connected output from the desktop state."))
    (when (ataxia.world:world-active-operation-p world)
      (error "A human is manipulating the World. Observe again after it ends."))
    (destructuring-bind (old-x old-y old-zoom old-rotation) (%desktop-viewport-camera world state)
      (let* ((angle (%viewport-number (or rotation old-rotation) (- (* 2d0 pi)) (* 2d0 pi) "rotation"))
             (camera
               (ecase action
                 (:set
                  (unless (or x y zoom rotation) (error "Supply x, y, zoom or rotation."))
                  (let ((scale (%viewport-number (or zoom old-zoom) .08d0 8d0 "zoom")))
                    (multiple-value-bind (w h) (%output-logical-size state)
                      (list (if x (%viewport-number x -1d9 1d9 "x") (+ old-x (/ w (* 2 old-zoom)) (- (/ w (* 2 scale)))))
                            (if y (%viewport-number y -1d9 1d9 "y") (+ old-y (/ h (* 2 old-zoom)) (- (/ h (* 2 scale)))))
                            scale angle))))
                 (:pan
                  (list (+ old-x (%viewport-number dx -1d9 1d9 "dx"))
                        (+ old-y (%viewport-number dy -1d9 1d9 "dy")) old-zoom old-rotation))
                 (:frame-window
                  (let ((target (and (integerp window) (ataxia.world:find-world-window world window))))
                    (unless (ataxia.world:world-window-visible-p world target)
                      (error "Window is unavailable. Inspect its state; framing does not restore or reveal hidden windows."))
                    (destructuring-bind (wx wy ww wh) (%desktop-viewport-geometry world target)
                      (%viewport-frame-camera world state wx wy ww wh angle padding))))
                 (:frame-region
                  (%viewport-frame-camera world state x y width height angle padding)))))
        ;; Validate the completed camera before cancelling motion or changing view state.
        (%viewport-number (first camera) -1d9 1d9 "camera x")
        (%viewport-number (second camera) -1d9 1d9 "camera y")
        (%apply-desktop-viewport world state camera)
        output))))
