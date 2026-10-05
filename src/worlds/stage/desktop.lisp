;;;; Shell overlays and the shared desktop protocol.
;;;;
;;;; Stage hosts shell overlays (status bar, assistant, widgets) in output
;;;; pixels above the director's scene and below cursors, and answers the
;;;; desktop protocol that computer use and the assistant consume. Layout stays
;;;; with the director: window actions reach a window's node as the request
;;;; events its own client could send, work areas are reported with outputs,
;;;; and viewport navigation moves the compositor-owned cameras.

(in-package #:ataxia.stage-world)

;;; Overlays.

(defmethod ataxia.world:world-outputs ((world stage-world))
  (mapcar #'stage-output-output (%outputs world)))

(defun %overlay-stage-output (world overlay)
  (%find-stage-output world (ataxia.world:overlay-output overlay)))

(defun %overlay-shown-p (overlay stage-output)
  (and (ataxia.world:overlay-visible-p overlay)
       (plusp (ataxia.world:overlay-opacity overlay))
       (eq (ataxia.world:overlay-output overlay) (stage-output-output stage-output))))

(defun %overlay-affine (overlay)
  "Map OVERLAY's component-local space to its output's logical pixels."
  (multiple-value-bind (x y width height)
      (ataxia.kernel:drawable-local-bounds (ataxia.world:overlay-component overlay))
    (let ((scale-x (/ (ataxia.world:overlay-width overlay) (max 1d-6 width)))
          (scale-y (/ (ataxia.world:overlay-height overlay) (max 1d-6 height))))
      (make-affine scale-x 0 0 scale-y
                   (- (ataxia.world:overlay-x overlay) (* scale-x x))
                   (- (ataxia.world:overlay-y overlay) (* scale-y y))))))

(defun %damage-overlay-local (world overlay rectangles)
  "Damage component-local RECTANGLES of OVERLAY, or its whole box when NIL."
  (let ((stage-output (%overlay-stage-output world overlay)))
    (when stage-output
      (let ((transform (affine-multiply (%buffer-transform stage-output) (%overlay-affine overlay))))
        (ataxia.world:damage-add-region
         (%damage world) (stage-output-output stage-output)
         (if rectangles
             (mapcar (lambda (rectangle)
                       (affine-rectangle-bounds transform
                                                          (ataxia.world:rectangle-x rectangle)
                                                          (ataxia.world:rectangle-y rectangle)
                                                          (ataxia.world:rectangle-width rectangle)
                                                          (ataxia.world:rectangle-height rectangle) 1))
                     rectangles)
             (multiple-value-bind (x y width height)
                 (ataxia.kernel:drawable-local-bounds (ataxia.world:overlay-component overlay))
               (list (affine-rectangle-bounds transform x y width height 1)))))
        (%request-frames world (list stage-output))))))

(defmethod ataxia.world:damage-overlay ((world stage-world) overlay)
  (%damage-overlay-local world overlay nil)
  overlay)

(defmethod ataxia.world:request-overlay-update ((world stage-world) overlay)
  (unless (%quiescing-p world)
    (let ((stage-output (%overlay-stage-output world overlay)))
      (when (and stage-output (%overlay-shown-p overlay stage-output))
        (%request-frames world (list stage-output))))
    (%schedule-component-timer world))
  overlay)

(defmethod ataxia.world:add-overlay ((world stage-world) overlay)
  (unless (member overlay (ataxia.world:world-overlays world))
    (setf (ataxia.world:world-overlays world)
          (stable-sort (append (ataxia.world:world-overlays world) (list overlay)) #'<
                       :key #'ataxia.world:overlay-layer))
    (%install-component-timer world)
    (ataxia.world:damage-overlay world overlay)
    (%invalidate-display world)
    (%schedule-component-timer world))
  overlay)

(defun %release-overlay-input (world overlay &key restore-p)
  "Drop pointer and keyboard references to OVERLAY, restoring displaced focus."
  (let ((component (ataxia.world:overlay-component overlay)))
    (%forget-pointer-client world component)
    (dolist (seat-state (%seat-states world))
      (when (eq overlay (stage-seat-focused-panel seat-state))
        (let ((previous (shiftf (stage-seat-previous-focus seat-state) nil)))
          (focus-panel world seat-state
                       (and restore-p previous (not (stage-window-p previous))
                            (not (eq previous overlay)) previous))
          (when (and restore-p (stage-window-p previous) (%window-presentable-p previous))
            (%focus-window world seat-state previous)))))
    (%invalidate-display world)))

(defmethod ataxia.world:remove-overlay ((world stage-world) overlay)
  (when (member overlay (ataxia.world:world-overlays world))
    (ataxia.world:damage-overlay world overlay)
    (%release-overlay-input world overlay :restore-p t)
    (setf (ataxia.world:world-overlays world) (remove overlay (ataxia.world:world-overlays world)))
    ;; Graphics are retired inside the next frame, where GL is current.
    (pushnew overlay (%retired-overlays world))
    (%request-frames world)
    (%schedule-component-timer world))
  overlay)

(defmethod ataxia.world:show-overlay ((world stage-world) overlay)
  (unless (member overlay (ataxia.world:world-overlays world))
    (error "Overlay does not belong to this World."))
  (unless (ataxia.world:overlay-visible-p overlay)
    (setf (ataxia.world:overlay-visible-p overlay) t)
    (ataxia.world:overlay-visibility-changed overlay t)
    (ataxia.world:damage-overlay world overlay)
    (%invalidate-display world)
    (%schedule-component-timer world))
  overlay)

(defmethod ataxia.world:hide-overlay ((world stage-world) overlay)
  (when (ataxia.world:overlay-visible-p overlay)
    (ataxia.world:damage-overlay world overlay)
    (setf (ataxia.world:overlay-visible-p overlay) nil)
    (ataxia.world:overlay-visibility-changed overlay nil)
    (%release-overlay-input world overlay :restore-p t)
    (%schedule-component-timer world))
  overlay)

(defun reap-retired-overlays (world)
  "Destroy removed overlays' graphics; call where GL is current."
  (mapc #'ataxia.world:destroy-overlay (%retired-overlays world))
  (setf (%retired-overlays world) nil))

(defun detach-overlay-graphics (world)
  (reap-retired-overlays world)
  (dolist (overlay (ataxia.world:world-overlays world))
    (ataxia.kernel:drawable-detach-graphics (ataxia.world:overlay-component overlay))))

(defun %updatable-overlays (world)
  (remove-if-not (lambda (overlay)
                   (let ((stage-output (%overlay-stage-output world overlay)))
                     (and stage-output (%overlay-shown-p overlay stage-output))))
                 (ataxia.world:world-overlays world)))

(defun %service-ui-engines (world)
  "Let UI engines run their work and deliver callbacks, even without a repaint."
  (let ((overlays (%updatable-overlays world))
        (serviced nil))
    (dolist (overlay overlays)
      (let* ((component (ataxia.world:overlay-component overlay))
             (key (ataxia.world:ui-service-key component)))
        (when (and key (not (member key serviced)))
          (push key serviced)
          (ataxia.world:ui-service component))))
    (dolist (overlay overlays)
      (ataxia.world:ui-dispatch-callbacks (ataxia.world:overlay-component overlay)))))

(defun %schedule-component-timer (world)
  "Wake for the earliest UI engine deadline; components due now pace with frames."
  (let ((timer (%component-timer world))
        (deadline nil))
    (when timer
      (dolist (overlay (%updatable-overlays world))
        (let* ((component (ataxia.world:overlay-component overlay))
               (delay (ataxia.world:ui-next-update-delay component)))
          (when (or (ataxia.kernel:drawable-active-p component) (and delay (zerop delay)))
            (%request-frames world (list (%overlay-stage-output world overlay))))
          (when (and delay (plusp delay))
            (setf deadline (if deadline (min deadline delay) delay)))))
      (ataxia.runtime:update-event-loop-timer
       timer (if deadline (max 1 (min (ceiling deadline) 86400000)) 0))))
  world)

(defun %install-component-timer (world)
  (unless (%component-timer world)
    (setf (%component-timer world)
          (ataxia.runtime:add-event-loop-timer
           (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
           (%guarded world :ui-timer
                     (lambda (source)
                       (declare (ignore source))
                       (%service-ui-engines world)
                       (%schedule-component-timer world)))))))

(defun stop-component-timer (world)
  (when (%component-timer world)
    (ataxia.runtime:remove-event-loop-source (%component-timer world))
    (setf (%component-timer world) nil)))

(defun prepare-overlays (world stage-output)
  "Service UI engines and upload overlay frames for STAGE-OUTPUT, damaging what changed."
  (reap-retired-overlays world)
  (%service-ui-engines world)
  (dolist (overlay (ataxia.world:world-overlays world))
    (when (%overlay-shown-p overlay stage-output)
      (let* ((component (ataxia.world:overlay-component overlay))
             (current (ataxia.world:ui-raster-scale component)))
        ;; Screen-space overlays raster at exactly the output's scale.
        (when current
          (multiple-value-bind (x y width height) (ataxia.kernel:drawable-local-bounds component)
            (declare (ignore x y))
            (let ((wanted (* (ataxia.kernel:output-scale (stage-output-output stage-output))
                             (/ (ataxia.world:overlay-width overlay) (max 1d-6 width)))))
              (unless (< (abs (- wanted current)) 1d-3)
                (ataxia.world:ui-resize component width height :scale wanted)
                (%invalidate-display world)
                (ataxia.world:damage-overlay world overlay)))))
        (multiple-value-bind (damage active-p) (ataxia.kernel:drawable-prepare-frame component)
          (when damage
            (%invalidate-display world)
            (%damage-overlay-local world overlay damage))
          (when active-p (%request-frames world (list stage-output)))))))
  (%schedule-component-timer world))

(defun emit-overlays (context)
  "Emit the overlays shown on CONTEXT's output, above the scene."
  (let ((stage-output (display-context-stage-output context)))
    (dolist (overlay (ataxia.world:world-overlays (display-context-world context)))
      (when (%overlay-shown-p overlay stage-output)
        (let* ((component (ataxia.world:overlay-component overlay))
               (affine (%overlay-affine overlay))
               (transform (affine-multiply (display-context-screen context) affine))
               (opacity (ataxia.world:overlay-opacity overlay)))
          (loop for surface across (ataxia.kernel:drawable-surfaces component)
                for index from 0
                do (let ((surface surface)
                         (x (ataxia.kernel:drawable-surface-local-x surface))
                         (y (ataxia.kernel:drawable-surface-local-y surface))
                         (width (ataxia.kernel:drawable-surface-width surface))
                         (height (ataxia.kernel:drawable-surface-height surface)))
                     (%emit context (list overlay index)
                            (affine-rectangle-bounds transform x y width height 1)
                            (list transform x y width height opacity
                                  (ataxia.kernel:drawable-surface-texture-coordinates surface))
                            (lambda (renderer)
                              (draw-stage-surface renderer transform surface x y width height
                                                  0 0 0d0 opacity))
                            :token (ataxia.kernel:drawable-surface-presentation-token surface)
                            :callback-p (ataxia.kernel:drawable-surface-frame-callback-p surface))))
          (when (and (typep component 'ataxia.kernel:interactable)
                     (ataxia.world:overlay-input-enabled-p overlay))
            (multiple-value-bind (x y width height) (ataxia.kernel:drawable-local-bounds component)
              (let ((inverse (affine-invert affine)))
                (when inverse
                  (push (%make-hit :inverse inverse :width width :height height
                                   :client component :overlay overlay
                                   :content +identity-affine+
                                   :content-bounds (ataxia.world:make-rectangle x y width height))
                        (display-context-hits context)))))))))))

;;; Reservations: screen space the director keeps for UI it draws itself, such
;;; as a bar. They join shell services' reservations in each output's work area,
;;; which windows' layouts and the director's `workArea` leave free.

(defstruct (stage-reservations (:constructor %make-stage-reservations))
  ;; (OUTPUT-NAME-OR-NIL LEFT TOP RIGHT BOTTOM) per <Reserve> node.
  (entries nil :type list))

(defmethod ataxia.world:service-output-insets ((service stage-reservations) world output)
  (declare (ignore world))
  (let ((left 0d0) (top 0d0) (right 0d0) (bottom 0d0))
    (loop for (name l u r b) in (stage-reservations-entries service)
          when (or (null name) (equal name (ataxia.kernel:output-name output)))
            do (setf left (max left l) top (max top u) right (max right r) bottom (max bottom b)))
    (values left top right bottom)))

(defun update-reservations (world nodes)
  "Adopt the reservations NODES declare, refitting work areas when they change."
  (let ((service (ataxia.world:world-service world :stage-reservations))
        (entries (mapcar (lambda (node)
                           (list* (node-prop node :output)
                                  (mapcar (lambda (key) (max 0d0 (min 4096d0 (node-prop node key))))
                                          '(:left :top :right :bottom))))
                         nodes)))
    (when (and service (not (equal entries (stage-reservations-entries service))))
      (setf (stage-reservations-entries service) entries)
      (dolist (stage-output (%outputs world))
        (ataxia.world:world-output-work-area-changed world (stage-output-output stage-output))))))

;;; Desktop protocol.

;; Workspaces are the director's own idea, so shell navigation is not offered.
(defmethod ataxia.world:world-supports-p ((world stage-world) capability)
  (not (null (member capability '(:ui :desktop :window-capture :viewport-navigation :launcher)))))

(defmethod ataxia.world:window-application ((window stage-window))
  (stage-window-application window))

(defmethod ataxia.world:world-windows ((world stage-world))
  "Windows bottom to top: in the director scene's paint order, then the rest."
  (let ((ordered nil))
    (map-scene-nodes (lambda (node)
                       (when (eq (stage-node-kind node) :window)
                         (let ((window (gethash (node-prop node :window) (%windows-by-id world))))
                           (when window (pushnew window ordered)))))
                     (%scene world))
    (setf ordered (nreverse ordered))
    (append ordered
            (sort (loop for window being the hash-values of (%windows world)
                        unless (member window ordered) collect window)
                  #'< :key #'stage-window-id))))

(defun %own-window-p (world window)
  (and (stage-window-p window)
       (eq window (gethash (stage-window-application window) (%windows world)))))

(defun %window-logical-transform (window stage-output)
  "Map WINDOW's content to STAGE-OUTPUT's logical pixels as last presented, or NIL."
  (let ((transform (first (gethash window (stage-output-window-transforms stage-output))))
        (to-logical (affine-invert (%buffer-transform stage-output))))
    (and transform to-logical (affine-multiply to-logical transform))))

(defun %require-placement (world window output)
  (let ((stage-output (%find-stage-output world output)))
    (or (and stage-output (%own-window-p world window)
             (%window-logical-transform window stage-output))
        (error "The window is not shown on output ~A." (ataxia.kernel:output-name output)))))

(defmethod ataxia.world:world-window-visible-p ((world stage-world) window &optional output)
  (and (%own-window-p world window)
       (%window-presentable-p window)
       (some (lambda (stage-output)
               (and (or (null output) (eq output (stage-output-output stage-output)))
                    (gethash window (stage-output-window-transforms stage-output))))
             (%outputs world))
       t))

(defmethod ataxia.world:window-output-bounds ((world stage-world) window output)
  (let ((transform (%require-placement world window output)))
    (multiple-value-bind (x y width height) (%window-bounds window)
      (let ((bounds (affine-rectangle-bounds transform x y width height)))
        (values (ataxia.world:rectangle-x bounds) (ataxia.world:rectangle-y bounds)
                (ataxia.world:rectangle-width bounds) (ataxia.world:rectangle-height bounds))))))

(defmethod ataxia.world:window-local-to-output ((world stage-world) window output x y)
  (affine-apply (%require-placement world window output) x y))

(defmethod ataxia.world:output-to-window-local ((world stage-world) window output x y)
  (let ((inverse (affine-invert (%require-placement world window output))))
    (if inverse (affine-apply inverse x y) (values x y))))

(defmethod ataxia.world:world-target-at ((world stage-world) output x y)
  (let ((stage-output (%find-stage-output world output)))
    (when stage-output
      (let ((hit (find-if (lambda (hit) (and (hit-client hit) (%hit-accepts-p world hit x y)))
                          (output-hits world stage-output))))
        (and hit (or (hit-window hit) (hit-overlay hit)))))))

(defun %seat-state (world seat)
  (or (gethash seat (%seats world)) (error "Seat ~A does not belong to this World." seat)))

(defmethod ataxia.world:world-seats ((world stage-world))
  (mapcar #'stage-seat-seat (%seat-states world)))

(defmethod ataxia.world:world-seat-output ((world stage-world) seat)
  (let* ((seat-state (gethash seat (%seats world)))
         (stage-output (and seat-state (%seat-output world seat-state))))
    (and stage-output (stage-output-output stage-output))))

(defmethod ataxia.world:world-seat-focus ((world stage-world) seat)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (let ((panel (stage-seat-focused-panel seat-state)))
        (if (typep panel 'ataxia.world:ui-overlay) panel (stage-seat-focused seat-state))))))

(defmethod ataxia.world:world-seat-previous-focus ((world stage-world) seat)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (or (stage-seat-previous-focus seat-state) (first (stage-seat-history seat-state))))))

(defmethod ataxia.world:focus-world-target ((world stage-world) seat target &key remember)
  (let ((seat-state (%seat-state world seat)))
    (when (and remember (not (eq target (ataxia.world:world-seat-focus world seat))))
      (setf (stage-seat-previous-focus seat-state) (ataxia.world:world-seat-focus world seat)))
    (etypecase target
      (null (focus-panel world seat-state nil))
      (stage-window
       (unless (%own-window-p world target) (error "The window does not belong to this World."))
       (%focus-window world seat-state target))
      (ataxia.world:ui-overlay (focus-panel world seat-state target)))
    target))

(defmethod ataxia.world:world-pointer-position ((world stage-world) seat)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (multiple-value-bind (stage-output x y) (%seat-screen-point world seat-state)
        (when stage-output (values x y))))))

(defmethod ataxia.world:world-active-operation-p ((world stage-world))
  (some (lambda (seat-state)
          (and (not (ataxia.world:agent-seat-p (stage-seat-seat seat-state)))
               (or (stage-seat-manipulation seat-state) (stage-seat-gesture-manipulation seat-state)
                   (stage-seat-capture seat-state))))
        (%seat-states world)))

(defmethod ataxia.world:world-output-work-area-changed ((world stage-world) output)
  (let ((stage-output (%find-stage-output world output)))
    (when stage-output
      (%send world (list :type "output" :output (%output-description world stage-output)))
      (%full-damage world))))

(defmethod ataxia.world:present-agent-cursor ((world stage-world) seat output x y tint)
  (declare (ignore tint))
  (let ((seat-state (%seat-state world seat))
        (stage-output (%find-stage-output world output)))
    (when stage-output
      (setf (stage-seat-x seat-state) (+ (stage-output-offset stage-output) x)
            (stage-seat-y seat-state) (coerce y 'double-float))
      (%damage-cursor world seat-state))))

(defmethod ataxia.world:request-world-capture ((world stage-world) output)
  (let ((stage-output (%find-stage-output world output)))
    (when stage-output
      (ataxia.world:damage-full-output (%damage world) output)
      (%request-frames world (list stage-output)))))

(defmethod ataxia.world:capture-window-pixels ((world stage-world) window bounds width height pixels)
  (unless (%renderer world) (error "Stage World has no graphics to capture with."))
  (let ((target (make-render-target width height)))
    (unwind-protect (read-window-pixels world window bounds width height pixels target)
      (destroy-render-target target))))

(defparameter +window-actions+
  '((:minimize . :minimizerequest) (:maximize . :maximizerequest) (:fullscreen . :fullscreenrequest))
  "Window actions and the client request event the director handles for each.")

(defmethod ataxia.world:control-world-window ((world stage-world) window action output)
  (declare (ignore output))
  (unless (%own-window-p world window) (error "The window does not belong to this World."))
  (let ((application (stage-window-application window))
        (node (%primary-node window)))
    (flet ((request (event value)
             (unless (and node (node-handles-p node event))
               (error "The Stage director does not handle ~(~A~) for this window." event))
             (%emit-event world node event :value (if value t :false))))
      (case action
        (:close (ataxia.kernel:request-object-state application world :close t))
        (:restore
         (dolist (event '(:fullscreenrequest :maximizerequest :minimizerequest))
           (when (and node (node-handles-p node event)) (request event nil))))
        (otherwise
         (let ((entry (assoc action +window-actions+)))
           (unless entry (error "Unknown window action ~S." action))
           (request (cdr entry) t)))))))

(defun %window-world-bounds (window stage-output)
  "WINDOW's presented box in world coordinates through STAGE-OUTPUT's camera."
  (let* ((placement (%window-logical-transform window stage-output))
         (to-world (affine-invert (camera-transform stage-output))))
    (unless (and placement to-world)
      (error "The window is not shown on output ~A." (%output-name stage-output)))
    (multiple-value-bind (x y width height) (%window-bounds window)
      (affine-rectangle-bounds (affine-multiply to-world placement) x y width height))))

(defmethod ataxia.world:navigate-world-viewport
    ((world stage-world) output action &key x y dx dy zoom rotation width height window padding)
  (let* ((stage-output (or (%find-stage-output world output) (error "Unknown output.")))
         (camera (stage-output-camera stage-output)))
    (flet ((frame (rectangle)
             (multiple-value-bind (view-width view-height) (%camera-viewport stage-output)
               (let ((margin (* 2 (or padding 48d0))))
                 (camera-move stage-output
                              :x (+ (ataxia.world:rectangle-x rectangle)
                                    (/ (ataxia.world:rectangle-width rectangle) 2))
                              :y (+ (ataxia.world:rectangle-y rectangle)
                                    (/ (ataxia.world:rectangle-height rectangle) 2))
                              :zoom (min (/ (max 1d0 (- view-width margin))
                                            (max 1d0 (ataxia.world:rectangle-width rectangle)))
                                         (/ (max 1d0 (- view-height margin))
                                            (max 1d0 (ataxia.world:rectangle-height rectangle)))))))))
      (ecase action
        (:set (camera-move stage-output :x x :y y :zoom zoom :rotation rotation))
        (:pan (camera-move stage-output
                           :x (+ (channel-target (stage-camera-x camera)) (or dx 0d0))
                           :y (+ (channel-target (stage-camera-y camera)) (or dy 0d0))))
        (:frame-window
         (let ((target (find window (ataxia.world:world-windows world) :key #'stage-window-id)))
           (unless target (error "Unknown window ~S." window))
           (frame (%window-world-bounds target stage-output))))
        (:frame-region
         (unless (and x y width height) (error "Framing a region needs x, y, width and height."))
         (frame (ataxia.world:make-rectangle x y width height))))
      (%report-cameras world)
      (%request-frames world (list stage-output))
      t)))

(defmethod ataxia.world:world-desktop-state ((world stage-world))
  (let ((state (call-next-method)))
    (setf (getf state :coordinate-space) "world"
          (getf state :cameras)
          (map 'vector (lambda (stage-output)
                         (let ((camera (stage-output-camera stage-output)))
                           (list :output (%output-name stage-output)
                                 :x (channel-value (stage-camera-x camera))
                                 :y (channel-value (stage-camera-y camera))
                                 :zoom (camera-zoom camera)
                                 :rotation (channel-value (stage-camera-rotation camera)))))
               (%outputs world)))
    state))
