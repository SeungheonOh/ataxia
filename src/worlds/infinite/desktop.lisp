;;;; Adapter from shared desktop services to Infinite World's scene policy.
(in-package #:ataxia.infinite-world)

(defmethod ataxia.world:world-supports-p ((world infinite-world) capability)
  (not (null (member capability '(:ui :desktop :launcher :viewport-navigation)))))

(defmethod ataxia.world:world-windows ((world infinite-world))
  (%world-stacking world))

(defmethod ataxia.world:world-desktop-state ((world infinite-world))
  (let ((state (call-next-method)))
    (setf (getf state :coordinate-space) "world"
          (getf state :windows)
          (map 'vector (lambda (entry)
                         (let ((window (ataxia.world:find-world-window world (getf entry :id))))
                           (list* :geometry (vector (canvas-window-x window) (canvas-window-y window)
                                                    (canvas-window-width window) (canvas-window-height window))
                                  :minimized (if (%canvas-window-minimized-p window) t :false) entry)))
               (getf state :windows))
          (getf state :outputs)
          (map 'vector (lambda (output)
                         (let ((view (gethash output (%world-outputs world))))
                           (list :id (ataxia.kernel:object-id output) :name (ataxia.kernel:output-name output)
                                 :position (vector (%canvas-output-layout-x view) (%canvas-output-layout-y view))
                                 :size (coerce (multiple-value-list (%output-logical-size view)) 'vector)
                                 :camera (vector (%canvas-output-camera-x view) (%canvas-output-camera-y view)
                                                 (%canvas-output-zoom view) (%canvas-output-rotation view))
                                 :transform (%canvas-output-transform view))))
               (ataxia.world:world-outputs world)))
    state))

(defmethod ataxia.world:world-window-visible-p
    ((world infinite-world) window &optional output)
  (and (typep window 'canvas-window)
       (member window (%world-stacking world))
       (%canvas-window-input-enabled-p window)
       (%window-visible-p window)
       (or (null output)
           (let ((state (gethash output (%world-outputs world))))
             (and state
                  (ataxia.world:region-intersects-p
                   (%window-buffer-coverage state window)
                   (list (ataxia.world:make-rectangle
                          0 0 (%canvas-output-buffer-width state)
                          (%canvas-output-buffer-height state)))))))))

(defmethod ataxia.world:window-output-bounds
    ((world infinite-world) window output)
  (let ((state (gethash output (%world-outputs world))))
    (multiple-value-bind (x y width height) (%window-canvas-geometry state window)
      (let* ((points (loop for (px py) in
                          (list (list x y) (list (+ x width) y)
                                (list x (+ y height)) (list (+ x width) (+ y height)))
                          collect (multiple-value-list (%canvas-to-screen state px py))))
             (left (reduce #'min points :key #'first))
             (top (reduce #'min points :key #'second)))
        (values left top (- (reduce #'max points :key #'first) left)
                (- (reduce #'max points :key #'second) top))))))

(defmethod ataxia.world:window-local-to-output
    ((world infinite-world) window output x y)
  (let ((state (gethash output (%world-outputs world))))
    (multiple-value-bind (rx ry rw rh)
        (ataxia.kernel:drawable-local-bounds (canvas-window-application window))
      (multiple-value-bind (wx wy ww wh) (%window-canvas-geometry state window)
        (%canvas-to-screen state (+ wx (* (/ (- x rx) rw) ww))
                           (+ wy (* (/ (- y ry) rh) wh)))))))

(defmethod ataxia.world:output-to-window-local
    ((world infinite-world) window output x y)
  (%target-local-position (gethash output (%world-outputs world)) window x y))

(defmethod ataxia.world:world-target-at ((world infinite-world) output x y)
  (let ((state (gethash output (%world-outputs world))))
    (when state (%target-at-screen-point world state x y))))

(defmethod ataxia.world:world-seats ((world infinite-world))
  (mapcar #'%canvas-seat-seat (%seat-states world)))

(defmethod ataxia.world:world-seat-output ((world infinite-world) seat)
  (let* ((state (gethash seat (%world-seats world)))
         (output (and state (%canvas-seat-output state))))
    (when output (%canvas-output-output output))))

(defmethod ataxia.world:world-seat-focus ((world infinite-world) seat)
  (let ((state (gethash seat (%world-seats world))))
    (when state (%canvas-seat-focused state))))

(defmethod ataxia.world:world-seat-previous-focus ((world infinite-world) seat)
  (let ((state (gethash seat (%world-seats world))))
    (when state (%canvas-seat-previous-focus state))))

(defmethod ataxia.world:focus-world-target
    ((world infinite-world) seat target &key remember)
  (let ((state (gethash seat (%world-seats world))))
    (unless state (error "Seat does not belong to this World."))
    (when (and remember (not (eq target (%canvas-seat-focused state))))
      (setf (%canvas-seat-previous-focus state) (%canvas-seat-focused state)))
    (%focus-target world state target)))

(defmethod ataxia.world:world-pointer-position ((world infinite-world) seat)
  (let ((state (gethash seat (%world-seats world))))
    (when state (values (%canvas-seat-x state) (%canvas-seat-y state)))))

(defmethod ataxia.world:world-active-operation-p ((world infinite-world))
  (some (lambda (state)
          (and (not (ataxia.world:agent-seat-p (%canvas-seat-seat state)))
               (or (%canvas-seat-operation state)
                   (gethash (%canvas-seat-seat state) (%world-view-shifts world))
                   (gethash state *canvas-gestures*))))
        (%seat-states world)))

(defmethod ataxia.world:world-output-work-area-changed ((world infinite-world) output)
  (let ((state (gethash output (%world-outputs world))))
    (when state (%full-damage world state))))

(defmethod ataxia.world:present-agent-cursor
    ((world infinite-world) seat output x y tint)
  (let ((state (gethash seat (%world-seats world))))
    (when state
      (%damage-cursor world state)
      (setf (%canvas-seat-output state) (gethash output (%world-outputs world))
            (%canvas-seat-x state) x (%canvas-seat-y state) y)
      (if tint (setf (gethash seat *canvas-seat-cursor-tints*) tint)
          (remhash seat *canvas-seat-cursor-tints*))
      (%damage-cursor world state)
      (%request-output-state-frame world (%canvas-seat-output state)))))

(defmethod ataxia.world:request-world-capture ((world infinite-world) output)
  (%full-damage world (gethash output (%world-outputs world))))

(defmethod ataxia.world:control-world-window
    ((world infinite-world) window action output)
  (case action
    (:close (ataxia.kernel:request-object-state (canvas-window-application window) world :close t))
    (:minimize (%set-window-minimized world window t))
    (:restore
     (when (or (%canvas-window-expanded-state window) (%canvas-window-restore-geometry window))
       (%set-window-expanded world window (or (%canvas-window-expanded-state window) :fullscreen) nil nil)
       (ataxia.kernel:request-object-state (canvas-window-application window) world :fullscreen nil)
       (ataxia.kernel:request-object-state (canvas-window-application window) world :maximized nil))
     (%set-window-minimized world window nil))
    ((:maximize :fullscreen)
     (let ((state (or (gethash output (%world-outputs world)) (%first-output-state world))))
       (unless state (error "There is no output to expand this window onto."))
       (%set-window-minimized world window nil)
       (%set-window-expanded world window (if (eq action :maximize) :maximized :fullscreen) t state)))
    (otherwise (error "Unknown window action ~S." action))))

(defmethod ataxia.world:world-application-catalog ((world infinite-world) output)
  (let ((launcher (%launcher-for-output world output)))
    (mapcar (lambda (entry)
              (list :id (%desktop-entry-id entry) :name (%desktop-entry-name entry)
                    :detail (%desktop-entry-detail entry)))
            (and launcher (%launcher-desktop-entries launcher)))))

(defmethod ataxia.world:launch-world-application ((world infinite-world) output id)
  (let* ((launcher (%launcher-for-output world output))
         (entry (find id (and launcher (%launcher-desktop-entries launcher))
                      :key #'%desktop-entry-id :test #'equal)))
    (unless entry (error "Unknown installed application ~S." id))
    (%launch-desktop-entry world entry)
    (%desktop-entry-name entry)))
