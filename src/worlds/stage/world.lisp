;;;; Stage World aggregate and Kernel lifecycle.
;;;;
;;;; The World owns the scene, window records, outputs, seats, damage history
;;;; and renderer. The director link only proposes scene changes; Kernel
;;;; mechanisms are invoked from World code, synchronously on the owner thread.

(in-package #:ataxia.stage-world)

(defstruct (stage-window (:constructor %make-stage-window (application id)))
  (application nil :read-only t)
  (id 0 :type integer :read-only t)
  ;; Live director nodes presenting this window; the first one configures it.
  (nodes nil :type list)
  ;; Placement used while no director scene is active.
  (fallback nil)
  (configured nil)
  (states nil :type list)
  (outputs nil :type list)
  (report nil :type list)
  ;; Last frame with retained render sources, and its local bounds, kept while
  ;; an exit animation may show the window after its client unmapped it.
  (snapshot #() :type vector)
  (snapshot-bounds nil :type list)
  (snapshot-revision nil))

(defstruct (stage-output (:constructor %make-stage-output (output)))
  (output nil :read-only t)
  ;; Outputs form one horizontal row in logical pixels, in arrival order.
  (offset 0d0 :type double-float)
  (buffer-width 1 :type integer)
  (buffer-height 1 :type integer)
  (transform 0 :type integer)
  ;; The scene's display list as (ITEMS PRESENTED ANIMATING-P RASTER-SCALES), its
  ;; hit list, when they were built, and whether they still match the scene.
  ;; Pointer motion over a still scene reuses them and only rebuilds the cursor.
  (display nil :type list)
  (hits nil :type list)
  (built-at 0d0 :type double-float)
  (display-valid-p nil)
  ;; Whether the cached display has been diffed into damage.
  (diffed-p nil)
  ;; Last diffed scene and cursor items: item key -> (damage rectangles . signature),
  ;; and the tables the next diff fills.
  (items (make-hash-table :test #'equal))
  (seat-items (make-hash-table :test #'equal))
  (spare-items (make-hash-table :test #'equal))
  (spare-seat-items (make-hash-table :test #'equal))
  ;; Window or page -> content-to-buffer transforms of its presented nodes.
  (window-transforms (make-hash-table :test #'eq) :read-only t)
  ;; Whether the last frame showed something moving; endless loops wake only these.
  (animating-p nil)
  ;; Whether its display has effects that read the pointer, which cursor motion rebuilds.
  (pointer-effects-p nil)
  ;; Text node id -> exact raster scale on the last rendered frame.
  (raster-scales (make-hash-table :test #'eql))
  (camera (make-stage-camera) :read-only t))

(defstruct (stage-seat (:constructor %make-stage-seat (seat)))
  (seat nil :read-only t)
  ;; Pointer position in layout coordinates.
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  ;; Window hit receiving protocol pointer focus.
  (hovered nil)
  ;; Topmost node under the pointer, for enter/leave events.
  (entered nil)
  ;; Node receiving pointer events until every button is released.
  (capture nil)
  (buttons (make-hash-table :test #'eql) :read-only t)
  (focused nil)
  (history nil :type list)
  (gesture nil)
  ;; Native pan/move/resize driven by the pointer, and pan/zoom by a gesture.
  (manipulation nil)
  (gesture-manipulation nil)
  ;; Held modifier names, as reported by the seat keyboard.
  (modifiers nil :type list)
  ;; The cursor surface the hovered client set, once it set one; NIL hides it.
  (cursor nil)
  (cursor-set-p nil)
  (cursor-x 0 :type integer)
  (cursor-y 0 :type integer)
  ;; Web page or shell overlay holding keyboard focus instead of the focused
  ;; window, the focus to restore when that overlay hides, and the client the
  ;; Kernel last gave keyboard focus.
  (focused-panel nil)
  (previous-focus nil)
  (keyboard-client nil))

;; A web node's page; see web.lisp.
(defstruct (stage-web (:constructor %make-stage-web (source component)))
  ;; The node presenting the page; it changes when a replacement adopts it.
  (node nil)
  (source "" :type string :read-only t)
  (component nil :read-only t)
  (revision nil)
  ;; JSON text last posted as the page's props, and whether the page has loaded.
  (data nil)
  (loaded-p nil)
  ;; Whether an autoFocus node already gave the page the keyboard.
  (auto-focused-p nil)
  ;; Outputs whose last frame showed the node, and its settled scale on each, as a plist.
  (outputs nil :type list)
  (wanted-scales nil :type list))

(defclass stage-world (ataxia.world:ui-host ataxia.kernel:world)
  ((kernel :initform nil :accessor ataxia.kernel:world-kernel)
   (socket-path :initarg :socket-path :initform nil :reader stage-director-socket)
   (screen-sharing-p :initarg :screen-sharing-p :initform nil :reader %screen-sharing-p)
   (scene :reader %scene)
   (fallback :reader %fallback)
   (windows :initform (make-hash-table :test #'eq) :reader %windows)
   (windows-by-id :initform (make-hash-table :test #'eql) :reader %windows-by-id)
   ;; Unregistered windows whose last frame an exiting node still shows.
   (departed :initform (make-hash-table :test #'eql) :reader %departed)
   (outputs :initform nil :accessor %outputs)
   (seats :initform (make-hash-table :test #'eq) :reader %seats)
   (cameras :initform nil :accessor %cameras)
   (bindings :initform nil :accessor %bindings)
   (shortcuts :initform (ataxia.world:make-shortcut-controller)
              :reader ataxia.world:world-shortcut-controller)
   (shortcuts-declared :initform nil :accessor %shortcuts-declared)
   (link :initform nil :accessor %link)
   (damage :initform (ataxia.world:make-damage-tracker) :reader %damage)
   (damage-debug-p :initarg :damage-debug-p :initform nil :accessor %damage-debug-p)
   (renderer :initform nil :accessor %renderer)
   ;; Absolute path -> STAGE-IMAGE, and the worker decoding them.
   (images :initform (make-hash-table :test #'equal) :reader %images)
   (image-loader :initform nil :accessor %image-loader)
   ;; (Shape . pixel size) -> THEME-CURSOR, or NIL where the theme lacks it.
   (cursor-images :initform (make-hash-table :test #'equal) :reader %cursor-images)
   (webs :initform nil :accessor %webs)
   ;; Clipboard transfers in flight.
   (selection-reads :initform nil :accessor %selection-reads)
   ;; Web node -> source whose page could not be created, so it is not retried.
   (failed-pages :initform (make-hash-table :test #'eq :weakness :key) :reader %failed-pages)
   ;; Node -> EFFECT-STATE, for nodes drawn through an effect.
   (effect-states :initform (make-hash-table :test #'eq :weakness :key) :reader %effect-states)
   ;; Shell overlays in layer order, overlays awaiting graphics retirement, and
   ;; the timer servicing UI engines between frames.
   (overlays :initform nil :accessor ataxia.world:world-overlays)
   (retired-overlays :initform nil :accessor %retired-overlays)
   (component-timer :initform nil :accessor %component-timer)
   (advanced-at :initform -1d0 :accessor %advanced-at)
   (quiescing-p :initform nil :accessor %quiescing-p))
  (:documentation
   "World presenting a retained scene declared by an external director process."))

(defun %call-with-gl (world function)
  "Call FUNCTION with WORLD's GL context current, outside a frame; nothing happens without graphics."
  (when (%renderer world)
    (ataxia.runtime:call-with-egl-context
     (ataxia.runtime:runtime-egl (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world)))
     function)))

(defmethod initialize-instance :after ((world stage-world) &key)
  (flet ((natural (node key) (%natural-node-value world node key)))
    (setf (slot-value world 'scene) (make-scene :natural-value #'natural)
          (slot-value world 'fallback) (make-scene :natural-value #'natural))))

(defun make-stage-world (&key socket-path damage-debug-p screen-sharing-p)
  "Create a Stage World listening for its director on SOCKET-PATH. With
SCREEN-SHARING-P it serves the desktop portal's screen sharing while attached."
  (make-instance 'stage-world :socket-path socket-path :damage-debug-p damage-debug-p
                              :screen-sharing-p screen-sharing-p))

(defmethod ataxia.world:damage-debug-mode-p ((world stage-world))
  (%damage-debug-p world))

(defmethod (setf ataxia.world:damage-debug-mode-p) (enabled (world stage-world))
  (setf (%damage-debug-p world) enabled)
  (%full-damage world))

(defun %now () (ataxia.world:monotonic-time))

(defun %guarded (world operation function)
  "An event-loop callback running FUNCTION under the World watchdog, only while WORLD
is the Kernel's current World. Like any World call, a failure faults the World instead
of the compositor."
  (lambda (&rest arguments)
    (let ((kernel (ataxia.kernel:world-kernel world)))
      (when (and kernel (not (%quiescing-p world))
                 (member (ataxia.kernel:kernel-world-status kernel) '(:running :rescue)))
        (ataxia.kernel:call-with-current-world
         kernel (lambda (current) (when (eq current world) (apply function arguments)))
         :operation operation)))
    0))

(defun %seat-states (world)
  (loop for state being the hash-values of (%seats world) collect state))

(defun %find-stage-output (world output)
  (find output (%outputs world) :key #'stage-output-output))

(defun %output-name (stage-output)
  (ataxia.kernel:output-name (stage-output-output stage-output)))

(defun %request-frames (world &optional (outputs (%outputs world)))
  (unless (%quiescing-p world)
    (dolist (stage-output outputs)
      (let ((output (stage-output-output stage-output)))
        (when (and (eq (ataxia.kernel:object-state output) :live)
                   (ataxia.kernel:output-enabled-p output))
          (ataxia.kernel:request-output-frame output)))))
  world)

(defun %full-damage (world)
  (dolist (stage-output (%outputs world))
    (ataxia.world:damage-full-output (%damage world) (stage-output-output stage-output)))
  (%scene-changed world))

(defmethod ataxia.world:refresh-world ((world stage-world))
  (%full-damage world))

(defun %invalidate-display (world)
  "The scene may present differently: rebuild display and hit lists before using them.
Anything releasing a resource that a display item draws must call this too."
  (dolist (stage-output (%outputs world))
    (setf (stage-output-display-valid-p stage-output) nil)))

(defun %scene-changed (world)
  "Presentation may differ anywhere; the next frame's item diff finds where."
  (%invalidate-display world)
  (%request-frames world))

;;; Windows.

(defun %live-application-p (application)
  (eq (ataxia.kernel:object-state application) :live))

(defun %window-presentable-p (window)
  (let ((application (stage-window-application window)))
    (and (%live-application-p application) (ataxia.kernel:application-mapped-p application))))

(defun %window-bounds (window)
  "Local bounds of WINDOW's content, or of its last frame once the client is gone."
  (if (or (%window-presentable-p window) (null (stage-window-snapshot-bounds window)))
      (ataxia.kernel:drawable-local-bounds (stage-window-application window))
      (values-list (stage-window-snapshot-bounds window))))

(defun %window-natural-size (window)
  (multiple-value-bind (x y width height) (%window-bounds window)
    (declare (ignore x y))
    (values (coerce (max 0 width) 'double-float) (coerce (max 0 height) 'double-float))))

(defun %node-window (world node)
  (let ((id (node-prop node :window)))
    (and id (or (gethash id (%windows-by-id world)) (gethash id (%departed world))))))

(defun %natural-node-value (world node key)
  (when (eq (stage-node-kind node) :window)
    (let ((window (%node-window world node)))
      (when window
        (multiple-value-bind (width height) (%window-natural-size window)
          (case key (:width width) (:height height)))))))

(defun %node-size (world node)
  "Displayed local size of a sized node; windows default to their natural size."
  (case (stage-node-kind node)
    ((:rect :group) (values (or (node-number node :width) 0d0) (or (node-number node :height) 0d0)))
    (:window
     (let ((window (%node-window world node)))
       (multiple-value-bind (width height)
           (if window (%window-natural-size window) (values 0d0 0d0))
         (values (or (node-number node :width) width) (or (node-number node :height) height)))))
    (:web (values (or (node-number node :width) 640d0) (or (node-number node :height) 360d0)))
    (:text (text-node-size node))
    (:image (image-node-size world node))
    (otherwise (values 0d0 0d0))))

(defun %window-metadata (window)
  (let ((application (stage-window-application window)))
    (multiple-value-bind (width height) (%window-natural-size window)
      (list :id (stage-window-id window)
            :title (or (ataxia.kernel:application-title application) "")
            :app (or (ataxia.kernel:application-app-id application) "")
            :mapped (if (ataxia.kernel:application-mapped-p application) t :false)
            :width (round width)
            :height (round height)))))

(defun %report-window (world window)
  (let ((metadata (%window-metadata window)))
    (unless (equal metadata (stage-window-report window))
      (setf (stage-window-report window) metadata)
      (%send world (list :type "window" :window metadata)))))

(defun %initialized-p (application)
  (or (not (typep application 'ataxia.kernel:wayland-application))
      (plusp (ataxia.kernel:surface-commit-sequence
              (ataxia.kernel:application-root-surface application)))))

(defun %request-window-state (world window state value)
  (unless (eq (getf (stage-window-states window) state :unset) value)
    (setf (getf (stage-window-states window) state) value)
    (ataxia.kernel:request-object-state (stage-window-application window) world state value)))

(defun %client-extent (value)
  "A configure dimension clients and the protocol accept."
  (max 1 (min 32767 (round value))))

(defun %configure-window (world window)
  "Send the primary node's declared size and states; the client sees targets, not frames."
  (let ((application (stage-window-application window))
        (node (first (stage-window-nodes window))))
    (when (and node (%live-application-p application) (%initialized-p application))
      (let* ((size (let ((width (node-target node :width))
                         (height (node-target node :height)))
                     (and width height (cons (%client-extent width) (%client-extent height)))))
             (tiled (if (node-prop node :tiled) 15 0))
             (sent-tiled (getf (stage-window-states window) :tiled 0))
             ;; Tiled edges need a newer xdg_wm_base; untiled windows never send them.
             (tiled-hint (if (eql tiled sent-tiled) :unchanged tiled)))
        (unless (and (equal size (stage-window-configured window)) (eq tiled-hint :unchanged))
          (setf (stage-window-configured window) size
                (getf (stage-window-states window) :tiled) tiled)
          (ataxia.kernel:request-object-configuration
           application world
           (make-instance 'ataxia.kernel:toplevel-configuration
                          :width (if size (car size) :unchanged)
                          :height (if size (cdr size) :unchanged)
                          :tiled-edges tiled-hint)))
        (%request-window-state world window :fullscreen (node-prop node :fullscreen))
        (%request-window-state world window :maximized (node-prop node :maximized)))))
  window)

(defun %set-window-membership (window outputs)
  (let ((application (stage-window-application window)))
    (when (%live-application-p application)
      (setf (stage-window-outputs window) outputs)
      (loop for surface across (ataxia.kernel:drawable-surfaces application)
            for token = (ataxia.kernel:drawable-surface-presentation-token surface)
            when token do (ataxia.kernel:set-wayland-surface-output-membership token outputs)))))

(defun %sync-fallback (world)
  "Cascade windows on the first output while no director scene presents them."
  (let ((fallback (%fallback world))
        (index 0)
        (time (%now)))
    (dolist (window (sort (loop for window being the hash-values of (%windows world)
                                collect window)
                          #'< :key #'stage-window-id))
      (let ((wanted (and (not (%director-scene-active-p world))
                         (null (stage-window-nodes window))
                         (ataxia.kernel:application-mapped-p (stage-window-application window))))
            (node (stage-window-fallback window)))
        (cond
          ((and wanted (null node))
           (let ((props (make-hash-table :test #'equal))
                 (offset (+ 48 (* 32 (mod index 8)))))
             (setf (gethash "window" props) (stage-window-id window)
                   (gethash "x" props) offset
                   (gethash "y" props) offset
                   (gethash "originX" props) 0
                   (gethash "originY" props) 0)
             (setf node (scene-create fallback (stage-window-id window) "window" props time)
                   (stage-window-fallback window) node)
             (scene-insert fallback 0 (stage-node-id node) nil)))
          ((and (not wanted) node)
           (scene-remove fallback 0 (stage-node-id node))
           (setf (stage-window-fallback window) nil)))
        (when wanted (incf index))))
    (scene-finish-commit fallback time)))

(defun %reindex (world)
  "Rebuild World indexes after the director scene changed."
  (let ((cameras nil) (bindings nil) (shortcuts nil) (media nil) (webs nil) (reserves nil))
    (loop for window being the hash-values of (%windows world)
          do (setf (stage-window-nodes window) nil))
    (map-scene-nodes
     (lambda (node)
       (case (stage-node-kind node)
         (:window
          (let ((window (%node-window world node)))
            (when window (push node (stage-window-nodes window)))))
         (:camera (push node cameras))
         (:reserve (push node reserves))
         (:shortcut (push node shortcuts))
         ((:pointer-binding :wheel-binding :gesture-binding) (push node bindings))
         ((:text :image) (push node media))
         (:web (push node webs))))
     (%scene world))
    (loop for window being the hash-values of (%windows world)
          do (setf (stage-window-nodes window)
                   (sort (stage-window-nodes window) #'< :key #'stage-node-id)))
    (setf (%cameras world) (nreverse cameras)
          (%bindings world) (nreverse bindings))
    (%install-shortcuts world (nreverse shortcuts))
    (dolist (stage-output (%outputs world))
      (let ((node (%find-camera world (%output-name stage-output))))
        (when node (apply-camera-node stage-output node (%now)))))
    (%report-cameras world)
    (%sync-fallback world)
    (loop for window being the hash-values of (%windows world)
          do (%configure-window world window)
             (when (%window-presentable-p window) (%update-snapshot window)))
    (dolist (node media) (refresh-media-node world node))
    (forget-unused-images world)
    (update-reservations world reserves)
    (sweep-departed world)
    (refresh-web-nodes world (nreverse webs))
    (%scene-changed world)))

(defun stage-scene-description (world)
  "The director's scene as nested plists of declared properties. Call on the owner thread."
  (scene-description (%scene world)))

(defun %report-cameras (world)
  (dolist (stage-output (%outputs world))
    (let ((report (camera-report stage-output)))
      (when report
        (%send world (list* :type "camera" report)
               :coalesce (cons :camera (%output-name stage-output)))))))

(defun %find-camera (world output-name)
  (or (find output-name (%cameras world) :key (lambda (node) (node-prop node :output))
                                         :test #'equal)
      (find nil (%cameras world) :key (lambda (node) (node-prop node :output)))))

;;; Focus.

(defun %focusable-p (window)
  (let ((node (first (stage-window-nodes window))))
    (and (ataxia.kernel:application-mapped-p (stage-window-application window))
         (or (null node) (node-prop node :focusable)))))

(defun %report-focus (world seat-state)
  (let ((window (stage-seat-focused seat-state)))
    (%send world (list :type "focus"
                       :seat (ataxia.kernel:seat-name (stage-seat-seat seat-state))
                       :window (and window (stage-window-id window))))))

(defun %window-focused-p (world window)
  (some (lambda (seat-state) (eq window (stage-seat-focused seat-state)))
        (%seat-states world)))

(defun %panel-client (panel)
  (if (stage-web-p panel)
      (stage-web-component panel)
      (ataxia.world:overlay-component panel)))

(defun %sync-keyboard (world seat-state)
  "Give the Kernel keyboard focus to the focused panel, else the focused window."
  (let* ((seat (stage-seat-seat seat-state))
         (panel (stage-seat-focused-panel seat-state))
         (window (stage-seat-focused seat-state))
         (client (cond (panel (%panel-client panel))
                       (window (stage-window-application window))))
         (old (stage-seat-keyboard-client seat-state)))
    (unless (eq client old)
      (setf (stage-seat-keyboard-client seat-state) client)
      (when (and old (%client-live-p old))
        (ataxia.kernel:interactable-focus old world seat :clear-keyboard))
      (if client
          (ataxia.kernel:interactable-focus client world seat :keyboard)
          (ataxia.kernel:clear-wayland-focus seat :keyboard t)))))

(defun %focus-window (world seat-state window)
  "Focus WINDOW, which also takes the keyboard back from a focused page."
  (let ((old (stage-seat-focused seat-state)))
    (when window
      (setf (stage-seat-focused-panel seat-state) nil))
    (unless (eq old window)
      (setf (stage-seat-focused seat-state) window)
      (when old
        (setf (stage-seat-history seat-state)
              (cons old (remove old (stage-seat-history seat-state))))
        (when (and (%live-application-p (stage-window-application old))
                   (not (%window-focused-p world old)))
          (ataxia.kernel:request-object-state (stage-window-application old) world :activated nil)))
      (when window
        (setf (stage-seat-history seat-state) (remove window (stage-seat-history seat-state)))
        (ataxia.kernel:request-object-state (stage-window-application window) world :activated t))
      (%report-focus world seat-state))
    (%sync-keyboard world seat-state))
  window)

(defun %forget-window-focus (world window)
  (dolist (seat-state (%seat-states world))
    (setf (stage-seat-history seat-state) (remove window (stage-seat-history seat-state)))
    (when (eq window (stage-seat-focused seat-state))
      (setf (stage-seat-focused seat-state) nil)
      ;; Focus returns to the latest window still on screen. A quiescing World is
      ;; being torn down; its clients need no new focus.
      (unless (%quiescing-p world)
        (%focus-window world seat-state
                       (find-if (lambda (window) (and (%focusable-p window) (stage-window-outputs window)))
                                (stage-seat-history seat-state)))))))

(defun %default-seat-state (world)
  (first (sort (%seat-states world) #'<
               :key (lambda (state) (ataxia.kernel:object-id (stage-seat-seat state))))))

;;; Kernel lifecycle.

(defmethod ataxia.kernel:world-attached ((world stage-world) kernel)
  (setf (ataxia.kernel:world-kernel world) kernel
        (%quiescing-p world) nil)
  (when (and (stage-director-socket world) (null (%link world)))
    (setf (%link world) (start-link world (stage-director-socket world))))
  (unless (ataxia.world:world-service world :stage-reservations)
    (ataxia.world:attach-world-service world :stage-reservations (%make-stage-reservations)))
  (when (%screen-sharing-p world)
    (handler-case (enable-screen-sharing world)
      (error (cause) (%log "screen sharing is unavailable: ~A" cause))))
  (refresh-application-catalog)
  world)

(defmethod ataxia.kernel:world-quiescing ((world stage-world) reason)
  (declare (ignore reason))
  ;; Shutdown quiesces without detaching, and a replacement World binds the
  ;; same path; the director simply reconnects to whichever World listens.
  (setf (%quiescing-p world) t)
  (when (%link world)
    (stop-link (%link world))
    (setf (%link world) nil))
  (stop-images world)
  (stop-selection-reads world)
  (destroy-webs world)
  (%release-snapshots world)
  (stop-component-timer world)
  world)

(defmethod ataxia.kernel:world-detached ((world stage-world) kernel)
  (when (eq kernel (ataxia.kernel:world-kernel world))
    (dolist (stage-output (%outputs world))
      (ataxia.world:damage-forget-output (%damage world) (stage-output-output stage-output)))
    (ataxia.world:detach-world-service world :stage-reservations)
    (%release-snapshots world)
    (clrhash (%windows world))
    (clrhash (%windows-by-id world))
    (clrhash (%seats world))
    (setf (%outputs world) nil
          (ataxia.kernel:world-kernel world) nil))
  world)

(defmethod ataxia.kernel:world-register-object
    ((world stage-world) (application ataxia.kernel:wayland-application))
  (unless (gethash application (%windows world))
    (let ((window (%make-stage-window application (ataxia.kernel:object-id application))))
      (setf (gethash application (%windows world)) window
            (gethash (stage-window-id window) (%windows-by-id world)) window)
      ;; The director may already present this id, e.g. after a World restart.
      (%reindex world)
      (%report-window world window)))
  application)

(defun %window-gone (world window)
  "WINDOW stopped showing: it loses pointer and keyboard focus and stops any share."
  (%forget-pointer-client world (stage-window-application window))
  (note-window-changed world window :gone-p t)
  (%forget-window-focus world window))

(defmethod ataxia.kernel:world-unregister-object
    ((world stage-world) (application ataxia.kernel:wayland-application) reason)
  (declare (ignore reason))
  (let ((window (gethash application (%windows world))))
    (when window
      (%window-gone world window)
      (remhash application (%windows world))
      (remhash (stage-window-id window) (%windows-by-id world))
      (dolist (stage-output (%outputs world))
        (remhash window (stage-output-window-transforms stage-output)))
      (let ((node (shiftf (stage-window-fallback window) nil)))
        (when node
          (scene-remove (%fallback world) 0 (stage-node-id node))
          (scene-finish-commit (%fallback world) (%now))))
      (when (plusp (length (stage-window-snapshot window)))
        (setf (gethash (stage-window-id window) (%departed world)) window))
      (%send world (list :type "window-removed" :id (stage-window-id window)))
      (%scene-changed world)))
  application)

;;; Last frames for exit animations. The Kernel releases a closing client's
;;; buffers before the World hears it unmapped, so a window whose removal would
;;; animate keeps its current frame: each new frame is retained before the
;;; previous one is released, which holds no buffer longer than the Kernel does.

(defun %window-exits-p (window)
  "Whether removing a node that presents WINDOW plays an exit animation."
  (some (lambda (node)
          (loop for current = node then (stage-node-parent current)
                while current
                  thereis (stage-node-exit current)))
        (stage-window-nodes window)))

(defun %release-snapshot (window)
  (loop for surface across (stage-window-snapshot window)
        do (ataxia.kernel:release-render-source (ataxia.kernel:drawable-surface-render-source surface)))
  (setf (stage-window-snapshot window) #()
        (stage-window-snapshot-bounds window) nil
        (stage-window-snapshot-revision window) nil))

(defun %update-snapshot (window)
  (let ((application (stage-window-application window)))
    (if (%window-exits-p window)
        (multiple-value-bind (surfaces revision) (ataxia.kernel:drawable-surfaces application)
          ;; An unmapping client has no surfaces left: keep the frame we have.
          (when (and (plusp (length surfaces))
                     (not (eql revision (stage-window-snapshot-revision window))))
            (let ((retained nil))
              (handler-case
                  (loop for surface across surfaces
                        for source = (ataxia.kernel:drawable-surface-render-source surface)
                        do (ataxia.kernel:retain-render-source source)
                           (push source retained))
                (error ()
                  (mapc #'ataxia.kernel:release-render-source retained)
                  (return-from %update-snapshot))))
            (%release-snapshot window)
            (setf (stage-window-snapshot window) (copy-seq surfaces)
                  (stage-window-snapshot-revision window) revision
                  (stage-window-snapshot-bounds window)
                  (multiple-value-list (ataxia.kernel:drawable-local-bounds application)))))
        (%release-snapshot window))))

(defun sweep-departed (world)
  "Release last frames of closed or hidden windows that no node presents any more."
  (let ((departed (%departed world))
        (hidden (loop for window being the hash-values of (%windows world)
                      when (and (plusp (length (stage-window-snapshot window)))
                                (not (%window-presentable-p window)))
                        collect window)))
    (when (or hidden (plusp (hash-table-count departed)))
      (let ((shown (make-hash-table :test #'eql)))
        (flet ((note (node)
                 (when (eq (stage-node-kind node) :window)
                   (setf (gethash (node-prop node :window) shown) t))))
          (map-scene-nodes #'note (%scene world))
          (dolist (root (scene-exiting (%scene world)))
            (%walk-subtree root #'note)))
        (loop for id being the hash-keys of departed using (hash-value window)
              unless (gethash id shown)
                do (%release-snapshot window)
                   (remhash id departed)
                   (%invalidate-display world))
        (dolist (window hidden)
          (unless (gethash (stage-window-id window) shown)
            (%release-snapshot window)
            (%invalidate-display world)))))))

(defun %release-snapshots (world)
  (loop for window being the hash-values of (%windows world) do (%release-snapshot window))
  (loop for window being the hash-values of (%departed world) do (%release-snapshot window))
  (clrhash (%departed world)))

(defmethod ataxia.kernel:world-object-changed ((world stage-world) object change)
  (let ((kind (ataxia.kernel:object-change-kind change)))
    (typecase object
      (ataxia.kernel:wayland-application
       (let ((window (gethash object (%windows world))))
         (when window
           (when (eq kind :mapped)
             (%sync-fallback world)
             (%configure-window world window)
             (if (ataxia.kernel:object-change-value change)
                 (let ((seat-state (%default-seat-state world)))
                   (when (and seat-state (%focusable-p window))
                     (%focus-window world seat-state window)))
                 (%window-gone world window))
             (%scene-changed world))
           (%report-window world window))))
      (ataxia.kernel:surface-node
       (when (eq kind :destroying)
         (dolist (seat-state (%seat-states world))
           (when (eq object (stage-seat-cursor seat-state))
             (setf (stage-seat-cursor seat-state) nil)
             (%damage-cursor world seat-state)))))))
  object)

(defmethod ataxia.kernel:world-object-invalidated ((world stage-world) object invalidation)
  (typecase object
    (ataxia.kernel:wayland-application
     (let ((window (gethash object (%windows world))))
       (when window
         ;; New buffers replace the surface records display items draw.
         (%invalidate-display world)
         (note-window-changed world window)
         (%damage-content world window (ataxia.kernel:drawable-invalidation-damage invalidation))
         (%update-snapshot window)
         ;; New subsurfaces and popups join the window's current outputs.
         (%set-window-membership window (stage-window-outputs window))
         (unless (stage-window-configured window) (%configure-window world window))
         (%report-window world window))))
    (ataxia.kernel:surface-node
     (dolist (seat-state (%seat-states world))
       (when (eq object (stage-seat-cursor seat-state))
         (%damage-cursor world seat-state)))))
  object)

(defun %layout-outputs (world)
  (let ((offset 0d0))
    (dolist (stage-output (%outputs world))
      (setf (stage-output-offset stage-output) offset)
      (incf offset (ataxia.world:output-logical-size (stage-output-output stage-output))))))

(defun %output-description (world stage-output)
  (let ((output (stage-output-output stage-output)))
    (multiple-value-bind (width height) (ataxia.world:output-logical-size output)
      (multiple-value-bind (area-x area-y area-width area-height)
          (ataxia.world:world-output-work-area world output)
        (list :name (ataxia.kernel:output-name output)
              :x (stage-output-offset stage-output)
              :width width :height height
              :scale (coerce (ataxia.kernel:output-scale output) 'double-float)
              ;; Logical area left after shell reservations such as a status bar.
              :work-area (list :x area-x :y area-y :width area-width :height area-height))))))

(defun %report-outputs (world)
  (dolist (stage-output (%outputs world))
    (%send world (list :type "output" :output (%output-description world stage-output)))))

(defun %center-seat (seat-state stage-output)
  (multiple-value-bind (width height)
      (ataxia.world:output-logical-size (stage-output-output stage-output))
    (setf (stage-seat-x seat-state) (+ (stage-output-offset stage-output) (/ width 2d0))
          (stage-seat-y seat-state) (/ height 2d0))))

(defmethod ataxia.kernel:world-output-added ((world stage-world) output)
  (unless (%find-stage-output world output)
    (let ((first-p (null (%outputs world)))
          (stage-output (%make-stage-output output)))
      (setf (%outputs world) (append (%outputs world) (list stage-output)))
      (%layout-outputs world)
      (center-unplaced-camera stage-output)
      (let ((node (%find-camera world (%output-name stage-output))))
        (when node (apply-camera-node stage-output node (%now))))
      (dolist (seat-state (%seat-states world))
        (if first-p
            (%center-seat seat-state (first (%outputs world)))
            (%clamp-seat world seat-state))))
    (%report-outputs world)
    (%report-cameras world)
    (%full-damage world))
  output)

(defmethod ataxia.kernel:world-output-changed ((world stage-world) output change)
  (let ((stage-output (%find-stage-output world output)))
    (when stage-output
      (if (eq (ataxia.kernel:object-change-kind change) :backend-damage)
          (ataxia.world:damage-add-region
           (%damage world) output
           (ataxia.world:frame-damage-to-region (ataxia.kernel:object-change-value change)))
          (progn
            (ataxia.world:damage-reset-output (%damage world) output)
            (%layout-outputs world)
            (center-unplaced-camera stage-output)
            ;; A smaller mode or larger scale can leave the pointer outside.
            (dolist (seat-state (%seat-states world))
              (%clamp-seat world seat-state))
            (%invalidate-display world)
            (%report-outputs world)
            (%report-cameras world)))
      (%request-frames world (list stage-output))))
  output)

(defmethod ataxia.kernel:world-output-removing ((world stage-world) output)
  (let ((stage-output (%find-stage-output world output)))
    (when stage-output
      ;; Pages shown only there stop painting.
      (sync-web-presence world stage-output (make-hash-table))
      (setf (%outputs world) (remove stage-output (%outputs world)))
      (ataxia.world:damage-forget-output (%damage world) output)
      (loop for window being the hash-values of (%windows world)
            when (member output (stage-window-outputs window))
              do (%set-window-membership window (remove output (stage-window-outputs window))))
      (%layout-outputs world)
      (dolist (seat-state (%seat-states world))
        (%clamp-seat world seat-state))
      (%send world (list :type "output-removed" :name (ataxia.kernel:output-name output)))
      (%report-outputs world)
      (%full-damage world)))
  output)

(defmethod ataxia.kernel:world-seat-added ((world stage-world) seat)
  (let ((seat-state (%make-stage-seat seat)))
    (when (%outputs world)
      (%center-seat seat-state (first (%outputs world))))
    (setf (gethash seat (%seats world)) seat-state)
    (%damage-cursor world seat-state))
  seat)

(defmethod ataxia.kernel:world-seat-removing ((world stage-world) seat)
  ;; The seat's protocol focus disappears with it; only World state is dropped.
  (when (remhash seat (%seats world))
    (ataxia.world:forget-shortcut-seat (ataxia.world:world-shortcut-controller world) seat)
    (%request-frames world))
  seat)

(defmethod ataxia.kernel:world-seat-cursor-request ((world stage-world) seat request)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (setf (stage-seat-cursor seat-state) (ataxia.kernel:cursor-surface-request-surface request)
            (stage-seat-cursor-set-p seat-state) t
            (stage-seat-cursor-x seat-state) (ataxia.kernel:cursor-surface-request-hotspot-x request)
            (stage-seat-cursor-y seat-state) (ataxia.kernel:cursor-surface-request-hotspot-y request))
      (%damage-cursor world seat-state)))
  request)

(defmethod ataxia.kernel:world-seat-drag-icon-changed ((world stage-world) seat)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state (%damage-cursor world seat-state))))
